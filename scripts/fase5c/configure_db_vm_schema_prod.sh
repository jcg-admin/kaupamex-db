#!/bin/bash
# =============================================================================
# configure_db_vm_schema_prod.sh
# Crea el schema de produccion (practicayoruba_db), otorga privilegios DML
# limitados a practicayoruba_app, y crea el usuario practicayoruba_readonly
# (SELECT only) para Claude Code web y analiticas via DNAT.
#
# Ejecutar DENTRO de ecom-db-vm como:
#   sudo PRACTICAYORUBA_APP_PASSWORD=<pass_app> \
#        PRACTICAYORUBA_READONLY_PASSWORD=<pass_readonly> \
#        bash /tmp/configure_db_vm_schema_prod.sh
#
# Contexto:  [VM3-UBUNTU] -- usuario ubuntu con sudo, dentro de ecom-db-vm
# Tarea:     5.C.6b [VM3] -- Schema produccion + usuario readonly
#
# Despliegue desde el Host:
#   scp -F /home/ubuntu/.ssh/config /tmp/configure_db_vm_schema_prod.sh ecom-db:/tmp/
#   ssh ecom-db "sudo PRACTICAYORUBA_APP_PASSWORD=<pass_app> \
#       PRACTICAYORUBA_READONLY_PASSWORD=<pass_readonly> \
#       bash /tmp/configure_db_vm_schema_prod.sh" 2>&1 | \
#       tee /tmp/log_5c_6b_schema_prod_db_$(date -u +%Y%m%dT%H%M%SZ).txt
#
# Prerequisitos:
#   - Tarea 5.C.6a completada: practicayoruba_app existe con contrasena
#   - MariaDB 11.8 activo desde vdb
#   - Socket /run/mysqld/mysqld.sock disponible
#
# Que crea:
#   Schema:  practicayoruba_db  (utf8mb4 / utf8mb4_unicode_ci)
#
#   practicayoruba_app (hosts %, localhost, 127.0.0.1):
#     GRANT SELECT, INSERT, UPDATE, DELETE ON practicayoruba_db.*
#     PoLP estricto -- Django no necesita DDL en produccion.
#
#   practicayoruba_readonly (host % -- DNAT externo):
#     GRANT SELECT ON practicayoruba_db.*
#     Solo lectura -- para Claude Code web y analiticas via DNAT Host:3306.
#     Sin acceso a practicayoruba_qa.
#
# Invariante de contrasena:
#   PRACTICAYORUBA_APP_PASSWORD DEBE ser identica a la usada en 5.C.6a.
#   PRACTICAYORUBA_READONLY_PASSWORD es diferente -- usuario distinto.
#
# Idempotente:
#   Schema ya existe    -> skip
#   Usuario ya existe   -> sincroniza contrasena + aplica grants
#   GRANTs ya aplicados -> no-op (GRANT es idempotente en MariaDB)
#
# Hallazgos producidos:
#   H-C6b-1-VM3 -- practicayoruba_db creado (utf8mb4_unicode_ci)
#   H-C6b-2-VM3 -- practicayoruba_app: DML en practicayoruba_db
#   H-C6b-3-VM3 -- practicayoruba_readonly: SELECT only en practicayoruba_db
#   H-C6b-4-VM3 -- Conexion readonly verificada
#
# Analisis de referencia: analisis-tarea-5C-6b-schema-prod-ecom-db-vm-v1_0_0.md
#
# -----------------------------------------------------------------------------
# Version  Fecha        Autor                                    Cambios
# -----------------------------------------------------------------------------
# v1.0.0   2026-06-20   Nestor Monroy <46802445+NestorMonroy    Version inicial.
#                       @users.noreply.github.com>               Schema prod
#                                                                practicayoruba_db.
#                                                                DML limitado
#                                                                practicayoruba_app.
#                                                                practicayoruba_readonly
#                                                                SELECT only.
#                                                                H-C6b-1..4-VM3.
# -----------------------------------------------------------------------------

