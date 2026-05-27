#!/bin/bash
# =============================================================================
# init-env.sh — Genera .env con credenciales seguras para PracticaYoruba-db
# =============================================================================
# Uso:
#   bash scripts/init-env.sh
#
# El script detecta si .env ya existe y lo preserva sin sobrescribir.
# También propaga DB_PASSWORD, DB_QA_PASSWORD y SECRET_KEY al .env de
# e-comerce-api/practicayoruba/ para mantener ambos repos sincronizados.
#
# Bootstrap flow (Bug 2):
#   bootstrap.sh (en e-comerce-api) lee DB_PASSWORD desde
#   practicayoruba/.env — no desde e-comerce-db/.env.
#   Este script genera los mismos valores en ambos archivos.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DB_ENV="${DB_REPO_ROOT}/.env"
DB_ENV_EXAMPLE="${DB_REPO_ROOT}/.env.example"

# Detectar repo hermano e-comerce-api
API_REPO_ROOT=""
for cand in \
    "$(cd "${DB_REPO_ROOT}/.." && pwd)/e-comerce-api" \
    "$(cd "${DB_REPO_ROOT}/.." && pwd)/PracticaYoruba-api"; do
    [[ -d "$cand/practicayoruba" ]] && { API_REPO_ROOT="$cand"; break; }
done
API_ENV="${API_REPO_ROOT:+${API_REPO_ROOT}/practicayoruba/.env}"
API_ENV_EXAMPLE="${API_REPO_ROOT:+${API_REPO_ROOT}/practicayoruba/.env.example}"

echo "=== PracticaYoruba — init-env.sh ==="
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

# ── Si ambos .env ya existen, no hay nada que hacer ───────────────────────
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
echo "  SECRET_KEY   : generado (base64 50)"
echo "  DB_PASSWORD  : generado (hex 16)"
echo "  DB_QA_PASSWORD: generado (hex 16)"
echo ""

# ── Crear .env de e-comerce-db ─────────────────────────────────────────────
if [[ "$DB_ENV_EXISTED" == "false" ]]; then
    if [[ ! -f "$DB_ENV_EXAMPLE" ]]; then
        echo "ERROR: ${DB_ENV_EXAMPLE} no encontrado. No se puede generar .env." >&2
        exit 1
    fi
    echo "  Creando ${DB_ENV} ..."
    sed \
        -e "s|^SECRET_KEY=.*|SECRET_KEY=${SECRET_KEY}|" \
        -e "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|" \
        -e "s|^DB_QA_PASSWORD=.*|DB_QA_PASSWORD=${DB_QA_PASSWORD}|" \
        "$DB_ENV_EXAMPLE" > "$DB_ENV"
    echo "  Creado: ${DB_ENV}"
fi

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
        # .env de API ya existe — actualizar solo las claves que cambiaron
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
    echo "  AVISO: repo hermano e-comerce-api no detectado — solo se generó db/.env"
fi

echo ""
echo "=== Listo ==="
echo ""
echo "Archivos generados:"
echo "  ${DB_ENV}"
[[ -n "$API_ENV" ]] && echo "  ${API_ENV}"
echo ""
echo "Siguiente paso para WSL2:"
echo "  cd ../e-comerce-api"
echo "  sudo bash scripts/bootstrap.sh"
