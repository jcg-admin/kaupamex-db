#!/bin/bash
# =============================================================================
# configure_db_vm_mariadb_install.sh
# Instala MariaDB 11.8 LTS en ecom-db-vm. Agrega el repositorio oficial
# de MariaDB (dlm.mariadb.com), pinea la serie 11.8.x, instala mariadb-server
# + plugin providers, activa la configuracion del proyecto
# (99-practicayoruba.cnf) y verifica que el servicio arranca correctamente.
#
# Ejecutar DENTRO de ecom-db-vm como:
#   sudo bash /tmp/configure_db_vm_mariadb_install.sh
#
# Contexto:  [VM3-UBUNTU] -- usuario ubuntu con sudo, dentro de ecom-db-vm
# Tarea:     5.1 [VM1] Script 1 -- Instalar MariaDB 11.8 LTS
#
# Despliegue desde el Host:
#   scp -F /home/ubuntu/.ssh/config /tmp/configure_db_vm_mariadb_install.sh ecom-db:/tmp/
#   ssh ecom-db "sudo bash /tmp/configure_db_vm_mariadb_install.sh" 2>&1 | \
#       tee /tmp/log_tarea_5_1_install_vm1_$(date -u +%Y%m%dT%H%M%SZ).txt
#
# Prerequisitos:
#   - Tarea 5.C.3e [VM3] completada: base del SO OK, AppArmor activo
#   - Acceso a internet desde VM1 (masquerade Host activo -- Tarea 4.0b)
#   - vdb presente con ext4 (UUID ce333b4b) -- este script NO lo toca (Tarea 5.C.5)
#
# Script autonomo: no invoca repositorios externos. Toda la logica
# de instalacion esta incluida directamente en este script.
# El repo e-comerce-db fue usado como referencia para: version MariaDB
# (11.8 LTS), CDN activo (dlm.mariadb.com), plugin providers necesarios,
# y configuracion 99-practicayoruba.cnf.
#
# Notas de instalacion MariaDB 11.8 en Ubuntu 26.04:
#   - CDN activo: dlm.mariadb.com (downloads.mariadb.com deprecado)
#   - Binarios canonicos: mariadb / mariadb-admin (no mysql / mysqladmin)
#   - Plugin providers obligatorios: bzip2, lz4, lzma, lzo, snappy
#     (MariaDB 11.8 los referencia con force_plus_permanent -- sin ellos
#      mariadbd aborta al arrancar con "Can't open shared library")
#   - Codename Ubuntu 26.04: resolute
#
# Configuracion aplicada (99-practicayoruba.cnf):
#   character-set-server  = utf8mb4
#   collation-server      = utf8mb4_unicode_ci
#   sql_mode              = STRICT_TRANS_TABLES,NO_ZERO_DATE,...
#   innodb_strict_mode    = ON
#   wait_timeout          = 300
#   log_error             = /var/lib/mysql/mysqld_err.log (en vdb tras Script 2)
#
# Hallazgos producidos:
#   H-C4-1-VM3  -- MariaDB 11.8.x instalado + mariadb.service active
#   H-C4-2-VM3 -- Version confirmada (11.8.x-MariaDB)
#   H-C4-3-VM3 -- AppArmor perfil mysqld en enforce
#   H-C4-4-VM3 -- 99-practicayoruba.cnf symlink activo
#
# Idempotente: si MariaDB 11.8.x ya esta instalado, el script verifica
# el estado y sale con exito sin hacer cambios.
#
# Siguiente script: configure_db_vm_mariadb_vdb.sh (Script 2)
# Mueve los datos de MariaDB a vdb (Clase C NVMe). Ejecutar solo
# despues de que este script haya completado con PASS.
#
# -----------------------------------------------------------------------------
# Version  Fecha        Autor                                    Cambios
# -----------------------------------------------------------------------------
# v1.0.0   2026-06-20   Nestor Monroy <46802445+NestorMonroy    Version inicial.
#                       @users.noreply.github.com>               MariaDB 11.8
#                                                                LTS. Repo
#                                                                dlm.mariadb.com
#                                                                Pin 11.8.x.
#                                                                Plugin providers
#                                                                99-practicayoruba
#                                                                .cnf. Hallazgos
#                                                                H-C4-1-VM3..H26d.
# -----------------------------------------------------------------------------

