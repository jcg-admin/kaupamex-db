#!/bin/bash
# =============================================================================
# provisioners/mariadb/db_setup.sh
# Crea el schema de produccion/desarrollo y el usuario Django en MariaDB
# =============================================================================
# IDEMPOTENTE: se puede ejecutar N veces sin efectos adversos.
#
# Uso:
#   sudo bash provisioners/mariadb/db_setup.sh
#   # En contenedores sin sudo (MariaDB ya accesible como root sin pass):
#   bash provisioners/mariadb/db_setup.sh
#
# Variables leidas desde .env en la raiz del repositorio (con defaults):
#   DB_NAME      (default: practicayoruba_db)
#   DB_USER      (default: django_user)
#   DB_PASSWORD  (default: django_pass)
#   DB_HOST      (default: 127.0.0.1)
#   DB_PORT      (default: 3306)
#
# Adaptaciones respecto a PracticaYoruba-api/scripts/provisioners/mysql/:
#   - PROJECT_ROOT: dos niveles arriba (no tres) — H-F1-002
#   - source paths: ${PROJECT_ROOT}/utils/ (no scripts/utils/) — H-F3-003
#   - ENV_FILE: ${PROJECT_ROOT}/.env (no practicayoruba/.env) — H-F1-002
#   - mysql_is_running/mysql_start → mariadb_is_running/mariadb_start — H-F2-004
#   - _my_exec renombrado a _db_exec y usa _MARIADB_SOCKETS — H-F3-002
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

DB_NAME="${DB_NAME:-practicayoruba_db}"
DB_USER="${DB_USER:-django_user}"
DB_PASSWORD="${DB_PASSWORD:-django_pass}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"

# -----------------------------------------------------------------------------
# _db_exec [args...]
#   Ejecuta un comando mysql como administrador del servidor.
#   Intenta socket Unix primero (de _MARIADB_SOCKETS), luego TCP.
#   Usar _db_exec_quiet para resultados escalares sin cabecera.
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
            log_error "  sudo bash provisioners/mariadb/db_setup.sh"
            exit 1
        }
    fi

    log_success "MariaDB activo en ${DB_HOST}:${DB_PORT}"
}

# =============================================================================
create_database() {
    log_header "PASO: Creando schema: ${DB_NAME}"

    local exists
    exists=$(_db_exec_quiet -e \
        "SELECT COUNT(*) FROM information_schema.SCHEMATA
         WHERE SCHEMA_NAME = '${DB_NAME}';" || echo "0")

    if [[ "$exists" -gt 0 ]]; then
        log_info "Schema ya existe — sin cambios"
    else
        _db_exec -e \
            "CREATE DATABASE \`${DB_NAME}\`
             CHARACTER SET utf8mb4
             COLLATE utf8mb4_unicode_ci;" > /dev/null
        log_success "Schema ${DB_NAME} creado (utf8mb4_unicode_ci)"
    fi
}

# =============================================================================
create_user() {
    log_header "PASO: Creando usuario: ${DB_USER}"

    for host in "%" "localhost" "127.0.0.1"; do
        local exists
        exists=$(_db_exec_quiet -e \
            "SELECT COUNT(*) FROM mysql.user
             WHERE User = '${DB_USER}' AND Host = '${host}';" || echo "0")

        if [[ "$exists" -gt 0 ]]; then
            _db_exec -e \
                "ALTER USER '${DB_USER}'@'${host}'
                 IDENTIFIED BY '${DB_PASSWORD}';" > /dev/null
            log_info "${DB_USER}@${host} ya existe — contrasena sincronizada"
        else
            _db_exec -e \
                "CREATE USER '${DB_USER}'@'${host}'
                 IDENTIFIED BY '${DB_PASSWORD}';" > /dev/null
            log_success "${DB_USER}@${host} creado"
        fi
    done
}

# =============================================================================
grant_privileges() {
    log_header "PASO: Otorgando privilegios: ${DB_USER} sobre ${DB_NAME}"

    local test_db="test_${DB_NAME}"

    for host in "%" "localhost" "127.0.0.1"; do
        _db_exec -e \
            "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${host}';" > /dev/null
        # pytest necesita crear y destruir test_<DB_NAME>
        _db_exec -e \
            "GRANT ALL PRIVILEGES ON \`${test_db}\`.* TO '${DB_USER}'@'${host}';" > /dev/null
    done

    _db_exec -e "FLUSH PRIVILEGES;" > /dev/null
    log_success "Privilegios aplicados (incluye test_${DB_NAME} para pytest)"
}

# =============================================================================
verify_connection() {
    log_header "PASO: Verificando conexion con credenciales Django"

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
log_header "MariaDB DB Setup — PracticaYoruba"
echo "  Schema  : ${DB_NAME}"
echo "  Usuario : ${DB_USER}"
echo "  Host    : ${DB_HOST}:${DB_PORT}"
echo ""

check_prerequisites
create_database
create_user
grant_privileges
verify_connection

echo ""
log_success "Setup completado."
log_info "Siguiente: cd <PracticaYoruba-api>/practicayoruba && python manage.py migrate"
