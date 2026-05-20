#!/bin/bash
# =============================================================================
# tests/test_start_db_idempotency.sh
# Idempotencia + estructural sobre scripts/start_db.sh.
# =============================================================================
# Origen: T-D2 de iniciativa resolver-problemas-db-pendientes
# (cierra TS-03, S-02).
#
# El test valida que start_db.sh es idempotente: invocarlo cuando
# MariaDB ya esta arriba no relanza el daemon, no re-aplica grants,
# no llama provisioners y termina con exit 0 en menos de 1s.
#
# Invariantes estructurales (siempre):
#
#   I-1: bash -n start_db.sh debe pasar sin errores de sintaxis.
#   I-2: La rama idempotente existe — el script comprueba
#        mariadb_is_running y, si retorna true, sale antes de
#        cualquier nohup / su mysql. Sin esta rama, el segundo run
#        causaria "Address already in use" o doble daemon (S-02).
#   I-3: start_db.sh NO invoca db_setup.sh ni db_qa_setup.sh ni
#        deploy_objetos.sh ni grants — un "start" idempotente no
#        re-provisiona. Si en el futuro alguien agrega esa llamada,
#        este test la atrapa.
#
# Modo runtime (opcional, si MariaDB ya esta arriba):
#
#   R-1: Primera invocacion = exit 0.
#   R-2: Segunda invocacion = exit 0 + output contiene "ya esta
#        activo" / "nada que hacer" / equivalente.
#   R-3: Segunda invocacion tarda <5s (vs ~3-20s para arranque real).
#
# Uso:
#   bash tests/test_start_db_idempotency.sh
#
# Idempotente — el test no levanta ni apaga MariaDB. Si MariaDB no
# esta arriba al iniciar, se omite el modo runtime (no se intenta
# arrancarla porque eso requiere root via `su mysql`).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
START_DB="${PROJECT_ROOT}/scripts/start_db.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; }

[[ -f "$START_DB" ]] || fail "no existe ${START_DB}"

# -----------------------------------------------------------------------------
# I-1: sintaxis
# -----------------------------------------------------------------------------
if ! bash -n "$START_DB" 2>/tmp/test_start_db_syntax.err; then
    cat /tmp/test_start_db_syntax.err >&2
    fail "start_db.sh tiene errores de sintaxis"
fi
pass "I-1 sintaxis OK"

# -----------------------------------------------------------------------------
# I-2: rama idempotente con mariadb_is_running -> exit 0
# -----------------------------------------------------------------------------
# El patron canonico (lineas 49-60 al momento de escribir):
#
#   if mariadb_is_running; then
#       log_success "MariaDB ya esta activo ..."
#       ...
#       exit 0
#   fi
#
# No buscamos la linea literal, buscamos:
#   1. uso de mariadb_is_running en un if.
#   2. un exit 0 (o return 0) en la rama positiva ANTES del nohup/su.
nohup_line=$(grep -nE '^[[:space:]]*nohup[[:space:]]' "$START_DB" | head -1 | cut -d: -f1 || true)
is_running_line=$(grep -n "if mariadb_is_running" "$START_DB" | head -1 | cut -d: -f1 || true)

if [[ -z "$is_running_line" ]]; then
    fail "I-2: start_db.sh no usa 'if mariadb_is_running' — la rama idempotente puede faltar"
fi
if [[ -z "$nohup_line" ]]; then
    fail "I-2: start_db.sh no tiene 'nohup' — no esta arrancando el daemon como se espera"
fi
if (( is_running_line >= nohup_line )); then
    fail "I-2: la rama idempotente (linea ${is_running_line}) esta DESPUES del nohup (linea ${nohup_line}) — el script arrancaria daemon aunque MariaDB ya este activo"
fi
# Y debe haber exit 0 entre is_running_line y nohup_line
exit_in_branch=$(sed -n "${is_running_line},$((nohup_line - 1))p" "$START_DB" | grep -cE 'exit[[:space:]]+0' || true)
if [[ "$exit_in_branch" -lt 1 ]]; then
    fail "I-2: no encuentro 'exit 0' dentro de la rama idempotente (entre lineas ${is_running_line} y ${nohup_line})"
fi
pass "I-2 rama idempotente correcta (if mariadb_is_running -> exit 0 antes de nohup)"

# -----------------------------------------------------------------------------
# I-3: start_db.sh NO invoca provisioners ni grants
# -----------------------------------------------------------------------------
forbidden_patterns=(
    'db_setup\.sh'
    'db_qa_setup\.sh'
    'deploy_objetos\.sh'
    'GRANT'
    'CREATE USER'
)
for pat in "${forbidden_patterns[@]}"; do
    if grep -qE "$pat" "$START_DB"; then
        fail "I-3: start_db.sh contiene '${pat}' — un 'start' no debe re-provisionar"
    fi
done
pass "I-3 start_db.sh no invoca provisioners ni grants"

# -----------------------------------------------------------------------------
# Modo runtime — solo si MariaDB ya esta arriba
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
    skip "MariaDB no responde — modo runtime omitido (no arrancamos desde el test; requiere root)"
    echo ""
    echo "OK: test_start_db_idempotency.sh (3/3 invariantes estructurales)"
    exit 0
fi

if [[ ! -f "${PROJECT_ROOT}/.env" ]]; then
    skip "no existe ${PROJECT_ROOT}/.env — modo runtime omitido"
    echo ""
    echo "OK: test_start_db_idempotency.sh (3/3 invariantes estructurales)"
    exit 0
fi

stdout1="$(mktemp)"; stdout2="$(mktemp)"
trap 'rm -f "$stdout1" "$stdout2" /tmp/test_start_db_syntax.err' EXIT

# R-1: primera invocacion (MariaDB ya arriba) -> exit 0
set +e
bash "$START_DB" --no-verify >"$stdout1" 2>&1
exit1=$?
set -e
[[ "$exit1" -eq 0 ]] || { cat "$stdout1" >&2; fail "R-1: primera invocacion exit ${exit1} (esperado 0)"; }
pass "R-1 primera invocacion exit 0"

# R-2 + R-3: segunda invocacion, tiempo de pared <5s, mensaje idempotente
t0=$(date +%s)
set +e
bash "$START_DB" --no-verify >"$stdout2" 2>&1
exit2=$?
set -e
t1=$(date +%s)
elapsed=$(( t1 - t0 ))

[[ "$exit2" -eq 0 ]] || { cat "$stdout2" >&2; fail "R-2: segunda invocacion exit ${exit2}"; }
if ! grep -qiE "ya esta activo|nada que hacer|already running" "$stdout2"; then
    cat "$stdout2" >&2
    fail "R-2: segunda invocacion no reporta idempotencia (esperaba 'ya esta activo' o similar)"
fi
pass "R-2 segunda invocacion idempotente (exit 0 + mensaje)"

if [[ "$elapsed" -gt 5 ]]; then
    fail "R-3: segunda invocacion tardo ${elapsed}s (esperado <5s — sugiere que esta arrancando daemon)"
fi
pass "R-3 segunda invocacion en ${elapsed}s (<5s)"

echo ""
echo "OK: test_start_db_idempotency.sh (3 estructurales + 3 runtime)"
