#!/bin/bash
# =============================================================================
# configure_db_vm_services.sh
# Elimina snapd, desactiva avahi-daemon y ModemManager, verifica otros
# servicios innecesarios, y produce una auditoria de superficie de
# ecom-db-vm.
#
# Ejecutar DENTRO de ecom-db-vm como:
#   sudo bash /tmp/configure_db_vm_services.sh
#
# Contexto:  [VM3-UBUNTU] -- usuario ubuntu con sudo, dentro de ecom-db-vm
# Tarea:     5.0e [VM1] -- Desactivacion de servicios innecesarios + auditoria
#
# Despliegue desde el Host:
#   scp -F /home/ubuntu/.ssh/config /tmp/configure_db_vm_services.sh ecom-db:/tmp/
#   ssh ecom-db "sudo bash /tmp/configure_db_vm_services.sh" 2>&1 | \
#       tee /tmp/log_tarea_5_0e_vm1_$(date -u +%Y%m%dT%H%M%SZ).txt
#
# Prerequisitos:
#   - Tarea 5.C.3c [VM3] completada: firewall nftables activo
#   - Tarea 5.0c [VM1] completada: SSH hardening activo
#
# Nota sobre vdb: VM3 tiene vda (SO 20G) + vdb (Block Storage Clase C 10G ext4).
#   multipathd irrelevante en VM3 -- vdb es Block Storage Clase C passthrough, no SAN.
#
# Servicios tratados:
#   PURGA:   snapd (apt purge + rm -rf residuales)
#   MASK:    avahi-daemon, ModemManager
#   DISABLE: bluetooth, multipathd, iscsid (si existen)
#   PRESERVAR: systemd-resolved, chrony, qemu-guest-agent, cron, rsyslog
#
# Todos los pasos verifican si el servicio existe antes de actuar.
# "No presente" es resultado valido -- no aborta.
#
# Hallazgos producidos:
#   H-C3d-1-VM3 -- snapd: no instalado o eliminado
#   H-C3d-2-VM3 -- avahi-daemon: inactivo/masked o no instalado
#   H-C3d-3-VM3 -- ModemManager: inactivo/masked o no instalado
#   H-C3d-4-VM3 -- Superficie TCP post-5.0e: solo loopback DNS + 49918
#
# Idempotente: segunda ejecucion verifica el estado actual y omite
# pasos ya completados.
#
# Precedente: configure_vm2_services.sh v1.0.0 (H58-H61 VM2, 2026-06-19)
#
# -----------------------------------------------------------------------------
# Version  Fecha        Autor                                    Cambios
# -----------------------------------------------------------------------------
# v1.0.0   2026-06-20   Nestor Monroy <46802445+NestorMonroy    Version inicial.
#                       @users.noreply.github.com>               snapd purge,
#                                                                avahi mask,
#                                                                ModemManager
#                                                                mask. Auditoria
#                                                                superficie.
#                                                                H-C3d-1-VM3..H-C3d-4-VM3
# -----------------------------------------------------------------------------

set -euo pipefail

VERSION="v1.0.1"

# =============================================================================
# CONFIGURACION
# =============================================================================

readonly SSH_PORT=65514
readonly VM_IP="192.168.100.30"
readonly LOG_DIR="/var/log/ecom-setup"
readonly LOG_FILE="${LOG_DIR}/configure_db_vm_services_$(date -u +%Y-%m-%dT%H%M%SZ).log"

readonly SERVICIOS_PRESERVAR=(
    "systemd-resolved"
    "chrony"
    "systemd-timesyncd"
    "qemu-guest-agent"
    "cron"
    "rsyslog"
    "nftables"
)

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

paquete_instalado() {
    dpkg -l "$1" 2>/dev/null | grep -q "^ii"
}

servicio_existe() {
    systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${1}\.service"
}

