#!/bin/bash
# =============================================================================
# tests/test_mariadb_version.sh
# Asserta que la version de MariaDB instalada y activa es la serie
# 11.8 LTS — la version canonica del proyecto segun ADR-009.
# =============================================================================
# Cubre la deuda D-014: MariaDB 10.11 vs 11.8 mandate.
#
# El test:
#   1. Verifica que el binario cliente reporta 11.8.x.
#   2. Si el servidor responde, verifica que SELECT VERSION() tambien
#      reporta 11.8.x (la version del demonio, no solo del cliente).
#
# Idempotente y seguro: no modifica datos. Se ejecuta solo lectura.
# Si MariaDB no esta activo, salta la verificacion del servidor pero
# falla si el cliente reporta una serie incorrecta — la presencia del
# binario 10.11 ya es deuda.
#
# Uso:
#   bash tests/test_mariadb_version.sh
# =============================================================================
set -euo pipefail

EXPECTED_SERIES="11.8"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# -----------------------------------------------------------------------------
# 1) Cliente: mysql --version debe reportar 11.8.x
# -----------------------------------------------------------------------------
if ! command -v mysql >/dev/null 2>&1; then
    fail "mysql/mariadb cliente no encontrado en PATH — instala con provisioners/mariadb/install.sh"
fi

client_version=$(mysql --version 2>/dev/null || true)
# Anchored match: la salida del cliente trae "Distrib 11.8.7-MariaDB" o
# "from 11.8.7-MariaDB". Un substring-match plano de "11.8" tambien
# matchea "10.11.8" — falso positivo (Codex review 2026-05-19).
# Forzamos el punto que cierra la serie y un prefijo Distrib|from.
if ! grep -Eq "(Distrib|from) ${EXPECTED_SERIES}\." <<<"$client_version"; then
    echo "  cliente: ${client_version}" >&2
    fail "cliente mysql/mariadb no es ${EXPECTED_SERIES}.x — ADR-009 mandata la serie ${EXPECTED_SERIES}"
fi
pass "cliente reporta serie ${EXPECTED_SERIES} — ${client_version}"

# -----------------------------------------------------------------------------
# 2) Servidor: SELECT VERSION() debe reportar 11.8.x (si responde)
# -----------------------------------------------------------------------------
# Probar el socket canonico sin credenciales (auth_socket via root local).
server_responds=false
for sock in /run/mysqld/mysqld.sock /var/run/mysqld/mysqld.sock; do
    [[ -S "$sock" ]] || continue
    if mysqladmin --socket="$sock" ping --silent >/dev/null 2>&1; then
        server_responds=true
        break
    fi
done

if [[ "$server_responds" == "false" ]]; then
    echo "SKIP: MariaDB server no responde — verificacion solo de cliente"
    echo "      Arranca el servicio: bash scripts/start_db.sh"
    echo "OK: test_mariadb_version.sh (cliente)"
    exit 0
fi

# Servidor activo — preguntar VERSION()
server_version=$(mysql --protocol=socket -N -B -e "SELECT VERSION();" 2>/dev/null || true)
if [[ -z "$server_version" ]]; then
    fail "servidor activo pero SELECT VERSION() no retorno resultado"
fi

# Anchored match: SELECT VERSION() devuelve "11.8.7-MariaDB-..." al
# inicio del string. Forzamos coincidencia desde el principio con el
# punto que cierra la serie. Misma proteccion que el cliente contra
# falsos positivos del tipo "10.11.8" (Codex review 2026-05-19).
if ! grep -Eq "^${EXPECTED_SERIES}\." <<<"$server_version"; then
    echo "  servidor: ${server_version}" >&2
    fail "servidor MariaDB no es ${EXPECTED_SERIES}.x — ADR-009 mandata la serie ${EXPECTED_SERIES}"
fi
pass "servidor reporta serie ${EXPECTED_SERIES} — ${server_version}"

echo ""
echo "OK: test_mariadb_version.sh"
