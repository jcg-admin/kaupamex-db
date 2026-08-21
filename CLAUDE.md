# CLAUDE.md — kaupamex-db

Submódulo **db** del monorepo PracticaYoruba (repo GitHub `jcg-admin/kaupamex-db`).
Base de datos, provisionada con bash + python-dotenv (sin Vagrant).
Cheat-sheet local — no duplica el gobierno del padre.

**El motor es PostgreSQL** (`docs: source/backend/adr/adr-028-postgresql.rst`,
supersede ADR-009). Mínimo efectivo **14** — el mayor de los dos mínimos que atan al
proyecto: la referencia declara 13 (`odoo19c: odoo/release.py:41`, que avisa) y
Django 6 declara 14 (`django/db/backends/postgresql/features.py:10`, que **aborta**
la conexión). Bases `kaupamex_core` (prod/dev) y `kaupamex_core_qa` (tests), rol
`django_user`. Desarrollo y pruebas ya corren ahí: suite api **2 235 passed,
5 skipped, 0 failed** contra PostgreSQL 16.13 (2026-08-06).

**`provisioners/mariadb/` sigue en el repo, y ya no hay razón operativa para
ello.** Hasta el 2026-08-06 este párrafo decía que producción seguía en MariaDB
hasta el corte. **Es falso**: la VM se eliminó y no se considera activa
(directiva del ejecutor). El próximo despliegue se levanta con PostgreSQL +
Gunicorn embebido, como aplicación autocontenida Django + DRF.

Lo que queda del motor viejo —`provisioners/mariadb/`, `start_db.sh`,
`verify.sh`, `backup_db.sh`, `check_db.py`— **no sirve a ningún entorno**. Sigue
en el repo porque hay documentos, reglas y el runbook E2E de `ui` que lo citan,
no porque algo lo ejecute. Retirarlo es una decisión pendiente del ejecutor, no
un olvido: la alternativa a borrarlo es limpiar primero las citas.

El análisis que fundó el cambio: `analisis-postgres-only-vs-mariadb.rst` y
`reporte-costo-mariadb-vs-postgres-2026-08-06.rst` en docs.

## Gobernanza

Las reglas no negociables viven en el superproyecto, no aquí:

- `../kaupamex/.claude/CLAUDE.md` — contexto persistente (Level 2).
- `../kaupamex/.claude/rules/` — reglas cargadas en cada sesión. En particular:
  - `commit-conventions.md` — **Tim Pope**: subject imperativo ≤50 ch, capitalizado,
    sin punto; body explica QUÉ y POR QUÉ.
  - `timestamps-iso8601-obligatorios.md` — nunca escribir timestamps a mano:
    `date -u +"%Y-%m-%dT%H:%M:%S"`.
  - `react-verification-gate.md` — toda afirmación de estado deriva de una
    Observation real ejecutada en el turno; nunca del resultado esperado.
  - `calibration-verified-numbers.md` — ningún número sin verificar.

**Los githooks se activan por clon, y no se activan solos.** `core.hooksPath`
vive en `.git/config`, que **no se versiona**: un clon nuevo tiene los dos
hooks escritos en `.githooks/` y git no los mira. Primer comando tras clonar:

```bash
bash scripts/install-hooks.sh        # git config core.hooksPath .githooks
git config core.hooksPath            # debe imprimir .githooks
```

`commit-msg` valida el subject Tim Pope; `pre-commit` exige `set -euo pipefail`
en los `*.sh` en *staging*. Sin el config, los dos están saltados por omisión —
sin `--no-verify` de por medio y sin nada en el árbol que lo delate. Ver
H-DOCS-249 en `docs: pm/docs/iniciativas/integrar-referencia-how-claude-code-works/hallazgos/`.

## Comandos

Todos leen variables desde `.env` en la raíz del repo (copiar de `.env.example`).
Esquema socket-primero, fallback TCP.

### PostgreSQL — el motor en uso

Nombres explícitos, no genéricos: `start_db.sh`/`verify.sh`/`backup_db.sh` se
quedan con MariaDB porque están citados en docs, reglas y el runbook E2E de `ui`.
Mismo criterio que `utils/postgresql.sh` junto a `utils/database.sh`.

