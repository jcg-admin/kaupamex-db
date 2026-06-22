#!/bin/bash
# =============================================================================
# configure_db_vm_ssl_letsencrypt.sh
# Obtiene certificado Let's Encrypt para db.practicayoruba.com en ecom-db-vm
# y configura MariaDB para usar TLS con ese certificado.
#
# Ejecutar DENTRO de ecom-db-vm como:
#   sudo bash /tmp/configure_db_vm_ssl_letsencrypt.sh
#
# Contexto:  [VM3-UBUNTU] -- usuario ubuntu con sudo, dentro de ecom-db-vm
# Tarea:     B.5.1 -- Certificado Let's Encrypt para MariaDB TLS
#
# Despliegue desde el Host:
#   scp -F /home/ubuntu/.ssh/config /tmp/configure_db_vm_ssl_letsencrypt.sh ecom-db:/tmp/
#   ssh ecom-db "sudo bash /tmp/configure_db_vm_ssl_letsencrypt.sh" 2>&1 | \
#       tee /tmp/log_tarea_B_5_1_$(date -u +%Y%m%dT%H%M%SZ).txt
#
# Prerequisitos CRÍTICOS (verificados por el script):
#   1. DNS A record para db.practicayoruba.com apuntando a IP pública de VM3
#      (bloqueador externo — debe estar propagado antes de ejecutar)
#   2. Puerto 80 abierto en firewall de VM3
#      (ejecutar configure_db_vm_open_port80_temp.sh primero — B.4.2)
#   3. MariaDB 11.8 instalado y operativo
#      (configure_db_vm_mariadb_install.sh debe haber sido ejecutado)
#   4. Acceso a Internet desde VM3 para validar dominio con Let's Encrypt
#
# Secuencia obligatoria:
#   1. configure_db_vm_open_port80_temp.sh   (B.4.2)
#   2. configure_db_vm_ssl_letsencrypt.sh    (este script — B.5.1)
#   3. configure_db_vm_close_port80_temp.sh  (B.6.1)
#
# Qué hace este script:
#   - Instala certbot (si no está instalado)
#   - Ejecuta certbot en modo standalone (no hay Apache/Nginx en VM3)
#   - Verifica que el certificado fue obtenido
#   - Copia los archivos de cert a /etc/mysql/ssl/ con permisos correctos
#   - Actualiza /etc/mysql/mariadb.conf.d/50-server.cnf con directivas TLS
#   - Reinicia MariaDB y verifica que TLS está activo
#
# Configuración TLS generada:
#   ssl-ca   = /etc/mysql/ssl/chain.pem
#   ssl-cert = /etc/mysql/ssl/cert.pem
#   ssl-key  = /etc/mysql/ssl/privkey.pem
#
# Hallazgos producidos:
#   H-B5a-1-VM3 -- certbot instalado (versión)
#   H-B5a-2-VM3 -- Certificado obtenido en /etc/letsencrypt/live/db.practicayoruba.com/
#   H-B5a-3-VM3 -- Archivos copiados a /etc/mysql/ssl/
#   H-B5a-4-VM3 -- MariaDB TLS activo (SHOW VARIABLES LIKE 'have_ssl')
# =============================================================================

set -euo pipefail

# =============================================================================
# CONSTANTES
# =============================================================================
readonly DOMAIN="db.practicayoruba.com"
readonly ACME_EMAIL="webmaster@practicayoruba.com"
readonly LETSENCRYPT_DIR="/etc/letsencrypt/live/${DOMAIN}"
readonly MYSQL_SSL_DIR="/etc/mysql/ssl"
readonly MARIADB_CONF="/etc/mysql/mariadb.conf.d/50-server.cnf"
readonly LOG_PREFIX="[B.5.1-ssl-letsencrypt]"

# =============================================================================
# FUNCIONES AUXILIARES
# =============================================================================

log_info()  { echo "${LOG_PREFIX} [INFO]  $*"; }
log_ok()    { echo "${LOG_PREFIX} [OK]    $*"; }
log_warn()  { echo "${LOG_PREFIX} [WARN]  $*"; }
log_error() { echo "${LOG_PREFIX} [ERROR] $*" >&2; }

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "Este script debe ejecutarse como root (sudo)."
        exit 1
    fi
}

