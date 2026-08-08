#!/bin/bash
# =============================================================================
# scripts/verify_postgres.sh
# Verificación completa del entorno PostgreSQL — kaupamex-db
# =============================================================================
# Hermano de ``verify.sh`` (MariaDB) para el motor en uso (ADR-028). El
# conteo de checks NO se hardcodea: sale de ``grep -c '^check_'`` sobre este
# mismo archivo, así que agregar o quitar uno nunca desincroniza el header.
# Mismo mecanismo que el hermano (T-C1, cierre H-01/S-01).
#
# Qué se verifica, y por qué cada uno está aquí:
#
#   1. Variables requeridas en .env
#   2. Herramientas CLI (psql, pg_isready, pg_dump)
#   3. El servidor responde
#   4. **Mínimo efectivo 14** — Django 6 ABORTA la conexión por debajo,
#      no avisa (django/db/backends/postgresql/features.py:10). H-DB-03.
#   5. Base kaupamex_db existe y tiene django_migrations
#   6. Base kaupamex_qa existe y tiene django_migrations
#   7. Rol django_user: LOGIN + CREATEDB (CREATEDB es global, no admite
#      acotar por patrón de nombre como el GRANT de MariaDB — H-DB-06)
#   8. **El rol entra por socket** — el pg_hba de Debian asigna ``peer`` al
#      canal local, así que la contraseña que funciona por TCP falla por
#      socket. Es el check que atrapa H-DB-05, y no lo atrapa ningún otro:
#      un fallo de credenciales y uno de método de autenticación se ven
#      igual desde la aplicación.
#   9. Extensiones pg_trgm y unaccent en ambas bases
#
# Vocabulario: aquí se dice **base**, no *schema*. En PostgreSQL un schema
# es un namespace dentro de una base (el default es ``public``); los dos
# "schemas" de MariaDB son dos bases.
#
# Uso:
#   bash scripts/verify_postgres.sh
#
# Variables del .env: DB_NAME, DB_QA_NAME, DB_USER, DB_PASSWORD,
#                     DB_QA_USER, DB_QA_PASSWORD, DB_SOCKET, DB_HOST, DB_PORT
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/utils/logging.sh"
source "${PROJECT_ROOT}/utils/core.sh"
source "${PROJECT_ROOT}/utils/postgresql.sh"

# =============================================================================
# Cargar .env — sin pisar lo que ya venga del entorno
# =============================================================================
# Precedencia: entorno > .env. Es la misma corrección de H-DB-04, donde un
# ``set -a; source`` hacía que ``DB_NAME=x bash script`` creara la base con
# el nombre del .env en vez del inyectado.
ENV_FILE="${PROJECT_ROOT}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo ""
    echo "  ERROR: Archivo .env no encontrado en ${PROJECT_ROOT}"
    echo "  Crea tu configuracion: cp .env.example .env"
    echo ""
    exit 1
