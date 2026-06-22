#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
setup_db.py — Setup de MariaDB ecom-prod desde el cliente local
================================================================
Crea schemas, usuarios y permisos de forma idempotente.
Útil para recrear el estado desde cero en un entorno nuevo (QA local,
staging) o para verificar que el estado en producción es el correcto.

REQUIERE un usuario con privilegios suficientes para crear schemas
y usuarios. Se recomienda usar un usuario admin configurado aparte,
NO el usuario practicayoruba_app de la aplicación.

Por defecto usa DB_USER y DB_PASSWORD del .env que deben tener
CREATE, CREATE USER y GRANT OPTION. Si no los tienen, el script
reportará exactamente qué pasos no pudo ejecutar.

Estado objetivo en VM3:
  Schemas: practicayoruba_db (utf8mb4/utf8mb4_unicode_ci)
           practicayoruba_qa (utf8mb4/utf8mb4_unicode_ci)

  Usuarios:
    practicayoruba_app@%            → DML en db, ALL en qa
    practicayoruba_app@localhost    → idem
    practicayoruba_app@127.0.0.1   → idem
    practicayoruba_readonly@%      → SELECT en db

Uso:
  cd scripts/db-client
  python setup_db.py [--dry-run]

  --dry-run: muestra las operaciones sin ejecutarlas

Prerequisitos:
  pip install -r requirements.txt
  .env con DB_USER que tenga privilegios de administración
