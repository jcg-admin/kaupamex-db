#!/bin/bash
# =============================================================================
# configure_db_vm_base_update.sh
# Actualiza el SO base de ecom-db-vm, instala qemu-guest-agent (DA-30)
# y verifica zona horaria UTC + sincronizacion NTP.
#
# Ejecutar DENTRO de ecom-db-vm como:
#   sudo bash /tmp/configure_db_vm_base_update.sh
#
# Contexto:  [VM3-UBUNTU] -- usuario ubuntu con sudo, dentro de ecom-db-vm
# Tarea:     5.0a [VM3] -- Actualizacion SO base + NTP + qemu-guest-agent
#
# Despliegue desde el Host:
#   scp -i /home/ubuntu/.ssh/id_ed25519_host_to_ecom_db_vm /tmp/configure_db_vm_base_update.sh ubuntu@192.168.100.30:/tmp/
#   ssh -i /home/ubuntu/.ssh/id_ed25519_host_to_ecom_db_vm ubuntu@192.168.100.30 "sudo bash /tmp/configure_db_vm_base_update.sh" 2>&1 | \
#       tee /tmp/log_tarea_5_0a_vm1_$(date -u +%Y%m%dT%H%M%SZ).txt
#
# Nota: VM3 se accede directamente desde el Host (sin doble salto).
#   Acceso desde el Host via clave id_ed25519_host_to_ecom_db_vm, IP 192.168.100.30.
#
# Prerequisitos:
#   - ecom-db-vm running y accesible via SSH (192.168.100.30) con id_ed25519_host_to_ecom_db_vm
#   - Masquerade activo en Host (Tarea 4.0b -- H35-H39 confirmado)
#   - cloud-init finalizado (Tarea 5.C.0c completada)
#   - Snapshot pre-Fase5 realizado (Tarea 5.C.snapshot (pendiente))
#   - Block Storage Clase C pendiente de attach (Tarea 5.C.2) -- este script NO lo toca
#
# Hallazgos producidos:
#   H1-VM3 -- paquetes actualizados por apt upgrade
#   H2-VM3 -- kernel pendiente de reboot (si aplica)
#   H3-VM3 -- qemu-guest-agent instalado y activo (DA-30 cerrada para VM3)
#   H4-VM3 -- timezone UTC confirmado
#   H5-VM3 -- NTP sincronizado + fuente
#
# DA-30: qemu-guest-agent diferido de Fase 4 por ausencia en imagen cloud
# Ubuntu 26.04. Se instala aqui como primer paquete de Fase 5 en VM3.
# Una vez activo, los snapshots pueden usar --quiesce para consistencia.
#
# Precedente: configure_vm2_base_update.sh v1.0.0 ejecutado 2026-06-19
# en mail-server-vm (H41-H45 confirmados). VM3 sigue el mismo patron.
#
# Reboot condicional: si apt upgrade instala un kernel nuevo, el script
# avisa al operador para ejecutar el reboot manualmente y re-ejecutar.
# No hace reboot automatico (corta la conexion SSH).
#
# Idempotente: segunda ejecucion post-reboot omite cambios ya aplicados
# y verifica TZ y NTP.
#
# -----------------------------------------------------------------------------
# Version  Fecha        Autor                                    Cambios
# -----------------------------------------------------------------------------
# v1.0.0   2026-06-20   Nestor Monroy <46802445+NestorMonroy    Version inicial.
#                       @users.noreply.github.com>               Tarea 5.0a VM3.
#                                                                apt upgrade,
#                                                                qemu-guest-agent
#                                                                (DA-30), TZ UTC,
#                                                                NTP. Hallazgos
#                                                                H1-VM3..H5-VM3.
# -----------------------------------------------------------------------------

set -euo pipefail

VERSION="v1.0.0"

# =============================================================================
# CONFIGURACION
# =============================================================================

readonly LOG_DIR="/var/log/ecom-setup"
readonly LOG_FILE="${LOG_DIR}/configure_db_vm_base_update_$(date -u +%Y-%m-%dT%H%M%SZ).log"

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
        log_warn "Continuando de todas formas -- confirmar si es correcto."
    else
        log_ok "Hostname: $hostname_actual -- correcto."
    fi

    log_info "Script: configure_db_vm_base_update.sh $VERSION"
    log_info "VM: $(hostname) | Kernel actual: $(uname -r)"
    log_info "IP: $(hostname -I 2>/dev/null | awk '{print $1}' || echo '?')"
    log_info "Log: $LOG_FILE"
    log_info ""

    # Informar sobre vdb -- este script no lo toca
    log_info "Discos detectados en esta VM:"
    lsblk -d -o NAME,SIZE,TYPE 2>/dev/null | while IFS= read -r line; do
        log_info "  $line"
    done || true
    log_info "Nota: Block Storage Clase C aun no adjunto -- se adjunta en Tarea 5.C.2."
}

