#!/bin/bash
# =============================================================================
# scripts/backup_postgres.sh — Respaldo de las bases PostgreSQL
# =============================================================================
# Hermano de ``backup_db.sh`` (MariaDB) para el motor en uso (ADR-028). No es
# una traducción: cuatro decisiones cambian porque el motor cambia.
#
#   | MariaDB (backup_db.sh)          | PostgreSQL (aquí)                   |
#   |---------------------------------|-------------------------------------|
#   | ``mysqldump \| gzip -6``        | ``pg_dump -Fc`` (comprime nativo)   |
#   | ``--single-transaction``        | idem, pero es el default del formato|
#   | ``--routines --triggers``       | innecesario: ``-Fc`` lleva todo     |
#   | privilegios LOCK TABLES/RELOAD  | no existen ni hacen falta           |
#
# **``-Fc`` (custom) y no SQL plano.** El formato custom ya viene comprimido
# —de ahí que no haya ``| gzip``— y además permite restaurar selectivamente
# con ``pg_restore -t <tabla>``, que un ``.sql.gz`` no permite sin editarlo.
# El costo es que se restaura con ``pg_restore``, no con ``psql``.
#
# **El rol de respaldo.** MariaDB exigía ``LOCK TABLES`` y ``RELOAD`` globales
# para un dump consistente; PostgreSQL no, porque ``pg_dump`` toma un snapshot
# transaccional. Lo que sí necesita es LEER todo lo que va a volcar, y eso en
# PostgreSQL se concede de forma limpia con el rol predefinido ``pg_read_all_data``
# (PG 14+) en vez de enumerar GRANTs tabla por tabla.
#
# Flujo:
#   1. Verifica que el servidor responde y cumple el mínimo
#   2. (--setup-user) crea/actualiza el rol de respaldo, idempotente
#   3. Dump de cada base → ``<TS>_<base>.dump`` + ``.sha256``
#   4. Verifica el dump con ``pg_restore --list`` (no sólo el checksum: un
#      archivo íntegro puede no ser un dump válido)
#   5. Retención: elimina lo anterior a BACKUP_RETENTION_DAYS días
#
# Uso:
#   bash scripts/backup_postgres.sh              # respaldo de ambas bases
#   sudo bash scripts/backup_postgres.sh --setup-user   # crear el rol
#
# Variables del .env: DB_NAME, DB_QA_NAME, DB_PORT, DB_SOCKET,
#                     PY_BACKUP_USER, PY_BACKUP_PASSWORD,
#                     BACKUP_DIR, BACKUP_RETENTION_DAYS
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/utils/logging.sh"
source "${PROJECT_ROOT}/utils/postgresql.sh"

# ─── Cargar .env sin pisar el entorno (misma precedencia que H-DB-04) ────────
ENV_FILE="${PROJECT_ROOT}/.env"
if [[ -f "$ENV_FILE" ]]; then
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# || -z "${key// }" ]] && continue
        key="${key// }"
        [[ -n "${!key+x}" ]] && continue
        export "$key=${value}"
    done < "$ENV_FILE"
fi

DB_PROD="${DB_NAME:-kaupamex_db}"
DB_QA="${DB_QA_NAME:-kaupamex_qa}"
DB_PORT="${DB_PORT:-5432}"
BACKUP_USER="${PY_BACKUP_USER:-py_backup_user}"
BACKUP_PASS="${PY_BACKUP_PASSWORD:-}"
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_ROOT}/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

# Timestamp en la zona del proyecto, igual que el hermano de MariaDB.
TS="$(TZ="America/Mexico_City" date +"%Y%m%d_%H%M%S")"

MODE="${1:-}"

mkdir -p "$BACKUP_DIR"

# =============================================================================
# PASO 1 — El servidor responde y cumple el mínimo
# =============================================================================
log_header "PASO: Estado del servidor"

if ! postgres_is_running; then
    log_fatal "PostgreSQL no responde — arráncalo con scripts/start_postgres.sh"
    exit 1
fi

if diag="$(postgres_meets_minimum)"; then
    log_success "$diag"
else
    log_warn "$diag"
fi

SOCK="$(postgres_socket_dir)"
[[ -z "$SOCK" ]] && SOCK="${DB_HOST:-127.0.0.1}"
log_info "Conexión: ${SOCK}:${DB_PORT}"