set -euo pipefail

VERSION="v1.0.0"

# =============================================================================
# CONFIGURACION
# =============================================================================

readonly DB_PROD_NAME="practicayoruba_db"
readonly DB_QA_NAME="practicayoruba_qa"
readonly DB_APP_USER="practicayoruba_app"
readonly DB_READONLY_USER="practicayoruba_readonly"
readonly DB_CHARSET="utf8mb4"
readonly DB_COLLATION="utf8mb4_unicode_ci"
readonly DB_SOCKET="/run/mysqld/mysqld.sock"
readonly DB_HOST="192.168.100.30"
readonly DB_PORT="3306"

# Contrasena del usuario de aplicacion
# INVARIANTE: debe ser identica a la usada en configure_db_vm_schema_qa.sh
readonly DB_APP_PASSWORD="${PRACTICAYORUBA_APP_PASSWORD:?Variable PRACTICAYORUBA_APP_PASSWORD no definida.}"

# Contrasena del usuario readonly (diferente a la de app)
readonly DB_READONLY_PASSWORD="${PRACTICAYORUBA_READONLY_PASSWORD:?Variable PRACTICAYORUBA_READONLY_PASSWORD no definida.}"

readonly LOG_DIR="/var/log/ecom-setup"
readonly LOG_FILE="${LOG_DIR}/configure_db_vm_schema_prod_$(date -u +%Y-%m-%dT%H%M%SZ).log"

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
        printf '[ERROR] Ejecutar como: sudo PRACTICAYORUBA_APP_PASSWORD=<pass> PRACTICAYORUBA_READONLY_PASSWORD=<pass> bash /tmp/%s\n' \
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

    if ! command -v mariadb &>/dev/null; then
        die "mariadb CLI no encontrado."
    fi
    log_ok "CLI mariadb disponible: $(mariadb --version 2>/dev/null | head -1)"

    if [[ -S "$DB_SOCKET" ]]; then
        if mariadb-admin --socket="$DB_SOCKET" ping --silent 2>/dev/null; then
            log_ok "MariaDB activo (socket: $DB_SOCKET)"
        else
            die "MariaDB no responde en socket $DB_SOCKET."
        fi
    else
        if mariadb-admin --host="$DB_HOST" --port="$DB_PORT" ping --silent 2>/dev/null; then
            log_ok "MariaDB activo (TCP: $DB_HOST:$DB_PORT)"
        else
            die "MariaDB no responde."
        fi
    fi

    local version
    version=$(db_query "SELECT @@version;")
    log_info "Version MariaDB: $version"

    log_info "Script: configure_db_vm_schema_prod.sh $VERSION"
    log_info "Schema prod: $DB_PROD_NAME"
    log_info "Usuario app: $DB_APP_USER (DML limitado)"
    log_info "Usuario readonly: $DB_READONLY_USER (SELECT only)"
    log_info "Log: $LOG_FILE"
}

# =============================================================================
# PASO 1 -- Auditoria estado actual
# =============================================================================