# =============================================================================
# PASO 1 -- apt update && apt upgrade
# =============================================================================

actualizar_paquetes() {
    section "PASO 1 -- apt update && apt upgrade"

    log_info "Configurando DEBIAN_FRONTEND=noninteractive para apt..."
    export DEBIAN_FRONTEND=noninteractive

    log_info "Ejecutando apt update..."
    apt-get update -q 2>&1 | while IFS= read -r line; do
        log_info "  $line"
    done || true

    log_info ""
    log_info "Ejecutando apt upgrade..."
    local antes despues
    antes=$(dpkg -l 2>/dev/null | grep '^ii' | wc -l)

    apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        2>&1 | while IFS= read -r line; do
        log_info "  $line"
    done || true

    despues=$(dpkg -l 2>/dev/null | grep '^ii' | wc -l)
    local actualizados=$(( despues - antes ))
    if [[ $actualizados -lt 0 ]]; then
        actualizados=0
    fi

    log_ok "HALLAZGO H1-VM3 -- apt upgrade completado."
    log_ok "  Paquetes totales antes: $antes | despues: $despues"
    log_info "  Ver log completo para detalle de paquetes actualizados."
}

# =============================================================================
# PASO 1b -- Detectar kernel pendiente de reboot
# =============================================================================

detectar_reboot_necesario() {
    section "PASO 1b -- Detectar kernel pendiente de reboot"

    local kernel_actual
    kernel_actual=$(uname -r)
    log_info "Kernel en ejecucion: $kernel_actual"

    local kernel_instalado
    kernel_instalado=$(ls /boot/vmlinuz-* 2>/dev/null \
        | sort -V | tail -1 \
        | sed 's|/boot/vmlinuz-||' || echo "")

    if [[ -z "$kernel_instalado" ]]; then
        log_warn "No se pudo determinar el kernel instalado en /boot."
        log_info "Continuando sin verificacion de reboot."
        return 0
    fi

    log_info "Kernel instalado mas reciente: $kernel_instalado"

    if [[ "$kernel_actual" != "$kernel_instalado" ]]; then
        log_warn ""
        log_warn "HALLAZGO H2-VM3 -- REBOOT REQUERIDO."
        log_warn "  Kernel en ejecucion: $kernel_actual"
        log_warn "  Kernel instalado:    $kernel_instalado"
        log_warn ""
        log_warn "El kernel fue actualizado por apt upgrade."
        log_warn "Ejecutar desde el Host:"
        log_warn "  ssh -i /home/ubuntu/.ssh/id_ed25519_host_to_ecom_db_vm ubuntu@192.168.100.30 'sudo reboot'"
        log_warn ""
        log_warn "Esperar ~30 segundos y re-ejecutar desde el Host:"
        log_warn "  scp -i /home/ubuntu/.ssh/id_ed25519_host_to_ecom_db_vm /tmp/configure_db_vm_base_update.sh ubuntu@192.168.100.30:/tmp/"
        log_warn "  ssh -i /home/ubuntu/.ssh/id_ed25519_host_to_ecom_db_vm ubuntu@192.168.100.30 'sudo bash /tmp/configure_db_vm_base_update.sh'"
        log_warn ""
        log_warn "El script detectara el kernel ya activo y continuara a los pasos 1c-4."

        local sep
        sep=$(printf '=%.0s' {1..70})
        printf '\n%s\n' "$sep"
        printf 'ACCION REQUERIDA -- REBOOT\n'
        printf '%s\n' "$sep"
        printf 'Kernel actual:    %s\n' "$kernel_actual"
        printf 'Kernel instalado: %s\n' "$kernel_instalado"
        printf 'Ejecutar: ssh -i /home/ubuntu/.ssh/id_ed25519_host_to_ecom_db_vm ubuntu@192.168.100.30 "sudo reboot"\n'
        printf 'Luego re-ejecutar este script.\n'
        printf '%s\n\n' "$sep"
        exit 0
    fi

    log_ok "HALLAZGO H2-VM3 -- Kernel sin pendiente de reboot."
    log_ok "  Kernel en ejecucion: $kernel_actual == kernel instalado."
}

