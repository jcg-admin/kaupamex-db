#!/usr/bin/env bash
#
# sync-and-test.sh — Sincroniza los 5 repos de PracticaYoruba a develop
# (fast-forward only) y, opcionalmente, reinstala dependencias.
# Pensado para el entorno WSL2 `Ubuntu-ecomerce-p001`.
#
# Correr SIEMPRE como el usuario `develop` (dueno de Clase A /opt/practicayoruba).
# NO usar `safe.directory` para `deploy`: rompe el aislamiento de Clase A.
#
# Uso:
#   bash scripts/sync-and-test.sh                 # solo sincroniza (ff-only)
#   bash scripts/sync-and-test.sh --with-deps     # + reinstala deps si aplica
#   bash scripts/sync-and-test.sh --test-steps    # imprime el procedimiento
#                                                 #   de pruebas (no lo corre)
#
# Variables:
#   ECOM_REPO_ROOT   raiz de los repos (default: /opt/practicayoruba)
#
# Barandas de seguridad:
#   - Aborta si no se corre como `develop`.
#   - Nunca pisa un repo con commits locales sin pushear (ahead > 0): lo salta.
#   - Pull estrictamente ff-only: si hay divergencia, se detiene en ese repo.
#
# Por que este script NO corre las pruebas (decision, no omision):
#   - El arranque de BD (`start_db.sh`) usa `su mysql` y la siembra de QA
#     (`db_qa_setup.sh`) exige root/`sudo` — son paso del perfil `deploy`,
#     NO de `develop`. Bundlearlos en un script develop-only fallaria.
#   - `pytest` debe correr desde la RAIZ del repo api (ahi vive `pytest.ini`
#     con `pythonpath=practicayoruba` + `testpaths=tests`). Desde
#     `practicayoruba/` colecta 0 items (verde falso).
#   Por eso las pruebas se documentan como procedimiento de dos perfiles
#   con captura de exit. Ver `--test-steps`.
#
# Lo que este script NO hace (a proposito):
#   - No toca el `.env` local (p. ej. el valor sin comillas que rompe
#     python-dotenv): es config de la maquina, no del repo. Arreglar a mano.

set -uo pipefail

# --- Re-exec desde copia estable -------------------------------------------
# Este script vive en e-comerce-db, que el propio script pull-ea. Si el pull
# actualiza este archivo a mitad de ejecucion, bash podria leer lineas
# inconsistentes. Nos copiamos a /tmp y re-ejecutamos desde ahi una sola vez.
if [ "${_SAT_STABLE:-}" != "1" ]; then
    _tmp=/tmp/_ecom-sync-and-test.sh
    cp -- "$0" "$_tmp"
    export _SAT_STABLE=1
    exec bash "$_tmp" "$@"
fi

REPO_ROOT="${ECOM_REPO_ROOT:-/opt/practicayoruba}"
REPOS=(e-comerce-api e-comerce-db e-comerce-docs e-comerce-server e-comerce-ui)

print_test_steps() {
    cat <<EOF
== Procedimiento de pruebas — DOS PERFILES (no bundleable en develop-only) ==

El arranque y siembra de la BD requieren root: son paso de 'deploy', no de
'develop'. Las suites corren como 'develop'. Captura el exit para gatear.

IMPORTANTE: antes de sembrar, arregla el valor sin comillas del .env
(linea ~53). Ambos seeders leen ese .env y abortan hasta que se entrecomille.

[deploy]  (tiene sudo; arranca mariadbd y siembra la BD de QA)
  sudo bash $REPO_ROOT/e-comerce-db/scripts/start_db.sh
  # Sembrar QA con el MISMO seeder que la auto-recuperacion de pytest
  # re-ejecuta (e-comerce-api/tests/conftest.py::_restart_mariadb, linea 21).
  # NO usar el de e-comerce-db: divergiria del que pytest usa y exige
  # DB_QA_PASSWORD sin default (aborta si el .env esta roto).
  sudo bash $REPO_ROOT/e-comerce-api/scripts/provisioners/mysql/db_qa_setup.sh

[develop] (corre las suites DESDE LA RAIZ del repo api; uv run, no pip/python pelados)
  # 'uv run' fija el interprete del .venv del API: evita PEP 668
  # (externally-managed) y el desajuste de interprete del enigma 1479.
  # D-031/H-14: el equipo usa uv en todos los submodulos.
  cd $REPO_ROOT/e-comerce-api      && uv run pytest --tb=no -q ; rc_api=\$?
  cd $REPO_ROOT/e-comerce-ui       && npx jest                 ; rc_ui=\$?
  echo "API rc=\$rc_api  UI rc=\$rc_ui"
  if [ "\$rc_api" -eq 0 ] && [ "\$rc_ui" -eq 0 ]; then echo VERDE; else echo ROJO; fi

Baselines esperados: API 1432/0/0 · UI 780/0/0.
Nota: 'pytest' NO debe correrse desde practicayoruba/ (colecta 0 items).
EOF
}

