#!/bin/bash
# =============================================================================
# scripts/verify_env_sync.sh
# Verifica que las claves DB_* esten sincronizadas entre el .env de db/
# y el .env de api/practicayoruba/.
# =============================================================================
# Origen: T-B1 de iniciativa resolver-problemas-db-pendientes
# (cierra ENV-01, H-03; DEC-DB-3).
#
# Comportamiento:
#
#   * Por default compara db/.env.example vs api/practicayoruba/.env.example
#     (las plantillas son el contrato — el .env real es secreto y puede no
#     existir en el repo padre cuando se corre este script en CI).
#   * Si ambos .env reales existen (db/.env y api/practicayoruba/.env) y se
#     pasa --check-values, ademas compara los valores de las claves DB_*.
#     Diferencia silenciosa entre los dos .env = bug clase
#     "errores silenciosos en tiempo de ejecucion" descrito en
#     db/docs/integracion-api.md.
#
# Uso:
#
#   bash db/scripts/verify_env_sync.sh                     # compara plantillas
#   bash db/scripts/verify_env_sync.sh --check-values      # tambien valores
#   bash db/scripts/verify_env_sync.sh --db-root <path> --api-root <path>
#
# Exit codes:
#
#   0 = OK (claves identicas; valores identicos si --check-values y ambos
#       .env existen).
#   1 = DRIFT detectado (claves distintas, o valores distintos en
#       --check-values).
#   2 = Error de invocacion (archivos no encontrados, paths invalidos).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_ROOT_DEFAULT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CHECK_VALUES=0
DB_ROOT="${DB_ROOT_DEFAULT}"
API_ROOT=""

usage() {
    sed -n '2,33p' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-values) CHECK_VALUES=1; shift ;;
        --db-root)      DB_ROOT="$2"; shift 2 ;;
        --api-root)     API_ROOT="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)
            echo "ERROR: argumento desconocido: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Resolucion de API_ROOT
# -----------------------------------------------------------------------------
# Estrategia: si el operador no la pasa, probar layouts conocidos:
#   1. Monorepo (jcg-admin/e-commerce): <parent>/api/
#   2. Sibling clone:                  <parent>/PracticaYoruba-api/
#   3. Sibling clone variante:         <parent>/e-commerce-api/
# Si ninguno existe, error 2 con sugerencia.
# -----------------------------------------------------------------------------
if [[ -z "$API_ROOT" ]]; then
    PARENT="$(cd "${DB_ROOT}/.." && pwd)"
    for cand in "${PARENT}/api" "${PARENT}/PracticaYoruba-api" "${PARENT}/e-commerce-api"; do
        if [[ -f "${cand}/practicayoruba/.env.example" ]]; then
            API_ROOT="$cand"
            break
        fi
    done
fi

if [[ -z "$API_ROOT" ]]; then
    echo "ERROR: no se encontro el repo api/." >&2
    echo "       Probe --api-root <path> apuntando al clon de PracticaYoruba-api." >&2
    exit 2
fi

DB_ENV_EXAMPLE="${DB_ROOT}/.env.example"
API_ENV_EXAMPLE="${API_ROOT}/practicayoruba/.env.example"

[[ -f "$DB_ENV_EXAMPLE" ]]  || { echo "ERROR: no existe $DB_ENV_EXAMPLE"  >&2; exit 2; }
[[ -f "$API_ENV_EXAMPLE" ]] || { echo "ERROR: no existe $API_ENV_EXAMPLE" >&2; exit 2; }

# -----------------------------------------------------------------------------
# Extraccion de claves DB_* (ignora comentarios y lineas en blanco)
# -----------------------------------------------------------------------------
extract_db_keys() {
    local file="$1"
    grep -E '^DB_[A-Z_]+=' "$file" | sed -E 's/=.*$//' | sort -u
}

extract_db_pairs() {
    local file="$1"
    grep -E '^DB_[A-Z_]+=' "$file" | sort -u
}

DB_KEYS="$(extract_db_keys "$DB_ENV_EXAMPLE")"
API_KEYS="$(extract_db_keys "$API_ENV_EXAMPLE")"

# -----------------------------------------------------------------------------
# 1) Diff de claves entre las plantillas
# -----------------------------------------------------------------------------
KEY_DIFF="$(diff <(echo "$DB_KEYS") <(echo "$API_KEYS") || true)"

EXIT_CODE=0

if [[ -n "$KEY_DIFF" ]]; then
    echo "DRIFT: las claves DB_* difieren entre las plantillas."
    echo "  db/.env.example                  : ${DB_ENV_EXAMPLE}"
    echo "  api/practicayoruba/.env.example  : ${API_ENV_EXAMPLE}"
    echo ""
    echo "Diff (< db, > api):"
    diff <(echo "$DB_KEYS") <(echo "$API_KEYS") | sed 's/^/  /' || true
    echo ""
    EXIT_CODE=1
else
    echo "OK: claves DB_* identicas en ambas plantillas ($(echo "$DB_KEYS" | wc -l | tr -d ' ') claves)."
fi

# -----------------------------------------------------------------------------
# 2) Valores (opcional). Solo aplica a las claves comunes presentes en AMBAS
#    plantillas — un drift de claves ya quedo reportado arriba.
# -----------------------------------------------------------------------------
if [[ "$CHECK_VALUES" -eq 1 ]]; then
    DB_ENV_REAL="${DB_ROOT}/.env"
    API_ENV_REAL="${API_ROOT}/practicayoruba/.env"

    if [[ ! -f "$DB_ENV_REAL" ]] || [[ ! -f "$API_ENV_REAL" ]]; then
        echo ""
        echo "WARN: --check-values pedido pero alguno de los .env reales no existe:"
        echo "  ${DB_ENV_REAL}  $([[ -f "$DB_ENV_REAL" ]] && echo OK || echo MISSING)"
        echo "  ${API_ENV_REAL} $([[ -f "$API_ENV_REAL" ]] && echo OK || echo MISSING)"
        echo "Skip de comparacion de valores. Exit code preservado."
    else
        DB_PAIRS="$(extract_db_pairs "$DB_ENV_REAL")"
        API_PAIRS="$(extract_db_pairs "$API_ENV_REAL")"
        VAL_DIFF="$(diff <(echo "$DB_PAIRS") <(echo "$API_PAIRS") || true)"

        if [[ -n "$VAL_DIFF" ]]; then
            echo ""
            echo "DRIFT: los valores DB_* difieren entre los .env reales."
            echo "  ${DB_ENV_REAL}"
            echo "  ${API_ENV_REAL}"
            echo ""
            echo "Diff (< db, > api):"
            diff <(echo "$DB_PAIRS") <(echo "$API_PAIRS") | sed 's/^/  /' || true
            EXIT_CODE=1
        else
            echo "OK: valores DB_* identicos en ambos .env reales."
        fi
    fi
fi

exit "$EXIT_CODE"
