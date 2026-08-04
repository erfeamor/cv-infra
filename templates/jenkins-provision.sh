#!/bin/bash
# T-002: provisions Jenkins (multibranch CI for cv-domain-service and
# cv-database) plus a reverse proxy that fronts both Drone and Jenkins on
# the existing 80/443 ingress. This script is used two ways (H1 decision 1):
#
#   1. Appended to aws_instance.drone's user_data (via ci.tf) so a *future*
#      instance replacement self-provisions Jenkins from scratch.
#   2. Pushed to the *live* instance out-of-band (SSM Run Command, driven by
#      null_resource.jenkins_provision in ci.tf), because aws_instance.drone
#      intentionally has no user_data_replace_on_change -- editing user_data
#      alone updates Terraform state only and cloud-init never re-runs on a
#      box that's already up (see compute.tf's note; this exact bug shipped
#      once). Out-of-band execution is what actually installs Jenkins today.
#
# Every docker/network operation below is guarded so re-running this script
# (case 2, repeatedly, or after a case-1 boot) never fails on "container
# name already in use" and never re-creates a container that's already
# correctly configured. Secrets are fetched from SSM Parameter Store via the
# instance role at run time -- nothing sensitive is written to this file or
# baked into the image.
set -euo pipefail

param() {
  aws ssm get-parameter --with-decryption --region "${aws_region}" \
    --name "/${project_name}/${environment}/ci/$1" \
    --query Parameter.Value --output text
}

docker network inspect drone >/dev/null 2>&1 || docker network create drone

# --- Remediate a drone-server that still publishes host :80 directly -----
# Before this task, drone-server bound -p 80:80 itself. The proxy below now
# owns 80, so if the live container still holds the old port mapping,
# recreate it (Drone's SQLite state lives on the /var/lib/drone bind mount,
# not in the container, so this is safe and idempotent -- once recreated
# without the mapping, this block is a no-op on every later run).
if docker inspect drone-server >/dev/null 2>&1 && \
   docker inspect drone-server --format '{{range $p, $c := .HostConfig.PortBindings}}{{$p}} {{end}}' | grep -q '80/tcp'; then
  echo "jenkins-provision: recreating drone-server without the direct :80 publish"
  docker rm -f drone-server
  DRONE_RPC_SECRET=$(param drone-rpc-secret)
  GITHUB_CLIENT_ID=$(param github-client-id)
  GITHUB_CLIENT_SECRET=$(param github-client-secret)
  docker run -d --name drone-server --restart unless-stopped \
    --network drone \
    -v /var/lib/drone:/data \
    -e DRONE_GITHUB_CLIENT_ID="$GITHUB_CLIENT_ID" \
    -e DRONE_GITHUB_CLIENT_SECRET="$GITHUB_CLIENT_SECRET" \
    -e DRONE_RPC_SECRET="$DRONE_RPC_SECRET" \
    -e DRONE_SERVER_HOST="${server_host}" \
    -e DRONE_SERVER_PROTO=http \
    -e DRONE_USER_CREATE="username:${admin_username},admin:true" \
    -e DRONE_USER_FILTER="${admin_username}" \
    drone/drone:2
fi

# --- Jenkins controller ---------------------------------------------------
# JENKINS_HOME lives on a host path bind mount (not the container's
# writable layer) so config, credentials and job history survive both a
# container recreation and an instance reboot (acceptance criterion:
# "Jenkins survives an instance reboot with jobs and credentials intact").
mkdir -p /var/lib/jenkins
mkdir -p /var/lib/jenkins-casc

JENKINS_ADMIN_PASSWORD=$(param jenkins-admin-password)
GITHUB_PAT=$(param github-pat)

# Security realm + authorization are configured from first boot via
# Configuration-as-Code: Jenkins never starts in the unauthenticated setup
# wizard state, and the admin password is passed only as a process env var
# to the container -- it is never written to this file, to JENKINS_HOME, or
# to terraform.tfvars/state.
#
# Escaping note: this .sh file is itself rendered by Terraform's
# templatefile() before it ever reaches the instance, and templatefile
# resolves any dollar-brace sequence as an HCL interpolation right now. The
# three JCasC placeholders just below (Jenkins admin user/password, the
# GitHub PAT) must survive that pass unresolved, because they are meant to
# be substituted later, by Jenkins itself, from the container's own env
# vars, at Jenkins startup -- so each is written with a doubled leading
# dollar sign, which templatefile collapses to a literal single one in the
# script that actually lands on the instance.
cat >/var/lib/jenkins-casc/jenkins.yaml <<'CASC_EOF'
jenkins:
  systemMessage: "cv-project Jenkins -- provisioned by cv-infra (T-002)"
  numExecutors: 2
  securityRealm:
    local:
      allowsSignup: false
      users:
        - id: "$${JENKINS_ADMIN_USER}"
          password: "$${JENKINS_ADMIN_PASSWORD}"
  authorizationStrategy:
    loggedInUsersCanDoAnything:
      allowAnonymousRead: false
