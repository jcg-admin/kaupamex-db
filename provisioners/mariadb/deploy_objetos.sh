#!/bin/bash
# =============================================================================
# provisioners/mariadb/deploy_objetos.sh
# Despliega objetos SQL y seed del catálogo en practicayoruba_db
# =============================================================================
# IDEMPOTENTE: usa CREATE OR REPLACE en funciones, vistas y SPs.
#              seed_catalogo.sql usa INSERT IGNORE.
#              Re-ejecutar no duplica ni produce errores.
#
# Orden de despliegue (dependencias):
#   1. Funciones           — sin dependencias entre sí
#   2. Vistas              — dependen de tablas Django (ya creadas con migrate)
#      a. v_catalogo_publicado   — sin dependencia de otra vista
#      b. v_productos_destacados — depende de v_catalogo_publicado
#      c. v_stock_critico        — depende de settings_sitesettings (seed)
#   3. Stored Procedures   — sp_rpt_stock_critico depende de fn_stock_status
#   4. Seed del catálogo   — prerequisito de v_stock_critico y sp_rpt_*
#
# NOTA sobre GRANT EXECUTE:
#   db_setup.sh ya ejecuta GRANT ALL PRIVILEGES ON practicayoruba_db.* que
#   incluye EXECUTE sobre todas las rutinas del schema. No se requiere un
#   GRANT adicional en este script.
#
# Uso:
#   bash provisioners/mariadb/deploy_objetos.sh
#
# Requiere: MariaDB activo, schema practicayoruba_db con migraciones Django
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${PROJECT_ROOT}/utils/logging.sh"
source "${PROJECT_ROOT}/utils/core.sh"
source "${PROJECT_ROOT}/utils/database.sh"

ENV_FILE="${PROJECT_ROOT}/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

DB_NAME="${DB_NAME:-practicayoruba_db}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"

readonly OBJETOS_DIR="${SCRIPT_DIR}/objetos"
readonly SEED_FILE="${SCRIPT_DIR}/seed_catalogo.sql"

# =============================================================================
# Helper: ejecutar un archivo SQL como root via socket-primero
# Captura errores — sale con 1 si hay ERROR en la salida.
# =============================================================================
_exec_sql_file() {
    local file="$1"
    local name
    name=$(basename "$file" .sql)
    local sock="" result=""

    for s in "${_MARIADB_SOCKETS[@]}"; do
        if [[ -S "$s" ]] && mysqladmin --socket="$s" ping --silent >/dev/null 2>&1; then
            sock="$s"
            break
        fi
    done

    if [[ -n "$sock" ]]; then
        result=$(mysql --socket="$sock" "$DB_NAME" < "$file" 2>&1)
    else
        result=$(mysql -h "$DB_HOST" -P "$DB_PORT" "$DB_NAME" < "$file" 2>&1)
    fi

    # Detectar errores reales (no los mensajes de verificación)
    local errors
    errors=$(echo "$result" | grep -E "^ERROR [0-9]" || true)

    if [[ -n "$errors" ]]; then
        log_error "  FALLA: ${name}"
        echo "$errors" | while IFS= read -r line; do
            log_error "    ${line}"
        done
        return 1
    fi

    log_success "${name}"
    return 0
}

