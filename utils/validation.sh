#!/bin/bash
# =============================================================================
# utils/validation.sh — Funciones de validación — PracticaYoruba-db
# =============================================================================
# Portado desde PracticaYoruba-api/scripts/utils/validation.sh sin cambios
# funcionales — no contiene referencias al dominio de la API.
#
# Depende de: logging.sh, core.sh
#
# Provee:
#   validate_root
#   validate_ubuntu [version_prefix]
#   validate_python_version [major] [minor]
# =============================================================================

# -----------------------------------------------------------------------------
# validate_root
#   Retorna 0 si el proceso corre como root (EUID=0), 1 si no.
#   Los scripts de provisioning (db_setup.sh, db_qa_setup.sh) requieren root
#   para operar sobre MariaDB como usuario administrador sin contraseña.
# -----------------------------------------------------------------------------
validate_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script debe ejecutarse como root (usa sudo)"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# validate_ubuntu [version_prefix]
#   Verifica que el SO es Ubuntu y que la versión comienza con version_prefix.
#   Default: "24.04"
# -----------------------------------------------------------------------------
validate_ubuntu() {
    local required_prefix="${1:-24.04}"
    local os_release="/etc/os-release"

    [[ -f "$os_release" ]] || { log_error "No se encontro ${os_release}"; return 1; }

    local os_id os_version_id
    os_id=$(. "$os_release" && echo "${ID:-}")
    os_version_id=$(. "$os_release" && echo "${VERSION_ID:-}")

    [[ "${os_id,,}" == "ubuntu" ]] || { log_error "SO incompatible: ${os_id}"; return 1; }
    [[ "${os_version_id}" == "${required_prefix}"* ]] || {
        log_error "Version incompatible: Ubuntu ${os_version_id} (se requiere ${required_prefix}.x)"
        return 1
    }
    return 0
}

# -----------------------------------------------------------------------------
# validate_python_version [major] [minor]
#   Verifica que python3 existe y cumple la versión mínima requerida.
#   Default: 3.11
#   Usado por scripts/check_db.py como prerequisito.
# -----------------------------------------------------------------------------
validate_python_version() {
    local required_major="${1:-3}" required_minor="${2:-11}"

    require_command python3 || return 1

    local major minor
    major=$(python3 -c "import sys; print(sys.version_info.major)")
    minor=$(python3 -c "import sys; print(sys.version_info.minor)")

    if (( major < required_major )) || (( major == required_major && minor < required_minor )); then
        log_error "Python ${major}.${minor} no cumple el minimo: ${required_major}.${required_minor}+"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# validate_mariadb_version [required_major] [required_minor]
#   Verifica que el binario mysql instalado es MariaDB y cumple la serie
#   required_major.required_minor.x
#   Default: 11.8 (ADR-009)
#
#   No requiere que el servidor esté corriendo — lee la versión del binario.
#   Retorna 0 si la versión es correcta, 1 si no está instalado, si es MySQL
#   en lugar de MariaDB, o si la serie no coincide.
# -----------------------------------------------------------------------------
validate_mariadb_version() {
    local required_major="${1:-11}" required_minor="${2:-8}"

    require_command mysql || {
        log_error "mysql CLI no encontrado — MariaDB no está instalado"
        return 1
    }

    # Obtener la cadena de versión del binario (no requiere servidor activo)
    local version_str
    version_str=$(mysql --version 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-MariaDB' \
        | head -1)

    if [[ -z "$version_str" ]]; then
        # Puede ser MySQL (sin el sufijo -MariaDB)
        local raw
        raw=$(mysql --version 2>/dev/null || echo "")
        log_error "El motor instalado no es MariaDB o no se pudo leer la versión"
        log_error "  Salida: ${raw}"
        log_error "  Se requiere: MariaDB ${required_major}.${required_minor}.x (ADR-009)"
        return 1
    fi

    local installed_major installed_minor
    installed_major=$(echo "$version_str" | cut -d. -f1)
    installed_minor=$(echo "$version_str" | cut -d. -f2)

    if [[ "${installed_major}" != "${required_major}" ]] || \
       [[ "${installed_minor}" != "${required_minor}" ]]; then
        log_error "Version instalada: ${version_str}"
        log_error "Se requiere: MariaDB ${required_major}.${required_minor}.x (ADR-009)"
        log_error "  Migra con: sudo bash provisioners/mariadb/install.sh"
        return 1
    fi

    return 0
}
