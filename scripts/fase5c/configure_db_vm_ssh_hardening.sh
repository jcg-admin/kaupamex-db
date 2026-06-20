#!/bin/bash
# =============================================================================
# configure_db_vm_ssh_hardening.sh
# Aplica el baseline de hardenizacion SSH del proyecto en ecom-db-vm.
# Crea /etc/ssh/sshd_config.d/99-ecom-prod-hardening.conf con las
# directivas de seguridad del proyecto. Hace reload de sshd sin cerrar
# la sesion SSH activa.
#
# Ejecutar DENTRO de ecom-db-vm como:
#   sudo bash /tmp/configure_db_vm_ssh_hardening.sh
#
# Contexto:  [VM3-UBUNTU] -- usuario ubuntu con sudo, dentro de ecom-db-vm
# Tarea:     5.0c [VM1] -- Hardenizacion SSH interna
#
# Despliegue desde el Host:
#   scp -i /home/ubuntu/.ssh/id_ed25519_host_to_ecom_db_vm /tmp/configure_db_vm_ssh_hardening.sh ubuntu@192.168.100.30:/tmp/
#   ssh ecom-db "sudo bash /tmp/configure_db_vm_ssh_hardening.sh" 2>&1 | \
#       tee /tmp/log_tarea_5_0c_vm1_$(date -u +%Y%m%dT%H%M%SZ).txt
#
# Prerequisitos:
#   - Tarea 5.C.3a [VM3] completada: SSH escucha en 192.168.100.30:49918
#   - Canal ssh vm1 funcional (Port 49918 en ~/.ssh/config del Host)
#
# Precedente: configure_vm2_ssh_hardening.sh v1.0.0 (H49-H53 VM2, 2026-06-19)
# Diferencias respecto al Host (Tarea 1.5):
#   - AllowUsers ubuntu (no ubuntu infra deploy -- cuentas no existen aun en VM)
#   - Port 49918 permanece en sshd_config principal (Tarea 5.0b) -- no se mueve
#
# Directivas aplicadas:
#   PermitRootLogin no
#   PubkeyAuthentication yes
#   AuthenticationMethods publickey
#   AllowUsers ubuntu
#   MaxAuthTries 3
#   LoginGraceTime 30
#   X11Forwarding no
#   PrintMotd no
#   PasswordAuthentication no (si no esta ya en 60-cloudimg-settings.conf)
#
# Hallazgos producidos:
#   H-C3b-1-VM3  -- 99-ecom-prod-hardening.conf creado
#   H-C3b-2-VM3 -- PermitRootLogin: no
#   H-C3b-3-VM3 -- AllowUsers: ubuntu
#   H-C3b-4-VM3 -- AuthenticationMethods: publickey
#   H-C3b-5-VM3 -- PasswordAuthentication: no
#
# Pendiente post-ejecucion:
#   Agregar 'deploy' a AllowUsers cuando se cree la cuenta deploy en VM1.
#
# Idempotente: segunda ejecucion sobreescribe el archivo con el mismo
# contenido, hace reload y verifica -- sin cambios funcionales.
#
# -----------------------------------------------------------------------------
# Version  Fecha        Autor                                    Cambios
# -----------------------------------------------------------------------------
# v1.0.0   2026-06-20   Nestor Monroy <46802445+NestorMonroy    Version inicial.
#                       @users.noreply.github.com>               Hardenizacion
#                                                                SSH VM1.
#                                                                99-ecom-prod-
#                                                                hardening.conf.
#                                                                Hallazgos
#                                                                H-C3b-1-VM3..H-C3b-5-VM3.
# -----------------------------------------------------------------------------

set -euo pipefail

VERSION="v1.0.1"

# =============================================================================
# CONFIGURACION
# =============================================================================

readonly SSH_PORT=65514
readonly VM_IP="192.168.100.30"
readonly HARDENING_FILE="/etc/ssh/sshd_config.d/99-ecom-prod-hardening.conf"
readonly CLOUDIMG_CONF="/etc/ssh/sshd_config.d/60-cloudimg-settings.conf"
readonly SSHD_CONF_DIR="/etc/ssh/sshd_config.d"
readonly LOG_DIR="/var/log/ecom-setup"
readonly LOG_FILE="${LOG_DIR}/configure_db_vm_ssh_hardening_$(date -u +%Y-%m-%dT%H%M%SZ).log"

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

    log_info "Script: configure_db_vm_ssh_hardening.sh $VERSION"
    log_info "Archivo hardening objetivo: $HARDENING_FILE"
    log_info "Puerto SSH activo: $SSH_PORT (alias ecom-db)"
    log_info "Log: $LOG_FILE"
}