- `bash scripts/start_postgres.sh` — arranque idempotente. Si ya responde,
  informa y sale. Si no, arranca el **cluster** (systemd si está; si no,
  `pg_ctlcluster`) y **verifica el mínimo efectivo (14)** antes de seguir:
  Django 6 aborta la conexión por debajo, no avisa. `--no-verify` omite el
  verify. NO replica el `nohup mariadbd` — en Debian se opera por cluster, y
  `initdb`/`pg_ctl` no están en `PATH` a propósito.
- `bash scripts/verify_postgres.sh` — **9 checks** (conteo dinámico): `.env`,
  CLI, servidor responde, mínimo efectivo, ambas bases + `django_migrations`,
  rol `LOGIN`+`CREATEDB`, **autenticación por socket** y extensiones. El check
  de socket es el que atrapa H-DB-05: un fallo de credenciales y uno de método
  de autenticación se ven idénticos desde la aplicación.
- `bash scripts/backup_postgres.sh` — `pg_dump -Fc` (comprimido nativo, sin
  `| gzip`) de ambas bases + SHA-256, verificado con `pg_restore --list` — un
  archivo íntegro puede no ser un dump válido, y el checksum solo no distingue
  esos dos casos. Retención `BACKUP_RETENTION_DAYS` (30).
  `sudo bash scripts/backup_postgres.sh --setup-user` crea el rol de respaldo
  con `pg_read_all_data` (PG 14+) — lectura de todo, escritura de nada.

### MariaDB — sin entorno al que aplicarse (ver arriba)

- `bash scripts/start_db.sh` — arranque de MariaDB **sin systemd** (idempotente).
  Si ya responde, informa y sale. Si no: limpia pid/sock stale, arranca `mariadbd`
  con `nohup su mysql`, espera activa máx. 20×1s y corre `verify.sh`. `--no-verify`
  arranca sin verificar.
- `bash scripts/verify.sh` — verificación del entorno. El total de checks se calcula
  dinámicamente (`grep -c` sobre el propio script): hoy **8 checks** (`.env`, CLI,
  versión 11.8, MariaDB responde, schemas db/qa + django_migrations, privilegios DML
  django_user en db/qa). Imprime resumen `OK: N`,
  `Advertencias: N`, `Errores: N`; exit 1 si hay errores.
- `bash scripts/backup_db.sh` — dump comprimido (gzip -6) de ambos schemas con
  checksum MD5 y retención (`BACKUP_RETENTION_DAYS`, default 30). Usa `py_backup_user`
  (no root) con privilegios mínimos, creado idempotente. Timestamp TZ `America/Mexico_City`.
- `python3 scripts/check_db.py` — verificación Python (mysqlclient + python-dotenv) de
  conectividad y privilegios DML de django_user en ambos schemas, y de
  `django_migrations` / `res_users`. Requiere `pip install -r requirements.txt`
  (mysqlclient==2.2.1) y `libmysqlclient-dev`.
- `bash provisioners/mariadb/db_setup.sh` / `db_qa_setup.sh` — crean schema + django_user
  (idempotente). `install.sh` instala/pinea MariaDB 11.8.x.
- `bash provisioners/postgresql/install.sh` — instala el PostgreSQL **del distro** y
  verifica el **mínimo efectivo**: el mayor entre el de la referencia (13,
  `odoo19c: odoo/release.py:41`) y el de nuestro ORM (**14**,
  `django/db/backends/postgresql/features.py:10` — aborta la conexión, no avisa).
  Ver H-DB-03. No pinea versión, igual que el `debian/control` de la referencia; en
  Ubuntu 24.04 resuelve a **16**. `--migrate` purga (destructivo).
- `bash provisioners/postgresql/db_setup.sh [--qa]` — crea **base** + **rol**
  (idempotente). Un archivo con flag, no dos como en MariaDB: la lógica es idéntica y
  duplicarla es cómo divergen dos scripts gemelos.

## Skill del motor

`.claude/skills/db-postgres/SKILL.md` — el skill de PostgreSQL: modelo de nombres
(database vs schema vs rol), los 33 binarios y por qué `initdb`/`pg_ctl`/`postgres`
**no** están en `PATH` (Debian opera por cluster: `pg_ctlcluster`, `pg_lsclusters`,
`pg_conftool`), el mínimo efectivo, y las diferencias de dialecto e índices frente a
MariaDB. Es el skill **del motor en uso**; `db-mysql` (que vive en `api`) queda como
referencia del motor retirado.

## Convenciones locales / gotchas

