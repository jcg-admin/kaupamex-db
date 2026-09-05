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
# Modelo de usuarios (ver Procedimiento-Implementacion-Almacenamiento-
# WSL2-ecomerce-p001 v1.0.0 si aplica):
#   - INVOCADOR canonico: 'deploy' (sudo general).
#   - NO RUN AS develop: sin sudo el acceso al socket mariadbd via
#     unix_socket auth como root falla.
#   - NO RUN AS infra: 'bash' no esta en la whitelist NOPASSWD de
#     infra; 'sudo bash db_qa_setup.sh' como infra falla.
#
# Variables leidas desde .env en la raiz del repositorio (con defaults):
#   DB_QA_NAME      (default: kaupamex_core_qa)
#   DB_QA_USER      (default: django_user)
#   DB_QA_PASSWORD  (default: django_pass)
#   DB_QA_HOST      (default: 127.0.0.1)
#   DB_QA_PORT      (default: 3306)
#
# Adaptaciones respecto a Kaupamex-api/scripts/provisioners/mysql/:
#   - PROJECT_ROOT: dos niveles arriba (no tres) — H-F1-002
#   - source paths: ${PROJECT_ROOT}/utils/ (no scripts/utils/) — H-F3-003
#   - ENV_FILE: ${PROJECT_ROOT}/.env (no kaupamex/.env) — H-F1-002
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
    # Fuente condicional: solo exporta variables no definidas en el entorno.
    # set -a; source sobreescribiría credenciales pasadas vía sudo env VAR=val,
    # rompiendo el flujo CI/CD donde el caller inyecta valores sin tocar el disco.
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        [[ -n "${!key+x}" ]] && continue
        export "$key=$value"
    done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$ENV_FILE")
fi

DB_NAME="${DB_QA_NAME:-kaupamex_core_qa}"
DB_USER="${DB_QA_USER:-django_user}"
DB_PASSWORD="${DB_QA_PASSWORD:?DB_QA_PASSWORD must be set in environment or .env}"
DB_HOST="${DB_QA_HOST:-127.0.0.1}"
DB_PORT="${DB_QA_PORT:-3306}"

# -----------------------------------------------------------------------------
# _db_exec [args...]
#   Ejecuta un comando mysql como administrador del servidor.
#   Intenta socket Unix primero (de _MARIADB_SOCKETS), luego TCP.
# -----------------------------------------------------------------------------
_db_exec() {
    # D-028: usar MARIADB_CLI/MARIADB_ADM (mariadb / mariadb-admin en
    # MariaDB 11.x). Resueltos al sourcear utils/database.sh.
    #
    # DEC-DOC-008 (D-028 bug #3): si la query falla y el caller hace
    # ``_db_exec ... > /dev/null``, antes el error era invisible.
    # Ahora emitimos a stderr el SQL fallido + el output antes de
    # propagar el rc.
    local sock="" adm="${MARIADB_ADM:-}" cli="${MARIADB_CLI:-}" out rc
    if [[ -n "$adm" ]]; then
        for s in "${_MARIADB_SOCKETS[@]}"; do
            if [[ -S "$s" ]] && "$adm" --socket="$s" ping --silent >/dev/null 2>&1; then
                sock="$s"
                break
            fi
        done
    fi
    if [[ -n "$sock" ]]; then
        out=$("$cli" --socket="$sock" --batch "$@" 2>&1); rc=$?
    else
        out=$("$cli" -h "$DB_HOST" -P "$DB_PORT" --batch "$@" 2>&1); rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
        {
            printf '\n[ERR] _db_exec fallo (rc=%s):\n' "$rc"
            printf '%s' "$out" | sed 's/^/    /'
            printf '\n'
        } >&2
    fi
    printf '%s' "$out"
    return $rc
}

_db_exec_quiet() { _db_exec --silent --skip-column-names "$@" 2>/dev/null; }

# =============================================================================
check_prerequisites() {
    log_header "PASO: Verificando prerequisitos"

    [[ -n "${MARIADB_CLI:-}" ]] || {
        log_fatal "Cliente MariaDB no encontrado (ni 'mariadb' ni 'mysql' en PATH)"
        log_error "  Instala: apt install mariadb-client"
        exit 1
    }
    log_info "  Cliente CLI: ${MARIADB_CLI}"

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
    # H-CICLO87-01: usar MYSQL_PWD en lugar de -p"${DB_PASSWORD}" para
    # evitar que la contraseña quede expuesta en la lista de procesos
    # (ps aux). db_setup.sh ya usaba este patron; db_qa_setup.sh no lo
    # replicaba, creando una inconsistencia de seguridad.
    result=$(MYSQL_PWD="${DB_PASSWORD}" _db_exec_quiet \
        -u "$DB_USER" \
        -e "SELECT CONCAT(DATABASE(), ' @ ', USER());" \
        "$DB_NAME" 2>&1) || {
        log_error "No se pudo conectar como ${DB_USER} a ${DB_NAME}"
        log_error "$result"
        exit 1
    }

    log_success "Conexion OK: ${result}"
}

# =============================================================================
log_header "MariaDB QA Setup — Kaupamex"
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
