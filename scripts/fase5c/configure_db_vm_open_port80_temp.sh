#!/bin/bash
# =============================================================================
# configure_db_vm_open_port80_temp.sh
# Abre temporalmente el puerto 80 TCP en el firewall nftables de ecom-db-vm
# para permitir el desafío HTTP-01 de Let's Encrypt (certbot standalone).
#
# ADVERTENCIA: Este script es TEMPORAL. El puerto 80 DEBE cerrarse
# inmediatamente después de obtener el certificado SSL ejecutando:
#   sudo bash configure_db_vm_close_port80_temp.sh
#
# Ejecutar DENTRO de ecom-db-vm como:
#   sudo bash /tmp/configure_db_vm_open_port80_temp.sh
#
# Contexto:  [VM3-UBUNTU] -- usuario ubuntu con sudo, dentro de ecom-db-vm
# Tarea:     B.4.2 -- Apertura temporal puerto 80 para ACME HTTP-01 challenge
#
# Despliegue desde el Host:
#   scp -F /home/ubuntu/.ssh/config /tmp/configure_db_vm_open_port80_temp.sh ecom-db:/tmp/
#   ssh ecom-db "sudo bash /tmp/configure_db_vm_open_port80_temp.sh" 2>&1 | \
#       tee /tmp/log_tarea_B_4_2_$(date -u +%Y%m%dT%H%M%SZ).txt
#
# Prerequisitos:
#   - Tarea 5.0d completada: firewall nftables activo con policy drop en input
#   - DNS A record para db.practicayoruba.com apuntando a IP pública de VM3
#   - Puerto 80 accesible desde Internet (requiere prerouting en VM1/Host)
#
# Secuencia obligatoria:
#   1. configure_db_vm_open_port80_temp.sh  (este script — B.4.2)
#   2. configure_db_vm_ssl_letsencrypt.sh   (obtener cert — B.5.1)
#   3. configure_db_vm_close_port80_temp.sh (cerrar puerto — B.6.1)
#
# Idempotente: si la regla TEMP-ACME-CHALLENGE ya existe, no la duplica.
#
# Hallazgos producidos:
#   H-B4c-1-VM3 -- Puerto 80 abierto temporalmente (TEMP-ACME-CHALLENGE)
#   H-B4c-2-VM3 -- Regla idempotente verificada (no duplicada)
# =============================================================================

set -euo pipefail

# =============================================================================
# CONSTANTES
# =============================================================================
readonly COMMENT="TEMP-ACME-CHALLENGE"
readonly LOG_PREFIX="[B.4.2-open-port80]"

# =============================================================================
# FUNCIONES AUXILIARES
# =============================================================================

log_info()  { echo "${LOG_PREFIX} [INFO]  $*"; }
log_ok()    { echo "${LOG_PREFIX} [OK]    $*"; }
log_warn()  { echo "${LOG_PREFIX} [WARN]  $*"; }
log_error() { echo "${LOG_PREFIX} [ERROR] $*" >&2; }

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "Este script debe ejecutarse como root (sudo)."
        exit 1
    fi
}

check_nft() {
    if ! command -v nft &>/dev/null; then
        log_error "nft no está instalado. Instalar con: apt-get install -y nftables"
        exit 1
    fi
}

rule_already_exists() {
    nft list ruleset 2>/dev/null | grep -q "${COMMENT}"
}

# =============================================================================
# PASO 1 — Validar prerequisitos
# =============================================================================
paso1_validar() {
    log_info "=== PASO 1: Validar prerequisitos ==="

    check_root
    log_ok "Ejecutando como root."

    check_nft
    log_ok "nft disponible: $(nft --version 2>&1 | head -1)"

    # Verificar que el firewall inet filter existe (instalado por configure_db_vm_firewall.sh)
    if ! nft list table inet filter &>/dev/null; then
        log_error "Tabla inet filter no existe. Ejecutar configure_db_vm_firewall.sh primero."
        exit 1
    fi
    log_ok "Tabla inet filter presente."
}

