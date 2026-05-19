# PracticaYoruba-db

Repositorio de infraestructura de base de datos para
[PracticaYoruba](https://github.com/NestorMonroy/PracticaYoruba-api) —
plataforma e-commerce de productos Yoruba.

Implementa los patrones de scripting identificados en el análisis de
referencia de IACT-db, adaptados al dominio ecommerce con MariaDB 11.8,
sin Vagrant, sin PostgreSQL, sin Adminer.

---

## Prerequisitos

- **OS**: Ubuntu 24.04 LTS (recomendado) o macOS con Homebrew
- **MariaDB**: **11.8 LTS** — version canonica del proyecto segun
  :ref:`ADR-009 <adr-009>` e instalada por
  ``provisioners/mariadb/install.sh``. La serie 10.11 (la que ofrece
  el repo base de Ubuntu 24.04) **no** es soportada — el provisioner
  pinea la serie 11.8.x para evitar saltos automaticos a 12.x.
- **Python**: 3.11 o superior
- **bash**: 5.x (`bash --version`)
- **Dependencias Python** para `scripts/check_db.py`:
  ```bash
  # Prerequisito del sistema:
  sudo apt-get install libmysqlclient-dev
  # Dependencias Python:
  pip install -r requirements.txt
  ```

---

## Estructura

```
PracticaYoruba-db/
├── .env.example                    # Plantilla de variables de entorno
├── .gitignore
├── README.md
│
├── config/
│   └── mariadb/
│       └── 99-practicayoruba.cnf  # Overrides de MariaDB (charset, sql_mode, InnoDB)
│
├── utils/                          # Librerías de shell compartidas
│   ├── logging.sh                  # log_info, log_warn, log_error, log_success
│   ├── network.sh                  # tcp_is_reachable
│   ├── core.sh                     # validate_ubuntu, apt_update, etc.
│   ├── validation.sh               # validate_root, validate_env_var, etc.
│   └── database.sh                 # mariadb_is_running, mariadb_start, etc.
│
├── provisioners/
│   └── mariadb/
│       ├── db_setup.sh             # Crea schema practicayoruba_db y usuario django_user
│       └── db_qa_setup.sh          # Crea schema practicayoruba_qa
│
├── scripts/
│   ├── backup_db.sh                # Backup de ambos schemas con MD5 y gzip-6
│   ├── verify.sh                   # 8 checks con contadores OK/WARN/ERROR
│   └── check_db.py                 # Verificación Python de conectividad y privilegios
│
├── backups/                        # Artefactos generados (en .gitignore)
│   └── README.md
│
└── docs/
    └── operaciones.md              # Runbook de operaciones comunes
```

---

## Configuración inicial

```bash
# 1. Clonar
git clone <repo>
cd e-comerce-db

# 2. Variables de entorno
cp .env.example .env
# Editar .env con las credenciales reales

# 3. Instalar MariaDB 11.8 LTS (idempotente — no-op si ya está 11.8.x)
sudo bash provisioners/mariadb/install.sh

# 4. Activar la configuración del proyecto (lo hace install.sh, pero
#    en upgrades manuales el symlink puede faltar)
sudo ln -sf "$(pwd)/config/mariadb/99-practicayoruba.cnf" \
            /etc/mysql/mariadb.conf.d/99-practicayoruba.cnf
sudo systemctl reload mariadb 2>/dev/null \
    || sudo mysqladmin --socket=/run/mysqld/mysqld.sock reload
```

### Version canónica de MariaDB

`MariaDB 11.8 LTS` es la version mandatoria del proyecto por
:ref:`ADR-009 <adr-009>` y la instala `provisioners/mariadb/install.sh`:

- El provisioner detecta la version actual; si ya es `11.8.x` reporta
  `"Sin cambios"` y sale (idempotente).
- Si encuentra una serie distinta (p.ej. `10.11` del repo base de
  Ubuntu) se detiene con un mensaje claro y requiere `--migrate`
  como confirmacion del operador para purgar e instalar `11.8`.
- En contenedores sin systemd usa `mariadb_repo_setup` oficial y
  arranca `mariadbd` con `nohup`.
- La serie esta pineada (`/etc/apt/preferences.d/mariadb-pin`) para
  permitir parches `11.8.x` pero bloquear saltos automaticos a `12.x`.

Auditar la version instalada cuando MariaDB esta activo:

```bash
bash tests/test_mariadb_version.sh
```

---

## Uso de scripts

### Provisionar los schemas

```bash
# Schema de producción/desarrollo
sudo bash provisioners/mariadb/db_setup.sh

# Schema de QA (para pytest)
sudo bash provisioners/mariadb/db_qa_setup.sh
```

### Verificar el entorno

```bash
# Verificación completa del entorno (8 checks)
bash scripts/verify.sh

# Verificación de conectividad Python
python3 scripts/check_db.py
```

### Backup

```bash
# Backup de ambos schemas
bash scripts/backup_db.sh

# Primera vez: crear el usuario de backup con privilegios mínimos
bash scripts/backup_db.sh --setup-user
```

---

## Integración con PracticaYoruba-api

`PracticaYoruba-db` provisiona la infraestructura de BD para entornos
donde la base de datos vive en un servidor dedicado (producción, CI).

Las variables en `PracticaYoruba-db/.env` y en
`PracticaYoruba-api/practicayoruba/.env` deben ser **idénticas** —
son archivos independientes y un cambio en uno no se replica en el otro.

El flujo completo de configuración inicial, la tabla de equivalencias
de variables y el troubleshooting están documentados en:

```
docs/integracion-api.md
```

### Relación técnica con los scripts de la API

`PracticaYoruba-api` tiene sus propios scripts en `scripts/provisioners/mysql/`
para entornos de desarrollo local (usados por `scripts/bootstrap.sh`).
`PracticaYoruba-db` es el repositorio canónico para infraestructura de BD
en servidores dedicados. Los `utils/` de ambos repos son equivalentes con
diferencias de nomenclatura: este repo usa prefijo `mariadb_*` en lugar de
`mysql_*` para reflejar el motor real.

---

## Decisiones de diseño

Ver `docs/operaciones.md` para el runbook operativo.

Las decisiones de arquitectura de base de datos están documentadas en:
- `ADR-009`: Migración a MariaDB 11.8
- `ADR-008`: Arranque de MariaDB sin systemd
- `databases/referencias/analisis-iact-db`: Análisis de patrones de IACT-db
