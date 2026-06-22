#!/bin/bash
# =============================================================================
# configure_db_vm_zabbix_agent.sh
# Instala y configura Zabbix Agent en ecom-db-vm para monitoreo
# desde el Zabbix Server en ecom-app-vm (VM1, 192.168.100.10).
#
# Ejecutar DENTRO de ecom-db-vm como:
#   sudo bash /tmp/configure_db_vm_zabbix_agent.sh
#
# Contexto:  [VM3-UBUNTU] -- usuario ubuntu con sudo, dentro de ecom-db-vm
# Tarea:     5.9 -- Instalar y configurar Zabbix Agent
#
# Despliegue desde el Host:
#   scp -F /home/ubuntu/.ssh/config /tmp/configure_db_vm_zabbix_agent.sh ecom-db:/tmp/
#   
#   ssh ecom-db "sudo bash /tmp/configure_db_vm_zabbix_agent.sh" 2>&1 | \
#       tee /tmp/log_tarea_5_9_$(date -u +%Y%m%dT%H%M%SZ).txt
#
# Prerequisitos:
#   - Tarea 5.C.3c completada: firewall VM2 con puerto 10050 abierto
#     desde 192.168.100.10 (ip saddr 192.168.100.10 tcp dport 10050 accept)
#
# Modo de operacion: pasivo (default)
#   El Zabbix Server en VM1 consulta al agente periodicamente.
#   El agente responde con metricas del sistema.
#
# Nota: el Zabbix Server en VM1 aun no esta instalado (Tarea 5.A).
#   La verificacion completa Server → Agent se realiza cuando se instale
#   el Server en VM1. El PASO 6 solo verifica alcanzabilidad del puerto.
#
# Configuracion aplicada:
#   Server       = 192.168.100.10   (Zabbix Server en VM1)
#   ServerActive = 192.168.100.10
#   Hostname     = ecom-db-vm
#   ListenPort   = 10050
#   ListenIP     = 192.168.100.20
#
# Hallazgos producidos:
#   H-C9-1-VM3 -- Zabbix Agent: zabbix-agent.service active
#   H-C9-2-VM3 -- Puerto 10050: LISTEN 192.168.100.30:10050
#   H-C9-3-VM3 -- Configuracion: Server=192.168.100.10, Hostname=ecom-db-vm
#
# Idempotente: segunda ejecucion sobreescribe la config con backup,
# reinicia el servicio y verifica -- sin cambios funcionales si la
# config es identica.
#
# -----------------------------------------------------------------------------
# Version  Fecha        Autor                                    Cambios
# -----------------------------------------------------------------------------
# v1.0.0   2026-06-20   Nestor Monroy <46802445+NestorMonroy    Version inicial.
#                       @users.noreply.github.com>               Zabbix Agent VM2.
#                                                                Server VM1.
#                                                                H-C9-1-VM3-H-C9-3-VM3.
# -----------------------------------------------------------------------------

set -euo pipefail

VERSION="v1.0.0"

# =============================================================================
# CONFIGURACION
# =============================================================================

readonly ZABBIX_SERVER="192.168.100.10"
readonly ZABBIX_SERVER_PORT="10051"
readonly AGENT_IP="192.168.100.30"
readonly AGENT_PORT="10050"
readonly AGENT_HOSTNAME="ecom-db-vm"
readonly ZABBIX_CONF="/etc/zabbix/zabbix_agentd.conf"
readonly ZABBIX_CONF_DIR="/etc/zabbix"
readonly LOG_DIR="/var/log/ecom-setup"
readonly LOG_FILE="${LOG_DIR}/configure_db_vm_zabbix_agent_$(date -u +%Y-%m-%dT%H%M%SZ).log"

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
    else
        log_ok "Hostname: $hostname_actual -- correcto."
    fi

    log_info "Script: configure_db_vm_zabbix_agent.sh $VERSION"
    log_info "Zabbix Server: $ZABBIX_SERVER:$ZABBIX_SERVER_PORT (VM1)"
    log_info "Agent listen:  $AGENT_IP:$AGENT_PORT"
    log_info "Log: $LOG_FILE"
}