WITH_DEPS=0
for a in "$@"; do
    case "$a" in
        --with-deps)  WITH_DEPS=1 ;;
        --test-steps) print_test_steps; exit 0 ;;
        --with-tests)
            echo "AVISO: --with-tests no esta soportado en este script develop-only"
            echo "       (arranque/siembra de BD requiere root). Procedimiento:"
            echo ""
            print_test_steps
            exit 2 ;;
        -h|--help)
            sed -n '2,34p' "$0"; exit 0 ;;
        *) echo "arg desconocido: $a (usa -h)"; exit 2 ;;
    esac
done

# --- Guard: debe correr como develop ---------------------------------------
if [ "$(whoami)" != "develop" ]; then
    echo "ERROR: corre como 'develop' (dueno de Clase A). Actual: $(whoami)"
    echo "       wsl -d Ubuntu-ecomerce-p001 -u develop"
    exit 1
fi

# --- 1. Diagnostico + sync ff-only por repo --------------------------------
echo "== Sincronizacion (ff-only) — raiz: $REPO_ROOT =="
fail=0
for r in "${REPOS[@]}"; do
    d="$REPO_ROOT/$r"
    cd "$d" 2>/dev/null || { echo "[$r] FALTA el directorio $d"; fail=1; continue; }

    git fetch origin -q || { echo "[$r] fetch FALLO"; fail=1; continue; }

    # left-right: "<ahead> <behind>" respecto a origin/develop
    read ahead behind < <(git rev-list --left-right --count HEAD...origin/develop 2>/dev/null)
    ahead=${ahead:-0}; behind=${behind:-0}

    if [ "$ahead" -gt 0 ]; then
        echo "[$r] AHEAD=$ahead — tienes commits locales sin pushear: SE SALTA (no piso tu trabajo)"
        fail=1
        continue
    fi

    old=$(git rev-parse --short HEAD)
    if [ "$behind" -eq 0 ]; then
        echo "[$r] ya en develop ($old)"
        continue
    fi

    git checkout develop -q 2>/dev/null
    if git pull --ff-only origin develop -q; then
        echo "[$r] $old -> $(git rev-parse --short HEAD)  (estaba $behind commits detras)"
    else
        echo "[$r] FF-ONLY FALLO — divergencia: revisar a mano antes de continuar"
        fail=1
    fi
done

# --- 2. Dependencias (opcional, develop-only: uv + npm ci) -----------------
# D-031/H-14: el equipo usa uv en todos los submodulos. NUNCA pip pelado:
# dispara PEP 668 (externally-managed) contra el Python del sistema.
if [ "$WITH_DEPS" = 1 ]; then
    echo "== Dependencias (uv, no pip pelado) =="
    api="$REPO_ROOT/e-comerce-api"
    if ! command -v uv >/dev/null 2>&1; then
        echo "[api] uv no esta en PATH — instala: curl -LsSf https://astral.sh/uv/install.sh | sh"
        echo "      (NO caer a pip pelado: PEP 668 lo bloquea en Ubuntu 24.04)"
    elif [ -f "$api/pyproject.toml" ]; then
        # Modelo-proyecto uv (pyproject.toml + uv.lock): reproducible.
        ( cd "$api" && uv sync --quiet && echo "[api] uv sync OK (pyproject.toml + uv.lock)" )
    else
        # Aun sin pyproject/uv.lock (iniciativa migrar-api-a-uv-pyproject
        # T-002/T-003 pendientes): uv como instalador sobre el .venv.
        ( cd "$api" && uv pip install --quiet -r requirements/development.txt \
            && echo "[api] uv pip install OK (requirements/development.txt)" )
    fi
    ( cd "$REPO_ROOT/e-comerce-ui" && npm ci --silent && echo "[ui] npm ci OK" )
fi

# --- Cierre ----------------------------------------------------------------
if [ "$fail" = 0 ]; then
    echo "OK: sincronizacion limpia. Para correr pruebas: bash $0 --test-steps"
else
    echo "ATENCION: hubo repos saltados o con divergencia (ver arriba)."
fi
exit "$fail"
