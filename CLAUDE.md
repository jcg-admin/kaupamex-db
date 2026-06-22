# CLAUDE.md — e-commerce-db

Submódulo **db** del monorepo PracticaYoruba (repo GitHub `jcg-admin/e-commerce-db`).
Base de datos de PracticaYoruba sobre **MariaDB 11.8 LTS**, provisionada con bash +
python-dotenv (sin Vagrant, sin PostgreSQL). Cheat-sheet local — no duplica el gobierno
del padre.

## Gobernanza

Las reglas no negociables viven en el superproyecto, no aquí:

- `../e-commerce/.claude/CLAUDE.md` — contexto persistente (Level 2).
- `../e-commerce/.claude/rules/` — reglas cargadas en cada sesión. En particular:
  - `commit-conventions.md` — **Tim Pope**: subject imperativo ≤50 ch, capitalizado,
    sin punto; body explica QUÉ y POR QUÉ.
  - `timestamps-iso8601-obligatorios.md` — nunca escribir timestamps a mano:
    `date -u +"%Y-%m-%dT%H:%M:%S"`.
  - `react-verification-gate.md` — toda afirmación de estado deriva de una
    Observation real ejecutada en el turno; nunca del resultado esperado.
  - `calibration-verified-numbers.md` — ningún número sin verificar.

## Comandos

Todos leen variables desde `.env` en la raíz del repo (copiar de `.env.example`).
Esquema socket-primero, fallback TCP `127.0.0.1:3306`.

- `bash scripts/start_db.sh` — arranque de MariaDB **sin systemd** (idempotente).
  Si ya responde, informa y sale. Si no: limpia pid/sock stale, arranca `mariadbd`
  con `nohup su mysql`, espera activa máx. 20×1s y corre `verify.sh`. `--no-verify`
  arranca sin verificar.
- `bash scripts/verify.sh` — verificación del entorno. El total de checks se calcula
  dinámicamente (`grep -c` sobre el propio script): hoy **11 checks** (`.env`, CLI,
  versión 11.8, MariaDB responde, schemas db/qa + django_migrations, privilegios DML
  django_user en db/qa, funciones/vistas/SPs SQL). Imprime resumen `OK: N`,
  `Advertencias: N`, `Errores: N`; exit 1 si hay errores.
- `bash scripts/backup_db.sh` — dump comprimido (gzip -6) de ambos schemas con
  checksum MD5 y retención (`BACKUP_RETENTION_DAYS`, default 30). Usa `py_backup_user`
  (no root) con privilegios mínimos, creado idempotente. Timestamp TZ `America/Mexico_City`.
- `python3 scripts/check_db.py` — verificación Python (mysqlclient + python-dotenv) de
  conectividad y privilegios DML de django_user en ambos schemas, y de
  `django_migrations` / `users_user`. Requiere `pip install -r requirements.txt`
  (mysqlclient==2.2.1) y `libmysqlclient-dev`.
- `bash provisioners/mariadb/deploy_objetos.sh` — despliega 3 funciones + 3 vistas +
  3 SPs + seed en `practicayoruba_db` (idempotente, `CREATE OR REPLACE` / `INSERT IGNORE`;
  migra nombres español→inglés). Requiere migraciones Django ya aplicadas.
- `bash provisioners/mariadb/db_setup.sh` / `db_qa_setup.sh` — crean schema + django_user
  (idempotente). `install.sh` instala/pinea MariaDB 11.8.x.

## Convenciones locales / gotchas

- **Socket Unix** `/run/mysqld/mysqld.sock` es la ruta canónica (verificado: owner
  `mysql`). Los scripts intentan socket primero, luego TCP.
- **`mariadb-admin`, no `mysqladmin`.** En MariaDB 11.8 / Ubuntu 24.04 los aliases
  legacy ya no se instalan; `utils/database.sh::mariadb_admin_bin` resuelve
  `mariadb-admin` (canónico) con fallback a `mysqladmin`.
- **`--tmpdir`** en `start_db.sh:80` es `${MARIADB_TMPDIR:-/tmp}` (default `/tmp`). En
  este contenedor `TMPDIR=/tmp/claude-0` no es escribible por `mysql` e InnoDB abortaría;
  el default `/tmp` lo evita. Exportar `MARIADB_TMPDIR` solo si se necesita otro path.

## Estructura

```
provisioners/mariadb/   db_setup.sh, db_qa_setup.sh, install.sh, deploy_objetos.sh,
                        seed_catalogo.sql
  objetos/funciones/    fn_price_with_tax, fn_stock_status, fn_qualifies_free_shipping
  objetos/vistas/       v_published_catalog, v_featured_products, v_low_stock
  objetos/sps/          sp_rpt_catalog_by_category, sp_rpt_low_stock, sp_rpt_catalog_summary
scripts/                start_db.sh, verify.sh, backup_db.sh, check_db.py, …
utils/                  core.sh, database.sh, logging.sh, network.sh, validation.sh
config/mariadb/         99-practicayoruba.cnf
```

## Schemas y usuario

- `practicayoruba_db` — producción/desarrollo (charset utf8mb4, collate utf8mb4_unicode_ci).
- `practicayoruba_qa` — testing.
- `django_user` — usuario de aplicación; en db recibe `SELECT, INSERT, UPDATE, DELETE,
  CREATE, ALTER, DROP, INDEX, REFERENCES` (más `ALL` sobre `test_practicayoruba_db` para pytest).
