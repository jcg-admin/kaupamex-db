#!/bin/bash
# =============================================================================
# scripts/backup_db.sh
# Backup completo de kaupamex_core y kaupamex_core_qa (MariaDB 11.8)
# =============================================================================
# Genera por ejecución (un par por schema):
#   backups/<timestamp>_kaupamex_core.sql.gz    dump comprimido (gzip -6)
#   backups/<timestamp>_kaupamex_core.md5        checksum MD5
#   backups/<timestamp>_kaupamex_core_qa.sql.gz
#   backups/<timestamp>_kaupamex_core_qa.md5
#   backups/<timestamp>.log                          log de operación
#
# El timestamp usa TZ America/Mexico_City (zona horaria del proyecto).
# Formato: YYYYMMDD_HHMMSS
#
# USUARIO DE BACKUP:
#   Usa py_backup_user (no root, no django_user) con privilegios mínimos:
#     SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, EVENT sobre cada schema.
#     PROCESS, RELOAD globales.
#   Se crea idempotente en cada ejecución (CREATE USER IF NOT EXISTS).
#   Nota: GRANT SELECT ON mysql.proc omitido — deprecated en MariaDB 11.8.
#   (Hallazgo H-F4-001)
#
# PATRONES APLICADOS (de IACT-db/provisioners/mariadb/backup_ivr_legacy.sh):
#   BK-001 — arranque MariaDB con mariadb_start (loop de reintento)
#   BK-002 — inventario InnoDB marcado como "no confiable"
#   BK-003 — GRANTs incluidos en el dump (--single-transaction normal)
#   BK-004 — gzip -6 (3x más rápido que -9, ratio similar)
#   BK-005 — stderr de mysqldump capturado y analizado por separado
#
# Uso:
#   bash scripts/backup_db.sh
#
# Variables del .env:
#   DB_NAME, DB_QA_NAME, PY_BACKUP_USER, PY_BACKUP_PASSWORD,
#   DB_HOST, DB_PORT, BACKUP_DIR, BACKUP_REMOTE_DEST
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/utils/logging.sh"
source "${PROJECT_ROOT}/utils/network.sh"
source "${PROJECT_ROOT}/utils/database.sh"

# =============================================================================
# Cargar .env
# =============================================================================
ENV_FILE="${PROJECT_ROOT}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    log_fatal "Archivo .env no encontrado en ${PROJECT_ROOT}"
    log_error "  Crea tu configuracion: cp .env.example .env"
    exit 1
fi
set -a; source "$ENV_FILE"; set +a

# =============================================================================
# Configuración
# =============================================================================
DB_PROD="${DB_NAME:-kaupamex_core}"
DB_QA="${DB_QA_NAME:-kaupamex_core_qa}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"

BACKUP_USER="${PY_BACKUP_USER:-py_backup_user}"
BACKUP_PASS="${PY_BACKUP_PASSWORD:?PY_BACKUP_PASSWORD must be set in environment or .env}"
BACKUP_HOST="localhost"

BACKUP_DIR="${BACKUP_DIR:-${PROJECT_ROOT}/backups}"
BACKUP_REMOTE_DEST="${BACKUP_REMOTE_DEST:-}"
# H-CICLO25-03: retención de backups.  Los archivos .sql.gz, .md5 y .log con
# más de BACKUP_RETENTION_DAYS días se eliminan automáticamente al final de
# cada ejecución.  Default: 30 días.  Sobreescribir con BACKUP_RETENTION_DAYS
# en .env para ajustar la política de retención del entorno.
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

# Timestamp en zona horaria del proyecto (H-F1-004, H-F4-002)
TS=$(TZ="America/Mexico_City" date +"%Y%m%d_%H%M%S")

LOG_FILE="${BACKUP_DIR}/${TS}.log"

init_log "backup_${TS}"

# =============================================================================
# Detección de socket (centralizada en _MARIADB_SOCKETS de database.sh)
# =============================================================================
_detect_socket() {
    for s in "${_MARIADB_SOCKETS[@]}"; do
        if [[ -S "$s" ]] && mysqladmin --socket="$s" ping --silent >/dev/null 2>&1; then
            echo "$s"
            return 0
        fi
    done
    echo ""
}

# Helpers de ejecución sql
_root_exec() {
    local sock
    sock=$(_detect_socket)
    if [[ -n "$sock" ]]; then
        mysql --batch --socket="$sock" "$@" 2>&1
    else
        mysql --batch -h "$DB_HOST" -P "$DB_PORT" "$@" 2>&1
    fi
}

_root_exec_q() { _root_exec --silent --skip-column-names "$@" 2>/dev/null; }

