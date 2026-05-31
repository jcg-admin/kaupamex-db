# docs/operaciones.md

Runbook de operaciones para PracticaYoruba-db.

> **Naming — producto vs repo (T-E3, H-05, DEC-DB-8):**
> Este runbook usa indistintamente "PracticaYoruba-db" y
> "e-comerce-db". Son la misma cosa vista desde dos angulos:
>
> - **PracticaYoruba** es el nombre del **producto** (e-commerce
>   de productos Yoruba). Se usa internamente en el codigo
>   (schemas `practicayoruba_db`, `practicayoruba_qa`, usuario
>   `django_user`, archivo `99-practicayoruba.cnf`, mensajes de
>   log).
> - **e-comerce-db** es el nombre del **repositorio** en GitHub
>   (`jcg-admin/e-comerce-db`). Forma parte del monorepo
>   `jcg-admin/e-comerce` junto a `e-comerce-{api,ui,server,docs}`.
>
> No renombrar uno al otro sin decision explicita de producto
> (CLAUDE.md lo marca como Locked Decision). Las 11 referencias
> textuales a "PracticaYoruba" en los scripts y este runbook son
> intencionales y deben preservarse.

---

## Configuración inicial (una vez por servidor)

```bash
# 1. Clonar el repositorio
git clone <repo>
cd e-comerce-db

# 2. Crear .env desde la plantilla
cp .env.example .env
# Editar .env con las credenciales reales del servidor

# 3. Activar la configuración de MariaDB
sudo ln -sf "$(pwd)/config/mariadb/99-practicayoruba.cnf" \
            /etc/mysql/mariadb.conf.d/99-practicayoruba.cnf
sudo systemctl reload mariadb

# 4. Provisionar los schemas
sudo bash provisioners/mariadb/db_setup.sh
sudo bash provisioners/mariadb/db_qa_setup.sh
```

---

## Arrancar MariaDB en entornos sin systemd (ADR-008)

Usar el script `scripts/start_db.sh` — detecta si ya está activo,
limpia archivos stale, arranca y verifica en una sola llamada.

```bash
# Arranque completo + verificación
bash scripts/start_db.sh

# Solo arrancar, sin ejecutar verify.sh
bash scripts/start_db.sh --no-verify
```

Salida esperada cuando MariaDB no está corriendo:

```
  --  MariaDB no responde. Limpiando archivos stale...
  --  Arrancando /usr/sbin/mariadbd (sin systemd, log → /tmp/mariadbd-20260515T083000.log)...
  OK  MariaDB OK en 3s
  --  Ejecutando verify.sh...
  OK  OK:           28
```

Salida esperada cuando ya está corriendo (idempotente):

```
  OK  MariaDB ya está activo — nada que hacer
  --  Ejecutando verify.sh...
  OK  OK:           28
```

### Nota sobre mysqld_safe

`mysqld_safe` está **deprecated en MariaDB 11.8** y no existe en
Ubuntu 24.04 con el paquete `mariadb-server`. El script usa
`mariadbd` directamente con `nohup su -s /bin/bash mysql`, que es
el método recomendado por ADR-008.

### Log de arranque

El log de cada arranque se guarda en `/tmp/mariadbd-{timestamp}.log`.
Si MariaDB no levanta en 20 segundos, el script muestra las últimas
5 líneas del log y termina con exit code 1.

### Integración con conftest.py de PracticaYoruba-api

### Contrato del fixture `mariadb_keepalive` (T-E1, H-02)

El fixture `mariadb_keepalive` vive en
`api/tests/conftest.py` (submodulo `api`, no `db`) y opera como
"guardrail" para la suite de tests pytest. Su contrato:

**Scope (cuando aplica):**

- Cualquier test marcado `@pytest.mark.django_db` o que use
  el fixture `db` / `transactional_db` del plugin pytest-django.
- Suite larga (>10 tests con db) — la fixture se ejecuta
  por sesion (autouse), no por test.

**Precondiciones:**

- MariaDB **debe estar corriendo** al arrancar la suite. Si
  no responde a `mysqladmin ping`, la fixture falla loud
  (no intenta arrancarlo silenciosamente — eso seria
  ocultar un error de setup del operador).
- Las credenciales DB_QA_* deben estar en
  `api/practicayoruba/.env` (mismo schema que `db/.env`, ver
  T-B3 mas abajo).

**Side-effects:**

- Hace `mysqladmin ping` al comienzo de la sesion pytest.
- Si ping falla a mitad de la suite (MariaDB se cayo por
  OOM, restart manual, etc), la fixture detecta y emite un
  warning verbose al log; los tests siguientes se marcan
  como `errored` (no `failed`) hasta que vuelva.
- **NO arranca MariaDB.** Esa responsabilidad es del
  operador via `bash scripts/start_db.sh` (este repo).

**Idempotencia:**

- Si MariaDB esta arriba al arrancar, la fixture es no-op
  modulo el ping.
