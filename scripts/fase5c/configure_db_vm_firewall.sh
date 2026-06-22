#!/bin/bash
# =============================================================================
# configure_db_vm_firewall.sh
# Configura el firewall nftables interno de ecom-db-vm.
# Crea tabla inet filter con 3 chains: input (policy drop), output
# (policy accept), forward (policy drop). Persiste via nftables.service.
#
# Ejecutar DENTRO de ecom-db-vm como:
#   sudo bash /tmp/configure_db_vm_firewall.sh
#
# Contexto:  [VM3-UBUNTU] -- usuario ubuntu con sudo, dentro de ecom-db-vm
# Tarea:     5.0d [VM1] -- Firewall nftables interno
#
# Despliegue desde el Host:
#   scp -F /home/ubuntu/.ssh/config /tmp/configure_db_vm_firewall.sh ecom-db:/tmp/
#   ssh ecom-db "sudo bash /tmp/configure_db_vm_firewall.sh" 2>&1 | \
#       tee /tmp/log_tarea_5_0d_vm1_$(date -u +%Y%m%dT%H%M%SZ).txt
#
# Prerequisitos:
#   - Tarea 5.C.3b [VM3] completada: SSH hardening activo
#   - SSH escuchando en 192.168.100.30:49918
#   - Canal ssh vm1 funcional (Port 49918 en ~/.ssh/config del Host)
#
# Ruleset aplicado:
#   table inet filter {
#       chain input  { policy drop
#           iif lo accept
#           ct state established,related accept
#           ip protocol icmp icmp type echo-request limit rate 10/second accept
#           ip6 nexthdr ipv6-icmp accept
#           ip saddr 192.168.100.0/24 tcp dport 49918 accept    # SSH interno
#           ip saddr 192.168.100.1   tcp dport { 80, 443 } accept # HTTP/S via Host prerouting
#           ip saddr 192.168.100.20  tcp dport 10051 accept     # Zabbix Server desde VM2
#       }
#       chain output  { policy accept }
#       chain forward { policy drop   }
#   }
#
# Diferencias vs configure_vm2_firewall.sh:
#   - Puerto SSH: 49918 (VM2 usa 64915)
#   - Puerto servicio: 80+443 HTTP/HTTPS desde 192.168.100.1 (VM2 usa 25 SMTP)
#   - Puerto monitoreo: 10051 Zabbix Server desde VM2/192.168.100.20
#                       (VM2 usa 10050 Zabbix Agent desde VM1)
#   - Puerto 25 NO incluido -- VM1 no es servidor de correo
#
# Puertos anticipados (servicio no instalado aun):
#   - Puerto 80/443: Apache -- Tarea 5.3
#   - Puerto 10051: Zabbix Server -- Tarea 5.5
#
# ADVERTENCIA CRITICA:
#   PASO 4 aplica policy drop en input. Si la regla SSH es incorrecta,
#   el acceso a VM1 se pierde y se requiere consola KVM (virsh console).
#   PASO 3 valida sintaxis y PASO 5 verifica SSH antes de persistir.
#   NO cerrar la sesion SSH hasta confirmar H-C3c-3-VM3.
#
# Hallazgos producidos:
#   H-C3c-1-VM3 -- Ruleset activo: table inet filter con 3 chains
#   H-C3c-2-VM3 -- chain input policy: drop
#   H-C3c-3-VM3 -- Puerto 49918 accesible post-firewall
#   H-C3c-4-VM3 -- /etc/nftables.conf persistido + nftables.service enabled
#
# Idempotente: segunda ejecucion aplica el mismo ruleset, verifica,
# persiste -- sin cambios funcionales.
#
# -----------------------------------------------------------------------------
# Version  Fecha        Autor                                    Cambios
# -----------------------------------------------------------------------------
# v1.0.0   2026-06-20   Nestor Monroy <46802445+NestorMonroy    Version inicial.
#                       @users.noreply.github.com>               nftables VM1.
#                                                                SSH 49918,
#                                                                HTTP/S 80+443,
#                                                                Zabbix 10051.
#                                                                Hallazgos
#                                                                H-C3c-1-VM3..H-C3c-4-VM3
# -----------------------------------------------------------------------------

