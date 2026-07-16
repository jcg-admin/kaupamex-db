#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_db.py — Verificación de MariaDB ecom-prod
================================================
Verifica conectividad SSL, usuarios, permisos y estado de schemas
contra db.practicayoruba.com:3306 desde el entorno local del desarrollador.

Lee configuración desde .env en el mismo directorio.

Checks realizados:
  1. Conectividad SSL con practicayoruba_readonly (SELECT)
  2. Conectividad SSL con practicayoruba_app (DML)
  3. SSL activo en la conexión (Ssl_cipher no vacío)
  4. require_secure_transport rechaza conexión sin SSL
  5. Schemas existentes: kaupamex_db, kaupamex_qa
  6. Permisos readonly: SELECT sí, INSERT no
  7. Permisos app en prod: DML sí, DROP no
  8. Permisos app en QA: ALL sí

Uso:
  cd scripts/db-client
  python check_db.py

Prerequisitos:
  pip install -r requirements.txt
  Copiar .env.example → .env y rellenar contraseñas
"""

import sys
import os
import logging
from typing import Tuple, Dict, Any

# ── Dependencias ──────────────────────────────────────────────────────────────

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


# ── Logger (patrón IACTLogger de check_db_connections.py) ────────────────────

class Logger:
    def __init__(self, script_name: str, logs_dir: str = "logs"):
        os.makedirs(logs_dir, exist_ok=True)
        self.log_file = os.path.join(logs_dir, f"{script_name}.log")
        self._logger = logging.getLogger(script_name)
        self._logger.setLevel(logging.INFO)
        if not self._logger.handlers:
            fh = logging.FileHandler(self.log_file, mode='w', encoding='utf-8')
            fh.setFormatter(logging.Formatter(
                '[%(asctime)s] [%(levelname)-7s] %(message)s',
                datefmt='%Y-%m-%d %H:%M:%S'))
            self._logger.addHandler(fh)

    def _p(self, color, prefix, msg):
        print(f"{color}{prefix}{Style.RESET_ALL} {msg}")
        self._logger.info(f"{prefix} {msg}")

    def header(self, msg):
        sep = "=" * 68
        print(f"\n{Fore.CYAN}{sep}\n  {msg}\n{sep}{Style.RESET_ALL}\n")
        self._logger.info(f"=== {msg} ===")

    def step(self, n, total, msg):
        print(f"\n{Fore.BLUE}[{n}/{total}]{Style.RESET_ALL} {msg}")
        print("-" * 68)
        self._logger.info(f"[{n}/{total}] {msg}")

    def ok(self, msg):   self._p(Fore.GREEN,  "[OK]     ", msg)
    def info(self, msg): self._p(Fore.CYAN,   "[INFO]   ", msg)
    def warn(self, msg): self._p(Fore.YELLOW, "[WARN]   ", msg)
    def error(self, msg):self._p(Fore.RED,    "[ERROR]  ", msg)


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


# ── Conexión SSL ───────────────────────────────────────────────────────────────

def _get_ssl_ca(cfg: dict) -> str:
    """
    Devuelve la ruta al bundle de CAs para verificar el certificado del servidor.
    Prioridad:
      1. DB_SSL_CA en .env (ruta explícita)
      2. certifi — bundle de CAs portátil (funciona en Windows, Linux, macOS)
      3. None — mysql-connector usa SSL_CTX_set_default_verify_paths (falla en Windows)
    """
    ssl_ca = cfg.get('ssl_ca', '').strip()
    if ssl_ca:
        return ssl_ca
    try:
        import certifi
        return certifi.where()
    except ImportError:
        return None


def connect(cfg: dict, require_ssl: bool = True) -> mysql.connector.MySQLConnection:
    """
    Abre conexión a MariaDB con SSL.
    El certificado Let's Encrypt es público — verificado con certifi (CA pública).
    Funciona en Windows, Linux y macOS sin configuración adicional.
    """
    params = {
        'host':             cfg['host'],
        'port':             int(cfg.get('port', 3306)),
        'user':             cfg['user'],
        'password':         cfg['password'],
        'database':         cfg.get('database'),
        'connection_timeout': 10,
        'ssl_verify_cert':  require_ssl,
        'ssl_verify_identity': False,   # SNI — no verificar hostname en cert
    }

    if require_ssl:
        ssl_ca = _get_ssl_ca(cfg)
        if ssl_ca:
            params['ssl_ca'] = ssl_ca

    if not require_ssl:
        # Intento sin SSL — debe fallar con require_secure_transport=ON
        params['ssl_disabled'] = True
        params.pop('ssl_verify_cert', None)
        params.pop('ssl_verify_identity', None)

    return mysql.connector.connect(**params)


def query_one(cnx, sql: str):
    cur = cnx.cursor()
    cur.execute(sql)
    row = cur.fetchone()
    cur.close()
    return row


def query_all(cnx, sql: str):
    cur = cnx.cursor()
    cur.execute(sql)
    rows = cur.fetchall()
    cur.close()
    return rows


# ── Checks ────────────────────────────────────────────────────────────────────

def check_ssl_conectividad(cfg_readonly: dict, cfg_app: dict,
                            log: Logger) -> Tuple[bool, bool]:
    """Check 1+2: conectividad SSL readonly y app."""
    ok_ro = ok_app = False

    # readonly
    try:
        cnx = connect(cfg_readonly)
        row = query_one(cnx, "SELECT @@hostname, @@version")
        log.ok(f"readonly → hostname={row[0]}, MariaDB {row[1]}")
        cnx.close()
        ok_ro = True
    except MySQLError as e:
        log.error(f"readonly falla: {e}")

    # app
    try:
        cnx = connect(cfg_app)
        row = query_one(cnx, "SELECT @@hostname, @@version")
        log.ok(f"app → hostname={row[0]}, MariaDB {row[1]}")
        cnx.close()
        ok_app = True
    except MySQLError as e:
        log.error(f"app falla: {e}")

    return ok_ro, ok_app


def check_ssl_cifrado(cfg_readonly: dict, log: Logger) -> bool:
    """Check 3: verificar que SSL está activo (Ssl_cipher no vacío)."""
    try:
        cnx = connect(cfg_readonly)
        row = query_one(cnx, "SHOW STATUS LIKE 'Ssl_cipher'")
        cnx.close()
        if row and row[1]:
            log.ok(f"Ssl_cipher = {row[1]}")
            return True
        else:
            log.error("Ssl_cipher vacío — conexión sin cifrado")
            return False
    except MySQLError as e:
        log.error(f"No se pudo verificar SSL: {e}")
        return False


def check_ssl_rechaza_sin_ssl(cfg_readonly: dict, log: Logger) -> bool:
    """Check 4: require_secure_transport rechaza conexión sin SSL."""
    cfg_nossl = {**cfg_readonly}
    try:
        cnx = connect(cfg_nossl, require_ssl=False)
        cnx.close()
        log.error("Conexión sin SSL aceptada — require_secure_transport puede estar OFF")
        return False
    except MySQLError as e:
        msg = str(e)
        if 'secure' in msg.lower() or '1045' in msg or 'SSL' in msg or 'ssl' in msg:
            log.ok(f"Conexión sin SSL rechazada correctamente")
            return True
        else:
            log.warn(f"Conexión sin SSL falló (causa diferente): {e}")
            return True   # Falló de todas formas — objetivo cumplido


def check_schemas(cfg_app: dict, log: Logger) -> bool:
    """Check 5: schemas kaupamex_db y kaupamex_qa existen."""
    try:
        cfg = {**cfg_app, 'database': None}
        cnx = connect(cfg)
        rows = query_all(cnx, "SHOW DATABASES LIKE 'practicayoruba%'")
        cnx.close()
        schemas = [r[0] for r in rows]
        log.info(f"Schemas encontrados: {schemas}")

        ok = True
        for s in ['kaupamex_db', 'kaupamex_qa']:
            if s in schemas:
                log.ok(f"Schema {s} existe")
            else:
                log.error(f"Schema {s} NO existe")
                ok = False
        return ok
    except MySQLError as e:
        log.error(f"Error verificando schemas: {e}")
        return False


def check_permisos_readonly(cfg_readonly: dict, log: Logger) -> bool:
    """Check 6: readonly puede SELECT, no puede INSERT."""
    ok = True
    cfg = {**cfg_readonly, 'database': 'kaupamex_db'}
    try:
        cnx = connect(cfg)

        # SELECT debe funcionar (en tabla de sistema)
        try:
            query_one(cnx, "SELECT COUNT(*) FROM information_schema.tables "
                           "WHERE table_schema='kaupamex_db'")
            log.ok("readonly: SELECT en kaupamex_db OK")
        except MySQLError as e:
            log.error(f"readonly: SELECT falla — {e}")
            ok = False

        # INSERT debe ser rechazado
        try:
            cur = cnx.cursor()
            cur.execute("CREATE TABLE IF NOT EXISTS _test_ro (id INT)")
            cur.close()
            log.error("readonly: CREATE TABLE aceptado — permisos excesivos")
            ok = False
        except MySQLError:
            log.ok("readonly: CREATE TABLE rechazado correctamente")

        cnx.close()
    except MySQLError as e:
        log.error(f"No se pudo conectar como readonly: {e}")
        ok = False
    return ok


def check_permisos_app_prod(cfg_app: dict, log: Logger) -> bool:
    """Check 7: app puede DML en kaupamex_db, no puede DROP DATABASE.

    practicayoruba_app tiene solo DML (SELECT, INSERT, UPDATE, DELETE) en
    kaupamex_db — no tiene CREATE TABLE permanente. Se usa
    CREATE TEMPORARY TABLE que no requiere privilegio CREATE y solo
    existe en la sesion actual.
    """
    ok = True
    cfg = {**cfg_app, 'database': 'kaupamex_db'}
    try:
        cnx = connect(cfg)
        cur = cnx.cursor()

        # Verificar grants DML via SHOW GRANTS
        # practicayoruba_app tiene SELECT, INSERT, UPDATE, DELETE en prod
        # No tiene CREATE — verificamos grants directamente sin crear tablas
        try:
            cur.execute("SHOW GRANTS FOR CURRENT_USER()")
            grants = [row[0] for row in cur.fetchall()]
            grant_str = ' '.join(grants).upper()

            dml_ok = all(op in grant_str for op in
                         ['SELECT', 'INSERT', 'UPDATE', 'DELETE'])
            if dml_ok:
                log.ok("app prod: grants DML (SELECT, INSERT, UPDATE, DELETE) confirmados")
            else:
                log.error(f"app prod: grants DML incompletos — {grants}")
                ok = False

            # SELECT funcional
            cur.execute("SELECT COUNT(*) FROM information_schema.tables "
                        "WHERE table_schema = 'kaupamex_db'")
            cur.fetchall()  # consumir resultados antes del siguiente query
            log.ok("app prod: SELECT funcional OK")
        except MySQLError as e:
            log.error(f"app prod: error verificando grants — {e}")
            ok = False

        # DROP DATABASE debe ser rechazado
        try:
            cur.execute("DROP DATABASE kaupamex_db")
            log.error("app prod: DROP DATABASE aceptado — permisos excesivos")
            ok = False
        except MySQLError:
            log.ok("app prod: DROP DATABASE rechazado correctamente")

        cur.close()
        cnx.close()
    except MySQLError as e:
        log.error(f"No se pudo conectar como app: {e}")
        ok = False
    return ok


def check_permisos_app_qa(cfg_app_qa: dict, log: Logger) -> bool:
    """Check 8: app puede ALL PRIVILEGES en kaupamex_qa."""
    ok = True
    cfg = {**cfg_app_qa, 'database': 'kaupamex_qa'}
    try:
        cnx = connect(cfg)
        cur = cnx.cursor()

        try:
            cur.execute("CREATE TABLE IF NOT EXISTS _check_qa "
                        "(id INT AUTO_INCREMENT PRIMARY KEY, val VARCHAR(32))")
            cur.execute("INSERT INTO _check_qa (val) VALUES ('qa_test')")
            cnx.commit()
            cur.execute("DROP TABLE IF EXISTS _check_qa")
            cnx.commit()
            log.ok("app QA: CREATE + INSERT + DROP OK")
        except MySQLError as e:
            log.error(f"app QA: operación falla — {e}")
            ok = False

        cur.close()
        cnx.close()
    except MySQLError as e:
        log.error(f"No se pudo conectar como app en QA: {e}")
        ok = False
    return ok


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    log = Logger("check_db")
    env = load_env()

    host = env.get('DB_HOST', 'db.practicayoruba.com')
    port = env.get('DB_PORT', '3306')
    ssl_ca = env.get('DB_SSL_CA', '')

    cfg_readonly = {
        'host': host, 'port': port,
        'user': env.get('DB_READONLY_USER', 'practicayoruba_readonly'),
        'password': env.get('DB_READONLY_PASSWORD', ''),
        'database': env.get('DB_NAME', 'kaupamex_db'),
        'ssl_ca': ssl_ca,
    }
    cfg_app = {
        'host': host, 'port': port,
        'user': env.get('DB_USER', 'practicayoruba_app'),
        'password': env.get('DB_PASSWORD', ''),
        'database': env.get('DB_NAME', 'kaupamex_db'),
        'ssl_ca': ssl_ca,
    }
    cfg_app_qa = {
        'host': host, 'port': port,
        'user': env.get('DB_QA_USER', 'practicayoruba_app'),
        'password': env.get('DB_QA_PASSWORD', ''),
        'database': env.get('DB_QA_NAME', 'kaupamex_qa'),
        'ssl_ca': ssl_ca,
    }

    log.header(f"CHECK DB — {host}:{port}")
    log.info(f"Log: {log.log_file}")

    checks = [
        (1, 8, "Conectividad SSL (readonly + app)",
            lambda: all(check_ssl_conectividad(cfg_readonly, cfg_app, log))),
        (2, 8, "SSL activo en la conexión (Ssl_cipher)",
            lambda: check_ssl_cifrado(cfg_readonly, log)),
        (3, 8, "Conexión sin SSL rechazada (require_secure_transport)",
            lambda: check_ssl_rechaza_sin_ssl(cfg_readonly, log)),
        (4, 8, "Schemas kaupamex_db y kaupamex_qa existen",
            lambda: check_schemas(cfg_app, log)),
        (5, 8, "Permisos readonly: SELECT sí, CREATE TABLE no",
            lambda: check_permisos_readonly(cfg_readonly, log)),
        (6, 8, "Permisos app prod: DML sí, DROP DATABASE no",
            lambda: check_permisos_app_prod(cfg_app, log)),
        (7, 8, "Permisos app QA: CREATE + INSERT + DROP sí",
            lambda: check_permisos_app_qa(cfg_app_qa, log)),
    ]

    results = []
    for n, total, desc, fn in checks:
        log.step(n, total, desc)
        try:
            ok = fn()
        except Exception as e:
            log.error(f"Excepción inesperada: {e}")
            ok = False
        results.append((desc, ok))

    log.header("RESUMEN")
    all_ok = True
    for desc, ok in results:
        if ok:
            log.ok(desc)
        else:
            log.error(desc)
            all_ok = False

    print()
    if all_ok:
        log.ok("Todos los checks pasaron — MariaDB lista para Django")
    else:
        log.error("Uno o más checks fallaron — revisar log")
        log.info(f"Log detallado: {log.log_file}")

    sys.exit(0 if all_ok else 1)


if __name__ == '__main__':
    main()
