#!/bin/bash
# =============================================================================
# utils/core.sh — Funciones utilitarias core — Kaupamex-db
# =============================================================================
# Portado desde Kaupamex-api/scripts/utils/core.sh sin cambios
# funcionales — no contiene referencias al dominio de la API.
#
# Nota: provisioning.sh (apt_update, install_apt_packages, setup_venv)
# no se porta porque Kaupamex-db no gestiona paquetes del sistema
# ni entornos virtuales Python. (Hallazgo H-F2-002)
#
# Depende de: logging.sh
#
# Provee:
#   command_exists <cmd>
#   require_command <cmd>
#   exists_file <path>
#   exists_dir  <path>
# =============================================================================

# -----------------------------------------------------------------------------
# command_exists <cmd>
#   Retorna 0 si el comando existe en PATH, 1 si no.
# -----------------------------------------------------------------------------
command_exists() {
    command -v "$1" &>/dev/null
}

# -----------------------------------------------------------------------------
# require_command <cmd>
#   Igual que command_exists pero emite log_warn si el comando no existe.
# -----------------------------------------------------------------------------
require_command() {
    local cmd="$1"
    if ! command_exists "$cmd"; then
        log_warn "Comando no encontrado: ${cmd}"
        return 1
    fi
    return 0
}

exists_file() { [[ -f "$1" ]]; }
exists_dir()  { [[ -d "$1" ]]; }