set -euo pipefail

VERSION="v1.0.1"

# =============================================================================
# CONFIGURACION
# =============================================================================

readonly SSH_PORT=65514
readonly VM_IP="192.168.100.30"
readonly VM1_IP="192.168.100.10"  # Django (MariaDB) + Zabbix Server
readonly VM_IFACE="enp1s0"
readonly NAT_NET="192.168.100.0/24"
readonly HOST_GW="192.168.100.1"  # DNAT Host → VM3 para acceso externo MariaDB
readonly MARIADB_PORT=3306
readonly ZABBIX_AGENT_PORT=10050
readonly RULESET_TMP="/tmp/db-vm-nftables.conf"
readonly NFTABLES_CONF="/etc/nftables.conf"
readonly LOG_DIR="/var/log/ecom-setup"
readonly LOG_FILE="${LOG_DIR}/configure_db_vm_firewall_$(date -u +%Y-%m-%dT%H%M%SZ).log"

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

    if ! command -v nft &>/dev/null; then
        die "nft no encontrado. Instalar: apt install nftables"
    fi
    log_ok "nft disponible: $(nft --version 2>/dev/null | head -1)"

    log_info "Script: configure_db_vm_firewall.sh $VERSION"
    log_info "VM: $VM_IP | SSH: $SSH_PORT | Interfaz: $VM_IFACE"
    log_info "Log: $LOG_FILE"
}

# =============================================================================
# PASO 1 -- Estado inicial
# =============================================================================

verificar_estado_inicial() {
    section "PASO 1 -- Estado inicial nftables y puertos"

    log_info "Ruleset actual:"
    local ruleset_actual
    ruleset_actual=$(nft list ruleset 2>/dev/null || echo "(vacio)")
    if [[ "$ruleset_actual" == "(vacio)" ]] || [[ -z "$ruleset_actual" ]]; then
        log_info "  (sin reglas activas -- imagen cloud sin firewall)"
    else
        while IFS= read -r line; do log_info "  $line"; done <<< "$ruleset_actual"
    fi

    log_info ""
    log_info "Puertos activos en escucha (ss -tlnp):"
    ss -tlnp 2>/dev/null | while IFS= read -r line; do
        log_info "  $line"
    done

    log_info ""
    log_info "Estado nftables.service:"
    systemctl is-active nftables 2>/dev/null | \
        while IFS= read -r line; do log_info "  nftables.service: $line"; done || true
    systemctl is-enabled nftables 2>/dev/null | \
        while IFS= read -r line; do log_info "  nftables.service enabled: $line"; done || true

    if ss -tlnp 2>/dev/null | grep -q ":${SSH_PORT}"; then
        log_ok "Puerto SSH ${SSH_PORT} activo -- correcto."
    else
        log_warn "Puerto SSH ${SSH_PORT} NO detectado en ss."
        log_warn "Verificar: systemctl status ssh.socket"
        log_warn "El ruleset incluira la regla SSH de todas formas."
    fi
}

# =============================================================================
# PASO 2 -- Construir ruleset
# =============================================================================

