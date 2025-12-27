#!/bin/bash

# Variables
APP_NAME=demo
GIT_REPO=https://github.com/yazdan-centos/demo.git
APP_DIR=/opt/$APP_NAME
JAR_NAME=demo-0.0.1-SNAPSHOT.jar
DB_NAME=demo_db
DB_USER=demo_user
DB_PASS=demo_pass
SPRING_PROFILE=prod
PG_VERSION=13

# Update system
dnf -y update

# Install required packages
dnf -y install git java-17-openjdk-devel wget

# Install PostgreSQL
dnf -y install https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-almalinux-repo-latest.noarch.rpm
dnf -qy module disable postgresql
dnf -y install postgresql$PG_VERSION-server postgresql$PG_VERSION

# Initialize and start PostgreSQL
/usr/pgsql-$PG_VERSION/bin/postgresql-$PG_VERSION-setup initdb
systemctl enable --now postgresql-$PG_VERSION

# Setup PostgreSQL user and database
sudo -u postgres psql <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER $DB_USER WITH ENCRYPTED PASSWORD '$DB_PASS';
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
EOF

# Allow password authentication
PG_HBA=/var/lib/pgsql/$PG_VERSION/data/pg_hba.conf
sed -i "s/^host.*all.*all.*127.0.0.1\/32.*$/host    all             all             0.0.0.0\/0            md5/" $PG_HBA
sed -i "s/^host.*all.*all.*::1\/128.*$/host    all             all             ::1\/128                 md5/" $PG_HBA
echo "listen_addresses='*'" >> /var/lib/pgsql/$PG_VERSION/data/postgresql.conf
systemctl restart postgresql-$PG_VERSION

# Clone application
git clone $GIT_REPO $APP_DIR

# Build application
cd $APP_DIR
./mvnw clean package -DskipTests

# Configure application properties
cat > $APP_DIR/src/main/resources/application.properties <<EOL
spring.datasource.url=jdbc:postgresql://localhost:5432/$DB_NAME
spring.datasource.username=$DB_USER
spring.datasource.password=$DB_PASS
spring.jpa.hibernate.ddl-auto=update
EOL

# Copy built jar to a standard location
cp $APP_DIR/target/$JAR_NAME /opt/$JAR_NAME

# Create systemd service
cat > /etc/systemd/system/$APP_NAME.service <<EOL
[Unit]
Description=Spring Boot Application - $APP_NAME
After=network.target

[Service]
User=root
WorkingDirectory=/opt
ExecStart=/usr/bin/java -jar /opt/$JAR_NAME --spring.profiles.active=$SPRING_PROFILE
SuccessExitStatus=143
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd and start service
systemctl daemon-reload
systemctl enable --now $APP_NAME

echo "Deployment complete. App should be running as a service."