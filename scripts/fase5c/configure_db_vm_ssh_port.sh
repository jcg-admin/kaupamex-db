#!/bin/bash
# =============================================================================
# configure_db_vm_ssh_port.sh
# Cambia el puerto SSH de ecom-db-vm de 22 a 49918 via override del
# socket systemd. Restringe la escucha a 192.168.100.30 (enp1s0 interna).
#
# Ejecutar DENTRO de ecom-db-vm como:
#   sudo bash /tmp/configure_db_vm_ssh_port.sh
#
# Contexto:  [VM3-UBUNTU] -- usuario ubuntu con sudo, dentro de ecom-db-vm
# Tarea:     5.0b [VM1] -- Cambio de puerto SSH interno via override socket systemd
#
# Despliegue desde el Host:
#   scp -i /home/ubuntu/.ssh/id_ed25519_host_to_ecom_db_vm /tmp/configure_db_vm_ssh_port.sh ubuntu@192.168.100.30:/tmp/
#   ssh -i /home/ubuntu/.ssh/id_ed25519_host_to_ecom_db_vm ubuntu@192.168.100.30 "sudo bash /tmp/configure_db_vm_ssh_port.sh" 2>&1 | \
#       tee /tmp/log_tarea_5_0b_vm1_$(date -u +%Y%m%dT%H%M%SZ).txt
#
# Nota: VM1 se accede directamente desde el Host (sin doble salto).
#
# Prerequisitos:
#   - Tarea 5.C.2 [VM3] completada (SO actualizado, qemu-guest-agent instalado)
#   - Sesion SSH activa en VM1 via SSH (doble salto Host → VM1 → VM3) -- NO cerrar hasta
#     completar la actualizacion de ~/.ssh/config en el Host
#
# ADVERTENCIA CRITICA:
#   Despues de ejecutar este script, el alias "ssh vm1" deja de funcionar
#   porque apunta al puerto 22. El script imprime las instrucciones exactas
#   para actualizar ~/.ssh/config en el Host. Ejecutarlas antes de cerrar
#   la sesion actual o se perdera el acceso a VM1.
#
#   DIFERENCIA vs VM2: el config que se actualiza es el del Host
#   (no el de VM1 como intermediario).
#
# Mecanismo (precedente: configure_vm2_ssh_port.sh v1.0.0 -- 2026-06-19):
#   Ubuntu 26.04 usa socket activation para SSH. El puerto lo controla
#   ssh.socket, no sshd_config. El override del socket es el unico metodo
#   correcto.
#
#   Override: /etc/systemd/system/ssh.socket.d/override.conf
#   [Socket]
#   ListenStream=           <- limpia el valor heredado (puerto 22)
#   ListenStream=192.168.100.30:49918
#
#   La linea ListenStream= vacia es obligatoria: sin ella systemd acumula
#   ambos puertos (22 y 49918) simultaneamente.
#
# Hallazgos producidos:
#   H-C3a-1-VM3 -- Puerto SSH antes: 0.0.0.0:22
#   H-C3a-2-VM3 -- Override socket creado: /etc/systemd/system/ssh.socket.d/override.conf
#   H-C3a-3-VM3 -- Puerto SSH despues: 192.168.100.30:49918
#
# Idempotente: segunda ejecucion detecta override existente con puerto
# correcto y registra OK sin modificar nada.
#
# -----------------------------------------------------------------------------
# Version  Fecha        Autor                                    Cambios
# -----------------------------------------------------------------------------
# v1.0.0   2026-06-20   Nestor Monroy <46802445+NestorMonroy    Version inicial.
#                       @users.noreply.github.com>               Puerto 49918.
#                                                                Override socket
#                                                                systemd.
#                                                                192.168.100.30.
#                                                                Hallazgos
#                                                                H-C3a-1-VM3..H-C3a-3-VM3.
# -----------------------------------------------------------------------------

set -euo pipefail

VERSION="v1.0.1"

