#!/bin/bash
# Bootstraps the domain-service host: swap, Docker, a self-hosted MySQL 8.4
# container, Flyway migrations, then the cv-domain-service container.
#
# MySQL runs on this same box (localhost, on the `cv` docker network) instead
# of RDS: no RDS instance cost, no MySQL 8.0 Extended Support charge, and we
# own the major version. DB password + Cognito issuer come from SSM at boot
# via the instance role, so nothing sensitive is baked into this script.
set -euo pipefail

# 2 GB swap: MySQL 8.4 alongside the JVM needs more headroom than the JVM
# alone did on a t3.micro (1 GB RAM). Prefer a t3.small if you want the DB
# and app to run comfortably in RAM without leaning on swap.
dd if=/dev/zero of=/swapfile bs=1M count=2048
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

dnf install -y docker git
systemctl enable --now docker

param() {
  aws ssm get-parameter --with-decryption --region "${aws_region}" \
    --name "/${project_name}/${environment}/$1" \
    --query Parameter.Value --output text
}

DB_PASSWORD=$(param db/password)
COGNITO_ISSUER_URI=$(param cognito/issuer-uri)

docker network create cv || true

# --- Self-hosted MySQL 8.4, tuned for a small box ---
# innodb-buffer-pool-size low + performance_schema off keep the memory
# footprint modest; the host volume persists data across container restarts
# and reboots (it is lost only if the instance itself is replaced).
mkdir -p /var/lib/cv-mysql
docker run -d --name mysql --restart unless-stopped --network cv \
  -e MYSQL_ROOT_PASSWORD="$DB_PASSWORD" \
  -e MYSQL_DATABASE="${db_name}" \
  -e MYSQL_USER="${db_username}" \
  -e MYSQL_PASSWORD="$DB_PASSWORD" \
  -v /var/lib/cv-mysql:/var/lib/mysql \
  mysql:8.4 \
  --innodb-buffer-pool-size=128M --performance-schema=OFF

# --- Flyway migrations (schema only) ---
# Production applies migrations ONLY: the dev-seeds location is deliberately
# excluded (see cv-database afterMigrate__seed_dev.sql). FLYWAY_CONNECT_RETRIES
# lets Flyway wait out MySQL's first-boot init. allowPublicKeyRetrieval is
# required for MySQL 8's caching_sha2_password over the non-TLS docker network.
git clone --depth 1 https://github.com/erfeamor/cv-database.git /opt/cv-database \
  || (cd /opt/cv-database && git pull --ff-only)
docker run --rm --network cv \
  -v /opt/cv-database/sql:/flyway/sql:ro \
  -e FLYWAY_URL="jdbc:mysql://mysql:3306/${db_name}?allowPublicKeyRetrieval=true" \
  -e FLYWAY_USER="${db_username}" \
  -e FLYWAY_PASSWORD="$DB_PASSWORD" \
  -e FLYWAY_LOCATIONS="filesystem:/flyway/sql/migrations" \
  -e FLYWAY_CONNECT_RETRIES=60 \
  flyway/flyway:10 migrate

# --- Domain service (Hibernate ddl-auto=validate against the migrated schema) ---
REGISTRY=$(echo "${image}" | cut -d/ -f1)
aws ecr get-login-password --region "${aws_region}" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# The image is pushed manually/by CI after this instance first boots, so keep
# retrying until it exists rather than failing the boot.
until docker pull "${image}"; do
  echo "image not available yet, retrying in 60s"
  sleep 60
done

docker run -d --name domain-service --restart unless-stopped --network cv \
  -p 8080:8080 \
  -e SPRING_DATASOURCE_URL="jdbc:mysql://mysql:3306/${db_name}?allowPublicKeyRetrieval=true&useSSL=false" \
  -e SPRING_DATASOURCE_USERNAME="${db_username}" \
  -e SPRING_DATASOURCE_PASSWORD="$DB_PASSWORD" \
  -e COGNITO_ISSUER_URI="$COGNITO_ISSUER_URI" \
  -e AUTH_ENABLED=true \
  -e CORS_ALLOWED_ORIGINS="https://${cloudfront_domain},http://localhost:5173,http://localhost:4173" \
  "${image}"
