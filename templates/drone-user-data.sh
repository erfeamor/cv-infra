#!/bin/bash
# Bootstraps the Drone CI host: swap, Docker, then the Drone server and docker
# runner containers. Secrets are fetched from SSM Parameter Store at boot via
# the instance role, so nothing sensitive is baked into this script.
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

docker network create drone

docker run -d --name drone-server --restart unless-stopped \
  --network drone \
  -p 80:80 \
  -v /var/lib/drone:/data \
  -e DRONE_GITHUB_CLIENT_ID="$GITHUB_CLIENT_ID" \
  -e DRONE_GITHUB_CLIENT_SECRET="$GITHUB_CLIENT_SECRET" \
  -e DRONE_RPC_SECRET="$DRONE_RPC_SECRET" \
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
