#!/bin/bash
# =============================================================================
# configure_db_vm_schema_qa.sh
# Crea el schema de QA (kaupamex_qa) y el usuario practicayoruba_app
# en MariaDB 11.8 en ecom-db-vm.
#
# Ejecutar DENTRO de ecom-db-vm como:
#   sudo bash /tmp/configure_db_vm_schema_qa.sh
#
# Contexto:  [VM3-UBUNTU] -- usuario ubuntu con sudo, dentro de ecom-db-vm
# Tarea:     5.6a [VM1] -- Schema QA + usuario practicayoruba_app
#
# Despliegue desde el Host:
#   scp -F /home/ubuntu/.ssh/config /tmp/configure_db_vm_schema_qa.sh ecom-db:/tmp/
#   ssh ecom-db "sudo PRACTICAYORUBA_APP_PASSWORD=<pass> bash /tmp/configure_db_vm_schema_qa.sh" 2>&1 | \
#       tee /tmp/log_tarea_5_6a_vm1_$(date -u +%Y%m%dT%H%M%SZ).txt
#
# Prerequisitos:
#   - MariaDB 11.8 activo desde vdb (Tarea 5.C.5 COMPLETADA)
#   - Socket /run/mysqld/mysqld.sock disponible
#
# Qué crea:
#   Schema:  kaupamex_qa  (utf8mb4 / utf8mb4_unicode_ci)
#   Usuario: practicayoruba_app (hosts: %, localhost, 127.0.0.1)
#   GRANTs:  ALL PRIVILEGES en kaupamex_qa.*
#            ALL PRIVILEGES en test_kaupamex_qa.*  (pytest)
#
# Naming: practicayoruba_app = nombre_producto + rol (app)
#   Convencion confirmada: nombre del proyecto + rol.
#   NO usar django_user (nombra la tecnologia, no el servicio).
#   Ver analisis-tarea-5C-6a-schema-qa-ecom-db-vm-v1_0_0.md Seccion 2.
#
# Invariante de contrasena:
#   practicayoruba_app es el MISMO usuario MariaDB para QA y produccion.
#   La contrasena definida aqui DEBE ser identica a la usada en
#   configure_db_vm_schema_prod.sh. Contrasenas distintas causan
#   "Access denied" al verificar la conexion QA.
#   Ver .env.example de kaupamex-db: INVARIANTE DB_QA_PASSWORD = DB_PASSWORD.
#
# Privilegios QA (ALL PRIVILEGES):
#   pytest necesita CREATE DATABASE / DROP DATABASE para test_kaupamex_qa.
#   En QA no aplica PoLP estricto -- es el entorno de pruebas.
#   En produccion los privilegios son DML limitados (ver configure_db_vm_schema_prod.sh).
#
# Idempotente:
#   Schema ya existe    -> skip (sin cambios)
#   Usuario ya existe   -> sincroniza contrasena (ALTER USER)
#   GRANTs ya aplicados -> no-op (GRANT es idempotente en MariaDB)
#
# Hallazgos producidos:
#   H-C6a-1-VM3 -- kaupamex_qa creado (utf8mb4_unicode_ci)
#   H-C6a-2-VM3 -- practicayoruba_app creado (3 hosts, conexion verificada)
#
# Analisis de referencia: analisis-tarea-5C-6a-schema-qa-ecom-db-vm-v1_0_0.md
#
# -----------------------------------------------------------------------------
# Version  Fecha        Autor                                    Cambios
# -----------------------------------------------------------------------------
# v1.0.0   2026-06-20   Nestor Monroy <46802445+NestorMonroy    Version inicial.
#                       @users.noreply.github.com>               Schema QA.
#                                                                Usuario
#                                                                practicayoruba_app.
#                                                                H-C6a-1-VM3,H-C6a-2-VM3.
# -----------------------------------------------------------------------------

set -euo pipefail

VERSION="v1.0.1"

# =============================================================================
# CONFIGURACION
# =============================================================================

readonly DB_QA_NAME="kaupamex_qa"
readonly DB_APP_USER="practicayoruba_app"
readonly DB_CHARSET="utf8mb4"
readonly DB_COLLATION="utf8mb4_unicode_ci"
readonly DB_SOCKET="/run/mysqld/mysqld.sock"
readonly DB_HOST="192.168.100.30"
readonly DB_PORT="3306"