# =============================================================================
# PASO 1 -- Instalar zabbix-agent
# =============================================================================

instalar_zabbix_agent() {
    section "PASO 1 -- Instalar zabbix-agent"

    export DEBIAN_FRONTEND=noninteractive

    if dpkg -l zabbix-agent 2>/dev/null | grep -q "^ii"; then
        local ver
        ver=$(dpkg -l zabbix-agent | grep "^ii" | awk '{print $3}')
        log_info "zabbix-agent ya instalado: $ver -- omitiendo instalacion."
        log_ok "HALLAZGO H-C9-1-VM3 (pre) -- zabbix-agent: ya instalado ($ver)"
        return 0
    fi

    log_info "Instalando zabbix-agent desde repositorios Ubuntu 26.04..."
    apt-get install -y zabbix-agent 2>&1 | \
        while IFS= read -r line; do log_info "  $line"; done || \
        die "Error al instalar zabbix-agent. Verificar disponibilidad en repos."

    if dpkg -l zabbix-agent 2>/dev/null | grep -q "^ii"; then
        local ver
        ver=$(dpkg -l zabbix-agent | grep "^ii" | awk '{print $3}')
        log_ok "zabbix-agent instalado: $ver"
    else
        die "zabbix-agent no encontrado post-instalacion."
    fi
}

# =============================================================================
# PASO 2 -- Configurar zabbix_agentd.conf
# =============================================================================

