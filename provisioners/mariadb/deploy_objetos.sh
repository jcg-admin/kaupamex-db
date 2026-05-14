#!/bin/bash
# =============================================================================
# provisioners/mariadb/deploy_objetos.sh
# Despliega objetos SQL y seed del catálogo en practicayoruba_db
# =============================================================================
# IDEMPOTENTE: usa CREATE OR REPLACE en funciones, vistas y SPs.
#              seed_catalogo.sql usa INSERT IGNORE.
#
# Incluye un PASO DE MIGRACIÓN que elimina los nombres en español
# (v1.0.0) antes de crear los nombres en inglés (v2.0.0). Idempotente:
# DROP IF EXISTS no falla si el objeto ya fue eliminado.
#
# Orden de despliegue (dependencias):
#   1. Migración — DROP nombres en español (SPs → vistas → funciones)
#   2. Funciones           — sin dependencias entre sí
#   3. Vistas              — orden explícito obligatorio:
#      a. v_published_catalog   — sin dependencia de otra vista
#      b. v_featured_products   — depende de v_published_catalog
#      c. v_low_stock           — depende de settings_sitesettings (seed)
#   4. Stored Procedures   — sp_rpt_low_stock depende de fn_stock_status
#   5. Seed del catálogo
#
# NOTA sobre GRANT EXECUTE:
#   db_setup.sh ya ejecuta GRANT ALL PRIVILEGES ON practicayoruba_db.* que
#   incluye EXECUTE sobre todas las rutinas. Sin GRANT adicional requerido.
#
# Uso:
#   bash provisioners/mariadb/deploy_objetos.sh
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

# Helper: ejecutar SQL inline como root via socket-primero
_exec_sql() {
    local sql="$1"
    local sock=""
    for s in "${_MARIADB_SOCKETS[@]}"; do
        if [[ -S "$s" ]] && mysqladmin --socket="$s" ping --silent >/dev/null 2>&1; then
            sock="$s"; break
        fi
    done
    if [[ -n "$sock" ]]; then
        mysql --socket="$sock" "$DB_NAME" -e "$sql" 2>/dev/null
    else
        mysql -h "$DB_HOST" -P "$DB_PORT" "$DB_NAME" -e "$sql" 2>/dev/null
    fi
}

# =============================================================================
# PASO 0: Verificar prerequisitos
# =============================================================================
_check_prereqs() {
    log_header "PASO: Verificando prerequisitos"

    if ! mariadb_is_running "$DB_HOST" "$DB_PORT"; then
        log_error "MariaDB no disponible en ${DB_HOST}:${DB_PORT}"
        exit 1
    fi
    log_success "MariaDB activo"

    local sock=""
    for s in "${_MARIADB_SOCKETS[@]}"; do
        if [[ -S "$s" ]] && mysqladmin --socket="$s" ping --silent >/dev/null 2>&1; then
            sock="$s"; break
        fi
    done

    local mig_exists
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
        log_error "django_migrations no encontrada — ejecuta: python manage.py migrate"
        exit 1
    fi
    log_success "Migraciones Django presentes"

    [[ -d "$OBJETOS_DIR" ]] || { log_error "Directorio objetos/ no encontrado"; exit 1; }
    log_success "Directorio objetos/ encontrado"
}

# =============================================================================
# PASO 1: Migración — DROP de nombres en español (v1.0.0)
# Orden inverso a dependencias: SPs → vistas (dependientes primero) → funciones
# =============================================================================
_migrate_drop_spanish_names() {
    log_header "PASO: Migración — eliminando nombres en español (v1.0.0)"

    # SPs — sin dependencias entre ellos
    for sp in sp_rpt_catalogo_por_categoria sp_rpt_stock_critico sp_rpt_resumen_catalogo; do
        _exec_sql "DROP PROCEDURE IF EXISTS \`${DB_NAME}\`.\`${sp}\`;"
        log_info "  DROP PROCEDURE IF EXISTS ${sp}"
    done

    # Vistas — v_productos_destacados depende de v_catalogo_publicado: eliminar dependiente primero
    for v in v_productos_destacados v_catalogo_publicado v_stock_critico; do
        _exec_sql "DROP VIEW IF EXISTS \`${DB_NAME}\`.\`${v}\`;"
        log_info "  DROP VIEW IF EXISTS ${v}"
    done

    # Funciones
    for fn in fn_precio_con_iva fn_aplica_envio_gratis; do
        _exec_sql "DROP FUNCTION IF EXISTS \`${DB_NAME}\`.\`${fn}\`;"
        log_info "  DROP FUNCTION IF EXISTS ${fn}"
    done

    log_success "Migración completada"
}

# =============================================================================
# PASO 2: Desplegar funciones SQL
# =============================================================================
_deploy_functions() {
    log_header "PASO: Desplegando funciones"

    local fn_dir="${OBJETOS_DIR}/funciones"
    local ok=0 err=0

    for sql_file in \
        "${fn_dir}/fn_price_with_tax.sql" \
        "${fn_dir}/fn_stock_status.sql" \
        "${fn_dir}/fn_qualifies_free_shipping.sql"; do

        if [[ ! -f "$sql_file" ]]; then
            log_error "  Archivo no encontrado: ${sql_file}"
            (( err++ )) || true; continue
        fi
        if _exec_sql_file "$sql_file"; then
            (( ok++ )) || true
        else
            (( err++ )) || true
        fi
    done

    [[ $err -gt 0 ]] && { log_error "${err} función(es) fallaron"; exit 1; }
    log_info "  ${ok} función(es) desplegadas"
}