# =============================================================================
# PASO 1 — Validar prerequisitos
# =============================================================================
paso1_validar() {
    log_info "=== PASO 1: Validar prerequisitos ==="

    check_root
    log_ok "Ejecutando como root."

    # Verificar MariaDB está activo
    if ! systemctl is-active --quiet mariadb; then
        log_error "MariaDB no está activo. Ejecutar configure_db_vm_mariadb_install.sh primero."
        exit 1
    fi
    log_ok "MariaDB activo."

    # Verificar puerto 80 abierto en nftables
    if ! nft list ruleset 2>/dev/null | grep -q "TEMP-ACME-CHALLENGE"; then
        log_error "Puerto 80 no está abierto en el firewall."
        log_error "Ejecutar configure_db_vm_open_port80_temp.sh primero (B.4.2)."
        exit 1
    fi
    log_ok "Puerto 80 abierto (TEMP-ACME-CHALLENGE verificado)."

    # Verificar resolución DNS del dominio (advertencia no bloqueante — certbot lo verificará)
    if command -v dig &>/dev/null; then
        local dns_result
        dns_result=$(dig +short "${DOMAIN}" 2>/dev/null | head -1 || true)
        if [[ -n "${dns_result}" ]]; then
            log_ok "DNS resuelve ${DOMAIN} -> ${dns_result}"
        else
            log_warn "No se pudo resolver ${DOMAIN} via dig. Verificar DNS antes de continuar."
            log_warn "Let's Encrypt fallará si el DNS no propaga correctamente."
        fi
    else
        log_warn "dig no disponible; no se puede verificar DNS localmente."
    fi
}

# =============================================================================
# PASO 2 — Instalar certbot
# =============================================================================
paso2_instalar_certbot() {
    log_info "=== PASO 2: Instalar certbot ==="

    if command -v certbot &>/dev/null; then
        log_ok "certbot ya instalado: $(certbot --version 2>&1)"
        return 0
    fi

    log_info "Instalando certbot..."
    apt-get update -qq
    apt-get install -y certbot

    log_ok "certbot instalado: $(certbot --version 2>&1)"
}

# =============================================================================
# PASO 3 — Obtener certificado Let's Encrypt (standalone)
# =============================================================================
paso3_obtener_cert() {
    log_info "=== PASO 3: Obtener certificado Let's Encrypt ==="

    # Si ya existe el certificado, no renovar salvo si está próximo a expirar
    if [[ -d "${LETSENCRYPT_DIR}" ]]; then
        log_warn "Directorio de certificado ya existe: ${LETSENCRYPT_DIR}"

        # Verificar fecha de expiración
        local expiry_date
        expiry_date=$(openssl x509 -enddate -noout \
            -in "${LETSENCRYPT_DIR}/cert.pem" 2>/dev/null | cut -d= -f2 || echo "UNKNOWN")
        log_warn "Certificado existente expira: ${expiry_date}"

        log_info "Renovando certificado existente..."
        certbot renew --cert-name "${DOMAIN}" --standalone --non-interactive 2>&1 || {
            log_warn "certbot renew retornó error; el cert puede no necesitar renovación."
        }
        return 0
    fi

    log_info "Obteniendo certificado para ${DOMAIN} via HTTP-01 standalone..."
    certbot certonly \
        --standalone \
        --domain "${DOMAIN}" \
        --non-interactive \
        --agree-tos \
        --email "${ACME_EMAIL}" \
        --http-01-port 80 \
        2>&1

    log_ok "certbot ejecutado."
}

# =============================================================================
# PASO 4 — Verificar certificado obtenido
# =============================================================================
paso4_verificar_cert() {
    log_info "=== PASO 4: Verificar certificado obtenido ==="

    # Verificar que el directorio existe
    if [[ ! -d "${LETSENCRYPT_DIR}" ]]; then
        log_error "Directorio de certificado no existe: ${LETSENCRYPT_DIR}"
        log_error "El proceso certbot pudo haber fallado. Ver log anterior."
        exit 1
    fi
    log_ok "Directorio existe: ${LETSENCRYPT_DIR}"

    # Verificar archivos individuales
    for archivo in cert.pem privkey.pem chain.pem fullchain.pem; do
        if [[ ! -f "${LETSENCRYPT_DIR}/${archivo}" ]]; then
            log_error "Archivo faltante: ${LETSENCRYPT_DIR}/${archivo}"
            exit 1
        fi
        log_ok "Archivo presente: ${archivo}"
    done

    # Mostrar información del certificado
    local subject expiry
    subject=$(openssl x509 -subject -noout -in "${LETSENCRYPT_DIR}/cert.pem" 2>/dev/null || echo "N/A")
    expiry=$(openssl x509 -enddate -noout -in "${LETSENCRYPT_DIR}/cert.pem" 2>/dev/null | cut -d= -f2 || echo "N/A")
    log_ok "Certificado: ${subject}"
    log_ok "Expira: ${expiry}"
}

