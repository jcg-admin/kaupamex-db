#!/bin/bash
# =============================================================================
# scripts/verify.sh
# Verificación completa del entorno MariaDB de PracticaYoruba
# =============================================================================
# Comprueba en orden los N checks declarados como funciones
# check_*() en este archivo. El conteo NO se hardcodea aqui —
# se calcula al iniciar el script (TOTAL_CHECKS = grep -c '^check_'
# "$0") y se reporta en el header. Asi, agregar/quitar un check
# nunca queda desincronizado con la documentacion. (T-C1 de
# iniciativa resolver-problemas-db-pendientes — cierre H-01/S-01.)
#
# Lista actual al momento de escribir (referencial — la fuente de
# verdad es el conteo dinamico):
#
#   1. Variables requeridas en .env
#   2. Herramientas CLI disponibles (mysql, mysqladmin)
#   3. MariaDB instalado y versión correcta (11.8.x — ADR-009)
#   4. MariaDB responde (socket Unix primero, luego TCP)
#   5. Schema practicayoruba_db existe y tiene django_migrations
#   6. Schema practicayoruba_qa existe y tiene django_migrations
#   7. Usuario Django tiene SELECT, INSERT, UPDATE, DELETE en practicayoruba_db
#   8. Usuario Django tiene SELECT, INSERT, UPDATE, DELETE en practicayoruba_qa
#   9. Funciones SQL desplegadas (fn_price_with_tax, fn_stock_status,
#      fn_qualifies_free_shipping) — warn si faltan, no fail
#   10. Vistas SQL desplegadas (v_published_catalog, v_featured_products,
#       v_low_stock) — warn si faltan, no fail
#   11. SPs de reporte desplegados (sp_rpt_catalog_by_category,
#       sp_rpt_low_stock, sp_rpt_catalog_summary) — warn si faltan
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
source "${PROJECT_ROOT}/utils/validation.sh"

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
# Helper: ejecutar query como root
# Intenta socket Unix primero (Ubuntu 24.04: root usa unix_socket plugin
# y no puede autenticar via TCP sin contraseña), luego TCP como fallback.
# =============================================================================
_root_exec() {
    local sock=""
    for s in "${_MARIADB_SOCKETS[@]}"; do
        if [[ -S "$s" ]] && mysqladmin --socket="$s" ping --silent >/dev/null 2>&1; then
            sock="$s"
            break
        fi
    done
    if [[ -n "$sock" ]]; then
        mysql --socket="$sock" \
            --batch --silent --skip-column-names \
            "$@" 2>/dev/null
    else
        mysql -h "$DB_HOST" -P "$DB_PORT" \
            --batch --silent --skip-column-names \
            "$@" 2>/dev/null
    fi
}

# =============================================================================
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
    count=$(_root_exec \
        -e "SELECT COUNT(*) FROM information_schema.SCHEMA_PRIVILEGES
            WHERE GRANTEE LIKE \"'${user}'%\"
            AND TABLE_SCHEMA = '${schema}'
            AND PRIVILEGE_TYPE = '${priv}';" || echo "0")
    [[ "${count:-0}" -gt 0 ]]
}

