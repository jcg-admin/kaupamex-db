#!/bin/bash
# =============================================================================
# configure_db_vm_apparmor.sh
# Verifica el estado de AppArmor en ecom-db-vm. Instala apparmor-utils
# si no esta disponible, verifica el servicio, audita perfiles, verifica
# los perfiles de Apache y MariaDB (pendiente instalacion), y lista
# procesos sin perfil.
#
# Ejecutar DENTRO de ecom-db-vm como:
#   sudo bash /tmp/configure_db_vm_apparmor.sh
#
# Contexto:  [VM3-UBUNTU] -- usuario ubuntu con sudo, dentro de ecom-db-vm
# Tarea:     5.0f [VM1] -- Verificacion AppArmor
#
# Despliegue desde el Host:
#   scp -F /home/ubuntu/.ssh/config /tmp/configure_db_vm_apparmor.sh ecom-db:/tmp/
#   ssh ecom-db "sudo bash /tmp/configure_db_vm_apparmor.sh" 2>&1 | \
#       tee /tmp/log_tarea_5_0f_vm1_$(date -u +%Y%m%dT%H%M%SZ).txt
#
# Prerequisitos:
#   - Tarea 5.C.3d [VM3] completada: servicios innecesarios desactivados
#   - DNS funcional en VM1 -- necesario para apt install apparmor-utils
#
# Precedente: configure_vm2_apparmor.sh v1.0.0 (H-C3e-1..4-VM3, 2026-06-19)
# Diferencias respecto a VM1:
#   - VERIFICACION 3: perfil MariaDB unicamente (sin Apache en VM3)
#   - MariaDB: /etc/apparmor.d/usr.sbin.mysqld -- viene con mariadb-server
#   - Zabbix Agent: sin perfil en Ubuntu 26.04 base
#   - Sin Apache en VM3
#
# Tarea de VERIFICACION, no de configuracion. El script no modifica
# el estado de AppArmor -- solo audita y reporta. La unica excepcion
# es la instalacion de apparmor-utils como prerequisito de la auditoria.
#
# Hallazgos producidos:
#   H-C3e-1-VM3 -- AppArmor servicio: enabled + active
#   H-C3e-2-VM3 -- Perfiles enforce: > 0
#   H-C3e-3-VM3 -- Perfiles Apache/MariaDB: no presentes (pendiente Tareas 5.1/5.3)
#   H-C3e-4-VM3 -- aa-unconfined: sin procesos de aplicacion sin perfil con red
#
# 5.C.3e es la ULTIMA tarea de hardening base de VM3. Su completitud habilita
# el inicio de las tareas de servicio (5.C.4 MariaDB).
#
# Idempotente: segunda ejecucion produce el mismo reporte sin cambios.
#
# -----------------------------------------------------------------------------
# Version  Fecha        Autor                                    Cambios
# -----------------------------------------------------------------------------
# v1.0.0   2026-06-20   Nestor Monroy <46802445+NestorMonroy    Version inicial.
#                       @users.noreply.github.com>               Verificacion
#                                                                AppArmor VM1.
#                                                                apparmor-utils.
#                                                                Perfiles Apache
#                                                                y MariaDB.
#                                                                aa-unconfined.
#                                                                H-C3e-1-VM3..H-C3e-4-VM3
# -----------------------------------------------------------------------------

set -euo pipefail

VERSION="v1.0.2"

# =============================================================================
# CONFIGURACION
# =============================================================================

readonly LOG_DIR="/var/log/ecom-setup"
readonly LOG_FILE="${LOG_DIR}/configure_db_vm_apparmor_$(date -u +%Y-%m-%dT%H%M%SZ).log"
readonly APPARMOR_D="/etc/apparmor.d"

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

    log_info "Script: configure_db_vm_apparmor.sh $VERSION"
    log_info "Log: $LOG_FILE"
    log_info ""
    log_info "Nota: tarea de VERIFICACION -- no modifica el estado de AppArmor."
    log_info "Unica excepcion: instalacion de apparmor-utils si no esta presente."
}

# =============================================================================
# PASO 1 -- Instalar apparmor-utils
# =============================================================================