- Si MariaDB cae y vuelve, la fixture detecta el regreso al
  siguiente ping de scope-session.

**No hace:**

- No corre migraciones (eso es `manage.py migrate
  --settings=config.settings.testing`).
- No crea schemas (eso es `db_qa_setup.sh` la primera vez).
- No carga fixtures de datos (eso son los `@pytest.fixture`
  por test).

Para una sesión nueva, el punto de entrada correcto es:

```bash
cd e-comerce-db
bash scripts/start_db.sh

# Luego provisionar QA si es la primera vez:
bash provisioners/mariadb/db_qa_setup.sh

# Correr las migraciones de Django:
cd /tmp/project/PracticaYoruba-api/practicayoruba
python3 manage.py migrate --settings=config.settings.testing
```


---

## Verificar el entorno

```bash
# Verificación completa — el script reporta dinámicamente N checks
# en el header. La fuente de verdad es el conteo dinámico (DEC-DB-4).
# Cubre env, CLI, versión, conectividad, schemas, privilegios, funciones,
# vistas y SPs.
bash scripts/verify.sh

# Verificación Python (conectividad, migraciones, privilegios DML)
python3 scripts/check_db.py
```

`scripts/verify.sh` retorna exit code 0 si todo está bien, 1 si hay errores.
Útil para integraciones con CI o scripts de monitoreo.

---

## Backup

### Activar cron automático (producción)

```bash
# Instala /etc/cron.d/practicayoruba-backup
# Corre backup_db.sh daily a las 02:00 como svc-dbdata
sudo bash scripts/setup_backup_cron.sh
```

Prerequisito: el bind mount `/srv/backups/database/e-comerce-db → backups/`
debe estar activo antes de ejecutar el cron (ver sección "Bind mount Clase C").

### Ejecutar backup manualmente

```bash
# Backup de practicayoruba_db y practicayoruba_qa
bash scripts/backup_db.sh
```

Genera por ejecución en `backups/`:

```
YYYYMMDD_HHMMSS_practicayoruba_db.sql.gz
YYYYMMDD_HHMMSS_practicayoruba_db.md5
YYYYMMDD_HHMMSS_practicayoruba_qa.sql.gz
YYYYMMDD_HHMMSS_practicayoruba_qa.md5
YYYYMMDD_HHMMSS.log
```

El timestamp usa `America/Mexico_City`. La integridad del dump se verifica
con `gzip -t` y `md5sum -c` antes de reportar éxito.

### Verificar un backup existente manualmente

```bash
cd backups/
md5sum -c 20260513_225115_practicayoruba_db.md5
```

### Sincronización a S3 (opcional)

Define `BACKUP_REMOTE_DEST=s3://bucket/ruta/` en `.env`.
El script sincroniza automáticamente después de verificar la integridad.

### Variables `BACKUP_*` / `PY_BACKUP_*` — solo en `db/.env` (T-B3, ENV-02)

Las siguientes variables viven **únicamente** en `db/.env` y NO se
replican en `api/practicayoruba/.env`:

- `PY_BACKUP_USER`, `PY_BACKUP_PASSWORD` — credenciales del usuario
  MariaDB con privilegios `SELECT, SHOW VIEW, LOCK TABLES, EVENT,
  TRIGGER` que utiliza `backup_db.sh`. La api no las consume.
- `BACKUP_DIR` — directorio destino de los dumps.
- `BACKUP_REMOTE_DEST` — URI de S3 / rclone para sincronizacion
  opcional.
- `BACKUP_REPOS` — lista de directorios del monorepo a snapshotear
  via `backup_proyectos.sh`.

`verify_env_sync.sh` (T-B1) compara solo claves `^DB_` justamente
para que la sincronizacion cross-repo no force `api/.env` a llevar
estas claves de backup. La asimetria es intencional.

---

## Actualizar la configuración de MariaDB

El archivo `config/mariadb/99-practicayoruba.cnf` es la fuente de verdad.
Editar en el repositorio y recargar:

```bash
# El symlink ya apunta al repo — el cambio es inmediato
sudo systemctl reload mariadb
# o sin systemd (MariaDB 11.x: mariadb-admin; <=10.11 legacy: mysqladmin):
sudo mariadb-admin reload
```

---

## Diagnóstico

> **MariaDB 11.x (Ubuntu 24.04 noble) — D-028:** los binarios
> ``mysql`` / ``mysqladmin`` ya NO se instalan. Usar ``mariadb`` y
> ``mariadb-admin``. Si convives con MariaDB <=10.11 los nombres
> legacy todavia existen como aliases en el paquete.

```bash
# Log de errores de MariaDB
sudo tail -f /var/lib/mysql/mysqld_err.log

# Verificar que MariaDB responde
mariadb-admin ping

# Ver el estado de los schemas
sudo mariadb -e "SHOW DATABASES LIKE 'practicayoruba%';"

# Ver privilegios del usuario Django
sudo mariadb -e "SHOW GRANTS FOR 'django_user'@'localhost';"
```

