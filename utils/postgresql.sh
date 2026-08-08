#!/bin/bash
# =============================================================================
# utils/postgresql.sh — Funciones de PostgreSQL — kaupamex-db
# =============================================================================
# Hermano de ``utils/database.sh``, que pese a su nombre genérico es
# MariaDB-only (todas sus funciones llevan prefijo ``mariadb_``). No se
# renombra ni se extiende: hacerlo tocaría los tres provisioners de MariaDB
# ya probados para un beneficio de nomenclatura. Se añade este archivo al
# lado y los consumidores hacen ``source`` del que necesitan.
#
# Por qué PostgreSQL entra al repo
# ---------------------------------
# La referencia corre sobre PostgreSQL y adapta contra él: SQL crudo,
# ``Query``/``SQL()``, índices GIN y operadores de arreglo. Lo que aquí se
# provisiona es ese motor, medido contra la referencia — no elegido de
# memoria.
#
# **Versión.** ``odoo19c:`` no fija una versión de servidor: su
# ``debian/control`` declara ``postgresql`` y ``postgresql-client`` sin
# número, o sea la del distro. Lo que sí declara es un **mínimo**:
# ``MIN_PG_VERSION = 13`` (``odoo19c: odoo/release.py:41``), verificado en
# arranque (``odoo/sql_db.py:699-700``, avisa si
# ``server_version < MIN_PG_VERSION * 10000``). ``odoo18c:`` **no** declara
# ese símbolo — sólo reporta la versión del servidor en el manifest del dump
# (``odoo/service/db.py:267``). Medido sobre ``odoo-tools@622ddc2a``.
#
# En Ubuntu 24.04 el candidato de apt es **16** (medido:
# ``apt-cache policy postgresql`` → ``16+257build1.1``), que satisface el
# mínimo con holgura. Por eso ``PG_MAJOR`` default es 16 y no un número
# inventado: es lo que el distro sirve, igual que hace la referencia.
#
# Modelo de nombres — traducción desde MariaDB
# ---------------------------------------------
# "Schema" no significa lo mismo en los dos motores, y confundirlos produce
# un provisioner que crea la cosa equivocada:
#
#   | MariaDB (lo que ya existe) | PostgreSQL (aquí)            |
#   |----------------------------|------------------------------|
#   | schema ``kaupamex_db``     | **database** ``kaupamex_db`` |
#   | schema ``kaupamex_qa``     | **database** ``kaupamex_qa`` |
#   | usuario ``django_user``    | **rol** ``django_user`` LOGIN|
#
# Un "schema" de PostgreSQL es un namespace **dentro** de una base; el
# equivalente de nuestros dos schemas de MariaDB son dos **bases**. Ese es
# también el modelo de la referencia: una base por instalación.
# =============================================================================

# Sockets Unix candidatos, en orden de preferencia. Debian/Ubuntu usa
# ``/var/run/postgresql``; el resto son fallbacks de otras distros.
_POSTGRES_SOCKET_DIRS=(
    "/var/run/postgresql"
    "/tmp"
)

# Mínimo efectivo = el MAYOR de los dos mínimos que nos atan, no el de la
# referencia solo:
#
#   | Quién lo impone | Mínimo | Dónde                                       |
#   |-----------------|--------|---------------------------------------------|
#   | la referencia   | **13** | ``odoo19c: odoo/release.py:41``             |
#   | **nuestro ORM** | **14** | ``django/db/backends/postgresql/features.py:10`` |
#
# Django 6 no avisa: `minimum_database_version = (14,)` aborta la conexión.
# Un servidor 13 pasaría el gate de la referencia y **rompería el arranque**
# de nuestro backend, así que 13 sería un gate que no protege lo que el
# proyecto realmente ejecuta. Ver H-DB-03.
POSTGRES_MIN_MAJOR="${POSTGRES_MIN_MAJOR:-14}"

# -----------------------------------------------------------------------------
# postgres_client_bin
#   Devuelve el cliente disponible (``psql``), o cadena vacía.
#   Existe por simetría con ``mariadb_client_bin``: en PostgreSQL no hay el
#   problema de aliases legacy que motivó aquel helper (D-028), pero el
#   consumidor no debería tener que saberlo.
# -----------------------------------------------------------------------------
postgres_client_bin() {
    if command -v psql &>/dev/null; then
        echo "psql"
    else
        echo ""
    fi
}

# -----------------------------------------------------------------------------
# postgres_socket_dir
#   Devuelve el directorio de socket donde el servidor está escuchando, o
#   cadena vacía si no encuentra ninguno.
# -----------------------------------------------------------------------------
postgres_socket_dir() {
    local dir
    for dir in "${_POSTGRES_SOCKET_DIRS[@]}"; do
        if compgen -G "${dir}/.s.PGSQL.*" > /dev/null 2>&1; then
            echo "$dir"
            return 0
        fi
    done
    echo ""
    return 1
}

# -----------------------------------------------------------------------------
# postgres_is_running
#   0 si el servidor responde, 1 si no.
#
#   Usa ``pg_isready`` cuando está — es la herramienta que existe justamente
#   para esto y no abre una sesión. Si no está (cliente no instalado), cae a
#   detectar el socket, que es más débil: un socket huérfano existe sin
#   servidor detrás. Se declara la diferencia en vez de tratarlas igual.
# -----------------------------------------------------------------------------
postgres_is_running() {
    if command -v pg_isready &>/dev/null; then
        pg_isready --quiet 2>/dev/null && return 0
        return 1
    fi
    [[ -n "$(postgres_socket_dir)" ]]
}

