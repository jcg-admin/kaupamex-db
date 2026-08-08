#!/bin/bash
# =============================================================================
# tests/test_cli_binary_detection.sh
# Test de regresion para D-028.
#
# D-028 reporto que install.sh + db_setup.sh + db_qa_setup.sh
# buscaban hardcodeado el binario ``mysql`` / ``mysqladmin``. En
# MariaDB 11.x sobre Ubuntu 24.04 noble esos alias legacy ya NO se
# instalan — solo existen ``mariadb`` / ``mariadb-admin``. El fix
# vive en ``utils/database.sh`` (helpers mariadb_client_bin /
# mariadb_admin_bin + variables MARIADB_CLI / MARIADB_ADM
# exportadas al sourcear el archivo).
#
# Este test asegura que el fix no regresione: si alguien revierte
# los helpers o vuelve a hardcodear ``mysql`` en los provisioners,
# el test falla LOUD con la causa explicita (DEC-DOC-008).
#
# Idempotente: solo lee scripts y verifica resolucion de binarios.
# No instala nada ni conecta al servidor.
# =============================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXIT=0

fail() { echo "FAIL: $*" >&2; EXIT=1; }
pass() { echo "PASS: $*"; }

# ----------------------------------------------------------------------------
# 1) utils/database.sh expone los helpers de D-028.
# ----------------------------------------------------------------------------
DB_UTIL="$PROJECT_ROOT/utils/database.sh"
[[ -f "$DB_UTIL" ]] || { echo "FATAL: $DB_UTIL no existe" >&2; exit 1; }

for fn in mariadb_client_bin mariadb_admin_bin; do
    if ! grep -qE "^${fn}\(\)" "$DB_UTIL"; then
        fail "utils/database.sh no define funcion ${fn}() (D-028 regresion)"
    else
        pass "utils/database.sh define ${fn}()"
    fi
done

# Variables MARIADB_CLI / MARIADB_ADM deben quedar exportadas al
# sourcear el archivo (la asignacion al final del archivo, no dentro
# de una funcion).
for var in MARIADB_CLI MARIADB_ADM; do
    if ! grep -qE "^${var}=" "$DB_UTIL"; then
        fail "utils/database.sh no asigna ${var} al cargar (D-028 regresion)"
    elif ! grep -qE "export[[:space:]]+.*${var}" "$DB_UTIL"; then
        fail "utils/database.sh asigna ${var} pero no la exporta (D-028 regresion)"
    else
        pass "utils/database.sh exporta ${var} al sourcear"
    fi
done

# ----------------------------------------------------------------------------
# 2) Los provisioners no llaman bare 'mysql' / 'mysqladmin' como
#    binarios. Solo se permiten esas cadenas como:
#      - paths del SO (--user=mysql, /var/lib/mysql, /run/mysqld)
#      - nombres de tablas internas (mysql.user, mysql.proc, etc.)
#      - cadenas en comentarios o mensajes de log
#      - nombre del paquete apt (mariadb-client, mariadb-server)
# ----------------------------------------------------------------------------
PROVISIONER_FILES=(
    "$PROJECT_ROOT/provisioners/mariadb/install.sh"
    "$PROJECT_ROOT/provisioners/mariadb/db_setup.sh"
    "$PROJECT_ROOT/provisioners/mariadb/db_qa_setup.sh"
)

for f in "${PROVISIONER_FILES[@]}"; do
    [[ -f "$f" ]] || { fail "provisioner ausente: $f"; continue; }
    # Busca patrones bare-binary: "mysql <flag>", "mysqladmin <flag>",
    # al inicio de palabra y seguido de --|-h|-e|-u|-p|ping|reload|--version
    # que indican uso como comando. Filtra falsos positivos por path/tabla.
    leaks=$(grep -nE '(^|[[:space:]])(mysql|mysqladmin)[[:space:]]+(--|-h|-e|-u|-p|ping|reload|--version)' "$f" \
            | grep -vE '/var/lib/mysql|/run/mysqld|/etc/mysql|--user=mysql|mysql_install_db|mysql:|mysql\.user|mysql\.proc|mysql\.plugin|comentario|legacy|MariaDB|mariadb-client' \
            || true)
    if [[ -n "$leaks" ]]; then
        fail "$(basename "$f") tiene llamadas bare a mysql/mysqladmin (D-028 regresion):"
        echo "$leaks" | sed 's/^/        /' >&2
    else
        pass "$(basename "$f") usa MARIADB_CLI/MARIADB_ADM (sin bare mysql)"
    fi
