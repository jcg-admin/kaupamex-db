#!/bin/bash
# =============================================================================
# provisioners/postgresql/install.sh
# Instala PostgreSQL (el del distro, ≥ mínimo de la referencia)
# =============================================================================
# IDEMPOTENTE: si ya hay un servidor que satisface el mínimo, no hace nada.
#
# Escenarios (mismos tres que provisioners/mariadb/install.sh):
#   A) PostgreSQL no instalado        → instala el del distro
#   B) Instalado y >= mínimo          → no-op, reporta OK
#   C) Instalado y < mínimo           → DETIENE con instrucciones,
#                                       a menos que se pase --migrate
#
# Uso:
#   sudo bash provisioners/postgresql/install.sh
#   sudo bash provisioners/postgresql/install.sh --migrate   # purga e instala
#
# Por qué se detiene ante versión insuficiente (sin --migrate):
#   Purgar PostgreSQL ELIMINA los datos en /var/lib/postgresql. Hacerlo
#   automáticamente sin confirmación es destructivo. El flag --migrate es la
#   confirmación del operador de que hizo backup y acepta la pérdida.
#   Mismo criterio, verbatim, que el provisioner de MariaDB.
#
# Qué versión y por qué (medido, no de memoria)
# ----------------------------------------------
#   La referencia NO fija versión de servidor: su ``debian/control`` declara
#   ``postgresql`` y ``postgresql-client`` sin número — la del distro. Lo que
#   sí declara es un mínimo: ``MIN_PG_VERSION = 13``
#   (``odoo19c: odoo/release.py:41``), verificado en arranque
#   (``odoo/sql_db.py:699-700``). ``odoo18c:`` no declara ese símbolo.
#   Medido sobre ``odoo-tools@622ddc2a``.
#
#   Este script hace lo mismo: instala el metapaquete ``postgresql`` del
#   distro y **verifica** que lo que quedó satisface el mínimo. No pinea un
#   número, porque pinearlo sería divergir de la referencia sin decidirlo.
#   En Ubuntu 24.04 eso resuelve a 16 (medido: ``apt-cache policy postgresql``
#   → ``16+257build1.1``).
#
#   El ecosistema corrobora el rango, sin ser autoridad. En el mismo repo
#   ``odoo-tools`` hay terceros que sí pinean, y no coinciden entre ellos:
#
#     | Fuente (terceros, NO la referencia)      | Versión         |
#     |------------------------------------------|-----------------|
#     | ``scripts/OdooScript/src/redhat.sh:47``   | 16 (pin duro)   |
#     | ``scripts/OdooScript/src/odoo_redhat.sh:43`` | 16 (pin duro)|
#     | ``19.x/oerp-odoo-19.0`` CI (``test.yml:15``) | ``postgres:13``|
#     | ``16.x/scuver-oddo`` (``docker-compose.yml:20``) | ``postgres:13`` |
#
#   Instalación fresca → 16; CI → 13. Nuestro 16-del-distro cae dentro y
#   satisface el mínimo, así que la elección no depende de ellos — pero vale
#   registrar que la vía **PGDG** (repositorio oficial de PostgreSQL, que es
#   lo que usan esos instaladores vía ``pgdg.list``/``pgdg20.list``) es una
#   alternativa real y no un exotismo. Se descarta por ahora porque añade un
#   repositorio externo al provisioning, no porque no funcione. Ver H-DB-02.
#
# Variables del .env (opcionales, con defaults):
#   POSTGRES_MIN_MAJOR  (default: 13 — el mínimo de la referencia)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../../utils/logging.sh
source "${PROJECT_ROOT}/utils/logging.sh"
# shellcheck source=../../utils/core.sh
source "${PROJECT_ROOT}/utils/core.sh"
# shellcheck source=../../utils/postgresql.sh
source "${PROJECT_ROOT}/utils/postgresql.sh"

ENV_FILE="${PROJECT_ROOT}/.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

POSTGRES_MIN_MAJOR="${POSTGRES_MIN_MAJOR:-13}"
MIGRATE=false
[[ "${1:-}" == "--migrate" ]] && MIGRATE=true

log_header "Provisioning de PostgreSQL"

# -----------------------------------------------------------------------------
# Escenario B — ya instalado y suficiente
# -----------------------------------------------------------------------------
if command_exists psql; then
    postgres_start || true
    if postgres_is_running; then
        diagnostico="$(postgres_meets_minimum)" && {
            log_success "Ya instalado — ${diagnostico}"
            log_info "Nada que hacer. Siguiente paso: db_setup.sh"
            exit 0
        }
        # -------------------------------------------------------------------
        # Escenario C — instalado pero por debajo del mínimo
        # -------------------------------------------------------------------
        log_warn "${diagnostico}"
        if [[ "$MIGRATE" != true ]]; then
            log_error "El servidor no satisface el mínimo de la referencia."
            log_info  "Para reinstalar PURGANDO los datos existentes:"
            log_info  "    sudo bash provisioners/postgresql/install.sh --migrate"
            log_info  "Antes de eso, respaldar:  pg_dumpall > respaldo.sql"
            exit 1
        fi
        log_warn "--migrate recibido: se purga la instalación existente"
        apt-get remove --purge -y 'postgresql-*' >/dev/null
        apt-get autoremove -y >/dev/null
    else
        log_warn "psql presente pero el servidor no responde; se continúa con la instalación"
    fi
fi

# -----------------------------------------------------------------------------
# Escenario A — instalar
# -----------------------------------------------------------------------------
log_step 1 3 "Instalando el PostgreSQL del distro (sin pinear versión, como la referencia)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y postgresql postgresql-client >/dev/null

log_step 2 3 "Arrancando el servidor"
if ! postgres_start; then
    log_fatal "PostgreSQL quedó instalado pero no arranca. Revisar los logs del cluster."
fi

# -----------------------------------------------------------------------------
# Gate: lo instalado tiene que satisfacer el mínimo. Instalar y no verificar
# dejaría el mismo estado que el escenario C, sin avisar.
# -----------------------------------------------------------------------------
log_step 3 3 "Verificando contra el mínimo de la referencia"
if diagnostico="$(postgres_meets_minimum)"; then
    log_success "$diagnostico"
else
    log_fatal "El distro sirvió una versión insuficiente: ${diagnostico}.
La salida es el repositorio PGDG (apt.postgresql.org), que es lo que usan los
instaladores de terceros de odoo-tools — no un exotismo. No se hace en
automático porque añade un repositorio externo al provisioning, y esa es una
decisión del operador, no un efecto colateral de correr este script."
fi

log_success "PostgreSQL instalado y en ejecución"
log_info "Siguiente paso:  sudo bash provisioners/postgresql/db_setup.sh"
