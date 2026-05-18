# Integración PracticaYoruba-db con PracticaYoruba-api

Este documento describe cómo los dos repositorios trabajan juntos y
el orden correcto de configuración.

---

## Dos enfoques, un propósito

`PracticaYoruba-api` tiene sus propios scripts de base de datos en
`scripts/provisioners/mysql/` que funcionan en un entorno de desarrollo
local sin separación de repos. `PracticaYoruba-db` es el repositorio
de infraestructura de BD para entornos de producción o cualquier entorno
donde la base de datos vive en un servidor dedicado.

| Situación | Enfoque recomendado |
|---|---|
| Desarrollo local en una máquina | `sudo bash scripts/bootstrap.sh` en la API |
| Servidor de BD dedicado (VPS, producción) | `PracticaYoruba-db` provisioners |
| CI/CD con contenedor de BD separado | `PracticaYoruba-db` provisioners |

Ambos enfoques crean los mismos schemas (`practicayoruba_db` y
`practicayoruba_qa`) con el mismo usuario (`django_user`) y las mismas
credenciales por defecto. La diferencia es dónde corren.

---

## Variables de entorno — sincronización obligatoria

Cada repositorio tiene su propio `.env`. Las variables de BD deben
ser **idénticas** en ambos archivos. Un cambio en uno que no se replique
en el otro produce errores silenciosos en tiempo de ejecución.

| `PracticaYoruba-db/.env` | `PracticaYoruba-api/practicayoruba/.env` | Default |
|---|---|---|
| `DB_NAME` | `DB_NAME` | `practicayoruba_db` |
| `DB_USER` | `DB_USER` | `django_user` |
| `DB_PASSWORD` | `DB_PASSWORD` | `django_pass` |
| `DB_HOST` | `DB_HOST` | `127.0.0.1` |
| `DB_PORT` | `DB_PORT` | `3306` |
| `DB_QA_NAME` | `DB_QA_NAME` | `practicayoruba_qa` |
| `DB_QA_USER` | `DB_QA_USER` | `django_user` |
| `DB_QA_PASSWORD` | `DB_QA_PASSWORD` | `django_pass` |
| `DB_QA_HOST` | `DB_QA_HOST` | `127.0.0.1` |
| `DB_QA_PORT` | `DB_QA_PORT` | `3306` |

---

## Flujo de configuración inicial — servidor de BD dedicado

Orden obligatorio. Un error en cualquier paso bloquea los siguientes.

```bash
# ── En PracticaYoruba-db ────────────────────────────────────────────
cd e-comerce-db
cp .env.example .env
# Editar .env con las credenciales reales

# 1. Instalar MariaDB 11.8 (idempotente — detecta si ya está instalado)
sudo bash provisioners/mariadb/install.sh

# 2. Crear schema de producción y usuario django_user
sudo bash provisioners/mariadb/db_setup.sh

# 3. Crear schema QA para pytest
sudo bash provisioners/mariadb/db_qa_setup.sh

# ── En PracticaYoruba-api ────────────────────────────────────────────
cd PracticaYoruba-api
cp practicayoruba/.env.example practicayoruba/.env
# Editar practicayoruba/.env con las MISMAS credenciales del paso anterior

source venv/bin/activate   # activar el virtualenv
cd practicayoruba

# 4. Aplicar migraciones en el schema de producción
python manage.py migrate

# 5. Aplicar migraciones en el schema QA
#    Necesario para que pytest encuentre las tablas al correr los tests
DJANGO_SETTINGS_MODULE=config.settings.testing \
  python manage.py migrate

# ── Verificación de la integración ──────────────────────────────────

# 6. Verificar BD desde PracticaYoruba-db (8 checks shell)
cd e-comerce-db
bash scripts/verify.sh

# 7. Verificar BD + ORM desde PracticaYoruba-db (6 checks Python)
pip install -r requirements.txt
python scripts/check_db.py

# 8. Verificar configuración Django
cd PracticaYoruba-api/practicayoruba
python manage.py check --database default

# 9. Correr la suite de tests
pytest
```

---

## Verificación continua

En cualquier momento, sin necesidad de reprovisionar:

```bash
# Desde PracticaYoruba-db
bash scripts/verify.sh           # verifica MariaDB, schemas, privilegios
python scripts/check_db.py       # verifica conectividad ORM y migraciones

# Desde PracticaYoruba-api/practicayoruba
python manage.py check --database default      # Django ORM
python manage.py showmigrations                # estado de migraciones
DJANGO_SETTINGS_MODULE=config.settings.testing \
  python manage.py showmigrations              # estado en schema QA
pytest                                         # suite completa
```

---

## Troubleshooting

### `django_migrations` no encontrada en `check_db.py`

Las migraciones no se han aplicado aún.

```bash
cd PracticaYoruba-api/practicayoruba
python manage.py migrate
```

### `users_user` no encontrada en `check_db.py`

La migración de la app `users` no se aplicó.

```bash
cd PracticaYoruba-api/practicayoruba
python manage.py migrate apps.users
```

### Error de conexión en `check_db.py` o en pytest

Las credenciales en los dos `.env` no coinciden.

1. Verificar `PracticaYoruba-db/.env` — los valores de `DB_*`
2. Verificar `PracticaYoruba-api/practicayoruba/.env` — deben ser idénticos
3. Verificar que MariaDB está activo: `bash scripts/verify.sh`

### `OperationalError: (2002, ...)` en pytest

MariaDB no está corriendo.

```bash
# Desde PracticaYoruba-db
bash scripts/verify.sh   # diagnostica el estado completo
```

Si el servidor está sin systemd (contenedor, CI):

```bash
# Arrancar MariaDB directamente
nohup su -s /bin/bash mysql -c \
  "mariadbd --datadir=/var/lib/mysql \
   --socket=/run/mysqld/mysqld.sock \
   --pid-file=/run/mysqld/mysqld.pid \
   --bind-address=127.0.0.1 --port=3306" \
  &>/tmp/mariadbd.log &
```

### `check_db.py` falla con `ImportError`

```bash
cd e-comerce-db
pip install -r requirements.txt
# Ubuntu requiere el paquete del sistema:
# sudo apt-get install libmysqlclient-dev
```
