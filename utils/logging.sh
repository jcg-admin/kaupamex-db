#!/bin/bash
# =============================================================================
# utils/logging.sh — Funciones de logging — PracticaYoruba-db
# =============================================================================
# Portado desde PracticaYoruba-api/scripts/utils/logging.sh.
#
# Adaptación respecto al original:
#   init_log usa ${PROJECT_ROOT}/logs en lugar de
#   ${PROJECT_ROOT}/practicayoruba/logs — en PracticaYoruba-db no
#   existe el subdirectorio practicayoruba/.
#   (Hallazgo H-F2-001)
#
# Provee:
#   log_header, log_step, log_success, log_info, log_warn,
#   log_fatal, log_error, log_separator, start_timer, show_elapsed,
#   init_log
#
# Uso:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"
# =============================================================================

# Colores — solo en terminal interactiva
if [[ -t 1 ]]; then
    _CLR_RESET="\033[0m"
    _CLR_GREEN="\033[0;32m"
    _CLR_YELLOW="\033[0;33m"
    _CLR_RED="\033[0;31m"
    _CLR_CYAN="\033[0;36m"
    _CLR_BOLD="\033[1m"
else
    _CLR_RESET=""
    _CLR_GREEN=""
    _CLR_YELLOW=""
    _CLR_RED=""
    _CLR_CYAN=""
    _CLR_BOLD=""
fi

_TIMER_START=""
_LOG_FILE=""

# -----------------------------------------------------------------------------
# init_log <nombre>
#   Inicializa el archivo de log en ${PROJECT_ROOT}/logs/<nombre>.log.
#   Crea el directorio si no existe.
# -----------------------------------------------------------------------------
init_log() {
    local name="${1:-script}"
    local log_dir="${PROJECT_ROOT}/logs"
    mkdir -p "$log_dir"
    _LOG_FILE="${log_dir}/${name}.log"
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') — Inicio ===" >> "$_LOG_FILE"
}

_write_log() {
    [[ -n "$_LOG_FILE" ]] && echo "$(date '+%H:%M:%S') $*" >> "$_LOG_FILE" || true
}

log_header() {
    echo ""
    echo -e "${_CLR_BOLD}${_CLR_CYAN}>>> $*${_CLR_RESET}"
    echo ""
    _write_log "HEADER $*"
}

log_step() {
    local current="$1" total="$2"
    shift 2
    echo -e "${_CLR_BOLD}[${current}/${total}]${_CLR_RESET} $*"
    _write_log "STEP [${current}/${total}] $*"
}

log_success() {
    echo -e "${_CLR_GREEN}  OK${_CLR_RESET}  $*"
    _write_log "OK   $*"
}

log_info() {
    echo -e "  --  $*"
    _write_log "INFO $*"
}

log_warn() {
    echo -e "${_CLR_YELLOW}WARN${_CLR_RESET}  $*"
    _write_log "WARN $*"
}

log_error() {
    echo -e "${_CLR_RED}ERR ${_CLR_RESET}  $*" >&2
    _write_log "ERR  $*"
}

log_fatal() {
    echo -e "${_CLR_BOLD}${_CLR_RED}FATAL${_CLR_RESET}  $*" >&2
    _write_log "FATAL $*"
}

log_separator() {
    local len="${1:-60}" char="${2:--}"
    local line
    line=$(printf '%*s' "$len" '' | tr ' ' "$char")
    echo "$line"
    _write_log "$line"
}

start_timer() {
    _TIMER_START=$(date +%s)
}

show_elapsed() {
    [[ -z "$_TIMER_START" ]] && echo "0s" && return
    local elapsed=$(( $(date +%s) - _TIMER_START ))
    (( elapsed < 60 )) && echo "${elapsed}s" || echo "$(( elapsed/60 ))m $(( elapsed%60 ))s"
}
