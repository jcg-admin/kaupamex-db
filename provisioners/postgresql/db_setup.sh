#!/bin/bash
# =============================================================================
# provisioners/postgresql/db_setup.sh
# Crea la base y el rol de aplicación en PostgreSQL
# =============================================================================
# IDEMPOTENTE: se puede ejecutar N veces sin efectos adversos.
#
# Uso:
#   sudo bash provisioners/postgresql/db_setup.sh          # base de producción
#   sudo bash provisioners/postgresql/db_setup.sh --qa     # base de QA
#
# Divergencia declarada respecto al provisioner de MariaDB
# ---------------------------------------------------------
#   MariaDB tiene DOS archivos —``db_setup.sh`` (208 líneas) y
#   ``db_qa_setup.sh`` (248)— que difieren en el prefijo de sus variables y
#   poco más. Aquí es UN archivo con ``--qa``: la lógica es idéntica y
#   duplicarla significa que un fix futuro haya que aplicarlo dos veces, que
#   es exactamente cómo divergen dos scripts gemelos.
#
#   No se toca el par de MariaDB: ya está probado y unificarlo es un refactor
#   con riesgo propio, no un efecto colateral de añadir PostgreSQL.
#
# Modelo de nombres — "schema" NO significa lo mismo en los dos motores
# ---------------------------------------------------------------------
#   | MariaDB                  | PostgreSQL (aquí)             |
#   |--------------------------|-------------------------------|
#   | schema ``kaupamex_db``   | **database** ``kaupamex_db``  |
#   | schema ``kaupamex_qa``   | **database** ``kaupamex_qa``  |
#   | usuario ``django_user``  | **rol** ``django_user`` LOGIN |
#
#   Un schema de PostgreSQL es un namespace DENTRO de una base. El
#   equivalente de nuestros dos schemas de MariaDB son dos **bases**, que es
#   además el modelo de la referencia: una base por instalación.
#
# Variables del .env:
#   DB_NAME         (default: kaupamex_db)      · DB_QA_NAME    (kaupamex_qa)
#   DB_USER         (default: django_user)      · DB_QA_USER    (django_user)
#   DB_PASSWORD     (OBLIGATORIA)               · DB_QA_PASSWORD (obligatoria en --qa)
#
#   ``DB_PASSWORD`` no lleva default a propósito — mismo criterio que
#   ``provisioners/mariadb/db_setup.sh:60``: un default de contraseña acaba
#   en producción.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../../utils/logging.sh
source "${PROJECT_ROOT}/utils/logging.sh"
# shellcheck source=../../utils/core.sh
source "${PROJECT_ROOT}/utils/core.sh"
# shellcheck source=../../utils/postgresql.sh
source "${PROJECT_ROOT}/utils/postgresql.sh"

ENV_FILE="${PROJECT_ROOT}/.env"
if [[ -f "$ENV_FILE" ]]; then
    # Fuente condicional: solo exporta lo que NO viene ya del entorno.
    # ``set -a; source`` pisaría las credenciales inyectadas por el caller
    # (``sudo env VAR=val``, CI/CD), que es exactamente al revés de 12-factor.
    # Copiado del provisioner de MariaDB, que ya lo tenía resuelto; escribirlo
    # con ``set -a`` fue una regresión frente al hermano. Ver H-DB-04.
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        [[ -n "${!key+x}" ]] && continue
        export "$key=$value"
    done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$ENV_FILE")
fi

IS_QA=false
[[ "${1:-}" == "--qa" ]] && IS_QA=true

if [[ "$IS_QA" == true ]]; then
    TARGET_DB="${DB_QA_NAME:-kaupamex_qa}"
    TARGET_USER="${DB_QA_USER:-django_user}"
    TARGET_PASSWORD="${DB_QA_PASSWORD:?DB_QA_PASSWORD must be set in environment or .env}"
    ETIQUETA="QA"
else
    TARGET_DB="${DB_NAME:-kaupamex_db}"
    TARGET_USER="${DB_USER:-django_user}"
    TARGET_PASSWORD="${DB_PASSWORD:?DB_PASSWORD must be set in environment or .env}"
    ETIQUETA="producción/desarrollo"
fi

log_header "Base de ${ETIQUETA} en PostgreSQL: ${TARGET_DB}"

# -----------------------------------------------------------------------------
# Pre-condiciones
# -----------------------------------------------------------------------------
require_command psql

