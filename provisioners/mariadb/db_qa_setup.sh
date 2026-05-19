#!/bin/bash
# =============================================================================
# provisioners/mariadb/db_qa_setup.sh
# Crea el schema de QA (tests) en MariaDB
# =============================================================================
# IDEMPOTENTE. Schema completamente separado del de produccion.
#
# Uso:
#   sudo bash provisioners/mariadb/db_qa_setup.sh
#   # En contenedores sin sudo (MariaDB ya accesible como root sin pass):
#   bash provisioners/mariadb/db_qa_setup.sh
#
# Variables leidas desde .env en la raiz del repositorio (con defaults):
#   DB_QA_NAME      (default: practicayoruba_qa)
#   DB_QA_USER      (default: django_user)
#   DB_QA_PASSWORD  (default: django_pass)
#   DB_QA_HOST      (default: 127.0.0.1)
#   DB_QA_PORT      (default: 3306)
#
# Adaptaciones respecto a PracticaYoruba-api/scripts/provisioners/mysql/:
#   - PROJECT_ROOT: dos niveles arriba (no tres) — H-F1-002
#   - source paths: ${PROJECT_ROOT}/utils/ (no scripts/utils/) — H-F3-003
#   - ENV_FILE: ${PROJECT_ROOT}/.env (no practicayoruba/.env) — H-F1-002
#   - mysql_is_running/mysql_start → mariadb_is_running/mariadb_start — H-F2-004
#   - _my_exec renombrado a _db_exec y usa _MARIADB_SOCKETS — H-F3-002
#   - repair_system_tables eliminado: mysql.proc no aplica a MariaDB 11.8 — H-F2-005
#   - Mensajes de log: MySQL → MariaDB
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${PROJECT_ROOT}/utils/logging.sh"
source "${PROJECT_ROOT}/utils/network.sh"
source "${PROJECT_ROOT}/utils/database.sh"

ENV_FILE="${PROJECT_ROOT}/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
fi

DB_NAME="${DB_QA_NAME:-practicayoruba_qa}"
DB_USER="${DB_QA_USER:-django_user}"
DB_PASSWORD="${DB_QA_PASSWORD:-django_pass}"
DB_HOST="${DB_QA_HOST:-127.0.0.1}"
DB_PORT="${DB_QA_PORT:-3306}"

# -----------------------------------------------------------------------------
# _db_exec [args...]
#   Ejecuta un comando mysql como administrador del servidor.
#   Intenta socket Unix primero (de _MARIADB_SOCKETS), luego TCP.
# -----------------------------------------------------------------------------
_db_exec() {
    local sock=""
    for s in "${_MARIADB_SOCKETS[@]}"; do
        if [[ -S "$s" ]] && mysqladmin --socket="$s" ping --silent >/dev/null 2>&1; then
            sock="$s"
            break
        fi
    done
    if [[ -n "$sock" ]]; then
        mysql --socket="$sock" --batch "$@" 2>&1
    else
        mysql -h "$DB_HOST" -P "$DB_PORT" --batch "$@" 2>&1
    fi
}

_db_exec_quiet() { _db_exec --silent --skip-column-names "$@" 2>/dev/null; }

# =============================================================================
check_prerequisites() {
    log_header "PASO: Verificando prerequisitos"

    command -v mysql &>/dev/null || {
        log_fatal "mysql client no encontrado. Instala: apt install mariadb-client"
        exit 1
    }

    if ! mariadb_is_running "$DB_HOST" "$DB_PORT"; then
        log_warn "MariaDB no responde — intentando arranque automatico"
        mariadb_start || {
            log_fatal "MariaDB no disponible en ${DB_HOST}:${DB_PORT}"
            log_error "Arranque manual:"
            log_error "  sudo service mariadb start"
            log_error "  # o sin systemd:"
            log_error "  sudo bash provisioners/mariadb/db_qa_setup.sh"
            exit 1
        }
    fi

    log_success "MariaDB activo"
}

# =============================================================================
create_database() {
    log_header "PASO: Creando schema QA: ${DB_NAME}"

    local exists
    exists=$(_db_exec_quiet -e \
        "SELECT COUNT(*) FROM information_schema.SCHEMATA
         WHERE SCHEMA_NAME = '${DB_NAME}';" || echo "0")
    # MariaDB 11.8 imprime un aviso de deprecacion de 'mysql' por stdout que
    # contamina el resultado; nos quedamos con la ultima linea (el conteo).
    # Sin esto, la comparacion numerica gatilla "mysql: unbound variable"
    # bajo set -u al intentar evaluar 'mysql:' como nombre de variable.
    exists="${exists##*$'\n'}"
    exists="${exists:-0}"

    if [[ "$exists" -gt 0 ]]; then
        log_info "Schema QA ya existe — sin cambios"
    else
        _db_exec -e \
            "CREATE DATABASE \`${DB_NAME}\`
             CHARACTER SET utf8mb4
             COLLATE utf8mb4_unicode_ci;" > /dev/null
        log_success "Schema QA ${DB_NAME} creado (utf8mb4_unicode_ci)"
    fi
}

# =============================================================================
grant_privileges() {
    log_header "PASO: Otorgando privilegios: ${DB_USER} sobre ${DB_NAME}"

    for host in "%" "localhost" "127.0.0.1"; do
        _db_exec -e \
            "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${host}';" > /dev/null
        # pytest necesita crear y destruir test_<DB_NAME>
        _db_exec -e \
            "GRANT ALL PRIVILEGES ON \`test_${DB_NAME}\`.* TO '${DB_USER}'@'${host}';" > /dev/null
    done

    _db_exec -e "FLUSH PRIVILEGES;" > /dev/null
    log_success "Privilegios aplicados (incluye test_${DB_NAME} para pytest)"
}

# =============================================================================
verify_connection() {
    log_header "PASO: Verificando conexion Django → QA"

    local result
    result=$(_db_exec_quiet \
        -u "$DB_USER" -p"${DB_PASSWORD}" \
        -e "SELECT CONCAT(DATABASE(), ' @ ', USER());" \
        "$DB_NAME" 2>&1) || {
        log_error "No se pudo conectar como ${DB_USER} a ${DB_NAME}"
        log_error "$result"
        exit 1
    }

    log_success "Conexion OK: ${result}"
}

# =============================================================================
log_header "MariaDB QA Setup — PracticaYoruba"
echo "  Schema QA : ${DB_NAME}"
echo "  Usuario   : ${DB_USER}"
echo "  Host      : ${DB_HOST}:${DB_PORT}"
echo "  NOTA      : Schema exclusivo para tests, separado del de produccion"
echo ""

check_prerequisites
create_database
grant_privileges
verify_connection

echo ""
log_success "Schema QA listo."
log_info "Siguiente: DJANGO_SETTINGS_MODULE=config.settings.testing python manage.py migrate"