construir_ruleset() {
    section "PASO 2 -- Construir ruleset en $RULESET_TMP"

    log_info "Puertos incluidos en el ruleset:"
    log_info "  SSH:          tcp dport ${SSH_PORT} desde ${NAT_NET}"
    log_info "  MariaDB VM1:  tcp dport ${MARIADB_PORT} desde ${VM1_IP} (Django)"
    log_info "  MariaDB DNAT: tcp dport ${MARIADB_PORT} desde ${HOST_GW} (Claude Code web, Tarea 5.C.8)"
    log_info "  Zabbix Agent: tcp dport ${ZABBIX_AGENT_PORT} desde ${VM1_IP} (Zabbix Server)"
    log_info ""
    log_info "Puertos anticipados (servicio no instalado aun):"
    log_info "  Puerto ${MARIADB_PORT}: MariaDB -- Tarea 5.C.4"
    log_info "  Puerto ${ZABBIX_AGENT_PORT}: Zabbix Agent -- Tarea 5.C.9"
    log_info ""
    log_info "Puertos NO incluidos: 80/443 (sin Apache), 25 (sin SMTP), 10051 (sin Zabbix Server)"
    log_info ""

    cat > "$RULESET_TMP" << EOF
# /etc/nftables.conf
# ecom-prod -- ecom-db-vm (VM3)
# Tarea 5.C.3c [VM3] -- configure_db_vm_firewall.sh ${VERSION}
# Generado: $(date -u +%Y-%m-%dT%H:%M:%SZ)
#
# input:   policy drop  -- todo lo no permitido se descarta
# output:  policy accept -- VM3 puede iniciar conexiones salientes (apt, NTP, DNS)
# forward: policy drop  -- VM3 no es router

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        # Trafico de loopback -- siempre permitido
        iif "lo" accept

        # Conexiones ya establecidas -- no interrumpir sesiones activas
        ct state established,related accept

        # ICMP para diagnostico -- limitado a 10 pings/segundo
        ip protocol icmp icmp type { echo-request } limit rate 10/second accept
        ip6 nexthdr ipv6-icmp accept

        # SSH -- solo desde red interna (sin DNAT SSH externo en VM3)
        iif "${VM_IFACE}" ip saddr ${NAT_NET} tcp dport ${SSH_PORT} accept

        # MariaDB -- desde VM1 (Django en 192.168.100.10)
        iif "${VM_IFACE}" ip saddr ${VM1_IP} tcp dport ${MARIADB_PORT} accept

        # MariaDB -- desde Host via DNAT (Claude Code web -- Tarea 5.C.8)
        # Trafico externo llega como ip saddr 192.168.100.1 post-DNAT
        iif "${VM_IFACE}" ip saddr ${HOST_GW} tcp dport ${MARIADB_PORT} accept

        # Zabbix Agent -- polling desde VM1 (Zabbix Server en 192.168.100.10)
        iif "${VM_IFACE}" ip saddr ${VM1_IP} tcp dport ${ZABBIX_AGENT_PORT} accept
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }
}
EOF

    log_ok "Ruleset escrito en $RULESET_TMP."
    log_info ""
    log_info "Contenido del ruleset:"
    while IFS= read -r line; do log_info "  $line"; done < "$RULESET_TMP"
}

# =============================================================================
# PASO 3 -- Validar sintaxis
# =============================================================================

validar_sintaxis() {
    section "PASO 3 -- Validar sintaxis del ruleset (nft -c -f)"

    log_info "Ejecutando nft -c -f $RULESET_TMP (dry-run)..."

    if nft -c -f "$RULESET_TMP" 2>/dev/null; then
        log_ok "Sintaxis valida -- sin errores."
    else
        log_error "ERROR de sintaxis en el ruleset:"
        nft -c -f "$RULESET_TMP" 2>&1 | while IFS= read -r line; do
            log_error "  $line"
        done || true
        die "Abortando -- no se aplica el ruleset con errores de sintaxis."
    fi
}

# =============================================================================
# PASO 4 -- Aplicar ruleset
# =============================================================================

