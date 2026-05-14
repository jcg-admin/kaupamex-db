#!/bin/bash
# =============================================================================
# scripts/verify.sh
# Verificación completa del entorno MariaDB de PracticaYoruba
# =============================================================================
# Comprueba en orden (7 checks):
#
#   1. Variables requeridas en .env
#   2. Herramientas CLI disponibles (mysql, mysqladmin)
#   3. MariaDB responde (socket Unix primero, luego TCP)
#   4. Schema practicayoruba_db existe y tiene django_migrations
#   5. Schema practicayoruba_qa existe y tiene django_migrations
#   6. Usuario Django tiene SELECT, INSERT, UPDATE, DELETE en practicayoruba_db
#   7. Usuario Django tiene SELECT, INSERT, UPDATE, DELETE en practicayoruba_qa
#
# Muestra resumen final con contadores OK / WARN / ERROR.
# Retorna exit code 0 si ERR=0, 1 si hay algún error.
#
# Uso:
#   bash scripts/verify.sh
#
# Variables del .env:
#   DB_NAME, DB_QA_NAME, DB_USER, DB_PASSWORD, DB_QA_USER, DB_QA_PASSWORD,
#   DB_HOST, DB_PORT
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/utils/logging.sh"
source "${PROJECT_ROOT}/utils/core.sh"
source "${PROJECT_ROOT}/utils/network.sh"
source "${PROJECT_ROOT}/utils/database.sh"

# =============================================================================
# Cargar .env
# =============================================================================
ENV_FILE="${PROJECT_ROOT}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo ""
    echo "  ERROR: Archivo .env no encontrado en ${PROJECT_ROOT}"
    echo "  Crea tu configuracion: cp .env.example .env"
    echo ""
    exit 1
fi
set -a; source "$ENV_FILE"; set +a

DB_NAME="${DB_NAME:-practicayoruba_db}"
DB_QA_NAME="${DB_QA_NAME:-practicayoruba_qa}"
DB_USER="${DB_USER:-django_user}"
DB_PASSWORD="${DB_PASSWORD:-django_pass}"
DB_QA_USER="${DB_QA_USER:-django_user}"
DB_QA_PASSWORD="${DB_QA_PASSWORD:-django_pass}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"

# =============================================================================
# Contadores OK / WARN / ERROR
# =============================================================================
_OK=0; _WARN=0; _ERR=0

ok()   { log_success "  [OK]   $1"; _OK=$(( _OK + 1 ));   }
warn() { log_warn    "  [WARN] $1"; _WARN=$(( _WARN + 1 )); }
fail() { log_error   "  [ERR]  $1"; _ERR=$(( _ERR + 1 ));  }

# =============================================================================
# Helper: ejecutar query con credenciales del usuario Django
# Intenta socket Unix primero, luego TCP.
# =============================================================================
_user_exec() {
    local user="$1" pass="$2" schema="$3"
    shift 3
    local sock=""
    for s in "${_MARIADB_SOCKETS[@]}"; do
        if [[ -S "$s" ]] && mysqladmin --socket="$s" ping --silent >/dev/null 2>&1; then
            sock="$s"
            break
        fi
    done
    if [[ -n "$sock" ]]; then
        mysql --socket="$sock" \
            -u "$user" -p"${pass}" \
            --batch --silent --skip-column-names \
            "$schema" "$@" 2>/dev/null
    else
        mysql -h "$DB_HOST" -P "$DB_PORT" \
            -u "$user" -p"${pass}" \
            --batch --silent --skip-column-names \
            "$schema" "$@" 2>/dev/null
    fi
}

