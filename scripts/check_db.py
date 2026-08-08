#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
scripts/check_db.py
Verificación Python de conectividad y privilegios MariaDB — PracticaYoruba-db
===============================================================================
Descripción:
    Verifica que MariaDB está accesible y que el usuario Django tiene los
    privilegios necesarios para operar la aplicación.

Checks:
    1. Conectividad a kaupamex_db como django_user
    2. Conectividad a kaupamex_qa como django_user (o DB_QA_USER)
    3. django_migrations existe en kaupamex_db (migraciones aplicadas)
    4. res_users existe en kaupamex_db (credencial, Odoo res.users)
    5. Privilegios DML en kaupamex_db (SELECT, INSERT, DELETE)
    6. Privilegios DML en kaupamex_qa (SELECT, INSERT, DELETE)

Adaptaciones respecto a IACT-db/test/check_db_connections.py:
    - Solo MariaDB (sin PostgreSQL) — H-F4-003
    - Usa mysqlclient (MySQLdb) en lugar de mysql.connector — H-F4-003
    - Usa python-dotenv (load_dotenv) en lugar de parser manual — H-F4-004
    - Verifica res_users en lugar de auth_user (H-F4-005). El nombre cambio
      de users_user a res_users al disolverse el addon users en base: la
      referencia no tiene un addon users, declara res.users en el nucleo
      (odoo19c: odoo/addons/base/models/res_users.py). Ver H-DB-01.
      (PracticaYoruba usa AUTH_USER_MODEL = 'users.User')
    - Salida con colores ANSI sin depender de colorama

Requisitos:
    pip install -r requirements.txt  (desde la raíz del repositorio)

    Prerequisito del sistema (Ubuntu):
      sudo apt-get install libmysqlclient-dev

Uso:
    python3 scripts/check_db.py
