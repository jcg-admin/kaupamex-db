#!/bin/bash
# =============================================================================
# configure_db_vm_mariadb_vdb.sh
# Mueve los datos de MariaDB de vda a vdb (Block Storage Clase C NVMe).
# Detiene MariaDB, formatea vdb con ext4, copia los datos via rsync,
# actualiza /etc/fstab con UUID de vdb, remonta y verifica que MariaDB
# arranca correctamente desde vdb.
#
# Ejecutar DENTRO de ecom-db-vm como:
#   sudo bash /tmp/configure_db_vm_mariadb_vdb.sh
#
# Contexto:  [VM3-UBUNTU] -- usuario ubuntu con sudo, dentro de ecom-db-vm
# Tarea:     5.1 [VM1] Script 2 -- Mover datos MariaDB a vdb (Clase C NVMe)
#
# Despliegue desde el Host:
#   scp -F /home/ubuntu/.ssh/config /tmp/configure_db_vm_mariadb_vdb.sh ecom-db:/tmp/
#   ssh ecom-db "sudo bash /tmp/configure_db_vm_mariadb_vdb.sh" 2>&1 | \
#       tee /tmp/log_tarea_5_1_vdb_vm1_$(date -u +%Y%m%dT%H%M%SZ).txt
#
# PREREQUISITO OBLIGATORIO:
#   configure_vm1_mariadb_install.sh (Script 1) debe haber completado
#   con PASS antes de ejecutar este script.
#
# Arquitectura de discos VM1:
#   vda (qcow2 20G, Clase B) -- SO + binarios MariaDB
#   vdb (raw 10G, Clase C NVMe, passthrough, ext4 UUID ce333b4b) -- /var/lib/mysql (datos)
#
# ADVERTENCIA CRITICA -- PASO 4 (mkfs):
#   mkfs.ext4 en vdb es DESTRUCTIVO e IRREVERSIBLE.
#   El PASO 1 verifica que vdb NO tiene FS antes de proceder.
#   Si vdb ya tiene FS, el script aborta sin tocar nada.
#
# Nota tecnica -- deteccion de estado MariaDB:
#   Se usa 'systemctl show --property=ActiveState --value' en lugar de
#   'systemctl is-active' porque en Ubuntu 26.04 con set -euo pipefail,
#   is-active retorna exit code 3 cuando el servicio esta inactive, lo
#   que interfiere con el manejo de errores del shell. show --property
#   retorna siempre exit code 0 con una sola linea limpia.
#   La verificacion de stop usa mariadb-admin ping (fallo = detenido).
#
# Hallazgos producidos:
#   H-C5-1-VM3 -- vdb montado en /var/lib/mysql (UUID en fstab, df confirma)
#   H-C5-2-VM3 -- MariaDB activo desde vdb (mariadb-admin ping OK)
#
# Script anterior: configure_db_vm_mariadb_install.sh (Tarea 5.C.4)
# Script siguiente: configure_db_vm_schema_qa.sh (Tarea 5.C.6a)
#
# -----------------------------------------------------------------------------
# Version  Fecha        Autor                                    Cambios
# -----------------------------------------------------------------------------
# v1.0.0   2026-06-20   Nestor Monroy <46802445+NestorMonroy    Version inicial.
#                       @users.noreply.github.com>
# v1.0.1   2026-06-20   Nestor Monroy <46802445+NestorMonroy    Fix: head -1 en
#                       @users.noreply.github.com>               capturas is-active
# v1.0.2   2026-06-20   Nestor Monroy <46802445+NestorMonroy    Fix: head -1 en
#                       @users.noreply.github.com>               PASO 1 tambien
# v1.0.3   2026-06-20   Nestor Monroy <46802445+NestorMonroy    Fix definitivo:
#                       @users.noreply.github.com>               reemplazar
#                                                                is-active por
#                                                                show --property=
#                                                                ActiveState.
#                                                                Stop verificado
#                                                                via socket ping.
# -----------------------------------------------------------------------------