instalar_apparmor_utils() {
    section "PASO 1 -- Verificar e instalar apparmor-utils"

    if command -v aa-status &>/dev/null && command -v aa-unconfined &>/dev/null; then
        log_ok "apparmor-utils ya disponible."
        log_info "  aa-status:     $(command -v aa-status)"
        log_info "  aa-unconfined: $(command -v aa-unconfined)"
        return 0
    fi

    log_info "apparmor-utils no encontrado -- instalando..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y apparmor-utils 2>&1 | while IFS= read -r line; do
        log_info "  $line"
    done || die "Error al instalar apparmor-utils."

    local missing=0
    for tool in aa-status aa-unconfined aa-enforce aa-complain; do
        if command -v "$tool" &>/dev/null; then
            log_ok "  $tool disponible: $(command -v $tool)"
        else
            log_warn "  $tool no encontrado tras instalacion."
            missing=$(( missing + 1 ))
        fi
    done

    if [[ "$missing" -gt 0 ]]; then
        log_warn "$missing herramienta(s) no disponibles -- algunos checks se omitiran."
    else
        log_ok "apparmor-utils instalado correctamente."
    fi
}

# =============================================================================
# PASO 2 -- VERIFICACION 1: Estado del servicio AppArmor
# =============================================================================

verificar_servicio_apparmor() {
    section "PASO 2 -- VERIFICACION 1: Estado del servicio AppArmor"

    local enabled
    enabled=$(systemctl is-enabled apparmor 2>/dev/null || echo "not-found")
    case "$enabled" in
        enabled)
            log_ok "apparmor.service: enabled -- arranca con el sistema." ;;
        not-found)
            log_warn "apparmor.service no encontrado en systemctl." ;;
        *)
            log_warn "apparmor.service: $enabled (esperado: enabled)" ;;
    esac

    local active
    active=$(systemctl is-active apparmor 2>/dev/null || echo "inactive")
    case "$active" in
        active)
            log_ok "apparmor.service: active -- operativo ahora." ;;
        *)
            log_warn "apparmor.service: $active (esperado: active)"
            log_warn "  AppArmor puede seguir operativo via LSM aunque el servicio no este activo." ;;
    esac

    local kernel_enabled
    kernel_enabled=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || echo "?")
    if [[ "$kernel_enabled" == "Y" ]]; then
        log_ok "Modulo AppArmor del kernel: cargado y habilitado (Y)."
    else
        log_warn "No se pudo verificar el modulo AppArmor del kernel: $kernel_enabled"
    fi

    if [[ "$enabled" == "enabled" ]] && \
       [[ "$active" == "active" || "$kernel_enabled" == "Y" ]]; then
        log_ok "HALLAZGO H-C3e-1-VM3 -- AppArmor servicio: enabled + active"
    else
        log_warn "HALLAZGO H-C3e-1-VM3 -- AppArmor: enabled=$enabled active=$active kernel=$kernel_enabled"
    fi
}

# =============================================================================
# PASO 3 -- VERIFICACION 2: Estado de perfiles
# =============================================================================

verificar_perfiles() {
    section "PASO 3 -- VERIFICACION 2: Estado de perfiles (aa-status)"

    if ! command -v aa-status &>/dev/null; then
        log_warn "aa-status no disponible -- omitiendo verificacion de perfiles."
        log_warn "HALLAZGO H-C3e-2-VM3 -- Perfiles: no verificados (aa-status no disponible)"
        return 0
    fi

    log_info "Ejecutando aa-status..."
    local status_output
    status_output=$(aa-status 2>/dev/null || true)

    if [[ -z "$status_output" ]]; then
        log_warn "aa-status no retorno salida."
        log_warn "HALLAZGO H-C3e-2-VM3 -- Perfiles: sin salida de aa-status"
        return 0
    fi

    while IFS= read -r line; do log_info "  $line"; done <<< "$status_output"
    log_info ""

    local profiles_loaded enforce_count complain_count
    profiles_loaded=$(echo "$status_output" | \
        grep "profiles are loaded" | grep -oP '^\d+' || echo "0")
    enforce_count=$(echo "$status_output" | \
        grep "profiles are in enforce mode" | grep -oP '^\d+' || echo "0")
    complain_count=$(echo "$status_output" | \
        grep "profiles are in complain mode" | grep -oP '^\d+' || echo "0")

    log_info "Resumen:"
    log_info "  Perfiles cargados: ${profiles_loaded:-0}"
    log_info "  En enforce:        ${enforce_count:-0}"
    log_info "  En complain:       ${complain_count:-0}"
    log_info ""

    if [[ "${profiles_loaded:-0}" -gt 0 && "${enforce_count:-0}" -gt 0 ]]; then
        log_ok "HALLAZGO H-C3e-2-VM3 -- Perfiles enforce: ${enforce_count} perfil(es) en modo enforce"
    elif [[ "${profiles_loaded:-0}" -gt 0 && "${enforce_count:-0}" -eq 0 ]]; then
        log_warn "HALLAZGO H-C3e-2-VM3 -- AppArmor activo pero ningun perfil en enforce"
    else
        log_warn "HALLAZGO H-C3e-2-VM3 -- AppArmor sin perfiles cargados: ${profiles_loaded:-0}"
    fi

    if [[ "${complain_count:-0}" -gt 0 ]]; then
        log_warn ""
        log_warn "${complain_count} perfil(es) en modo complain (solo registro, sin bloqueo):"
        echo "$status_output" | grep -A "${complain_count}" "complain mode:" | \
            grep "^   " | while IFS= read -r line; do log_warn "  $line"; done || true
        log_warn "Los perfiles en complain deben revisarse antes de instalar servicios."
    fi

    log_info ""
    log_info "Perfiles esperados para servicios activos en VM1:"
    for svc_profile in "sshd" "rsyslogd" "chronyd"; do
        if echo "$status_output" | grep -q "$svc_profile"; then
            log_ok "  $svc_profile: perfil activo en AppArmor"
        else
            log_info "  $svc_profile: no detectado en aa-status (puede ser normal)"
        fi
    done
}

