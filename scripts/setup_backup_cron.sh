#!/bin/bash
# =============================================================================
# scripts/setup_backup_cron.sh
# Activa el cron automático de backup_db.sh como svc-dbdata
# =============================================================================
# Instala la entrada en /etc/cron.d/practicayoruba-backup para que
# backup_db.sh corra diariamente a las 02:00 (America/Mexico_City)
# como svc-dbdata via sudo.
#
# Prerequisitos:
#   - backup_db.sh existe en el repo (scripts/backup_db.sh)
#   - El usuario svc-dbdata existe en el sistema
#   - .env en el directorio raíz del repo con BACKUP_* configurado
#   - El bind mount /srv/backups/database/e-comerce-db está activo
#     (operaciones.md — sección "Bind mount Clase C → repo")
#
# Uso:
#   sudo bash scripts/setup_backup_cron.sh
#
# Para deshabilitar:
#   sudo rm /etc/cron.d/practicayoruba-backup
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CRON_FILE="/etc/cron.d/practicayoruba-backup"
BACKUP_SCRIPT="${REPO_DIR}/scripts/backup_db.sh"
BACKUP_PROYECTOS_SCRIPT="${REPO_DIR}/scripts/backup_proyectos.sh"

# ---- Colores ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'

log_info()    { echo -e "${BOLD}  --${RESET}  $*"; }
log_success() { echo -e "${GREEN}  OK${RESET}  $*"; }
log_warn()    { echo -e "${YELLOW}  WW${RESET}  $*"; }
log_error()   { echo -e "${RED}  EE${RESET}  $*" >&2; }

# ---- Verificaciones previas ----

if [[ "${EUID}" -ne 0 ]]; then
    log_error "Este script requiere sudo."
    exit 1
fi

if ! id "svc-dbdata" &>/dev/null; then
    log_error "El usuario svc-dbdata no existe. Revisar el procedimiento de provisioning."
    exit 1
fi

if [[ ! -f "${BACKUP_SCRIPT}" ]]; then
    log_error "No se encontró scripts/backup_db.sh en ${REPO_DIR}."
    exit 1
fi

# ---- Verificar bind mount activo ----
BACKUPS_DIR="${REPO_DIR}/backups"
if [[ ! -d "${BACKUPS_DIR}" ]]; then
    log_warn "El directorio backups/ no existe o no está montado."
    log_warn "Verificar bind mount /srv/backups/database/e-comerce-db → ${BACKUPS_DIR}"
    log_warn "El cron se instalará pero fallará si el mount no está activo."
fi

# ---- Instalar cron ----
log_info "Instalando cron de backup en ${CRON_FILE} ..."

# El cron file usa la ruta absoluta al repo para ser independiente del cwd.
# Corre como root via sudo -u svc-dbdata para que el output quede en
# /srv/backups/database/e-comerce-db (propiedad de svc-dbdata).
# La variable REPO_DIR se expande en tiempo de instalación — no en tiempo
# de ejecución del cron — para que el path sea fijo.

cat > "${CRON_FILE}" <<EOF
# /etc/cron.d/practicayoruba-backup
# Backup automático de practicayoruba_db + practicayoruba_qa.
# Instalado por: setup_backup_cron.sh
# Repositorio: ${REPO_DIR}
#
# Corre daily a las 02:00 America/Mexico_City.
# backup_db.sh genera dumps .sql.gz + checksums MD5 en backups/.
# Los logs de cada ejecución quedan en backups/<timestamp>.log
#
# Para deshabilitar temporalmente: comentar la línea siguiente.
# Para deshabilitar permanentemente: rm ${CRON_FILE}
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 2 * * * root sudo -u svc-dbdata bash ${BACKUP_SCRIPT} >> /var/log/practicayoruba-backup.log 2>&1
EOF

chmod 644 "${CRON_FILE}"
log_success "Cron instalado: ${CRON_FILE}"

# ---- Verificar que cron daemon leerá el archivo ----
if systemctl is-active --quiet cron 2>/dev/null; then
    log_success "Servicio cron activo — el job se ejecutará en el próximo ciclo."
elif systemctl is-active --quiet crond 2>/dev/null; then
    log_success "Servicio crond activo — el job se ejecutará en el próximo ciclo."
else
    log_warn "Servicio cron no detectado como activo via systemctl."
    log_warn "Verificar manualmente: systemctl status cron || service cron status"
fi

# ---- Mostrar resumen ----
echo ""
log_info "=============================================="
log_info "Cron de backup configurado"
log_info "=============================================="
log_info "  Archivo:  ${CRON_FILE}"
log_info "  Script:   ${BACKUP_SCRIPT}"
log_info "  Horario:  02:00 diario (America/Mexico_City)"
log_info "  Usuario:  svc-dbdata (via sudo)"
log_info "  Log:      /var/log/practicayoruba-backup.log"
echo ""
log_info "Para verificar la próxima ejecución:"
log_info "  grep practicayoruba-backup /var/log/syslog | tail -5"
log_info ""
log_info "Para ejecutar manualmente (como test):"
log_info "  sudo -u svc-dbdata bash ${BACKUP_SCRIPT}"
echo ""
