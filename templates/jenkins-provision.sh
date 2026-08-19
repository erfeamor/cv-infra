#!/bin/bash
# T-002: Jenkins + reverse proxy on the Drone host. Used both in user_data
# (future boots) and pushed via SSM to the live instance (rationale in
# ci.tf, kept out of here for user_data size). All ops are convergent and
# idempotent.
set -euo pipefail

# Concurrency guard; waits (not fail-fast) since both paths are idempotent.
exec 200>/var/lock/cv-ci-provision.lock
if ! flock -w 1500 200; then
  echo "jenkins-provision: another run held the lock for over 1500s -- exiting" >&2
  exit 1
fi

param() {
  aws ssm get-parameter --with-decryption --region "${aws_region}" \
    --name "/${project_name}/${environment}/ci/$1" \
    --query Parameter.Value --output text
}

# Recreates $1 (opts.., image last) when missing/stopped/drifted ($2 image, $3 config hash).
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
    docker rm -f -v "$name" >/dev/null 2>&1 || true # -v: drop anon volumes too
  fi
  docker run -d --name "$name" --label "cv_config_hash=$config_hash" "$@" "$image"
}

docker network inspect drone >/dev/null 2>&1 || docker network create drone

# Jenkins: files/image first, containers last (Drone untouched till the end).
# JENKINS_HOME mounted at an identical host/container path -- sibling
# containers launched via the socket resolve host paths, so $WORKSPACE
# must mean the same thing both sides. HOME overridden too (image bakes
# HOME=/var/jenkins_home) so ~/.m2 isn't a discarded anon volume.
JENKINS_HOME_DIR=/var/lib/jenkins
mkdir -p "$JENKINS_HOME_DIR" "$JENKINS_HOME_DIR/init.groovy.d"
mkdir -p /var/lib/jenkins-casc

JENKINS_ADMIN_PASSWORD=$(param jenkins-admin-password)
GITHUB_PAT=$(param github-pat)

# Doubled-dollar placeholders below resolve later (JCasC/Docker env), not
# now via templatefile(). Security doesn't depend on this YAML applying
# cleanly -- a configurator error aborts the whole doc, so init.groovy.d
# below sets the same realm/authorization via the Jenkins API directly
# (plugin-independent) as a fail-closed fallback. JDK/Maven use fixed
# `home:` paths, not auto-installer plugins (none in plugins.txt).
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
      # usernamePassword, NOT Secret Text: github-branch-source looks up
      # StandardUsernamePasswordCredentials specifically and silently falls
      # back to anonymous (no commit-status POST) otherwise.
      - credentials:
          - usernamePassword:
              scope: GLOBAL
              id: "github-pat"
              username: "x-access-token"
              password: "$${GITHUB_PAT}"
              description: "cv-project GitHub PAT (commit-status only, T-002)"
unclassified:
  # Empty root URL => no target URL on the commit status github-branch-source posts.
  location:
    url: "http://${server_host}/jenkins/"
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
                // Both REQUIRED by the plugin ctor; omitting them aborts
                // JCasC and Jenkins never boots. false => repoOwner wins.
                repositoryUrl('https://github.com/erfeamor/cv-domain-service')
                configuredByUrl(false)
                credentialsId('github-pat')
                // Public repo + mounted docker.sock: an untrusted
                // Jenkinsfile is RCE-on-host. Explicit traits pin this --
                // branches + origin PRs on, fork PRs deliberately absent.
                // Not boilerplate; do not delete.
                traits {
                  gitHubBranchDiscovery {
                    strategyId(1) // exclude branches also filed as a PR
                  }
                  gitHubPullRequestDiscovery {
                    strategyId(1) // merge PR with target branch, then build
                  }
                }
              }
            }
          }
        }
        // T-019: finds pushes missed while stopped. Why: ci-on-demand.tf
        triggers {
          periodicFolderTrigger { interval('5m') }
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
                repositoryUrl('https://github.com/erfeamor/cv-database')
                configuredByUrl(false)
                credentialsId('github-pat')
                // Same reasoning as cv-domain-service above -- not boilerplate.
                traits {
                  gitHubBranchDiscovery {
                    strategyId(1)
                  }
                  gitHubPullRequestDiscovery {
                    strategyId(1)
                  }
                }
              }
            }
          }
        }
        // T-019: finds pushes missed while stopped. Why: ci-on-demand.tf
        triggers {
          periodicFolderTrigger { interval('5m') }
        }
        orphanedItemStrategy {
          discardOldItems { numToKeep(20) }
        }
      }
CASC_EOF

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
junit
PLUGINS_EOF

# Bind mounts don't inherit image ownership -- chown to uid/gid 1000 or
# the container fails to write config.xml on first start.
chown -R 1000:1000 "$JENKINS_HOME_DIR"
mkdir -p /opt/jenkins-image
cp /var/lib/jenkins-casc/plugins.txt /opt/jenkins-image/plugins.txt
cat >/opt/jenkins-image/Dockerfile <<'DOCKERFILE_EOF'
FROM jenkins/jenkins:lts-jdk17
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

