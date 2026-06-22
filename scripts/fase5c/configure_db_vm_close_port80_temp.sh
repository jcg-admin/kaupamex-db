#!/bin/bash
# =============================================================================
# configure_db_vm_close_port80_temp.sh
# Elimina la regla temporal de puerto 80 del firewall nftables de ecom-db-vm
# después de haber obtenido el certificado Let's Encrypt.
#
# Ejecutar DENTRO de ecom-db-vm como:
#   sudo bash /tmp/configure_db_vm_close_port80_temp.sh
#
# Contexto:  [VM3-UBUNTU] -- usuario ubuntu con sudo, dentro de ecom-db-vm
# Tarea:     B.6.1 -- Cierre puerto 80 temporal post-ACME challenge
#
# Despliegue desde el Host:
#   scp -F /home/ubuntu/.ssh/config /tmp/configure_db_vm_close_port80_temp.sh ecom-db:/tmp/
#   ssh ecom-db "sudo bash /tmp/configure_db_vm_close_port80_temp.sh" 2>&1 | \
#       tee /tmp/log_tarea_B_6_1_$(date -u +%Y%m%dT%H%M%SZ).txt
#
# Prerequisitos:
#   - B.4.2 completado: configure_db_vm_open_port80_temp.sh ejecutado
#   - B.5.1 completado: configure_db_vm_ssl_letsencrypt.sh ejecutado
#   - Certificado obtenido y MariaDB TLS activo
#
# Secuencia (este es el paso final):
#   1. configure_db_vm_open_port80_temp.sh   (B.4.2) ← ya ejecutado
#   2. configure_db_vm_ssl_letsencrypt.sh    (B.5.1) ← ya ejecutado
#   3. configure_db_vm_close_port80_temp.sh  (este script — B.6.1)
#
# Qué hace este script:
#   - Localiza y elimina la regla TEMP-ACME-CHALLENGE del chain input
#   - Verifica que la regla fue eliminada del ruleset en memoria
#   - Persiste el ruleset limpio en /etc/nftables.conf
#   - Confirma que el firewall volvió al estado restrictivo
#
# Idempotente: si la regla ya no existe (ya fue eliminada), informa y sale.
#
# Hallazgos producidos:
#   H-B6a-1-VM3 -- Regla TEMP-ACME-CHALLENGE eliminada del chain input
#   H-B6a-2-VM3 -- Ruleset persistido en /etc/nftables.conf
#   H-B6a-3-VM3 -- Firewall en estado restrictivo (puerto 80 cerrado)
# =============================================================================

set -euo pipefail

# =============================================================================
# CONSTANTES
# =============================================================================
readonly COMMENT="TEMP-ACME-CHALLENGE"
readonly NFTABLES_CONF="/etc/nftables.conf"
readonly LOG_PREFIX="[B.6.1-close-port80]"

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
        log_error "nft no está instalado."
        exit 1
    fi
}

rule_exists() {
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

    # Verificar que la tabla inet filter existe
    if ! nft list table inet filter &>/dev/null; then
        log_error "Tabla inet filter no existe. Estado del firewall inconsistente."
        exit 1
    fi
    log_ok "Tabla inet filter presente."
}

# =============================================================================
# PASO 2 — Verificar idempotencia
# =============================================================================
paso2_idempotencia() {
    log_info "=== PASO 2: Verificar idempotencia ==="

    if ! rule_exists; then
        log_warn "Regla ${COMMENT} NO está en el ruleset."
        log_warn "El puerto 80 ya fue cerrado previamente (idempotente)."
        return 1  # señal de que no hay nada que hacer
    fi

    log_info "Regla ${COMMENT} encontrada. Procediendo a eliminar."

    # Mostrar la regla que se eliminará
    log_info "Regla a eliminar:"
    nft list chain inet filter input | grep "${COMMENT}" || true
    return 0
}

# =============================================================================
# PASO 3 — Eliminar regla TEMP-ACME-CHALLENGE
# =============================================================================
paso3_eliminar_regla() {
    log_info "=== PASO 3: Eliminar regla temporal puerto 80 ==="

    # Obtener el handle de la regla para eliminarla por handle (más preciso que por posición)
    local handle
    handle=$(nft --handle list chain inet filter input 2>/dev/null \
        | grep "${COMMENT}" \
        | grep -oP '# handle \K[0-9]+' \
        | head -1 || echo "")

    if [[ -z "${handle}" ]]; then
        log_warn "No se pudo obtener handle de la regla. Intentando eliminar por contenido..."

        # Fallback: recargar el ruleset guardado sin la regla TEMP-ACME-CHALLENGE
        # Esto es más agresivo pero garantiza eliminar la regla
        if [[ -f "${NFTABLES_CONF}" ]]; then
            local ruleset_sin_temp
            ruleset_sin_temp=$(grep -v "${COMMENT}" "${NFTABLES_CONF}" || true)
            echo "${ruleset_sin_temp}" | nft -f /dev/stdin
            log_ok "Ruleset recargado sin regla ${COMMENT}."
        else
            log_error "No se pudo obtener handle ni existe ${NFTABLES_CONF} para recargar."
            exit 1
        fi
        return 0
    fi

    log_info "Eliminando regla con handle ${handle}..."
    nft delete rule inet filter input handle "${handle}"
    log_ok "Regla eliminada (handle ${handle})."
}

