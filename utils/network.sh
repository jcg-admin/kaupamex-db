#!/bin/bash
# =============================================================================
# utils/network.sh — Funciones de red — PracticaYoruba-db
# =============================================================================
# Portado desde PracticaYoruba-api/scripts/utils/network.sh sin cambios
# funcionales — no contiene referencias al dominio de la API.
#
# Depende de: logging.sh
#
# Provee:
#   tcp_is_reachable <host> <port> [timeout_secs]
#   wait_for_port    <host> <port> [attempts] [sleep_secs]
# =============================================================================

# -----------------------------------------------------------------------------
# tcp_is_reachable <host> <port> [timeout_secs]
#   Retorna 0 si el puerto TCP acepta conexiones, 1 si no.
#   Usa nc(1) si está disponible; si no, usa el built-in /dev/tcp de bash.
# -----------------------------------------------------------------------------
tcp_is_reachable() {
    local host="$1" port="$2" timeout="${3:-5}"

    if command -v nc &>/dev/null; then
        nc -z -w "$timeout" "$host" "$port" &>/dev/null
        return $?
    fi

    # Fallback: bash built-in /dev/tcp
    ( exec 3<>/dev/tcp/"$host"/"$port" ) &>/dev/null
    return $?
}

# -----------------------------------------------------------------------------
# wait_for_port <host> <port> [attempts] [sleep_secs]
#   Reintenta la conexión TCP hasta <attempts> veces con <sleep_secs> entre
#   intentos. Retorna 0 en cuanto conecta, 1 si se agota el número de intentos.
# -----------------------------------------------------------------------------
wait_for_port() {
    local host="$1" port="$2" attempts="${3:-10}" sleep_secs="${4:-2}"
    local i=0
    while (( i < attempts )); do
        tcp_is_reachable "$host" "$port" 2 && return 0
        i=$(( i + 1 ))
        log_info "Esperando ${host}:${port} ... intento ${i}/${attempts}"
        sleep "$sleep_secs"
    done
    log_error "Puerto ${host}:${port} no disponible despues de ${attempts} intentos"
    return 1
}