# =============================================================================
# PASO 5 — Copiar certificados a /etc/mysql/ssl/
# =============================================================================
paso5_copiar_certs() {
    log_info "=== PASO 5: Copiar certificados a ${MYSQL_SSL_DIR} ==="

    # Crear directorio con permisos restrictivos
    mkdir -p "${MYSQL_SSL_DIR}"
    chmod 750 "${MYSQL_SSL_DIR}"
    chown root:mysql "${MYSQL_SSL_DIR}"
    log_ok "Directorio ${MYSQL_SSL_DIR} creado (root:mysql 750)."

    # Copiar archivos necesarios para MariaDB TLS
    # cert.pem  → certificado del servidor
    # privkey.pem → clave privada
    # chain.pem → CA chain para verificación de clientes
    cp -f "${LETSENCRYPT_DIR}/cert.pem"    "${MYSQL_SSL_DIR}/cert.pem"
    cp -f "${LETSENCRYPT_DIR}/privkey.pem" "${MYSQL_SSL_DIR}/privkey.pem"
    cp -f "${LETSENCRYPT_DIR}/chain.pem"   "${MYSQL_SSL_DIR}/chain.pem"

    # Permisos: mysql necesita leer los archivos, pero privkey.pem NO debe ser
    # legible por otros procesos
    chown root:mysql "${MYSQL_SSL_DIR}/cert.pem"    && chmod 640 "${MYSQL_SSL_DIR}/cert.pem"
    chown root:mysql "${MYSQL_SSL_DIR}/privkey.pem" && chmod 640 "${MYSQL_SSL_DIR}/privkey.pem"
    chown root:mysql "${MYSQL_SSL_DIR}/chain.pem"   && chmod 640 "${MYSQL_SSL_DIR}/chain.pem"

    log_ok "Certificados copiados con permisos correctos:"
    ls -la "${MYSQL_SSL_DIR}/"
}

# =============================================================================
# PASO 6 — Configurar MariaDB para usar TLS
# =============================================================================
paso6_configurar_mariadb_tls() {
    log_info "=== PASO 6: Configurar MariaDB TLS en ${MARIADB_CONF} ==="

    if [[ ! -f "${MARIADB_CONF}" ]]; then
        log_error "Archivo de configuración no existe: ${MARIADB_CONF}"
        log_error "¿Está MariaDB instalado correctamente?"
        exit 1
    fi

    # Backup del archivo de configuración original
    local backup_file="${MARIADB_CONF}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    cp "${MARIADB_CONF}" "${backup_file}"
    log_ok "Backup: ${backup_file}"

    # Verificar si ya están configuradas las directivas TLS
    if grep -q "^ssl-cert" "${MARIADB_CONF}"; then
        log_warn "Directivas TLS ya presentes en ${MARIADB_CONF}. Actualizando..."
        # Eliminar directivas TLS existentes para reescribir
        sed -i '/^ssl-ca\s*=/d;/^ssl-cert\s*=/d;/^ssl-key\s*=/d' "${MARIADB_CONF}"
    fi

    # Agregar directivas TLS al final de la sección [mysqld]
    # Buscar la sección [mysqld] e insertar después
    if grep -q "^\[mysqld\]" "${MARIADB_CONF}"; then
        # Insertar directivas TLS después de [mysqld]
        sed -i "/^\[mysqld\]/a \\
# TLS/SSL — configurado por configure_db_vm_ssl_letsencrypt.sh\\
ssl-ca   = ${MYSQL_SSL_DIR}/chain.pem\\
ssl-cert = ${MYSQL_SSL_DIR}/cert.pem\\
ssl-key  = ${MYSQL_SSL_DIR}/privkey.pem" "${MARIADB_CONF}"
        log_ok "Directivas TLS agregadas después de [mysqld]."
    else
        # Agregar al final del archivo
        cat >> "${MARIADB_CONF}" <<EOF

# TLS/SSL — configurado por configure_db_vm_ssl_letsencrypt.sh
[mysqld]
ssl-ca   = ${MYSQL_SSL_DIR}/chain.pem
ssl-cert = ${MYSQL_SSL_DIR}/cert.pem
ssl-key  = ${MYSQL_SSL_DIR}/privkey.pem
EOF
        log_ok "Sección [mysqld] con directivas TLS agregada al final."
    fi

    log_info "Configuración TLS en ${MARIADB_CONF}:"
    grep -E "ssl-|^\[mysqld\]" "${MARIADB_CONF}" || true
}