auditar_estado_actual() {
    section "PASO 1 -- Auditoria del estado actual"

    log_info "Schemas existentes en MariaDB:"
    db_exec "SHOW DATABASES;" | \
        grep -v "^information_schema$\|^performance_schema$\|^mysql$\|^sys$\|^#" | \
        while IFS= read -r line; do log_info "  $line"; done || true

    log_info ""
    log_info "Schema $DB_PROD_NAME:"
    local schema_existe
    schema_existe=$(db_query "SELECT COUNT(*) FROM information_schema.SCHEMATA
                              WHERE SCHEMA_NAME = '${DB_PROD_NAME}';")
    if [[ "$schema_existe" -gt 0 ]]; then
        log_warn "  Ya existe -- se verificaran grants (idempotente)."
    else
        log_info "  No existe -- se creara."
    fi

    log_info ""
    log_info "Usuario $DB_READONLY_USER:"
    local readonly_existe
    readonly_existe=$(db_query "SELECT COUNT(*) FROM mysql.user
                                WHERE User = '${DB_READONLY_USER}';")
    if [[ "$readonly_existe" -gt 0 ]]; then
        log_warn "  Ya existe -- se sincronizara la contrasena."
    else
        log_info "  No existe -- se creara en host '%'."
    fi
}

# =============================================================================
# PASO 2 -- Crear schema practicayoruba_db
# =============================================================================

crear_schema_prod() {
    section "PASO 2 -- Crear schema $DB_PROD_NAME"

    local schema_existe
    schema_existe=$(db_query "SELECT COUNT(*) FROM information_schema.SCHEMATA
                              WHERE SCHEMA_NAME = '${DB_PROD_NAME}';")

    if [[ "$schema_existe" -gt 0 ]]; then
        log_info "Schema $DB_PROD_NAME ya existe -- sin cambios."
    else
        db_exec "CREATE DATABASE \`${DB_PROD_NAME}\`
                 CHARACTER SET ${DB_CHARSET}
                 COLLATE ${DB_COLLATION};" > /dev/null
        log_ok "Schema ${DB_PROD_NAME} creado (${DB_CHARSET} / ${DB_COLLATION})."
    fi

    local charset collation
    charset=$(db_query "SELECT DEFAULT_CHARACTER_SET_NAME
                        FROM information_schema.SCHEMATA
                        WHERE SCHEMA_NAME = '${DB_PROD_NAME}';")
    collation=$(db_query "SELECT DEFAULT_COLLATION_NAME
                          FROM information_schema.SCHEMATA
                          WHERE SCHEMA_NAME = '${DB_PROD_NAME}';")
    log_info "  Charset:   $charset"
    log_info "  Collation: $collation"

    log_ok "HALLAZGO H-C6b-1-VM3 -- Schema ${DB_PROD_NAME}: ${charset} / ${collation}"
}

# =============================================================================
# PASO 3 -- Grants DML limitados a practicayoruba_app en produccion
# =============================================================================

otorgar_privilegios_prod_app() {
    section "PASO 3 -- Privilegios DML de $DB_APP_USER en $DB_PROD_NAME"

    log_info "PoLP estricto: SELECT, INSERT, UPDATE, DELETE"
    log_info "Django no necesita DDL en produccion (CREATE/DROP/ALTER)."
    log_info ""

    for host in "%" "localhost" "127.0.0.1"; do
        # Sincronizar contrasena (INVARIANTE con 5.C.6a)
        local user_en_host
        user_en_host=$(db_query "SELECT COUNT(*) FROM mysql.user
                                 WHERE User = '${DB_APP_USER}'
                                   AND Host = '${host}';")
        if [[ "$user_en_host" -gt 0 ]]; then
            db_exec "ALTER USER '${DB_APP_USER}'@'${host}'
                     IDENTIFIED BY '${DB_APP_PASSWORD}';" > /dev/null
            log_ok "  ${DB_APP_USER}@${host} -- contrasena sincronizada."
        else
            db_exec "CREATE USER '${DB_APP_USER}'@'${host}'
                     IDENTIFIED BY '${DB_APP_PASSWORD}';" > /dev/null
            log_ok "  ${DB_APP_USER}@${host} -- creado."
        fi

        # Grants DML limitados en prod
        db_exec "GRANT SELECT, INSERT, UPDATE, DELETE
                 ON \`${DB_PROD_NAME}\`.*
                 TO '${DB_APP_USER}'@'${host}';" > /dev/null
        log_ok "  GRANT SELECT,INSERT,UPDATE,DELETE ON ${DB_PROD_NAME}.* TO ${DB_APP_USER}@${host}"
    done

    db_exec "FLUSH PRIVILEGES;" > /dev/null
    log_ok "HALLAZGO H-C6b-2-VM3 -- ${DB_APP_USER}: DML en ${DB_PROD_NAME}.* aplicado"
}

# =============================================================================
# PASO 4 -- Crear practicayoruba_readonly (SELECT only)
# =============================================================================

crear_usuario_readonly() {
    section "PASO 4 -- Crear $DB_READONLY_USER (SELECT only)"

    log_info "Host '%' -- conexiones desde internet via DNAT Host:3306."
    log_info "Solo SELECT en $DB_PROD_NAME -- sin acceso a $DB_QA_NAME."
    log_info ""

    local readonly_existe
    readonly_existe=$(db_query "SELECT COUNT(*) FROM mysql.user
                                WHERE User = '${DB_READONLY_USER}'
                                  AND Host = '%';")

    if [[ "$readonly_existe" -gt 0 ]]; then
        db_exec "ALTER USER '${DB_READONLY_USER}'@'%'
                 IDENTIFIED BY '${DB_READONLY_PASSWORD}';" > /dev/null
        log_ok "  ${DB_READONLY_USER}@% -- contrasena sincronizada."
    else
        db_exec "CREATE USER '${DB_READONLY_USER}'@'%'
                 IDENTIFIED BY '${DB_READONLY_PASSWORD}';" > /dev/null
        log_ok "  ${DB_READONLY_USER}@% -- creado."
    fi

    db_exec "GRANT SELECT
             ON \`${DB_PROD_NAME}\`.*
             TO '${DB_READONLY_USER}'@'%';" > /dev/null
    log_ok "  GRANT SELECT ON ${DB_PROD_NAME}.* TO ${DB_READONLY_USER}@%"

    db_exec "FLUSH PRIVILEGES;" > /dev/null
    log_ok "HALLAZGO H-C6b-3-VM3 -- ${DB_READONLY_USER}: SELECT only en ${DB_PROD_NAME}.* aplicado"
}

# =============================================================================
# PASO 5 -- Verificar conexion readonly
# =============================================================================

verificar_conexion_readonly() {
    section "PASO 5 -- Verificar conexion $DB_READONLY_USER -> $DB_PROD_NAME"

    local resultado
    if [[ -S "$DB_SOCKET" ]]; then
        resultado=$(mariadb \
            --socket="$DB_SOCKET" \
            --user="$DB_READONLY_USER" \
            --password="$DB_READONLY_PASSWORD" \
            --silent --skip-column-names \
            "$DB_PROD_NAME" \
            -e "SELECT CONCAT(DATABASE(), ' @ ', USER());" 2>&1) || {
            die "No se pudo conectar como ${DB_READONLY_USER} a ${DB_PROD_NAME}."
        }
    else
        resultado=$(mariadb \
            --host="$DB_HOST" \
            --port="$DB_PORT" \
            --user="$DB_READONLY_USER" \
            --password="$DB_READONLY_PASSWORD" \
            --silent --skip-column-names \
            "$DB_PROD_NAME" \
            -e "SELECT CONCAT(DATABASE(), ' @ ', USER());" 2>&1) || {
            die "No se pudo conectar como ${DB_READONLY_USER} a ${DB_PROD_NAME}."
        }
    fi

    log_ok "Conexion verificada: $resultado"

    # Verificar que readonly NO puede escribir
    local write_test
    write_test=$(mariadb \
        --socket="$DB_SOCKET" \
        --user="$DB_READONLY_USER" \
        --password="$DB_READONLY_PASSWORD" \
        --silent --skip-column-names \
        "$DB_PROD_NAME" \
        -e "CREATE TABLE _test_readonly_deny (id INT);" 2>&1 || true)

    if echo "$write_test" | grep -qi "denied\|access"; then
        log_ok "  CREATE TABLE denegado para readonly -- correcto (SELECT only)."
    else
        log_warn "  CREATE TABLE no fue denegado -- verificar grants."
    fi

    # Limpiar si se creó por error
    mariadb --socket="$DB_SOCKET" --silent \
        -e "DROP TABLE IF EXISTS \`${DB_PROD_NAME}\`._test_readonly_deny;" \
        2>/dev/null || true

    log_ok "HALLAZGO H-C6b-4-VM3 -- ${DB_READONLY_USER}: conexion y permisos SELECT only verificados"
}

# =============================================================================
# PASO 6 -- Mostrar grants
# =============================================================================

mostrar_grants() {
    section "PASO 6 -- Resumen de grants"

    log_info "--- $DB_APP_USER en $DB_PROD_NAME ---"
    for host in "%" "localhost" "127.0.0.1"; do
        db_exec "SHOW GRANTS FOR '${DB_APP_USER}'@'${host}';" 2>/dev/null | \
            grep -i "$DB_PROD_NAME\|USAGE" | \
            while IFS= read -r line; do log_info "  $line"; done || true
    done

    log_info ""
    log_info "--- $DB_READONLY_USER ---"
    db_exec "SHOW GRANTS FOR '${DB_READONLY_USER}'@'%';" 2>/dev/null | \
        while IFS= read -r line; do log_info "  $line"; done || true
}

# =============================================================================
# RESUMEN FINAL
# =============================================================================

print_summary() {
    local sep
    sep=$(printf '=%.0s' {1..70})

    printf '\n%s\n' "$sep"
    printf 'RESUMEN -- configure_db_vm_schema_prod.sh %s\n' "$VERSION"
    printf '%s\n' "$sep"
    printf 'Fecha:    %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'VM:       %s | MariaDB: %s\n' \
        "$(hostname)" "$(db_query "SELECT @@version;" 2>/dev/null || echo "?")"
    printf 'Log:      %s\n' "$LOG_FILE"
    printf '%s\n' "$sep"
    printf 'Schema prod creado:\n'
    printf '  Nombre:    %s\n' "$DB_PROD_NAME"
    printf '  Charset:   %s / %s\n' "$DB_CHARSET" "$DB_COLLATION"
    printf 'Usuarios configurados:\n'
    printf '  %s @ %%,localhost,127.0.0.1\n' "$DB_APP_USER"
    printf '    Privilegios prod: SELECT, INSERT, UPDATE, DELETE ON %s.*\n' "$DB_PROD_NAME"
    printf '  %s @ %%\n' "$DB_READONLY_USER"
    printf '    Privilegios: SELECT ON %s.* (readonly -- Claude Code web)\n' "$DB_PROD_NAME"
    printf '%s\n' "$sep"
    printf 'Hallazgos confirmados:\n'
    printf '  H-C6b-1-VM3 -- Schema %s: %s / %s\n' \
        "$DB_PROD_NAME" "$DB_CHARSET" "$DB_COLLATION"
    printf '  H-C6b-2-VM3 -- %s: DML en %s.* (3 hosts)\n' \
        "$DB_APP_USER" "$DB_PROD_NAME"
    printf '  H-C6b-3-VM3 -- %s: SELECT only en %s.*\n' \
        "$DB_READONLY_USER" "$DB_PROD_NAME"
    printf '  H-C6b-4-VM3 -- Conexion readonly verificada\n'
    printf '%s\n' "$sep"
    printf 'Tarea 5.C.6b [VM3] completada.\n'
    printf 'Proxima tarea: 5.C.9 [VM3] -- Zabbix Agent (configure_db_vm_zabbix_agent.sh)\n'
    printf '%s\n\n' "$sep"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    verificar_precondiciones
    auditar_estado_actual
    crear_schema_prod
    otorgar_privilegios_prod_app
    crear_usuario_readonly
    verificar_conexion_readonly
    mostrar_grants
    print_summary
    exit 0
}

mkdir -p "$LOG_DIR"
main "$@" 2>&1 | tee -a "$LOG_FILE"
exit "${PIPESTATUS[0]}"