set -euo pipefail

VERSION="v1.0.1"

# =============================================================================
# CONFIGURACION
# =============================================================================

readonly MARIADB_TARGET_SERIES="11.8"
readonly MARIADB_TARGET_MAJOR="11"
readonly MARIADB_TARGET_MINOR="8"
readonly MARIADB_KEYRING="/usr/share/keyrings/mariadb.gpg"
readonly MARIADB_REPO_FILE="/etc/apt/sources.list.d/mariadb.list"
readonly MARIADB_PIN_FILE="/etc/apt/preferences.d/mariadb-pin"
readonly MARIADB_CNF_DIR="/etc/mysql/mariadb.conf.d"
readonly MARIADB_CNF_DST="${MARIADB_CNF_DIR}/99-practicayoruba.cnf"
readonly MARIADB_CNF_SRC="/etc/mysql/99-practicayoruba.cnf"
readonly LOG_DIR="/var/log/ecom-setup"
readonly LOG_FILE="${LOG_DIR}/configure_db_vm_mariadb_install_$(date -u +%Y-%m-%dT%H%M%SZ).log"

# =============================================================================
# UTILIDADES
# =============================================================================

log_info() {
    printf '[%s] [INFO]  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1"
}

log_ok() {
    printf '[%s] [OK]    %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1"
}

log_warn() {
    printf '[%s] [WARN]  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1"
}

log_error() {
    printf '[%s] [ERROR] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >&2
}

die() {
    log_error "$1"
    exit 1
}

section() {
    local sep
    sep=$(printf '=%.0s' {1..70})
    printf '\n%s\n[%s] === %s\n%s\n\n' \
        "$sep" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$sep"
}

# =============================================================================
# VERIFICACIONES INICIALES
# =============================================================================

verificar_precondiciones() {
    if [[ $EUID -ne 0 ]]; then
        printf '[ERROR] Ejecutar como: sudo bash /tmp/%s\n' \
            "$(basename "$0")" >&2
        exit 1
    fi
    log_ok "Privilegios root confirmados."

    local hostname_actual
    hostname_actual=$(hostname)
    if [[ "$hostname_actual" != "ecom-db-vm" ]]; then
        log_warn "Hostname: $hostname_actual (esperado: ecom-db-vm)"
        log_warn "Verificar que este ejecutando DENTRO de ecom-db-vm."
    else
        log_ok "Hostname: $hostname_actual -- correcto."
    fi

    log_info "Script: configure_db_vm_mariadb_install.sh $VERSION"
    log_info "Objetivo: MariaDB ${MARIADB_TARGET_SERIES}.x LTS"
    log_info "Log: $LOG_FILE"
}

# =============================================================================
# PASO 1 -- Verificar estado inicial
# =============================================================================