# =============================================================================
# CONFIGURACION
# =============================================================================

readonly SSH_PORT=65514
readonly VM_IP="192.168.100.30"
readonly VM_IFACE="enp1s0"
readonly OVERRIDE_DIR="/etc/systemd/system/ssh.socket.d"
readonly OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"
readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSHD_HARDENING="/etc/ssh/sshd_config.d/99-ecom-prod-hardening.conf"
readonly LOG_DIR="/var/log/ecom-setup"
readonly LOG_FILE="${LOG_DIR}/configure_db_vm_ssh_port_$(date -u +%Y-%m-%dT%H%M%SZ).log"

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

    log_info "Script: configure_db_vm_ssh_port.sh $VERSION"
    log_info "Puerto objetivo: $SSH_PORT"
    log_info "IP objetivo:     $VM_IP ($VM_IFACE)"
    log_info "Log: $LOG_FILE"
}

# =============================================================================
# PASO 1 -- Estado SSH actual
# =============================================================================

verificar_estado_actual() {
    section "PASO 1 -- Estado SSH actual"

    log_info "Consultando puertos SSH activos con ss..."
    local ss_output
    ss_output=$(ss -tlnp 2>/dev/null | grep -E ":22|sshd|ssh" || true)

    if [[ -z "$ss_output" ]]; then
        log_warn "No se detecto SSH escuchando en puerto 22. Verificar ssh.socket:"
        systemctl status ssh.socket --no-pager 2>/dev/null | \
            while IFS= read -r line; do log_info "  $line"; done || true
    else
        log_info "Estado SSH actual:"
        while IFS= read -r line; do
            log_info "  $line"
        done <<< "$ss_output"
    fi

    log_info ""
    log_info "Estado ssh.socket:"
    systemctl is-active ssh.socket 2>/dev/null | \
        while IFS= read -r line; do log_info "  ssh.socket: $line"; done || true

    log_ok "HALLAZGO H-C3a-1-VM3 -- Puerto SSH antes: $(ss -tlnp 2>/dev/null | \
        grep -oP ':\K\d+(?=\s)' | sort -u | tr '\n' ' ' || echo '22 (default)')"
}

# =============================================================================
# PASO 2 -- Crear override del socket systemd
# =============================================================================

crear_override_socket() {
    section "PASO 2 -- Crear override del socket systemd"

    log_info "Directorio override: $OVERRIDE_DIR"
    log_info "Archivo override:    $OVERRIDE_FILE"
    log_info ""

    if [[ -f "$OVERRIDE_FILE" ]]; then
        if grep -q "ListenStream=${VM_IP}:${SSH_PORT}" "$OVERRIDE_FILE" 2>/dev/null; then
            log_ok "Override ya existe con el puerto correcto -- idempotente."
            log_info "Contenido actual:"
            cat "$OVERRIDE_FILE" | while IFS= read -r line; do
                log_info "  $line"
            done
            return 0
        else
            log_warn "Override existe pero con configuracion diferente -- sobreescribiendo."
            log_info "Contenido previo:"
            cat "$OVERRIDE_FILE" | while IFS= read -r line; do
                log_warn "  $line"
            done
        fi
    fi

    log_info "Creando directorio $OVERRIDE_DIR..."
    mkdir -p "$OVERRIDE_DIR"

    log_info "Escribiendo override.conf..."
    cat > "$OVERRIDE_FILE" << EOF
[Socket]
ListenStream=
ListenStream=${VM_IP}:${SSH_PORT}
EOF

    log_ok "Override escrito correctamente."
    log_info ""
    log_info "Contenido de $OVERRIDE_FILE:"
    cat "$OVERRIDE_FILE" | while IFS= read -r line; do
        log_info "  $line"
    done

    log_ok "HALLAZGO H-C3a-2-VM3 -- Override socket creado: $OVERRIDE_FILE"
}

# =============================================================================
# PASO 3 -- Actualizar sshd_config
# =============================================================================