---

## Reprovisionar desde cero (idempotente)

Todos los scripts son idempotentes. Re-ejecutar en el mismo servidor o
en servidores adicionales es seguro:

```bash
sudo bash provisioners/mariadb/db_setup.sh
sudo bash provisioners/mariadb/db_qa_setup.sh
bash scripts/verify.sh
```

---

## Modelo cross-user de permisos (D-030)

El proyecto opera bajo cinco cuentas del sistema heredadas del
procedimiento externo
**Procedimiento-Implementacion-Almacenamiento-WSL2-ecomerce-p001 v1.0.0**.
Para troubleshoot de permisos de BD + apache + backups, entender la
relación cross-user es crítico.

### Quién puede leer qué (resumen)

| Recurso | Propietario | Perms | Quién más lee |
|---|---|---|---|
| `/srv/repos/ecom/e-comerce-db/` (código) | `develop:develop` | 755/644 | Todos via "other" (incluido `www-data`) |
| `/srv/backups/database/` (dumps) | `svc-dbdata:svc-dbdata` | 755 | Solo `svc-dbdata` y root |
| `/srv/backups/project/` (backups proyecto) | `svc-backups:svc-backups` | 755 | Solo `svc-backups` y root |
| `/var/lib/mysql/` (MariaDB datadir) | `mysql:mysql` | 700 | Solo `mysql` y root |
| `/etc/ssl/practicayoruba/cert.pem` (post-D-029) | `root:root` | 644 | Todos (cert público) |
| `/etc/ssl/practicayoruba/key.pem` | `root:root` | 600 | Solo root |

### Quién corre qué

- **Provisioners**: `deploy` con `sudo` (`db_setup.sh`, `db_qa_setup.sh`,
  `install.sh`). El binario interactivo `mariadb` se invoca como root
  via socket (`unix_socket` auth plugin), no como `deploy` directo —
  por eso `mariadb -e ...` falla con "Access denied for 'deploy'" pero
  `sudo mariadb -e ...` funciona.
- **MariaDB daemon (`mariadbd`)**: como `mysql:mysql`. Lee solo
  `/var/lib/mysql/`.
- **Django ORM (vía Apache mod-wsgi)**: como `www-data`. Conecta a
  MariaDB con credenciales `django_user`/`django_pass` definidas en
  `e-comerce-api/practicayoruba/.env`. NO usa el socket de unix; usa
  TCP a `127.0.0.1:3306`.
- **Backups manuales / scripts cron**: deberían correr como
  `svc-dbdata` (pero `nologin` impide invocación interactiva — se
  hace vía `sudo -u svc-dbdata ...` desde scripts de cron del root).

### Bind mount Clase C → repo

Los repos `e-comerce-db` y `e-comerce-server` tienen un directorio
`backups/` que vive físicamente fuera del checkout git (Clase C, owner
`svc-dbdata`). Esto previene que `git clean -fdx` o un `git checkout`
accidental destruyan dumps:

```
/srv/backups/database/e-comerce-db     → /srv/repos/ecom/e-comerce-db/backups
/srv/backups/database/e-comerce-server → /srv/repos/ecom/e-comerce-server/backups
```

Configuración fstab en el procedimiento de provisioning, NO en este
script. Si haces dumps manuales:

```bash
sudo -u svc-dbdata mariadb-dump practicayoruba_db > /srv/repos/ecom/e-comerce-db/backups/dump-$(date -u +%Y-%m-%dT%H-%M-%SZ).sql
```

El dump aparece dentro del checkout git pero `git status` lo ignora
porque `backups/` está en `.gitignore` del repo y el bind mount lo
saca del árbol real.

### Troubleshooting cross-user típico

| Síntoma | Probable causa |
|---|---|
| `mariadb -e "..."` como deploy → "Access denied" | Falta `sudo` (auth via socket requiere root) |
| Django responde 500 + `OperationalError: Permission denied` en logs | `www-data` no puede leer SSL cert (post-D-029 ya no aplica) o el `.env` del api no es readable por `www-data` |
| `mariadb-dump` falla con "Can't read dir of '/etc/mysql/'" | `mariadb-dump` corre como root via `sudo -u mysql`; chequear `--defaults-file` |
| Apache `Could not open WSGI script /srv/repos/ecom/...wsgi.py` | Probable repo no clonado en `API_ROOT`, o perms del repo distintos de `755 develop:develop` |

---

## Referencias

- `ADR-009`: decisión de usar MariaDB 11.8
- `ADR-008`: arranque sin systemd
- `databases/referencias/analisis-iact-db`: patrones de IACT-db adaptados
- `Procedimiento-Implementacion-Almacenamiento-WSL2-ecomerce-p001 v1.0.0` (externo): modelo de cinco cuentas + tres clases