# Contrasena del usuario de aplicacion
# INVARIANTE: debe ser identica en configure_db_vm_schema_prod.sh
# Cambiar antes de ejecutar en produccion -- NO usar el default
readonly DB_APP_PASSWORD="${PRACTICAYORUBA_APP_PASSWORD:?Variable PRACTICAYORUBA_APP_PASSWORD no definida. Ejecutar como: sudo PRACTICAYORUBA_APP_PASSWORD=<pass> bash /tmp/configure_db_vm_schema_qa.sh}"

readonly LOG_DIR="/var/log/ecom-setup"
readonly LOG_FILE="${LOG_DIR}/configure_db_vm_schema_qa_$(date -u +%Y-%m-%dT%H%M%SZ).log"

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

# Ejecutar SQL como root via socket-primero, fallback TCP
db_exec() {
    local sql="$1"
    if [[ -S "$DB_SOCKET" ]]; then
        mariadb --socket="$DB_SOCKET" --silent \
            -e "$sql" 2>&1
    else
        mariadb --host="$DB_HOST" --port="$DB_PORT" --silent \
            -e "$sql" 2>&1
    fi
}

# Ejecutar SQL y retornar valor escalar (sin cabecera)
db_query() {
    local sql="$1"
    if [[ -S "$DB_SOCKET" ]]; then
        mariadb --socket="$DB_SOCKET" --silent --skip-column-names \
            -e "$sql" 2>/dev/null || echo "0"
    else
        mariadb --host="$DB_HOST" --port="$DB_PORT" --silent --skip-column-names \
            -e "$sql" 2>/dev/null || echo "0"
    fi
}

# =============================================================================
# VERIFICACIONES INICIALES
# =============================================================================

verificar_precondiciones() {
    if [[ $EUID -ne 0 ]]; then
        printf '[ERROR] Ejecutar como: sudo PRACTICAYORUBA_APP_PASSWORD=<pass> bash /tmp/%s\n' \
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

    # Verificar CLI mariadb disponible
    if ! command -v mariadb &>/dev/null; then
        die "mariadb CLI no encontrado. MariaDB 11.8 debe estar instalado (Tarea 5.1)."
    fi
    log_ok "CLI mariadb disponible: $(mariadb --version 2>/dev/null | head -1)"

    # Verificar mariadb-admin
    if ! command -v mariadb-admin &>/dev/null; then
        die "mariadb-admin no encontrado."
    fi

    # Verificar MariaDB activo
    if [[ -S "$DB_SOCKET" ]]; then
        if mariadb-admin --socket="$DB_SOCKET" ping --silent 2>/dev/null; then
            log_ok "MariaDB activo (socket: $DB_SOCKET)"
        else
            die "MariaDB no responde en socket $DB_SOCKET."
        fi
    else
        log_warn "Socket $DB_SOCKET no disponible -- intentando TCP $DB_HOST:$DB_PORT"
        if mariadb-admin --host="$DB_HOST" --port="$DB_PORT" ping --silent 2>/dev/null; then
            log_ok "MariaDB activo (TCP: $DB_HOST:$DB_PORT)"
        else
            die "MariaDB no responde ni por socket ni por TCP."
        fi
    fi

    # Verificar version 11.8
    local version
    version=$(db_query "SELECT @@version;")
    log_info "Version MariaDB: $version"
    if [[ "$version" != 11.8* ]]; then
        log_warn "Version no es 11.8.x -- continuando de todas formas."
    fi

    log_info "Script: configure_db_vm_schema_qa.sh $VERSION"
    log_info "Schema QA: $DB_QA_NAME"
    log_info "Usuario:   $DB_APP_USER"
    log_info "Log:       $LOG_FILE"
}

# =============================================================================
# PASO 1 -- Auditoria estado actual
# =============================================================================

