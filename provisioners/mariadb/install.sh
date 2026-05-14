#!/bin/bash
# =============================================================================
# provisioners/mariadb/install.sh
# Instala MariaDB 11.8 LTS o migra desde una versión incorrecta
# =============================================================================
# IDEMPOTENTE: si MariaDB 11.8.x ya está instalado, no hace nada.
#
# Escenarios:
#   A) MariaDB no instalado      → instala 11.8 directamente
#   B) MariaDB 11.8.x instalado  → no-op, reporta OK
#   C) Versión incorrecta        → DETIENE y muestra instrucciones
#                                  a menos que se pase --migrate
#
# Uso:
#   sudo bash provisioners/mariadb/install.sh
#   sudo bash provisioners/mariadb/install.sh --migrate   # purga e instala
#
# Por qué se detiene ante versión incorrecta (sin --migrate):
#   Purgar una instalación existente ELIMINA los datos de MariaDB en
#   /var/lib/mysql. Hacer esto automáticamente sin confirmación explícita
#   es destructivo. El flag --migrate es la confirmación del operador de
#   que ha hecho backup y acepta la pérdida de datos de la versión anterior.
#
# Variables del .env (opcionales, con defaults):
#   DB_HOST, DB_PORT
#
# Requiere: root, Ubuntu 20.04+, conexión a internet (para descargar el repo)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${PROJECT_ROOT}/utils/logging.sh"
source "${PROJECT_ROOT}/utils/core.sh"
source "${PROJECT_ROOT}/utils/network.sh"
source "${PROJECT_ROOT}/utils/database.sh"
source "${PROJECT_ROOT}/utils/validation.sh"

# La serie objetivo es fija: ADR-009 establece MariaDB 11.8 LTS
readonly MARIADB_TARGET_MAJOR="11"
readonly MARIADB_TARGET_MINOR="8"
readonly MARIADB_TARGET_SERIES="${MARIADB_TARGET_MAJOR}.${MARIADB_TARGET_MINOR}"

# Flag de migración: falso por defecto (protege datos)
ALLOW_MIGRATE=false
for arg in "$@"; do
    [[ "$arg" == "--migrate" ]] && ALLOW_MIGRATE=true
done

# =============================================================================
# Cargar .env si existe (opcional para este provisioner)
# =============================================================================
ENV_FILE="${PROJECT_ROOT}/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
fi

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"

# =============================================================================
# Helpers de apt — privados, solo para este script
# =============================================================================
_apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" 2>&1
}

_apt_purge() {
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "$@" 2>/dev/null || true
}

# =============================================================================
# Detectar versión instalada
# =============================================================================
_detect_installed_version() {
    # Retorna "major.minor.patch-MariaDB" o cadena vacía si no hay MariaDB
    # También retorna vacío si hay MySQL (sin sufijo -MariaDB)
    mysql --version 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-MariaDB' \
        | head -1 \
        || echo ""
}

_detect_installed_series() {
    local version
    version=$(_detect_installed_version)
    [[ -z "$version" ]] && echo "" && return
    echo "$version" | grep -oE '^[0-9]+\.[0-9]+'
}

# =============================================================================
# PASO: Verificar requisitos
# =============================================================================
_check_requisites() {
    log_header "PASO: Verificando requisitos"

    validate_root || {
        log_fatal "Este script requiere root: sudo bash provisioners/mariadb/install.sh"
        exit 1
    }
    ok "Corriendo como root"

    # Ubuntu requerido (apt-based)
    if ! command_exists apt-get; then
        log_fatal "Este script requiere apt (Ubuntu/Debian)"
        exit 1
    fi
    ok "apt disponible"

    # Conexión a internet (para descargar repo si es necesario)
    if ! tcp_is_reachable "downloads.mariadb.com" 443 5; then
        log_warn "Sin acceso a downloads.mariadb.com:443"
        log_warn "  El repo de MariaDB.org puede no ser alcanzable"
        log_warn "  Si el paquete ya está en los repos del sistema, puede continuar"
    else
        ok "Acceso a downloads.mariadb.com"
    fi
}

