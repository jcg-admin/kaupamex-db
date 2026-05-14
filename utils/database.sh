#!/bin/bash
# =============================================================================
# utils/database.sh — Funciones de base de datos — PracticaYoruba-db
# =============================================================================
# Adaptado desde PracticaYoruba-api/scripts/utils/database.sh.
#
# Adaptaciones respecto al original (Hallazgo H-F2-003):
#   - Variables privadas renombradas: _MYSQL_* → _MARIADB_*
#   - Funciones privadas renombradas: _mysql_* → _mariadb_*
#   - Funciones públicas renombradas: mysql_* → mariadb_*
#   - Mensajes de log actualizados: "MySQL" → "MariaDB"
#   El renombrado es completo (público + privado + constantes) para
#   mantener consistencia interna y evitar confusión entre nombres.
#   Los binarios CLI (mysqladmin, mysqldump, mysql) mantienen sus
#   nombres — son herramientas del sistema operativo, no del repo.
#
# Depende de: logging.sh, network.sh
#
# Funciones públicas:
#   mariadb_is_running      — detecta si el servidor responde (socket o TCP)
#   mariadb_cleanup_stale   — limpia archivos pid/sock de sesiones anteriores
#   mariadb_start           — arranca MariaDB (systemd o directo)
#   mariadb_wait_ready      — espera activa hasta que el servidor responda
# =============================================================================

# Rutas de socket conocidas de MariaDB/MySQL en Ubuntu 24.04
_MARIADB_SOCKETS=(
    "/run/mysqld/mysqld.sock"
    "/var/run/mysqld/mysqld.sock"
    "/tmp/mysql.sock"
)

# Archivo PID primario de MariaDB en Ubuntu 24.04
_MARIADB_PID_FILE="/run/mysqld/mysqld.pid"

# -----------------------------------------------------------------------------
# mariadb_is_running [host] [port]
#   Retorna 0 si el servidor responde, 1 si no.
#   Orden de verificación:
#     1. Socket Unix (rápido, funciona en contenedores sin red configurada)
#     2. TCP (host:port)
#     3. Fallback: solo conectividad TCP sin autenticación (nc o /dev/tcp)
# -----------------------------------------------------------------------------
mariadb_is_running() {
    local host="${1:-127.0.0.1}" port="${2:-3306}"

    # 1. Socket Unix — más rápido, disponible antes que el puerto TCP
    if command -v mysqladmin &>/dev/null; then
        for sock in "${_MARIADB_SOCKETS[@]}"; do
            if [[ -S "$sock" ]]; then
                if mysqladmin --socket="$sock" ping --silent >/dev/null 2>&1; then
                    return 0
                fi
            fi
        done
    fi

    # 2. TCP con autenticación
    if command -v mysqladmin &>/dev/null; then
        if mysqladmin ping --silent --host="$host" --port="$port" >/dev/null 2>&1; then
            return 0
        fi
    fi

    # 3. Fallback: solo verificar conectividad TCP (sin credenciales)
    tcp_is_reachable "$host" "$port" 3
}

