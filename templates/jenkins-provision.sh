#!/bin/bash
# T-002: provisions Jenkins + reverse proxy on the Drone host. Used both
# appended to aws_instance.drone's user_data (future boots) and pushed
# out-of-band via SSM to the live instance (see ci.tf header for the full
# rationale -- kept out of this file to stay under the EC2 user_data size
# limit). All docker/network ops below are convergent and idempotent:
# re-running never fails on "name already in use" and corrects drift.
set -euo pipefail

# Concurrency guard: two invocations (out-of-band + a future user_data boot,
# or two reflexive re-applies) must not race two `docker run --name X` calls
# for the same container.
exec 200>/var/lock/cv-ci-provision.lock
if ! flock -n 200; then
  echo "jenkins-provision: another run is already in progress -- exiting" >&2
  exit 1
fi

param() {
  aws ssm get-parameter --with-decryption --region "${aws_region}" \
    --name "/${project_name}/${environment}/ci/$1" \
    --query Parameter.Value --output text
}

# Recreates container $1 (rest of args = `docker run` opts, image last)
# whenever it's missing, not running, its image digest no longer matches
# $2, or its mounted config has drifted from the fingerprint in $3 (config
# edits don't change the image, so image-drift alone would miss them).
recreate_if_needed() {
  local name="$1" image="$2" config_hash="$3"
  shift 3
  local wanted_id running current_id current_hash
  wanted_id=$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || echo "")
  if docker inspect "$name" >/dev/null 2>&1; then
    running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "false")
    current_id=$(docker inspect -f '{{.Image}}' "$name" 2>/dev/null || echo "")
    current_hash=$(docker inspect -f '{{index .Config.Labels "cv_config_hash"}}' "$name" 2>/dev/null || echo "")
    if [ "$running" = "true" ] && [ "$current_id" = "$wanted_id" ] && [ "$current_hash" = "$config_hash" ]; then
      return 0
    fi
    echo "recreate_if_needed: recreating $name (running=$running, image-drift=$([ "$current_id" != "$wanted_id" ] && echo yes || echo no), config-drift=$([ "$current_hash" != "$config_hash" ] && echo yes || echo no))"
    docker rm -f "$name" >/dev/null 2>&1 || true
  fi
  docker run -d --name "$name" --label "cv_config_hash=$config_hash" "$@" "$image"
}

docker network inspect drone >/dev/null 2>&1 || docker network create drone

# --- Jenkins: files/image first, containers last; Drone is untouched until
# the remediation block near the end, to keep its outage window tight. ----
#
# JENKINS_HOME is a host bind mount kept at an *identical path* inside and
# outside the container: sibling containers Jenkins launches over the
# mounted docker socket are resolved by the *host* daemon against the host
# filesystem, so "$WORKSPACE/x" only maps to a real host dir if $WORKSPACE
# means the same path on both sides.
JENKINS_HOME_DIR=/var/lib/jenkins
mkdir -p "$JENKINS_HOME_DIR" "$JENKINS_HOME_DIR/init.groovy.d"
mkdir -p /var/lib/jenkins-casc

JENKINS_ADMIN_PASSWORD=$(param jenkins-admin-password)
GITHUB_PAT=$(param github-pat)

# Escaping: this file is rendered by Terraform's templatefile() before it
# reaches the instance. Any dollar-brace pair below meant to resolve later
# (JCasC reading its own container env; Docker expanding ENV at image build)
# is written doubled ($${...}) so templatefile emits a literal single-dollar
# form instead of trying to resolve it as an HCL var now. Plain single-$
# references like aws_region are genuine template vars and stay unescaped.
#
# Security does NOT depend on this YAML applying cleanly: a configurator
# error aborts the whole JCasC document, and runSetupWizard=false with no
# realm applied means an unauthenticated Jenkins. init.groovy.d below sets
# the same realm/authorization via the Jenkins API directly (core, plugin-
# independent), so lockdown holds even if this YAML fails outright.
# JDK/Maven use fixed `home:` paths, not auto-installer plugins, since none
# ship in plugins.txt.
cat >/var/lib/jenkins-casc/jenkins.yaml <<'CASC_EOF'
jenkins:
  systemMessage: "cv-project Jenkins -- provisioned by cv-infra (T-002)"
  numExecutors: 1
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
        home: "$${JAVA_HOME}"
  maven:
    installations:
      - name: "maven3"
        home: "$${MAVEN_HOME}"
credentials:
  system:
    domainCredentials:
      - credentials:
          - string:
              scope: GLOBAL
              id: "github-pat"
              secret: "$${GITHUB_PAT}"
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

# Fail-closed security fallback (see note above): runs on every Jenkins
# startup regardless of JCasC's own success. Reads the same env, never a
# literal secret.
cat >"$JENKINS_HOME_DIR/init.groovy.d/basic-security.groovy" <<'GROOVY_EOF'
import jenkins.model.*
import hudson.security.*

def instance = Jenkins.get()

def realm = new HudsonPrivateSecurityRealm(false)
realm.createAccount(System.getenv("JENKINS_ADMIN_USER"), System.getenv("JENKINS_ADMIN_PASSWORD"))
instance.setSecurityRealm(realm)

def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)

instance.save()
GROOVY_EOF

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

# Bind mounts don't inherit image ownership: JENKINS_HOME must be owned by
# the image's uid/gid 1000 ("jenkins") or the container fails to write
# config.xml on first start. Do this last, after every file above exists.
chown -R 1000:1000 "$JENKINS_HOME_DIR"