# =============================================================================
# PASO: Detectar versión actual
# =============================================================================
_check_current_version() {
    log_header "PASO: Detectando versión instalada"

    local installed_version installed_series
    installed_version=$(_detect_installed_version)
    installed_series=$(_detect_installed_series)

    if [[ -z "$installed_version" ]]; then
        # Verificar si hay MySQL (no MariaDB)
        local raw_version
        raw_version=$(mysql --version 2>/dev/null || echo "")
        if [[ -n "$raw_version" ]]; then
            log_warn "mysql encontrado pero no es MariaDB: ${raw_version}"
            log_warn "  Este script solo gestiona MariaDB"
            fail "Motor no soportado instalado — instala MariaDB manualmente"
        else
            log_info "MariaDB no instalado — se instalará 11.8 desde cero"
            ok "Sin instalación previa — listo para instalar"
        fi
        return 0
    fi

    log_info "Instalado: MariaDB ${installed_version} (serie ${installed_series})"

    if [[ "$installed_series" == "$MARIADB_TARGET_SERIES" ]]; then
        ok "MariaDB ${installed_version} — serie correcta (${MARIADB_TARGET_SERIES}.x)"
        ok "Idempotente: no se requiere ninguna acción"
        echo ""
        log_separator 60 "="
        log_success "MariaDB ${MARIADB_TARGET_SERIES}.x ya instalado. Sin cambios."
        exit 0
    fi

    # Versión incorrecta
    fail "Serie incorrecta: ${installed_series} (se requiere ${MARIADB_TARGET_SERIES})"
    echo ""

    if [[ "$ALLOW_MIGRATE" == "false" ]]; then
        log_error "======================================================="
        log_error "ACCIÓN REQUERIDA — DATO DESTRUCTIVO"
        log_error "======================================================="
        log_error ""
        log_error "Hay MariaDB ${installed_version} instalado."
        log_error "PracticaYoruba requiere MariaDB ${MARIADB_TARGET_SERIES}.x (ADR-009)."
        log_error ""
        log_error "Para migrar, el script necesita:"
        log_error "  1. Detener el servicio MariaDB"
        log_error "  2. Purgar los paquetes de la versión ${installed_series}"
        log_error "  3. Instalar MariaDB ${MARIADB_TARGET_SERIES}"
        log_error ""
        log_error "ESTO ELIMINA LOS DATOS EN /var/lib/mysql."
        log_error ""
        log_error "Antes de continuar:"
        log_error "  bash scripts/backup_db.sh"
        log_error ""
        log_error "Cuando hayas hecho el backup:"
        log_error "  sudo bash provisioners/mariadb/install.sh --migrate"
        log_error ""
        exit 1
    fi

    log_warn "Flag --migrate detectado — continuando con la purga"
    log_warn "  Versión a purgar: MariaDB ${installed_version}"
    log_warn "  Esperando 5 segundos antes de proceder (Ctrl+C para cancelar)..."
    sleep 5
}

# =============================================================================
# PASO: Purgar versión incorrecta (solo con --migrate)
# =============================================================================
_purge_wrong_version() {
    log_header "PASO: Purgando versión incorrecta"

    local installed_series
    installed_series=$(_detect_installed_series)
    [[ -z "$installed_series" ]] && { log_info "Sin instalación previa — omitiendo purga"; return 0; }

    # Detener el servicio
    log_info "  Deteniendo MariaDB..."
    service mariadb stop 2>/dev/null \
        || systemctl stop mariadb 2>/dev/null \
        || pkill -f mariadbd 2>/dev/null \
        || true
    sleep 2

    # Purgar paquetes de la serie incorrecta
    log_info "  Purgando paquetes..."
    _apt_purge mariadb-server mariadb-client mariadb-common \
        "mariadb-server-${installed_series}" \
        "mariadb-client-${installed_series}" > /dev/null

    # Limpiar repos y pins anteriores
    rm -f /etc/apt/sources.list.d/mariadb.list
    rm -f /etc/apt/preferences.d/mariadb-pin
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null > /dev/null || true

    ok "MariaDB ${installed_series} purgado"
}

