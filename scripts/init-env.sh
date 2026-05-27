#!/bin/bash
# =============================================================================
# init-env.sh — Genera .env con credenciales seguras para PracticaYoruba-db
# =============================================================================
# Uso:
#   bash scripts/init-env.sh [--db-root <path>] [--api-root <path>]
#
# Opciones:
#   --db-root <path>   Ruta absoluta al repo e-comerce-db.
#                      Default: detectado por contenido (.env.example) desde
#                      el directorio del script.
#   --api-root <path>  Ruta absoluta al repo e-comerce-api.
#                      Default: autodetectado como sibling de db-root.
#
# El script detecta si .env ya existe y lo preserva sin sobrescribir.
# También propaga DB_PASSWORD, DB_QA_PASSWORD y SECRET_KEY al .env de
# e-comerce-api/practicayoruba/ para mantener ambos repos sincronizados.
#
# Bootstrap flow:
#   bootstrap.sh (en e-comerce-api) lee DB_PASSWORD desde
#   practicayoruba/.env — no desde e-comerce-db/.env.
#   Este script genera los mismos valores en ambos archivos.
#
# Ejemplos:
#   # Desde dentro del repo:
#   bash scripts/init-env.sh
#
#   # Desde cualquier ruta (bind-mount, /tmp, etc.):
#   bash /srv/repos/ecom/e-comerce-db/scripts/init-env.sh \
#     --db-root /srv/repos/ecom/e-comerce-db \
#     --api-root /srv/repos/ecom/e-comerce-api
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
    # Esto es robusto si BASH_SOURCE[0] es una ruta real (no proceso sustitución).
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CANDIDATE="$(cd "${SCRIPT_DIR}/.." && pwd)"
    if [[ -f "${CANDIDATE}/.env.example" ]]; then
        DB_REPO_ROOT="${CANDIDATE}"
    else
        # Fallback: intentar el directorio actual
        CANDIDATE="$(pwd)"
        if [[ -f "${CANDIDATE}/.env.example" ]]; then
            DB_REPO_ROOT="${CANDIDATE}"
        else
            echo "ERROR: No se pudo detectar el repo root de e-comerce-db." >&2
            echo "  Asegúrate de ejecutar desde dentro del repo, o pasa --db-root:" >&2
            echo "    bash scripts/init-env.sh --db-root /ruta/a/e-comerce-db" >&2
            exit 1
        fi
    fi
fi

# Validar que el directorio resuelto es realmente el repo db
if [[ ! -f "${DB_REPO_ROOT}/.env.example" ]]; then
    echo "ERROR: ${DB_REPO_ROOT}/.env.example no encontrado." >&2
    echo "  El path --db-root no apunta al repo e-comerce-db." >&2
    exit 1
fi

DB_ENV="${DB_REPO_ROOT}/.env"
DB_ENV_EXAMPLE="${DB_REPO_ROOT}/.env.example"

# ── Resolver API_REPO_ROOT ─────────────────────────────────────────────────
if [[ -n "$API_ROOT_ARG" ]]; then
    API_REPO_ROOT="$(cd "$API_ROOT_ARG" && pwd)"
else
    # Autodetección: buscar repo hermano en el directorio padre
    API_REPO_ROOT=""
    PARENT="$(cd "${DB_REPO_ROOT}/.." && pwd)"
    for cand in \
        "${PARENT}/e-comerce-api" \
        "${PARENT}/PracticaYoruba-api"; do
        [[ -d "$cand/practicayoruba" ]] && { API_REPO_ROOT="$cand"; break; }
    done
fi

API_ENV="${API_REPO_ROOT:+${API_REPO_ROOT}/practicayoruba/.env}"
API_ENV_EXAMPLE="${API_REPO_ROOT:+${API_REPO_ROOT}/practicayoruba/.env.example}"

echo "=== PracticaYoruba — init-env.sh ==="
echo ""
echo "  db-root : ${DB_REPO_ROOT}"
echo "  api-root: ${API_REPO_ROOT:-(no detectado)}"
echo ""

# ── Verificar que openssl está disponible ──────────────────────────────────
if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl no disponible. Instala openssl antes de continuar." >&2
    exit 1