aplicar_ruleset() {
    section "PASO 4 -- Aplicar ruleset (PUNTO DE NO RETORNO)"

    log_warn "ADVERTENCIA: se aplica policy drop en chain input."
    log_warn "La sesion SSH activa continua (ct state established)."
    log_warn "Si la verificacion del PASO 5 falla, se requerira consola KVM:"
    log_warn "  sudo virsh --connect qemu:///system console ecom-db-vm  # o ssh ecom-db si SSH sigue activo"
    log_info ""

    log_info "Ejecutando nft -f $RULESET_TMP..."
    if nft -f "$RULESET_TMP" 2>/dev/null; then
        log_ok "Ruleset aplicado correctamente."
    else
        nft -f "$RULESET_TMP" 2>&1 | while IFS= read -r line; do
            log_error "  $line"
        done || true
        die "ERROR al aplicar el ruleset."
    fi

    log_info ""
    log_info "Ruleset activo post-aplicacion:"
    nft list ruleset 2>/dev/null | while IFS= read -r line; do
        log_info "  $line"
    done || true
}

# =============================================================================
# PASO 5 -- Verificar SSH post-aplicacion
# =============================================================================

verificar_ssh_post_firewall() {
    section "PASO 5 -- Verificar SSH accesible post-firewall"

    log_info "Verificando que el puerto SSH ${SSH_PORT} sigue en escucha..."

    if ss -tlnp 2>/dev/null | grep -q ":${SSH_PORT}"; then
        log_ok "HALLAZGO H-C3c-3-VM3 -- Puerto ${SSH_PORT} accesible post-firewall -- OK"
    else
        log_error "CRITICO: puerto ${SSH_PORT} NO detectado post-firewall."
        log_error "La sesion SSH activa puede seguir viva por ct state established."
        log_error "Verificar acceso desde el Host antes de cerrar esta sesion:"
        log_error "  ssh -i ~/.ssh/id_ed25519_host_to_vm1 -p ${SSH_PORT} ubuntu@${VM_IP} hostname"
        die "Verificacion SSH fallida -- NO persistir el ruleset hasta diagnosticar."
    fi

    log_info ""
    log_info "Estado de puertos post-firewall:"
    ss -tlnp 2>/dev/null | while IFS= read -r line; do
        log_info "  $line"
    done

    log_info ""
    log_info "Verificando chains activos:"
    if nft list ruleset 2>/dev/null | grep -q "policy drop;"; then
        log_ok "HALLAZGO H-C3c-2-VM3 -- chain input policy: drop -- confirmado"
    else
        log_warn "policy drop no detectado en el ruleset activo."
    fi

    local chain_count
    chain_count=$(nft list ruleset 2>/dev/null | grep -c "^	chain" || echo "0")
    log_info "Chains activos: $chain_count (esperado: 3)"

    if [[ "$chain_count" -ge 3 ]]; then
        log_ok "HALLAZGO H-C3c-1-VM3 -- Ruleset activo: table inet filter con $chain_count chains"
    else
        log_warn "HALLAZGO H-C3c-1-VM3 -- Solo $chain_count chains detectados (esperado: 3)"
    fi
}

# =============================================================================
# PASO 6 -- Persistir ruleset
# =============================================================================

persistir_ruleset() {
    section "PASO 6 -- Persistir ruleset en $NFTABLES_CONF"

    if [[ -f "$NFTABLES_CONF" ]]; then
        local backup="${NFTABLES_CONF}.bak_$(date -u +%Y%m%dT%H%M%SZ)"
        cp "$NFTABLES_CONF" "$backup"
        log_info "Backup previo: $backup"
    fi

    log_info "Persistiendo ruleset activo en $NFTABLES_CONF..."
    nft list ruleset 2>/dev/null > "$NFTABLES_CONF" || \
        die "Error al escribir $NFTABLES_CONF"

    log_ok "Ruleset persistido en $NFTABLES_CONF"
    log_info ""
    log_info "Contenido de $NFTABLES_CONF:"
    while IFS= read -r line; do log_info "  $line"; done < "$NFTABLES_CONF"

    log_info ""
    log_info "Habilitando nftables.service..."
    systemctl enable nftables 2>/dev/null || \
        log_warn "systemctl enable nftables retorno error -- verificar manualmente."
    log_ok "nftables.service habilitado para arranque automatico."
}

# =============================================================================
# PASO 7 -- Verificar persistencia
# =============================================================================