# =============================================================================
# Variables requeridas en .env
# =============================================================================
check_env_vars() {
    log_header "PASO: Variables de entorno (.env)"

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
    log_header "PASO: Herramientas CLI"

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
# MariaDB instalado y versión correcta (11.8.x — ADR-009)
# =============================================================================
check_mariadb_version() {
    log_header "PASO: MariaDB instalado y versión"

    if ! command_exists mysql; then
        fail "mysql CLI no encontrado — MariaDB no está instalado"
        log_error "  Instala con: sudo bash provisioners/mariadb/install.sh"
        return
    fi

    if validate_mariadb_version 11 8; then
        local version_str
        version_str=$(mysql --version 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-MariaDB' | head -1)
        ok "MariaDB ${version_str} instalado (serie 11.8.x — ADR-009)"
    else
        fail "Versión de MariaDB incorrecta o motor no es MariaDB"
        log_error "  Migra con: sudo bash provisioners/mariadb/install.sh"
    fi
}

# =============================================================================
# MariaDB responde
# =============================================================================
check_mariadb_running() {
    log_header "PASO: MariaDB responde"

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
    log_header "PASO: Schema ${DB_NAME}: existencia y migraciones"

    if ! command_exists mysql; then
        warn "mysql CLI no disponible — check omitido"
        return
    fi

    # Verificar que el schema existe
    local schema_exists
    schema_exists=$(_root_exec \
        -e "SELECT COUNT(*) FROM information_schema.SCHEMATA
            WHERE SCHEMA_NAME = '${DB_NAME}';" || echo "0")

    if [[ "${schema_exists:-0}" -lt 1 ]]; then
        fail "Schema ${DB_NAME} no existe"
        log_error "  Crea el schema: sudo bash provisioners/mariadb/db_setup.sh"
        return
    fi
    ok "Schema ${DB_NAME} existe"

    # Verificar que django_migrations existe (migraciones aplicadas)
    local mig_exists
    mig_exists=$(_root_exec \
        -e "SELECT COUNT(*) FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = '${DB_NAME}'
            AND TABLE_NAME = 'django_migrations';" || echo "0")

    if [[ "${mig_exists:-0}" -gt 0 ]]; then
        local mig_count
        mig_count=$(_root_exec \
            -e "SELECT COUNT(*) FROM \`${DB_NAME}\`.django_migrations;" \
            || echo "?")
        ok "django_migrations presente (${mig_count} migraciones aplicadas)"
    else
        warn "django_migrations no encontrada — ejecuta: python manage.py migrate"
    fi
}

# =============================================================================
# Schema practicayoruba_qa existe y tiene django_migrations
# =============================================================================
check_schema_qa() {
    log_header "PASO: Schema ${DB_QA_NAME}: existencia y migraciones"

    if ! command_exists mysql; then
        warn "mysql CLI no disponible — check omitido"
        return
    fi

    local schema_exists
    schema_exists=$(_root_exec \
        -e "SELECT COUNT(*) FROM information_schema.SCHEMATA
            WHERE SCHEMA_NAME = '${DB_QA_NAME}';" || echo "0")

    if [[ "${schema_exists:-0}" -lt 1 ]]; then
        fail "Schema ${DB_QA_NAME} no existe"
        log_error "  Crea el schema QA: sudo bash provisioners/mariadb/db_qa_setup.sh"
        return
    fi
    ok "Schema ${DB_QA_NAME} existe"

    local mig_exists
    mig_exists=$(_root_exec \
        -e "SELECT COUNT(*) FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = '${DB_QA_NAME}'
            AND TABLE_NAME = 'django_migrations';" || echo "0")

    if [[ "${mig_exists:-0}" -gt 0 ]]; then
        local mig_count
        mig_count=$(_root_exec \
            -e "SELECT COUNT(*) FROM \`${DB_QA_NAME}\`.django_migrations;" \
            || echo "?")
        ok "django_migrations presente (${mig_count} migraciones aplicadas)"
    else
        warn "django_migrations no encontrada — ejecuta: DJANGO_SETTINGS_MODULE=config.settings.testing python manage.py migrate"
    fi
}

# =============================================================================
# Privilegios Django en practicayoruba_db
# =============================================================================
check_privs_db() {
    log_header "PASO: Privilegios ${DB_USER} en ${DB_NAME}"

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
    log_header "PASO: Privilegios ${DB_QA_USER} en ${DB_QA_NAME}"

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
# Check 9: Funciones SQL desplegadas
# Emite warn (no fail): las funciones son una capa adicional — su ausencia
# no impide que Django funcione correctamente.
# =============================================================================
check_sql_functions() {
    log_header "PASO: Funciones SQL desplegadas"

    local fn_ok=0 fn_miss=0

    for fn in fn_price_with_tax fn_stock_status fn_qualifies_free_shipping; do
        local exists
        exists=$(_root_exec \
            -e "SELECT COUNT(*) FROM information_schema.routines
                WHERE routine_schema='${DB_NAME}'
                AND routine_name='${fn}'
                AND routine_type='FUNCTION';" || echo "0")
        if [[ "${exists:-0}" -ge 1 ]]; then
            ok "FUNCTION ${fn}"
            (( fn_ok++ )) || true
        else
            warn "FUNCTION ${fn}: no desplegada"
            (( fn_miss++ )) || true
        fi
    done

    if [[ $fn_miss -gt 0 ]]; then
        log_warn "  Despliega con: bash provisioners/mariadb/deploy_objetos.sh"
    fi
}

# =============================================================================
# Check 10: Vistas SQL desplegadas
# =============================================================================
check_sql_views() {
    log_header "PASO: Vistas SQL desplegadas"

    local v_ok=0 v_miss=0

    for v in v_published_catalog v_featured_products v_low_stock; do
        local exists
        exists=$(_root_exec \
            -e "SELECT COUNT(*) FROM information_schema.views
                WHERE table_schema='${DB_NAME}'
                AND table_name='${v}';" || echo "0")
        if [[ "${exists:-0}" -ge 1 ]]; then
            ok "VIEW ${v}"
            (( v_ok++ )) || true
        else
            warn "VIEW ${v}: no desplegada"
            (( v_miss++ )) || true
        fi
    done

    if [[ $v_miss -gt 0 ]]; then
        log_warn "  Despliega con: bash provisioners/mariadb/deploy_objetos.sh"
    fi
}

# =============================================================================
# Check 11: Stored procedures desplegados
# =============================================================================
check_sql_sps() {
    log_header "PASO: Stored procedures desplegados"

    local sp_ok=0 sp_miss=0

    for sp in sp_rpt_catalog_by_category sp_rpt_low_stock sp_rpt_catalog_summary; do
        local exists
        exists=$(_root_exec \
            -e "SELECT COUNT(*) FROM information_schema.routines
                WHERE routine_schema='${DB_NAME}'
                AND routine_name='${sp}'
                AND routine_type='PROCEDURE';" || echo "0")
        if [[ "${exists:-0}" -ge 1 ]]; then
            ok "PROCEDURE ${sp}"
            (( sp_ok++ )) || true
        else
            warn "PROCEDURE ${sp}: no desplegado"
            (( sp_miss++ )) || true
        fi
    done

    if [[ $sp_miss -gt 0 ]]; then
        log_warn "  Despliega con: bash provisioners/mariadb/deploy_objetos.sh"
    fi
}

# =============================================================================
# MAIN
# =============================================================================
# DEC-DB-4: conteo de checks calculado dinamicamente.
# grep -c sobre el propio script para encontrar las definiciones
# de funcion check_*(). Evita el magic number en docs.
TOTAL_CHECKS=$(grep -cE '^(function )?check_[a-z_]+\(\)' "$0")

log_header "PracticaYoruba-db — Verificacion completa (${TOTAL_CHECKS} checks)"
log_info "  DB prod : ${DB_NAME} @ ${DB_HOST}:${DB_PORT}"
log_info "  DB QA   : ${DB_QA_NAME} @ ${DB_HOST}:${DB_PORT}"
echo ""

check_env_vars;          echo ""
check_tools;             echo ""
check_mariadb_version;   echo ""
check_mariadb_running;   echo ""
check_schema_db;    echo ""
check_schema_qa;    echo ""
check_privs_db;     echo ""
check_privs_qa;     echo ""
check_sql_functions; echo ""
check_sql_views;    echo ""
check_sql_sps;       echo ""

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