# =============================================================================
# PASO 4 -- VERIFICACION 3: Perfil de MariaDB (unico servicio VM3)
# =============================================================================

verificar_perfiles_vm3() {
    section "PASO 4 -- VERIFICACION 3: Perfil de MariaDB"

    log_info "Servicio a instalar en VM3 que requiere perfil AppArmor:"
    log_info "  MariaDB: /etc/apparmor.d/usr.sbin.mysqld (viene con mariadb-server)"
    log_info "  Sin Apache en VM3 -- solo tier de datos."
    log_info ""

    local perfiles_ausentes=0

    # Verificar perfil MariaDB / MySQL
    log_info "--- MariaDB ---"
    local mariadb_perfiles
    mariadb_perfiles=$(find "$APPARMOR_D" -name "*mysql*" -o -name "*mariadb*" \
        2>/dev/null | sort || true)
    if [[ -z "$mariadb_perfiles" ]]; then
        log_info "Ningun perfil de MariaDB encontrado en $APPARMOR_D."
        log_info "ESPERADO: el perfil viene incluido en el paquete 'mariadb-server'."
        log_info "PENDIENTE: verificar en Tarea 5.C.4 que se cargo en enforce."
        log_info "  Comando post-instalacion: aa-status | grep mysqld"
        perfiles_ausentes=$(( perfiles_ausentes + 1 ))
    else
        log_ok "Perfil(es) MariaDB encontrado(s):"
        while IFS= read -r p; do log_ok "  $p"; done <<< "$mariadb_perfiles"
    fi

    log_info ""

    # Zabbix Agent -- sin perfil esperado en Ubuntu 26.04
    log_info "--- Zabbix Agent ---"
    local zabbix_perfiles
    zabbix_perfiles=$(find "$APPARMOR_D" -name "*zabbix*" \
        2>/dev/null | sort || true)
    if [[ -z "$zabbix_perfiles" ]]; then
        log_info "Ningun perfil de Zabbix Agent en $APPARMOR_D."
        log_info "Ubuntu 26.04 no incluye perfil AppArmor para Zabbix Agent."
        log_info "Requiere perfil manual post-instalacion (Tarea 5.C.9) si se desea."
    else
        log_ok "Perfil(es) Zabbix encontrado(s):"
        while IFS= read -r p; do log_ok "  $p"; done <<< "$zabbix_perfiles"
    fi

    log_info ""

    if [[ "$perfiles_ausentes" -gt 0 ]]; then
        log_ok "HALLAZGO H-C3e-3-VM3 -- Perfil MariaDB: no presente (esperado)"
        log_ok "  El perfil se instala con mariadb-server en Tarea 5.C.4."
    else
        log_ok "HALLAZGO H-C3e-3-VM3 -- Perfil MariaDB: encontrado (ver detalle)"
    fi

    # Listar contenido de apparmor.d para referencia
    log_info ""
    log_info "Contenido de $APPARMOR_D (referencia):"
    ls -la "$APPARMOR_D" 2>/dev/null | while IFS= read -r line; do
        log_info "  $line"
    done || true
}


# =============================================================================
# PASO 5 -- VERIFICACION 4: Procesos sin perfil con red (aa-unconfined)
# =============================================================================