fi

# ── Guardar si ya existía para mensaje final ───────────────────────────────
DB_ENV_EXISTED=false
[[ -f "$DB_ENV" ]] && DB_ENV_EXISTED=true

API_ENV_EXISTED=false
[[ -n "$API_ENV" && -f "$API_ENV" ]] && API_ENV_EXISTED=true

# ── Si .env de db ya existe, no sobreescribir ──────────────────────────────
if [[ "$DB_ENV_EXISTED" == "true" ]]; then
    echo "  .env ya existe en ${DB_ENV}"
    echo "  Preservado sin cambios."
    if [[ -n "$API_ENV" && "$API_ENV_EXISTED" == "true" ]]; then
        echo "  .env ya existe en ${API_ENV}"
        echo "  Preservado sin cambios."
    fi
    echo ""
    echo "Para regenerar, elimina primero el .env existente:"
    echo "  rm ${DB_ENV}"
    [[ -n "$API_ENV" ]] && echo "  rm ${API_ENV}"
    exit 0
fi

# ── Generar valores seguros ────────────────────────────────────────────────
echo "  Generando credenciales seguras..."
SECRET_KEY="$(openssl rand -base64 50 | tr -d '\n')"
DB_PASSWORD="$(openssl rand -hex 16)"
DB_QA_PASSWORD="$(openssl rand -hex 16)"
echo "  SECRET_KEY    : generado (base64 50)"
echo "  DB_PASSWORD   : generado (hex 16)"
echo "  DB_QA_PASSWORD: generado (hex 16)"
echo ""

# ── Crear .env de e-comerce-db ─────────────────────────────────────────────
echo "  Creando ${DB_ENV} ..."
sed \
    -e "s|^SECRET_KEY=.*|SECRET_KEY=${SECRET_KEY}|" \
    -e "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|" \
    -e "s|^DB_QA_PASSWORD=.*|DB_QA_PASSWORD=${DB_QA_PASSWORD}|" \
    "$DB_ENV_EXAMPLE" > "$DB_ENV"
echo "  Creado: ${DB_ENV}"

# ── Crear / actualizar .env de e-comerce-api ──────────────────────────────
if [[ -n "$API_ENV" ]]; then
    if [[ "$API_ENV_EXISTED" == "false" ]]; then
        if [[ -f "$API_ENV_EXAMPLE" ]]; then
            echo "  Creando ${API_ENV} ..."
            sed \
                -e "s|^SECRET_KEY=.*|SECRET_KEY=${SECRET_KEY}|" \
                -e "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|" \
                -e "s|^DB_QA_PASSWORD=.*|DB_QA_PASSWORD=${DB_QA_PASSWORD}|" \
                "$API_ENV_EXAMPLE" > "$API_ENV"
            echo "  Creado: ${API_ENV}"
        else
            echo "  AVISO: ${API_ENV_EXAMPLE} no encontrado — omitiendo propagación a API"
        fi
    else
        # .env de API ya existe — actualizar solo las tres claves
        echo "  Actualizando credenciales en ${API_ENV} ..."
        tmp=$(mktemp)
        sed \
            -e "s|^SECRET_KEY=.*|SECRET_KEY=${SECRET_KEY}|" \
            -e "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|" \
            -e "s|^DB_QA_PASSWORD=.*|DB_QA_PASSWORD=${DB_QA_PASSWORD}|" \
            "$API_ENV" > "$tmp"
        mv "$tmp" "$API_ENV"
        echo "  Actualizado: ${API_ENV}"
    fi
else
    echo "  AVISO: repo hermano e-comerce-api no detectado."
    echo "  Pasa --api-root si los repos no son siblings:"
    echo "    bash scripts/init-env.sh --api-root /ruta/a/e-comerce-api"
fi

echo ""
echo "=== Listo ==="
echo ""
echo "Archivos generados:"
echo "  ${DB_ENV}"
[[ -n "$API_ENV" && (-f "$API_ENV") ]] && echo "  ${API_ENV}"
echo ""
echo "Siguiente paso para WSL2:"
echo "  cd ${API_REPO_ROOT:-../e-comerce-api}"
echo "  sudo bash scripts/bootstrap.sh"
