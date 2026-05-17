#!/usr/bin/env bash
# =============================================================================
# backup_proyectos.sh — Backup completo de los tres repositorios PracticaYoruba
# =============================================================================
# Genera por cada repo:
#   - git bundle  (restaurable con git clone <bundle>)
#   - tar.gz      (extracción directa, incluye .git)
#   - MD5 checksums verificados
#   - MANIFEST con metadatos del backup
#
# Uso:
#   bash scripts/backup_proyectos.sh [/ruta/origen] [/ruta/destino]
#
# Defaults:
#   ORIGEN:  /tmp/project
#   DESTINO: backups/proyectos/<TIMESTAMP>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

ORIGEN="${1:-/tmp/project}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_BASE="${2:-${REPO_ROOT}/backups/proyectos}"
BACKUP_DIR="${BACKUP_BASE}/${TIMESTAMP}"
LOG="${BACKUP_DIR}/backup.log"
CHECKSUMS="${BACKUP_DIR}/${TIMESTAMP}_checksums.md5"
MANIFEST="${BACKUP_DIR}/${TIMESTAMP}_MANIFEST.txt"

# Nombres de directorio de repos hermanos — configurable via BACKUP_REPOS en .env
# Default: nombres reales de los repos en GitHub (resultado de git clone sin destino)
BACKUP_REPOS_DEFAULT="e-comerce-api e-comerce-docs e-comerce-ui"

# Cargar .env si existe
ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

REPO_SOURCE="${BACKUP_REPOS:-}"
if [[ -z "${REPO_SOURCE//[[:space:]]/}" ]]; then
    REPO_SOURCE="$BACKUP_REPOS_DEFAULT"
fi

REPOS=()
while IFS= read -r repo; do
    [[ -n "$repo" ]] && REPOS+=("$repo")
done < <(printf '%s' "$REPO_SOURCE" | tr -s '[:space:]' '\n')

if [[ ${#REPOS[@]} -eq 0 ]]; then
    echo "ERROR: BACKUP_REPOS no contiene repositorios válidos." >&2
    exit 1
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

mkdir -p "$BACKUP_DIR"
log "=== INICIO BACKUP — PracticaYoruba Proyectos ==="
log "Origen:  $ORIGEN"
log "Destino: $BACKUP_DIR"
echo "" | tee -a "$LOG"

# ── Bundles git ───────────────────────────────────────────────────────────────
for repo in "${REPOS[@]}"; do
    log "[bundle] $repo ..."
    git -C "${ORIGEN}/${repo}" bundle create \
        "${BACKUP_DIR}/${TIMESTAMP}_${repo}.bundle" \
        --all
    git bundle verify "${BACKUP_DIR}/${TIMESTAMP}_${repo}.bundle" | \
        grep -E "bundle|valid" | tee -a "$LOG"
    log "OK: $repo bundle verificado"
done

echo "" | tee -a "$LOG"

# ── tar.gz ────────────────────────────────────────────────────────────────────
for repo in "${REPOS[@]}"; do
    log "[tar.gz] $repo ..."
    tar -czf "${BACKUP_DIR}/${TIMESTAMP}_${repo}.tar.gz" \
        -C "$ORIGEN" "$repo"
    SIZE=$(du -sh "${BACKUP_DIR}/${TIMESTAMP}_${repo}.tar.gz" | cut -f1)
    log "OK: ${repo}.tar.gz — $SIZE"
done

echo "" | tee -a "$LOG"

# ── MD5 checksums ─────────────────────────────────────────────────────────────
log "Generando checksums MD5..."
cd "$BACKUP_DIR"
md5sum ${TIMESTAMP}_*.bundle ${TIMESTAMP}_*.tar.gz > "$CHECKSUMS"

log "Verificando checksums..."
md5sum -c "$CHECKSUMS" | tee -a "$LOG"
log "VERIFICACION EXITOSA"

echo "" | tee -a "$LOG"
log "Artefactos generados en: $BACKUP_DIR"
log "=== FIN BACKUP ==="