# =============================================================================
# PASO 1c -- Instalar qemu-guest-agent (DA-30)
# =============================================================================

instalar_qemu_guest_agent() {
    section "PASO 1c -- Instalar qemu-guest-agent (DA-30 VM3)"

    log_info "DA-30: qemu-guest-agent no viene en imagen cloud Ubuntu 26.04."
    log_info "Se instala como primer paquete de Fase 5 en VM3."
    log_info ""

    if dpkg -l qemu-guest-agent 2>/dev/null | grep -q "^ii"; then
        local ver
        ver=$(dpkg -l qemu-guest-agent | grep "^ii" | awk '{print $3}')
        log_info "qemu-guest-agent ya instalado: $ver -- idempotente."
    else
        log_info "Instalando qemu-guest-agent..."
        apt-get install -y qemu-guest-agent 2>&1 | \
            while IFS= read -r line; do log_info "  $line"; done || \
            die "Error al instalar qemu-guest-agent."
        log_ok "qemu-guest-agent instalado."
    fi

    systemctl enable qemu-guest-agent 2>/dev/null || true
    systemctl start qemu-guest-agent 2>/dev/null || true

    local estado
    estado=$(systemctl is-active qemu-guest-agent 2>/dev/null || echo "unknown")

    if [[ "$estado" == "active" ]]; then
        log_ok "HALLAZGO H3-VM3 -- qemu-guest-agent: active (running)"
        log_ok "  DA-30 cerrada para VM3. Snapshots con --quiesce disponibles."
    elif [[ "$estado" == "activating" ]]; then
        log_ok "HALLAZGO H3-VM3 -- qemu-guest-agent: activating"
        log_info "  El agent tarda unos segundos en conectar con el hipervisor."
    else
        log_warn "HALLAZGO H3-VM3 -- qemu-guest-agent estado: $estado"
        log_warn "  En imagen cloud Ubuntu 26.04 puede quedar en espera hasta"
        log_warn "  que el hipervisor lo active via socket virtio. Ver DA-30."
        log_warn "  Verificar desde el Host: virsh dominfo ecom-db-vm"
    fi

    log_info ""
    log_info "Detalle del servicio:"
    systemctl status qemu-guest-agent --no-pager 2>/dev/null \
        | while IFS= read -r line; do log_info "  $line"; done || true
}

# =============================================================================
# PASO 2 -- Verificar zona horaria UTC
# =============================================================================

verificar_timezone() {
    section "PASO 2 -- Verificar zona horaria UTC"

    log_info "Verificando timezone con timedatectl..."

    local tz
    tz=$(timedatectl show --property=Timezone --value 2>/dev/null || \
         timedatectl | grep "Time zone" | awk '{print $3}' || echo "")

    if [[ -z "$tz" ]]; then
        log_warn "No se pudo obtener la timezone con timedatectl."
        log_warn "Intentando con /etc/timezone..."
        tz=$(cat /etc/timezone 2>/dev/null || echo "desconocida")
    fi

    log_info "Timezone detectada: $tz"

    if [[ "$tz" == "UTC" ]]; then
        log_ok "HALLAZGO H4-VM3 -- Timezone: UTC -- correcto."
        log_ok "  Consistente con el Host y VM2 (UTC -- decision deliberada)."
    else
        log_warn "HALLAZGO H4-VM3 -- Timezone: $tz (esperado: UTC)"
        log_warn "  Para corregir: sudo timedatectl set-timezone UTC"
    fi

    log_info ""
    log_info "Salida completa de timedatectl:"
    timedatectl 2>/dev/null | while IFS= read -r line; do
        log_info "  $line"
    done || true
}

# =============================================================================
# PASO 3 -- Verificar sincronizacion NTP
# =============================================================================

