#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
migrate_db.py — Django migrate hacia db.practicayoruba.com
==========================================================
Wrapper que corre `python manage.py migrate` con la configuración
de base de datos apuntando a db.practicayoruba.com:3306 via SSL.

Verifica antes de migrar:
  1. Conectividad SSL a MariaDB
  2. manage.py existe en la ruta configurada
  3. Schema kaupamex_db accesible con el usuario app

Después de migrar verifica:
  4. Tablas Django creadas en kaupamex_db

Uso:
  cd scripts/db-client
  python migrate_db.py              # migrate en producción
  python migrate_db.py --schema qa  # migrate en QA
  python migrate_db.py --check      # solo verificar sin migrar
  python migrate_db.py --list       # listar migraciones pendientes

Prerequisitos:
  pip install -r requirements.txt
  .env configurado con DB_USER=practicayoruba_app
  DJANGO_MANAGE_PATH apuntando al manage.py del proyecto
"""

import sys
import os
import subprocess
import argparse
import logging
from typing import List

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

    def ok(self, msg):    self._p(Fore.GREEN,  "[OK]     ", msg)
    def info(self, msg):  self._p(Fore.CYAN,   "[INFO]   ", msg)
    def warn(self, msg):  self._p(Fore.YELLOW, "[WARN]   ", msg)
    def error(self, msg): self._p(Fore.RED,    "[ERROR]  ", msg)


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

def connect(env: dict, schema: str) -> mysql.connector.MySQLConnection:
    params = {
        'host':               env.get('DB_HOST', 'db.practicayoruba.com'),
        'port':               int(env.get('DB_PORT', 3306)),
        'user':               env.get('DB_USER', 'practicayoruba_app'),
        'password':           env.get('DB_PASSWORD', ''),
        'database':           schema,
        'connection_timeout': 10,
        'ssl_verify_cert':    True,
        'ssl_verify_identity': False,
    }
    ssl_ca = env.get('DB_SSL_CA', '').strip()
    if ssl_ca:
        params['ssl_ca'] = ssl_ca
    return mysql.connector.connect(**params)


# ── Pre-check ─────────────────────────────────────────────────────────────────

def pre_check(env: dict, schema: str, manage_py: str,
              log: Logger) -> bool:
    ok = True

    log.step(1, 3, "Verificar conectividad SSL a MariaDB")
    try:
        cnx = connect(env, schema)
        row_host = cnx.cursor()
        row_host.execute("SELECT @@hostname, @@version")
        hostname, version = row_host.fetchone()
        row_host.close()

        cipher_cur = cnx.cursor()
        cipher_cur.execute("SHOW STATUS LIKE 'Ssl_cipher'")
        _, cipher = cipher_cur.fetchone()
        cipher_cur.close()

        cnx.close()
        log.ok(f"hostname={hostname}, MariaDB {version}")
        log.ok(f"SSL activo: {cipher}")
    except MySQLError as e:
        log.error(f"No se puede conectar: {e}")
        ok = False

    log.step(2, 3, f"Verificar manage.py en {manage_py}")
    manage_abs = os.path.abspath(manage_py)
    if os.path.isfile(manage_abs):
        log.ok(f"manage.py encontrado: {manage_abs}")
    else:
        log.error(f"manage.py NO encontrado: {manage_abs}")
        log.warn("Ajustar DJANGO_MANAGE_PATH en .env")
        ok = False

    log.step(3, 3, f"Verificar schema {schema} accesible")
    try:
        cnx = connect(env, schema)
        cur = cnx.cursor()
        cur.execute(
            "SELECT COUNT(*) FROM information_schema.tables "
            f"WHERE table_schema='{schema}'")
        count = cur.fetchone()[0]
        cur.close()
        cnx.close()
        log.ok(f"Schema {schema} accesible — {count} tabla(s) existentes")
    except MySQLError as e:
        log.error(f"Schema {schema} no accesible: {e}")
        ok = False

    return ok


# ── Tablas Django post-migrate ─────────────────────────────────────────────────

def verificar_tablas_django(env: dict, schema: str, log: Logger) -> bool:
    """Verifica que las tablas Django clave existen post-migrate."""
    tablas_django = [
        'django_migrations',
        'django_content_type',
        'auth_user',
        'auth_permission',
        'auth_group',
    ]
    try:
        cnx = connect(env, schema)
        cur = cnx.cursor()
        cur.execute(
            "SELECT table_name FROM information_schema.tables "
            f"WHERE table_schema='{schema}'")
        existentes = {r[0] for r in cur.fetchall()}
        cur.close()
        cnx.close()

        log.info(f"Tablas en {schema}: {len(existentes)} total")
        ok = True
        for tabla in tablas_django:
            if tabla in existentes:
                log.ok(f"  {tabla}")
            else:
                log.warn(f"  {tabla} — NO encontrada")
                ok = False
        return ok
    except MySQLError as e:
        log.error(f"Error verificando tablas: {e}")
        return False


# ── Django manage.py wrapper ───────────────────────────────────────────────────

def build_env_for_django(env: dict, schema: str) -> dict:
    """
    Construye variables de entorno para que Django use la BD correcta.
    Se inyectan via os.environ para el subprocess de manage.py.
    El settings de Django debe leer estas variables.
    """
    django_env = os.environ.copy()

    # Variables estándar que Django settings suele leer
    django_env['DB_HOST']     = env.get('DB_HOST', 'db.practicayoruba.com')
    django_env['DB_PORT']     = env.get('DB_PORT', '3306')
    django_env['DB_NAME']     = schema
    django_env['DB_USER']     = env.get('DB_USER', 'practicayoruba_app')
    django_env['DB_PASSWORD'] = env.get('DB_PASSWORD', '')
    django_env['DB_SSL_CA']   = env.get('DB_SSL_CA', '')

    # DJANGO_SETTINGS_MODULE si está en .env
    settings = env.get('DJANGO_SETTINGS_MODULE', '')
    if settings:
        django_env['DJANGO_SETTINGS_MODULE'] = settings

    return django_env


def run_manage(manage_py: str, args: List[str],
               django_env: dict, log: Logger) -> bool:
    """Ejecuta python manage.py <args> y muestra output en tiempo real."""
    cmd = [sys.executable, manage_py] + args
    log.info(f"Ejecutando: {' '.join(cmd)}")
    log.info("")

    proc = subprocess.Popen(
        cmd,
        env=django_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding='utf-8',
        errors='replace',
    )

    for line in proc.stdout:
        line = line.rstrip()
        print(f"  {line}")
        log._l.info(line)

    proc.wait()
    return proc.returncode == 0


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Django migrate hacia db.practicayoruba.com')
    parser.add_argument('--schema', choices=['prod', 'qa'], default='prod',
                        help='Schema destino: prod=kaupamex_db, '
                             'qa=kaupamex_qa (default: prod)')
    parser.add_argument('--check', action='store_true',
                        help='Solo verificar conectividad sin migrar')
    parser.add_argument('--list', action='store_true',
                        help='Listar migraciones pendientes (showmigrations)')
    args = parser.parse_args()

    log = Logger("migrate_db")
    env = load_env()

    schema_map = {
        'prod': env.get('DB_NAME', 'kaupamex_db'),
        'qa':   env.get('DB_QA_NAME', 'kaupamex_qa'),
    }
    schema = schema_map[args.schema]
    manage_py = os.path.abspath(
        env.get('DJANGO_MANAGE_PATH', '../manage.py'))

    log.header(f"MIGRATE DB — {env.get('DB_HOST', 'db.practicayoruba.com')} "
               f"→ {schema}")
    log.info(f"manage.py: {manage_py}")
    log.info(f"Log: {log.log_file}")

    # Pre-check siempre
    ok = pre_check(env, schema, manage_py, log)
    if not ok:
        log.error("Pre-check fallido — corregir antes de migrar")
        sys.exit(1)

    if args.check:
        log.header("RESULTADO — solo verificación")
        log.ok("Pre-check OK — BD accesible y manage.py encontrado")
        sys.exit(0)

    django_env = build_env_for_django(env, schema)

    if args.list:
        log.header("MIGRACIONES PENDIENTES")
        ok = run_manage(manage_py, ['showmigrations', '--list'],
                        django_env, log)
        sys.exit(0 if ok else 1)

    # Migrate
    log.header(f"EJECUTANDO migrate → {schema}")
    ok = run_manage(manage_py, ['migrate', '--verbosity=1'],
                    django_env, log)

    if ok:
        log.header("VERIFICANDO TABLAS DJANGO POST-MIGRATE")
        ok = verificar_tablas_django(env, schema, log)

    log.header("RESUMEN")
    if ok:
        log.ok(f"migrate completado — {schema} con tablas Django")
        log.info("Siguiente paso: verificar con check_db.py")
    else:
        log.error("migrate completado con errores — revisar log")
        log.info(f"Log detallado: {log.log_file}")

    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
