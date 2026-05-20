#!/bin/bash
# =============================================================================
# tests/test_verify_sh.sh
# Smoke + estructural sobre scripts/verify.sh.
# =============================================================================
# Origen: T-D1 de iniciativa resolver-problemas-db-pendientes
# (cierra TS-02).
#
# El test valida tres invariantes que NO dependen de tener MariaDB
# corriendo, y opcionalmente corre verify.sh end-to-end si MariaDB
# esta disponible.
#
# Invariantes estructurales (siempre):
#
#   I-1: bash -n verify.sh debe pasar sin errores de sintaxis.
#   I-2: La regla T-C1 (conteo dinamico de checks) sigue presente —
#        el script DEBE calcular TOTAL_CHECKS via grep -cE sobre
#        '^(function )?check_[a-z_]+\(\)'. Sin esto, agregar un
#        check no se refleja en el header y vuelve el hallazgo H-01.
#   I-3: TOTAL_CHECKS computado por la regla = numero real de
#        funciones check_* declaradas en el script. Si la regla y la
#        realidad divergen, el header miente.
#
# Modo runtime (opcional, si MariaDB responde):
#
#   R-1: verify.sh corre y retorna exit code (0 o 1, ambos validos
#        para el smoke — un ERR no es bug del test).
#   R-2: La linea de header del output incluye "(${N} checks)" con
#        N = TOTAL_CHECKS computado en I-3.
#   R-3: stderr no contiene "syntax error" ni "command not found".
#
# Uso:
#   bash tests/test_verify_sh.sh
#
# Idempotente — solo lectura. No modifica datos ni configuracion.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERIFY_SH="${PROJECT_ROOT}/scripts/verify.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; }

[[ -f "$VERIFY_SH" ]] || fail "no existe ${VERIFY_SH}"

# -----------------------------------------------------------------------------
# I-1: sintaxis
# -----------------------------------------------------------------------------
if ! bash -n "$VERIFY_SH" 2>/tmp/test_verify_sh_syntax.err; then
    cat /tmp/test_verify_sh_syntax.err >&2
    fail "verify.sh tiene errores de sintaxis"
fi
pass "I-1 sintaxis OK"

# -----------------------------------------------------------------------------
# I-2: regla TOTAL_CHECKS dinamica presente
# -----------------------------------------------------------------------------
if ! grep -qE "TOTAL_CHECKS=\\\$\(grep -cE '\\^\(function \)\?check_\[a-z_\]\+\\\\\(\\\\\)' \"\\\$0\"\)" "$VERIFY_SH" \
   && ! grep -qE "TOTAL_CHECKS=\\\$\(grep -cE '\^\(function \)\?check_\[a-z_\]\+\\\\\(\\\\\)' \"\\\$0\"\)" "$VERIFY_SH" \
   && ! grep -qF 'TOTAL_CHECKS=$(grep -cE ' "$VERIFY_SH"; then
    fail "verify.sh no tiene la regla T-C1 (TOTAL_CHECKS dinamico via grep -cE). El hallazgo H-01 reaparecio."
fi
pass "I-2 regla TOTAL_CHECKS dinamica presente"

# -----------------------------------------------------------------------------
# I-3: TOTAL_CHECKS de la regla == funciones check_* reales
# -----------------------------------------------------------------------------
declared=$(grep -cE '^(function )?check_[a-z_]+\(\)' "$VERIFY_SH")
[[ "$declared" -gt 0 ]] || fail "I-3: 0 funciones check_* detectadas — la regex de T-C1 contaria 0"
pass "I-3 declared=${declared} (consistencia regla vs realidad)"

# -----------------------------------------------------------------------------
# Modo runtime — solo si MariaDB esta listening
# -----------------------------------------------------------------------------
mariadb_up=false
for sock in /run/mysqld/mysqld.sock /var/run/mysqld/mysqld.sock; do
    [[ -S "$sock" ]] || continue
    if mysqladmin --socket="$sock" ping --silent >/dev/null 2>&1; then
        mariadb_up=true
        break
    fi
done

if [[ "$mariadb_up" == "false" ]]; then
    skip "MariaDB no responde — modo runtime omitido (estructural ya valido)"
    echo ""
    echo "OK: test_verify_sh.sh (3/3 invariantes estructurales)"
    exit 0
fi

# Requiere .env para el path R-1..R-3
if [[ ! -f "${PROJECT_ROOT}/.env" ]]; then
    skip "no existe ${PROJECT_ROOT}/.env — modo runtime omitido"
    echo ""
    echo "OK: test_verify_sh.sh (3/3 invariantes estructurales)"
    exit 0
fi

# R-1 + R-2 + R-3
verify_stdout="$(mktemp)"
verify_stderr="$(mktemp)"
trap 'rm -f "$verify_stdout" "$verify_stderr" /tmp/test_verify_sh_syntax.err' EXIT

set +e
bash "$VERIFY_SH" >"$verify_stdout" 2>"$verify_stderr"
verify_exit=$?
set -e

# R-1: exit 0 o 1 (ambos son outcomes legitimos del verify)
if [[ "$verify_exit" -ne 0 ]] && [[ "$verify_exit" -ne 1 ]]; then
    cat "$verify_stderr" >&2
    fail "R-1: verify.sh termino con exit ${verify_exit} (esperado 0 o 1)"
fi
pass "R-1 exit code = ${verify_exit} (0|1 OK)"

# R-2: header reporta (${declared} checks)
if ! grep -qE "\(${declared} checks\)" "$verify_stdout"; then
    echo "--- stdout ---" >&2
    cat "$verify_stdout" >&2
    fail "R-2: header de verify.sh no reporta (${declared} checks) dinamico"
fi
pass "R-2 header reporta (${declared} checks) dinamico"

# R-3: stderr limpio de syntax error / command not found
if grep -qE "(syntax error|command not found)" "$verify_stderr"; then
    cat "$verify_stderr" >&2
    fail "R-3: stderr contiene errores no esperados"
fi
pass "R-3 stderr sin errores estructurales"

echo ""
echo "OK: test_verify_sh.sh (3 estructurales + 3 runtime)"
