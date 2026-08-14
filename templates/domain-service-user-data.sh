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

dnf install -y docker git xfsprogs
systemctl enable --now docker

param() {
  aws ssm get-parameter --with-decryption --region "${aws_region}" \
    --name "/${project_name}/${environment}/$1" \
    --query Parameter.Value --output text
}

DB_PASSWORD=$(param db/password)
COGNITO_ISSUER_URI=$(param cognito/issuer-uri)

docker network create cv || true

# --- Mount the dedicated MySQL EBS volume (T-018) ---
# This runs before the MySQL container starts (ruling 4) so /var/lib/cv-mysql
# is already backed by the persistent volume -- not the instance's root
# volume -- by the time `docker run` binds it in.
#
# Ruling 2: nitro instances present EBS volumes as /dev/nvme<N>n1 with N not
# stable across boots, so never resolve by device name. Go by volume ID via
# the udev by-id symlink instead (AWS renders the ID without its "vol-"
# hyphen in that symlink name).
MYSQL_VOLUME_ID_NO_HYPHEN=$(echo "${mysql_volume_id}" | tr -d '-')
MYSQL_DEVICE="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$MYSQL_VOLUME_ID_NO_HYPHEN"

# The by-id symlink appears once udev processes the attachment, which can
# happen slightly after this script starts (Terraform creates the instance,
# whose user_data starts running at boot, before it creates the
# aws_volume_attachment resource that actually attaches the volume). Wait
# rather than fail on the first boot's inherent race.
for i in $(seq 1 90); do
  [ -e "$MYSQL_DEVICE" ] && break
  echo "waiting for $MYSQL_DEVICE to appear ($i/90)"
  sleep 2
done
if [ ! -e "$MYSQL_DEVICE" ]; then
  echo "FATAL: $MYSQL_DEVICE never appeared -- refusing to start MySQL without its data volume" >&2
  exit 1
fi

mkdir -p /var/lib/cv-mysql

# Ruling 3: format ONLY a genuinely empty volume, fail closed. blkid exits 2
# when it finds no recognizable filesystem signature at all -- that's the
# one case safe to format (first boot, brand-new volume). Any other outcome
# (0 = a filesystem is already there, e.g. a reattach after replacement; or
# anything else = detection was ambiguous or errored) must NOT trigger
# mkfs. An unconditional mkfs here would reformat the database on every
# instance replacement -- the exact failure this task exists to prevent,
# arriving disguised as a healthy boot.
set +e
blkid "$MYSQL_DEVICE" >/dev/null 2>&1
BLKID_STATUS=$?
set -e
case "$BLKID_STATUS" in
  2)
    echo "$MYSQL_DEVICE has no filesystem -- first boot, formatting"
    mkfs.xfs "$MYSQL_DEVICE"
    ;;
  0)
    echo "$MYSQL_DEVICE already has a filesystem -- reattach, not formatting"
    ;;
  *)
    echo "FATAL: blkid on $MYSQL_DEVICE was ambiguous (exit $BLKID_STATUS) -- refusing to format or mount an unidentified volume" >&2
    exit 1
    ;;
esac

# Ruling 4: persist by UUID (never by device name -- see ruling 2 on why
# device names aren't stable here) with nofail, so on a later reboot a
# missing/detached volume degrades to a failed MySQL container rather than
# an instance that fails to boot and can't even be reached via SSM to
# diagnose.
MYSQL_VOLUME_UUID=$(blkid -s UUID -o value "$MYSQL_DEVICE")
if ! grep -q "$MYSQL_VOLUME_UUID" /etc/fstab; then
  echo "UUID=$MYSQL_VOLUME_UUID /var/lib/cv-mysql xfs defaults,nofail 0 2" >> /etc/fstab
fi
mount /var/lib/cv-mysql

# --- Self-hosted MySQL 8.4, tuned for a small box ---
# innodb-buffer-pool-size low + performance_schema off keep the memory
# footprint modest. Data now lives on the dedicated EBS volume mounted
# above (T-018), so it survives instance replacement -- ruling 5: this
# starts empty and Flyway (below) rebuilds the schema; there is no
# migration path for pre-T-018 data, which the previous replacement already
# discarded.
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

# The dump is the entire database, so it must never be readable outside root
# while it sits on local disk. Root's default umask here is 022, which would
# create it 0644 — world-readable for the whole window between the redirect
# below and the rm. Nothing else on this box can read /tmp today, but that is a
# property of what happens to run here, not of this script; 077 makes it hold
# regardless.
umask 077

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
