#!/bin/bash
# =============================================================================
# init-env.sh — Genera .env con credenciales seguras para PracticaYoruba-db
# =============================================================================
# Uso:
#   bash scripts/init-env.sh [--db-root <path>] [--api-root <path>]
#
# Opciones:
#   --db-root <path>   Ruta absoluta al repo kaupamex-db.
#                      Default: detectado por contenido (.env.example) desde
#                      el directorio del script.
#   --api-root <path>  Ruta absoluta al repo kaupamex-api.
#                      Default: autodetectado como sibling de db-root.
#
# El script detecta si .env ya existe y lo preserva sin sobrescribir.
# Propaga DB_PASSWORD, DB_QA_PASSWORD y SECRET_KEY a tres destinos en orden:
#
#   1. kaupamex/db/.env  ← FUENTE DE VERDAD PRIMARIA
#      Los provisioners db_setup.sh / db_qa_setup.sh leen de aquí.
#      (PROJECT_ROOT = SCRIPT_DIR/../.. resuelve a kaupamex/db/)
#
#   2. kaupamex-db/.env  ← copia derivada (repo standalone)
#
#   3. kaupamex-api/practicayoruba/.env  ← copia derivada (API Django)
#      bootstrap.sh lee DB_PASSWORD desde aquí.
#
# Invariante crítica — DB_PASSWORD == DB_QA_PASSWORD:
#   db_setup.sh crea django_user con DB_PASSWORD.
#   db_qa_setup.sh verifica la conexión con DB_QA_PASSWORD.
#   Son el mismo usuario MariaDB en los tres hosts (%, localhost, 127.0.0.1)
#   y DEBEN tener la misma contraseña. Este script genera un único valor
#   y lo asigna a ambas variables.
#
# Ejemplos:
#   # Desde dentro del repo:
#   bash scripts/init-env.sh
#
#   # Desde cualquier ruta (bind-mount, /tmp, etc.):
#   bash /opt/kaupamex/db/scripts/init-env.sh \
#     --db-root /opt/kaupamex/db \
#     --api-root /opt/kaupamex/api
# =============================================================================
set -euo pipefail

# ── Parsear argumentos CLI ─────────────────────────────────────────────────
DB_ROOT_ARG=""
API_ROOT_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --db-root)
            DB_ROOT_ARG="${2:-}"
            shift 2
            ;;
        --api-root)
            API_ROOT_ARG="${2:-}"
            shift 2
            ;;
        *)
            echo "ERROR: Argumento desconocido: $1" >&2
            echo "  Uso: bash scripts/init-env.sh [--db-root <path>] [--api-root <path>]" >&2
            exit 1
            ;;
    esac
done

# ── Resolver DB_REPO_ROOT ──────────────────────────────────────────────────
if [[ -n "$DB_ROOT_ARG" ]]; then
    DB_REPO_ROOT="$(cd "$DB_ROOT_ARG" && pwd)"
else
    # Detección por contenido: buscar .env.example subiendo desde SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CANDIDATE="$(cd "${SCRIPT_DIR}/.." && pwd)"
    if [[ -f "${CANDIDATE}/.env.example" ]]; then
        DB_REPO_ROOT="${CANDIDATE}"
    else
        CANDIDATE="$(pwd)"
        if [[ -f "${CANDIDATE}/.env.example" ]]; then
            DB_REPO_ROOT="${CANDIDATE}"
        else
            echo "ERROR: No se pudo detectar el repo root de kaupamex-db." >&2
            echo "  Asegúrate de ejecutar desde dentro del repo, o pasa --db-root:" >&2
            echo "    bash scripts/init-env.sh --db-root /ruta/a/kaupamex-db" >&2
            exit 1
        fi
    fi
fi

if [[ ! -f "${DB_REPO_ROOT}/.env.example" ]]; then
    echo "ERROR: ${DB_REPO_ROOT}/.env.example no encontrado." >&2
    echo "  El path --db-root no apunta al repo kaupamex-db." >&2
    exit 1
fi

DB_ENV="${DB_REPO_ROOT}/.env"
DB_ENV_EXAMPLE="${DB_REPO_ROOT}/.env.example"

# ── Resolver MONOREPO_DB_ROOT (kaupamex/db/) ──────────────────────────────
# Los provisioners db_setup.sh / db_qa_setup.sh calculan:
#   PROJECT_ROOT = SCRIPT_DIR/../..  →  kaupamex/db/
# y leen credenciales de ${PROJECT_ROOT}/.env. Esta ruta es la fuente de
# verdad primaria y debe actualizarse antes que los repos standalone.
PARENT="$(cd "${DB_REPO_ROOT}/.." && pwd)"
MONOREPO_DB_ROOT=""
for cand in \
    "${PARENT}/kaupamex/db" \
    "${PARENT}/../kaupamex/db"; do
    if [[ -f "${cand}/.env.example" ]]; then
        MONOREPO_DB_ROOT="$(cd "$cand" && pwd)"
        break
    fi
