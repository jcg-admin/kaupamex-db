#!/bin/bash
# =============================================================================
# inspect-flow.sh — wrapper que ejecuta el SQL de un flujo contra la BD.
#
# Uso:
#   ./inspect-flow.sh guest        — ejecuta flow-guest-checkout.sql
#   ./inspect-flow.sh register     — ejecuta flow-register-activate-checkout.sql
#   ./inspect-flow.sh all          — ambos
#
# Variables consumidas (.env o entorno):
#   DB_NAME   default: kaupamex_db
#   DB_USER   default: django_user
#   DB_HOST   default: 127.0.0.1
#   DB_PORT   default: 3306
#   DB_PASSWORD (sin default — debe venir de .env)
#
# Loud-failure segun DEC-DOC-008: si falta password, si mariadb no
# resuelve, o si la BD no existe, falla con mensaje explicito y
# exit !=0. No silenciamos errores.
# =============================================================================
set -euo pipefail

# Resolver dir del script y del repo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Cargar .env si existe (no es obligatorio si las vars vienen del shell)
if [[ -f "$REPO_ROOT/.env" ]]; then
    # Solo exportar variables que NO esten ya seteadas en el entorno.
    set -a
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env"
    set +a
fi

DB_NAME="${DB_NAME:-kaupamex_db}"
DB_USER="${DB_USER:-django_user}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"

if [[ -z "${DB_PASSWORD:-}" ]]; then
    echo "FATAL: DB_PASSWORD no esta definida en .env ni en el entorno." >&2
    echo "       Copia $REPO_ROOT/.env.example a $REPO_ROOT/.env y" >&2
    echo "       completa DB_PASSWORD." >&2
    exit 2
fi

# Resolver el binario mariadb (post-D-028)
MARIADB_BIN="${MARIADB_BIN:-mariadb}"
if ! command -v "$MARIADB_BIN" >/dev/null 2>&1; then
    if command -v mysql >/dev/null 2>&1; then
        MARIADB_BIN=mysql
        echo "WARN: 'mariadb' no encontrado; usando 'mysql' como fallback." >&2
    else
        echo "FATAL: ni 'mariadb' ni 'mysql' disponibles en PATH." >&2
        exit 3
    fi
fi

_run_sql() {
    local sql_file="$1"
    local label="$2"

    if [[ ! -f "$sql_file" ]]; then
        echo "FATAL: archivo SQL no encontrado: $sql_file" >&2
        exit 4
    fi

    echo ""
    echo "============================================================"
    echo "  $label"
    echo "  archivo: $sql_file"
    echo "  base:    $DB_NAME  host: $DB_HOST:$DB_PORT  user: $DB_USER"
    echo "============================================================"

    "$MARIADB_BIN" \
        --protocol=TCP \
        --host="$DB_HOST" \
        --port="$DB_PORT" \
        --user="$DB_USER" \
        --password="$DB_PASSWORD" \
        --table \
        "$DB_NAME" \
        < "$sql_file"
}

FLOW="${1:-}"
case "$FLOW" in
    guest)
        _run_sql "$SCRIPT_DIR/flow-guest-checkout.sql" \
                 "FLUJO A — Compra como invitado (sin registro)"
        ;;
    register)
        _run_sql "$SCRIPT_DIR/flow-register-activate-checkout.sql" \
                 "FLUJO B — Registro + verificacion email + compra"
        ;;
    all)
        _run_sql "$SCRIPT_DIR/flow-guest-checkout.sql" \
                 "FLUJO A — Compra como invitado (sin registro)"
        _run_sql "$SCRIPT_DIR/flow-register-activate-checkout.sql" \
                 "FLUJO B — Registro + verificacion email + compra"
        ;;
    ""|-h|--help)
        echo "Uso: $0 {guest|register|all}"
        echo ""
        echo "  guest     Inspecciona tablas del flujo de compra anonimo."
        echo "  register  Inspecciona tablas del flujo de registro + activacion."
        echo "  all       Ejecuta ambos en secuencia."
        exit 0
        ;;
    *)
        echo "FATAL: flow desconocido: '$FLOW'. Use guest|register|all." >&2
        exit 1
        ;;
esac
