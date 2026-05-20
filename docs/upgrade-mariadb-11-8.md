# Upgrade MariaDB 10.11 -> 11.8 (incluyendo entornos sin systemd)

Esta guia documenta el procedimiento para llevar una instalacion de
MariaDB 10.11 (la que sirve `apt` en Ubuntu 24.04 LTS por defecto) a
MariaDB 11.8 LTS, incluyendo el caso especial de **contenedores sin
systemd** (devcontainers, Docker minimal, sandboxes de CI).

## 1. Por que MariaDB 11.8

ADR-009 fija MariaDB 11.8 LTS como motor canonico para PracticaYoruba.
La serie 11.8 es LTS hasta 2028 e incluye correcciones que la 10.11 no
recibira en el ciclo de soporte vigente del proyecto.

El provisioner `provisioners/mariadb/install.sh` impone esto:
- Si encuentra 11.8.x: no-op (idempotente).
- Si encuentra otra serie sin `--migrate`: aborta para proteger datos.
- Si encuentra otra serie con `--migrate`: purga e instala 11.8.

## 2. Detectar la version actual

```bash
# MariaDB 11.x (Ubuntu 24.04 noble):
mariadb --version
# mariadb from 11.8.x-MariaDB-ubu2404 ...           <- ya en destino

# MariaDB <=10.11 (alias legacy mysql todavia existe):
mysql --version
# mysql  Ver 15.1 Distrib 10.11.x-MariaDB ...       <- destino: 11.8
```

**D-028 (verificado yollotl 2026-05-20):** en MariaDB 11.x sobre
Ubuntu 24.04 noble el binario `mysql` ya NO se instala; solo
existe `mariadb`. Usa `command -v mariadb || command -v mysql`
para auto-detectar antes de invocar.

## 3. Upgrade con el repo oficial de MariaDB

El metodo soportado upstream usa el script `mariadb_repo_setup`:

```bash
curl -fsSL https://r.mariadb.com/downloads/mariadb_repo_setup \
  | sudo bash -s -- --mariadb-server-version=11.8

sudo apt-get update
sudo apt-get install -y mariadb-server mariadb-client
```

Si vienes de una 11.x mas reciente (por ejemplo, una build dev de la
serie 12.x instalada por error) y necesitas bajar a 11.8 estable:

```bash
sudo apt-get install -y --allow-downgrades \
  mariadb-server=1:11.8.* mariadb-client=1:11.8.* mariadb-common=1:11.8.*
```

El directorio de datos (`/var/lib/mysql`) se conserva. Los schemas y
usuarios sobreviven a la actualizacion entre series LTS adyacentes.
Aun asi: **siempre haz backup antes** (`bash scripts/backup_db.sh`).

## 4. Reinicio en entornos sin systemd

En contenedores con PID 1 != systemd (`bash`, `tini`, `sh`), `service
mariadb start` y `systemctl restart mariadb` fallan silenciosamente.
Procedimiento manual:

```bash
# 1. Detener cualquier mariadbd antiguo (puede haber quedado el de 10.11)
sudo pkill -f mariadbd || true
# Esperar a que el socket desaparezca
while [[ -S /run/mysqld/mysqld.sock ]]; do sleep 1; done

# 2. Asegurar directorios de runtime y log
sudo mkdir -p /run/mysqld /var/log/mysql
sudo chown mysql:mysql /run/mysqld /var/log/mysql

# 3. Arrancar la nueva 11.8 con nohup
sudo nohup mariadbd --user=mysql \
  > /var/log/mysql/mariadbd.log 2>&1 &

# 4. Verificar que responde
sudo mysqladmin --socket=/run/mysqld/mysqld.sock ping
mariadb --version
```

## 5. Detalles de idempotencia

- `install.sh` detecta la presencia de systemd al arranque y elige una
  ruta directa basada en `nohup mariadbd` si no hay init real. La
  segunda corrida no relanza mariadbd si ya responde en
  `/run/mysqld/mysqld.sock`.
- El datadir `/var/lib/mysql` se reutiliza entre series. Los schemas
  `practicayoruba_db`, `practicayoruba_qa` y los usuarios creados por
  `db_setup.sh` / `db_qa_setup.sh` sobreviven al upgrade.
- Tras el upgrade conviene correr una vez `mariadb-upgrade` (mismo
  binario, gestiona `mysql.user`, `mysql.proc` legacy, etc.):
  ```bash
  sudo mariadb-upgrade --socket=/run/mysqld/mysqld.sock
  ```

## 6. Referencias

- `provisioners/mariadb/install.sh` — provisioner principal, contiene
  la deteccion de systemd y la ruta sin-systemd documentada arriba.
- `provisioners/mariadb/db_setup.sh` — schema de produccion.
- `provisioners/mariadb/db_qa_setup.sh` — schema de QA/tests.
- `utils/database.sh` — `mariadb_start`, `_mariadb_start_direct`.
- ADR-009 — decision de fijar MariaDB 11.8 LTS.