# Helper: verificar si el usuario tiene un privilegio específico sobre un schema
_has_priv() {
    local user="$1" schema="$2" priv="$3"
    local count
    count=$(mysql -h "$DB_HOST" -P "$DB_PORT" \
        --batch --silent --skip-column-names \
        -e "SELECT COUNT(*) FROM information_schema.SCHEMA_PRIVILEGES
            WHERE GRANTEE LIKE \"'${user}'%\"
            AND TABLE_SCHEMA = '${schema}'
            AND PRIVILEGE_TYPE = '${priv}';" 2>/dev/null || echo "0")
    [[ "${count:-0}" -gt 0 ]]
}

# =============================================================================
# Variables requeridas en .env
# =============================================================================
check_env_vars() {
    log_header "Variables de entorno (.env)"

    local required=(
        "DB_NAME" "DB_USER" "DB_PASSWORD"
        "DB_QA_NAME" "DB_QA_USER" "DB_QA_PASSWORD"
        "DB_HOST" "DB_PORT"
    )

    for var in "${required[@]}"; do
        if [[ -n "${!var:-}" ]]; then
            ok "${var}=${!var}"
        else
            fail "${var} no configurado en .env"
        fi
    done
}

# =============================================================================
# Herramientas CLI
# =============================================================================
check_tools() {
    log_header "Herramientas CLI"

    local tools=(
        "mysql:cliente SQL MariaDB"
        "mysqladmin:health check MariaDB"
        "mysqldump:backup MariaDB"
    )

    for entry in "${tools[@]}"; do
        local cmd="${entry%%:*}"
        local desc="${entry##*:}"
        if command_exists "$cmd"; then
            ok "${cmd} disponible (${desc})"
        else
            fail "${cmd} no encontrado — instala: apt install mariadb-client"
        fi
    done
}

# =============================================================================
# MariaDB responde
# =============================================================================
check_mariadb_running() {
    log_header "MariaDB responde"

    # Intentar socket Unix primero (H-F3-002)
    for sock in "${_MARIADB_SOCKETS[@]}"; do
        if [[ -S "$sock" ]] && \
           mysqladmin --socket="$sock" ping --silent >/dev/null 2>&1; then
            ok "MariaDB activo via socket: ${sock}"
            return 0
        fi
    done

    # Fallback TCP
    if mariadb_is_running "$DB_HOST" "$DB_PORT"; then
        ok "MariaDB activo via TCP: ${DB_HOST}:${DB_PORT}"
        return 0
    fi

    fail "MariaDB no responde en ${DB_HOST}:${DB_PORT}"
    log_warn "  Arranca con: sudo service mariadb start"
    log_warn "  O sin systemd: sudo bash provisioners/mariadb/db_setup.sh"
}

# =============================================================================
# Schema practicayoruba_db existe y tiene django_migrations
# =============================================================================
check_schema_db() {
    log_header "Schema ${DB_NAME}: existencia y migraciones"

    if ! command_exists mysql; then
        warn "mysql CLI no disponible — check omitido"
        return
    fi

    # Verificar que el schema existe
    local schema_exists
    schema_exists=$(mysql -h "$DB_HOST" -P "$DB_PORT" \
        --batch --silent --skip-column-names \
        -e "SELECT COUNT(*) FROM information_schema.SCHEMATA
            WHERE SCHEMA_NAME = '${DB_NAME}';" 2>/dev/null || echo "0")

    if [[ "${schema_exists:-0}" -lt 1 ]]; then
        fail "Schema ${DB_NAME} no existe"
        log_error "  Crea el schema: sudo bash provisioners/mariadb/db_setup.sh"
        return
    fi
    ok "Schema ${DB_NAME} existe"

    # Verificar que django_migrations existe (migraciones aplicadas)
    local mig_exists
    mig_exists=$(mysql -h "$DB_HOST" -P "$DB_PORT" \
        --batch --silent --skip-column-names \
        -e "SELECT COUNT(*) FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = '${DB_NAME}'
            AND TABLE_NAME = 'django_migrations';" 2>/dev/null || echo "0")

    if [[ "${mig_exists:-0}" -gt 0 ]]; then
        local mig_count
        mig_count=$(mysql -h "$DB_HOST" -P "$DB_PORT" \
            --batch --silent --skip-column-names \
            -e "SELECT COUNT(*) FROM \`${DB_NAME}\`.django_migrations;" \
            2>/dev/null || echo "?")
        ok "django_migrations presente (${mig_count} migraciones aplicadas)"
    else
        warn "django_migrations no encontrada — ejecuta: python manage.py migrate"
    fi
}

# =============================================================================
# Schema practicayoruba_qa existe y tiene django_migrations
# =============================================================================
check_schema_qa() {
    log_header "Schema ${DB_QA_NAME}: existencia y migraciones"

    if ! command_exists mysql; then
        warn "mysql CLI no disponible — check omitido"
        return
    fi

    local schema_exists
    schema_exists=$(mysql -h "$DB_HOST" -P "$DB_PORT" \
        --batch --silent --skip-column-names \
        -e "SELECT COUNT(*) FROM information_schema.SCHEMATA
            WHERE SCHEMA_NAME = '${DB_QA_NAME}';" 2>/dev/null || echo "0")

    if [[ "${schema_exists:-0}" -lt 1 ]]; then
        fail "Schema ${DB_QA_NAME} no existe"
        log_error "  Crea el schema QA: sudo bash provisioners/mariadb/db_qa_setup.sh"
        return
    fi
    ok "Schema ${DB_QA_NAME} existe"

    local mig_exists
    mig_exists=$(mysql -h "$DB_HOST" -P "$DB_PORT" \
        --batch --silent --skip-column-names \
        -e "SELECT COUNT(*) FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = '${DB_QA_NAME}'
            AND TABLE_NAME = 'django_migrations';" 2>/dev/null || echo "0")

    if [[ "${mig_exists:-0}" -gt 0 ]]; then
        local mig_count
        mig_count=$(mysql -h "$DB_HOST" -P "$DB_PORT" \
            --batch --silent --skip-column-names \
            -e "SELECT COUNT(*) FROM \`${DB_QA_NAME}\`.django_migrations;" \
            2>/dev/null || echo "?")
        ok "django_migrations presente (${mig_count} migraciones aplicadas)"
    else
        warn "django_migrations no encontrada — ejecuta: DJANGO_SETTINGS_MODULE=config.settings.testing python manage.py migrate"
    fi
}

# =============================================================================
# Privilegios Django en practicayoruba_db
# =============================================================================
check_privs_db() {
    log_header "Privilegios ${DB_USER} en ${DB_NAME}"

    if ! command_exists mysql; then
        warn "mysql CLI no disponible — check omitido"
        return
    fi

    # Verificar conectividad primero
    local conn_result
    conn_result=$(_user_exec "$DB_USER" "$DB_PASSWORD" "$DB_NAME" \
        -e "SELECT CONCAT(DATABASE(), ' @ ', USER());" 2>/dev/null || echo "ERROR")

    if [[ "$conn_result" == "ERROR" ]] || [[ -z "$conn_result" ]]; then
        fail "No se puede conectar como ${DB_USER} a ${DB_NAME}"
        log_error "  Verifica credenciales en .env y ejecuta db_setup.sh"
        return
    fi
    ok "Conexion: ${conn_result}"

    # Verificar los cuatro verbos DML individualmente (H-F4-006)
    for priv in "SELECT" "INSERT" "UPDATE" "DELETE"; do
        if _has_priv "$DB_USER" "$DB_NAME" "$priv"; then
            ok "${priv} en ${DB_NAME}"
        else
            fail "Falta privilegio ${priv} para ${DB_USER} en ${DB_NAME}"
            log_error "  Ejecuta: sudo bash provisioners/mariadb/db_setup.sh"
        fi
    done
}

# =============================================================================
# Privilegios Django en practicayoruba_qa
# =============================================================================
check_privs_qa() {
    log_header "Privilegios ${DB_QA_USER} en ${DB_QA_NAME}"

    if ! command_exists mysql; then
        warn "mysql CLI no disponible — check omitido"
        return
    fi

    local conn_result
    conn_result=$(_user_exec "$DB_QA_USER" "$DB_QA_PASSWORD" "$DB_QA_NAME" \
        -e "SELECT CONCAT(DATABASE(), ' @ ', USER());" 2>/dev/null || echo "ERROR")

    if [[ "$conn_result" == "ERROR" ]] || [[ -z "$conn_result" ]]; then
        fail "No se puede conectar como ${DB_QA_USER} a ${DB_QA_NAME}"
        log_error "  Verifica credenciales en .env y ejecuta db_qa_setup.sh"
        return
    fi
    ok "Conexion: ${conn_result}"

    for priv in "SELECT" "INSERT" "UPDATE" "DELETE"; do
        if _has_priv "$DB_QA_USER" "$DB_QA_NAME" "$priv"; then
            ok "${priv} en ${DB_QA_NAME}"
        else
            fail "Falta privilegio ${priv} para ${DB_QA_USER} en ${DB_QA_NAME}"
            log_error "  Ejecuta: sudo bash provisioners/mariadb/db_qa_setup.sh"
        fi
    done
}

# =============================================================================
# MAIN
# =============================================================================
log_header "PracticaYoruba-db — Verificacion completa"
log_info "  DB prod : ${DB_NAME} @ ${DB_HOST}:${DB_PORT}"
log_info "  DB QA   : ${DB_QA_NAME} @ ${DB_HOST}:${DB_PORT}"
echo ""

check_env_vars;     echo ""
check_tools;        echo ""
check_mariadb_running; echo ""
check_schema_db;    echo ""
check_schema_qa;    echo ""
check_privs_db;     echo ""
check_privs_qa;     echo ""

# =============================================================================
# Resumen
# =============================================================================
log_separator 60 "="
echo ""
log_success  "OK:           ${_OK}"
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