- **Socket Unix de PostgreSQL** — en libpq el socket **es el HOST**: `HOST` es el
  *directorio* (`/var/run/postgresql`) y `PORT` nombra el archivo
  (`.s.PGSQL.5432`). Un `Peer authentication failed` no es de credenciales: el
  `pg_hba.conf` de Debian asigna `peer` al canal local (H-DB-05).
- **Socket Unix de MariaDB** `/run/mysqld/mysqld.sock` es la ruta canónica del
  motor viejo (verificado: owner `mysql`). Los scripts intentan socket primero,
  luego TCP. Sólo aplica a los scripts de MariaDB, que ya no sirven a ningún
  entorno.
- **`mariadb-admin`, no `mysqladmin`.** En MariaDB 11.8 / Ubuntu 24.04 los aliases
  legacy ya no se instalan; `utils/database.sh::mariadb_admin_bin` resuelve
  `mariadb-admin` (canónico) con fallback a `mysqladmin`.
- **`--tmpdir`** en `start_db.sh:80` es `${MARIADB_TMPDIR:-/tmp}` (default `/tmp`). En
  este contenedor `TMPDIR=/tmp/claude-0` no es escribible por `mysql` e InnoDB abortaría;
  el default `/tmp` lo evita. Exportar `MARIADB_TMPDIR` solo si se necesita otro path.

## Estructura

```
provisioners/mariadb/   db_setup.sh, db_qa_setup.sh, install.sh
  data/                 sepomex-codigos-postales.txt
provisioners/postgresql/ install.sh, db_setup.sh (--qa para la base de pruebas)
scripts/                start_postgres.sh, verify_postgres.sh, backup_postgres.sh
                        start_db.sh, verify.sh, backup_db.sh (MariaDB), check_db.py, …
  db-client/            verificación SSL/privilegios contra la VM de producción
utils/                  core.sh, database.sh (MariaDB), postgresql.sh, logging.sh,
                        network.sh, validation.sh
config/mariadb/         99-practicayoruba.cnf
```

## Bases y rol (PostgreSQL)

En PostgreSQL lo que MariaDB llamaba *schema* es una **base**; un *schema* es un
namespace **dentro** de una base (el default es `public`).

- `kaupamex_core` — producción/desarrollo (encoding `unicode`, `TEMPLATE template0`).
- `kaupamex_core_qa` — testing.
- `django_user` — rol de aplicación, `LOGIN CREATEDB` + `GRANT ALL ON SCHEMA public`.
  `CREATEDB` es un atributo **global** del rol: no admite acotar por patrón de
  nombre como el `GRANT ... company\_%` de MariaDB (H-DB-06). Desde PG 15 el schema
  `public` ya no se otorga a `PUBLIC`, de ahí el `GRANT` explícito.
- Las bases por empresa (`company_<N>_db`) las crea la app, con `pg_trgm` y
  `unaccent` instaladas al crearlas.

**Motor viejo (sin entorno activo):** schemas `practicayoruba_db` /
`practicayoruba_qa` en MariaDB, charset `utf8mb4`, collate `utf8mb4_unicode_ci`.

## Lo que este submódulo NO lleva (y por qué)

Los objetos SQL de negocio —3 funciones, 3 vistas, 3 stored procedures,
`deploy_objetos.sh` y `seed_catalogo.sql`— se **eliminaron**, no se archivaron.
Medido sobre `odoo-tools@622ddc2a`: la referencia tiene **0**
`CREATE PROCEDURE`/`FUNCTION` en sus 78 `.sql`, y declara sus vistas como
**modelo Python** con `_auto = False` + `_table_query` (39 archivos; el
`CREATE VIEW` lo emite el ORM, `odoo/addons/base/models/res_device.py:233`).
No estaban desactualizados: su **forma** contradice la referencia, así que
archivarlos los dejaría como tentación de reintroducirlos.

Servían al addon `reports` de `api`, borrado en `api@115d219`; a HEAD tenían
**0 consumidores** en `src/`. Igual se eliminaron `scripts/mapping/` (leía 18
tablas, todas de familias muertas) y `scripts/fase5c/` (provisioning de una VM
concreta, 0 invocadores). El git log conserva los tres. Ver H-DB-01.

**Si vuelve a hacer falta una vista de reporte:** se declara como modelo Python
en el addon dueño con `_auto = False`, no como `.sql` versionado aquí.
