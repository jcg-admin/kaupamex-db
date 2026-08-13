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
#
# Modelo de usuarios (ver Procedimiento-Implementacion-Almacenamiento-
# WSL2-ecomerce-p001 v1.0.0 si aplica):
#   - INVOCADOR: cualquier cuenta con sudo + 'bash' en su whitelist.
#     En el modelo WSL2 canonico esa cuenta es 'deploy' (sudo general).
#   - NO RUN AS develop: develop no tiene sudo, el apt-get fallaria.
#   - NO RUN AS infra: en el modelo WSL2 infra tiene NOPASSWD solo
#     sobre una whitelist de binarios (mkfs.ext4, mount, apt, ...).
#     'bash' NO esta en la whitelist, asi que 'sudo bash install.sh'
#     como infra falla con 'sudo: a password is required'. Usar deploy.
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
# Deteccion de systemd (contenedores Docker/devcontainer no lo tienen)
# =============================================================================
# Estrategia: PID 1 es systemd O 'systemctl' funciona como cliente real.
# En contenedores tipicamente PID 1 es bash/sh/tini y systemctl ausente o
# falla con "System has not been booted with systemd as init system".
# Exporta HAS_SYSTEMD (true/false) usado por las rutas de service/start.
_detect_systemd() {
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        if systemctl is-system-running --quiet 2>/dev/null \
                || systemctl list-units --type=service >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

if _detect_systemd; then
    HAS_SYSTEMD=true
else
    HAS_SYSTEMD=false
    log_warn "systemd NO detectado (contenedor sin init real)."
    log_warn "  install.sh usara la ruta directa: mariadb_repo_setup + nohup mariadbd"
    log_warn "  El servicio NO se gestionara via systemctl; arranque manual con nohup."
fi
readonly HAS_SYSTEMD

# =============================================================================
# Helper: verificar si mariadbd ya esta corriendo en el socket canonico
# Usado para idempotencia en rutas sin systemd.
# =============================================================================
_mariadbd_already_running() {
    local sock adm
    adm=$(mariadb_admin_bin)
    [[ -z "$adm" ]] && return 1
    for sock in /run/mysqld/mysqld.sock /var/run/mysqld/mysqld.sock; do
        if [[ -S "$sock" ]] && "$adm" --socket="$sock" ping --silent >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# =============================================================================
# Helper: arrancar mariadbd directo bajo nohup (sin systemd)
# IDEMPOTENTE: no-op si ya hay un mariadbd respondiendo en el socket.
# =============================================================================
_start_mariadbd_nohup() {
    if _mariadbd_already_running; then
        log_info "  mariadbd ya activo en /run/mysqld/mysqld.sock — omitiendo arranque"
        return 0
    fi

    mkdir -p /run/mysqld /var/log/mysql
    chown mysql:mysql /run/mysqld /var/log/mysql 2>/dev/null || true

    local daemon=""
    for bin in /usr/sbin/mariadbd /usr/sbin/mysqld /usr/bin/mariadbd; do
        [[ -x "$bin" ]] && daemon="$bin" && break
    done
    if [[ -z "$daemon" ]]; then
        log_fatal "No se encontro el binario mariadbd/mysqld"
        exit 1
    fi

    log_info "  Arrancando ${daemon} con nohup (sin systemd)"
    nohup "$daemon" --user=mysql \
        > /var/log/mysql/mariadbd.log 2>&1 &

    # Esperar hasta 30s a que el socket responda
    local elapsed=0
    while (( elapsed < 30 )); do
        if _mariadbd_already_running; then
            log_success "  mariadbd respondiendo (${elapsed}s)"
            return 0
        fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
    done
    log_error "mariadbd no respondio en 30s — revisa /var/log/mysql/mariadbd.log"
    return 1
}

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
    # D-028: en MariaDB 11.x el binario CLI es ``mariadb``; ``mysql``
    # solo existe en MariaDB <= 10.11. mariadb_client_bin resuelve cual
    # esta instalado.
    local cli; cli=$(mariadb_client_bin)
    [[ -z "$cli" ]] && echo "" && return
    "$cli" --version 2>/dev/null \
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
    log_success "Corriendo como root"

    # Ubuntu requerido (apt-based)
    if ! command_exists apt-get; then
        log_fatal "Este script requiere apt (Ubuntu/Debian)"
        exit 1
    fi
    log_success "apt disponible"

    # Conexión a internet (para descargar repo si es necesario)
    # 2026-05-20: downloads.mariadb.com quedó deprecado para apt repos
    # (302 -> mariadb.com/downloads HTML); la CDN apt activa es
    # dlm.mariadb.com (verificado contra noble + amd64).
    if ! tcp_is_reachable "dlm.mariadb.com" 443 5; then
        log_warn "Sin acceso a dlm.mariadb.com:443"
        log_warn "  El repo de MariaDB puede no ser alcanzable"
        log_warn "  Si el paquete ya está en los repos del sistema, puede continuar"
    else
        log_success "Acceso a dlm.mariadb.com"
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
        # Verificar si hay MySQL (no MariaDB). En MariaDB <=10.11 el
        # binario CLI puede llamarse 'mysql'; en MariaDB 11.x es
        # 'mariadb'. Si NO se detecto version MariaDB pero existe
        # alguno de los binarios, asumimos MySQL puro y abortamos.
        local raw_version raw_cli
        for raw_cli in mariadb mysql; do
            if command -v "$raw_cli" &>/dev/null; then
                raw_version=$("$raw_cli" --version 2>/dev/null || echo "")
                if [[ -n "$raw_version" ]]; then
                    log_warn "${raw_cli} encontrado pero no es MariaDB: ${raw_version}"
                    log_warn "  Este script solo gestiona MariaDB"
                    log_error "Motor no soportado — instala MariaDB manualmente"
                    log_error "  Este script no puede continuar con MySQL puro instalado"
                    exit 1
                fi
            fi
        done
        log_info "MariaDB no instalado — se instalará 11.8 desde cero"
        log_success "Sin instalación previa — listo para instalar"
        return 0
    fi

    log_info "Instalado: MariaDB ${installed_version} (serie ${installed_series})"

    if [[ "$installed_series" == "$MARIADB_TARGET_SERIES" ]]; then
        log_success "MariaDB ${installed_version} — serie correcta (${MARIADB_TARGET_SERIES}.x)"
        log_success "Idempotente: no se requiere ninguna acción"
        echo ""
        log_separator 60 "="
        log_success "MariaDB ${MARIADB_TARGET_SERIES}.x ya instalado. Sin cambios."
        exit 0
    fi

    # Versión incorrecta
    log_error "Serie incorrecta: ${installed_series} (se requiere ${MARIADB_TARGET_SERIES})"
    echo ""

    if [[ "$ALLOW_MIGRATE" == "false" ]]; then
        log_error "======================================================="
        log_error "ACCIÓN REQUERIDA — DATO DESTRUCTIVO"
        log_error "======================================================="
        log_error ""
        log_error "Hay MariaDB ${installed_version} instalado."
        log_error "Kaupamex requiere MariaDB ${MARIADB_TARGET_SERIES}.x (ADR-009)."
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

    log_success "MariaDB ${installed_series} purgado"
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
        log_success "MariaDB ${MARIADB_TARGET_SERIES}.x disponible en repos del sistema"
        return 0
    fi

    log_info "  ${MARIADB_TARGET_SERIES}.x no en repos del sistema — agregando repo oficial"

    # Prereqs
    _apt_install software-properties-common dirmngr \
        apt-transport-https curl gpg > /dev/null

    # Preferir el setup script oficial de MariaDB cuando no hay systemd:
    # es la ruta documentada por mariadb.com, configura keyring + sources
    # consistentemente para contenedores y hosts sin gestor de servicios.
    if [[ "$HAS_SYSTEMD" == "false" ]] \
            && tcp_is_reachable "r.mariadb.com" 443 5 2>/dev/null; then
        log_info "  Usando mariadb_repo_setup oficial (ruta sin systemd)"
        if curl -fsSL https://r.mariadb.com/downloads/mariadb_repo_setup \
                | bash -s -- --mariadb-server-version="${MARIADB_TARGET_SERIES}" \
                    > /dev/null 2>&1; then
            apt-get update -qq 2>/dev/null || true
            log_success "Repositorio MariaDB ${MARIADB_TARGET_SERIES} agregado (mariadb_repo_setup)"
            return 0
        fi
        log_warn "  mariadb_repo_setup fallo — cayendo al metodo manual"
    fi

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
    # 2026-05-20: la ruta historica
    #   https://downloads.mariadb.com/MariaDB/mariadb-<v>/repo/ubuntu
    # quedo deprecada (302 -> 302 -> mariadb.com/downloads HTML, sin
    # InRelease PGP). Operador deploy@yollotl reporto fallo con
    # 'Clearsigned file isn't valid, got NOSPLIT'. CDN apt activo:
    #   https://dlm.mariadb.com/repo/mariadb-server/<v>/repo/ubuntu
    # Verificado contra noble + amd64 con paquetes 11.8.7+maria~ubu2404.
    # El endpoint sirve 302 a una signed URL de Google Cloud Storage
    # (storage.googleapis.com/downloads-cdn.mariadb.com); apt sigue el
    # redirect transparentemente.
    local repo_file="/etc/apt/sources.list.d/mariadb.list"
    cat > "$repo_file" << EOF
# MariaDB ${MARIADB_TARGET_SERIES} LTS — gestionado por kaupamex-db
# provisioners/mariadb/install.sh
deb [arch=amd64 signed-by=${keyring}] https://dlm.mariadb.com/repo/mariadb-server/${MARIADB_TARGET_SERIES}/repo/ubuntu ${codename} main
EOF

    # DEC-DOC-008: loud failure. Capture stderr; if apt-get update fails,
    # surface the underlying error before exiting. Sin esto, set -euo
    # pipefail mata el script silenciosamente justo tras "GPG key importada".
    local apt_update_log
    apt_update_log=$(mktemp)
    if ! apt-get update -qq 2>"$apt_update_log"; then
        log_fatal "apt-get update fallo tras agregar el repo MariaDB ${MARIADB_TARGET_SERIES}"
        log_error "stderr:"
        sed 's/^/    /' "$apt_update_log" >&2
        log_error "Verificacion sugerida:"
        log_error "  cat ${repo_file}"
        log_error "  sudo apt-get update      # sin -qq para ver el error completo"
        rm -f "$apt_update_log"
        exit 1
    fi
    rm -f "$apt_update_log"
    log_success "Repositorio MariaDB ${MARIADB_TARGET_SERIES} agregado (${repo_file})"
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

    log_success "Serie ${MARIADB_TARGET_SERIES}.x pineada — no actualizará a 12.x automáticamente"
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

    # D-031 H-20 (reportado por deploy@yollotl): el config default de
    # MariaDB 11.8 referencia plugin providers con 'force_plus_permanent'
    # en /etc/mysql/mariadb.conf.d/*.cnf. Como _apt_install usa
    # --no-install-recommends, esos paquetes provider NO se instalan
    # automaticamente y mariadbd revienta al arrancar con:
    #   [ERROR] mariadbd: Can't open shared library
    #     '/usr/lib/mysql/plugin/provider_bzip2.so'
    #   [ERROR] unknown variable 'provider_bzip2=force_plus_permanent'
    #   [ERROR] Aborting
    # Especificar los providers explicitamente para que un install
    # limpio (o un --migrate) deje un daemon arrancable. Idempotente:
    # apt skip si ya estan instalados.
    if ! _apt_install \
            mariadb-server mariadb-client \
            mariadb-plugin-provider-bzip2 \
            mariadb-plugin-provider-lz4 \
            mariadb-plugin-provider-lzma \
            mariadb-plugin-provider-lzo \
            mariadb-plugin-provider-snappy \
            > /dev/null; then
        log_fatal "No se pudo instalar mariadb-server + plugin providers"
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
        # DEC-DOC-008: loud failure on datadir init.
        local init_log
        init_log=$(mktemp)
        if ! "$init_cmd" --user=mysql --datadir=/var/lib/mysql 2>"$init_log"; then
            log_fatal "${init_cmd} fallo inicializando /var/lib/mysql"
            log_error "stderr:"
            sed 's/^/    /' "$init_log" >&2
            rm -f "$init_log"
            exit 1
        fi
        rm -f "$init_log"
        log_info "  datadir inicializado via ${init_cmd}"
    fi

    # Activar y arrancar el servicio
    if [[ "$HAS_SYSTEMD" == "true" ]]; then
        systemctl enable mariadb 2>/dev/null \
            || service mariadb enable 2>/dev/null \
            || true

        mariadb_start || {
            log_fatal "MariaDB instalado pero no responde"
            exit 1
        }
    else
        # Sin systemd: arrancar mariadbd manualmente con nohup. Idempotente.
        _start_mariadbd_nohup || {
            log_fatal "MariaDB instalado pero no se pudo arrancar mariadbd"
            exit 1
        }
    fi

    log_success "MariaDB ${MARIADB_TARGET_SERIES} instalado y activo"
}

# =============================================================================
# PASO: Verificar versión instalada
# =============================================================================
_verify_installation() {
    log_header "PASO: Verificando versión instalada"

    # D-028: tras instalar MariaDB 11.x, el binario CLI se llama
    # ``mariadb`` (no ``mysql``). Re-resolver MARIADB_CLI por si el
    # source inicial de database.sh ocurrio antes de que existiera
    # algun cliente (instalacion desde cero).
    MARIADB_CLI=$(mariadb_client_bin)
    MARIADB_ADM=$(mariadb_admin_bin)
    export MARIADB_CLI MARIADB_ADM

    if [[ -z "$MARIADB_CLI" ]]; then
        log_fatal "Tras la instalacion no se encontro 'mariadb' ni 'mysql' en PATH"
        log_error "  Verifica con: dpkg -l | grep mariadb-client"
        exit 1
    fi

    if validate_mariadb_version "$MARIADB_TARGET_MAJOR" "$MARIADB_TARGET_MINOR"; then
        local version_str
        version_str=$(_detect_installed_version)
        log_success "MariaDB ${version_str} — serie ${MARIADB_TARGET_SERIES}.x confirmada (ADR-009)"
        log_info "  Cliente CLI: ${MARIADB_CLI}"
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
    log_success "Symlink activo: ${cnf_dst} → ${cnf_src}"

    # Recargar configuración sin reiniciar
    if [[ "$HAS_SYSTEMD" == "true" ]] && systemctl is-active --quiet mariadb 2>/dev/null; then
        systemctl reload mariadb 2>/dev/null \
            || "${MARIADB_ADM:-mariadb-admin}" reload 2>/dev/null \
            || log_warn "  No se pudo recargar la configuración — reinicia el servicio manualmente"
        log_success "Configuración recargada"
    elif [[ "$HAS_SYSTEMD" == "false" ]] && _mariadbd_already_running; then
        # Sin systemd: usar mariadb-admin (o mysqladmin legacy) contra
        # el socket activo. MARIADB_ADM ya esta resuelto al sourcear
        # database.sh; usar default literal si vacio.
        local sock adm; adm="${MARIADB_ADM:-mariadb-admin}"
        for sock in /run/mysqld/mysqld.sock /var/run/mysqld/mysqld.sock; do
            [[ -S "$sock" ]] || continue
            "$adm" --socket="$sock" reload 2>/dev/null && {
                log_success "Configuración recargada (via socket)"; break
            }
        done
    fi
}

# =============================================================================
# MAIN
# =============================================================================
log_header "Instalación MariaDB ${MARIADB_TARGET_SERIES} — Kaupamex"
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