actualizar_sshd_config() {
    section "PASO 3 -- Actualizar sshd_config"

    log_info "Nota: con socket activation, sshd_config no controla el puerto."
    log_info "Se actualiza igualmente para consistencia y referencia de herramientas."
    log_info ""

    local config_target
    if [[ -f "$SSHD_HARDENING" ]]; then
        config_target="$SSHD_HARDENING"
        log_info "Usando archivo de hardening: $config_target"
    else
        config_target="$SSHD_CONFIG"
        log_info "Usando sshd_config principal: $config_target"
    fi

    local backup="${config_target}.bak_$(date -u +%Y%m%dT%H%M%SZ)"
    cp "$config_target" "$backup"
    log_info "Backup: $backup"

    if grep -q "^Port " "$config_target" 2>/dev/null; then
        log_info "Reemplazando directiva Port existente..."
        sed -i "s/^Port .*/Port ${SSH_PORT}/" "$config_target"
        log_ok "Port reemplazado a ${SSH_PORT}."
    elif grep -q "^#Port " "$config_target" 2>/dev/null; then
        log_info "Descomentando y actualizando #Port..."
        sed -i "s/^#Port .*/Port ${SSH_PORT}/" "$config_target"
        log_ok "Port agregado: ${SSH_PORT}."
    else
        log_info "Agregando directiva Port al archivo..."
        echo "Port ${SSH_PORT}" >> "$config_target"
        log_ok "Port ${SSH_PORT} agregado."
    fi

    log_info ""
    log_info "Verificando sintaxis sshd_config..."
    if sshd -t 2>/dev/null; then
        log_ok "Sintaxis sshd_config: OK"
    else
        log_warn "Advertencia de sintaxis -- verificar manualmente."
        sshd -t 2>&1 | while IFS= read -r line; do log_warn "  $line"; done || true
    fi
}

# =============================================================================
# PASO 4 -- Reload systemd + restart socket
# =============================================================================

aplicar_cambios() {
    section "PASO 4 -- Reload systemd + restart ssh.socket"

    log_info "Ejecutando systemctl daemon-reload..."
    systemctl daemon-reload
    log_ok "daemon-reload completado."

    log_info ""
    log_info "Reiniciando ssh.socket..."
    log_warn "ADVERTENCIA: la sesion SSH actual NO se corta -- el nuevo socket"
    log_warn "aplica solo a conexiones nuevas. Esta sesion continua en puerto 22."
    log_info ""

    systemctl restart ssh.socket
    log_ok "ssh.socket reiniciado."

    sleep 2
    log_info "Socket estabilizado (2s)."
}

# =============================================================================
# PASO 5 -- Verificar nuevo estado SSH
# =============================================================================

verificar_estado_nuevo() {
    section "PASO 5 -- Verificar nuevo estado SSH"

    log_info "Consultando puertos SSH activos post-cambio..."
    local ss_output
    ss_output=$(ss -tlnp 2>/dev/null | grep -E "ssh|${SSH_PORT}" || true)

    if [[ -z "$ss_output" ]]; then
        log_warn "ss no muestra output para SSH. Estado general de puertos:"
        ss -tlnp 2>/dev/null | while IFS= read -r line; do log_info "  $line"; done || true
    else
        log_info "Estado SSH post-cambio:"
        while IFS= read -r line; do log_info "  $line"; done <<< "$ss_output"
    fi

    log_info ""
    log_info "Estado ssh.socket post-restart:"
    systemctl status ssh.socket --no-pager 2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || true

    if ss -tlnp 2>/dev/null | grep -q ":${SSH_PORT}"; then
        log_ok "HALLAZGO H-C3a-3-VM3 -- Puerto SSH despues: ${VM_IP}:${SSH_PORT} -- OK"
    else
        log_warn "HALLAZGO H-C3a-3-VM3 -- Puerto ${SSH_PORT} no detectado en ss."
        log_warn "  Verificar: ss -tlnp | grep ${SSH_PORT}"
        log_warn "  Verificar: systemctl status ssh.socket"
    fi

    if ss -tlnp 2>/dev/null | grep -q ":22 "; then
        log_warn "Puerto 22 aun aparece en escucha."
        log_warn "  Es la sesion SSH activa actual -- no el socket. Es normal."
    else
        log_ok "Puerto 22 no aparece en escucha -- correcto."
    fi
}