done

MONOREPO_DB_ENV="${MONOREPO_DB_ROOT:+${MONOREPO_DB_ROOT}/.env}"
MONOREPO_DB_ENV_EXAMPLE="${MONOREPO_DB_ROOT:+${MONOREPO_DB_ROOT}/.env.example}"

# ── Resolver API_REPO_ROOT ─────────────────────────────────────────────────
if [[ -n "$API_ROOT_ARG" ]]; then
    API_REPO_ROOT="$(cd "$API_ROOT_ARG" && pwd)"
else
    API_REPO_ROOT=""
    for cand in \
        "${PARENT}/kaupamex-api" \
        "${PARENT}/PracticaYoruba-api"; do
        [[ -d "$cand/practicayoruba" ]] && { API_REPO_ROOT="$cand"; break; }
    done
fi

API_ENV="${API_REPO_ROOT:+${API_REPO_ROOT}/practicayoruba/.env}"
API_ENV_EXAMPLE="${API_REPO_ROOT:+${API_REPO_ROOT}/practicayoruba/.env.example}"

echo "=== PracticaYoruba — init-env.sh ==="
echo ""
echo "  db-root     : ${DB_REPO_ROOT}"
echo "  monorepo-db : ${MONOREPO_DB_ROOT:-(no detectado — provisioners usarán kaupamex/db/)}"
echo "  api-root    : ${API_REPO_ROOT:-(no detectado)}"
echo ""

# ── Verificar que openssl está disponible ──────────────────────────────────
if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl no disponible. Instala openssl antes de continuar." >&2
    exit 1
fi

# ── Estado previo ──────────────────────────────────────────────────────────
DB_ENV_EXISTED=false
[[ -f "$DB_ENV" ]] && DB_ENV_EXISTED=true

MONOREPO_DB_ENV_EXISTED=false
[[ -n "$MONOREPO_DB_ENV" && -f "$MONOREPO_DB_ENV" ]] && MONOREPO_DB_ENV_EXISTED=true

API_ENV_EXISTED=false
[[ -n "$API_ENV" && -f "$API_ENV" ]] && API_ENV_EXISTED=true

# ── Si .env de db ya existe, no sobreescribir ──────────────────────────────
if [[ "$DB_ENV_EXISTED" == "true" ]]; then
    echo "  .env ya existe en ${DB_ENV}"
    echo "  Preservado sin cambios."
    [[ -n "$MONOREPO_DB_ENV" && "$MONOREPO_DB_ENV_EXISTED" == "true" ]] && {
        echo "  .env ya existe en ${MONOREPO_DB_ENV}"
        echo "  Preservado sin cambios."
    }
    [[ -n "$API_ENV" && "$API_ENV_EXISTED" == "true" ]] && {
        echo "  .env ya existe en ${API_ENV}"
        echo "  Preservado sin cambios."
    }
    echo ""
    echo "Para regenerar, elimina primero los archivos .env existentes:"
    echo "  rm ${DB_ENV}"
    [[ -n "$MONOREPO_DB_ENV" ]] && echo "  rm ${MONOREPO_DB_ENV}"
    [[ -n "$API_ENV" ]] && echo "  rm ${API_ENV}"
    exit 0
fi

# ── Generar valores seguros ────────────────────────────────────────────────
echo "  Generando credenciales seguras..."
SECRET_KEY="$(openssl rand -base64 50 | tr -d '\n')"
# Invariante: DB_PASSWORD == DB_QA_PASSWORD.
# db_setup.sh crea django_user con DB_PASSWORD para los hosts %, localhost
# y 127.0.0.1. db_qa_setup.sh verifica la conexión con DB_QA_PASSWORD.
# Son el mismo usuario MariaDB — una contraseña distinta por nombre de
# variable causa "Access denied" en el flujo E2E.
SHARED_DB_PASSWORD="$(openssl rand -hex 16)"
DB_PASSWORD="${SHARED_DB_PASSWORD}"
DB_QA_PASSWORD="${SHARED_DB_PASSWORD}"
# Credenciales de seed E2E (iniciativa seed-usuarios-e2e).
# Solo se usan en entornos QA/E2E. En produccion real, rotar manualmente.
ADMIN_PASSWORD="$(openssl rand -hex 16)"
QA_BUYER_PASSWORD="$(openssl rand -hex 16)"
echo "  SECRET_KEY      : generado (base64 50)"
echo "  DB_PASSWORD     : generado (hex 16)"
echo "  DB_QA_PASSWORD  : igual a DB_PASSWORD (invariante django_user)"
echo "  ADMIN_PASSWORD  : generado (hex 16)"
echo "  QA_BUYER_PASSWORD: generado (hex 16)"
echo ""