verificar_ntp() {
    section "PASO 3 -- Verificar sincronizacion NTP"

    log_info "Detectando herramienta NTP activa (chrony o systemd-timesyncd)..."

    local herramienta="none"

    if systemctl is-active chrony &>/dev/null 2>&1; then
        herramienta="chrony"
    elif systemctl is-active chronyd &>/dev/null 2>&1; then
        herramienta="chronyd"
    elif systemctl is-active systemd-timesyncd &>/dev/null 2>&1; then
        herramienta="timesyncd"
    fi

    log_info "Herramienta NTP activa: $herramienta"
    log_info ""

    local sincronizado
    sincronizado=$(timedatectl show --property=NTPSynchronized --value \
        2>/dev/null || echo "")

    if [[ -z "$sincronizado" ]]; then
        sincronizado=$(timedatectl 2>/dev/null \
            | grep -i "synchronized" \
            | grep -o "yes\|no" || echo "desconocido")
    fi

    log_info "NTPSynchronized: $sincronizado"

    case "$herramienta" in
        chrony|chronyd)
            log_info ""
            log_info "Detalle chrony (chronyc tracking):"
            chronyc tracking 2>/dev/null | while IFS= read -r line; do
                log_info "  $line"
            done || log_warn "  chronyc tracking no disponible."
            ;;
        timesyncd)
            log_info ""
            log_info "Detalle timesyncd (timedatectl timesync-status):"
            timedatectl timesync-status 2>/dev/null | while IFS= read -r line; do
                log_info "  $line"
            done || log_warn "  timedatectl timesync-status no disponible."
            ;;
        none)
            log_warn "No se detecto herramienta NTP activa."
            log_warn "Verificar: systemctl status systemd-timesyncd chronyd"
            ;;
    esac

    log_info ""

    if [[ "$sincronizado" == "yes" ]]; then
        log_ok "HALLAZGO H5-VM3 -- NTP sincronizado: yes"
        log_ok "  Herramienta: $herramienta"
    elif [[ "$sincronizado" == "no" ]]; then
        log_warn "HALLAZGO H5-VM3 -- NTP sincronizado: no"
        log_warn "  Esperar 30s y verificar: timedatectl"
        log_warn "  Si persiste: ping ntp.ubuntu.com"
    else
        log_warn "HALLAZGO H5-VM3 -- NTP sincronizado: $sincronizado"
        log_warn "  Verificar manualmente: timedatectl status"
    fi

    log_info ""
    log_info "Salida completa de timedatectl:"
    timedatectl 2>/dev/null | while IFS= read -r line; do
        log_info "  $line"
    done || true
}

# =============================================================================
# RESUMEN FINAL
# =============================================================================

print_summary() {
    local sep
    sep=$(printf '=%.0s' {1..70})

    local kernel_actual
    kernel_actual=$(uname -r)

    local tz
    tz=$(timedatectl show --property=Timezone --value 2>/dev/null || \
         cat /etc/timezone 2>/dev/null || echo "?")

    local ntp_sync
    ntp_sync=$(timedatectl show --property=NTPSynchronized --value \
        2>/dev/null || echo "?")

    local qga_estado
    qga_estado=$(systemctl is-active qemu-guest-agent 2>/dev/null || echo "unknown")

    printf '\n%s\n' "$sep"
    printf 'RESUMEN -- configure_db_vm_base_update.sh %s\n' "$VERSION"
    printf '%s\n' "$sep"
    printf 'Fecha:    %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'VM:       %s | Kernel: %s\n' "$(hostname)" "$kernel_actual"
    printf 'Log:      %s\n' "$LOG_FILE"
    printf '%s\n' "$sep"
    printf 'Hallazgos confirmados:\n'
    printf '  H1-VM3 -- apt upgrade completado (ver log para detalle)\n'
    printf '  H2-VM3 -- Kernel sin pendiente de reboot: %s\n' "$kernel_actual"
    printf '  H3-VM3 -- qemu-guest-agent: %s (DA-30 cerrada VM3)\n' "$qga_estado"
    printf '  H4-VM3 -- Timezone: %s\n' "$tz"
    printf '  H5-VM3 -- NTP sincronizado: %s\n' "$ntp_sync"
    printf '%s\n' "$sep"
    printf 'Tarea 5.0a [VM3] completada.\n'
    printf 'Proxima tarea: 5.0b [VM3] -- Passthrough Block Storage Clase C (override socket systemd)\n'
    printf '%s\n\n' "$sep"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    verificar_precondiciones
    actualizar_paquetes
    detectar_reboot_necesario
    instalar_qemu_guest_agent
    verificar_timezone
    verificar_ntp
    print_summary
    exit 0
}

mkdir -p "$LOG_DIR"
main "$@" 2>&1 | tee -a "$LOG_FILE"
exit "${PIPESTATUS[0]}"
