#!/bin/bash
# =============================================================================
# scripts/backup_media.sh
# Backup del árbol de media (uploads) de PracticaYoruba
# =============================================================================
# Cierra la brecha H-KRU-02 (diseño Kruchten K2): backup_db.sh respalda SOLO
# los schemas MariaDB (practicayoruba_db, practicayoruba_qa); los archivos
# subidos por usuarios (imágenes de producto, etc.) viven en MEDIA_ROOT y NO
# se respaldaban.  Un restore de solo-BD perdería todos los uploads.
#
# media + db son DOS respaldos COMPLEMENTARIOS:
#   scripts/backup_db.sh     — schemas MariaDB (dump SQL gzip + MD5)
#   scripts/backup_media.sh  — árbol de media (tar.gz + MD5)   ← este script
# Un restore completo requiere AMBOS.
#
# MEDIA_ROOT por entorno (api/config/settings):
#   producción → /srv/data/practicayoruba/media   (production.py:127)
#   desarrollo → BASE_DIR/media
#
# Genera por ejecución:
#   backups/<timestamp>_media.tar.gz    tar comprimido (gzip) del árbol media
#   backups/<timestamp>_media.md5        checksum MD5 del tar
#   backups/<timestamp>_media.log        log de operación (resumen)
#
# El timestamp usa TZ America/Mexico_City (zona horaria del proyecto),
# formato YYYYMMDD_HHMMSS — idéntico a backup_db.sh (H-F1-004, H-F4-002).
#
# RETENCIÓN (H-CICLO25-03):
#   Los archivos _media.tar.gz / _media.md5 / _media.log con más de
#   BACKUP_RETENTION_DAYS días (default 30) se eliminan al final de cada
#   ejecución.  Misma política que backup_db.sh.
#
# CASO MEDIA_ROOT vacío / inexistente:
#   En dev puede no haber media aún.  No es un error fatal: el script
#   emite un warning y termina con exit 0 SIN crear un tar corrupto.
#
# Uso:
#   bash scripts/backup_media.sh
#
# Variables del entorno / .env:
#   MEDIA_ROOT             ruta del árbol media (default /srv/data/practicayoruba/media)
#   BACKUP_DIR            destino de los backups (default ${PROJECT_ROOT}/backups)
#   BACKUP_RETENTION_DAYS días de retención (default 30)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/utils/logging.sh"
source "${PROJECT_ROOT}/utils/core.sh"

# =============================================================================
# Cargar .env (opcional)
# =============================================================================
# A diferencia de backup_db.sh (que requiere credenciales de BD del .env),
# el backup de media solo necesita rutas del filesystem que pueden venir del
# entorno directo.  Si existe .env, se carga para tomar overrides de
# MEDIA_ROOT / BACKUP_DIR / BACKUP_RETENTION_DAYS; si no existe, se continúa
# con los defaults y/o las variables ya presentes en el entorno.
#
# PRECEDENCIA: variable de entorno explícita > .env > default.  Capturamos
# los valores ya presentes en el entorno ANTES de sourcear .env para que un
# override explícito (p. ej. MEDIA_ROOT=... bash scripts/backup_media.sh) gane
# sobre el valor del .env, en lugar de ser pisado por él.
_ENV_MEDIA_ROOT="${MEDIA_ROOT:-}"
_ENV_BACKUP_DIR="${BACKUP_DIR:-}"
_ENV_RETENTION="${BACKUP_RETENTION_DAYS:-}"

ENV_FILE="${PROJECT_ROOT}/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
fi

# Restaurar los overrides explícitos del entorno (si los había).
[[ -n "$_ENV_MEDIA_ROOT" ]] && MEDIA_ROOT="$_ENV_MEDIA_ROOT"
[[ -n "$_ENV_BACKUP_DIR" ]] && BACKUP_DIR="$_ENV_BACKUP_DIR"
[[ -n "$_ENV_RETENTION" ]] && BACKUP_RETENTION_DAYS="$_ENV_RETENTION"

# =============================================================================
# Configuración
# =============================================================================
MEDIA_ROOT="${MEDIA_ROOT:-/srv/data/practicayoruba/media}"
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_ROOT}/backups}"
# H-CICLO25-03: retención de backups.  Los archivos _media.tar.gz, _media.md5
# y _media.log con más de BACKUP_RETENTION_DAYS días se eliminan al final de
# cada ejecución.  Default: 30 días.  Sobreescribir con BACKUP_RETENTION_DAYS
# en .env o el entorno para ajustar la política de retención.
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

# Timestamp en zona horaria del proyecto (H-F1-004, H-F4-002)
TS=$(TZ="America/Mexico_City" date +"%Y%m%d_%H%M%S")

TAR_FILE="${BACKUP_DIR}/${TS}_media.tar.gz"
MD5_FILE="${BACKUP_DIR}/${TS}_media.md5"
LOG_FILE="${BACKUP_DIR}/${TS}_media.log"

# =============================================================================
# Resumen al log de operación (backups/<ts>_media.log)
# =============================================================================
# Apende una línea al log de la ejecución (distinto del log global de
# init_log).  Centraliza el resumen pedido en H-KRU-02.
_op_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

init_log "backup_media_${TS}"

# =============================================================================
# MAIN
# =============================================================================
mkdir -p "$BACKUP_DIR"

log_header "Backup media PracticaYoruba — ${TS}"
log_info "  MEDIA_ROOT: ${MEDIA_ROOT}"
log_info "  Destino:    ${BACKUP_DIR}"
log_info "  Retención:  ${BACKUP_RETENTION_DAYS} días"
echo ""
_op_log "INICIO backup media — MEDIA_ROOT=${MEDIA_ROOT} BACKUP_DIR=${BACKUP_DIR}"