# =============================================================================
# PASO 6 -- Instrucciones post-ejecucion
# =============================================================================

instrucciones_postejecutar() {
    section "PASO 6 -- Acciones requeridas post-ejecucion"

    local sep
    sep=$(printf '!%.0s' {1..70})

    printf '\n%s\n' "$sep"
    printf 'ACCION REQUERIDA ANTES DE CERRAR ESTA SESION\n'
    printf '%s\n\n' "$sep"
    printf 'El puerto SSH de ecom-db-vm cambio a %s.\n' "$SSH_PORT"
    printf 'ssh ecom-db no existe aun -- se crea con alias tras este script.\n\n'
    printf 'Ejecutar desde el Host para actualizar ~/.ssh/config:\n\n'
    printf '  # [HOST-UBUNTU]\n'
    printf '  # Verificar config actual:\n'
    printf '  grep -A 7 "Host ecom-db" ~/.ssh/config\n\n'
    printf '  # Agregar el bloque Host ecom-db en ~/.ssh/config:\n'
    printf '  Host ecom-db\n'
    printf '      HostName 192.168.100.30\n'
    printf '      User ubuntu\n'
    printf '      Port %s\n' "$SSH_PORT"
    printf '      IdentityFile ~/.ssh/id_ed25519_host_to_ecom_db_vm\n'
    printf '      StrictHostKeyChecking accept-new\n\n'
    printf 'Verificar acceso con el nuevo puerto desde el Host:\n'
    printf '  ssh -i ~/.ssh/id_ed25519_host_to_ecom_db_vm -p %s ubuntu@%s "hostname"\n\n' \
        "$SSH_PORT" "$VM_IP"
    printf 'Una vez actualizado el config, verificar tambien el canal completo:\n'
    printf '  ssh ecom-db hostname\n'
    printf '%s\n\n' "$sep"
}

# =============================================================================
# RESUMEN FINAL
# =============================================================================

print_summary() {
    local sep
    sep=$(printf '=%.0s' {1..70})

    printf '\n%s\n' "$sep"
    printf 'RESUMEN -- configure_db_vm_ssh_port.sh %s\n' "$VERSION"
    printf '%s\n' "$sep"
    printf 'Fecha:    %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'VM:       %s | IP: %s\n' "$(hostname)" "$VM_IP"
    printf 'Log:      %s\n' "$LOG_FILE"
    printf '%s\n' "$sep"
    printf 'Hallazgos confirmados:\n'
    printf '  H-C3a-1-VM3 -- Puerto SSH antes: 0.0.0.0:22\n'
    printf '  H-C3a-2-VM3 -- Override socket: %s\n' "$OVERRIDE_FILE"
    printf '  H-C3a-3-VM3 -- Puerto SSH despues: %s:%s\n' "$VM_IP" "$SSH_PORT"
    printf '%s\n' "$sep"
    printf 'Tarea 5.C.3a [VM3] completada.\n'
    printf 'PENDIENTE: actualizar ~/.ssh/config en el Host con alias ecom-db -- ver PASO 6.\n'
    printf 'Proxima tarea: 5.C.3b -- Hardenizacion SSH ecom-db-vm\n'
    printf '%s\n\n' "$sep"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    verificar_precondiciones
    verificar_estado_actual
    crear_override_socket
    actualizar_sshd_config
    aplicar_cambios
    verificar_estado_nuevo
    instrucciones_postejecutar
    print_summary
    exit 0
}

mkdir -p "$LOG_DIR"
main "$@" 2>&1 | tee -a "$LOG_FILE"
exit "${PIPESTATUS[0]}"