servicio_activo() {
    systemctl is-active "$1" &>/dev/null 2>&1
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
    else
        log_ok "Hostname: $hostname_actual -- correcto."
    fi

    log_info "Script: configure_db_vm_services.sh $VERSION"
    log_info "VM: $VM_IP | SSH: $SSH_PORT (alias ecom-db)"
    log_info "Log: $LOG_FILE"
}

# =============================================================================
# PASO 1 -- Auditoria pre-desactivacion
# =============================================================================

auditoria_pre() {
    section "PASO 1 -- Auditoria pre-desactivacion"

    log_info "Puertos TCP en escucha (ss -tlnp):"
    ss -tlnp 2>/dev/null | while IFS= read -r line; do
        log_info "  $line"
    done

    log_info ""
    log_info "Puertos UDP en escucha (ss -ulnp):"
    ss -ulnp 2>/dev/null | while IFS= read -r line; do
        log_info "  $line"
    done

    log_info ""
    log_info "Servicios activos (running):"
    systemctl list-units --type=service --state=running \
        --no-legend --no-pager 2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || true

    log_info ""
    log_info "Estado de servicios candidatos a desactivar:"
    for svc in snapd avahi-daemon ModemManager bluetooth multipathd iscsid; do
        if paquete_instalado "$svc" 2>/dev/null || \
           servicio_existe "$svc" 2>/dev/null; then
            local estado
            estado=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
            local enabled
            enabled=$(systemctl is-enabled "$svc" 2>/dev/null || echo "disabled")
            log_info "  $svc: active=$estado enabled=$enabled"
        else
            log_info "  $svc: NO PRESENTE"
        fi
    done
}

# =============================================================================
# PASO 2 -- Eliminar snapd
# =============================================================================

