```yml
name: db-postgres
description: "Skill de tecnología para PostgreSQL en kaupamex. Usar cuando se instale o arranque el motor, se creen bases/roles, se escriban migraciones o SQL crudo, o se diagnostique una conexión contra PostgreSQL. Cubre: el modelo de nombres (database vs schema vs rol), los binarios reales y los envoltorios de Debian, el mínimo de versión efectivo, respaldo/restauración, y las diferencias de dialecto frente a MariaDB. Invocar en Phase 7 DESIGN/SPECIFY para especificar schema, en Stage 10 IMPLEMENT para migraciones y provisioning, y en Phase 11 TRACK/EVALUATE para verificar índices y planes."
layer: db
framework: postgresql
project: kaupamex
allowed-tools: Read Glob Grep Bash
stack:
  - PostgreSQL 16 (del distro Ubuntu 24.04)
  - postgresql-common (envoltorios pg_wrapper / pg_*cluster)
  - Django 6 + psycopg
```

# DB PostgreSQL — SKILL

Guía por fases para trabajar con PostgreSQL en kaupamex. Es el hermano de
`db-mysql`, no su reemplazo: **MariaDB sigue siendo el motor en uso**; este
skill gobierna el motor que la referencia usa y hacia el que la iniciativa
`migrar-motor-mariadb-a-postgresql` se dirige.

**Es abstracto a propósito.** Un skill de motor escrito como recetario de
comandos envejece con la versión y con el sistema de paquetes. Lo que sigue
fija primero los **conceptos que cambian de significado entre motores** —ahí es
donde se cometen los errores caros— y sólo después los comandos, siempre
marcando cuál es del motor y cuál del empaquetado de Debian.

---

## 0. El modelo de nombres — lo primero que hay que traducir

Tres palabras significan cosas distintas en cada motor. Confundirlas produce un
provisioner que crea el objeto equivocado y un `GRANT` que no protege nada.

| Concepto | MariaDB | PostgreSQL |
|---|---|---|
| Unidad de aislamiento que la app ve como "la base" | **schema** (`CREATE DATABASE` es su sinónimo) | **database** (`CREATE DATABASE`) |
| Espacio de nombres **dentro** de esa unidad | no existe | **schema** (`public` por defecto) |
| Identidad que se conecta | **user** (`'u'@'host'`) | **rol** con `LOGIN` — no lleva host en el nombre |
| Alcance del `GRANT` | por schema | por database **y** por schema **y** por objeto |

Consecuencia operativa: nuestros dos schemas de MariaDB (`practicayoruba_db`,
`practicayoruba_qa`) se convierten en dos **databases** de PostgreSQL, no en dos
schemas de una sola. Y el rol necesita `GRANT ALL ON SCHEMA public` explícito
—ver §4— o el ORM falla en la primera migración.

## 1. Los binarios — y cuáles NO son del motor

Medido en este entorno (`ls /usr/lib/postgresql/16/bin/`): **33** ejecutables
instalados, de los cuales **19** quedan expuestos en `PATH` por los symlinks de
`pg_wrapper` (`/usr/bin/psql -> ../share/postgresql-common/pg_wrapper`).

*Métrica:* presencia en `PATH` (`command -v`) de cada nombre del `bindir` de la
versión 16. *Ciega a:* binarios de otras versiones instaladas en paralelo — el
wrapper resuelve la versión por cluster, así que `psql` puede no ser el 16 si
hubiera dos.

**Los 14 que NO están en `PATH`** — se invocan por ruta absoluta o, mejor, no se
invocan: `initdb` · `pg_ctl` · `postgres` · `pg_upgrade` · `pg_rewind` ·
`pg_resetwal` · `pg_controldata` · `pg_checksums` · `pg_verifybackup` ·
`pg_waldump` · `pg_amcheck` · `pg_test_fsync` · `pg_test_timing` · `oid2name`.

Que `initdb`, `pg_ctl` y `postgres` estén fuera del `PATH` **no es un accidente**:
Debian los sustituye por envoltorios de cluster. Esta es la diferencia estructural
más grande frente a MariaDB, donde arrancamos `mariadbd` a mano con `nohup`
(`scripts/start_db.sh`).