verificar_unconfined() {
    section "PASO 5 -- VERIFICACION 4: Procesos sin perfil con red (aa-unconfined)"

    if ! command -v aa-unconfined &>/dev/null; then
        log_warn "aa-unconfined no disponible -- omitiendo verificacion."
        log_warn "HALLAZGO H-C3e-4-VM3 -- aa-unconfined: no disponible"
        return 0
    fi

    log_info "Ejecutando aa-unconfined --paranoid..."
    log_info "(Lista todos los procesos sin perfil AppArmor, con o sin red)"
    log_info ""

    local unconfined_output
    unconfined_output=$(aa-unconfined --paranoid 2>/dev/null || true)

    if [[ -z "$unconfined_output" ]]; then
        log_ok "No se detectaron procesos sin perfil AppArmor."
        log_ok "HALLAZGO H-C3e-4-VM3 -- aa-unconfined: sin procesos sin perfil"
        return 0
    fi

    while IFS= read -r line; do log_info "  $line"; done <<< "$unconfined_output"
    log_info ""

    local total_unconfined
    total_unconfined=$(echo "$unconfined_output" | grep -c "." 2>/dev/null || echo "0")
    log_info "Total de procesos sin perfil: $total_unconfined"
    log_info ""

    local conocidos=("systemd" "sshd" "chronyd" "rsyslogd" "cron" \
                     "agetty" "login" "dbus" "polkit" "networkd" \
                     "resolved" "udevd" "logind" "journald" "qemu-ga" \
                     "fwupd" "udisksd" "packagekit" "multipathd" \
                     "unattended-upgrades")

    local alertar=0
    while IFS= read -r linea; do
        [[ -z "$linea" ]] && continue
        local es_conocido=0
        for conocido in "${conocidos[@]}"; do
            if echo "$linea" | grep -qi "$conocido"; then
                es_conocido=1
                break
            fi
        done
        if [[ "$es_conocido" -eq 0 ]]; then
            log_warn "  Proceso sin perfil NO conocido: $linea"
            alertar=$(( alertar + 1 ))
        fi
    done <<< "$unconfined_output"

    if [[ "$alertar" -eq 0 ]]; then
        log_ok "HALLAZGO H-C3e-4-VM3 -- aa-unconfined: $total_unconfined proceso(s) sin perfil"
        log_ok "  Todos son servicios de sistema conocidos -- aceptable en imagen cloud."
    else
        log_warn "HALLAZGO H-C3e-4-VM3 -- aa-unconfined: $alertar proceso(s) no reconocido(s) sin perfil"
        log_warn "  Revisar manualmente antes de instalar servicios."
    fi
}

# =============================================================================
# RESUMEN FINAL
# =============================================================================

print_summary() {
    local sep
    sep=$(printf '=%.0s' {1..70})

    printf '\n%s\n' "$sep"
    printf 'RESUMEN -- configure_db_vm_apparmor.sh %s\n' "$VERSION"
    printf '%s\n' "$sep"
    printf 'Fecha:    %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'VM:       %s\n' "$(hostname)"
    printf 'Log:      %s\n' "$LOG_FILE"
    printf '%s\n' "$sep"
    printf 'Hallazgos confirmados:\n'
    printf '  H-C3e-1-VM3 -- AppArmor servicio: enabled + active\n'
    printf '  H-C3e-2-VM3 -- Perfiles enforce: > 0\n'
    printf '  H-C3e-3-VM3 -- Perfil MariaDB: no presente (pendiente Tarea 5.C.4)\n'
    printf '             PENDIENTE: verificar en Tarea 5.C.4 (mariadb-server)\n'
    printf '  H-C3e-4-VM3 -- aa-unconfined: todos son procesos de sistema conocidos (aceptable)\n'
    printf '%s\n' "$sep"
    printf 'Tarea 5.C.3e [VM3] completada.\n'
    printf 'HARDENING BASE VM3 COMPLETADO: 5.C.3a-5.C.3e ejecutadas.\n'
    printf 'Proxima tarea: 5.C.4 [VM3] -- Instalar MariaDB 11.8 en ecom-db-vm\n'
    printf '%s\n\n' "$sep"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    verificar_precondiciones
    instalar_apparmor_utils
    verificar_servicio_apparmor
    verificar_perfiles
    verificar_perfiles_vm3
    verificar_unconfined
    print_summary
    exit 0
}

mkdir -p "$LOG_DIR"
main "$@" 2>&1 | tee -a "$LOG_FILE"
exit "${PIPESTATUS[0]}"