USER root
# docker-cli NOT docker.io: on Debian 13 the latter only *Recommends* the
# client, so --no-install-recommends yields no /usr/bin/docker. Client is
# all we want anyway -- the daemon is the host's, via the socket.
# archive.apache.org (immutable; dlcdn 404s once superseded), sha512-verified.
RUN curl -fsSL -o /tmp/maven.tar.gz https://archive.apache.org/dist/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz \
  && curl -fsSL -o /tmp/maven.tar.gz.sha512 https://archive.apache.org/dist/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz.sha512 \
  && echo "$(awk '{print $1}' /tmp/maven.tar.gz.sha512)  /tmp/maven.tar.gz" | sha512sum -c - \
  && tar -xzf /tmp/maven.tar.gz -C /opt \
  && ln -s /opt/apache-maven-3.9.9 /opt/maven \
  && rm -f /tmp/maven.tar.gz /tmp/maven.tar.gz.sha512 \
  && apt-get update \
  && apt-get install -y --no-install-recommends docker-cli \
  && rm -rf /var/lib/apt/lists/*
ENV MAVEN_HOME=/opt/maven
ENV PATH="$${MAVEN_HOME}/bin:$${PATH}"
USER jenkins
DOCKERFILE_EOF
docker build -t cv-jenkins:local /opt/jenkins-image

# Host docker.sock GID known only at run time (accepted trade-off, PR body).
DRONE_HOST_DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)

# Fingerprints config + GID + secrets (via process substitution, never a
# file) so a rotated secret/changed GID isn't missed by image-digest alone.
JENKINS_CONFIG_HASH=$(cat /var/lib/jenkins-casc/jenkins.yaml "$JENKINS_HOME_DIR/init.groovy.d/basic-security.groovy" \
  <(echo "$DRONE_HOST_DOCKER_GID") <(echo "$JENKINS_ADMIN_PASSWORD") <(echo "$GITHUB_PAT") \
  | sha256sum | awk '{print $1}')

recreate_if_needed jenkins cv-jenkins:local "$JENKINS_CONFIG_HASH" \
  --restart unless-stopped \
  --network drone \
  --group-add "$DRONE_HOST_DOCKER_GID" \
  -v "$JENKINS_HOME_DIR:$JENKINS_HOME_DIR" \
  -e JENKINS_HOME="$JENKINS_HOME_DIR" \
  -e HOME="$JENKINS_HOME_DIR" \
  -v /var/lib/jenkins-casc/jenkins.yaml:/var/jenkins_casc/jenkins.yaml:ro \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e JAVA_OPTS="-Djenkins.install.runSetupWizard=false" \
  -e JENKINS_OPTS="--prefix=/jenkins" \
  -e CASC_JENKINS_CONFIG=/var/jenkins_casc/jenkins.yaml \
  -e JENKINS_ADMIN_USER="${jenkins_admin_username}" \
  -e JENKINS_ADMIN_PASSWORD="$JENKINS_ADMIN_PASSWORD" \
  -e GITHUB_PAT="$GITHUB_PAT"
# No -p 8080:8080: Jenkins is reachable only over "drone", via the proxy.

# Reverse proxy fronts Drone (/) and Jenkins (/jenkins/) on 80/443.
# resolver + variable proxy_pass re-resolve container names per request
# instead of caching an IP, so an upstream recreate doesn't 502.
mkdir -p /etc/ci-proxy
cat >/etc/ci-proxy/nginx.conf <<'NGINX_EOF'
events {}
http {
  resolver 127.0.0.11 valid=10s;

  server {
    listen 80;

    location /jenkins/ {
      # No URI part after the variable: with one, nginx replaces the whole
      # request URI with it on every request (collapsing every path to a
      # bare /jenkins/); with none, the original URI passes through, which
      # --prefix=/jenkins expects.
      set $jenkins_upstream http://jenkins:8080;
      proxy_pass $jenkins_upstream;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_redirect http://jenkins:8080/jenkins/ /jenkins/;
      proxy_read_timeout 90s;
      proxy_buffering off;
      proxy_request_buffering off;
    }

    # Everything else (GitHub /hook, Drone OAuth) goes to Drone untouched.
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

# Remediates a drone-server still publishing :80 directly; kept last and
# tight (secrets fetched right before use). State is on the bind mount, so
# recreation is safe and this is a no-op once done.
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

# Health check: `docker run -d` only proves creation, not serving.
docker exec ci-proxy nginx -t
health_elapsed=0
health_timeout_s=120
health_poll_s=5
while :; do
  if curl -sf -o /dev/null "http://localhost/jenkins/login"; then
    echo "jenkins-provision: ci-proxy is serving Jenkins."
    break
  fi
  if [ "$health_elapsed" -ge "$health_timeout_s" ]; then
    echo "jenkins-provision: /jenkins/login never came up through ci-proxy within $${health_timeout_s}s" >&2
    exit 1
  fi
  sleep "$health_poll_s"
  health_elapsed=$((health_elapsed + health_poll_s))
done