| Tarea | MariaDB (aquí) | PostgreSQL (Debian) |
|---|---|---|
| Crear la instancia | `mariadb-install-db` | `pg_createcluster <ver> main` |
| Arrancar / parar | `mariadbd` con `nohup` | `pg_ctlcluster <ver> main start` |
| Ver qué hay | `ps` + `mariadb-admin ping` | `pg_lsclusters` |
| Tocar la config | editar el `.cnf` | `pg_conftool <ver> main set …` |
| Subir de versión | dump + restore | `pg_upgradecluster` |

**Regla:** en Debian/Ubuntu se opera por **cluster**, no por proceso. Un
`nohup postgres …` a mano deja el cluster fuera del registro de
`postgresql-common` y `pg_lsclusters` deja de decir la verdad.

Los que sí se usan a diario: `psql` (cliente), `pg_isready` (probe de
disponibilidad — es el análogo de `mariadb-admin ping`), `createdb`/`createuser`/
`dropdb`/`dropuser` (envoltorios de los `CREATE …`), `pg_dump`/`pg_dumpall`/
`pg_restore` (respaldo), `vacuumdb`/`reindexdb`/`clusterdb` (mantenimiento),
`pgbench` (carga).

## 2. Versión mínima — se verifica, no se pinea

No se fija un número de versión en el provisioning: se instala **el del distro**
y se **verifica** contra un mínimo, igual que hace la referencia (su
`debian/control` declara `postgresql` sin número).

El mínimo efectivo es el **mayor** de los que nos atan, no el de la referencia
solo:

| Quién lo impone | Mínimo | Dónde | Qué pasa por debajo |
|---|---|---|---|
| la referencia | 13 | `odoo19c: odoo/release.py:41` | avisa en cada arranque |
| **nuestro ORM** | **14** | `django/db/backends/postgresql/features.py:10` | **aborta la conexión** |

Ver H-DB-03. El gate vive en `utils/postgresql.sh::postgres_meets_minimum`
(`POSTGRES_MIN_MAJOR`, default 14).

## 3. Stage 3 DIAGNOSE — qué investigar antes de tocar el schema

Lo que `db-mysql` pide (tablas, relaciones, volumen, queries, índices) sigue
aplicando. Se añade lo que sólo existe aquí:

- **¿El tipo tiene equivalente nativo?** `JSONB` (no `JSON` de texto), arreglos,
  `UUID`, rangos, `citext`. Elegir el nativo evita emulaciones que después
  bloquean el índice.
- **¿El índice correcto es B-tree?** GIN para `JSONB`/arreglos/búsqueda de texto;
  GiST para rangos y geometría; parcial (`WHERE`) cuando la selectividad viene de
  un predicado fijo. En MariaDB la respuesta era casi siempre B-tree o FULLTEXT;
  aquí no.
- **¿Necesita extensión?** `pg_trgm`, `unaccent`, `citext` requieren
  `CREATE EXTENSION` — es DDL, va en migración, y **necesita privilegio**.
- **Búsqueda de texto:** el `FULLTEXT INDEX` de MariaDB no existe. El equivalente
  es `tsvector` + índice GIN, con `to_tsvector('spanish', …)`.

## 4. Phase 7 DESIGN/SPECIFY — qué especificar

Por cada tabla nueva o modificada, además de lo de `db-mysql`:

- **Sin charset por tabla.** El encoding es de la **database** (`UTF8`), no de la
  tabla ni de la columna. No hay `utf8mb4` que declarar; la `COLLATE` sí existe,
  pero por columna y sólo cuando el orden lo exige.
- **Identidad:** `GENERATED BY DEFAULT AS IDENTITY` es el estándar; `SERIAL` es
  el legado. Django emite lo que corresponda — no escribirlo a mano en una
  migración salvo que se sepa por qué.
- **`GRANT` del rol de aplicación**, explícito y mínimo. Desde PostgreSQL 15 el
  esquema `public` **ya no** está concedido a `PUBLIC`, así que sin esto el ORM
  falla en la primera migración::

      GRANT ALL ON SCHEMA public TO <rol>;

