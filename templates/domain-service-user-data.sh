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

# --- Nightly MySQL backup: mysqldump -> S3 (T-001) ---
# RDS's managed backups went away when MySQL moved onto this instance (see
# CLAUDE.md's "No RDS" decision) -- this timer is the replacement. The dump
# script re-reads the DB password from SSM at run time rather than reusing
# this boot script's copy: a systemd timer fires long after this process has
# exited, so nothing sensitive can be inherited from this shell.
cat > /usr/local/bin/mysql-backup.sh <<'BACKUP_SCRIPT'
#!/bin/bash
set -euo pipefail

DB_PASSWORD=$(aws ssm get-parameter --with-decryption --region "${aws_region}" \
  --name "/${project_name}/${environment}/db/password" \
  --query Parameter.Value --output text)

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
DUMP_FILE="/tmp/mysql-dump-$TIMESTAMP.sql.gz"

# pipefail (set above) makes this pipeline's exit status the FIRST non-zero
# exit among mysqldump/gzip, so a mysqldump failure mid-stream is caught
# here even though gzip itself always exits 0. The dump lands in a local
# temp file first and is uploaded only if the pipeline succeeded AND the
# file is non-empty -- a bad run therefore never reaches S3, let alone
# clobbers the last good dump (every upload also gets its own timestamped
# key, for the same reason).
if ! docker exec mysql mysqldump -u root -p"$DB_PASSWORD" --single-transaction --quick "${db_name}" | gzip > "$DUMP_FILE"; then
  echo "mysqldump failed -- not uploading a partial dump" >&2
  rm -f "$DUMP_FILE"
  exit 1
fi

if [ ! -s "$DUMP_FILE" ]; then
  echo "dump file is empty -- not uploading" >&2
  rm -f "$DUMP_FILE"
  exit 1
fi

aws s3 cp "$DUMP_FILE" "s3://${backup_bucket}/${backup_prefix}/${db_name}-$TIMESTAMP.sql.gz"
rm -f "$DUMP_FILE"
BACKUP_SCRIPT
chmod 700 /usr/local/bin/mysql-backup.sh

cat > /etc/systemd/system/mysql-backup.service <<'EOF'
[Unit]
Description=Nightly mysqldump of the self-hosted MySQL container to S3
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mysql-backup.sh
EOF

cat > /etc/systemd/system/mysql-backup.timer <<'EOF'
[Unit]
Description=Nightly trigger for mysql-backup.service

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now mysql-backup.timer