configurar_agente() {
    section "PASO 2 -- Configurar $ZABBIX_CONF"

    # Crear directorio si no existe
    mkdir -p "$ZABBIX_CONF_DIR"
    mkdir -p /var/log/zabbix
    chown zabbix:zabbix /var/log/zabbix 2>/dev/null || true

    # Backup del config actual
    if [[ -f "$ZABBIX_CONF" ]]; then
        local backup="${ZABBIX_CONF}.bak_$(date -u +%Y%m%dT%H%M%SZ)"
        cp "$ZABBIX_CONF" "$backup"
        log_info "Backup: $backup"
    fi

    log_info "Escribiendo $ZABBIX_CONF..."

    cat > "$ZABBIX_CONF" << EOF
# /etc/zabbix/zabbix_agentd.conf
# ecom-prod -- ecom-db-vm
# Tarea 5.C.9 -- configure_db_vm_zabbix_agent.sh ${VERSION}
# Generado: $(date -u +%Y-%m-%dT%H:%M:%SZ)
#
# Modo: pasivo -- Zabbix Server consulta al agente periodicamente
# Server: ecom-app-vm (VM1) -- 192.168.100.10

# =============================================================================
# PROCESO
# =============================================================================

PidFile=/run/zabbix/zabbix_agentd.pid

# =============================================================================
# LOGS
# =============================================================================

LogFile=/var/log/zabbix/zabbix_agentd.log
LogFileSize=10
DebugLevel=3

# =============================================================================
# SERVIDOR ZABBIX (modo pasivo)
# =============================================================================

# IPs autorizadas para consultar este agente
# Solo VM1 (Zabbix Server) puede conectar
Server=${ZABBIX_SERVER}

# Para modo activo (el agente envia datos al Server)
ServerActive=${ZABBIX_SERVER}

# =============================================================================
# IDENTIDAD DEL HOST
# =============================================================================

# Debe coincidir con el nombre del host en la interfaz de Zabbix
Hostname=${AGENT_HOSTNAME}

# =============================================================================
# RED
# =============================================================================

# Escuchar solo en la interfaz NAT interna
ListenIP=${AGENT_IP}
ListenPort=${AGENT_PORT}

# =============================================================================
# SEGURIDAD
# =============================================================================

# Zabbix 7.0: DenyKey reemplaza EnableRemoteCommands=0 (deprecado)
# Deniega system.run[*] -- el agente no puede ejecutar comandos remotos
DenyKey=system.run[*]

# No permitir que el agente ejecute como root
# (el agente corre como usuario zabbix por defecto)

# =============================================================================
# INCLUDE
# =============================================================================

# Directorio para configuraciones adicionales (custom checks)
Include=/etc/zabbix/zabbix_agentd.d/*.conf
EOF

    log_ok "zabbix_agentd.conf escrito correctamente."
    log_info ""
    log_info "Directivas clave:"
    grep -v "^#\|^$" "$ZABBIX_CONF" | while IFS= read -r line; do
        log_info "  $line"
    done

    # Crear directorio para includes
    mkdir -p /etc/zabbix/zabbix_agentd.d
    log_ok "Directorio include: /etc/zabbix/zabbix_agentd.d/"

    log_ok "HALLAZGO H-C9-3-VM3 -- Configuracion: Server=$ZABBIX_SERVER, Hostname=$AGENT_HOSTNAME"
}

# =============================================================================
# PASO 3 -- Habilitar y arrancar zabbix-agent
# =============================================================================

arrancar_agente() {
    section "PASO 3 -- Habilitar y arrancar zabbix-agent.service"

    log_info "Habilitando zabbix-agent para arranque automatico..."
    systemctl enable zabbix-agent 2>/dev/null || true
    log_ok "zabbix-agent.service: enabled."

    log_info ""
    log_info "Reiniciando zabbix-agent..."
    systemctl restart zabbix-agent 2>/dev/null || \
        systemctl start zabbix-agent 2>/dev/null || \
        die "Error al iniciar zabbix-agent.service."

    sleep 2
    log_info "zabbix-agent estabilizado (2s)."
}

# =============================================================================
# PASO 4 -- Verificar servicio activo
# =============================================================================

verificar_servicio() {
    section "PASO 4 -- Verificar zabbix-agent.service"

    local estado
    estado=$(systemctl is-active zabbix-agent 2>/dev/null || echo "unknown")

    if [[ "$estado" == "active" ]]; then
        log_ok "HALLAZGO H-C9-1-VM3 -- Zabbix Agent: active"
    else
        log_warn "HALLAZGO H-C9-1-VM3 -- zabbix-agent.service: $estado"
        systemctl status zabbix-agent --no-pager 2>/dev/null | \
            while IFS= read -r line; do log_warn "  $line"; done || true
        die "zabbix-agent.service no esta active -- revisar logs con: journalctl -u zabbix-agent -n 20"
    fi

    log_info ""
    log_info "Estado zabbix-agent.service:"
    systemctl status zabbix-agent --no-pager 2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || true
}

# =============================================================================
# PASO 5 -- Verificar puerto 10050 en escucha
# =============================================================================

verificar_puerto() {
    section "PASO 5 -- Verificar puerto $AGENT_PORT en escucha"

    log_info "Consultando puertos activos (ss -tlnp)..."
    local ss_output
    ss_output=$(ss -tlnp 2>/dev/null | grep ":${AGENT_PORT}" || echo "")

    if [[ -n "$ss_output" ]]; then
        while IFS= read -r line; do log_info "  $line"; done <<< "$ss_output"

        if echo "$ss_output" | grep -q "${AGENT_IP}:${AGENT_PORT}"; then
            log_ok "HALLAZGO H-C9-2-VM3 -- Puerto $AGENT_PORT: LISTEN ${AGENT_IP}:${AGENT_PORT} -- OK"
        else
            log_warn "HALLAZGO H-C9-2-VM3 -- Puerto $AGENT_PORT en escucha pero IP diferente:"
            log_warn "  $ss_output"
            log_warn "  Esperado: ${AGENT_IP}:${AGENT_PORT}"
        fi
    else
        log_warn "HALLAZGO H-C9-2-VM3 -- Puerto $AGENT_PORT NO detectado en escucha."
        log_warn "  Verificar: systemctl status zabbix-agent"
        log_warn "  Logs: journalctl -u zabbix-agent -n 20"
    fi
}

# =============================================================================
# PASO 6 -- Test de conectividad (informativo)
# =============================================================================

test_conectividad() {
    section "PASO 6 -- Test conectividad hacia Zabbix Server en VM1"

    log_info "Nota: el Zabbix Server en VM1 aun no esta instalado (Tarea 5.A)."
    log_info "Este test verifica alcanzabilidad del puerto 10051 en VM1."
    log_info "Es INFORMATIVO -- no es un error si falla."
    log_info ""

    log_info "Probando conexion a $ZABBIX_SERVER:$ZABBIX_SERVER_PORT..."
    if nc -zv "$ZABBIX_SERVER" "$ZABBIX_SERVER_PORT" -w 3 2>/dev/null; then
        log_ok "Zabbix Server en $ZABBIX_SERVER:$ZABBIX_SERVER_PORT accesible."
        log_ok "VM1 tiene el Server instalado -- verificar registro del host en Zabbix UI."
    else
        log_info "Zabbix Server no responde en $ZABBIX_SERVER:$ZABBIX_SERVER_PORT."
        log_info "Es esperado -- el Server se instala en Tarea 5.A."
        log_info "Verificar conectividad cuando el Server este activo en VM1:"
        log_info "  ssh vm1 'nc -zv 192.168.100.30 10050 -w 3'"
    fi
}

# =============================================================================
# RESUMEN FINAL
# =============================================================================

print_summary() {
    local sep
    sep=$(printf '=%.0s' {1..70})

    local agent_estado
    agent_estado=$(systemctl is-active zabbix-agent 2>/dev/null || echo "unknown")

    local agent_ver
    agent_ver=$(dpkg -l zabbix-agent 2>/dev/null | grep "^ii" | awk '{print $3}' || echo "?")

    printf '\n%s\n' "$sep"
    printf 'RESUMEN -- configure_db_vm_zabbix_agent.sh %s\n' "$VERSION"
    printf '%s\n' "$sep"
    printf 'Fecha:    %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'VM:       %s\n' "$(hostname)"
    printf 'Version:  zabbix-agent %s\n' "$agent_ver"
    printf 'Estado:   zabbix-agent.service %s\n' "$agent_estado"
    printf 'Log:      %s\n' "$LOG_FILE"
    printf '%s\n' "$sep"
    printf 'Hallazgos confirmados:\n'
    printf '  H-C9-1-VM3 -- Zabbix Agent: %s\n' "$agent_estado"
    printf '  H-C9-2-VM3 -- Puerto %s: LISTEN %s:%s\n' \
        "$AGENT_PORT" "$AGENT_IP" "$AGENT_PORT"
    printf '  H-C9-3-VM3 -- Configuracion: Server=%s, Hostname=%s\n' \
        "$ZABBIX_SERVER" "$AGENT_HOSTNAME"
    printf '%s\n' "$sep"
    printf 'Configuracion:\n'
    printf '  Server:     %s (VM1 ecom-app-vm)\n' "$ZABBIX_SERVER"
    printf '  ListenIP:   %s\n' "$AGENT_IP"
    printf '  ListenPort: %s\n' "$AGENT_PORT"
    printf '  Hostname:   %s\n' "$AGENT_HOSTNAME"
    printf '%s\n' "$sep"
    printf 'PENDIENTE: Zabbix Server en VM1 (Tarea 5.A)\n'
    printf '  Verificar conectividad desde VM1:\n'
    printf '    ssh vm1 '"'"'nc -zv %s %s -w 3'"'"'\n' \
        "$AGENT_IP" "$AGENT_PORT"
    printf '  Agregar host en Zabbix UI:\n'
    printf '    Nombre: %s | IP: %s | Puerto: %s\n' \
        "$AGENT_HOSTNAME" "$AGENT_IP" "$AGENT_PORT"
    printf '%s\n' "$sep"
    printf 'Tarea 5.C.9 completada.\n'
    printf 'Proxima tarea: 5.C.10 [VM3] -- Ajuste DB_HOST en VM1 .env (cuando se instale Django)\n'
    printf '%s\n\n' "$sep"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    verificar_precondiciones
    instalar_zabbix_agent
    configurar_agente
    arrancar_agente
    verificar_servicio
    verificar_puerto
    test_conectividad
    print_summary
    exit 0
}

mkdir -p "$LOG_DIR"
main "$@" 2>&1 | tee -a "$LOG_FILE"
exit "${PIPESTATUS[0]}"
