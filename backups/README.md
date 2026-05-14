# backups/

Directorio de artefactos generados por `scripts/backup_db.sh`.

## Convención de nombres

Cada ejecución del script genera un par de archivos por schema:

```
<YYYYMMDD_HHMMSS>_practicayoruba_db.sql.gz   — dump comprimido
<YYYYMMDD_HHMMSS>_practicayoruba_db.md5       — checksum MD5
<YYYYMMDD_HHMMSS>_practicayoruba_qa.sql.gz
<YYYYMMDD_HHMMSS>_practicayoruba_qa.md5
<YYYYMMDD_HHMMSS>.log                         — log completo de la operación
```

El timestamp usa la zona horaria `America/Mexico_City` (TZ del proyecto).

## Qué está en .gitignore

Todos los archivos `*.sql`, `*.sql.gz`, `*.md5` y `*.log` están
excluidos del control de versión. Este directorio existe en el
repositorio solo para mantener la estructura — los backups reales
van a almacenamiento permanente (AWS S3 u otro destino configurado
en `BACKUP_REMOTE_DEST`).

## Generar un backup

```bash
# Desde la raíz del repositorio
bash scripts/backup_db.sh
```

## Verificar integridad de un backup existente

```bash
cd backups/
md5sum -c 20260513_225115_practicayoruba_db.md5
```