set -euo pipefail

VERSION="v1.0.4"

# =============================================================================
# CONFIGURACION
# =============================================================================

readonly VDB_DEVICE="/dev/vdb"
readonly VDB_UUID_EXPECTED="ce333b4b-8c9e-4e84-ae59-4e174650bead"  # ext4 creado en Tarea 5.1 VM1 -- NO reformatear
readonly VDB_LABEL="mariadb-data"
readonly VDB_MOUNT="/var/lib/mysql"
readonly VDB_TMP_MOUNT="/mnt/vdb-tmp"
readonly FSTAB_FILE="/etc/fstab"
readonly LOG_DIR="/var/log/ecom-setup"
readonly LOG_FILE="${LOG_DIR}/configure_db_vm_mariadb_vdb_$(date -u +%Y-%m-%dT%H%M%SZ).log"

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

# Helper: obtener ActiveState de un servicio systemd.
# Usa 'show --property=ActiveState --value' en lugar de 'is-active':
#   - Retorna siempre exit code 0 (compatible con set -euo pipefail)
#   - Retorna UNA sola linea: "active", "inactive", "failed", etc.
#   - No tiene el problema de multilinea de is-active en Ubuntu 26.04
mariadb_active_state() {
    systemctl show mariadb --property=ActiveState --value 2>/dev/null \
        || echo "unknown"
}

# Helper: verificar si MariaDB responde en el socket.
# Retorna 0 si responde, 1 si no.
mariadb_socket_alive() {
    mariadb-admin ping --silent 2>/dev/null
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

    log_info "Script: configure_db_vm_mariadb_vdb.sh $VERSION"
    log_info "Dispositivo vdb: $VDB_DEVICE"
    log_info "Destino datos: $VDB_MOUNT"
    log_info "Log: $LOG_FILE"
}

# =============================================================================
# PASO 1 -- Verificar precondiciones
# =============================================================================

verificar_estado_inicial() {
    section "PASO 1 -- Verificar precondiciones"

    # 1a. MariaDB debe estar activo
    log_info "Verificando que MariaDB este activo (Script 1 completado)..."

    if ! command -v mariadb &>/dev/null; then
        die "mariadb CLI no encontrado. Ejecutar Script 1 primero."
    fi

    local estado
    estado=$(mariadb_active_state)
    log_info "mariadb.service ActiveState: $estado"

    if [[ "$estado" != "active" ]]; then
        die "mariadb.service no esta active (ActiveState: $estado). Script 1 debe completar con PASS primero."
    fi
    log_ok "mariadb.service: active."

    if ! mariadb_socket_alive; then
        die "MariaDB no responde en el socket aunque el servicio esta active."
    fi
    log_ok "Socket MariaDB respondiendo."

    # 1b. vdb debe existir como dispositivo de bloque
    log_info ""
    log_info "Verificando dispositivo $VDB_DEVICE..."
    if [[ ! -b "$VDB_DEVICE" ]]; then
        die "$VDB_DEVICE no existe como dispositivo de bloque."
    fi
    local vdb_size
    vdb_size=$(lsblk -d -n -o SIZE "$VDB_DEVICE" 2>/dev/null || echo "?")
    log_ok "$VDB_DEVICE presente -- tamaño: $vdb_size"

    # 1c. vdb DEBE tener ext4 con UUID ce333b4b (NO reformatear -- Tarea 5.1 VM1)
    log_info ""
    log_info "Verificando que $VDB_DEVICE tiene ext4 con UUID $VDB_UUID_EXPECTED..."
    local vdb_fstype
    vdb_fstype=$(blkid -s TYPE -o value "$VDB_DEVICE" 2>/dev/null || echo "")
    local vdb_uuid_real
    vdb_uuid_real=$(blkid -s UUID -o value "$VDB_DEVICE" 2>/dev/null || echo "")

    if [[ "$vdb_fstype" != "ext4" ]]; then
        die "$VDB_DEVICE no tiene ext4 (tipo: ${vdb_fstype:-ninguno}). Verificar passthrough Clase C."
    fi
    if [[ "$vdb_uuid_real" != "$VDB_UUID_EXPECTED" ]]; then
        die "UUID de vdb ($vdb_uuid_real) != esperado ($VDB_UUID_EXPECTED). Disco incorrecto."
    fi
    log_ok "$VDB_DEVICE tiene ext4 con UUID $vdb_uuid_real -- correcto (NO se reformatea)."
    VDB_UUID="$vdb_uuid_real"
    export VDB_UUID

    # Estado actual de discos
    log_info ""
    log_info "Estado actual de discos y montajes:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || true

    log_info ""
    log_info "Espacio en /var/lib/mysql (actualmente en vda):"
    du -sh "$VDB_MOUNT" 2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || true
}