- **Plantilla al crear la base:** `TEMPLATE template0` cuando se fija encoding o
  collation — `template1` puede llevar objetos locales heredados.

## 5. Stage 10 IMPLEMENT — migraciones

La diferencia que más cambia el procedimiento frente a MariaDB:

| | MariaDB | PostgreSQL |
|---|---|---|
| `can_rollback_ddl` | **False** | **True** (`features.py:31`) |
| Granularidad atómica real | **la operación**, no la migración | **la migración completa** |
| Migración a medias posible | sí — de ahí `proc-escribir-migraciones` | no: o toda o ninguna |

Es decir: `proc-escribir-migraciones.rst` (R-1 … R-5) existe **por una
limitación de MariaDB**. Bajo PostgreSQL sus reglas siguen siendo buena higiene
—una operación por migración se revisa mejor— pero dejan de ser la defensa
contra un estado a medias, porque el `BEGIN … ROLLBACK` del DDL lo cubre.

Orden recomendado:

1. Migración de **schema** (DDL), separada de la de **datos** (`RunPython`).
2. Índices de tablas grandes en su propia migración. Si el bloqueo importa:
   `CREATE INDEX CONCURRENTLY` — pero exige `atomic = False` en la migración,
   porque no corre dentro de transacción.
3. Verificar la estructura: `\d+ tabla` en `psql` (equivalente de
   `SHOW CREATE TABLE`).
4. `RunPython` con `reverse_code` siempre que el dato lo permita.

**SQL crudo en migraciones:** hoy hay **1** (`api: src/addons/base/migrations/
0004_resdevice.py`), y su docstring documenta dos adaptaciones de dialecto
MariaDB que **se revierten** al migrar — `<=>` vuelve a
`IS NOT DISTINCT FROM`, que es la forma de la referencia. Es el ejemplo canónico
de que el dialecto es una traducción reversible, no una reescritura.

## 6. Phase 11 TRACK/EVALUATE — qué revisar al cerrar

- `EXPLAIN (ANALYZE, BUFFERS)` en las queries nuevas — no `EXPLAIN` a secas: sin
  `ANALYZE` es el plan estimado, no el ejecutado.
- Toda FK con índice explícito. **PostgreSQL tampoco lo crea solo** — igual que
  MariaDB, no es una diferencia.
- `pg_stat_user_tables` para secuencial vs índice; `pg_stat_activity` para
  conexiones colgadas.
- Sin `SELECT *` en código de producción.
- Credenciales por variable de entorno; el rol de aplicación **no** es superusuario
  ni dueño de la base si se puede evitar.
- Respaldo verificado: `pg_dump -Fc` (formato custom, restaurable selectivamente
  con `pg_restore`) sobre `pg_dumpall` cuando se respalda una sola base.

## 7. Comandos verificados en este entorno

```bash
# Estado del cluster y del servidor
pg_lsclusters                      # Ver Cluster Port Status Owner …
pg_isready                         # /var/run/postgresql:5432 - accepting connections

# Provisioning del repo (idempotente, ver kaupamex-db/CLAUDE.md)
sudo bash provisioners/postgresql/install.sh
sudo bash provisioners/postgresql/db_setup.sh [--qa]

# Gate de versión mínima, aislado
source utils/logging.sh; source utils/postgresql.sh; postgres_meets_minimum
```

El socket vive en `/var/run/postgresql/.s.PGSQL.5432` (owner `postgres`) — no en
`/run/mysqld/`. El puerto es 5432, no 3306.

## Relación con otros artefactos

- `db-mysql` — el skill del motor **en uso**; sigue vigente mientras la migración
  no se ejecute.
- `kaupamex-db: utils/postgresql.sh` — las funciones que este skill describe.
- `docs: source/normativa/procedimientos/proc-escribir-migraciones.rst` — la
  política de migraciones cuyo motivo (DDL no transaccional) desaparece aquí.
- `docs: …/pm/db/iniciativas/migrar-motor-mariadb-a-postgresql/` — la iniciativa
  que consume este skill.
- `docs: …/pm/db/iniciativas/provisionar-postgresql-db/` — el provisioning y
  H-DB-02.
