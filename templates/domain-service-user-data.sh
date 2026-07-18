#!/bin/bash
# Bootstraps the domain-service host: swap, Docker, then the cv-domain-service
# container pulled from ECR. DB password and Cognito issuer come from SSM at
# boot via the instance role, so nothing sensitive is baked into this script.
set -euo pipefail

# 1 GB of swap: the JVM plus MySQL driver OOM a bare t3.micro (1 GB RAM).
dd if=/dev/zero of=/swapfile bs=1M count=1024
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

dnf install -y docker
systemctl enable --now docker

param() {
  aws ssm get-parameter --with-decryption --region "${aws_region}" \
    --name "/${project_name}/${environment}/$1" \
    --query Parameter.Value --output text
}

DB_PASSWORD=$(param db/password)
COGNITO_ISSUER_URI=$(param cognito/issuer-uri)

REGISTRY=$(echo "${image}" | cut -d/ -f1)
aws ecr get-login-password --region "${aws_region}" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# The image is pushed manually/by CI after this instance first boots, so keep
# retrying until it exists rather than failing the boot.
until docker pull "${image}"; do
  echo "image not available yet, retrying in 60s"
  sleep 60
done

# allowPublicKeyRetrieval: MySQL 8 + the bundled driver hang without it (see
# meta repo CLAUDE.md); the RDS endpoint already includes the port.
docker run -d --name domain-service --restart unless-stopped \
  -p 8080:8080 \
  -e SPRING_DATASOURCE_URL="jdbc:mysql://${db_endpoint}/${db_name}?allowPublicKeyRetrieval=true&useSSL=true" \
  -e SPRING_DATASOURCE_USERNAME="${db_username}" \
  -e SPRING_DATASOURCE_PASSWORD="$DB_PASSWORD" \
  -e COGNITO_ISSUER_URI="$COGNITO_ISSUER_URI" \
  -e AUTH_ENABLED=true \
  -e CORS_ALLOWED_ORIGINS="https://${cloudfront_domain},http://localhost:5173,http://localhost:4173" \
  "${image}"
