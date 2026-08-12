# docs/operaciones.md

Runbook de operaciones de **kaupamex-db**.

> **Reescrito 2026-08-12 (tarea #249, H-SERVER-11).** La versión anterior
> era un runbook de MariaDB: 70 menciones al motor retirado, 8 al par de
> schemas `practicayoruba_*` y 8 a `/opt/practicayoruba/`, más una sección
> completa sobre un fixture de pytest que ya no existe. Barrer sólo las
> rutas —el eje barato— lo habría sacado de la lista de pendientes dejando
> declarado el motor equivocado, que es lo que
> `porte-completo-no-parcial.md` prohíbe.

## Identidad — L0, L1 y el nombre del repo

Tres capas que la versión anterior de este archivo colapsaba en una:

- **Kaupamex es el producto y el operador L0.** Da nombre a la
  infraestructura: bases `kaupamex_db` / `kaupamex_qa`, rutas de
  despliegue `/opt/kaupamex/`, repos `kaupamex-{api,db,docs,server,ui}`.
- **PracticaYoruba es una empresa L1** — la de ejemplo, no el producto.
  Un e-commerce es lo que hace un L1, nunca la plataforma entera.
- **kaupamex-db** es este repositorio (`jcg-admin/kaupamex-db`).

Canon: `.claude/rules/terminologia-l0-company.md`, DEC-KX-05, DEC-KX-06 y
ADR-021. Las apariciones de `practicayoruba` que **sí** son correctas hoy
son las de la empresa L1; en **infraestructura** (nombre de base, ruta de
despliegue, dominio de plataforma) son drift y se corrigen al encontrarlas.

## Motor: PostgreSQL

**ADR-028** (`docs: source/backend/adr/adr-028-postgresql.rst`) supersede a
ADR-009. Mínimo efectivo **14** — el mayor de los dos mínimos que atan al
proyecto:

| Fuente | Mínimo | Qué hace por debajo |
|---|---|---|
| La referencia (`odoo19c: odoo/release.py:41`) | 13 | avisa |
| Django 6 (`django/db/backends/postgresql/features.py:10`) | **14** | **aborta la conexión** |

En Ubuntu 24.04 el paquete del distro resuelve a **16**; el cluster de este
contenedor vive en `/var/lib/postgresql/16/main`.

**Base ≠ schema.** Lo que MariaDB llamaba *schema* aquí es una **base**; un
*schema* es un namespace **dentro** de ella (el default es `public`).

| Objeto | Nombre | Para qué |
|---|---|---|
| Base | `kaupamex_db` | producción / desarrollo |
| Base | `kaupamex_qa` | testing (`config.settings.testing`) |
| Rol | `django_user` | aplicación — `LOGIN CREATEDB` + `GRANT ALL ON SCHEMA public` |
| Extensiones | `unaccent`, `pg_trgm` | instaladas en ambas bases al provisionar |

`CREATEDB` es un atributo **global** del rol: no admite acotarlo por patrón
de nombre como el `GRANT … company\_%` de MariaDB. Lo necesita para las
bases por empresa (`company_<N>_db`), que crea la aplicación. Ver H-DB-06 y
la tarea #117 (evaluar la separación en dos roles).

---

## Configuración inicial (una vez por servidor)

```bash
# 1. Clonar el repositorio
git clone <repo>
cd kaupamex-db

# 2. Crear .env desde la plantilla
cp .env.example .env
# Editar .env con las credenciales reales del servidor

# 3. Instalar PostgreSQL del distro y verificar el mínimo efectivo
sudo bash provisioners/postgresql/install.sh

# 4. Provisionar ambas bases — un solo script con flag, no dos gemelos
sudo bash provisioners/postgresql/db_setup.sh          # kaupamex_db
sudo bash provisioners/postgresql/db_setup.sh --qa     # kaupamex_qa
```

`install.sh` **no pinea versión**, igual que el `debian/control` de la
referencia — verifica el mínimo y acepta lo que el distro traiga. Su flag
`--migrate` **purga el cluster**: es destructivo.

`db_setup.sh` requiere superusuario para el paso de extensiones: el owner
de la base no puede `CREATE EXTENSION` por sí mismo.

---

## Arrancar el motor

En Debian/Ubuntu PostgreSQL **se opera por cluster**, no por proceso suelto.
`initdb`, `pg_ctl` y `postgres` **no están en `PATH` a propósito**;
`pg_wrapper` expone `pg_ctlcluster`, `pg_lsclusters` y `pg_conftool` en su
lugar. Por eso no hay equivalente del `nohup su mysql -c mariadbd` del motor
viejo, y buscarlo es el error más común al llegar desde MariaDB.

```bash
# Arranque idempotente + verificación
bash scripts/start_postgres.sh

# Sólo arrancar, sin correr verify_postgres.sh
bash scripts/start_postgres.sh --no-verify
```

El script usa systemd si está disponible y cae a `pg_ctlcluster` si no; y
**verifica el mínimo efectivo antes de seguir**, porque Django 6 aborta por
debajo de 14 en vez de avisar.

Comprobación manual mínima:

```bash
pg_isready          # /var/run/postgresql:5432 - accepting connections
pg_lsclusters       # estado del cluster
```

---

## Verificar el entorno

```bash
bash scripts/verify_postgres.sh
```

**9 checks** — el conteo no se hardcodea en el header: sale de
`grep -c '^check_'` sobre el propio script, así que añadir uno lo actualiza
solo.

| # | Check | Qué cubre |
|---|---|---|
| 1 | `check_env_vars` | claves `DB_*` en `.env` |
| 2 | `check_tools` | `psql`, `pg_dump`, `pg_isready` |
| 3 | `check_server_running` | el servidor responde |
| 4 | `check_minimum_version` | ≥ 14 (el mínimo efectivo) |
| 5-6 | `check_base_db` · `check_base_qa` | ambas bases + `django_migrations` |
| 7 | `check_rol_atributos` | `django_user` con `LOGIN` + `CREATEDB` |
| 8 | `check_socket_auth` | **autenticación por socket** |
| 9 | `check_extensiones` | `pg_trgm` y `unaccent` en ambas bases |

El check 8 es el que justifica el script: un fallo de credenciales y uno de
**método de autenticación** se ven idénticos desde la aplicación. Ver
"Diagnóstico" abajo.

Exit code 0 si todo está bien, 1 si hay errores — usable desde CI.

---

## Backup

```bash
# Crear el rol de respaldo (una vez, requiere root)
sudo bash scripts/backup_postgres.sh --setup-user

# Backup manual de ambas bases
bash scripts/backup_postgres.sh
```

El rol de respaldo recibe **`pg_read_all_data`** (rol predefinido desde
PG 14): lee todo, no escribe nada. En MariaDB eso exigía enumerar
`SELECT, SHOW VIEW, LOCK TABLES, EVENT, TRIGGER`.

Genera por ejecución en `backups/`:

```
YYYYMMDD_HHMMSS_kaupamex_db.dump
YYYYMMDD_HHMMSS_kaupamex_db.sha256
YYYYMMDD_HHMMSS_kaupamex_qa.dump
YYYYMMDD_HHMMSS_kaupamex_qa.sha256
```

Tres diferencias con el flujo de MariaDB, y las tres importan:

- **`pg_dump -Fc` comprime nativo** — no hay `| gzip`, y el `.dump` no es
  SQL plano: se restaura con `pg_restore`, no con `psql <`.
- **No hay `--single-transaction`**: `pg_dump` toma un snapshot MVCC por sí
  mismo, así que el dump ya es consistente.
- **La verificación es `pg_restore --list`, no sólo el checksum.** Un
  archivo íntegro puede no ser un dump válido; el `sha256` solo no
  distingue esos dos casos.

Timestamp en `America/Mexico_City`. Retención por
`BACKUP_RETENTION_DAYS` (default **30**).

### Cron automático (producción)

```bash
sudo bash scripts/setup_backup_cron.sh
```

Instala `/etc/cron.d/practicayoruba-backup`, que corre el backup diario a
las 02:00 (`America/Mexico_City`) como `svc-dbdata`.

Prerequisito: el bind mount
`/opt/kaupamex/backups/database → backups/` debe estar activo (ver "Bind
mount Clase C").

> **El nombre del archivo de cron y el del log siguen diciendo
> `practicayoruba`.** Es deliberado: renombrar
> `/etc/cron.d/practicayoruba-backup` y
> `/var/log/practicayoruba-backup.log` es una decisión de rename aparte —
> el mismo precedente con el que H-SERVER-08 dejó los nombres de vhost.
> Lo que **sí** se corrigió aquí es a qué script apunta el cron: instalaba
> `backup_db.sh` (MariaDB) mientras su propio comentario declaraba respaldar
> `kaupamex_db + kaupamex_qa`. Ver H-DB-09.

### Verificar un backup existente

```bash
cd backups/
sha256sum -c 20260812_020000_kaupamex_db.sha256
pg_restore --list 20260812_020000_kaupamex_db.dump | head
```

### Sincronización a S3 (opcional)

Definir `BACKUP_REMOTE_DEST=s3://bucket/ruta/` en `.env`. El script
sincroniza tras verificar la integridad.

### Variables `BACKUP_*` / `PY_BACKUP_*` — sólo en `db/.env`

Viven **únicamente** aquí y NO se replican en `api/src/.env`:

- `PY_BACKUP_USER`, `PY_BACKUP_PASSWORD` — el rol de respaldo.
- `BACKUP_DIR` — directorio destino de los dumps.
- `BACKUP_REMOTE_DEST` — URI de S3 / rclone.
- `BACKUP_RETENTION_DAYS` — días de retención.

La asimetría es intencional: `verify_env_sync.sh` compara sólo claves
`^DB_`, justamente para que la sincronización cross-repo no fuerce a
`api/.env` a llevar claves de backup que no consume.

---

## Diagnóstico

```bash
# ¿Responde?
pg_isready

# Estado del cluster (Debian opera por cluster)
pg_lsclusters

# Log del cluster
sudo tail -f /var/log/postgresql/postgresql-16-main.log

# Bases y rol
sudo -u postgres psql -c "\l kaupamex*"
sudo -u postgres psql -c "\du django_user"

# Conexión por socket como la aplicación
psql -h /var/run/postgresql -U django_user -d kaupamex_qa -c "SELECT 1"
```

### `Peer authentication failed` NO es un problema de credenciales

Es el gotcha que más tiempo cuesta al llegar desde MariaDB. El
`pg_hba.conf` por defecto de Debian asigna el método **`peer`** al canal
local: la misma contraseña que entra por TCP falla por socket, porque por
socket no se pide contraseña — se compara el usuario del sistema con el rol.

La regla del rol de aplicación va **por encima** de la genérica, y la
instala `provisioners/postgresql/db_setup.sh`. El check 8 de
`verify_postgres.sh` existe precisamente para distinguir este caso de un
fallo de credenciales. Ver H-DB-05.

### El socket **es** el HOST

En libpq no hay opción `unix_socket`: un `HOST` que empieza con `/` es el
**directorio** del socket (`/var/run/postgresql`) y el `PORT` nombra el
archivo (`.s.PGSQL.5432`). Por eso los settings de `api` resuelven
`'HOST': _DB_SOCKET or config('DB_HOST')`. Buscar la clave vieja de MySQL
devuelve `<NONE>` incluso conectando por socket — un falso negativo. Ver
H-API-305.

---

## Reprovisionar desde cero (idempotente)

```bash
sudo bash provisioners/postgresql/db_setup.sh
sudo bash provisioners/postgresql/db_setup.sh --qa
bash scripts/verify_postgres.sh
```

---

## Integración con la suite de `api`

`api` corre pytest contra **`kaupamex_qa`** con `config.settings.testing`
(`ENGINE = django.db.backends.postgresql`). `pytest.ini` declara
`--reuse-db`, así que la base **no** se recrea en cada corrida: es
compartida, y recrearla mientras otro agente corre la suite le rompe el run.

```bash
# 1. Motor arriba (desde este repo)
bash scripts/start_postgres.sh

# 2. Suite del subconjunto tocado (desde kaupamex-api)
cd ../kaupamex-api && uv run pytest tests/unit/<addon>/ -q --reuse-db
```

Baseline vigente: **2 235 passed, 5 skipped, 0 failed** contra PostgreSQL
16.13 (2026-08-06). La suite **completa no se corre por defecto** — sólo el
subconjunto que el cambio toca, o la pila entera cuando se toca un mecanismo
transversal (`test-execution-protocol.md`).

> **El fixture `mariadb_keepalive` ya no existe.** La versión anterior de
> este runbook dedicaba 60 líneas a su contrato. Medido 2026-08-12:
> `grep -c mariadb_keepalive api/tests/conftest.py` → **0**. Se retiró con
> el motor (H-API-384) y pytest ya no re-ejecuta ningún seeder. La sección
> se elimina en vez de traducirse: documentar el contrato de algo que no
> existe es peor que no documentarlo.

---

## Modelo cross-user de permisos

El proyecto opera bajo cinco cuentas del sistema heredadas del procedimiento
externo **Procedimiento-Implementacion-Almacenamiento-WSL2-ecomerce-p001
v1.0.0**. Para diagnosticar permisos de BD + servidor web + backups, la
relación cross-user es lo que hay que entender.

### Quién puede leer qué

| Recurso | Propietario | Perms | Quién más lee |
|---|---|---|---|
| `/opt/kaupamex/db/` (código) | `develop:develop` | 755/644 | todos vía "other" |
| `/opt/kaupamex/backups/database/` (dumps) | `svc-dbdata:svc-dbdata` | 755 | sólo `svc-dbdata` y root |
| `/opt/kaupamex/backups/project/` | `svc-backups:svc-backups` | 755 | sólo `svc-backups` y root |
| `/var/lib/postgresql/16/main/` (datadir) | `postgres:postgres` | 700 | sólo `postgres` y root |
| `/etc/ssl/practicayoruba/cert.pem` | `root:root` | 644 | todos (cert público) |
| `/etc/ssl/practicayoruba/key.pem` | `root:root` | 600 | sólo root |

`SSL_CERT_DIR` conserva el nombre del L1 porque está atado al **dominio
real** (`practicayoruba.mx`), no a la plataforma: es una decisión de DNS,
no de layout. Ese es el criterio que la separa de las rutas de despliegue,
que sí se migraron.

### Quién corre qué

- **Provisioners**: `deploy` con `sudo`. El cliente `psql` se invoca como
  `postgres` por socket (`sudo -u postgres psql`), no como `deploy`
  directo — por eso `psql -c …` como `deploy` falla y
  `sudo -u postgres psql -c …` funciona.
- **El motor**: como `postgres:postgres`. Lee sólo su datadir.
- **La aplicación**: **Gunicorn embebido**, arrancado por
  `kaupamex-bin server` bajo la unidad systemd `kaupamex.service`, con
  Apache como **proxy inverso** delante (ADR-027; H-SERVER-04 retiró
  mod_wsgi, así que ya no corre bajo `www-data` como módulo de Apache).
  Conecta con `django_user` leyendo `api/src/.env`, **por socket**
  (`/var/run/postgresql`), no por TCP.
- **Backups**: como `svc-dbdata`, vía `sudo -u svc-dbdata` desde el cron de
  root — la cuenta es `nologin`, así que no admite invocación interactiva.

### Bind mount Clase C → repo

`kaupamex-db` y `kaupamex-server` tienen un `backups/` que vive físicamente
fuera del checkout git (Clase C, owner `svc-dbdata`). Previene que un
`git clean -fdx` o un `git checkout` accidental destruyan los dumps:

```
/opt/kaupamex/backups/database/kaupamex-db     → /opt/kaupamex/db/backups
/opt/kaupamex/backups/database/kaupamex-server → /opt/kaupamex/server/backups
```

La configuración de `fstab` vive en el procedimiento de provisioning, NO en
estos scripts. Para un dump manual:

```bash
sudo -u svc-dbdata pg_dump -Fc kaupamex_db \
  > /opt/kaupamex/db/backups/dump-$(date -u +%Y-%m-%dT%H-%M-%SZ).dump
```

El dump aparece dentro del checkout pero `git status` lo ignora: `backups/`
está en el `.gitignore` del repo y el bind mount lo saca del árbol real.

### Troubleshooting cross-user típico

| Síntoma | Probable causa |
|---|---|
| `psql -c "…"` como `deploy` → *"role does not exist"* | falta `sudo -u postgres` (el canal local autentica por `peer`) |
| `Peer authentication failed for user "django_user"` | falta la regla del rol de aplicación **por encima** de la genérica en `pg_hba.conf` (H-DB-05) — no es la contraseña |
| `permission denied to create database` | al rol le falta el atributo global `CREATEDB` (H-DB-06) |
| La API responde 500 con `OperationalError` | el `.env` de `api` no es legible por el usuario del servicio, o el socket no existe |
| `pg_dump` falla por socket con *"Peer authentication"* | el rol de respaldo existe pero no tiene su regla en `pg_hba.conf` — lo instala `--setup-user` |

---

## Lo que queda de MariaDB, y por qué sigue aquí

`provisioners/mariadb/`, `scripts/start_db.sh`, `verify.sh`,
`backup_db.sh`, `check_db.py`, `utils/database.sh` y
`config/mariadb/99-practicayoruba.cnf` **no sirven a ningún entorno**. La VM
que los usaba se eliminó y no se considera activa; el próximo despliegue se
levanta con PostgreSQL + Gunicorn embebido.

Siguen en el repo porque hay documentos, reglas y el runbook E2E de `ui` que
los citan — no porque algo los ejecute. Retirarlos es una decisión pendiente
del ejecutor: **la alternativa a borrarlos es limpiar primero las citas.**

Sus nombres genéricos (`start_db.sh`, `verify.sh`, `backup_db.sh`) se
quedaron con el motor viejo y los de PostgreSQL llevan sufijo explícito
(`start_postgres.sh`, …). Es lo contrario de lo que se haría partiendo de
cero, y es a propósito: renombrar los genéricos rompería las citas que son
la única razón por la que los archivos siguen existiendo.

---

## Referencias

- **ADR-028** — PostgreSQL como motor canónico (supersede ADR-009).
- **ADR-027** — Gunicorn embebido como servidor de aplicación.
- **H-DB-05** — `peer` en el canal local; la regla del rol de aplicación.
- **H-DB-06** — `CREATEDB` es un atributo global, no acotable por patrón.
- **H-DB-09** — el cron de backup instalaba el script del motor retirado.
- **H-API-305** — el socket **es** el HOST en libpq.
- **H-API-384** — retirada del keepalive de MariaDB en pytest.
- **H-SERVER-04** — retirada de mod_wsgi; Apache pasa a proxy inverso.
- `.claude/skills/db-postgres/SKILL.md` — modelo de nombres, los 33
  binarios, y las diferencias de dialecto e índices frente a MariaDB.
- `Procedimiento-Implementacion-Almacenamiento-WSL2-ecomerce-p001 v1.0.0`
  (externo) — modelo de cinco cuentas + tres clases.