# =============================================================================
# PASO: Agregar repositorio MariaDB 11.8
# =============================================================================
_add_mariadb_repo() {
    log_header "PASO: Repositorio MariaDB ${MARIADB_TARGET_SERIES}"

    # Verificar si la versión ya está en repos del sistema
    apt-get update -qq 2>/dev/null || true
    if apt-cache show mariadb-server 2>/dev/null \
            | grep -qE "Version: 1:${MARIADB_TARGET_SERIES}\."; then
        ok "MariaDB ${MARIADB_TARGET_SERIES}.x disponible en repos del sistema"
        return 0
    fi

    log_info "  ${MARIADB_TARGET_SERIES}.x no en repos del sistema — agregando repo oficial"

    # Prereqs
    _apt_install software-properties-common dirmngr \
        apt-transport-https curl gpg > /dev/null

    # Codename del OS (noble, jammy, focal...)
    local codename
    codename=$(lsb_release -cs 2>/dev/null || echo "noble")
    log_info "  Codename OS: ${codename}"

    # GPG key via /usr/share/keyrings/ (apt-key deprecado en Ubuntu 22.04+)
    local keyring="/usr/share/keyrings/mariadb.gpg"
    if ! curl -fsSL https://mariadb.org/mariadb_release_signing_key.asc \
            | gpg --dearmor | tee "$keyring" > /dev/null 2>&1; then
        log_fatal "No se pudo importar la GPG key de MariaDB"
        exit 1
    fi
    log_info "  GPG key importada: ${keyring}"

    # Agregar la fuente
    local repo_file="/etc/apt/sources.list.d/mariadb.list"
    cat > "$repo_file" << EOF
# MariaDB ${MARIADB_TARGET_SERIES} LTS — gestionado por PracticaYoruba-db
# provisioners/mariadb/install.sh
deb [arch=amd64 signed-by=${keyring}] https://downloads.mariadb.com/MariaDB/mariadb-${MARIADB_TARGET_SERIES}/repo/ubuntu ${codename} main
EOF

    apt-get update -qq 2>/dev/null
    ok "Repositorio MariaDB ${MARIADB_TARGET_SERIES} agregado (${repo_file})"
}

# =============================================================================
# PASO: Pinear serie 11.8 (evitar saltos automáticos a 12.x)
# =============================================================================
_pin_mariadb_series() {
    log_header "PASO: Pineando MariaDB ${MARIADB_TARGET_SERIES}.x"

    local pref_file="/etc/apt/preferences.d/mariadb-pin"
    cat > "$pref_file" << EOF
# Pinear MariaDB a la serie ${MARIADB_TARGET_SERIES}.x
# Permite actualizaciones de patch (${MARIADB_TARGET_SERIES}.1 -> ${MARIADB_TARGET_SERIES}.2)
# pero bloquea saltos de serie (${MARIADB_TARGET_SERIES} -> 12.x)
# Generado por: provisioners/mariadb/install.sh
Package: mariadb-server mariadb-client mariadb-common
Pin: version 1:${MARIADB_TARGET_SERIES}.*
Pin-Priority: 1001
EOF

    ok "Serie ${MARIADB_TARGET_SERIES}.x pineada — no actualizará a 12.x automáticamente"
}