"""

import sys
import os
import argparse
import logging
from typing import List, Tuple

for mod, pkg in [('mysql.connector', 'mysql-connector-python'),
                 ('colorama', 'colorama')]:
    try:
        __import__(mod.split('.')[0])
    except ImportError:
        print(f"ERROR: falta {mod} — instalar con: pip install {pkg}")
        sys.exit(1)

import mysql.connector
from mysql.connector import Error as MySQLError

try:
    from colorama import Fore, Style, init
    init(autoreset=True)
except ImportError:
    class _C:
        def __getattr__(self, _): return ''
    Fore = Style = _C()


# ── Logger ────────────────────────────────────────────────────────────────────

class Logger:
    def __init__(self, name: str, logs_dir: str = "logs"):
        os.makedirs(logs_dir, exist_ok=True)
        self.log_file = os.path.join(logs_dir, f"{name}.log")
        self._l = logging.getLogger(name)
        self._l.setLevel(logging.INFO)
        if not self._l.handlers:
            fh = logging.FileHandler(self.log_file, mode='w', encoding='utf-8')
            fh.setFormatter(logging.Formatter(
                '[%(asctime)s] [%(levelname)-7s] %(message)s',
                datefmt='%Y-%m-%d %H:%M:%S'))
            self._l.addHandler(fh)

    def _p(self, color, prefix, msg):
        print(f"{color}{prefix}{Style.RESET_ALL} {msg}")
        self._l.info(f"{prefix} {msg}")

    def header(self, msg):
        sep = "=" * 68
        print(f"\n{Fore.CYAN}{sep}\n  {msg}\n{sep}{Style.RESET_ALL}\n")
        self._l.info(f"=== {msg} ===")

    def step(self, n, total, msg):
        print(f"\n{Fore.BLUE}[{n}/{total}]{Style.RESET_ALL} {msg}")
        print("-" * 68)
        self._l.info(f"[{n}/{total}] {msg}")

    def ok(self, msg):      self._p(Fore.GREEN,  "[OK]     ", msg)
    def skip(self, msg):    self._p(Fore.CYAN,   "[SKIP]   ", msg)
    def info(self, msg):    self._p(Fore.CYAN,   "[INFO]   ", msg)
    def warn(self, msg):    self._p(Fore.YELLOW, "[WARN]   ", msg)
    def error(self, msg):   self._p(Fore.RED,    "[ERROR]  ", msg)
    def dry(self, msg):     self._p(Fore.YELLOW, "[DRY-RUN]", msg)


# ── .env ──────────────────────────────────────────────────────────────────────

def load_env(path: str = None) -> dict:
    if path is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env')
    env = {}
    if os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, _, v = line.partition('=')
                    env[k.strip()] = v.strip().strip('"').strip("'")
    return env


# ── Conexión ──────────────────────────────────────────────────────────────────

def connect_admin(env: dict) -> mysql.connector.MySQLConnection:
    params = {
        'host':               env.get('DB_HOST', 'db.practicayoruba.com'),
        'port':               int(env.get('DB_PORT', 3306)),
        'user':               env.get('DB_USER', 'practicayoruba_app'),
        'password':           env.get('DB_PASSWORD', ''),
        'connection_timeout': 10,
        'ssl_verify_cert':    True,
        'ssl_verify_identity': False,
    }
    ssl_ca = env.get('DB_SSL_CA', '').strip()
    if ssl_ca:
        params['ssl_ca'] = ssl_ca
    return mysql.connector.connect(**params)


def exec_sql(cnx, sql: str, log: Logger, dry_run: bool,
             ok_msg: str = None, skip_msg: str = None) -> bool:
    """Ejecuta SQL. En dry_run solo imprime. Retorna True si OK."""
    if dry_run:
        log.dry(sql.strip())
        return True
    try:
        cur = cnx.cursor()
        cur.execute(sql)
        cnx.commit()
        cur.close()
        if ok_msg:
            log.ok(ok_msg)
        return True
    except MySQLError as e:
        err = str(e)
        # Errores idempotentes — no es un fallo real
        idempotent = [
            "already exists", "Can't create database",
            "Operation CREATE USER failed",
            "1007", "1396",
        ]
        if any(x in err for x in idempotent):
            if skip_msg:
                log.skip(skip_msg)
            return True
        log.error(f"SQL falla: {e}")
        log.error(f"  → {sql.strip()}")
        return False


def row_exists(cnx, sql: str) -> bool:
    cur = cnx.cursor()
    cur.execute(sql)
    row = cur.fetchone()
    cur.close()
    return bool(row and row[0])


# ── Pasos de setup ─────────────────────────────────────────────────────────────

def setup_schemas(cnx, log: Logger, dry_run: bool) -> bool:
    log.step(1, 5, "Crear schemas")
    ok = True

    for schema in ['practicayoruba_db', 'practicayoruba_qa']:
        exists = row_exists(cnx,
            f"SELECT SCHEMA_NAME FROM information_schema.SCHEMATA "
            f"WHERE SCHEMA_NAME='{schema}'")
        if exists and not dry_run:
            log.skip(f"Schema {schema} ya existe — sin cambios")
        else:
            ok &= exec_sql(cnx,
                f"CREATE DATABASE IF NOT EXISTS `{schema}` "
                f"CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci",
                log, dry_run,
                ok_msg=f"Schema {schema} creado (utf8mb4/utf8mb4_unicode_ci)",
                skip_msg=f"Schema {schema} ya existe")

    return ok


def setup_usuario_app(cnx, env: dict, log: Logger, dry_run: bool) -> bool:
    log.step(2, 5, "Crear usuario practicayoruba_app (3 hosts)")
    ok = True
    pwd = env.get('DB_PASSWORD', '')

    for host in ['%', 'localhost', '127.0.0.1']:
        user_host = f"'practicayoruba_app'@'{host}'"

        exists = row_exists(cnx,
            f"SELECT COUNT(*) FROM mysql.user "
            f"WHERE User='practicayoruba_app' AND Host='{host}'")

        if exists and not dry_run:
            # Sincronizar contraseña
            ok &= exec_sql(cnx,
                f"ALTER USER {user_host} IDENTIFIED BY '{pwd}'",
                log, dry_run,
                ok_msg=f"Contraseña sincronizada: {user_host}")
        else:
            ok &= exec_sql(cnx,
                f"CREATE USER IF NOT EXISTS {user_host} IDENTIFIED BY '{pwd}'",
                log, dry_run,
                ok_msg=f"Usuario creado: {user_host}",
                skip_msg=f"Usuario ya existe: {user_host}")

    return ok


def setup_usuario_readonly(cnx, env: dict, log: Logger, dry_run: bool) -> bool:
    log.step(3, 5, "Crear usuario practicayoruba_readonly")
    ok = True
    pwd = env.get('DB_READONLY_PASSWORD', '')
    user_host = "'practicayoruba_readonly'@'%'"

    exists = row_exists(cnx,
        "SELECT COUNT(*) FROM mysql.user "
        "WHERE User='practicayoruba_readonly' AND Host='%'")

    if exists and not dry_run:
        ok &= exec_sql(cnx,
            f"ALTER USER {user_host} IDENTIFIED BY '{pwd}'",
            log, dry_run,
            ok_msg="Contraseña readonly sincronizada")
    else:
        ok &= exec_sql(cnx,
            f"CREATE USER IF NOT EXISTS {user_host} IDENTIFIED BY '{pwd}'",
            log, dry_run,
            ok_msg=f"Usuario creado: {user_host}",
            skip_msg="Usuario readonly ya existe")

    return ok


def setup_grants(cnx, log: Logger, dry_run: bool) -> bool:
    log.step(4, 5, "Aplicar grants")
    ok = True

    grants = [
        # app — DML en prod (3 hosts)
        ("SELECT, INSERT, UPDATE, DELETE", "practicayoruba_db.*",
         "practicayoruba_app", "%"),
        ("SELECT, INSERT, UPDATE, DELETE", "practicayoruba_db.*",
         "practicayoruba_app", "localhost"),
        ("SELECT, INSERT, UPDATE, DELETE", "practicayoruba_db.*",
         "practicayoruba_app", "127.0.0.1"),

        # app — ALL en QA (3 hosts)
        ("ALL PRIVILEGES", "practicayoruba_qa.*",
         "practicayoruba_app", "%"),
        ("ALL PRIVILEGES", "practicayoruba_qa.*",
         "practicayoruba_app", "localhost"),
        ("ALL PRIVILEGES", "practicayoruba_qa.*",
         "practicayoruba_app", "127.0.0.1"),

        # readonly — SELECT en prod
        ("SELECT", "practicayoruba_db.*",
         "practicayoruba_readonly", "%"),
    ]

    for privs, on, user, host in grants:
        ok &= exec_sql(cnx,
            f"GRANT {privs} ON {on} TO '{user}'@'{host}'",
            log, dry_run,
            ok_msg=f"GRANT {privs} ON {on} → '{user}'@'{host}'")

    ok &= exec_sql(cnx, "FLUSH PRIVILEGES", log, dry_run,
                   ok_msg="FLUSH PRIVILEGES OK")
    return ok


def verificar_grants(cnx, log: Logger, dry_run: bool) -> bool:
    log.step(5, 5, "Verificar grants aplicados")
    if dry_run:
        log.dry("SHOW GRANTS FOR 'practicayoruba_app'@'%'")
        log.dry("SHOW GRANTS FOR 'practicayoruba_readonly'@'%'")
        return True

    ok = True
    for user, host in [('practicayoruba_app', '%'),
                        ('practicayoruba_readonly', '%')]:
        try:
            cur = cnx.cursor()
            cur.execute(f"SHOW GRANTS FOR '{user}'@'{host}'")
            rows = cur.fetchall()
            cur.close()
            log.ok(f"SHOW GRANTS '{user}'@'{host}':")
            for r in rows:
                log.info(f"  {r[0]}")
        except MySQLError as e:
            log.error(f"No se pudo obtener grants de {user}@{host}: {e}")
            ok = False
    return ok


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Setup MariaDB ecom-prod desde cliente local')
    parser.add_argument('--dry-run', action='store_true',
                        help='Mostrar operaciones sin ejecutarlas')
    args = parser.parse_args()

    log = Logger("setup_db")
    env = load_env()

    host = env.get('DB_HOST', 'db.practicayoruba.com')
    port = env.get('DB_PORT', '3306')

    mode = "DRY-RUN" if args.dry_run else "APLICANDO"
    log.header(f"SETUP DB — {host}:{port} [{mode}]")
    log.info(f"Usuario admin: {env.get('DB_USER', 'practicayoruba_app')}")
    log.info(f"Log: {log.log_file}")

    if args.dry_run:
        log.warn("Modo DRY-RUN — ningún cambio se aplicará en la BD")

    # Conectar
    try:
        cnx = connect_admin(env)
        log.ok(f"Conectado a {host}:{port} con SSL")
    except MySQLError as e:
        log.error(f"No se puede conectar: {e}")
        sys.exit(1)

    results = []
    for fn, label in [
        (lambda: setup_schemas(cnx, log, args.dry_run),        "Schemas"),
        (lambda: setup_usuario_app(cnx, env, log, args.dry_run), "Usuario app"),
        (lambda: setup_usuario_readonly(cnx, env, log, args.dry_run), "Usuario readonly"),
        (lambda: setup_grants(cnx, log, args.dry_run),         "Grants"),
        (lambda: verificar_grants(cnx, log, args.dry_run),     "Verificación grants"),
    ]:
        try:
            ok = fn()
        except Exception as e:
            log.error(f"Excepción: {e}")
            ok = False
        results.append((label, ok))

    cnx.close()

    log.header("RESUMEN")
    all_ok = True
    for label, ok in results:
        if ok:
            log.ok(label)
        else:
            log.error(label)
            all_ok = False

    print()
    if all_ok:
        if args.dry_run:
            log.ok("Dry-run completado — sin errores. Ejecutar sin --dry-run para aplicar.")
        else:
            log.ok("Setup completado — ejecutar check_db.py para verificar")
    else:
        log.error("Setup completado con errores — revisar log")
        log.warn("Nota: el usuario DB_USER necesita CREATE, CREATE USER y GRANT OPTION")
        log.info(f"Log detallado: {log.log_file}")

    sys.exit(0 if all_ok else 1)


if __name__ == '__main__':
    main()