# =============================================================================
# PASO 2 -- Detener MariaDB
# =============================================================================

detener_mariadb() {
    section "PASO 2 -- Detener MariaDB (OBLIGATORIO antes de mover datos)"

    log_warn "Deteniendo mariadb.service..."
    log_warn "ATENCION: MariaDB quedara fuera de servicio hasta el PASO 8."

    systemctl stop mariadb 2>/dev/null || true

    # Verificar via socket -- mas confiable que ActiveState en Ubuntu 26.04
    # Socket no disponible = MariaDB detenido correctamente
    local elapsed=0
    while (( elapsed < 30 )); do
        if ! mariadb_socket_alive; then
            log_ok "MariaDB detenido -- socket no responde (${elapsed}s). Seguro continuar."
            break
        fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
        log_info "  Esperando que MariaDB libere el socket... ${elapsed}s"
    done

    # Verificacion final via socket
    if mariadb_socket_alive; then
        die "MariaDB sigue respondiendo en el socket tras 30s. Abortar."
    fi

    # Confirmar via ActiveState como informacion adicional
    local estado_final
    estado_final=$(mariadb_active_state)
    log_info "mariadb.service ActiveState post-stop: $estado_final"
    log_ok "MariaDB detenido. Seguro continuar con movimiento de datos."
}

# =============================================================================
# PASO 3 -- Backup de /var/lib/mysql en vda
# =============================================================================

backup_datos_actuales() {
    section "PASO 3 -- Backup de /var/lib/mysql en vda"

    local timestamp
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    local backup_dir="/var/lib/mysql.bak_${timestamp}"

    log_info "Creando backup: $backup_dir"
    log_info "Permanece en vda como red de seguridad."

    if cp -a "$VDB_MOUNT" "$backup_dir" 2>/dev/null; then
        local backup_size
        backup_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1 || echo "?")
        log_ok "Backup creado: $backup_dir ($backup_size)"
    else
        die "No se pudo crear el backup de $VDB_MOUNT."
    fi

    log_info "Para eliminar tras verificar vdb: sudo rm -rf $backup_dir"
}

# =============================================================================
# PASO 4 -- ELIMINADO para VM3 (ext4 ya existe en vdb)
# =============================================================================
# El FS ext4 (UUID ce333b4b) fue creado en Tarea 5.1 de VM1 con mkfs.ext4.
# Los datos de MariaDB de VM1 fueron eliminados con rm -rf en el rollback.
# El FS esta limpio pero intacto -- VM3 lo usa directamente sin reformatear.
# VDB_UUID fue establecido en PASO 1c via blkid.
#
# formatear_vdb() -- NO DEFINIDA en VM3 (no se invoca desde main())

# Funcion dummy para documentar la omision
formatear_vdb_omitido() {
    section "PASO 4 -- OMITIDO: ext4 (UUID $VDB_UUID_EXPECTED) ya existe en vdb"
    log_ok "vdb ya tiene ext4 con UUID $VDB_UUID -- sin mkfs."
    log_ok "VDB_UUID = $VDB_UUID"
}

