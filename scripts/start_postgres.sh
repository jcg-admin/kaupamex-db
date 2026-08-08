#!/bin/bash
# =============================================================================
# scripts/start_postgres.sh — Arranque idempotente de PostgreSQL
# =============================================================================
#
# Equivalente de ``start_db.sh`` para el motor en uso (ADR-028). NO es una
# traducción de aquel: la forma cambia porque el motor se opera distinto.
#
#   | MariaDB (start_db.sh)              | PostgreSQL (aquí)                |
#   |------------------------------------|----------------------------------|
#   | ``nohup su mysql -c mariadbd …``   | ``pg_ctlcluster <ver> <name>``   |
#   | flags de datadir/socket/pid        | los toma del cluster registrado  |
#   | limpieza de pid/sock stale         | la hace el wrapper del cluster   |
#
# En Debian/Ubuntu PostgreSQL se opera **por cluster**, no por proceso suelto:
# ``initdb``, ``pg_ctl`` y ``postgres`` NO están en ``PATH`` a propósito —
# ``pg_wrapper`` expone en su lugar ``pg_ctlcluster``, ``pg_lsclusters`` y
# ``pg_conftool``. Inventar aquí un arranque a mano del binario sería pelearse
# con el empaquetado del distro para reimplementar lo que ya resuelve.
#
# Nombre del archivo: explícito, no genérico. ``start_db.sh`` se queda con
# MariaDB — está citado en docs, reglas de agente y el runbook E2E de ``ui``,
# y renombrarlo rompería esas referencias por un beneficio de nomenclatura.
# Mismo criterio que ``utils/postgresql.sh`` al lado de ``utils/database.sh``.
#
# Flujo:
#   1. Si el servidor ya responde → informa y sale (idempotente)
#   2. Arranca el cluster (systemd si está; si no, pg_ctlcluster)
#   3. Espera activa hasta 20 s
#   4. GATE: verifica el mínimo efectivo (14 — ver utils/postgresql.sh)
#   5. Ejecuta verify_postgres.sh y muestra solo OK/WARN/ERROR
#
# Uso:
#   bash scripts/start_postgres.sh              # arranque + verify
#   bash scripts/start_postgres.sh --no-verify  # solo arrancar
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/utils/logging.sh"
source "${PROJECT_ROOT}/utils/postgresql.sh"

NO_VERIFY="${1:-}"

run_verify() {
    [[ "$NO_VERIFY" == "--no-verify" ]] && return 0
    log_info "Ejecutando verify_postgres.sh..."
    export PROJECT_ROOT
    bash "${SCRIPT_DIR}/verify_postgres.sh" 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -E "OK:|WARN:|ERROR:|Errores:" || true
}

# ─── 1. ¿Ya responde? ────────────────────────────────────────────────────────
if postgres_is_running; then
    log_success "PostgreSQL ya está activo — nada que hacer"
    log_info "$(postgres_meets_minimum || true)"
    run_verify
    exit 0
fi

# ─── 2 y 3. Arrancar el cluster + espera activa ──────────────────────────────
log_info "PostgreSQL no responde. Arrancando el cluster..."

if ! command -v pg_ctlcluster &>/dev/null; then
    log_error "pg_ctlcluster no está — ¿PostgreSQL instalado?"
    log_error "  Instálalo con: sudo bash provisioners/postgresql/install.sh"
    exit 1
fi

if ! postgres_start; then
    log_error "El cluster no respondió en 20 s"
    log_error "  Diagnóstico: pg_lsclusters"
    pg_lsclusters 2>/dev/null || true
    log_error "  Log del cluster: /var/log/postgresql/postgresql-<ver>-<name>.log"
    exit 1
fi

log_success "PostgreSQL responde en $(postgres_socket_dir)"

# ─── 4. GATE del mínimo efectivo ─────────────────────────────────────────────
# Se verifica DESPUÉS de arrancar porque el mínimo es del servidor en
# ejecución, no del paquete instalado: con varios clusters pueden diferir.
if minimo="$(postgres_meets_minimum)"; then
    log_success "$minimo"
else
    log_error "$minimo"
    log_error "  Django 6 ABORTA la conexión por debajo de 14, no avisa"
    log_error "  (django/db/backends/postgresql/features.py:10)"
    exit 1
fi

# ─── 5. Verificar el entorno ─────────────────────────────────────────────────
run_verify