# -----------------------------------------------------------------------------
# mariadb_cleanup_stale
#   Detecta y elimina archivos .pid y .sock que apuntan a procesos muertos.
#   Ocurre cuando el sistema se reinicia sin apagar MariaDB limpiamente.
#   Solo elimina archivos cuyo PID ya no existe en /proc — nunca mata
#   procesos vivos.
# -----------------------------------------------------------------------------
mariadb_cleanup_stale() {
    local cleaned=0

    # Limpiar PID files de procesos muertos
    for pid_file in /run/mysqld/*.pid; do
        [[ -f "$pid_file" ]] || continue
        local pid
        pid=$(cat "$pid_file" 2>/dev/null) || continue
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
            log_warn "PID stale detectado: ${pid_file} (PID ${pid} ya no existe)"
            rm -f "$pid_file"
            cleaned=$(( cleaned + 1 ))
        fi
    done

    # Limpiar socket files sin proceso activo
    for sock in "${_MARIADB_SOCKETS[@]}"; do
        [[ -S "$sock" ]] || continue
        if ! mysqladmin --socket="$sock" ping --silent >/dev/null 2>&1; then
            log_warn "Socket stale detectado: ${sock}"
            rm -f "$sock"
            cleaned=$(( cleaned + 1 ))
        fi
    done

    (( cleaned > 0 )) && log_info "Limpiados ${cleaned} archivos stale" || true
}

# -----------------------------------------------------------------------------
# _mariadb_start_systemd
#   Intenta arrancar MariaDB via service/systemctl.
#   Retorna 0 si tuvo éxito, 1 si el gestor no está disponible o falló.
#   Función privada — usar mariadb_start como punto de entrada.
# -----------------------------------------------------------------------------
_mariadb_start_systemd() {
    command -v service &>/dev/null || return 1

    service mariadb start 2>/dev/null && return 0
    service mysql    start 2>/dev/null && return 0

    return 1
}

# -----------------------------------------------------------------------------
# _mariadb_start_direct
#   Arranca mariadbd/mysqld directamente con nohup.
#   Usado como fallback en contenedores sin systemd.
#   Busca el binario en rutas conocidas de Ubuntu 24.04.
#   Función privada — usar mariadb_start como punto de entrada.
# -----------------------------------------------------------------------------
_mariadb_start_direct() {
    local daemon=""
    for bin in /usr/sbin/mariadbd /usr/sbin/mysqld /usr/bin/mariadbd; do
        [[ -x "$bin" ]] && daemon="$bin" && break
    done

    if [[ -z "$daemon" ]]; then
        log_error "No se encontro el daemon de MariaDB en rutas conocidas"
        return 1
    fi

    log_info "Arrancando ${daemon} directamente (sin systemd)..."

    nohup su -s /bin/bash mysql -c \
        "${daemon} \
         --datadir=/var/lib/mysql \
         --socket=/run/mysqld/mysqld.sock \
         --pid-file=${_MARIADB_PID_FILE} \
         --log-error=/var/lib/mysql/mysqld_err.log \
         --bind-address=127.0.0.1 \
         --port=3306" \
        > /tmp/mariadbd_startup.log 2>&1 &

    return 0
}

# -----------------------------------------------------------------------------
# mariadb_wait_ready [timeout_secs]
#   Espera activamente hasta que mariadb_is_running retorne 0.
#   Retorna 0 si el servidor respondió antes del timeout, 1 si no.
#   Incremento de elapsed con forma segura para set -euo pipefail:
#     elapsed=$(( elapsed + interval )) en lugar de (( elapsed++ ))
#     que evaluaría a 0 en la primera iteración y terminaría el script.
# -----------------------------------------------------------------------------
mariadb_wait_ready() {
    local timeout="${1:-30}" elapsed=0 interval=2

    log_info "Esperando a que MariaDB este listo (timeout: ${timeout}s)..."

    while (( elapsed < timeout )); do
        if mariadb_is_running; then
            log_success "MariaDB listo (${elapsed}s)"
            return 0
        fi
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
        log_info "  ... ${elapsed}s / ${timeout}s"
    done

    log_error "MariaDB no respondio en ${timeout}s"
    log_error "Revisa el log: /var/lib/mysql/mysqld_err.log"
    return 1
}

# -----------------------------------------------------------------------------
# mariadb_start
#   Punto de entrada principal para arrancar MariaDB.
#   Flujo:
#     1. Si ya responde → retornar 0 inmediatamente
#     2. Limpiar estado stale de sesiones anteriores
#     3. Intentar arranque via systemd/service
#     4. Si falla, intentar arranque directo (contenedores sin systemd)
#     5. Esperar activamente hasta que responda (30s máximo)
# -----------------------------------------------------------------------------
mariadb_start() {
    # 1. Ya está corriendo
    if mariadb_is_running; then
        log_success "MariaDB ya esta activo"
        return 0
    fi

    log_info "MariaDB no responde. Iniciando procedimiento de arranque..."

    # 2. Limpiar estado stale
    mariadb_cleanup_stale

    # 3. Intentar via systemd/service
    if _mariadb_start_systemd; then
        log_info "Arranque via service solicitado"
    else
        log_info "service no disponible — intentando arranque directo"
        _mariadb_start_direct || {
            log_error "No se pudo iniciar MariaDB"
            return 1
        }
    fi

    # 4. Esperar a que responda (30s máximo)
    mariadb_wait_ready 30
}