# =============================================================================
# PASO 5 -- Copiar datos vda → vdb
# =============================================================================

copiar_datos() {
    section "PASO 5 -- Copiar datos /var/lib/mysql → $VDB_DEVICE"

    mkdir -p "$VDB_TMP_MOUNT"
    log_info "Montando $VDB_DEVICE en $VDB_TMP_MOUNT..."
    if ! mount "$VDB_DEVICE" "$VDB_TMP_MOUNT" 2>/dev/null; then
        die "No se pudo montar $VDB_DEVICE en $VDB_TMP_MOUNT."
    fi
    log_ok "$VDB_DEVICE montado en $VDB_TMP_MOUNT."

    log_info ""
    log_info "Ejecutando rsync $VDB_MOUNT/ → $VDB_TMP_MOUNT/ (-aAX)"
    if ! rsync -aAX --info=progress2 \
            "$VDB_MOUNT/" "$VDB_TMP_MOUNT/" 2>&1 | \
            while IFS= read -r line; do log_info "  $line"; done; then
        log_error "rsync fallo."
        umount "$VDB_TMP_MOUNT" 2>/dev/null || true
        die "Error en rsync. vdb desmontado. Datos originales intactos en vda."
    fi
    log_ok "rsync completado."

    log_info ""
    log_info "Espacio ocupado en vdb tras rsync:"
    df -h "$VDB_TMP_MOUNT" 2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || true

    log_info ""
    log_info "Desmontando $VDB_TMP_MOUNT..."
    if ! umount "$VDB_TMP_MOUNT" 2>/dev/null; then
        die "No se pudo desmontar $VDB_TMP_MOUNT."
    fi
    rmdir "$VDB_TMP_MOUNT" 2>/dev/null || true
    log_ok "$VDB_DEVICE desmontado de $VDB_TMP_MOUNT."
}

# =============================================================================
# PASO 6 -- Actualizar /etc/fstab con UUID de vdb
# =============================================================================

actualizar_fstab() {
    section "PASO 6 -- Actualizar $FSTAB_FILE con UUID de vdb"

    log_info "UUID de vdb: $VDB_UUID"

    if grep -q "$VDB_UUID" "$FSTAB_FILE" 2>/dev/null; then
        log_info "UUID ya presente en fstab -- sin cambios (idempotente)."
        return 0
    fi

    # Comentar entrada previa de /var/lib/mysql si existe
    if grep -qE "[[:space:]]${VDB_MOUNT}[[:space:]]" "$FSTAB_FILE" 2>/dev/null; then
        log_warn "Entrada existente para $VDB_MOUNT en fstab -- comentando."
        sed -i "s|^\([^#].*[[:space:]]${VDB_MOUNT}[[:space:]].*\)|# REEMPLAZADO: \1|" \
            "$FSTAB_FILE"
    fi

    # Backup de fstab
    local fstab_bak="${FSTAB_FILE}.bak_$(date -u +%Y%m%dT%H%M%SZ)"
    cp "$FSTAB_FILE" "$fstab_bak"
    log_info "Backup fstab: $fstab_bak"

    # Agregar entrada
    local fstab_entry="UUID=${VDB_UUID} ${VDB_MOUNT} ext4 defaults,noatime 0 2"
    {
        echo ""
        echo "# ecom-prod: MariaDB datos en vdb (Block Storage Clase C NVMe)"
        echo "# configure_db_vm_mariadb_vdb.sh ${VERSION} -- $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "$fstab_entry"
    } >> "$FSTAB_FILE"

    log_ok "Entrada agregada: $fstab_entry"

    log_info ""
    log_info "Contenido relevante de fstab:"
    grep -v "^#\|^$" "$FSTAB_FILE" 2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || true
}

# =============================================================================
# PASO 7 -- Remontar vdb en /var/lib/mysql y ajustar permisos
# =============================================================================