# =============================================================================
# PASO 2 — Rol de respaldo (--setup-user)
# =============================================================================
# Se separa del respaldo porque crear un rol exige superusuario y el respaldo
# no: quien corre el backup diario no necesita poder crear roles.
# =============================================================================
if [[ "$MODE" == "--setup-user" ]]; then
    log_header "PASO: Rol de respaldo ${BACKUP_USER}"

    if [[ -z "$BACKUP_PASS" ]]; then
        log_fatal "PY_BACKUP_PASSWORD no definida — requerida para crear el rol"
        exit 1
    fi
    if [[ "$(id -u)" != "0" ]]; then
        log_fatal "--setup-user requiere root (crea un rol del motor)"
        exit 1
    fi

    # ``CREATE ROLE`` no admite ``IF NOT EXISTS``; se pregunta antes.
    _existe="$(su postgres -c \
        "psql -tAX -c \"SELECT 1 FROM pg_roles WHERE rolname='${BACKUP_USER}'\"" \
        2>/dev/null | tr -d '[:space:]')"
    if [[ "$_existe" == "1" ]]; then
        su postgres -c "psql -v ON_ERROR_STOP=1 -tAX -c \
            \"ALTER ROLE \\\"${BACKUP_USER}\\\" WITH LOGIN PASSWORD '${BACKUP_PASS}'\"" \
            >/dev/null
        log_success "Rol ya existía — contraseña actualizada"
    else
        su postgres -c "psql -v ON_ERROR_STOP=1 -tAX -c \
            \"CREATE ROLE \\\"${BACKUP_USER}\\\" WITH LOGIN PASSWORD '${BACKUP_PASS}'\"" \
            >/dev/null
        log_success "Rol creado"
    fi

    # pg_read_all_data (PG 14+) concede lectura sobre todo sin enumerar
    # tablas — y sin dar escritura, que es lo que un rol de respaldo no debe
    # tener. Es lo más cercano al principio de mínimo privilegio aquí.
    for _b in "$DB_PROD" "$DB_QA"; do
        su postgres -c "psql -v ON_ERROR_STOP=1 -tAX -d '${_b}' -c \
            \"GRANT pg_read_all_data TO \\\"${BACKUP_USER}\\\"\"" >/dev/null 2>&1 \
            && log_success "Lectura concedida sobre ${_b}" \
            || log_warn "No se pudo conceder pg_read_all_data sobre ${_b}"
        su postgres -c "psql -v ON_ERROR_STOP=1 -tAX -d '${_b}' -c \
            \"GRANT CONNECT ON DATABASE \\\"${_b}\\\" TO \\\"${BACKUP_USER}\\\"\"" \
            >/dev/null 2>&1 || true
    done

    # Sin esto el rol existe y aun así pg_dump falla por socket con "Peer
    # authentication failed" — H-DB-08. Crear un rol y no darle su regla de
    # pg_hba es crear un rol que no puede entrar por el canal que el proyecto
    # declara canónico.
    log_success "$(postgres_ensure_hba_socket "${BACKUP_USER}")"

    log_success "Rol de respaldo listo. Vuelve a ejecutar sin --setup-user."
    exit 0
fi

# =============================================================================
# PASO 3 y 4 — Dump y verificación por base
# =============================================================================
_dump_base() {
    local base="$1"
    local dump_file="${BACKUP_DIR}/${TS}_${base}.dump"
    local sum_file="${BACKUP_DIR}/${TS}_${base}.sha256"
    local err_file="${BACKUP_DIR}/${TS}_${base}.pg_dump.stderr"

    log_info "  Dump de ${base} → $(basename "$dump_file")"

    local t_ini; t_ini="$(date +%s)"

    # -Fc: formato custom (comprimido, restaurable selectivamente).
    # --no-password: falla en vez de quedarse esperando en un prompt, que en
    # un cron sería un cuelgue silencioso.
    if ! PGPASSWORD="$BACKUP_PASS" pg_dump \
            -h "$SOCK" -p "$DB_PORT" -U "$BACKUP_USER" \
            -Fc --no-password -d "$base" -f "$dump_file" 2>"$err_file"; then
        log_error "  pg_dump falló para ${base}:"
        while IFS= read -r line; do log_error "    ${line}"; done < "$err_file"
        return 1
    fi

    local t_fin elapsed size
    t_fin="$(date +%s)"; elapsed=$(( t_fin - t_ini ))
    size="$(du -h "$dump_file" | cut -f1)"
    log_info "  Completado: ${size} en ${elapsed}s"

    if [[ -s "$err_file" ]]; then
        log_warn "  pg_dump escribió en stderr:"
        while IFS= read -r line; do log_warn "    ${line}"; done < "$err_file"
    else
        rm -f "$err_file"
    fi

    # Verificación del dump, no sólo del archivo: pg_restore --list lee el
    # índice del formato custom. Un archivo íntegro puede no ser un dump
    # válido, y el checksum solo no distingue esos dos casos.
    if ! pg_restore --list "$dump_file" >/dev/null 2>&1; then
        log_fatal "  El dump de ${base} no es legible por pg_restore. Aborta."
        exit 1
    fi

    (cd "$BACKUP_DIR" && sha256sum "$(basename "$dump_file")") > "$sum_file"
    if ! (cd "$BACKUP_DIR" && sha256sum -c "$(basename "$sum_file")" >/dev/null 2>&1); then
        log_fatal "  Verificación SHA-256 fallida para ${base}. Aborta."
        exit 1
    fi

    log_success "  ${base}: dump OK — pg_restore --list y SHA-256 verificados"
}

log_header "PASO: Respaldo de las bases"

if [[ -z "$BACKUP_PASS" ]]; then
    log_fatal "PY_BACKUP_PASSWORD no definida — crea el rol con --setup-user"
    exit 1
fi

_fallos=0
for _b in "$DB_PROD" "$DB_QA"; do
    _dump_base "$_b" || _fallos=$(( _fallos + 1 ))
done

# =============================================================================
# PASO 5 — Retención
# =============================================================================
log_header "PASO: Retención (>${BACKUP_RETENTION_DAYS} días)"

_borrados=0
while IFS= read -r -d '' f; do
    rm -f "$f"
    _borrados=$(( _borrados + 1 ))
done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \
              \( -name '*.dump' -o -name '*.sha256' -o -name '*.pg_dump.stderr' \) \
              -mtime "+${BACKUP_RETENTION_DAYS}" -print0 2>/dev/null)

if [[ "$_borrados" -gt 0 ]]; then
    log_success "${_borrados} archivo(s) antiguo(s) eliminado(s)"
else
    log_info "Nada que eliminar"
fi

echo ""
if [[ "$_fallos" -eq 0 ]]; then
    log_success "Respaldo completo en ${BACKUP_DIR}"
else
    log_error "${_fallos} base(s) fallaron — revisa los mensajes de arriba"
fi
exit $(( _fallos > 0 ? 1 : 0 ))