# =============================================================================
# PASO 4 — Verificar que la regla fue eliminada
# =============================================================================
paso4_verificar_eliminacion() {
    log_info "=== PASO 4: Verificar eliminación de regla ==="

    if rule_exists; then
        log_error "La regla ${COMMENT} aún aparece en el ruleset después de eliminarla."
        log_error "Estado actual del chain input:"
        nft list chain inet filter input 2>/dev/null || true
        exit 1
    fi

    log_ok "Regla ${COMMENT} NO aparece en el ruleset. Eliminación exitosa."

    log_info "Estado actual del chain input (sin TEMP-ACME-CHALLENGE):"
    nft list chain inet filter input
}

# =============================================================================
# PASO 5 — Persistir ruleset limpio en /etc/nftables.conf
# =============================================================================
paso5_persistir_ruleset() {
    log_info "=== PASO 5: Persistir ruleset en ${NFTABLES_CONF} ==="

    # Backup del archivo de configuración actual
    if [[ -f "${NFTABLES_CONF}" ]]; then
        local backup_file="${NFTABLES_CONF}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
        cp "${NFTABLES_CONF}" "${backup_file}"
        log_ok "Backup: ${backup_file}"
    fi

    # Guardar el ruleset actual en memoria (ya sin la regla TEMP-ACME-CHALLENGE)
    nft list ruleset > "${NFTABLES_CONF}"
    log_ok "Ruleset persistido en ${NFTABLES_CONF}"

    # Verificar que el archivo guardado NO contiene la regla temporal
    if grep -q "${COMMENT}" "${NFTABLES_CONF}"; then
        log_error "¡El archivo ${NFTABLES_CONF} aún contiene ${COMMENT}!"
        log_error "El ruleset persistido es incorrecto. Revisar manualmente."
        exit 1
    fi
    log_ok "Verificado: ${NFTABLES_CONF} no contiene ${COMMENT}."
}

# =============================================================================
# PASO 6 — Limpiar estado temporal y confirmar firewall restrictivo
# =============================================================================
paso6_confirmar_firewall() {
    log_info "=== PASO 6: Confirmar firewall en estado restrictivo ==="

    # Limpiar archivo de estado temporal del script de apertura
    local estado_file="/tmp/.acme_port80_open_state"
    if [[ -f "${estado_file}" ]]; then
        rm -f "${estado_file}"
        log_ok "Archivo de estado temporal eliminado: ${estado_file}"
    fi

    # Verificar que el puerto 80 NO es accesible desde localhost
    # (prueba de conectividad local — no garantiza acceso externo pero confirma el estado del chain)
    if command -v ss &>/dev/null; then
        local port80_listening
        port80_listening=$(ss -tlnp | grep ':80 ' || echo "")
        if [[ -n "${port80_listening}" ]]; then
            log_warn "Puerto 80 aún tiene un proceso escuchando (puede ser certbot standalone)."
            log_warn "Verificar: ${port80_listening}"
        else
            log_ok "Puerto 80 no tiene proceso escuchando (estado esperado post-certbot)."
        fi
    fi

    # Mostrar resumen final del firewall
    log_info "Resumen final del firewall (chain input):"
    nft list chain inet filter input

    log_ok "Firewall en estado restrictivo. Puerto 80 cerrado."
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo ""
    echo "============================================================"
    echo " B.6.1 — Cierre TEMPORAL puerto 80 post-ACME challenge"
    echo " Eliminando regla: ${COMMENT}"
    echo "============================================================"
    echo ""

    paso1_validar

    # Verificar idempotencia — si la regla no existe, salir limpio
    if ! paso2_idempotencia; then
        echo ""
        echo "============================================================"
        echo " Puerto 80 ya estaba cerrado (idempotente). Sin cambios."
        echo " El firewall ya está en estado restrictivo."
        echo "============================================================"
        exit 0
    fi

    paso3_eliminar_regla
    paso4_verificar_eliminacion
    paso5_persistir_ruleset
    paso6_confirmar_firewall

    echo ""
    echo "============================================================"
    echo " Puerto 80 CERRADO exitosamente."
    echo " Firewall de ecom-db-vm en estado restrictivo."
    echo ""
    echo " Verificación:"
    echo "   nft list ruleset | grep -v ${COMMENT} | grep 80"
    echo "   (no debe aparecer ninguna regla de puerto 80)"
    echo ""
    echo " MariaDB TLS sigue activo — el cert está en:"
    echo "   /etc/letsencrypt/live/db.practicayoruba.com/"
    echo "   /etc/mysql/ssl/"
    echo "============================================================"
}

main "$@"
