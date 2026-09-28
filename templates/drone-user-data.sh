#!/bin/bash
# Bootstraps the Drone CI host: swap, Docker, then the Drone server and docker
# runner containers. Secrets are fetched from SSM Parameter Store at boot via
# the instance role, so nothing sensitive is baked into this script.
#
# T-002: Drone no longer publishes host port 80 directly. A reverse proxy
# (templates/jenkins-provision.sh, appended after this script in user_data)
# now owns 80/443 and fronts both Drone and Jenkins over the shared "drone"
# docker network, so the SG's existing 80/443 rule keeps serving both
# services without a new ingress rule or a new internet-facing port.
set -euo pipefail

# 1 GB of swap: parallel node builds OOM a bare t3.micro (1 GB RAM) without it.
dd if=/dev/zero of=/swapfile bs=1M count=1024
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

dnf install -y docker
systemctl enable --now docker

param() {
  aws ssm get-parameter --with-decryption --region "${aws_region}" \
    --name "/${project_name}/${environment}/ci/$1" \
    --query Parameter.Value --output text
}

DRONE_RPC_SECRET=$(param drone-rpc-secret)
GITHUB_CLIENT_ID=$(param github-client-id)
GITHUB_CLIENT_SECRET=$(param github-client-secret)
# T-007: encrypts sensitive data (OAuth tokens, activated-repo secrets) at
# rest in Drone's SQLite. Never echoed or logged -- read straight into the
# env var docker run below reads from.
DRONE_DATABASE_SECRET=$(param drone/database-secret)

# Idempotent (review round 1, finding 5): templates/jenkins-provision.sh
# creates this same network with the identical guard, and either script can
# run first on a fresh boot -- a bare `docker network create` would make the
# loser of that race fail on "network already exists".
docker network inspect drone >/dev/null 2>&1 || docker network create drone

docker run -d --name drone-server --restart unless-stopped \
  --network drone \
  -v /var/lib/drone:/data \
  -e DRONE_GITHUB_CLIENT_ID="$GITHUB_CLIENT_ID" \
  -e DRONE_GITHUB_CLIENT_SECRET="$GITHUB_CLIENT_SECRET" \
  -e DRONE_RPC_SECRET="$DRONE_RPC_SECRET" \
  -e DRONE_DATABASE_SECRET="$DRONE_DATABASE_SECRET" \
  -e DRONE_SERVER_HOST="${server_host}" \
  -e DRONE_SERVER_PROTO=http \
  -e DRONE_USER_CREATE="username:${admin_username},admin:true" \
  -e DRONE_USER_FILTER="${admin_username}" \
  drone/drone:2

# DRONE_RUNNER_CAPACITY=1: one pipeline at a time keeps the micro instance
# from OOMing when a pipeline runs several node containers.
docker run -d --name drone-runner --restart unless-stopped \
  --network drone \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e DRONE_RPC_HOST=drone-server \
  -e DRONE_RPC_PROTO=http \
  -e DRONE_RPC_SECRET="$DRONE_RPC_SECRET" \
  -e DRONE_RUNNER_CAPACITY=1 \
  -e DRONE_RUNNER_NAME="${project_name}-runner" \
  drone/drone-runner-docker:1

# T-007 (H1 decision 2, commands per review round 1 finding 3): nothing on
# this host prunes Docker images -- every base-image/tool bump (e.g. Flyway)
# adds a layer set beside the old one, and that whole-disk growth is what
# forced the disk measurement behind this task's root-size choice. A weekly
# sweep keeps the 20 GB root from filling silently between replacements.
#
# `docker image prune -af --filter until=168h` and
# `docker builder prune -af --filter until=168h` -- deliberately NOT
# `docker system prune`, which also removes stopped containers and unused
# networks. -a reaches every unused image, not just dangling ones (that's
# what actually reclaims an old tag left behind by a base-image bump -- a
# plain, non -a prune would not), age-filtered to >1 week so an image pulled
# for a build still in flight this week is never a target. Never touches a
# running container, a named volume, or the "drone" network -- Drone's own
# data lives in the /var/lib/drone bind mount above regardless. Idempotent:
# both unit files are overwritten deterministically and
# `systemctl enable --now` is a no-op if already enabled.
cat >/etc/systemd/system/docker-prune.service <<'EOF'
[Unit]
Description=Weekly docker image/build-cache prune
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker image prune -af --filter until=168h
ExecStart=/usr/bin/docker builder prune -af --filter until=168h
EOF

cat >/etc/systemd/system/docker-prune.timer <<'EOF'
[Unit]
Description=Weekly timer for docker-prune.service

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now docker-prune.timer