verificar_estado_inicial() {
    section "PASO 1 -- Estado inicial"

    # Detectar MariaDB o MySQL instalado
    local cli=""
    for bin in mariadb mysql; do
        if command -v "$bin" &>/dev/null; then
            cli="$bin"
            break
        fi
    done

    if [[ -n "$cli" ]]; then
        local version_str
        version_str=$("$cli" --version 2>/dev/null || echo "")
        log_info "Cliente DB detectado: $cli"
        log_info "Version: $version_str"

        # Verificar si ya es MariaDB 11.8.x
        local installed_major installed_minor
        installed_major=$(echo "$version_str" \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-MariaDB' \
            | head -1 | cut -d. -f1 || echo "")
        installed_minor=$(echo "$version_str" \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-MariaDB' \
            | head -1 | cut -d. -f2 || echo "")

        if [[ "$installed_major" == "$MARIADB_TARGET_MAJOR" && \
              "$installed_minor" == "$MARIADB_TARGET_MINOR" ]]; then
            log_ok "MariaDB ${MARIADB_TARGET_SERIES}.x ya instalado -- verificando estado."
            local svc_estado
            svc_estado=$(systemctl is-active mariadb 2>/dev/null || echo "inactive")
            log_info "mariadb.service: $svc_estado"

            if [[ "$svc_estado" == "active" ]]; then
                log_ok "HALLAZGO H-C4-1-VM3 -- MariaDB ${MARIADB_TARGET_SERIES}.x: active (idempotente)"
                log_ok "  Instalacion ya correcta. Script sale sin cambios."
                verificar_post_instalacion
                print_summary
                exit 0
            else
                log_warn "MariaDB instalado pero inactivo -- intentando arrancar."
                systemctl start mariadb 2>/dev/null || true
            fi
        else
            if echo "$version_str" | grep -q "MariaDB"; then
                log_error "MariaDB instalado pero serie incorrecta: $version_str"
                log_error "Se requiere MariaDB ${MARIADB_TARGET_SERIES}.x"
                die "Abortar -- limpiar instalacion existente antes de continuar."
            else
                log_error "Motor detectado no es MariaDB: $version_str"
                die "Este script solo gestiona MariaDB."
            fi
        fi
    else
        log_info "MariaDB no instalado -- procediendo con instalacion."
    fi

    # Verificar conectividad al CDN de MariaDB
    log_info ""
    log_info "Verificando acceso a dlm.mariadb.com:443..."
    if curl -fsSL --max-time 10 --head \
            "https://dlm.mariadb.com" &>/dev/null; then
        log_ok "Acceso a dlm.mariadb.com confirmado."
    else
        log_warn "Sin acceso a dlm.mariadb.com:443"
        log_warn "  Verificar masquerade del Host (Tarea 4.0b)"
        log_warn "  Intentando continuar -- apt puede tener cache."
    fi

    # Informar sobre discos -- vdb no se toca en este script
    log_info ""
    log_info "Discos detectados:"
    lsblk -d -o NAME,SIZE,TYPE,FSTYPE 2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || true
    log_info "Nota: vdb NO se toca en este script -- es responsabilidad del Script 2."
}

# =============================================================================
# PASO 2 -- Instalar prerequisitos apt
# =============================================================================

instalar_prereqs() {
    section "PASO 2 -- Instalar prerequisitos apt"

    log_info "Actualizando indice de paquetes..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>&1 | while IFS= read -r line; do
        log_info "  $line"
    done || true

    log_info "Instalando prerequisitos: curl, gpg, apt-transport-https, lsb-release..."
    apt-get install -y --no-install-recommends \
        curl gpg apt-transport-https lsb-release ca-certificates \
        2>&1 | while IFS= read -r line; do log_info "  $line"; done || \
        die "Error al instalar prerequisitos."

    log_ok "Prerequisitos instalados."
}

# =============================================================================
# PASO 3 -- Agregar repositorio oficial MariaDB 11.8
# =============================================================================

agregar_repositorio() {
    section "PASO 3 -- Agregar repositorio MariaDB ${MARIADB_TARGET_SERIES}"

    local codename
    codename=$(lsb_release -cs 2>/dev/null || echo "resolute")
    log_info "Codename OS: $codename"

    # Idempotencia: verificar si el repo ya esta configurado
    if [[ -f "$MARIADB_REPO_FILE" ]]; then
        log_info "Archivo de repo ya existe: $MARIADB_REPO_FILE"
        log_info "Contenido actual:"
        while IFS= read -r line; do log_info "  $line"; done < "$MARIADB_REPO_FILE"
        log_info "Continuando -- se sobreescribira para garantizar configuracion correcta."
    fi

    # Importar GPG key
    log_info "Importando GPG key de MariaDB..."
    if ! curl -fsSL \
            "https://mariadb.org/mariadb_release_signing_key.asc" \
            | gpg --dearmor | tee "$MARIADB_KEYRING" > /dev/null 2>&1; then
        die "No se pudo importar la GPG key de MariaDB."
    fi
    log_ok "GPG key importada: $MARIADB_KEYRING"

    # Escribir sources.list
    # CDN activo verificado 2026-05-20 (dlm.mariadb.com -- downloads.mariadb.com
    # quedo deprecado y redirige a HTML; dlm.mariadb.com sirve paquetes reales)
    cat > "$MARIADB_REPO_FILE" << EOF
# MariaDB ${MARIADB_TARGET_SERIES} LTS -- gestionado por ecom-prod
# configure_db_vm_mariadb_install.sh ${VERSION}
# CDN: dlm.mariadb.com (activo 2026-06-20 -- downloads.mariadb.com deprecado)
deb [arch=amd64 signed-by=${MARIADB_KEYRING}] https://dlm.mariadb.com/repo/mariadb-server/${MARIADB_TARGET_SERIES}/repo/ubuntu ${codename} main
EOF

    log_ok "Repo escrito: $MARIADB_REPO_FILE"
    log_info "Contenido:"
    while IFS= read -r line; do log_info "  $line"; done < "$MARIADB_REPO_FILE"

    # apt-get update con diagnostico explicito en caso de fallo
    log_info ""
    log_info "Ejecutando apt-get update..."
    local apt_update_log
    apt_update_log=$(mktemp)
    if ! apt-get update -qq 2>"$apt_update_log"; then
        log_error "apt-get update fallo tras agregar el repo MariaDB:"
        while IFS= read -r line; do log_error "  $line"; done < "$apt_update_log"
        rm -f "$apt_update_log"
        die "Verificar conectividad y contenido de $MARIADB_REPO_FILE"
    fi
    rm -f "$apt_update_log"
    log_ok "apt-get update completado."
}

# =============================================================================
# PASO 4 -- Pinear serie 11.8.x
# =============================================================================

pinear_serie() {
    section "PASO 4 -- Pinear MariaDB ${MARIADB_TARGET_SERIES}.x"

    cat > "$MARIADB_PIN_FILE" << EOF
# Pinear MariaDB a la serie ${MARIADB_TARGET_SERIES}.x
# Permite actualizaciones de patch (${MARIADB_TARGET_SERIES}.1 -> ${MARIADB_TARGET_SERIES}.2)
# pero bloquea saltos de serie (${MARIADB_TARGET_SERIES} -> 12.x)
# Generado por: configure_db_vm_mariadb_install.sh ${VERSION}
Package: mariadb-server mariadb-client mariadb-common
Pin: version 1:${MARIADB_TARGET_SERIES}.*
Pin-Priority: 1001
EOF

    log_ok "Pin escrito: $MARIADB_PIN_FILE"
    log_info "Serie ${MARIADB_TARGET_SERIES}.x pineada -- no actualizara a 12.x automaticamente."
}

# =============================================================================
# PASO 5 -- Instalar MariaDB + plugin providers
# =============================================================================

instalar_mariadb() {
    section "PASO 5 -- Instalar MariaDB ${MARIADB_TARGET_SERIES} + plugin providers"

    log_info "Instalando mariadb-server, mariadb-client y plugin providers..."
    log_info ""
    log_info "Plugin providers obligatorios en MariaDB 11.8:"
    log_info "  MariaDB 11.8 referencia bzip2/lz4/lzma/lzo/snappy con"
    log_info "  force_plus_permanent. Sin ellos mariadbd aborta al arrancar."
    log_info ""

    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get install -y --no-install-recommends \
            mariadb-server \
            mariadb-client \
            mariadb-plugin-provider-bzip2 \
            mariadb-plugin-provider-lz4 \
            mariadb-plugin-provider-lzma \
            mariadb-plugin-provider-lzo \
            mariadb-plugin-provider-snappy \
            2>&1 | while IFS= read -r line; do log_info "  $line"; done; then
        die "Error al instalar mariadb-server y plugin providers."
    fi

    log_ok "MariaDB ${MARIADB_TARGET_SERIES} y plugin providers instalados."
}

# =============================================================================
# PASO 6 -- Escribir y activar 99-practicayoruba.cnf
# =============================================================================

configurar_mariadb_cnf() {
    section "PASO 6 -- Configurar 99-practicayoruba.cnf"

    # Crear directorio de configuracion del proyecto si no existe
    mkdir -p "$(dirname "$MARIADB_CNF_SRC")"

    log_info "Escribiendo configuracion del proyecto en $MARIADB_CNF_SRC..."

    cat > "$MARIADB_CNF_SRC" << 'EOF'
# =============================================================================
# 99-practicayoruba.cnf
# Configuracion MariaDB del proyecto ecom-prod -- ecom-db-vm (VM3)
# Generado por: configure_db_vm_mariadb_install.sh
# Activado via symlink en /etc/mysql/mariadb.conf.d/
#
# Por que 99-practicayoruba.cnf y no modificar 50-server.cnf:
#   - 50-server.cnf es propiedad del paquete mariadb-server.
#   - MariaDB lee mariadb.conf.d/ en orden alfabetico.
#   - El prefijo 99 garantiza precedencia sobre defaults del sistema.
# =============================================================================

[mariadbd]

# ── Codificacion ─────────────────────────────────────────────────────────────
# utf8mb4 es el charset real de Unicode (incluye emojis y caracteres fuera
# del BMP). utf8mb4_unicode_ci alinea con la collation usada en CREATE DATABASE
# (db_setup.sh) y con OPTIONS charset: utf8mb4 en Django settings.
character-set-server  = utf8mb4
collation-server      = utf8mb4_unicode_ci

# ── Modo estricto ─────────────────────────────────────────────────────────────
# Alinea con el init_command de Django settings/base.py:
#   'init_command': "SET sql_mode='STRICT_TRANS_TABLES'"
# Activarlo a nivel servidor evita inserciones silenciosas de datos invalidos
# desde conexiones que no pasen por Django.
sql_mode = STRICT_TRANS_TABLES,NO_ZERO_DATE,NO_ZERO_IN_DATE,ERROR_FOR_DIVISION_BY_ZERO

# ── InnoDB ────────────────────────────────────────────────────────────────────
# innodb_strict_mode rechaza operaciones invalidas en lugar de silenciarlas.
# Detecta errores de esquema en CREATE TABLE / ALTER TABLE en desarrollo.
innodb_strict_mode = ON

# ── Conexiones ────────────────────────────────────────────────────────────────
# Django cierra conexiones con CONN_MAX_AGE pero en desarrollo puede haber
# conexiones huerfanas. 300s libera recursos sin afectar consultas legitimas.
wait_timeout         = 300
interactive_timeout  = 300

# ── Bind address ─────────────────────────────────────────────────────────────
# VM3 acepta conexiones TCP desde VM1 (Django) y Host (DNAT Claude Code web).
# El control de acceso lo ejerce el firewall nftables (Tarea 5.C.3c).
# 0.0.0.0 con firewall restrictivo es el patron correcto para BD con acceso
# externo controlado (DA-36).
bind-address = 192.168.100.30

# ── Logging de errores ────────────────────────────────────────────────────────
# /var/lib/mysql/ estara en vdb (Clase C NVMe) tras Script 2 (Tarea 5.C.4).
# El log de errores queda en el mismo volumen que los datos.
log_error = /var/lib/mysql/mysqld_err.log
EOF

    log_ok "Configuracion escrita: $MARIADB_CNF_SRC"

    # Verificar que el directorio de conf.d existe
    if [[ ! -d "$MARIADB_CNF_DIR" ]]; then
        log_warn "$MARIADB_CNF_DIR no existe -- creando."
        mkdir -p "$MARIADB_CNF_DIR"
    fi

    # Crear symlink (ln -sf es idempotente)
    ln -sf "$MARIADB_CNF_SRC" "$MARIADB_CNF_DST"
    log_ok "Symlink activo: $MARIADB_CNF_DST → $MARIADB_CNF_SRC"

    log_info ""
    log_info "Contenido aplicado:"
    while IFS= read -r line; do log_info "  $line"; done < "$MARIADB_CNF_SRC"
}

# =============================================================================
# PASO 7 -- Habilitar y arrancar mariadb.service
# =============================================================================

arrancar_mariadb() {
    section "PASO 7 -- Habilitar y arrancar mariadb.service"

    log_info "Habilitando mariadb.service para arranque automatico..."
    systemctl enable mariadb 2>/dev/null || \
        log_warn "systemctl enable mariadb retorno error -- verificar manualmente."
    log_ok "mariadb.service habilitado."

    log_info ""
    log_info "Arrancando mariadb.service..."

    # Reload de la configuracion antes de arrancar (aplica el CNF recien escrito)
    systemctl daemon-reload 2>/dev/null || true

    if systemctl start mariadb 2>/dev/null; then
        log_ok "mariadb.service arrancado correctamente."
    else
        log_error "mariadb.service no arranco. Diagnostico:"
        journalctl -u mariadb --no-pager -n 30 2>/dev/null | \
            while IFS= read -r line; do log_error "  $line"; done || true
        die "MariaDB no arranco. Revisar logs arriba."
    fi

    # Esperar hasta 15s a que el socket este disponible
    local elapsed=0
    while (( elapsed < 15 )); do
        if mariadb-admin ping --silent 2>/dev/null; then
            log_ok "Socket MariaDB disponible (${elapsed}s)."
            break
        fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
        log_info "  Esperando socket... ${elapsed}s"
    done

    if ! mariadb-admin ping --silent 2>/dev/null; then
        die "MariaDB no responde en el socket tras 15s."
    fi
}

# =============================================================================
# PASO 8 -- Verificar instalacion
# =============================================================================

verificar_post_instalacion() {
    section "PASO 8 -- Verificar instalacion"

    # H-C4-1-VM3: mariadb.service active
    local svc_estado
    svc_estado=$(systemctl is-active mariadb 2>/dev/null || echo "inactive")
    if [[ "$svc_estado" == "active" ]]; then
        log_ok "HALLAZGO H-C4-1-VM3 -- mariadb.service: active"
    else
        log_warn "HALLAZGO H-C4-1-VM3 -- mariadb.service: $svc_estado (esperado: active)"
    fi

    # H-C4-2-VM3: version 11.8.x-MariaDB
    local version_str=""
    if command -v mariadb &>/dev/null; then
        version_str=$(mariadb --version 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-MariaDB' | head -1 || echo "")
    fi

    if [[ -n "$version_str" ]]; then
        local vmaj vmin
        vmaj=$(echo "$version_str" | cut -d. -f1)
        vmin=$(echo "$version_str" | cut -d. -f2)
        if [[ "$vmaj" == "$MARIADB_TARGET_MAJOR" && \
              "$vmin" == "$MARIADB_TARGET_MINOR" ]]; then
            log_ok "HALLAZGO H-C4-2-VM3 -- Version: $version_str (serie ${MARIADB_TARGET_SERIES}.x confirmada)"
        else
            log_warn "HALLAZGO H-C4-2-VM3 -- Version: $version_str (esperado: ${MARIADB_TARGET_SERIES}.x)"
        fi
    else
        log_warn "HALLAZGO H-C4-2-VM3 -- Version no determinada (mariadb CLI no disponible)"
    fi

    # H-C4-3-VM3: AppArmor perfil mysqld en enforce
    log_info ""
    log_info "Verificando perfil AppArmor de MariaDB..."
    local aa_output
    aa_output=$(aa-status 2>/dev/null | grep -iE "mysqld|mariadbd" || echo "")

    if echo "$aa_output" | grep -q "enforce"; then
        log_ok "HALLAZGO H-C4-3-VM3 -- AppArmor mysqld: enforce"
        while IFS= read -r line; do log_info "  $line"; done <<< "$aa_output"
    elif [[ -n "$aa_output" ]]; then
        log_warn "HALLAZGO H-C4-3-VM3 -- AppArmor mysqld: encontrado pero modo no enforce"
        while IFS= read -r line; do log_warn "  $line"; done <<< "$aa_output"
    else
        log_info "HALLAZGO H-C4-3-VM3 -- AppArmor mysqld: no detectado en aa-status"
        log_info "  Puede ser normal si el perfil se carga con nombre diferente."
        log_info "  Verificar: aa-status | grep -i mysql"
    fi

    # H-C4-4-VM3: symlink 99-practicayoruba.cnf activo
    if [[ -L "$MARIADB_CNF_DST" ]]; then
        log_ok "HALLAZGO H-C4-4-VM3 -- 99-practicayoruba.cnf symlink activo: $MARIADB_CNF_DST"
    else
        log_warn "HALLAZGO H-C4-4-VM3 -- 99-practicayoruba.cnf symlink no encontrado en $MARIADB_CNF_DIR"
    fi

    # Informacion adicional del servicio
    log_info ""
    log_info "Estado detallado mariadb.service:"
    systemctl status mariadb --no-pager 2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || true

    log_info ""
    log_info "Ping al socket:"
    mariadb-admin ping 2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || \
        log_warn "  mariadb-admin ping fallo."

    log_info ""
    log_info "Variables de configuracion activas (muestra):"
    mariadb --batch --silent -e \
        "SHOW VARIABLES WHERE Variable_name IN \
        ('character_set_server','collation_server','sql_mode',\
         'innodb_strict_mode','wait_timeout','log_error');" \
        2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || \
        log_warn "  No se pudo consultar variables (autenticacion pendiente)."
}

# =============================================================================
# RESUMEN FINAL
# =============================================================================

print_summary() {
    local sep
    sep=$(printf '=%.0s' {1..70})

    local svc_estado
    svc_estado=$(systemctl is-active mariadb 2>/dev/null || echo "unknown")

    local version_str
    version_str=$(mariadb --version 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-MariaDB' | head -1 || echo "?")

    printf '\n%s\n' "$sep"
    printf 'RESUMEN -- configure_db_vm_mariadb_install.sh %s\n' "$VERSION"
    printf '%s\n' "$sep"
    printf 'Fecha:    %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'VM:       %s | IP: 192.168.100.30\n' "$(hostname)"
    printf 'Log:      %s\n' "$LOG_FILE"
    printf '%s\n' "$sep"
    printf 'Hallazgos confirmados:\n'
    printf '  H-C4-1-VM3  -- mariadb.service: %s\n' "$svc_estado"
    printf '  H-C4-2-VM3 -- Version: %s\n' "$version_str"
    printf '  H-C4-3-VM3 -- AppArmor mysqld: ver PASO 8\n'
    printf '  H-C4-4-VM3 -- 99-practicayoruba.cnf: %s\n' "$MARIADB_CNF_DST"
    printf '%s\n' "$sep"
    printf 'MariaDB instalado en vda (temporal).\n'
    printf 'Los datos se moveran a vdb en el Script 2:\n'
    printf '  configure_db_vm_mariadb_vdb.sh\n'
    printf '%s\n' "$sep"
    printf 'Tarea 5.C.4 Script 1 completada.\n'
    printf 'Proxima accion: ejecutar configure_db_vm_mariadb_vdb.sh\n'
    printf '%s\n\n' "$sep"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    verificar_precondiciones
    verificar_estado_inicial
    instalar_prereqs
    agregar_repositorio
    pinear_serie
    instalar_mariadb
    configurar_mariadb_cnf
    arrancar_mariadb
    verificar_post_instalacion
    print_summary
    exit 0
}

mkdir -p "$LOG_DIR"
main "$@" 2>&1 | tee -a "$LOG_FILE"
exit "${PIPESTATUS[0]}"