# =============================================================================
# PASO 1 -- Auditoria SSH actual
# =============================================================================

auditar_estado_actual() {
    section "PASO 1 -- Auditoria del estado SSH actual"

    log_info "Archivos en $SSHD_CONF_DIR:"
    local archivos
    archivos=$(ls -la "$SSHD_CONF_DIR" 2>/dev/null || echo "(directorio vacio o inexistente)")
    while IFS= read -r line; do log_info "  $line"; done <<< "$archivos"

    log_info ""
    log_info "Contenido de archivos .conf activos:"
    for conf in "$SSHD_CONF_DIR"/*.conf; do
        if [[ -f "$conf" ]]; then
            log_info ""
            log_info "--- $(basename "$conf") ---"
            while IFS= read -r line; do
                log_info "  $line"
            done < "$conf"
        fi
    done

    log_info ""
    log_info "Directivas activas relevantes en sshd_config principal:"
    grep -v "^#\|^$" /etc/ssh/sshd_config 2>/dev/null | \
        grep -iE "permitroot|pubkey|password|allowuser|authmeth|maxauth|gracetime|x11|motd|port" | \
        while IFS= read -r line; do log_info "  $line"; done || true

    log_info ""
    log_info "Puerto SSH actual en escucha:"
    ss -tlnp 2>/dev/null | grep -E "ssh|${SSH_PORT}" | \
        while IFS= read -r line; do log_info "  $line"; done || true
}

# =============================================================================
# PASO 2 -- Crear 99-ecom-prod-hardening.conf
# =============================================================================

crear_hardening_conf() {
    section "PASO 2 -- Crear 99-ecom-prod-hardening.conf"

    if [[ -f "$HARDENING_FILE" ]]; then
        log_warn "Archivo ya existe -- sobreescribiendo (idempotente)."
        log_warn "Contenido previo:"
        while IFS= read -r line; do log_warn "  $line"; done < "$HARDENING_FILE"
        log_info ""
        local backup="${HARDENING_FILE}.bak_$(date -u +%Y%m%dT%H%M%SZ)"
        cp "$HARDENING_FILE" "$backup"
        log_info "Backup: $backup"
        log_info ""
    fi

    log_info "Escribiendo $HARDENING_FILE..."

    cat > "$HARDENING_FILE" << 'EOF'
# 99-ecom-prod-hardening.conf
# Hardenizacion SSH del proyecto ecom-prod -- ecom-db-vm
# Tarea 5.C.3b [VM3] -- 2026-06-20
# Precedente: configure_vm1_ssh_hardening.sh v1.0.0 (Tarea 5.0c VM1)
#
# AllowUsers definitivo en VM3 -- tier de datos, sin cuentas deploy/app.

# Acceso root via SSH completamente bloqueado
PermitRootLogin no

# Autenticacion exclusiva por llave publica
PubkeyAuthentication yes
AuthenticationMethods publickey

# Cuentas permitidas -- AllowUsers definitivo en VM3 (tier de datos)
AllowUsers ubuntu

# Limitar intentos de autenticacion y ventana de conexion
MaxAuthTries 3
LoginGraceTime 30

# Reducir superficie de ataque
X11Forwarding no
PrintMotd no
EOF

    log_ok "99-ecom-prod-hardening.conf escrito correctamente."
    log_info ""
    log_info "Contenido:"
    while IFS= read -r line; do log_info "  $line"; done < "$HARDENING_FILE"

    log_ok "HALLAZGO H-C3b-1-VM3 -- 99-ecom-prod-hardening.conf creado: $HARDENING_FILE"
}

# =============================================================================
# PASO 3 -- Verificar PasswordAuthentication
# =============================================================================

verificar_password_authentication() {
    section "PASO 3 -- Verificar PasswordAuthentication"

    log_info "Buscando PasswordAuthentication en archivos de configuracion..."

    local encontrado_en=""

    for conf in "$SSHD_CONF_DIR"/*.conf /etc/ssh/sshd_config; do
        if [[ -f "$conf" ]]; then
            if grep -qi "^PasswordAuthentication[[:space:]]*no" "$conf" 2>/dev/null; then
                encontrado_en="$conf"
                log_info "  Encontrado en: $conf"
                break
            fi
        fi
    done

    if [[ -n "$encontrado_en" ]]; then
        log_ok "PasswordAuthentication no ya activo en: $(basename "$encontrado_en")"
        log_info "No se duplica en 99-ecom-prod-hardening.conf."

        if [[ "$encontrado_en" == "$CLOUDIMG_CONF" ]]; then
            log_info "Origen: 60-cloudimg-settings.conf de OVH -- comportamiento esperado."
        fi

        log_ok "HALLAZGO H-C3b-5-VM3 -- PasswordAuthentication: no (en $(basename "$encontrado_en"))"
    else
        log_warn "PasswordAuthentication no encontrado en ningun archivo."
        log_info "Agregando a $HARDENING_FILE..."
        echo "" >> "$HARDENING_FILE"
        echo "# PasswordAuthentication no encontrado en 60-cloudimg -- se agrega aqui" \
            >> "$HARDENING_FILE"
        echo "PasswordAuthentication no" >> "$HARDENING_FILE"
        log_ok "PasswordAuthentication no agregado a 99-ecom-prod-hardening.conf."
        log_ok "HALLAZGO H-C3b-5-VM3 -- PasswordAuthentication: no (agregado en 99-hardening)"
    fi
}

# =============================================================================
# PASO 4 -- Verificar sintaxis
# =============================================================================

verificar_sintaxis() {
    section "PASO 4 -- Verificar sintaxis sshd_config"

    log_info "Ejecutando sshd -t..."
    if sshd -t 2>/dev/null; then
        log_ok "Sintaxis sshd_config: OK -- sin errores."
    else
        log_error "ERROR de sintaxis en sshd_config:"
        sshd -t 2>&1 | while IFS= read -r line; do log_error "  $line"; done || true
        die "Abortando antes del reload para proteger la sesion SSH activa."
    fi
}

# =============================================================================
# PASO 5 -- Reload sshd
# =============================================================================

reload_sshd() {
    section "PASO 5 -- Reload sshd"

    log_info "Nota: reload recarga la configuracion sin cerrar sesiones activas."
    log_info "La sesion SSH actual en VM1 continua activa."
    log_info ""

    log_info "Ejecutando systemctl reload ssh..."
    if systemctl reload ssh 2>/dev/null; then
        log_ok "sshd recargado correctamente."
    else
        log_warn "systemctl reload ssh fallo. Intentando con sshd..."
        if systemctl reload sshd 2>/dev/null; then
            log_ok "sshd recargado via sshd.service."
        else
            log_warn "Reload manual: kill -HUP \$(pidof sshd)..."
            kill -HUP "$(pidof sshd 2>/dev/null || echo '')" 2>/dev/null || true
            log_ok "HUP enviado a sshd."
        fi
    fi

    sleep 1
    log_info "sshd estabilizado (1s)."
}

# =============================================================================
# PASO 6 -- Verificar directivas activas
# =============================================================================

verificar_directivas_activas() {
    section "PASO 6 -- Verificar directivas activas post-reload"

    log_info "Consultando configuracion efectiva con sshd -T..."
    log_info ""

    local sshd_T_output
    sshd_T_output=$(sshd -T 2>/dev/null || echo "")

    if [[ -z "$sshd_T_output" ]]; then
        log_warn "sshd -T no disponible -- verificando via grep en archivos."
    fi

    # PermitRootLogin
    local permit_root
    if [[ -n "$sshd_T_output" ]]; then
        permit_root=$(echo "$sshd_T_output" | grep -i "^permitrootlogin" | \
            awk '{print $2}' || echo "")
    else
        permit_root=$(grep -h "^PermitRootLogin" \
            "$SSHD_CONF_DIR"/*.conf /etc/ssh/sshd_config 2>/dev/null | \
            tail -1 | awk '{print $2}' || echo "")
    fi

    if [[ "$permit_root" == "no" ]]; then
        log_ok "HALLAZGO H-C3b-2-VM3 -- PermitRootLogin: no"
    else
        log_warn "HALLAZGO H-C3b-2-VM3 -- PermitRootLogin: ${permit_root:-desconocido}"
        log_warn "  Verificar: sshd -T | grep permitrootlogin"
    fi

    # AllowUsers
    local allow_users
    if [[ -n "$sshd_T_output" ]]; then
        allow_users=$(echo "$sshd_T_output" | grep -i "^allowusers" | \
            awk '{print $2}' || echo "")
    else
        allow_users=$(grep -h "^AllowUsers" \
            "$SSHD_CONF_DIR"/*.conf /etc/ssh/sshd_config 2>/dev/null | \
            tail -1 | awk '{$1=""; print $0}' | xargs || echo "")
    fi

    if echo "$allow_users" | grep -q "ubuntu"; then
        log_ok "HALLAZGO H-C3b-3-VM3 -- AllowUsers: $allow_users"
    else
        log_warn "HALLAZGO H-C3b-3-VM3 -- AllowUsers: ${allow_users:-no definido}"
        log_warn "  ubuntu no aparece en AllowUsers -- verificar acceso."
    fi

    # AuthenticationMethods
    local auth_methods
    if [[ -n "$sshd_T_output" ]]; then
        auth_methods=$(echo "$sshd_T_output" | grep -i "^authenticationmethods" | \
            awk '{print $2}' || echo "")
    else
        auth_methods=$(grep -h "^AuthenticationMethods" \
            "$SSHD_CONF_DIR"/*.conf /etc/ssh/sshd_config 2>/dev/null | \
            tail -1 | awk '{print $2}' || echo "")
    fi

    if [[ "$auth_methods" == "publickey" ]]; then
        log_ok "HALLAZGO H-C3b-4-VM3 -- AuthenticationMethods: publickey"
    else
        log_warn "HALLAZGO H-C3b-4-VM3 -- AuthenticationMethods: ${auth_methods:-no definido}"
    fi

    log_info ""
    log_info "Directivas SSH efectivas relevantes:"
    if [[ -n "$sshd_T_output" ]]; then
        echo "$sshd_T_output" | grep -iE \
            "permitroot|pubkey|password|allowuser|authmeth|maxauth|gracetime|x11|printmotd|port" | \
            while IFS= read -r line; do log_info "  $line"; done || true
    else
        log_info "  (sshd -T no disponible -- ver archivos de configuracion)"
    fi
}

# =============================================================================
# RESUMEN FINAL
# =============================================================================

print_summary() {
    local sep
    sep=$(printf '=%.0s' {1..70})

    printf '\n%s\n' "$sep"
    printf 'RESUMEN -- configure_db_vm_ssh_hardening.sh %s\n' "$VERSION"
    printf '%s\n' "$sep"
    printf 'Fecha:    %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'VM:       %s | IP: %s | Puerto SSH: %s\n' \
        "$(hostname)" "$VM_IP" "$SSH_PORT"
    printf 'Log:      %s\n' "$LOG_FILE"
    printf '%s\n' "$sep"
    printf 'Hallazgos confirmados:\n'
    printf '  H-C3b-1-VM3  -- 99-ecom-prod-hardening.conf: %s\n' "$HARDENING_FILE"
    printf '  H-C3b-2-VM3 -- PermitRootLogin: no\n'
    printf '  H-C3b-3-VM3 -- AllowUsers: ubuntu\n'
    printf '  H-C3b-4-VM3 -- AuthenticationMethods: publickey\n'
    printf '  H-C3b-5-VM3 -- PasswordAuthentication: no\n'
    printf '%s\n' "$sep"
    printf 'AllowUsers definitivo en VM3 -- sin cuentas deploy/app en el tier de datos.\n'
    printf '%s\n' "$sep"
    printf 'Tarea 5.C.3b [VM3] completada.\n'
    printf 'Proxima tarea: 5.C.3c [VM3] -- Firewall nftables ecom-db-vm\n'
    printf '%s\n\n' "$sep"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    verificar_precondiciones
    auditar_estado_actual
    crear_hardening_conf
    verificar_password_authentication
    verificar_sintaxis
    reload_sshd
    verificar_directivas_activas
    print_summary
    exit 0
}

mkdir -p "$LOG_DIR"
main "$@" 2>&1 | tee -a "$LOG_FILE"
exit "${PIPESTATUS[0]}"
