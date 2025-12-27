#!/bin/bash
set -Eeuo pipefail

# ==============================================================================
# Production-ready Spring Boot REST API deployment
# Target:
#   - API accessible from outside (0.0.0.0:8080)
#   - Idempotent (safe re-run)
#   - No permission / already-exists failures
#   - Secure defaults
# ==============================================================================

APP_NAME=demo
APP_USER=demoapp
APP_PORT=8080
APP_DIR=/opt/${APP_NAME}
DEPLOY_DIR=/opt/apps
JAR_NAME=demo-0.0.1-SNAPSHOT.jar
GIT_REPO=https://github.com/yazdan-centos/demo.git

DB_NAME=demo_db
DB_USER=demo_user
DB_PASS=demo_pass
PG_VERSION=15

SPRING_PROFILE=prod
JAVA_VERSION=17

LOG_DIR=/var/log/${APP_NAME}

# ==============================================================================
# Basic helpers
# ==============================================================================

log() {
  echo "[INFO] $1"
}

warn() {
  echo "[WARN] $1"
}

# ==============================================================================
# System preparation
# ==============================================================================

log "Updating system"
dnf -y update

log "Installing base packages"
dnf -y install git wget curl firewalld java-${JAVA_VERSION}-openjdk-devel

# ==============================================================================
# PostgreSQL install (safe)
# ==============================================================================

if ! rpm -q pgdg-redhat-repo >/dev/null 2>&1; then
  dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm
fi

dnf -qy module disable postgresql || true

if ! rpm -q postgresql${PG_VERSION}-server >/dev/null 2>&1; then
  dnf install -y postgresql${PG_VERSION}-server
fi

PG_DATA=/var/lib/pgsql/${PG_VERSION}/data

if [ ! -f "${PG_DATA}/PG_VERSION" ]; then
  /usr/pgsql-${PG_VERSION}/bin/postgresql-${PG_VERSION}-setup initdb
fi

systemctl enable postgresql-${PG_VERSION}
systemctl start postgresql-${PG_VERSION}

# ==============================================================================
# PostgreSQL configuration
# ==============================================================================

PG_HBA=${PG_DATA}/pg_hba.conf
PG_CONF=${PG_DATA}/postgresql.conf

grep -q "^listen_addresses" "${PG_CONF}" \
  && sed -i "s/^listen_addresses.*/listen_addresses='*'/" "${PG_CONF}" \
  || echo "listen_addresses='*'" >> "${PG_CONF}"

grep -q "0.0.0.0/0" "${PG_HBA}" || \
  echo "host all all 0.0.0.0/0 md5" >> "${PG_HBA}"

systemctl restart postgresql-${PG_VERSION}

# ==============================================================================
# Database & role (idempotent)
# ==============================================================================

sudo -u postgres psql <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='${DB_NAME}') THEN
    CREATE DATABASE ${DB_NAME};
  END IF;
END\$\$;

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}') THEN
    CREATE USER ${DB_USER} WITH ENCRYPTED PASSWORD '${DB_PASS}';
  ELSE
    ALTER USER ${DB_USER} WITH ENCRYPTED PASSWORD '${DB_PASS}';
  END IF;
END\$\$;

GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF

# ==============================================================================
# Application user
# ==============================================================================

if ! id "${APP_USER}" >/dev/null 2>&1; then
  useradd -r -m -s /sbin/nologin "${APP_USER}"
fi

# ==============================================================================
# Clone or update repository
# ==============================================================================

if [ -d "${APP_DIR}/.git" ]; then
  log "Updating application repository"
  git -C "${APP_DIR}" fetch --all
  git -C "${APP_DIR}" reset --hard origin/$(git -C "${APP_DIR}" symbolic-ref --short HEAD)
else
  log "Cloning application repository"
  rm -rf "${APP_DIR}"
  git clone "${GIT_REPO}" "${APP_DIR}"
fi

# ==============================================================================
# Spring configuration (external access enabled)
# ==============================================================================

mkdir -p "${APP_DIR}/src/main/resources"

cat > "${APP_DIR}/src/main/resources/application-prod.properties" <<EOF
server.address=0.0.0.0
server.port=${APP_PORT}

spring.datasource.url=jdbc:postgresql://localhost:5432/${DB_NAME}
spring.datasource.username=${DB_USER}
spring.datasource.password=${DB_PASS}

spring.jpa.hibernate.ddl-auto=update
spring.jpa.open-in-view=false

management.endpoints.web.exposure.include=health,info
EOF

# ==============================================================================
# Build
# ==============================================================================

cd "${APP_DIR}"
chmod +x mvnw
./mvnw clean package -DskipTests

[ -f "target/${JAR_NAME}" ] || {
  echo "Build failed: JAR not found"
  exit 1
}

# ==============================================================================
# Deploy
# ==============================================================================

mkdir -p "${DEPLOY_DIR}" "${LOG_DIR}"

cp "target/${JAR_NAME}" "${DEPLOY_DIR}/${APP_NAME}.jar"
chown "${APP_USER}:${APP_USER}" "${DEPLOY_DIR}/${APP_NAME}.jar"
chown -R "${APP_USER}:${APP_USER}" "${LOG_DIR}"

# ==============================================================================
# systemd service
# ==============================================================================

cat > /etc/systemd/system/${APP_NAME}.service <<EOF
[Unit]
Description=Spring Boot REST API - ${APP_NAME}
After=network.target postgresql-${PG_VERSION}.service
Requires=postgresql-${PG_VERSION}.service

[Service]
User=${APP_USER}
WorkingDirectory=${DEPLOY_DIR}
ExecStart=/usr/bin/java -jar ${DEPLOY_DIR}/${APP_NAME}.jar --spring.profiles.active=${SPRING_PROFILE}
Restart=on-failure
SuccessExitStatus=143
StandardOutput=append:${LOG_DIR}/stdout.log
StandardError=append:${LOG_DIR}/stderr.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ${APP_NAME}
systemctl restart ${APP_NAME}

# ==============================================================================
# Firewall (REST API externally accessible)
# ==============================================================================

systemctl enable firewalld
systemctl start firewalld
firewall-cmd --permanent --add-port=${APP_PORT}/tcp || true
firewall-cmd --reload

# ==============================================================================
# Result
# ==============================================================================

echo
echo "✅ REST API deployment completed"
echo "➡ API URL: http://<SERVER_IP>:${APP_PORT}"
echo "➡ Health check: http://<SERVER_IP>:${APP_PORT}/actuator/health"
