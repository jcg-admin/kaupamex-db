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

---

## Actualizar la configuración de MariaDB

El archivo `config/mariadb/99-practicayoruba.cnf` es la fuente de verdad.
Editar en el repositorio y recargar:

```bash
# El symlink ya apunta al repo — el cambio es inmediato
sudo systemctl reload mariadb
# o sin systemd:
sudo mysqladmin reload
```

---

## Diagnóstico

```bash
# Log de errores de MariaDB
sudo tail -f /var/lib/mysql/mysqld_err.log

# Verificar que MariaDB responde
mysqladmin ping

# Ver el estado de los schemas
mysql -e "SHOW DATABASES LIKE 'practicayoruba%';"

# Ver privilegios del usuario Django
mysql -e "SHOW GRANTS FOR 'django_user'@'localhost';"
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

## Referencias

- `ADR-009`: decisión de usar MariaDB 11.8
- `ADR-008`: arranque sin systemd
- `databases/referencias/analisis-iact-db`: patrones de IACT-db adaptados