if ! postgres_start; then
    log_fatal "PostgreSQL no responde. Ejecutar antes:
    sudo bash provisioners/postgresql/install.sh"
fi

if ! diagnostico="$(postgres_meets_minimum)"; then
    log_fatal "El servidor no satisface el mínimo de la referencia: ${diagnostico}"
fi
log_info "$diagnostico"

# -----------------------------------------------------------------------------
# _pg <sql>
#   Ejecuta SQL como el superusuario ``postgres`` por socket local (peer auth).
#   Se usa ``-v ON_ERROR_STOP=1`` para que un error SQL falle el script en vez
#   de seguir con estado a medias — MariaDB tiene el mismo cuidado y aquí
#   importa más, porque este script encadena varias sentencias.
# -----------------------------------------------------------------------------
_pg() {
    su postgres -c "psql -v ON_ERROR_STOP=1 -tAX -c \"$1\""
}

_pg_exists() {
    local sql="$1"
    [[ "$(su postgres -c "psql -tAX -c \"${sql}\"" 2>/dev/null | tr -d '[:space:]')" == "1" ]]
}

# -----------------------------------------------------------------------------
# Rol de aplicación
#   ``CREATE ROLE`` no admite ``IF NOT EXISTS`` (a diferencia de ``CREATE USER
#   IF NOT EXISTS`` de MariaDB), así que la idempotencia se construye: se
#   consulta ``pg_roles`` y se crea o se actualiza la contraseña.
# -----------------------------------------------------------------------------
#   ``CREATEDB`` es el equivalente PostgreSQL del grant ``company\_%`` de
#   MariaDB (T-091-01): lo que habilita el multi-DB-per-company, donde la
#   aplicación crea la base de cada empresa en caliente
#   (``api: service/db.create_empty_database``). Sin él, esa ruta muere con
#   "permission denied to create database".
#
#   PostgreSQL NO permite acotar el permiso a un patrón de nombre: ``CREATEDB``
#   es global o no es. Es una pérdida real de granularidad frente al
#   ``company\_%`` de MariaDB, y se acepta porque la alternativa —que el rol de
#   aplicación sea superusuario, o que un humano cree cada base a mano— es
#   peor. Ver H-DB-06.
log_step 1 6 "Rol ${TARGET_USER}"
if _pg_exists "SELECT 1 FROM pg_roles WHERE rolname = '${TARGET_USER}'"; then
    _pg "ALTER ROLE \\\"${TARGET_USER}\\\" WITH LOGIN CREATEDB PASSWORD '${TARGET_PASSWORD}'" >/dev/null
    log_success "Rol ya existía — contraseña y CREATEDB actualizados"
else
    _pg "CREATE ROLE \\\"${TARGET_USER}\\\" WITH LOGIN CREATEDB PASSWORD '${TARGET_PASSWORD}'" >/dev/null
    log_success "Rol creado (LOGIN CREATEDB)"
fi

# -----------------------------------------------------------------------------
# Base de datos
#   ``CREATE DATABASE`` tampoco admite ``IF NOT EXISTS``. Mismo patrón.
#
#   ``ENCODING 'UTF8'`` es el equivalente de ``utf8mb4`` de MariaDB: en
#   PostgreSQL UTF-8 es UTF-8 completo, sin el histórico de 3 bytes que
#   obligó a ``utf8mb4`` allá.
#
#   ``TEMPLATE template0`` es necesario para poder fijar encoding/locale
#   distintos de los de ``template1``; sin él, ``CREATE DATABASE`` los hereda
#   y rechaza el override.
# -----------------------------------------------------------------------------
log_step 2 6 "Base ${TARGET_DB}"
if _pg_exists "SELECT 1 FROM pg_database WHERE datname = '${TARGET_DB}'"; then
    log_success "Base ya existía — no se toca"
else
    _pg "CREATE DATABASE \\\"${TARGET_DB}\\\" OWNER \\\"${TARGET_USER}\\\" ENCODING 'UTF8' TEMPLATE template0" >/dev/null
    log_success "Base creada (owner ${TARGET_USER}, UTF8)"
fi

# -----------------------------------------------------------------------------
# Privilegios
#   El rol es OWNER de la base, así que tiene lo que necesita sobre ella. Lo
#   que NO hereda de ser owner es el permiso sobre el schema ``public`` desde
#   PostgreSQL 15: dejó de estar abierto a ``PUBLIC``, y sin este GRANT el
#   ORM falla al crear tablas con "permission denied for schema public".
#
#   Es la diferencia con MariaDB que más fácil pasa desapercibida, porque el
#   error aparece en la primera migración, no aquí.
# -----------------------------------------------------------------------------
log_step 3 6 "Privilegios sobre el schema public"
su postgres -c "psql -v ON_ERROR_STOP=1 -tAX -d '${TARGET_DB}' -c \
    \"GRANT ALL ON SCHEMA public TO \\\"${TARGET_USER}\\\"\"" >/dev/null
log_success "GRANT aplicado"

# -----------------------------------------------------------------------------
# Extensiones
#   Las mismas dos que la referencia instala al crear cada base:
#   ``odoo19c: odoo/service/db.py::_create_empty_database`` ejecuta
#   ``CREATE EXTENSION IF NOT EXISTS`` sobre ``unaccent`` y ``pg_trgm``.
#
#   Van AQUÍ y no sólo en el aprovisionamiento por empresa: las dos bases L0
#   (``kaupamex_db`` y ``kaupamex_qa``) las crea este script, así que sin este
#   paso quedaban sin extensiones mientras las bases por empresa sí las tenían
#   — la búsqueda por similitud habría funcionado por empresa y no en L0.
#   Detectado por ``scripts/verify_postgres.sh`` (H-DB-07).
#
#   Requiere superusuario: ``CREATE EXTENSION`` no lo puede el owner de la
#   base. Por eso corre como ``postgres`` y no como el rol de aplicación.
# -----------------------------------------------------------------------------
log_step 4 6 "Extensiones (unaccent, pg_trgm)"
for _ext in unaccent pg_trgm; do
    if su postgres -c "psql -v ON_ERROR_STOP=1 -tAX -d '${TARGET_DB}' -c \
        \"CREATE EXTENSION IF NOT EXISTS ${_ext}\"" >/dev/null 2>&1; then
        log_success "${_ext} instalada"
    else
        log_warn "${_ext} no se pudo instalar — ¿falta postgresql-contrib?"
    fi
done

# -----------------------------------------------------------------------------
# Autenticación por socket — pg_hba.conf
#   La convención del proyecto es conectar por socket Unix. En MariaDB eso
#   salía gratis: el usuario se autentica con contraseña venga por socket o
#   por TCP. En PostgreSQL NO: el pg_hba por defecto de Debian trae
#
#       local   all   all   peer
#
#   y ``peer`` exige que el usuario del SISTEMA operativo se llame igual que
#   el rol. Como la aplicación corre con otro usuario, la conexión por socket
#   falla con "Peer authentication failed for user" — mientras que la misma
#   credencial por TCP funciona, porque ahí el default sí es scram.
#
#   Se añade una regla de socket para ESTE rol, por encima de la genérica,
#   con el mismo método que ya usa el TCP local. No se toca la línea de
#   ``postgres``: su ``peer`` es lo que permite administrar sin contraseña.
#   Ver H-DB-05.
# -----------------------------------------------------------------------------
#   La mecánica vive en ``postgres_ensure_hba_socket`` (utils/postgresql.sh)
#   porque el mismo problema aplica a CUALQUIER rol que conecte por socket,
#   no sólo al de la aplicación — ver H-DB-08.
log_step 5 6 "Autenticación por socket para ${TARGET_USER}"
log_success "$(postgres_ensure_hba_socket "${TARGET_USER}")"

# -----------------------------------------------------------------------------
# Verificación — no se declara hecho sin leer el estado resultante
# -----------------------------------------------------------------------------
log_step 6 6 "Verificación"
_pg_exists "SELECT 1 FROM pg_database WHERE datname = '${TARGET_DB}'" \
    || log_fatal "La base ${TARGET_DB} no existe tras crearla"
_pg_exists "SELECT 1 FROM pg_roles WHERE rolname = '${TARGET_USER}' AND rolcanlogin" \
    || log_fatal "El rol ${TARGET_USER} no puede iniciar sesión"

log_success "Base de ${ETIQUETA} lista: ${TARGET_DB} (rol ${TARGET_USER})"
if [[ "$IS_QA" != true ]]; then
    log_info "Para la base de QA:  sudo bash provisioners/postgresql/db_setup.sh --qa"
fi