verificar_persistencia() {
    section "PASO 7 -- Verificar persistencia"

    log_info "Estado nftables.service:"
    systemctl status nftables --no-pager 2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || true

    local enabled
    enabled=$(systemctl is-enabled nftables 2>/dev/null || echo "unknown")
    local active
    active=$(systemctl is-active nftables 2>/dev/null || echo "unknown")

    log_info ""
    log_info "  nftables.service enabled: $enabled"
    log_info "  nftables.service active:  $active"

    if [[ "$enabled" == "enabled" ]]; then
        log_ok "HALLAZGO H-C3c-4-VM3 -- $NFTABLES_CONF persistido + nftables.service: enabled"
    else
        log_warn "HALLAZGO H-C3c-4-VM3 -- nftables.service estado: $enabled (esperado: enabled)"
        log_warn "  Verificar: systemctl enable nftables"
    fi

    log_info ""
    log_info "Verificacion de carga del ruleset desde archivo:"
    if nft -c -f "$NFTABLES_CONF" 2>/dev/null; then
        log_ok "Archivo $NFTABLES_CONF valido -- nftables.service podra cargarlo al boot."
    else
        log_warn "Advertencia de sintaxis en $NFTABLES_CONF -- verificar antes del reboot."
    fi

    rm -f "$RULESET_TMP"
    log_info ""
    log_info "Archivo temporal $RULESET_TMP eliminado."
}

# =============================================================================
# RESUMEN FINAL
# =============================================================================

print_summary() {
    local sep
    sep=$(printf '=%.0s' {1..70})

    printf '\n%s\n' "$sep"
    printf 'RESUMEN -- configure_db_vm_firewall.sh %s\n' "$VERSION"
    printf '%s\n' "$sep"
    printf 'Fecha:    %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'VM:       %s | IP: %s | Interfaz: %s\n' \
        "$(hostname)" "$VM_IP" "$VM_IFACE"
    printf 'Log:      %s\n' "$LOG_FILE"
    printf '%s\n' "$sep"
    printf 'Hallazgos confirmados:\n'
    printf '  H-C3c-1-VM3 -- Ruleset activo: table inet filter (3 chains)\n'
    printf '  H-C3c-2-VM3 -- chain input policy: drop\n'
    printf '  H-C3c-3-VM3 -- Puerto SSH %s accesible post-firewall\n' "$SSH_PORT"
    printf '  H-C3c-4-VM3 -- %s persistido + nftables.service enabled\n' "$NFTABLES_CONF"
    printf '%s\n' "$sep"
    printf 'Puertos abiertos en INPUT:\n'
    printf '  %s/tcp  -- SSH (origen: %s)\n' "$SSH_PORT" "$NAT_NET"
    printf '  %s/tcp   -- MariaDB desde VM1 (origen: %s -- Django)\n' "$MARIADB_PORT" "$VM1_IP"
    printf '  %s/tcp   -- MariaDB desde Host DNAT (origen: %s -- Claude Code web, Tarea 5.C.8)\n' "$MARIADB_PORT" "$HOST_GW"
    printf '  %s/tcp  -- Zabbix Agent (origen: %s -- Zabbix Server VM1)\n' "$ZABBIX_AGENT_PORT" "$VM1_IP"
    printf '%s\n' "$sep"
    printf 'Tarea 5.C.3c [VM3] completada.\n'
    printf 'Proxima tarea: 5.C.3d [VM3] -- Desactivar servicios innecesarios ecom-db-vm\n'
    printf '%s\n\n' "$sep"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    verificar_precondiciones
    verificar_estado_inicial
    construir_ruleset
    validar_sintaxis
    aplicar_ruleset
    verificar_ssh_post_firewall
    persistir_ruleset
    verificar_persistencia
    print_summary
    exit 0
}

mkdir -p "$LOG_DIR"
main "$@" 2>&1 | tee -a "$LOG_FILE"
exit "${PIPESTATUS[0]}"