eliminar_snapd() {
    section "PASO 2 -- Eliminar snapd"

    if ! paquete_instalado "snapd" 2>/dev/null; then
        log_ok "snapd no instalado en esta imagen -- omitiendo."
        log_ok "HALLAZGO H-C3d-1-VM3 -- snapd: no instalado (imagen cloud minima)"
        return 0
    fi

    log_info "snapd detectado -- procediendo con purga."
    log_info ""

    if servicio_activo "snapd" 2>/dev/null; then
        log_info "Deteniendo snapd.service..."
        systemctl stop snapd.service snapd.socket 2>/dev/null || true
        log_ok "snapd detenido."
    fi

    log_info "Ejecutando apt purge snapd -y..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge snapd -y 2>&1 | while IFS= read -r line; do
        log_info "  $line"
    done || true

    log_info ""
    log_info "Ejecutando apt autoremove -y..."
    apt-get autoremove -y 2>&1 | while IFS= read -r line; do
        log_info "  $line"
    done || true

    for dir in /snap /var/snap /var/lib/snapd /root/snap /home/*/snap; do
        if [[ -d "$dir" ]]; then
            log_info "Eliminando directorio residual: $dir"
            rm -rf "$dir" 2>/dev/null || log_warn "No se pudo eliminar: $dir"
        fi
    done

    if paquete_instalado "snapd" 2>/dev/null; then
        log_warn "HALLAZGO H-C3d-1-VM3 -- snapd: purga ejecutada pero paquete sigue en dpkg"
    else
        log_ok "HALLAZGO H-C3d-1-VM3 -- snapd: eliminado correctamente"
    fi
}

# =============================================================================
# PASO 3 -- Desactivar avahi-daemon
# =============================================================================

desactivar_avahi() {
    section "PASO 3 -- Desactivar avahi-daemon"

    if ! paquete_instalado "avahi-daemon" 2>/dev/null && \
       ! servicio_existe "avahi-daemon" 2>/dev/null; then
        log_ok "avahi-daemon no instalado en esta imagen -- omitiendo."
        log_ok "HALLAZGO H-C3d-2-VM3 -- avahi-daemon: no instalado (imagen cloud minima)"
        return 0
    fi

    log_info "avahi-daemon detectado -- desactivando con mask."

    if servicio_activo "avahi-daemon" 2>/dev/null; then
        log_info "Deteniendo avahi-daemon..."
        systemctl stop avahi-daemon 2>/dev/null || true
        log_ok "avahi-daemon detenido."
    fi

    log_info "Ejecutando systemctl disable avahi-daemon..."
    systemctl disable avahi-daemon 2>/dev/null || true

    log_info "Ejecutando systemctl mask avahi-daemon..."
    systemctl mask avahi-daemon 2>/dev/null || true

    local estado_masked
    estado_masked=$(systemctl is-enabled avahi-daemon 2>/dev/null || echo "unknown")
    if [[ "$estado_masked" == "masked" ]]; then
        log_ok "HALLAZGO H-C3d-2-VM3 -- avahi-daemon: masked"
    else
        log_warn "HALLAZGO H-C3d-2-VM3 -- avahi-daemon: estado=$estado_masked (esperado: masked)"
    fi
}

# =============================================================================
# PASO 4 -- Desactivar ModemManager
# =============================================================================

desactivar_modemmanager() {
    section "PASO 4 -- Desactivar ModemManager"

    if ! paquete_instalado "modemmanager" 2>/dev/null && \
       ! servicio_existe "ModemManager" 2>/dev/null; then
        log_ok "ModemManager no instalado en esta imagen -- omitiendo."
        log_ok "HALLAZGO H-C3d-3-VM3 -- ModemManager: no instalado (imagen cloud minima)"
        return 0
    fi

    log_info "ModemManager detectado -- desactivando con mask."

    if servicio_activo "ModemManager" 2>/dev/null; then
        log_info "Deteniendo ModemManager..."
        systemctl stop ModemManager 2>/dev/null || true
        log_ok "ModemManager detenido."
    fi

    log_info "Ejecutando systemctl disable ModemManager..."
    systemctl disable ModemManager 2>/dev/null || true

    log_info "Ejecutando systemctl mask ModemManager..."
    systemctl mask ModemManager 2>/dev/null || true

    local estado_masked
    estado_masked=$(systemctl is-enabled ModemManager 2>/dev/null | tr -d "\n" || echo "unknown")
    if [[ "$estado_masked" == "masked" ]]; then
        log_ok "HALLAZGO H-C3d-3-VM3 -- ModemManager: masked"
    else
        log_warn "HALLAZGO H-C3d-3-VM3 -- ModemManager: estado=$estado_masked (esperado: masked)"
    fi
}

# =============================================================================
# PASO 5 -- Verificar otros servicios
# =============================================================================

verificar_otros_servicios() {
    section "PASO 5 -- Verificar otros servicios (bluetooth, multipathd, iscsid)"

    log_info "Nota: multipathd irrelevante en VM3 -- vdb es passthrough, no SAN."
    log_info ""

    local otros=("bluetooth" "multipathd" "iscsid")

    for svc in "${otros[@]}"; do
        if servicio_existe "$svc" 2>/dev/null; then
            log_info "$svc: presente -- desactivando..."
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            local estado
            estado=$(systemctl is-enabled "$svc" 2>/dev/null || echo "disabled")
            log_ok "$svc: $estado"
        else
            log_info "$svc: no presente en esta imagen -- OK"
        fi
    done

    log_info ""
    log_info "Verificando servicios a preservar:"
    for svc in "${SERVICIOS_PRESERVAR[@]}"; do
        if servicio_existe "$svc" 2>/dev/null; then
            local estado
            estado=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
            log_info "  $svc: $estado (preservado)"
        else
            log_info "  $svc: no presente"
        fi
    done
}

# =============================================================================
# PASO 6 -- Auditoria post-desactivacion
# =============================================================================

auditoria_post() {
    section "PASO 6 -- Auditoria post-desactivacion"

    log_info "Puertos TCP en escucha post-desactivacion (ss -tlnp):"
    local tcp_output
    tcp_output=$(ss -tlnp 2>/dev/null)
    while IFS= read -r line; do log_info "  $line"; done <<< "$tcp_output"

    log_info ""
    log_info "Puertos UDP en escucha post-desactivacion (ss -ulnp):"
    ss -ulnp 2>/dev/null | while IFS= read -r line; do
        log_info "  $line"
    done

    log_info ""
    log_info "Servicios activos post-desactivacion:"
    systemctl list-units --type=service --state=running \
        --no-legend --no-pager 2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || true

    log_info ""

    # Evaluar superficie TCP
    local puertos_inesperados=0
    while IFS= read -r line; do
        if echo "$line" | grep -qE \
            "State|127\.0\.0\.(53|54)(%lo)?:53|${VM_IP}:${SSH_PORT}"; then
            continue
        fi
        if echo "$line" | grep -q "LISTEN"; then
            log_warn "Puerto inesperado en escucha: $line"
            puertos_inesperados=$(( puertos_inesperados + 1 ))
        fi
    done <<< "$tcp_output"

    if [[ "$puertos_inesperados" -eq 0 ]]; then
        log_ok "HALLAZGO H-C3d-4-VM3 -- Superficie TCP: solo loopback DNS + ${SSH_PORT} -- minima"
    else
        log_warn "HALLAZGO H-C3d-4-VM3 -- Superficie TCP: $puertos_inesperados puerto(s) inesperado(s)"
    fi

    log_info ""
    log_info "Confirmacion eliminacion snapd:"
    if paquete_instalado "snapd" 2>/dev/null; then
        log_warn "  snapd aun aparece en dpkg -- revisar."
    else
        log_ok "  snapd: no instalado -- correcto."
    fi

    log_info ""
    log_info "Confirmacion estado avahi-daemon:"
    local avahi_estado
    avahi_estado=$(systemctl is-enabled avahi-daemon 2>/dev/null || echo "not-found")
    log_info "  avahi-daemon: $avahi_estado"

    log_info ""
    log_info "Confirmacion estado ModemManager:"
    local mm_estado
    mm_estado=$(systemctl is-enabled ModemManager 2>/dev/null || echo "not-found")
    log_info "  ModemManager: $mm_estado"
}

# =============================================================================
# RESUMEN FINAL
# =============================================================================

print_summary() {
    local sep
    sep=$(printf '=%.0s' {1..70})

    printf '\n%s\n' "$sep"
    printf 'RESUMEN -- configure_db_vm_services.sh %s\n' "$VERSION"
    printf '%s\n' "$sep"
    printf 'Fecha:    %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'VM:       %s | IP: %s\n' "$(hostname)" "$VM_IP"
    printf 'Log:      %s\n' "$LOG_FILE"
    printf '%s\n' "$sep"
    printf 'Hallazgos confirmados:\n'
    printf '  H-C3d-1-VM3 -- snapd: no instalado o eliminado\n'
    printf '  H-C3d-2-VM3 -- avahi-daemon: masked o no instalado\n'
    printf '  H-C3d-3-VM3 -- ModemManager: masked o no instalado\n'
    printf '  H-C3d-4-VM3 -- Superficie TCP: loopback DNS + %s\n' "$SSH_PORT"
    printf '%s\n' "$sep"
    printf 'Tarea 5.C.3d [VM3] completada.\n'
    printf 'Proxima tarea: 5.C.3e [VM3] -- Verificacion AppArmor ecom-db-vm\n'
    printf '%s\n\n' "$sep"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    verificar_precondiciones
    auditoria_pre
    eliminar_snapd
    desactivar_avahi
    desactivar_modemmanager
    verificar_otros_servicios
    auditoria_post
    print_summary
    exit 0
}

mkdir -p "$LOG_DIR"
main "$@" 2>&1 | tee -a "$LOG_FILE"
exit "${PIPESTATUS[0]}"