done

# ----------------------------------------------------------------------------
# 3) _db_exec en db_setup.sh + db_qa_setup.sh es loud bajo error
#    (DEC-DOC-008 sub-fix de D-028: el silent death de "Creando
#    schema" se elimina porque _db_exec emite stderr antes de
#    propagar el rc).
# ----------------------------------------------------------------------------
for f in "$PROJECT_ROOT/provisioners/mariadb/db_setup.sh" \
         "$PROJECT_ROOT/provisioners/mariadb/db_qa_setup.sh"; do
    if ! grep -qE '_db_exec fallo' "$f"; then
        fail "$(basename "$f") _db_exec no es loud bajo error (D-028 bug #3 regresion)"
    else
        pass "$(basename "$f") _db_exec emite stderr loud bajo rc != 0"
    fi
done

# ----------------------------------------------------------------------------
# H-20 (D-031): install.sh instala los plugin-provider packages
# (bzip2, lz4, lzma, lzo, snappy). Sin estos paquetes mariadbd 11.8
# revienta porque el config default los referencia con
# force_plus_permanent y las .so no existen.
# ----------------------------------------------------------------------------
INSTALL_SH="$PROJECT_ROOT/provisioners/mariadb/install.sh"
if [[ -f "$INSTALL_SH" ]]; then
    missing_providers=()
    for prov in bzip2 lz4 lzma lzo snappy; do
        if ! grep -qE "mariadb-plugin-provider-${prov}" "$INSTALL_SH"; then
            missing_providers+=("$prov")
        fi
    done
    if (( ${#missing_providers[@]} == 0 )); then
        pass "install.sh instala los 5 mariadb-plugin-provider-* (H-20)"
    else
        fail "install.sh no instala: ${missing_providers[*]} (H-20 regresion)"
    fi
fi

# ----------------------------------------------------------------------------
# 4) Si MariaDB esta instalado localmente, los helpers resuelven a
#    binarios que existen (smoke test funcional).
# ----------------------------------------------------------------------------
# shellcheck disable=SC1090
source "$DB_UTIL"

if [[ -n "${MARIADB_CLI:-}" ]]; then
    if ! command -v "$MARIADB_CLI" &>/dev/null; then
        fail "MARIADB_CLI=${MARIADB_CLI} pero no esta en PATH"
    else
        pass "MARIADB_CLI=${MARIADB_CLI} (existe en PATH)"
    fi
else
    pass "MARIADB_CLI vacio (esperado si ni mariadb ni mysql instalados)"
fi

if [[ -n "${MARIADB_ADM:-}" ]]; then
    if ! command -v "$MARIADB_ADM" &>/dev/null; then
        fail "MARIADB_ADM=${MARIADB_ADM} pero no esta en PATH"
    else
        pass "MARIADB_ADM=${MARIADB_ADM} (existe en PATH)"
    fi
else
    pass "MARIADB_ADM vacio (esperado si ni mariadb-admin ni mysqladmin instalados)"
fi

# ----------------------------------------------------------------------------
# Cierre
# ----------------------------------------------------------------------------
echo ""
if [[ "$EXIT" -eq 0 ]]; then
    echo ">>> ALL PASS — D-028 fix integro"
else
    echo ">>> FAIL — D-028 regresion detectada; revisar utils/database.sh y provisioners"
fi
exit "$EXIT"