# ── Función: sustituir credenciales en un .env ─────────────────────────────
_apply_creds() {
    local src="$1" dst="$2"
    sed \
        -e "s|^SECRET_KEY=.*|SECRET_KEY=${SECRET_KEY}|" \
        -e "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|" \
        -e "s|^DB_QA_PASSWORD=.*|DB_QA_PASSWORD=${DB_QA_PASSWORD}|" \
        -e "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${ADMIN_PASSWORD}|" \
        -e "s|^QA_BUYER_PASSWORD=.*|QA_BUYER_PASSWORD=${QA_BUYER_PASSWORD}|" \
        "$src" > "$dst"
}

# ── 1. Monorepo kaupamex/db/.env (fuente de verdad primaria) ─────────────
if [[ -n "$MONOREPO_DB_ENV" ]]; then
    if [[ "$MONOREPO_DB_ENV_EXISTED" == "false" ]]; then
        if [[ -f "$MONOREPO_DB_ENV_EXAMPLE" ]]; then
            echo "  Creando ${MONOREPO_DB_ENV} ..."
            _apply_creds "$MONOREPO_DB_ENV_EXAMPLE" "$MONOREPO_DB_ENV"
            echo "  Creado: ${MONOREPO_DB_ENV}  ← fuente de verdad primaria"
        else
            echo "  AVISO: ${MONOREPO_DB_ENV_EXAMPLE} no encontrado — omitiendo monorepo"
        fi
    else
        echo "  Actualizando ${MONOREPO_DB_ENV} ..."
        local_tmp=$(mktemp)
        _apply_creds "$MONOREPO_DB_ENV" "$local_tmp"
        mv "$local_tmp" "$MONOREPO_DB_ENV"
        echo "  Actualizado: ${MONOREPO_DB_ENV}  ← fuente de verdad primaria"
    fi
else
    echo "  AVISO: monorepo kaupamex/db/ no detectado."
    echo "  Los provisioners db_setup.sh / db_qa_setup.sh leen de kaupamex/db/.env."
    echo "  Crea kaupamex/db/.env manualmente con las mismas credenciales"
    echo "  o ejecuta init-env.sh desde el directorio padre del monorepo."
fi
echo ""

# ── 2. Standalone kaupamex-db/.env ───────────────────────────────────────
echo "  Creando ${DB_ENV} ..."
_apply_creds "$DB_ENV_EXAMPLE" "$DB_ENV"
echo "  Creado: ${DB_ENV}"
echo ""

# ── 3. API kaupamex-api/practicayoruba/.env ──────────────────────────────
if [[ -n "$API_ENV" ]]; then
    if [[ "$API_ENV_EXISTED" == "false" ]]; then
        if [[ -f "$API_ENV_EXAMPLE" ]]; then
            echo "  Creando ${API_ENV} ..."
            _apply_creds "$API_ENV_EXAMPLE" "$API_ENV"
            echo "  Creado: ${API_ENV}"
        else
            echo "  AVISO: ${API_ENV_EXAMPLE} no encontrado — omitiendo propagación a API"
        fi
    else
        echo "  Actualizando ${API_ENV} ..."
        api_tmp=$(mktemp)
        _apply_creds "$API_ENV" "$api_tmp"
        mv "$api_tmp" "$API_ENV"
        echo "  Actualizado: ${API_ENV}"
    fi
else
    echo "  AVISO: repo hermano kaupamex-api no detectado."
    echo "  Pasa --api-root si los repos no son siblings:"
    echo "    bash scripts/init-env.sh --api-root /ruta/a/kaupamex-api"
fi

echo ""
echo "=== Listo ==="
echo ""
echo "Archivos generados:"
[[ -n "$MONOREPO_DB_ENV" && -f "$MONOREPO_DB_ENV" ]] && echo "  ${MONOREPO_DB_ENV}  ← fuente de verdad primaria (provisioners)"
echo "  ${DB_ENV}"
[[ -n "$API_ENV" && -f "$API_ENV" ]] && echo "  ${API_ENV}"
echo ""
echo "Siguiente paso para WSL2:"
echo "  cd ${API_REPO_ROOT:-../kaupamex-api}"
echo "  sudo bash scripts/bootstrap.sh"