tool:
  jdk:
    installations:
      - name: "jdk17"
        properties:
          - installSource:
              installers:
                - adoptOpenJdkInstaller:
                    id: "jdk-17.0.9+9"
  maven:
    installations:
      - name: "maven3"
        properties:
          - installSource:
              installers:
                - maven:
                    id: "3.9.6"
credentials:
  system:
    domainCredentials:
      - credentials:
          - usernamePassword:
              scope: GLOBAL
              id: "github-pat"
              username: "x-access-token"
              password: "$${GITHUB_PAT}"
              description: "cv-project GitHub PAT (commit-status only, T-002)"
jobs:
  - script: |
      multibranchPipelineJob('cv-domain-service') {
        branchSources {
          branchSource {
            source {
              github {
                id('cv-domain-service')
                repoOwner('erfeamor')
                repository('cv-domain-service')
                credentialsId('github-pat')
              }
            }
          }
        }
        orphanedItemStrategy {
          discardOldItems { numToKeep(20) }
        }
      }
  - script: |
      multibranchPipelineJob('cv-database') {
        branchSources {
          branchSource {
            source {
              github {
                id('cv-database')
                repoOwner('erfeamor')
                repository('cv-database')
                credentialsId('github-pat')
              }
            }
          }
        }
        orphanedItemStrategy {
          discardOldItems { numToKeep(20) }
        }
      }
CASC_EOF

cat >/var/lib/jenkins-casc/plugins.txt <<'PLUGINS_EOF'
configuration-as-code
workflow-aggregator
git
github
github-branch-source
credentials-binding
job-dsl
pipeline-stage-view
PLUGINS_EOF

# Build a small local image with plugins baked in at build time -- plugins
# dropped via `docker cp` after the container starts are never picked up by
# the official image's entrypoint, so this must happen at image build.
# `docker build` is itself idempotent/cached, so re-running this is cheap.
mkdir -p /opt/jenkins-image
cp /var/lib/jenkins-casc/plugins.txt /opt/jenkins-image/plugins.txt
cat >/opt/jenkins-image/Dockerfile <<'DOCKERFILE_EOF'
FROM jenkins/jenkins:lts-jdk17
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
DOCKERFILE_EOF
docker build -t cv-jenkins:local /opt/jenkins-image

# --name-guarded: safe to re-run. Jenkins is NEVER published on a host port
# directly (no -p 8080:8080 anywhere) -- it is reachable only over the
# "drone" docker network, from the proxy container below. That is what
# keeps the raw Jenkins port unreachable from the internet, with no SG
# change needed.
docker inspect jenkins >/dev/null 2>&1 || docker run -d --name jenkins --restart unless-stopped \
  --network drone \
  -v /var/lib/jenkins:/var/jenkins_home \
  -v /var/lib/jenkins-casc/jenkins.yaml:/var/jenkins_casc/jenkins.yaml:ro \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e JAVA_OPTS="-Djenkins.install.runSetupWizard=false" \
  -e JENKINS_OPTS="--prefix=/jenkins" \
  -e CASC_JENKINS_CONFIG=/var/jenkins_casc/jenkins.yaml \
  -e JENKINS_ADMIN_USER="${jenkins_admin_username}" \
  -e JENKINS_ADMIN_PASSWORD="$JENKINS_ADMIN_PASSWORD" \
  -e GITHUB_PAT="$GITHUB_PAT" \
  cv-jenkins:local

# --- Reverse proxy: fronts Drone (/) and Jenkins (/jenkins/) on 80/443 ---
# A real proxy container is required here, not a one-line SG change: port
# 80 was fully claimed by drone-server's own -p 80:80 (now removed above).
mkdir -p /etc/ci-proxy
cat >/etc/ci-proxy/nginx.conf <<'NGINX_EOF'
events {}
http {
  server {
    listen 80;

    location /jenkins/ {
      proxy_pass http://jenkins:8080/jenkins/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_redirect http://jenkins:8080/jenkins/ /jenkins/;
      proxy_read_timeout 90s;
      proxy_buffering off;
      proxy_request_buffering off;
    }

    # Everything else -- including GitHub's webhook POSTs to /hook and
    # Drone's own OAuth login/callback -- goes to Drone untouched: no path
    # prefix, no Host rewrite. DRONE_SERVER_HOST keeps pointing at the EIP,
    # so the OAuth callback URL is byte-for-byte the same as when Drone
    # bound :80 directly; only the hop in front of it changed.
    location / {
      proxy_pass http://drone-server:80;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }
  }
}
NGINX_EOF

docker inspect ci-proxy >/dev/null 2>&1 || docker run -d --name ci-proxy --restart unless-stopped \
  --network drone \
  -p 80:80 \
  -v /etc/ci-proxy/nginx.conf:/etc/nginx/nginx.conf:ro \
  nginx:alpine