# =============================================================================
# PASO: Verificar prerequisitos
# =============================================================================
_check_prereqs() {
    log_header "PASO: Verificando prerequisitos"

    if ! mariadb_is_running "$DB_HOST" "$DB_PORT"; then
        log_error "MariaDB no disponible en ${DB_HOST}:${DB_PORT}"
        exit 1
    fi
    log_success "MariaDB activo"

    # Verificar que las migraciones Django están aplicadas
    local mig_exists
    local sock=""
    for s in "${_MARIADB_SOCKETS[@]}"; do
        if [[ -S "$s" ]] && mysqladmin --socket="$s" ping --silent >/dev/null 2>&1; then
            sock="$s"; break
        fi
    done

    if [[ -n "$sock" ]]; then
        mig_exists=$(mysql --socket="$sock" --batch --silent --skip-column-names \
            -e "SELECT COUNT(*) FROM information_schema.TABLES
                WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='django_migrations';" \
            2>/dev/null || echo "0")
    else
        mig_exists=$(mysql -h "$DB_HOST" -P "$DB_PORT" --batch --silent --skip-column-names \
            -e "SELECT COUNT(*) FROM information_schema.TABLES
                WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_NAME='django_migrations';" \
            2>/dev/null || echo "0")
    fi

    if [[ "${mig_exists:-0}" -lt 1 ]]; then
        log_error "django_migrations no encontrada en ${DB_NAME}"
        log_error "  Ejecuta primero: python manage.py migrate"
        exit 1
    fi
    log_success "Migraciones Django presentes"

    if [[ ! -d "$OBJETOS_DIR" ]]; then
        log_error "Directorio objetos/ no encontrado: ${OBJETOS_DIR}"
        exit 1
    fi
    log_success "Directorio objetos/ encontrado"
}

# =============================================================================
# PASO: Desplegar funciones SQL
# =============================================================================
_deploy_funciones() {
    log_header "PASO: Desplegando funciones"

    local fn_dir="${OBJETOS_DIR}/funciones"
    local ok=0 err=0

    for sql_file in \
        "${fn_dir}/fn_precio_con_iva.sql" \
        "${fn_dir}/fn_stock_status.sql" \
        "${fn_dir}/fn_aplica_envio_gratis.sql"; do

        if [[ ! -f "$sql_file" ]]; then
            log_error "  Archivo no encontrado: ${sql_file}"
            (( err++ )) || true
            continue
        fi

        if _exec_sql_file "$sql_file"; then
            (( ok++ )) || true
        else
            (( err++ )) || true
        fi
    done

    if [[ $err -gt 0 ]]; then
        log_error "${err} función(es) fallaron"
        exit 1
    fi
    log_info "  ${ok} función(es) desplegadas"
}

# =============================================================================
# PASO: Desplegar vistas SQL
# El orden importa: v_catalogo_publicado antes de v_productos_destacados
# =============================================================================
_deploy_vistas() {
    log_header "PASO: Desplegando vistas"

    local vistas_dir="${OBJETOS_DIR}/vistas"
    local ok=0 err=0

    # Orden explícito — v_productos_destacados depende de v_catalogo_publicado
    for sql_file in \
        "${vistas_dir}/v_catalogo_publicado.sql" \
        "${vistas_dir}/v_productos_destacados.sql" \
        "${vistas_dir}/v_stock_critico.sql"; do

        if [[ ! -f "$sql_file" ]]; then
            log_error "  Archivo no encontrado: ${sql_file}"
            (( err++ )) || true
            continue
        fi

        if _exec_sql_file "$sql_file"; then
            (( ok++ )) || true
        else
            (( err++ )) || true
        fi
    done

    if [[ $err -gt 0 ]]; then
        log_error "${err} vista(s) fallaron"
        exit 1
    fi
    log_info "  ${ok} vista(s) desplegadas"
}

# =============================================================================
# PASO: Desplegar stored procedures
# sp_rpt_stock_critico depende de fn_stock_status — funciones van primero
# =============================================================================
_deploy_sps() {
    log_header "PASO: Desplegando stored procedures"

    local sps_dir="${OBJETOS_DIR}/sps"
    local ok=0 err=0

    for sql_file in \
        "${sps_dir}/sp_rpt_catalogo_por_categoria.sql" \
        "${sps_dir}/sp_rpt_stock_critico.sql" \
        "${sps_dir}/sp_rpt_resumen_catalogo.sql"; do

        if [[ ! -f "$sql_file" ]]; then
            log_error "  Archivo no encontrado: ${sql_file}"
            (( err++ )) || true
            continue
        fi

        if _exec_sql_file "$sql_file"; then
            (( ok++ )) || true
        else
            (( err++ )) || true
        fi
    done

    if [[ $err -gt 0 ]]; then
        log_error "${err} SP(s) fallaron"
        exit 1
    fi
    log_info "  ${ok} SP(s) desplegados"
}

# =============================================================================
# PASO: Aplicar seed del catálogo
# =============================================================================
_deploy_seed() {
    log_header "PASO: Aplicando seed del catálogo"

    if [[ ! -f "$SEED_FILE" ]]; then
        log_warn "  seed_catalogo.sql no encontrado — omitiendo seed"
        return 0
    fi

    if _exec_sql_file "$SEED_FILE"; then
        log_info "  Seed aplicado (INSERT IGNORE — idempotente)"
    else
        log_error "  El seed falló"
        exit 1
    fi
}

# =============================================================================
# PASO: Verificar objetos desplegados
# =============================================================================
_verify_objects() {
    log_header "PASO: Verificando objetos en information_schema"

    local sock=""
    for s in "${_MARIADB_SOCKETS[@]}"; do
        if [[ -S "$s" ]] && mysqladmin --socket="$s" ping --silent >/dev/null 2>&1; then
            sock="$s"; break
        fi
    done

    _q() {
        if [[ -n "$sock" ]]; then
            mysql --socket="$sock" --batch --silent --skip-column-names \
                -e "$1" information_schema 2>/dev/null || echo "0"
        else
            mysql -h "$DB_HOST" -P "$DB_PORT" --batch --silent --skip-column-names \
                -e "$1" information_schema 2>/dev/null || echo "0"
        fi
    }

    local all_ok=true

    # Verificar funciones
    for fn in fn_precio_con_iva fn_stock_status fn_aplica_envio_gratis; do
        local exists
        exists=$(_q "SELECT COUNT(*) FROM routines
                     WHERE routine_schema='${DB_NAME}'
                     AND routine_name='${fn}'
                     AND routine_type='FUNCTION';")
        if [[ "${exists:-0}" -ge 1 ]]; then
            log_success "  FUNCTION ${fn}"
        else
            log_error "  FUNCTION ${fn}: NO encontrada"
            all_ok=false
        fi
    done

    # Verificar vistas
    for v in v_catalogo_publicado v_productos_destacados v_stock_critico; do
        local exists
        exists=$(_q "SELECT COUNT(*) FROM views
                     WHERE table_schema='${DB_NAME}'
                     AND table_name='${v}';")
        if [[ "${exists:-0}" -ge 1 ]]; then
            log_success "  VIEW ${v}"
        else
            log_error "  VIEW ${v}: NO encontrada"
            all_ok=false
        fi
    done

    # Verificar SPs
    for sp in sp_rpt_catalogo_por_categoria sp_rpt_stock_critico sp_rpt_resumen_catalogo; do
        local exists
        exists=$(_q "SELECT COUNT(*) FROM routines
                     WHERE routine_schema='${DB_NAME}'
                     AND routine_name='${sp}'
                     AND routine_type='PROCEDURE';")
        if [[ "${exists:-0}" -ge 1 ]]; then
            log_success "  PROCEDURE ${sp}"
        else
            log_error "  PROCEDURE ${sp}: NO encontrada"
            all_ok=false
        fi
    done

    if [[ "$all_ok" == "false" ]]; then
        log_error "Uno o más objetos no se desplegaron correctamente"
        exit 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================
log_header "Despliegue de objetos SQL — PracticaYoruba-db"
log_info "  Schema: ${DB_NAME}"
log_info "  Objetos: 3 funciones + 3 vistas + 3 SPs + seed"
echo ""

_check_prereqs;    echo ""
_deploy_funciones; echo ""
_deploy_vistas;    echo ""
_deploy_sps;       echo ""
_deploy_seed;      echo ""
_verify_objects;   echo ""

log_separator 60 "="
log_success "9 objetos SQL desplegados. Seed del catálogo aplicado."
echo ""
log_info "Verificar con:"
log_info "  bash scripts/verify.sh"
log_info "  python scripts/check_db.py"