# =============================================================================
# Verificar MariaDB activo (BK-001)
# =============================================================================
_check_mariadb() {
    log_header "PASO: Verificando MariaDB"

    if mariadb_is_running "$DB_HOST" "$DB_PORT"; then
        log_success "MariaDB activo"
        return 0
    fi

    log_warn "MariaDB no responde — intentando arranque automatico (BK-001)"
    mariadb_start || {
        log_fatal "MariaDB no disponible. Aborta."
        exit 1
    }
}

# =============================================================================
# Crear py_backup_user (idempotente)
# =============================================================================
_setup_backup_user() {
    log_header "PASO: Creando usuario de backup (idempotente)"

    local sql="
CREATE USER IF NOT EXISTS '${BACKUP_USER}'@'${BACKUP_HOST}'
    IDENTIFIED BY '${BACKUP_PASS}';
GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, EVENT
    ON \`${DB_PROD}\`.* TO '${BACKUP_USER}'@'${BACKUP_HOST}';
GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, EVENT
    ON \`${DB_QA}\`.* TO '${BACKUP_USER}'@'${BACKUP_HOST}';
GRANT PROCESS, RELOAD ON *.* TO '${BACKUP_USER}'@'${BACKUP_HOST}';
FLUSH PRIVILEGES;"

    if _root_exec -e "$sql" > /dev/null; then
        log_success "${BACKUP_USER}@${BACKUP_HOST} listo"
        log_info "  Grants en ${DB_PROD}: SELECT,SHOW VIEW,TRIGGER,LOCK TABLES,EVENT"
        log_info "  Grants en ${DB_QA}:   SELECT,SHOW VIEW,TRIGGER,LOCK TABLES,EVENT"
        log_info "  Grants globales:      PROCESS,RELOAD"
    else
        log_warn "${BACKUP_USER} no se pudo crear/actualizar"
        log_warn "  Continuando con las credenciales actuales"
        log_warn "  Si el backup falla, verifica los privilegios manualmente"
    fi
}

# =============================================================================
# PASO 3 — Inventario de tablas (referencial, BK-002)
# =============================================================================
_log_inventory() {
    local schema="$1"
    log_info "  Inventario InnoDB para ${schema} (estimacion — no confiable para InnoDB, BK-002):"

    _root_exec_q -e \
        "SELECT table_name,
                table_rows AS filas_APROX,
                ROUND(data_length/1024/1024,2) AS mb_datos
         FROM information_schema.tables
         WHERE table_schema = '${schema}'
         ORDER BY table_name;" 2>/dev/null \
    | while IFS=$'\t' read -r tbl rows mb; do
        log_info "    ${tbl}: ~${rows} filas  (${mb} MB)"
    done || log_warn "  No se pudo obtener inventario de ${schema}"
}

# =============================================================================
# PASO 4 — Generar dumps (BK-004, BK-005)
# =============================================================================
_dump_schema() {
    local schema="$1"
    local dump_file="${BACKUP_DIR}/${TS}_${schema}.sql.gz"
    local md5_file="${BACKUP_DIR}/${TS}_${schema}.md5"
    local stderr_file="${BACKUP_DIR}/${TS}_${schema}.mysqldump.stderr"

    log_info "  Dump de ${schema} → $(basename "$dump_file")"

    local sock
    sock=$(_detect_socket)

    local dump_args=(
        --single-transaction     # snapshot consistente sin bloquear (BK-003)
        --routines               # incluye stored procedures y funciones
        --triggers               # incluye triggers
        --events                 # incluye eventos del Event Scheduler
        --add-drop-table
        --add-locks
        --extended-insert
        --comments
        --set-charset
        -u"${BACKUP_USER}"
        "${schema}"
    )

    local t_ini
    t_ini=$(date +%s)

    # MYSQL_PWD avoids exposing the password in the process list (ps aux).
    if [[ -n "$sock" ]]; then
        MYSQL_PWD="${BACKUP_PASS}" mysqldump --socket="$sock" "${dump_args[@]}" \
            2>"$stderr_file" | gzip -6 > "$dump_file"
    else
        MYSQL_PWD="${BACKUP_PASS}" mysqldump -h "$DB_HOST" -P "$DB_PORT" "${dump_args[@]}" \
            2>"$stderr_file" | gzip -6 > "$dump_file"
    fi

    local t_fin elapsed dump_size
    t_fin=$(date +%s)
    elapsed=$(( t_fin - t_ini ))
    dump_size=$(du -h "$dump_file" | cut -f1)

    log_info "  Completado: ${dump_size} en ${elapsed}s"

    # Analizar stderr de mysqldump (BK-005)
    if [[ -s "$stderr_file" ]]; then
        log_warn "  mysqldump produjo mensajes en stderr:"
        while IFS= read -r line; do log_warn "    ${line}"; done < "$stderr_file"
    else
        rm -f "$stderr_file"
    fi

    # Verificar integridad del dump (gzip -t)
    if ! gzip -t "$dump_file" 2>/dev/null; then
        log_fatal "  El dump de ${schema} está corrupto. Aborta."
        exit 1
    fi

    # Checksum MD5
    (cd "$BACKUP_DIR" && md5sum "$(basename "$dump_file")") > "$md5_file"

    # Verificar MD5 antes de reportar éxito
    if ! (cd "$BACKUP_DIR" && md5sum -c "$(basename "$md5_file")" >/dev/null 2>&1); then
        log_fatal "  Verificacion MD5 fallida para ${schema}. Aborta."
        exit 1
    fi

    log_success "  ${schema}: dump OK — MD5 verificado"
    log_info "    Dump: $(basename "$dump_file")  (${dump_size})"
    log_info "    MD5:  $(basename "$md5_file")"
}

# =============================================================================
# H-CICLO25-03: Eliminar backups antiguos (retención)
# =============================================================================
_prune_old_backups() {
    log_header "PASO: Retención de backups (>${BACKUP_RETENTION_DAYS} días)"

    local count=0
    # Buscar archivos de backup (.sql.gz, .md5, .log, .mysqldump.stderr)
    # con más de BACKUP_RETENTION_DAYS días y eliminarlos.
    while IFS= read -r -d '' f; do
        log_info "  Eliminando: $(basename "$f")"
        rm -f "$f"
        (( count++ )) || true
    done < <(find "$BACKUP_DIR" -maxdepth 1 \
        \( -name "*.sql.gz" -o -name "*.md5" -o -name "*.log" -o -name "*.mysqldump.stderr" \) \
        -mtime +"${BACKUP_RETENTION_DAYS}" -print0 2>/dev/null)

    if [[ $count -eq 0 ]]; then
        log_info "  Sin backups expirados (retención: ${BACKUP_RETENTION_DAYS} días)"
    else
        log_success "  ${count} archivo(s) expirado(s) eliminado(s)"
    fi
}

# =============================================================================
# Listar backups en BACKUP_DIR
# =============================================================================
_list_backups() {
    log_header "PASO: Backups en ${BACKUP_DIR}"

    if ls "${BACKUP_DIR}"/*.sql.gz >/dev/null 2>&1; then
        ls -lh "${BACKUP_DIR}"/*.sql.gz | awk '{printf "  %s  %s\n", $9, $5}'
    else
        log_info "  Sin backups previos"
    fi
}

# =============================================================================
# Sincronizar a destino remoto (opcional)
# =============================================================================
_sync_remote() {
    log_header "PASO: Sincronizacion remota"

    if [[ -z "${BACKUP_REMOTE_DEST}" ]]; then
        log_info "  BACKUP_REMOTE_DEST no configurado — solo backup local"
        return 0
    fi

    if ! command -v aws &>/dev/null; then
        log_warn "  aws CLI no encontrado — sincronizacion omitida"
        log_warn "  Instala con: pip install awscli"
        return 0
    fi

    # DECISION DE IMPLEMENTACION: aws s3 sync es el mecanismo actual.
    # El proveedor de almacenamiento remoto debe documentarse en un ADR
    # separado (CNST-ARQ-001 P3 v3.0.0 — excepcion para backups).
    log_info "  Sincronizando a ${BACKUP_REMOTE_DEST} ..."
    if aws s3 sync "$BACKUP_DIR" "$BACKUP_REMOTE_DEST" \
            --exclude "*.log" --exclude "*.stderr" \
            2>&1 | while IFS= read -r line; do log_info "    ${line}"; done; then
        log_success "  Sincronizacion completada"
    else
        log_warn "  Sincronizacion remota fallida — backup local disponible"
    fi
}

# =============================================================================
# MAIN
# =============================================================================
mkdir -p "$BACKUP_DIR"

log_header "Backup PracticaYoruba — ${TS}"
log_info "  Schemas:   ${DB_PROD}, ${DB_QA}"
log_info "  Usuario:   ${BACKUP_USER}"
log_info "  Destino:   ${BACKUP_DIR}"
echo ""

_check_mariadb
echo ""

_setup_backup_user
echo ""

log_header "PASO: Inventario de tablas (referencial)"
_log_inventory "$DB_PROD"
echo ""
_log_inventory "$DB_QA"
echo ""

log_header "PASO: Generando dumps"
_dump_schema "$DB_PROD"
echo ""
_dump_schema "$DB_QA"
echo ""

_list_backups
echo ""

_sync_remote
echo ""

_prune_old_backups
echo ""

log_separator 60 "="
log_success "Backup completado: ${TS}"
log_info "  Log: ${LOG_FILE}"