remontar_y_permisos() {
    section "PASO 7 -- Remontar vdb en $VDB_MOUNT y ajustar permisos"

    log_info "Ejecutando mount -a para montar vdb desde fstab..."
    if ! mount -a 2>/dev/null; then
        die "mount -a fallo. Verificar fstab y UUID: blkid $VDB_DEVICE"
    fi

    local mount_device
    mount_device=$(findmnt -n -o SOURCE "$VDB_MOUNT" 2>/dev/null || echo "")
    if [[ -z "$mount_device" ]]; then
        die "$VDB_MOUNT no aparece montado tras mount -a."
    fi
    log_ok "$VDB_MOUNT montado desde: $mount_device"

    local mounted_uuid
    mounted_uuid=$(blkid -s UUID -o value "$mount_device" 2>/dev/null || echo "")
    if [[ "$mounted_uuid" == "$VDB_UUID" ]]; then
        log_ok "UUID confirmado: es vdb correcto."
    else
        log_warn "UUID montado ($mounted_uuid) != UUID vdb ($VDB_UUID) -- verificar."
    fi

    log_info ""
    log_info "Ajustando permisos: chown -R mysql:mysql $VDB_MOUNT"
    if ! chown -R mysql:mysql "$VDB_MOUNT" 2>/dev/null; then
        die "chown -R mysql:mysql $VDB_MOUNT fallo."
    fi
    log_ok "Permisos ajustados: mysql:mysql en $VDB_MOUNT"

    log_info ""
    log_info "Espacio disponible en vdb:"
    df -h "$VDB_MOUNT" 2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || true
}

# =============================================================================
# PASO 8 -- Arrancar MariaDB desde vdb
# =============================================================================

arrancar_mariadb() {
    section "PASO 8 -- Arrancar MariaDB desde vdb"

    log_info "Arrancando mariadb.service..."
    if ! systemctl start mariadb 2>/dev/null; then
        log_error "mariadb.service no arranco. Diagnostico:"
        journalctl -u mariadb --no-pager -n 30 2>/dev/null | \
            while IFS= read -r line; do log_error "  $line"; done || true
        die "MariaDB no arranco desde vdb."
    fi

    # Esperar socket -- no systemctl is-active
    local elapsed=0
    while (( elapsed < 30 )); do
        if mariadb_socket_alive; then
            log_ok "Socket MariaDB disponible desde vdb (${elapsed}s)."
            break
        fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
        log_info "  Esperando socket desde vdb... ${elapsed}s"
    done

    if ! mariadb_socket_alive; then
        die "MariaDB no responde en el socket tras 30s desde vdb."
    fi

    log_ok "MariaDB arrancado y respondiendo desde vdb."
}

# =============================================================================
# PASO 9 -- Verificar post-movimiento
# =============================================================================