# =============================================================================
# PASO 3: Desplegar vistas SQL
# Orden explícito: v_published_catalog antes de v_featured_products
# =============================================================================
_deploy_views() {
    log_header "PASO: Desplegando vistas"

    local views_dir="${OBJETOS_DIR}/vistas"
    local ok=0 err=0

    for sql_file in \
        "${views_dir}/v_published_catalog.sql" \
        "${views_dir}/v_featured_products.sql" \
        "${views_dir}/v_low_stock.sql"; do

        if [[ ! -f "$sql_file" ]]; then
            log_error "  Archivo no encontrado: ${sql_file}"
            (( err++ )) || true; continue
        fi
        if _exec_sql_file "$sql_file"; then
            (( ok++ )) || true
        else
            (( err++ )) || true
        fi
    done

    [[ $err -gt 0 ]] && { log_error "${err} vista(s) fallaron"; exit 1; }
    log_info "  ${ok} vista(s) desplegadas"
}

# =============================================================================
# PASO 4: Desplegar stored procedures
# sp_rpt_low_stock depende de fn_stock_status — funciones van primero
# =============================================================================
_deploy_sps() {
    log_header "PASO: Desplegando stored procedures"

    local sps_dir="${OBJETOS_DIR}/sps"
    local ok=0 err=0

    for sql_file in \
        "${sps_dir}/sp_rpt_catalog_by_category.sql" \
        "${sps_dir}/sp_rpt_low_stock.sql" \
        "${sps_dir}/sp_rpt_catalog_summary.sql"; do

        if [[ ! -f "$sql_file" ]]; then
            log_error "  Archivo no encontrado: ${sql_file}"
            (( err++ )) || true; continue
        fi
        if _exec_sql_file "$sql_file"; then
            (( ok++ )) || true
        else
            (( err++ )) || true
        fi
    done

    [[ $err -gt 0 ]] && { log_error "${err} SP(s) fallaron"; exit 1; }
    log_info "  ${ok} SP(s) desplegados"
}

# =============================================================================
# PASO 5: Aplicar seed del catálogo
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
        log_error "  El seed falló"; exit 1
    fi
}

# =============================================================================
# PASO 6: Verificar objetos desplegados en information_schema
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

    for fn in fn_price_with_tax fn_stock_status fn_qualifies_free_shipping; do
        local exists
        exists=$(_q "SELECT COUNT(*) FROM routines
                     WHERE routine_schema='${DB_NAME}'
                     AND routine_name='${fn}' AND routine_type='FUNCTION';")
        if [[ "${exists:-0}" -ge 1 ]]; then
            log_success "  FUNCTION ${fn}"
        else
            log_error "  FUNCTION ${fn}: NO encontrada"; all_ok=false
        fi
    done

    for v in v_published_catalog v_featured_products v_low_stock; do
        local exists
        exists=$(_q "SELECT COUNT(*) FROM views
                     WHERE table_schema='${DB_NAME}' AND table_name='${v}';")
        if [[ "${exists:-0}" -ge 1 ]]; then
            log_success "  VIEW ${v}"
        else
            log_error "  VIEW ${v}: NO encontrada"; all_ok=false
        fi
    done

    for sp in sp_rpt_catalog_by_category sp_rpt_low_stock sp_rpt_catalog_summary; do
        local exists
        exists=$(_q "SELECT COUNT(*) FROM routines
                     WHERE routine_schema='${DB_NAME}'
                     AND routine_name='${sp}' AND routine_type='PROCEDURE';")
        if [[ "${exists:-0}" -ge 1 ]]; then
            log_success "  PROCEDURE ${sp}"
        else
            log_error "  PROCEDURE ${sp}: NO encontrada"; all_ok=false
        fi
    done

    # Verificar que los nombres en español ya NO existen
    local spanish_ok=true
    for old in fn_precio_con_iva fn_aplica_envio_gratis \
               v_catalogo_publicado v_productos_destacados v_stock_critico \
               sp_rpt_catalogo_por_categoria sp_rpt_stock_critico sp_rpt_resumen_catalogo; do
        local exists
        exists=$(_q "SELECT COUNT(*) FROM routines
                     WHERE routine_schema='${DB_NAME}' AND routine_name='${old}'
                     UNION ALL
                     SELECT COUNT(*) FROM views
                     WHERE table_schema='${DB_NAME}' AND table_name='${old}';" \
                 | awk '{s+=$1} END{print s}')
        if [[ "${exists:-0}" -gt 0 ]]; then
            log_error "  Nombre en español AÚN EXISTE: ${old}"
            spanish_ok=false
        fi
    done
    if [[ "$spanish_ok" == "true" ]]; then
        log_success "  Nombres en español eliminados correctamente"
    fi

    if [[ "$all_ok" == "false" || "$spanish_ok" == "false" ]]; then
        log_error "Uno o más objetos no se desplegaron correctamente"
        exit 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================
log_header "Despliegue de objetos SQL — PracticaYoruba-db v2.0.0"
log_info "  Schema : ${DB_NAME}"
log_info "  Objetos: 3 funciones + 3 vistas + 3 SPs + seed (nombres en inglés)"
echo ""

_check_prereqs;                echo ""
_migrate_drop_spanish_names;   echo ""
_deploy_functions;             echo ""
_deploy_views;                 echo ""
_deploy_sps;                   echo ""
_deploy_seed;                  echo ""
_verify_objects;               echo ""

log_separator 60 "="
log_success "9 objetos SQL desplegados con nombres en inglés."
log_success "Nombres en español eliminados de la BD."