fi
while IFS='=' read -r key value; do
    [[ "$key" =~ ^[[:space:]]*# || -z "${key// }" ]] && continue
    key="${key// }"
    [[ -n "${!key+x}" ]] && continue      # el entorno gana
    export "$key=${value}"
done < "$ENV_FILE"

DB_NAME="${DB_NAME:-kaupamex_db}"
DB_QA_NAME="${DB_QA_NAME:-kaupamex_qa}"
DB_USER="${DB_USER:-django_user}"
DB_PASSWORD="${DB_PASSWORD:-django_pass}"
DB_QA_USER="${DB_QA_USER:-django_user}"
DB_QA_PASSWORD="${DB_QA_PASSWORD:-django_pass}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"

# =============================================================================
# Contadores OK / WARN / ERROR
# =============================================================================
_OK=0; _WARN=0; _ERR=0

ok()   { log_success "  [OK]   $1"; _OK=$(( _OK + 1 ));   }
warn() { log_warn    "  [WARN] $1"; _WARN=$(( _WARN + 1 )); }
fail() { log_error   "  [ERR]  $1"; _ERR=$(( _ERR + 1 ));  }

PSQL="$(postgres_client_bin)"

# -----------------------------------------------------------------------------
# _super_exec <sql> [base]
#   Ejecuta como el superusuario del motor (rol ``postgres``, por socket con
#   ``peer``). Cadena vacía si no se puede.
# -----------------------------------------------------------------------------
_super_exec() {
    local sql="$1" base="${2:-postgres}"
    [[ -z "$PSQL" ]] && { echo ""; return 1; }
    su postgres -c "${PSQL} -tAX -d '${base}' -c \"${sql}\"" 2>/dev/null \
        | tr -d '\r'
}

# -----------------------------------------------------------------------------
# _app_exec <user> <pass> <base> <sql>
#   Ejecuta como el rol de aplicación POR SOCKET. Es la ruta que usa Django
#   (``HOST`` = directorio del socket), no una aproximación por TCP.
# -----------------------------------------------------------------------------
_app_exec() {
    local user="$1" pass="$2" base="$3" sql="$4"
    local sock
    sock="$(postgres_socket_dir)"
    [[ -z "$PSQL" || -z "$sock" ]] && { echo ""; return 1; }
    PGPASSWORD="$pass" ${PSQL} -h "$sock" -p "$DB_PORT" -U "$user" \
        -d "$base" -tAX -c "$sql" 2>/dev/null | tr -d '\r'
}

# =============================================================================
# 1. Variables requeridas en .env
# =============================================================================
check_env_vars() {
    log_header "PASO: Variables de entorno (.env)"
    local required=(DB_NAME DB_QA_NAME DB_USER DB_PASSWORD DB_PORT)
    local v
    for v in "${required[@]}"; do
        if [[ -n "${!v:-}" ]]; then
            ok "${v} definida"
        else
            fail "${v} no definida en .env"
        fi
    done
    if [[ -n "${DB_SOCKET:-}" ]]; then
        ok "DB_SOCKET=${DB_SOCKET} (en libpq el socket ES el HOST)"
    else
        warn "DB_SOCKET vacía — la app conectará por TCP ${DB_HOST}:${DB_PORT}"
    fi
}

# =============================================================================
# 2. Herramientas CLI
# =============================================================================
check_tools() {
    log_header "PASO: Herramientas CLI de PostgreSQL"
    local t
    for t in psql pg_isready pg_dump; do
        if command -v "$t" &>/dev/null; then
            ok "${t} disponible"
        else
            fail "${t} no encontrado — instala postgresql-client"
        fi
    done
    # Los wrappers del distro, que son la interfaz real de operación.
    if command -v pg_ctlcluster &>/dev/null; then
        ok "pg_ctlcluster disponible (Debian opera por cluster)"
    else
        warn "pg_ctlcluster no está — servidor no instalado localmente"
    fi
}

# =============================================================================
# 3. El servidor responde
# =============================================================================
check_server_running() {
    log_header "PASO: El servidor responde"
    if postgres_is_running; then
        local sock
        sock="$(postgres_socket_dir)"
        ok "PostgreSQL responde${sock:+ (socket: ${sock})}"
    else
        fail "PostgreSQL no responde"
        log_error "  Arráncalo: bash scripts/start_postgres.sh"
    fi
}

# =============================================================================
# 4. Mínimo efectivo de versión (GATE — H-DB-03)
# =============================================================================
check_minimum_version() {
    log_header "PASO: Versión mínima efectiva (${POSTGRES_MIN_MAJOR})"
    local diag
    if diag="$(postgres_meets_minimum)"; then
        ok "$diag"
    else
        fail "$diag"
        log_error "  Django 6 aborta la conexión por debajo del mínimo,"
        log_error "  no avisa (postgresql/features.py:10)"
    fi
}

# =============================================================================
# 5. Base de producción/desarrollo
# =============================================================================
check_base_db() {
    log_header "PASO: Base ${DB_NAME}: existencia y migraciones"
    _check_base "$DB_NAME"
}

# =============================================================================
# 6. Base de tests
# =============================================================================
check_base_qa() {
    log_header "PASO: Base ${DB_QA_NAME}: existencia y migraciones"
    _check_base "$DB_QA_NAME"
}

_check_base() {
    local base="$1"
    if [[ -z "$PSQL" ]]; then
        warn "psql no disponible — check omitido"
        return
    fi
    local exists
    exists="$(_super_exec "SELECT 1 FROM pg_database WHERE datname = '${base}'")"
    if [[ "${exists:-}" != "1" ]]; then
        fail "Base ${base} no existe"
        log_error "  Créala: sudo bash provisioners/postgresql/db_setup.sh"
        return
    fi
    ok "Base ${base} existe"

    local mig
    mig="$(_super_exec "SELECT to_regclass('public.django_migrations')" "$base")"
    if [[ -n "${mig:-}" ]]; then
        local n
        n="$(_super_exec "SELECT count(*) FROM public.django_migrations" "$base")"
        ok "django_migrations presente (${n:-?} migraciones aplicadas)"
    else
        warn "django_migrations no encontrada — ejecuta: manage.py migrate"
    fi
}

# =============================================================================
# 7. Atributos del rol de aplicación
# =============================================================================
check_rol_atributos() {
    log_header "PASO: Rol ${DB_USER}: LOGIN y CREATEDB"
    if [[ -z "$PSQL" ]]; then
        warn "psql no disponible — check omitido"
        return
    fi
    local row
    row="$(_super_exec "SELECT rolcanlogin, rolcreatedb FROM pg_roles \
                        WHERE rolname = '${DB_USER}'")"
    if [[ -z "${row:-}" ]]; then
        fail "El rol ${DB_USER} no existe"
        log_error "  Créalo: sudo bash provisioners/postgresql/db_setup.sh"
        return
    fi
    local canlogin creatdb
    IFS='|' read -r canlogin creatdb <<< "$row"
    [[ "$canlogin" == "t" ]] && ok "${DB_USER} tiene LOGIN" \
                             || fail "${DB_USER} NO tiene LOGIN"
    if [[ "$creatdb" == "t" ]]; then
        ok "${DB_USER} tiene CREATEDB (bases por empresa)"
    else
        fail "${DB_USER} NO tiene CREATEDB — el aprovisionamiento por empresa fallará"
        log_error "  'permission denied to create database' (H-DB-06)"
    fi
}

# =============================================================================
# 8. El rol entra POR SOCKET (atrapa H-DB-05)
# =============================================================================
check_socket_auth() {
    log_header "PASO: ${DB_USER} autentica por socket (pg_hba)"
    local sock
    sock="$(postgres_socket_dir)"
    if [[ -z "$sock" ]]; then
        warn "No hay socket activo — check omitido"
        return
    fi
    local base
    for base in "$DB_NAME" "$DB_QA_NAME"; do
        local pass="$DB_PASSWORD"
        [[ "$base" == "$DB_QA_NAME" ]] && pass="$DB_QA_PASSWORD"
        if [[ "$(_app_exec "$DB_USER" "$pass" "$base" 'SELECT 1')" == "1" ]]; then
            ok "${DB_USER} entra a ${base} por ${sock}"
        else
            fail "${DB_USER} NO entra a ${base} por socket"
            log_error "  Suele ser 'Peer authentication failed': el pg_hba de"
            log_error "  Debian asigna 'peer' al canal local. La regla del rol"
            log_error "  va POR ENCIMA de la genérica (H-DB-05)."
            log_error "  Corrige: sudo bash provisioners/postgresql/db_setup.sh"
        fi
    done
}

# =============================================================================
# 9. Extensiones que la referencia instala al crear cada base
# =============================================================================
check_extensiones() {
    log_header "PASO: Extensiones pg_trgm y unaccent"
    if [[ -z "$PSQL" ]]; then
        warn "psql no disponible — check omitido"
        return
    fi
    local base ext
    for base in "$DB_NAME" "$DB_QA_NAME"; do
        for ext in pg_trgm unaccent; do
            local found
            found="$(_super_exec \
                "SELECT 1 FROM pg_extension WHERE extname = '${ext}'" "$base")"
            if [[ "${found:-}" == "1" ]]; then
                ok "${ext} instalada en ${base}"
            else
                warn "${ext} ausente en ${base}"
                log_warn "    Instálala: sudo bash provisioners/postgresql/db_setup.sh"
                log_warn "    (las bases por empresa las reciben de create_empty_database;"
                log_warn "     estas dos son L0 y las crea el provisioner — H-DB-07)"
            fi
        done
    done
}

# =============================================================================
# Ejecución
# =============================================================================
TOTAL_CHECKS=$(grep -cE '^check_[a-z_]+\(\)' "$0")

log_header "kaupamex-db — Verificación PostgreSQL (${TOTAL_CHECKS} checks)"
echo ""

check_env_vars;          echo ""
check_tools;             echo ""
check_server_running;    echo ""
check_minimum_version;   echo ""
check_base_db;           echo ""
check_base_qa;           echo ""
check_rol_atributos;     echo ""
check_socket_auth;       echo ""
check_extensiones;       echo ""

log_separator 60 "="
echo ""
log_success "OK:           ${_OK}"
[[ $_WARN -gt 0 ]] && log_warn "Advertencias: ${_WARN}" \
                   || log_success "Advertencias: ${_WARN}"
[[ $_ERR  -gt 0 ]] && log_error  "Errores:      ${_ERR}" \
                   || log_success "Errores:      ${_ERR}"
echo ""

if [[ $_ERR -eq 0 && $_WARN -eq 0 ]]; then
    log_success "Entorno listo."
elif [[ $_ERR -eq 0 ]]; then
    log_warn "Entorno funcional con advertencias — revisa los items marcados."
else
    log_error "Entorno incompleto — corrige los errores antes de continuar."
fi

exit $(( _ERR > 0 ? 1 : 0 ))
