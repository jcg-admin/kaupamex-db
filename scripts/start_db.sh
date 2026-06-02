#!/bin/bash
# =============================================================================
# scripts/start_db.sh — Arranque rápido de MariaDB para entornos sin systemd
# =============================================================================
#
# Patrón adaptado de IACT-db (mysqld_safe) para MariaDB 11.8 en Ubuntu 24.04.
# En MariaDB 11.8, mysqld_safe está deprecated — se usa mariadbd directamente
# con nohup + su mysql, igual que IACT-db pero con el binario correcto.
#
# Flujo:
#   1. Si MariaDB ya responde → informa y sale (idempotente)
#   2. Limpia archivos pid/sock de sesiones muertas (stale cleanup)
#   3. Arranca mariadbd con nohup como usuario mysql
#   4. Espera activa máx. 20 iteraciones de 1s (patrón IACT-db)
#   5. Ejecuta verify.sh y muestra solo las líneas de OK/WARN/ERROR
#
# Uso:
#   bash scripts/start_db.sh            # arranque completo + verify
#   bash scripts/start_db.sh --no-verify  # solo arrancar, sin verify
#
# Variables leídas desde .env en la raíz del repositorio.
#
# Adaptaciones respecto al patrón IACT-db:
#   - mysqld_safe → mariadbd directo (deprecated en MariaDB 11.8)
#   - nohup su -s /bin/bash mysql -c "..." (contenedor sin sudo)
#   - timestamp en log: /tmp/mariadbd-{timestamp}.log
#   - Verificación usa scripts/verify.sh de este mismo repo
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/utils/logging.sh"
source "${PROJECT_ROOT}/utils/network.sh"
source "${PROJECT_ROOT}/utils/database.sh"

# ─── Configuración ────────────────────────────────────────────────────────────
DAEMON=""
for bin in /usr/sbin/mariadbd /usr/sbin/mysqld /usr/bin/mariadbd; do
    [[ -x "$bin" ]] && DAEMON="$bin" && break
done

SOCKET="/run/mysqld/mysqld.sock"
PID_FILE="/run/mysqld/mysqld.pid"
TIMESTAMP="$(date +%Y%m%dT%H%M%S)"
LOG_FILE="/tmp/mariadbd-${TIMESTAMP}.log"
NO_VERIFY="${1:-}"

# ─── 1. Verificar si ya está corriendo ────────────────────────────────────────
if mariadb_is_running; then
    log_success "MariaDB ya está activo — nada que hacer"
    if [[ "$NO_VERIFY" != "--no-verify" ]]; then
        log_info "Ejecutando verify.sh..."
        export PROJECT_ROOT
        bash "${SCRIPT_DIR}/verify.sh" 2>/dev/null \
            | sed 's/\x1b\[[0-9;]*m//g' \
            | grep -E "OK:|WARN:|ERROR:|Errores:" || true
    fi
    exit 0
fi

# ─── 2. Cleanup de archivos stale ─────────────────────────────────────────────
log_info "MariaDB no responde. Limpiando archivos stale..."
mariadb_cleanup_stale

# ─── 3. Arrancar mariadbd ─────────────────────────────────────────────────────
if [[ -z "$DAEMON" ]]; then
    log_error "No se encontró el daemon de MariaDB en rutas conocidas"
    exit 1
fi

log_info "Arrancando ${DAEMON} (sin systemd, log → ${LOG_FILE})..."

nohup su -s /bin/bash mysql -c \
    "${DAEMON} \
     --datadir=/var/lib/mysql \
     --socket=${SOCKET} \
     --pid-file=${PID_FILE} \
     --tmpdir=${MARIADB_TMPDIR:-/tmp} \
     --bind-address=127.0.0.1 \
     --port=3306" \
    > "${LOG_FILE}" 2>&1 &

# ─── 4. Espera activa — patrón IACT-db (max 20 × 1s) ─────────────────────────
for i in $(seq 1 20); do
    sleep 1
    if "$(mariadb_admin_bin)" --socket="${SOCKET}" ping --silent 2>/dev/null; then
        log_success "MariaDB OK en ${i}s"
        break
    fi
    if [[ "$i" -eq 20 ]]; then
        log_error "MariaDB no respondió en 20s — revisa ${LOG_FILE}"
        tail -5 "${LOG_FILE}" || true
        exit 1
    fi
done

# ─── 5. Verificar entorno ─────────────────────────────────────────────────────
if [[ "$NO_VERIFY" != "--no-verify" ]]; then
    log_info "Ejecutando verify.sh..."
    export PROJECT_ROOT
    bash "${SCRIPT_DIR}/verify.sh" 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -E "OK:|WARN:|ERROR:|Errores:" || true
fi