# =============================================================================
# PASO: Instalar MariaDB 11.8
# =============================================================================
_install_mariadb() {
    log_header "PASO: Instalando MariaDB ${MARIADB_TARGET_SERIES}"

    export DEBIAN_FRONTEND=noninteractive

    # Actualizar índice antes de instalar
    apt-get update -qq 2>/dev/null || \
        log_warn "  apt-get update retornó error — continuando"

    if ! _apt_install mariadb-server mariadb-client > /dev/null; then
        log_fatal "No se pudo instalar mariadb-server"
        exit 1
    fi

    # Verificar e inicializar datadir si el postinst no lo hizo
    if [[ ! -f /var/lib/mysql/ibdata1 ]]; then
        log_info "  datadir no inicializado — ejecutando inicialización"
        local init_cmd=""
        command_exists mariadb-install-db && init_cmd="mariadb-install-db"
        command_exists mysql_install_db   && init_cmd="mysql_install_db"

        if [[ -z "$init_cmd" ]]; then
            log_fatal "No se encontró mariadb-install-db ni mysql_install_db"
            exit 1
        fi
        "$init_cmd" --user=mysql --datadir=/var/lib/mysql 2>/dev/null
        log_info "  datadir inicializado via ${init_cmd}"
    fi

    # Activar y arrancar el servicio
    systemctl enable mariadb 2>/dev/null \
        || service mariadb enable 2>/dev/null \
        || true

    mariadb_start || {
        log_fatal "MariaDB instalado pero no responde"
        exit 1
    }

    ok "MariaDB ${MARIADB_TARGET_SERIES} instalado y activo"
}

# =============================================================================
# PASO: Verificar versión instalada
# =============================================================================
_verify_installation() {
    log_header "PASO: Verificando versión instalada"

    if validate_mariadb_version "$MARIADB_TARGET_MAJOR" "$MARIADB_TARGET_MINOR"; then
        local version_str
        version_str=$(_detect_installed_version)
        ok "MariaDB ${version_str} — serie ${MARIADB_TARGET_SERIES}.x confirmada (ADR-009)"
    else
        log_fatal "La verificación de versión falló tras la instalación"
        exit 1
    fi
}

# =============================================================================
# PASO: Activar configuración del proyecto
# =============================================================================
_activate_project_config() {
    log_header "PASO: Activando configuración del proyecto"

    local cnf_src="${PROJECT_ROOT}/config/mariadb/99-practicayoruba.cnf"
    local cnf_dst="/etc/mysql/mariadb.conf.d/99-practicayoruba.cnf"

    if [[ ! -f "$cnf_src" ]]; then
        log_warn "  ${cnf_src} no encontrado — omitiendo"
        return 0
    fi

    ln -sf "$cnf_src" "$cnf_dst"
    ok "Symlink activo: ${cnf_dst} → ${cnf_src}"

    # Recargar configuración sin reiniciar
    if systemctl is-active --quiet mariadb 2>/dev/null; then
        systemctl reload mariadb 2>/dev/null \
            || mysqladmin reload 2>/dev/null \
            || log_warn "  No se pudo recargar la configuración — reinicia el servicio manualmente"
        ok "Configuración recargada"
    fi
}

# =============================================================================
# MAIN
# =============================================================================
log_header "Instalación MariaDB ${MARIADB_TARGET_SERIES} — PracticaYoruba"
log_info "  Objetivo: MariaDB ${MARIADB_TARGET_SERIES}.x LTS (ADR-009)"
[[ "$ALLOW_MIGRATE" == "true" ]] && \
    log_warn "  Modo: --migrate activo — puede purgar datos existentes"
echo ""

_check_requisites;      echo ""
_check_current_version; echo ""

# Si llegamos aquí es porque hay que instalar (no es idempotente-exit)
installed_series=$(_detect_installed_series)
if [[ -n "$installed_series" && "$installed_series" != "$MARIADB_TARGET_SERIES" ]]; then
    _purge_wrong_version; echo ""
fi

_add_mariadb_repo;        echo ""
_pin_mariadb_series;      echo ""
_install_mariadb;         echo ""
_verify_installation;     echo ""
_activate_project_config; echo ""

log_separator 60 "="
log_success "MariaDB ${MARIADB_TARGET_SERIES} instalado y configurado."
echo ""
log_info "Siguientes pasos:"
log_info "  sudo bash provisioners/mariadb/db_setup.sh"
log_info "  sudo bash provisioners/mariadb/db_qa_setup.sh"
log_info "  bash scripts/verify.sh"