# =============================================================================
# PASO 2 — Verificar idempotencia
# =============================================================================
paso2_idempotencia() {
    log_info "=== PASO 2: Verificar idempotencia ==="

    if rule_already_exists; then
        log_warn "Regla ${COMMENT} ya existe en el ruleset. No se duplicará."
        log_ok "Estado: Puerto 80 ya abierto temporalmente (idempotente)."
        # Mostrar la regla existente para confirmación
        log_info "Regla existente:"
        nft list ruleset | grep -A1 "${COMMENT}" || true
        return 0
    fi

    log_info "Regla ${COMMENT} no encontrada. Procediendo a agregar."
    return 1
}

# =============================================================================
# PASO 3 — Agregar regla temporal en chain input
# =============================================================================
paso3_agregar_regla() {
    log_info "=== PASO 3: Agregar regla temporal puerto 80 ==="

    # Agregar regla al chain input de inet filter
    # La regla acepta TCP 80 desde cualquier origen (necesario para ACME challenge)
    nft add rule inet filter input tcp dport 80 accept comment "\"${COMMENT}\""

    log_ok "Regla agregada: tcp dport 80 accept comment ${COMMENT}"
}

# =============================================================================
# PASO 4 — Verificar que la regla está activa
# =============================================================================
paso4_verificar() {
    log_info "=== PASO 4: Verificar regla activa ==="

    if ! rule_already_exists; then
        log_error "La regla ${COMMENT} no aparece en el ruleset tras insertarla."
        log_error "Inspeccionar: nft list ruleset"
        exit 1
    fi

    log_ok "Regla ${COMMENT} verificada en ruleset."
    log_info "Ruleset actual (chain input):"
    nft list chain inet filter input
}

# =============================================================================
# PASO 5 — Guardar estado para el script de cierre
# =============================================================================
paso5_guardar_estado() {
    log_info "=== PASO 5: Guardar estado para script de cierre ==="

    # Guardar marca de tiempo para auditoría
    local estado_file="/tmp/.acme_port80_open_state"
    {
        echo "opened_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "comment=${COMMENT}"
        echo "script=configure_db_vm_open_port80_temp.sh"
        echo "close_script=configure_db_vm_close_port80_temp.sh"
    } > "${estado_file}"

    log_ok "Estado guardado en ${estado_file}"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo ""
    echo "============================================================"
    echo " B.4.2 — Apertura TEMPORAL puerto 80 para ACME HTTP-01"
    echo " Objetivo: db.practicayoruba.com Let's Encrypt challenge"
    echo "============================================================"
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!! ADVERTENCIA: Este es un cambio TEMPORAL.              !!"
    echo "!! El puerto 80 DEBE cerrarse inmediatamente después     !!"
    echo "!! de obtener el certificado SSL ejecutando:             !!"
    echo "!!   sudo bash configure_db_vm_close_port80_temp.sh      !!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""

    paso1_validar

    # Verificar idempotencia — si ya existe la regla, salir limpio
    if paso2_idempotencia; then
        echo ""
        echo "============================================================"
        echo " Puerto 80 ya estaba abierto (idempotente). Sin cambios."
        echo " Continuar con: configure_db_vm_ssl_letsencrypt.sh"
        echo "============================================================"
        exit 0
    fi

    paso3_agregar_regla
    paso4_verificar
    paso5_guardar_estado

    echo ""
    echo "============================================================"
    echo " Puerto 80 abierto TEMPORALMENTE."
    echo ""
    echo " SIGUIENTE PASO OBLIGATORIO:"
    echo "   sudo bash configure_db_vm_ssl_letsencrypt.sh"
    echo ""
    echo " DESPUÉS DEL CERTIFICADO — CERRAR INMEDIATAMENTE:"
    echo "   sudo bash configure_db_vm_close_port80_temp.sh"
    echo "============================================================"
}

main "$@"