verificar_post_movimiento() {
    section "PASO 9 -- Verificar post-movimiento"

    # H-C5-1-VM3
    local mount_device
    mount_device=$(findmnt -n -o SOURCE "$VDB_MOUNT" 2>/dev/null || echo "")
    local mounted_uuid
    mounted_uuid=$(blkid -s UUID -o value "$mount_device" 2>/dev/null || echo "")
    local fstab_ok=false
    grep -q "$VDB_UUID" "$FSTAB_FILE" 2>/dev/null && fstab_ok=true

    if [[ -n "$mount_device" && "$mounted_uuid" == "$VDB_UUID" \
          && "$fstab_ok" == "true" ]]; then
        log_ok "HALLAZGO H-C5-1-VM3 -- vdb montado en $VDB_MOUNT"
        log_ok "  Dispositivo: $mount_device | UUID: $mounted_uuid"
        log_ok "  fstab: UUID presente (persistencia en reboot garantizada)"
    else
        log_warn "HALLAZGO H-C5-1-VM3 -- vdb montaje incompleto:"
        log_warn "  Dispositivo: ${mount_device:-no montado}"
        log_warn "  UUID coincide: $([ "$mounted_uuid" == "$VDB_UUID" ] && echo si || echo no)"
        log_warn "  UUID en fstab: $fstab_ok"
    fi

    log_info ""
    df -h "$VDB_MOUNT" 2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || true

    # H-C5-2-VM3
    log_info ""
    local estado_final
    estado_final=$(mariadb_active_state)
    local ping_result
    ping_result=$(mariadb-admin ping 2>/dev/null || echo "no responde")

    if [[ "$estado_final" == "active" && "$ping_result" == "mysqld is alive" ]]; then
        log_ok "HALLAZGO H-C5-2-VM3 -- MariaDB activo desde vdb"
        log_ok "  ActiveState: $estado_final | ping: $ping_result"
    else
        log_warn "HALLAZGO H-C5-2-VM3 -- MariaDB no confirma:"
        log_warn "  ActiveState: $estado_final | ping: $ping_result"
    fi

    # datadir confirmacion
    log_info ""
    log_info "Confirmacion datadir desde MariaDB:"
    mariadb --batch --silent \
        -e "SELECT @@datadir, @@socket, VERSION();" 2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || \
        log_warn "  No se pudo consultar datadir."

    # Backup info
    log_info ""
    log_info "Backup en vda (eliminar tras verificar):"
    ls -d /var/lib/mysql.bak_* 2>/dev/null | \
        while IFS= read -r dir; do
            local sz; sz=$(du -sh "$dir" 2>/dev/null | cut -f1 || echo "?")
            log_info "  $dir ($sz)"
        done || log_info "  (ninguno)"
    log_info "  sudo rm -rf /var/lib/mysql.bak_*"
}

# =============================================================================
# RESUMEN FINAL
# =============================================================================

print_summary() {
    local sep
    sep=$(printf '=%.0s' {1..70})

    local estado_final
    estado_final=$(mariadb_active_state)

    local mount_device
    mount_device=$(findmnt -n -o SOURCE "$VDB_MOUNT" 2>/dev/null || echo "?")

    local ping_result
    ping_result=$(mariadb-admin ping 2>/dev/null || echo "no responde")

    printf '\n%s\n' "$sep"
    printf 'RESUMEN -- configure_db_vm_mariadb_vdb.sh %s\n' "$VERSION"
    printf '%s\n' "$sep"
    printf 'Fecha:    %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'VM:       %s | IP: 192.168.100.30\n' "$(hostname)"
    printf 'Log:      %s\n' "$LOG_FILE"
    printf '%s\n' "$sep"
    printf 'Hallazgos confirmados:\n'
    printf '  H-C5-1-VM3 -- vdb montado en %s\n' "$VDB_MOUNT"
    printf '             Dispositivo: %s\n' "$mount_device"
    printf '  H-C5-2-VM3 -- MariaDB: %s | ping: %s\n' "$estado_final" "$ping_result"
    printf '%s\n' "$sep"
    printf 'Datos MariaDB en vdb (Clase C NVMe).\n'
    printf 'Backup en vda: /var/lib/mysql.bak_* (eliminar tras verificar).\n'
    printf '%s\n' "$sep"
    printf 'Tarea 5.C.5 completa (MariaDB en vdb).\n'
    printf 'Proxima tarea: 5.C.6a [VM3] -- Schemas QA (configure_db_vm_schema_qa.sh)\n'
    printf '%s\n\n' "$sep"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    verificar_precondiciones
    verificar_estado_inicial
    detener_mariadb
    backup_datos_actuales
    formatear_vdb_omitido
    copiar_datos
    actualizar_fstab
    remontar_y_permisos
    arrancar_mariadb
    verificar_post_movimiento
    print_summary
    exit 0
}

mkdir -p "$LOG_DIR"
main "$@" 2>&1 | tee -a "$LOG_FILE"
exit "${PIPESTATUS[0]}"