# -----------------------------------------------------------------------------
# postgres_server_major
#   Devuelve la versión mayor del servidor EN EJECUCIÓN (no la del paquete
#   instalado — pueden diferir si hay varios clusters). Cadena vacía si no
#   responde.
# -----------------------------------------------------------------------------
postgres_server_major() {
    local psql_bin
    psql_bin="$(postgres_client_bin)"
    [[ -z "$psql_bin" ]] && { echo ""; return 1; }
    postgres_is_running || { echo ""; return 1; }
    # ``server_version_num`` viene como entero: 160004 → 16.
    local num
    num="$(su postgres -c "${psql_bin} -tAX -c 'SHOW server_version_num'" 2>/dev/null | tr -d '[:space:]')"
    [[ -z "$num" ]] && { echo ""; return 1; }
    echo $(( num / 10000 ))
}

# -----------------------------------------------------------------------------
# postgres_meets_minimum
#   0 si el servidor en ejecución satisface el mínimo de la referencia.
#   Imprime el diagnóstico; no decide qué hacer con él.
# -----------------------------------------------------------------------------
postgres_meets_minimum() {
    local major
    major="$(postgres_server_major)"
    if [[ -z "$major" ]]; then
        echo "DESCONOCIDO: el servidor no responde o falta psql"
        return 1
    fi
    if (( major < POSTGRES_MIN_MAJOR )); then
        echo "PostgreSQL ${major} < mínimo efectivo ${POSTGRES_MIN_MAJOR}" \
             "(referencia 13 · Django 6 exige 14)"
        return 1
    fi
    echo "PostgreSQL ${major} (mínimo efectivo: ${POSTGRES_MIN_MAJOR}" \
         "— referencia 13, Django 6 exige 14)"
    return 0
}

# -----------------------------------------------------------------------------
# postgres_wait_ready <timeout_segundos>
#   Espera activa a que el servidor responda. 0 si respondió, 1 si expiró.
# -----------------------------------------------------------------------------
postgres_wait_ready() {
    local timeout="${1:-20}"
    local i
    for (( i = 0; i < timeout; i++ )); do
        postgres_is_running && return 0
        sleep 1
    done
    return 1
}

# -----------------------------------------------------------------------------
# postgres_start
#   Arranca el servidor. Idempotente: si ya responde, no hace nada.
#
#   Dos vías, igual que ``mariadb_start``: systemd cuando está disponible, y
#   ``pg_ctlcluster`` directo cuando no (el caso del contenedor de este
#   proyecto — ver ADR-008 para el precedente de MariaDB sin systemd).
# -----------------------------------------------------------------------------
postgres_start() {
    if postgres_is_running; then
        return 0
    fi

    if command -v systemctl &>/dev/null && systemctl list-units --type=service &>/dev/null; then
        systemctl start postgresql 2>/dev/null || true
        postgres_wait_ready 20 && return 0
    fi

    # Sin systemd: arrancar el cluster por su versión mayor instalada.
    if command -v pg_ctlcluster &>/dev/null && command -v pg_lsclusters &>/dev/null; then
        local ver name
        # Primera columna = versión, segunda = nombre del cluster.
        read -r ver name _ < <(pg_lsclusters --no-header 2>/dev/null | head -1)
        if [[ -n "${ver:-}" && -n "${name:-}" ]]; then
            pg_ctlcluster "$ver" "$name" start 2>/dev/null || true
            postgres_wait_ready 20 && return 0
        fi
    fi

    return 1
}

# -----------------------------------------------------------------------------
# postgres_ensure_hba_socket <rol>
#   Garantiza que <rol> pueda autenticar con contraseña POR SOCKET.
#   Idempotente: si la regla ya está, no toca nada. Requiere root.
#
#   Por qué existe como función y no inline en el provisioner: el mismo
#   problema aparece para CADA rol que conecte por socket, no sólo para el de
#   la aplicación. ``backup_postgres.sh --setup-user`` creó su rol sin la
#   regla y pg_dump falló con "Peer authentication failed" — el mismo H-DB-05
#   una segunda vez, en otro script. Un rol nuevo sin regla es el modo de
#   fallo por defecto de este motor en Debian, así que la cura vive junto a la
#   creación de roles, no copiada en cada consumidor. Ver H-DB-08.
#
#   El pg_hba de Debian trae ``local all all peer``; ``peer`` exige que el
#   usuario del SISTEMA se llame igual que el rol. La regla nueva va POR
#   ENCIMA de esa: pg_hba se evalúa en orden y la primera coincidencia gana,
#   así que ponerla después no tendría efecto.
#
#   NO se toca la línea de ``postgres``: su ``peer`` es lo que permite
#   administrar el motor sin contraseña.
# -----------------------------------------------------------------------------
postgres_ensure_hba_socket() {
    local rol="$1"
    local hba regla

    hba="$(su postgres -c 'psql -tAX -c "SHOW hba_file"' 2>/dev/null | tr -d '[:space:]')"
    if [[ -z "$hba" || ! -f "$hba" ]]; then
        echo "No se pudo localizar pg_hba.conf"
        return 1
    fi

    if grep -qE "^local[[:space:]]+all[[:space:]]+${rol}[[:space:]]" "$hba"; then
        echo "Regla de socket ya presente para ${rol}"
        return 0
    fi

    regla="local   all             ${rol}                            scram-sha-256"
    awk -v regla="$regla" '
        !hecho && /^local[[:space:]]+all[[:space:]]+all[[:space:]]/ { print regla; hecho = 1 }
        { print }
    ' "$hba" > "${hba}.nuevo" && mv "${hba}.nuevo" "$hba"
    chown postgres:postgres "$hba"
    chmod 640 "$hba"
    su postgres -c "psql -tAX -c 'SELECT pg_reload_conf()'" >/dev/null 2>&1

    echo "Regla de socket añadida para ${rol} y configuración recargada"
    return 0
}