# Custom image: plugins baked in at build (`docker cp` after start is too
# late), Maven at a fixed path (no auto-installer plugin/runtime download),
# and the docker CLI for both Jenkinsfiles' `agent any` stages to call the
# mounted host socket. `docker build` is cache-idempotent, cheap to re-run.
mkdir -p /opt/jenkins-image
cp /var/lib/jenkins-casc/plugins.txt /opt/jenkins-image/plugins.txt
cat >/opt/jenkins-image/Dockerfile <<'DOCKERFILE_EOF'
FROM jenkins/jenkins:lts-jdk17
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

USER root
RUN curl -fsSL -o /tmp/maven.tar.gz https://dlcdn.apache.org/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz \
  && tar -xzf /tmp/maven.tar.gz -C /opt \
  && ln -s /opt/apache-maven-3.9.9 /opt/maven \
  && rm -f /tmp/maven.tar.gz \
  && apt-get update \
  && apt-get install -y --no-install-recommends docker.io \
  && rm -rf /var/lib/apt/lists/*
ENV MAVEN_HOME=/opt/maven
ENV PATH="$${MAVEN_HOME}/bin:$${PATH}"
USER jenkins
DOCKERFILE_EOF
docker build -t cv-jenkins:local /opt/jenkins-image

# Host docker.sock GID is only known at run time -- granted as a
# supplementary group on the container's uid-1000 user, not baked into the
# image (accepted trade-off, recorded in the PR body).
DRONE_HOST_DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)

# Fingerprint the mounted JCasC/groovy config so recreate_if_needed also
# catches a config-only edit (it doesn't change the image digest).
JENKINS_CONFIG_HASH=$(sha256sum /var/lib/jenkins-casc/jenkins.yaml "$JENKINS_HOME_DIR/init.groovy.d/basic-security.groovy" | sha256sum | awk '{print $1}')

recreate_if_needed jenkins cv-jenkins:local "$JENKINS_CONFIG_HASH" \
  --restart unless-stopped \
  --network drone \
  --group-add "$DRONE_HOST_DOCKER_GID" \
  -v "$JENKINS_HOME_DIR:$JENKINS_HOME_DIR" \
  -e JENKINS_HOME="$JENKINS_HOME_DIR" \
  -v /var/lib/jenkins-casc/jenkins.yaml:/var/jenkins_casc/jenkins.yaml:ro \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e JAVA_OPTS="-Djenkins.install.runSetupWizard=false" \
  -e JENKINS_OPTS="--prefix=/jenkins" \
  -e CASC_JENKINS_CONFIG=/var/jenkins_casc/jenkins.yaml \
  -e JENKINS_ADMIN_USER="${jenkins_admin_username}" \
  -e JENKINS_ADMIN_PASSWORD="$JENKINS_ADMIN_PASSWORD" \
  -e GITHUB_PAT="$GITHUB_PAT"
# No -p 8080:8080 anywhere: Jenkins is reachable only over the "drone"
# docker network, from the proxy container below -- no SG change needed.

# --- Reverse proxy: fronts Drone (/) and Jenkins (/jenkins/) on 80/443 ---
# `resolver` + variable proxy_pass targets force nginx to re-resolve
# container names per request via Docker's embedded DNS instead of caching
# an IP once at config load, so recreating an upstream doesn't 502 the proxy
# until it's restarted too.
mkdir -p /etc/ci-proxy
cat >/etc/ci-proxy/nginx.conf <<'NGINX_EOF'
events {}
http {
  resolver 127.0.0.11 valid=10s;

  server {
    listen 80;

    location /jenkins/ {
      set $jenkins_upstream http://jenkins:8080;
      proxy_pass $jenkins_upstream/jenkins/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_redirect http://jenkins:8080/jenkins/ /jenkins/;
      proxy_read_timeout 90s;
      proxy_buffering off;
      proxy_request_buffering off;
    }

    # Everything else (GitHub's /hook POSTs, Drone's OAuth login/callback)
    # goes to Drone untouched: no path prefix, no Host rewrite -- the OAuth
    # callback URL stays byte-for-byte what it was when Drone bound :80.
    location / {
      set $drone_upstream http://drone-server:80;
      proxy_pass $drone_upstream;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }
  }
}
NGINX_EOF

# --- Remediate a drone-server still publishing host :80 directly ---------
# Kept last and as tight as possible: secrets fetched right before use, and
# the only work between `docker rm` and the new container being `Up` is the
# `docker run` call itself. Drone's SQLite state lives on the /var/lib/drone
# bind mount, not the container, so this is safe and idempotent -- once
# done, the port binding below is gone and every later run is a no-op.
if docker inspect drone-server >/dev/null 2>&1; then
  drone_port80_binding=$(docker inspect -f '{{index .HostConfig.PortBindings "80/tcp"}}' drone-server 2>/dev/null || echo "")
  if [ -n "$drone_port80_binding" ] && [ "$drone_port80_binding" != "<no value>" ] && [ "$drone_port80_binding" != "[]" ] && [ "$drone_port80_binding" != "map[]" ]; then
    DRONE_RPC_SECRET=$(param drone-rpc-secret)
    GITHUB_CLIENT_ID=$(param github-client-id)
    GITHUB_CLIENT_SECRET=$(param github-client-secret)
    echo "jenkins-provision: recreating drone-server without the direct :80 publish"
    docker rm -f drone-server
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
fi

CI_PROXY_CONFIG_HASH=$(sha256sum /etc/ci-proxy/nginx.conf | awk '{print $1}')
recreate_if_needed ci-proxy nginx:alpine "$CI_PROXY_CONFIG_HASH" \
  --restart unless-stopped \
  --network drone \
  -p 80:80 \
  -v /etc/ci-proxy/nginx.conf:/etc/nginx/nginx.conf:ro
