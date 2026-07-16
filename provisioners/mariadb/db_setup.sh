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
# Modelo de usuarios (ver Procedimiento-Implementacion-Almacenamiento-
# WSL2-ecomerce-p001 v1.0.0 si aplica):
#   - INVOCADOR canonico: 'deploy' (sudo general).
#   - NO RUN AS develop: sin sudo el acceso al socket mariadbd via
#     unix_socket auth como root falla.
#   - NO RUN AS infra: 'bash' no esta en la whitelist NOPASSWD de
#     infra; 'sudo bash db_setup.sh' como infra falla con
#     'sudo: a password is required'.
#
# Variables leidas desde .env en la raiz del repositorio (con defaults):
#   DB_NAME      (default: kaupamex_db)
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
    # Fuente condicional: solo exporta variables no definidas en el entorno.
    # set -a; source sobreescribiría credenciales pasadas vía sudo env VAR=val,
    # rompiendo el flujo CI/CD donde el caller inyecta valores sin tocar el disco.
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        [[ -n "${!key+x}" ]] && continue
        export "$key=$value"
    done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$ENV_FILE")
fi

DB_NAME="${DB_NAME:-kaupamex_db}"
DB_USER="${DB_USER:-django_user}"
DB_PASSWORD="${DB_PASSWORD:?DB_PASSWORD must be set in environment or .env}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"

# -----------------------------------------------------------------------------
# _db_exec [args...]
#   Ejecuta un comando mysql como administrador del servidor.
#   Intenta socket Unix primero (de _MARIADB_SOCKETS), luego TCP.
#   Usar _db_exec_quiet para resultados escalares sin cabecera.
# -----------------------------------------------------------------------------
_db_exec() {
    # D-028: usar MARIADB_CLI/MARIADB_ADM resueltos por database.sh
    # (mariadb / mariadb-admin en MariaDB 11.x; mysql / mysqladmin en
    # MariaDB <=10.11 o MySQL puro). Validacion en check_prerequisites.
    #
    # DEC-DOC-008 (D-028 bug #3 reportado por deploy@yollotl):
    # Antes el script moria silenciosamente bajo ``set -euo pipefail``
    # cuando un CREATE/GRANT fallaba — la salida iba a /dev/null en
    # el caller y nunca se veia el error real. Ahora capturamos
    # output, lo emitimos a stderr con prefijo si el exit code es
    # distinto de cero, y propagamos el rc para que el caller (o
    # set -e) reaccione con contexto visible.
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
        # Loud failure: dejar la causa visible antes de que set -e
        # mate el script en el caller.
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
    exists="${exists##*$'\n'}"; exists="${exists:-0}"

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
        exists="${exists##*$'\n'}"; exists="${exists:-0}"

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

    # H-CICLO26-03: principio de mínimo privilegio — el usuario Django de
    # aplicación solo necesita DML + los permisos estructurales para
    # que `migrate` funcione (CREATE TABLE, ALTER TABLE, DROP TABLE, INDEX,
    # REFERENCES).  No necesita GRANT OPTION, SUPER, FILE, etc.
    # Para la base de test, pytest requiere CREATE y DROP a nivel de schema.
    local APP_GRANTS="SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES"
    local test_db="test_${DB_NAME}"

    # SOL-091 (T-091-01): provisioning multi-DB DB-per-company. El aprovisionador
    # crea/destruye bases `company_<N>_db` (Odoo exp_create_database/exp_drop
    # adaptado). Mínimo privilegio: solo el patrón `company\_%`, NO `*.*`. El
    # patrón `company\_%` incluye CREATE/DROP DATABASE para bases que matchean.
    local PROV_GRANTS="SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES"

    for host in "%" "localhost" "127.0.0.1"; do
        _db_exec -e \
            "GRANT ${APP_GRANTS} ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${host}';" > /dev/null
        # pytest necesita crear y destruir test_<DB_NAME> (CREATE/DROP DATABASE)
        _db_exec -e \
            "GRANT ALL PRIVILEGES ON \`${test_db}\`.* TO '${DB_USER}'@'${host}';" > /dev/null
        # provisioning multi-DB: CREATE/DROP DATABASE company_<N>_db (patrón)
        _db_exec -e \
            "GRANT ${PROV_GRANTS} ON \`company\\_%\`.* TO '${DB_USER}'@'${host}';" > /dev/null
    done

    _db_exec -e "FLUSH PRIVILEGES;" > /dev/null
    log_success "Privilegios aplicados (${APP_GRANTS}; test_${DB_NAME} pytest; company\\_%% provisioning SOL-091)"
}

# =============================================================================
verify_connection() {
    log_header "PASO: Verificando conexion con credenciales Django"

    local result
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
