# docs/operaciones.md

Runbook de operaciones para PracticaYoruba-db.

---

## Configuración inicial (una vez por servidor)

```bash
# 1. Clonar el repositorio
git clone <repo> PracticaYoruba-db
cd PracticaYoruba-db

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

## Verificar el entorno

```bash
# Verificación completa (7 checks: env, CLI, conectividad, schemas, privilegios)
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