auditar_estado_actual() {
    section "PASO 1 -- Auditoria del estado actual"

    log_info "Schemas existentes en MariaDB:"
    db_exec "SHOW DATABASES;" | grep -v "^information_schema$\|^performance_schema$\|^mysql$\|^sys$" | \
        while IFS= read -r line; do log_info "  $line"; done || true

    log_info ""
    log_info "Schema $DB_QA_NAME:"
    local schema_existe
    schema_existe=$(db_query "SELECT COUNT(*) FROM information_schema.SCHEMATA
                              WHERE SCHEMA_NAME = '${DB_QA_NAME}';")
    if [[ "$schema_existe" -gt 0 ]]; then
        log_warn "  Ya existe -- se verificaran owners y grants (idempotente)."
    else
        log_info "  No existe -- se creara."
    fi

    log_info ""
    log_info "Usuario $DB_APP_USER:"
    local user_existe
    user_existe=$(db_query "SELECT COUNT(*) FROM mysql.user
                            WHERE User = '${DB_APP_USER}';")
    if [[ "$user_existe" -gt 0 ]]; then
        log_warn "  Ya existe en $user_existe host(s) -- se sincronizara la contrasena."
    else
        log_info "  No existe -- se creara en 3 hosts (%, localhost, 127.0.0.1)."
    fi
}

# =============================================================================
# PASO 2 -- Crear schema kaupamex_qa
# =============================================================================

crear_schema_qa() {
    section "PASO 2 -- Crear schema $DB_QA_NAME"

    local schema_existe
    schema_existe=$(db_query "SELECT COUNT(*) FROM information_schema.SCHEMATA
                              WHERE SCHEMA_NAME = '${DB_QA_NAME}';")

    if [[ "$schema_existe" -gt 0 ]]; then
        log_info "Schema $DB_QA_NAME ya existe -- sin cambios."
    else
        db_exec "CREATE DATABASE \`${DB_QA_NAME}\`
                 CHARACTER SET ${DB_CHARSET}
                 COLLATE ${DB_COLLATION};" > /dev/null
        log_ok "Schema ${DB_QA_NAME} creado (${DB_CHARSET} / ${DB_COLLATION})."
    fi

    # Verificar charset y collation
    local charset collation
    charset=$(db_query "SELECT DEFAULT_CHARACTER_SET_NAME
                        FROM information_schema.SCHEMATA
                        WHERE SCHEMA_NAME = '${DB_QA_NAME}';")
    collation=$(db_query "SELECT DEFAULT_COLLATION_NAME
                          FROM information_schema.SCHEMATA
                          WHERE SCHEMA_NAME = '${DB_QA_NAME}';")
    log_info "  Charset:   $charset"
    log_info "  Collation: $collation"

    log_ok "HALLAZGO H-C6a-1-VM3 -- Schema ${DB_QA_NAME}: ${charset} / ${collation}"
}

# =============================================================================
# PASO 3 -- Crear usuario practicayoruba_app
# =============================================================================

crear_usuario() {
    section "PASO 3 -- Crear usuario $DB_APP_USER"

    for host in "%" "localhost" "127.0.0.1"; do
        local user_en_host
        user_en_host=$(db_query "SELECT COUNT(*) FROM mysql.user
                                 WHERE User = '${DB_APP_USER}'
                                   AND Host = '${host}';")

        if [[ "$user_en_host" -gt 0 ]]; then
            # Ya existe -- sincronizar contrasena
            db_exec "ALTER USER '${DB_APP_USER}'@'${host}'
                     IDENTIFIED BY '${DB_APP_PASSWORD}';" > /dev/null
            log_ok "  ${DB_APP_USER}@${host} -- contrasena sincronizada."
        else
            db_exec "CREATE USER '${DB_APP_USER}'@'${host}'
                     IDENTIFIED BY '${DB_APP_PASSWORD}';" > /dev/null
            log_ok "  ${DB_APP_USER}@${host} -- creado."
        fi
    done

    db_exec "FLUSH PRIVILEGES;" > /dev/null
    log_ok "Privilegios recargados."
}

# =============================================================================
# PASO 4 -- Otorgar privilegios en kaupamex_qa
# =============================================================================

otorgar_privilegios_qa() {
    section "PASO 4 -- Privilegios en $DB_QA_NAME"

    local test_db="test_${DB_QA_NAME}"

    log_info "Privilegios QA: ALL PRIVILEGES (pytest necesita CREATE/DROP DATABASE)"

    for host in "%" "localhost" "127.0.0.1"; do
        # Schema QA -- ALL PRIVILEGES (entorno de pruebas)
        db_exec "GRANT ALL PRIVILEGES ON \`${DB_QA_NAME}\`.*
                 TO '${DB_APP_USER}'@'${host}';" > /dev/null
        log_ok "  GRANT ALL PRIVILEGES ON ${DB_QA_NAME}.* TO ${DB_APP_USER}@${host}"

        # test_kaupamex_qa -- pytest crea/destruye este schema
        db_exec "GRANT ALL PRIVILEGES ON \`${test_db}\`.*
                 TO '${DB_APP_USER}'@'${host}';" > /dev/null
        log_ok "  GRANT ALL PRIVILEGES ON ${test_db}.* TO ${DB_APP_USER}@${host}"
    done

    db_exec "FLUSH PRIVILEGES;" > /dev/null
    log_ok "Privilegios aplicados."
}

# =============================================================================
# PASO 5 -- Verificar conexion con credenciales de practicayoruba_app
# =============================================================================

verificar_conexion() {
    section "PASO 5 -- Verificar conexion ${DB_APP_USER} -> ${DB_QA_NAME}"

    local resultado
    if [[ -S "$DB_SOCKET" ]]; then
        resultado=$(mariadb \
            --socket="$DB_SOCKET" \
            --user="$DB_APP_USER" \
            --password="$DB_APP_PASSWORD" \
            --silent --skip-column-names \
            "$DB_QA_NAME" \
            -e "SELECT CONCAT(DATABASE(), ' @ ', USER());" 2>&1) || {
            die "No se pudo conectar como ${DB_APP_USER} a ${DB_QA_NAME}. Verificar contrasena y grants."
        }
    else
        resultado=$(mariadb \
            --host="$DB_HOST" \
            --port="$DB_PORT" \
            --user="$DB_APP_USER" \
            --password="$DB_APP_PASSWORD" \
            --silent --skip-column-names \
            "$DB_QA_NAME" \
            -e "SELECT CONCAT(DATABASE(), ' @ ', USER());" 2>&1) || {
            die "No se pudo conectar como ${DB_APP_USER} a ${DB_QA_NAME}. Verificar contrasena y grants."
        }
    fi

    log_ok "Conexion verificada: $resultado"
    log_ok "HALLAZGO H-C6a-2-VM3 -- ${DB_APP_USER}: 3 hosts -- conexion QA OK"
}

# =============================================================================
# PASO 6 -- Mostrar grants aplicados
# =============================================================================

mostrar_grants() {
    section "PASO 6 -- Grants de ${DB_APP_USER}"

    for host in "%" "localhost" "127.0.0.1"; do
        log_info "  SHOW GRANTS FOR '${DB_APP_USER}'@'${host}':"
        db_exec "SHOW GRANTS FOR '${DB_APP_USER}'@'${host}';" 2>/dev/null | \
            while IFS= read -r line; do log_info "    $line"; done || true
        log_info ""
    done
}

# =============================================================================
# RESUMEN FINAL
# =============================================================================

print_summary() {
    local sep
    sep=$(printf '=%.0s' {1..70})

    printf '\n%s\n' "$sep"
    printf 'RESUMEN -- configure_db_vm_schema_qa.sh %s\n' "$VERSION"
    printf '%s\n' "$sep"
    printf 'Fecha:    %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'VM:       %s | MariaDB: %s\n' \
        "$(hostname)" "$(db_query "SELECT @@version;" 2>/dev/null || echo "?")"
    printf 'Log:      %s\n' "$LOG_FILE"
    printf '%s\n' "$sep"
    printf 'Schema QA creado:\n'
    printf '  Nombre:    %s\n' "$DB_QA_NAME"
    printf '  Charset:   %s / %s\n' "$DB_CHARSET" "$DB_COLLATION"
    printf 'Usuario creado:\n'
    printf '  Usuario:   %s\n' "$DB_APP_USER"
    printf '  Hosts:     %%, localhost, 127.0.0.1\n'
    printf '  Privilegios QA:          ALL PRIVILEGES ON %s.*\n' "$DB_QA_NAME"
    printf '  Privilegios test QA:     ALL PRIVILEGES ON test_%s.*\n' "$DB_QA_NAME"
    printf '%s\n' "$sep"
    printf 'Hallazgos confirmados:\n'
    printf '  H-C6a-1-VM3 -- Schema %s: %s / %s\n' \
        "$DB_QA_NAME" "$DB_CHARSET" "$DB_COLLATION"
    printf '  H-C6a-2-VM3 -- %s: 3 hosts -- conexion QA verificada\n' "$DB_APP_USER"
    printf '%s\n' "$sep"
    printf 'INVARIANTE: La contrasena de %s DEBE ser la misma\n' "$DB_APP_USER"
    printf '  en configure_db_vm_schema_prod.sh.\n'
    printf '%s\n' "$sep"
    printf 'Tarea 5.C.6a [VM3] completada.\n'
    printf 'Proxima tarea: 5.C.6b [VM3] -- Schema kaupamex_db (configure_db_vm_schema_prod.sh)\n'
    printf '%s\n\n' "$sep"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    verificar_precondiciones
    auditar_estado_actual
    crear_schema_qa
    crear_usuario
    otorgar_privilegios_qa
    verificar_conexion
    mostrar_grants
    print_summary
    exit 0
}

mkdir -p "$LOG_DIR"
main "$@" 2>&1 | tee -a "$LOG_FILE"
exit "${PIPESTATUS[0]}"