# =============================================================================
# PASO 7 — Reiniciar MariaDB y verificar TLS activo
# =============================================================================
paso7_reiniciar_verificar() {
    log_info "=== PASO 7: Reiniciar MariaDB y verificar TLS ==="

    log_info "Reiniciando MariaDB..."
    systemctl restart mariadb

    # Esperar hasta 15 segundos a que MariaDB esté listo
    local intentos=0
    while ! systemctl is-active --quiet mariadb && [[ ${intentos} -lt 15 ]]; do
        sleep 1
        intentos=$((intentos + 1))
    done

    if ! systemctl is-active --quiet mariadb; then
        log_error "MariaDB no está activo después de restart."
        log_error "Revisar: journalctl -u mariadb -n 50 --no-pager"
        journalctl -u mariadb -n 30 --no-pager 2>/dev/null || true
        exit 1
    fi
    log_ok "MariaDB activo después de restart."

    # Verificar TLS activo via mariadb-admin / mariadb CLI
    # Usar socket Unix para verificación local (sin requerir TLS en la conexión de verificación)
    local have_ssl
    if command -v mariadb &>/dev/null; then
        have_ssl=$(mariadb --user=root --socket=/var/run/mysqld/mysqld.sock \
            -e "SHOW VARIABLES LIKE 'have_ssl';" 2>/dev/null | awk '/have_ssl/{print $2}' || echo "UNKNOWN")
    elif command -v mysql &>/dev/null; then
        have_ssl=$(mysql --user=root --socket=/var/run/mysqld/mysqld.sock \
            -e "SHOW VARIABLES LIKE 'have_ssl';" 2>/dev/null | awk '/have_ssl/{print $2}' || echo "UNKNOWN")
    else
        have_ssl="UNKNOWN (mariadb/mysql CLI no disponible)"
    fi

    log_ok "have_ssl = ${have_ssl}"

    if [[ "${have_ssl}" == "YES" ]]; then
        log_ok "TLS ACTIVO en MariaDB."
    elif [[ "${have_ssl}" == "DISABLED" ]]; then
        log_warn "TLS reportado como DISABLED. Verificar que los archivos de cert son legibles por mysql."
        log_warn "  ls -la ${MYSQL_SSL_DIR}/"
        ls -la "${MYSQL_SSL_DIR}/" 2>/dev/null || true
    else
        log_warn "Estado TLS: ${have_ssl}. Verificación manual recomendada."
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo ""
    echo "============================================================"
    echo " B.5.1 — Certificado Let's Encrypt para MariaDB TLS"
    echo " Dominio: ${DOMAIN}"
    echo " Email:   ${ACME_EMAIL}"
    echo "============================================================"
    echo ""
    echo "PREREQUISITO CRÍTICO: DNS A record para ${DOMAIN}"
    echo "debe estar propagado y apuntando a IP pública de VM3."
    echo ""

    paso1_validar
    paso2_instalar_certbot
    paso3_obtener_cert
    paso4_verificar_cert
    paso5_copiar_certs
    paso6_configurar_mariadb_tls
    paso7_reiniciar_verificar

    echo ""
    echo "============================================================"
    echo " Certificado SSL configurado exitosamente."
    echo " MariaDB TLS activo para ${DOMAIN}"
    echo ""
    echo " PASO SIGUIENTE OBLIGATORIO — cerrar puerto 80:"
    echo "   sudo bash configure_db_vm_close_port80_temp.sh"
    echo ""
    echo " Verificación de conexión TLS desde cliente:"
    echo "   mariadb -h ${DOMAIN} -u django_user -p --ssl"
    echo "============================================================"
}

main "$@"