"""

import sys
import os
import textwrap
from pathlib import Path

# =============================================================================
# Verificar dependencias antes de importar
# =============================================================================
_REQUIRED = {
    "MySQLdb": "mysqlclient",
    "dotenv":  "python-dotenv",
}

for _mod, _pkg in _REQUIRED.items():
    try:
        __import__(_mod)
    except ImportError:
        print(f"\n  ERROR: Modulo requerido no encontrado: {_mod}")
        print(f"  Instala las dependencias del repositorio:")
        print(f"    pip install -r requirements.txt")
        print(f"  (Paquete que provee el módulo: {_pkg})\n")
        sys.exit(1)

import MySQLdb
from dotenv import load_dotenv

# =============================================================================
# Colores ANSI (sin colorama — terminales modernas los soportan)
# =============================================================================
_IS_TTY = sys.stdout.isatty()

def _c(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _IS_TTY else text

def _green(t):  return _c("0;32", t)
def _yellow(t): return _c("0;33", t)
def _red(t):    return _c("0;31", t)
def _cyan(t):   return _c("0;36", t)
def _bold(t):   return _c("1", t)

# =============================================================================
# Logger simple
# =============================================================================
class Logger:
    """Logging de consola con colores y contadores OK/WARN/ERR."""

    def __init__(self):
        self.ok_count   = 0
        self.warn_count = 0
        self.err_count  = 0

    def header(self, msg: str) -> None:
        print(f"\n{_bold(_cyan('>>> ' + msg))}\n")

    def ok(self, msg: str) -> None:
        print(f"  {_green('[OK]  ')} {msg}")
        self.ok_count += 1

    def warn(self, msg: str) -> None:
        print(f"  {_yellow('[WARN]')} {msg}", file=sys.stderr)
        self.warn_count += 1

    def err(self, msg: str) -> None:
        print(f"  {_red('[ERR] ')} {msg}", file=sys.stderr)
        self.err_count += 1

    def info(self, msg: str) -> None:
        print(f"  {'--':6} {msg}")

    def summary(self) -> None:
        print("\n" + "=" * 60)
        print(f"  {_green('OK:          ')} {self.ok_count}")
        if self.warn_count:
            print(f"  {_yellow('Advertencias:')} {self.warn_count}")
        else:
            print(f"  {_green('Advertencias:')} {self.warn_count}")
        if self.err_count:
            print(f"  {_red('Errores:     ')} {self.err_count}")
        else:
            print(f"  {_green('Errores:     ')} {self.err_count}")
        print()


log = Logger()

# =============================================================================
# Cargar .env
# =============================================================================
_SCRIPT_DIR = Path(__file__).resolve().parent
_PROJECT_ROOT = _SCRIPT_DIR.parent
_ENV_FILE = _PROJECT_ROOT / ".env"

if not _ENV_FILE.exists():
    print(f"\n  {_red('ERROR')} Archivo .env no encontrado en {_PROJECT_ROOT}")
    print(f"  Crea tu configuracion: cp .env.example .env\n")
    sys.exit(1)

load_dotenv(dotenv_path=_ENV_FILE)

DB_NAME     = os.getenv("DB_NAME",         "kaupamex_db")
DB_USER     = os.getenv("DB_USER",         "django_user")
DB_PASSWORD = os.getenv("DB_PASSWORD",     "django_pass")
DB_HOST     = os.getenv("DB_HOST",         "127.0.0.1")
DB_PORT     = int(os.getenv("DB_PORT",     "3306"))

DB_QA_NAME     = os.getenv("DB_QA_NAME",     "kaupamex_qa")
DB_QA_USER     = os.getenv("DB_QA_USER",     "django_user")
DB_QA_PASSWORD = os.getenv("DB_QA_PASSWORD", "django_pass")
DB_QA_HOST     = os.getenv("DB_QA_HOST",     DB_HOST)
DB_QA_PORT     = int(os.getenv("DB_QA_PORT", str(DB_PORT)))


# =============================================================================
# Helpers de conexión
# =============================================================================

def _connect(host: str, port: int, user: str, password: str, db: str):
    """
    Retorna una conexion MySQLdb o lanza excepcion.
    Timeout de 5 segundos para no bloquear en entornos sin MariaDB.
    """
    return MySQLdb.connect(
        host=host,
        port=port,
        user=user,
        passwd=password,
        db=db,
        connect_timeout=5,
        charset="utf8mb4",
    )


def _query_one(conn, sql: str, params=None):
    """Ejecuta una query y retorna el primer campo de la primera fila, o None."""
    with conn.cursor() as cur:
        cur.execute(sql, params)
        row = cur.fetchone()
        return row[0] if row else None


def _table_exists(conn, schema: str, table: str) -> bool:
    """Retorna True si la tabla existe en information_schema."""
    result = _query_one(
        conn,
        "SELECT COUNT(*) FROM information_schema.TABLES "
        "WHERE TABLE_SCHEMA = %s AND TABLE_NAME = %s",
        (schema, table),
    )
    return int(result or 0) > 0


def _check_dml_privs(
    host: str, port: int,
    user: str, password: str,
    schema: str,
) -> dict[str, bool]:
    """
    Verifica privilegios DML creando una tabla temporal, ejecutando
    SELECT / INSERT / DELETE y luego borrando la tabla.
    Retorna un dict {priv: bool}.
    """
    results = {"SELECT": False, "INSERT": False, "DELETE": False}
    tmp_table = "_py_verify_tmp"
    conn = None

    try:
        conn = _connect(host, port, user, password, schema)
        with conn.cursor() as cur:
            # Crear tabla temporal de prueba
            cur.execute(
                f"CREATE TABLE IF NOT EXISTS `{tmp_table}` "
                "(id INT PRIMARY KEY AUTO_INCREMENT, val VARCHAR(10))"
            )
            conn.commit()

            # INSERT
            try:
                cur.execute(f"INSERT INTO `{tmp_table}` (val) VALUES ('verify')")
                conn.commit()
                results["INSERT"] = True
            except MySQLdb.OperationalError:
                conn.rollback()

            # SELECT
            try:
                cur.execute(f"SELECT COUNT(*) FROM `{tmp_table}`")
                cur.fetchone()
                results["SELECT"] = True
            except MySQLdb.OperationalError:
                pass

            # DELETE
            try:
                cur.execute(f"DELETE FROM `{tmp_table}`")
                conn.commit()
                results["DELETE"] = True
            except MySQLdb.OperationalError:
                conn.rollback()

            # Limpiar tabla temporal
            try:
                cur.execute(f"DROP TABLE IF EXISTS `{tmp_table}`")
                conn.commit()
            except MySQLdb.OperationalError:
                pass

    except MySQLdb.Error:
        pass
    finally:
        if conn:
            conn.close()

    return results


# =============================================================================
# Conectividad a kaupamex_db
# =============================================================================
def check_connectivity_db() -> bool:
    log.header(f"PASO: Conectividad a {DB_NAME}")
    try:
        conn = _connect(DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME)
        version = _query_one(conn, "SELECT VERSION()")
        db_at_user = _query_one(conn, "SELECT CONCAT(DATABASE(), ' @ ', USER())")
        conn.close()
        log.ok(f"Conexion OK: {db_at_user}")
        log.info(f"Servidor: MariaDB {version}")

        # Validar que la versión es 11.8.x (ADR-009)
        if version and "MariaDB" in str(version):
            parts = str(version).split("-")[0].split(".")
            try:
                major, minor = int(parts[0]), int(parts[1])
                if major == 11 and minor == 8:
                    log.ok(f"Version correcta: {version} (ADR-009)")
                else:
                    log.warn(
                        f"Version {version} — se requiere 11.8.x (ADR-009). "
                        f"Migra con: sudo bash provisioners/mariadb/install.sh"
                    )
            except (ValueError, IndexError):
                log.warn(f"No se pudo parsear la version: {version}")
        else:
            log.warn(
                f"El motor no parece ser MariaDB: {version}. "
                f"Se requiere MariaDB 11.8.x (ADR-009)"
            )

        return True
    except MySQLdb.OperationalError as e:
        log.err(f"No se pudo conectar a {DB_NAME} como {DB_USER}: {e}")
        log.err(f"  Verifica credenciales en .env y ejecuta db_setup.sh")
        return False


# =============================================================================
# Conectividad a kaupamex_qa
# =============================================================================
def check_connectivity_qa() -> bool:
    log.header(f"PASO: Conectividad a {DB_QA_NAME}")
    try:
        conn = _connect(DB_QA_HOST, DB_QA_PORT, DB_QA_USER, DB_QA_PASSWORD, DB_QA_NAME)
        db_at_user = _query_one(conn, "SELECT CONCAT(DATABASE(), ' @ ', USER())")
        conn.close()
        log.ok(f"Conexion OK: {db_at_user}")
        return True
    except MySQLdb.OperationalError as e:
        log.err(f"No se pudo conectar a {DB_QA_NAME} como {DB_QA_USER}: {e}")
        log.err(f"  Verifica credenciales en .env y ejecuta db_qa_setup.sh")
        return False


# =============================================================================
# django_migrations en kaupamex_db
# =============================================================================
def check_migrations_db() -> None:
    log.header(f"PASO: Migraciones en {DB_NAME}")
    try:
        conn = _connect(DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME)

        if _table_exists(conn, DB_NAME, "django_migrations"):
            count = _query_one(conn, f"SELECT COUNT(*) FROM `{DB_NAME}`.django_migrations")
            log.ok(f"django_migrations presente ({count} migraciones aplicadas)")
        else:
            log.warn("django_migrations no encontrada")
            log.info("  Ejecuta: python manage.py migrate")

        conn.close()
    except MySQLdb.OperationalError as e:
        log.warn(f"No se pudo verificar migraciones: {e}")


# =============================================================================
# res_users en kaupamex_db (H-F4-005)
# =============================================================================
def check_users_table() -> None:
    log.header(f"PASO: Tabla res_users en {DB_NAME}")
    log.info("  AUTH_USER_MODEL = 'base.ResUsers' — tabla: res_users")
    try:
        conn = _connect(DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME)

        if _table_exists(conn, DB_NAME, "res_users"):
            count = _query_one(conn, f"SELECT COUNT(*) FROM `{DB_NAME}`.res_users")
            log.ok(f"res_users presente ({count} usuarios registrados)")
        else:
            log.warn("res_users no encontrada — ejecuta: python manage.py migrate base")

        conn.close()
    except MySQLdb.OperationalError as e:
        log.warn(f"No se pudo verificar res_users: {e}")


# =============================================================================
# Tablas de aplicacion criticas en kaupamex_db (H-CICLO66-10)
#
# django_migrations puede existir aunque las migraciones hayan fallado
# a mitad de camino, dejando tablas de negocio ausentes.  Este check
# verifica que las tablas mas criticas esten presentes para detectar
# migraciones parciales antes de arrancar la aplicacion.
# =============================================================================
# Nombres verificados contra el schema real (SHOW TABLES) tras la adaptacion
# a las familias de la referencia: el carrito ya no es una tabla propia — es
# una SaleOrder en estado draft (odoo19c: addons/sale), asi que cart_cart y
# orders_* desaparecieron. payments_* conserva su nombre fisico aunque el
# addon se llame payment, igual que settings_sitesettings. Ver H-DB-01.
_REQUIRED_TABLES = [
    "sale_order",
    "sale_order_line",
    "payments_payment",
    "product_product",
    "product_template",
]


def check_required_tables() -> None:
    log.header(f"PASO: Tablas de aplicacion en {DB_NAME}")
    log.info("  Verifica tablas criticas ausentes tras migraciones parciales")
    try:
        conn = _connect(DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME)
        for table in _REQUIRED_TABLES:
            if _table_exists(conn, DB_NAME, table):
                log.ok(f"{table} presente")
            else:
                log.err(
                    f"{table} no encontrada — migracion incompleta. "
                    f"Ejecuta: python manage.py migrate"
                )
        conn.close()
    except MySQLdb.OperationalError as e:
        log.warn(f"No se pudo verificar tablas de aplicacion: {e}")


# =============================================================================
# Privilegios DML en kaupamex_db
# =============================================================================
def check_privs_db() -> None:
    log.header(f"PASO: Privilegios DML en {DB_NAME}")
    privs = _check_dml_privs(DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME)

    for priv, ok_val in privs.items():
        if ok_val:
            log.ok(f"{priv} en {DB_NAME}")
        else:
            log.err(f"Falta privilegio {priv} para {DB_USER} en {DB_NAME}")
            log.info("  Ejecuta: sudo bash provisioners/mariadb/db_setup.sh")


# =============================================================================
# Privilegios DML en kaupamex_qa
# =============================================================================
def check_privs_qa() -> None:
    log.header(f"PASO: Privilegios DML en {DB_QA_NAME}")
    privs = _check_dml_privs(
        DB_QA_HOST, DB_QA_PORT, DB_QA_USER, DB_QA_PASSWORD, DB_QA_NAME
    )

    for priv, ok_val in privs.items():
        if ok_val:
            log.ok(f"{priv} en {DB_QA_NAME}")
        else:
            log.err(f"Falta privilegio {priv} para {DB_QA_USER} en {DB_QA_NAME}")
            log.info("  Ejecuta: sudo bash provisioners/mariadb/db_qa_setup.sh")


# =============================================================================
# MAIN
# =============================================================================
def _count_checks() -> int:
    """Cuenta dinamicamente las funciones publicas check_*().

    Mismo patron que verify.sh (T-C1): la unica fuente de verdad del
    numero de checks es la introspeccion del modulo. Si en el futuro
    se agrega o quita una funcion check_*(), el header del run se
    actualiza solo y la documentacion no queda desincronizada.
    Cierra DC-03 de iniciativa resolver-problemas-db-pendientes.
    """
    import inspect
    module = sys.modules[__name__]
    return sum(
        1 for name, obj in inspect.getmembers(module, inspect.isfunction)
        if name.startswith("check_") and not name.startswith("_")
    )


def main() -> None:
    n = _count_checks()
    print(_bold(_cyan(f"\n>>> PracticaYoruba-db — Verificacion Python ({n} checks)\n")))
    print(f"  DB prod : {DB_NAME} @ {DB_HOST}:{DB_PORT}  ({DB_USER})")
    print(f"  DB QA   : {DB_QA_NAME} @ {DB_QA_HOST}:{DB_QA_PORT}  ({DB_QA_USER})")

    db_ok = check_connectivity_db()
    qa_ok = check_connectivity_qa()

    if db_ok:
        check_migrations_db()
        check_users_table()
        check_required_tables()
        check_privs_db()
    else:
        log.warn("Migraciones, res_users, tablas y privilegios de DB omitidos — sin conexion a kaupamex_db")

    if qa_ok:
        check_privs_qa()
    else:
        log.warn("Privilegios QA omitidos — sin conexion a kaupamex_qa")

    log.summary()

    if log.err_count == 0 and log.warn_count == 0:
        print(_green("  Entorno listo.\n"))
    elif log.err_count == 0:
        print(_yellow("  Entorno funcional con advertencias.\n"))
    else:
        print(_red("  Entorno incompleto — corrige los errores.\n"))

    sys.exit(0 if log.err_count == 0 else 1)


if __name__ == "__main__":
    main()