# -----------------------------------------------------------------------------
# Caso MEDIA_ROOT inexistente o vacío → warn + exit 0 (no fatal, no tar corrupto)
# -----------------------------------------------------------------------------
if [[ ! -d "$MEDIA_ROOT" ]]; then
    log_warn "MEDIA_ROOT no existe: ${MEDIA_ROOT}"
    log_warn "  En dev puede no haber media aún. Nada que respaldar — exit 0."
    _op_log "WARN MEDIA_ROOT inexistente: ${MEDIA_ROOT} — sin backup (exit 0)"
    log_separator 60 "="
    log_success "Sin media que respaldar: ${TS}"
    exit 0
fi

# Contar archivos regulares dentro de MEDIA_ROOT (cifra verificada — H-KRU-02)
FILE_COUNT=$(find "$MEDIA_ROOT" -type f 2>/dev/null | wc -l | tr -d ' ')

if [[ "$FILE_COUNT" -eq 0 ]]; then
    log_warn "MEDIA_ROOT está vacío: ${MEDIA_ROOT} (0 archivos)"
    log_warn "  Nada que respaldar — exit 0 (no se crea tar corrupto)."
    _op_log "WARN MEDIA_ROOT vacío: ${MEDIA_ROOT} — sin backup (exit 0)"
    log_separator 60 "="
    log_success "Sin media que respaldar: ${TS}"
    exit 0
fi

# -----------------------------------------------------------------------------
# Generar tar.gz del árbol media
# -----------------------------------------------------------------------------
log_header "PASO: Generando tar.gz del árbol media"

# Empaquetar relativo al parent de MEDIA_ROOT para preservar el nombre del
# directorio media dentro del tar (restore predecible).
MEDIA_PARENT="$(cd "$MEDIA_ROOT" && cd .. && pwd)"
MEDIA_BASE="$(basename "$MEDIA_ROOT")"

log_info "  Empaquetando ${FILE_COUNT} archivo(s) de ${MEDIA_ROOT}"
log_info "  → $(basename "$TAR_FILE")"

start_timer

# tar usa gzip interno (-z). El errexit (set -e) aborta si tar falla.
tar -czf "$TAR_FILE" -C "$MEDIA_PARENT" "$MEDIA_BASE"

ELAPSED=$(show_elapsed)
TAR_SIZE=$(du -h "$TAR_FILE" | cut -f1)

log_info "  Completado: ${TAR_SIZE} en ${ELAPSED}"

# Verificar integridad del tar.gz (gzip -t + listado tar)
if ! gzip -t "$TAR_FILE" 2>/dev/null; then
    log_fatal "  El tar de media está corrupto (gzip -t). Aborta."
    _op_log "FATAL tar corrupto: ${TAR_FILE}"
    rm -f "$TAR_FILE"
    exit 1
fi
if ! tar -tzf "$TAR_FILE" >/dev/null 2>&1; then
    log_fatal "  El tar de media no se puede listar. Aborta."
    _op_log "FATAL tar ilegible: ${TAR_FILE}"
    rm -f "$TAR_FILE"
    exit 1
fi

# -----------------------------------------------------------------------------
# Checksum MD5
# -----------------------------------------------------------------------------
(cd "$BACKUP_DIR" && md5sum "$(basename "$TAR_FILE")") > "$MD5_FILE"

# Verificar MD5 antes de reportar éxito
if ! (cd "$BACKUP_DIR" && md5sum -c "$(basename "$MD5_FILE")" >/dev/null 2>&1); then
    log_fatal "  Verificación MD5 fallida para media. Aborta."
    _op_log "FATAL MD5 fallido: ${MD5_FILE}"
    exit 1
fi

MD5_SUM=$(cut -d' ' -f1 "$MD5_FILE")

log_success "  media: tar OK — MD5 verificado"
log_info "    Tar: $(basename "$TAR_FILE")  (${TAR_SIZE}, ${FILE_COUNT} archivos)"
log_info "    MD5: $(basename "$MD5_FILE")  (${MD5_SUM})"

_op_log "OK tar=$(basename "$TAR_FILE") size=${TAR_SIZE} archivos=${FILE_COUNT} md5=${MD5_SUM}"
echo ""

# =============================================================================
# H-CICLO25-03: Eliminar backups antiguos (retención)
# =============================================================================
log_header "PASO: Retención de backups de media (>${BACKUP_RETENTION_DAYS} días)"

PRUNE_COUNT=0
while IFS= read -r -d '' f; do
    log_info "  Eliminando: $(basename "$f")"
    rm -f "$f"
    (( PRUNE_COUNT++ )) || true
done < <(find "$BACKUP_DIR" -maxdepth 1 \
    \( -name "*_media.tar.gz" -o -name "*_media.md5" -o -name "*_media.log" \) \
    -mtime +"${BACKUP_RETENTION_DAYS}" -print0 2>/dev/null)

if [[ $PRUNE_COUNT -eq 0 ]]; then
    log_info "  Sin backups de media expirados (retención: ${BACKUP_RETENTION_DAYS} días)"
else
    log_success "  ${PRUNE_COUNT} archivo(s) de media expirado(s) eliminado(s)"
fi
_op_log "RETENCION expirados_eliminados=${PRUNE_COUNT} dias=${BACKUP_RETENTION_DAYS}"
echo ""

log_separator 60 "="
log_success "Backup de media completado: ${TS}"
log_info "  Tar: ${TAR_FILE}"
log_info "  MD5: ${MD5_FILE}"
log_info "  Log: ${LOG_FILE}"
_op_log "FIN backup media OK"
