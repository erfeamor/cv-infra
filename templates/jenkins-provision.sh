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

# T-007 review round 1, finding 5, corrected round 2 (BLOCKER): a cloud-init
# readiness wait (`cloud-init` "status", "--wait") used to live here. It
# deadlocked: this exact script also runs INSIDE cloud-init on the
# user_data path (templates/jenkins-bootstrap.sh's `bash "$provision_script"`,
# itself invoked by cloud-init's own user_data run) -- a script waiting for
# cloud-init to finish, while it IS the thing cloud-init is currently
# running, never returns, and the out-of-band SSM copy then times out
# waiting on the same lock (held by the deadlocked user_data run). The wait
# this script still needs (so a fresh-replace SSM run doesn't race
# cloud-init's Docker install/network-create in drone-user-data.sh) now
# lives ONLY in the SSM command path that is never itself inside cloud-init
# -- see ci.tf's null_resource.jenkins_provision, which runs that same
# readiness check as a command BEFORE this script's own content, not
# inside it. scripts/check-t007-static.sh's Check D fails if this script
# ever calls that command directly again (deliberately not spelled out
# verbatim in this comment, so the check stays meaningful).

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

# T-034 phase 2: the DNS-on-boot updater. Written and enabled here (not just
# in templates/drone-user-data.sh) because THIS script is the one pushed to
# the LIVE box out-of-band (ci.tf's null_resource.jenkins_provision) --
# `systemctl enable` makes it fire on every FUTURE boot automatically, via
# systemd, with no further action from this script; `--now` also runs it
# immediately as part of THIS run, which is what gets today's IP recorded.
# Deliberately BEFORE the docker network/Jenkins/proxy setup below: on a warm
# reboot (not running this script at all -- see the header comment), Docker
# itself restarts every `--restart unless-stopped` container, including
# ci-proxy, the instant docker.service starts. Before=docker.service in the
# unit itself is what actually wins that race on THOSE boots; ordering it
# first in THIS script only matters for a run that also touches Docker
# (a fresh replace, or this SSM push), and costs nothing either way.
cat >/usr/local/bin/ci-dns-updater.sh <<'DNS_UPDATER_EOF'
${dns_updater_script}
DNS_UPDATER_EOF
chmod 755 /usr/local/bin/ci-dns-updater.sh

# Review round 1, finding 3: restarting on failure (with RestartSec + a
# start limit, set on the unit below) is a SECOND, systemd-level retry layer
# on top of
# scripts/ci-dns-updater.sh's OWN internal retry/backoff -- the script gives
# up after its own bounded attempts (RETRY_MAX_ATTEMPTS), and if it still
# exits non-zero, systemd gets another few tries at the whole thing rather
# than leaving it stopped until the next boot or the next timer tick.
# StartLimitIntervalSec/StartLimitBurst belong in [Unit], not [Service] --
# systemd rejects them silently misplaced (they're simply ignored, not an
# error, which makes this exact mistake easy to ship unnoticed).
cat >/etc/systemd/system/ci-dns-updater.service <<'DNS_UNIT_EOF'
[Unit]
Description=Keep ${ci_hostname} pointed at this host's current public IPv4 (T-034 phase 2)
Wants=network-online.target
After=network-online.target
Before=docker.service
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=oneshot
Environment=AWS_REGION=${aws_region}
Environment=CI_HOSTNAME=${ci_hostname}
Environment=ROUTE53_ZONE_ID=${route53_zone_id}
ExecStart=/usr/local/bin/ci-dns-updater.sh
Restart=on-failure
RestartSec=20

[Install]
WantedBy=multi-user.target
DNS_UNIT_EOF

# Review round 1, finding 2: a timer keeps re-running the updater every 5
# minutes for as long as the host stays up, on top of the boot-time oneshot
# above -- belt-and-suspenders against anything that could otherwise leave
# the record stale for a whole uptime (the updater's own idempotency check,
# scripts/ci-dns-updater.sh, makes every run after the first a cheap read
# rather than a write, so this costs nothing at rest).
cat >/etc/systemd/system/ci-dns-updater.timer <<'DNS_TIMER_EOF'
[Unit]
Description=Periodically re-check ${ci_hostname}'s Route 53 record (T-034 phase 2 review round 1, finding 2)

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Unit=ci-dns-updater.service

[Install]
WantedBy=timers.target
DNS_TIMER_EOF

systemctl daemon-reload

# Review round 1, finding 3: a failed run here must not abort the REST of
# this script (Jenkins, Drone, Caddy still need to come up) -- `set -euo
# pipefail` is active for the whole file, so an unguarded `systemctl
# enable --now` would take the exit status of the service's own (already
# internally retried, scripts/ci-dns-updater.sh) failure and kill
# provisioning over it. Logged loudly instead: the timer above, and the
# next boot's oneshot, both get another chance regardless.
if ! systemctl enable --now ci-dns-updater.service; then
  echo "jenkins-provision: ci-dns-updater.service failed on this run (DNS may be stale) -- continuing provisioning; the timer and the next boot will retry" >&2
fi
systemctl enable --now ci-dns-updater.timer

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
    url: "https://${ci_hostname}/jenkins/"
jobs:
  - script: |
      // T-026: SEED ONLY WHEN ABSENT. JCasC re-applies this whole document on
      // every Jenkins start, and re-running the DSL recreates the multibranch
      // job -- which re-creates its branch children with their build numbering
      // reset to #1, against a JENKINS_HOME whose builds/1 is still on disk.
      // Jenkins then refuses to overwrite (JENKINS-23152) and creates a fresh
      // #2, orphaning the #1 that is already running: "No build record could be
      // located". Measured 7/7 against every recorded occurrence -- see T-026.
      //
      // TEST THE FILESYSTEM, NOT THE ITEM MODEL. Attempt 1 asked
      // Jenkins.get().getItemByFullName(...) and was PROVEN INERT by an apply:
      // JCasC runs job-dsl BEFORE Jenkins loads jobs from disk -- the boot log
      // order is "Processing provided DSL script" -> createOrUpdateConfig ->
      // "Loaded all jobs" -- so at DSL time the item model is EMPTY and the
      // lookup returns null for every job regardless of what is on disk. The
      // job directory, on the persistent JENKINS_HOME bind mount, IS there.
      //
      // Path hardcoded because this heredoc is quoted ('CASC_EOF'): it is
      // $JENKINS_HOME_DIR/jobs/<name>/config.xml, and JENKINS_HOME_DIR is
      // /var/lib/jenkins above, bind-mounted and passed as JENKINS_HOME at the
      // identical path inside the container (see the `docker run` below).
      //
      // The try/catch is the safety property: on any failure `seeded` stays
      // false and we fall through to creating the job -- today's behaviour,
      // never worse. A raised exception here would abort the ENTIRE JCasC
      // document and the box would come up with no jobs at all. It LOGS:
      // attempt 1's catch was silent, so the log could not tell "returned
      // null" from "threw and was swallowed", and disambiguating that cost a
      // whole apply cycle.
      def seeded = false
      try {
        seeded = new File('/var/lib/jenkins/jobs/cv-domain-service/config.xml').exists()
        println 'T-026: cv-domain-service config.xml present=' + seeded
      } catch (Throwable t) {
        println 'T-026: cv-domain-service existence check FAILED, seeding anyway: ' + t
        seeded = false
      }
      if (seeded) {
        println 'T-026: cv-domain-service already exists; not reseeding'
        return
      }
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
      // T-026: seed only when absent -- see the full reasoning on the
      // cv-domain-service script above. Same filesystem probe, same fail-open
      // try/catch, same logging.
      def seeded = false
      try {
        seeded = new File('/var/lib/jenkins/jobs/cv-database/config.xml').exists()
        println 'T-026: cv-database config.xml present=' + seeded
      } catch (Throwable t) {
        println 'T-026: cv-database existence check FAILED, seeding anyway: ' + t
        seeded = false
      }
      if (seeded) {
        println 'T-026: cv-database already exists; not reseeding'
        return
      }
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

# Reverse proxy fronts Drone (/) and Jenkins (/jenkins/) on 80/443, and
# terminates TLS (T-033 H1, option b, Let's Encrypt on the host).
#
# T-034 phase 2 replaced nginx with Caddy: automatic Let's Encrypt is
# Caddy's whole reason for being here -- a site block naming a real hostname
# gets a PRODUCTION certificate via HTTP-01 with zero extra config, an
# automatic HTTP->HTTPS redirect (made explicit below anyway, so it's a
# grep-able fact rather than an implicit default to trust), and its own
# retry/fallback-to-staging behaviour on failure. `handle` (not
# `handle_path`) for /jenkins/* is the Caddy equivalent of nginx's bare
# `proxy_pass $jenkins_upstream` above with no trailing path segment: it
# passes the ORIGINAL request path through untouched, prefix intact, which
# `--prefix=/jenkins` (the jenkins docker run below) expects. `handle_path`
# would strip the matched /jenkins prefix before proxying and break that.
#
# Certs and Caddy's own state persist on host bind mounts (/var/lib/caddy-*
# below) precisely so a stop/start cycle or a reboot -- both routine under
# T-019's on-demand start/reap, now that there's no EIP keeping the box up
# -- never has to re-issue a certificate. Let's Encrypt's production CA
# rate-limits duplicate certificates for the same name to 5/week
# (docs/runbooks/drone.md) -- losing the persisted cert repeatedly would
# burn through that fast.
# Review round 1, finding 6: no manual per-request header overrides below --
# Caddy's reverse_proxy already sets X-Forwarded-For, X-Forwarded-Proto and
# X-Forwarded-Host correctly by default, and passes the original Host
# through unchanged on its own, so the nginx-era manual set was redundant
# with Caddy's defaults (and, for the manual X-Real-IP specifically, mildly
# wrong: Caddy's own convention there is X-Forwarded-For, which it already
# sets). Nothing below needs a {remote_host}-style placeholder either --
# there's no directive left that takes one.
mkdir -p /etc/ci-proxy /var/lib/caddy-data /var/lib/caddy-config
cat >/etc/ci-proxy/Caddyfile <<'CADDY_EOF'
${ci_hostname} {
  handle /jenkins/* {
    reverse_proxy jenkins:8080
  }

  handle {
    reverse_proxy drone-server:80
  }
}

http://${ci_hostname} {
  redir https://{host}{uri} permanent
}

# Review round 1, finding 1: anything that reaches this listener with a
# Host that ISN'T ${ci_hostname} -- a request straight to the instance's raw
# public IP (SNI-less or IP-SNI), a stray old bookmark, a scanner -- falls
# through to here rather than to either site block above (Caddy matches the
# more specific host first). A non-2xx here matters beyond hygiene: Drone's
# EXISTING hook (never doorbell-signed, re-registered to
# https://${ci_hostname}/hook by hand post-apply -- see docs/runbooks/
# drone.md) still targets this same listener, and if it were ever
# mis-addressed, GitHub's own delivery-status tracking must see that as a
# clean failure -- 421, not a hang or a 2xx that would stop the doorbell
# from ever redelivering it. `tls internal` (a locally-generated cert, not a
# real Let's Encrypt one) is deliberate: this catch-all must never trigger
# an ACME issuance attempt for whatever hostname a client happens to claim.
:443 {
  tls internal
  respond 421
}

:80 {
  respond 421
}
CADDY_EOF

# Remediates a drone-server still publishing :80 directly; kept last and
# tight (secrets fetched right before use). State is on the bind mount, so
# recreation is safe and this is a no-op once done.
if docker inspect drone-server >/dev/null 2>&1; then
  drone_port80_binding=$(docker inspect -f '{{index .HostConfig.PortBindings "80/tcp"}}' drone-server 2>/dev/null || echo "")
  if [ -n "$drone_port80_binding" ] && [ "$drone_port80_binding" != "<no value>" ] && [ "$drone_port80_binding" != "[]" ] && [ "$drone_port80_binding" != "map[]" ]; then
    DRONE_RPC_SECRET=$(param drone-rpc-secret)
    GITHUB_CLIENT_ID=$(param github-client-id)
    GITHUB_CLIENT_SECRET=$(param github-client-secret)
    # T-007 review round 1, finding 8: this is a second, independent
    # drone-server invocation from templates/drone-user-data.sh's -- it
    # drifted once already (this whole block exists to fix a :80-publish
    # drift), so DRONE_DATABASE_SECRET is fetched and passed here too rather
    # than assuming the two copies stay in sync. scripts/check-t007-static.sh
    # pins this: every `docker run ... drone/drone:...` invocation, in
    # either template, must carry -e DRONE_DATABASE_SECRET.
    DRONE_DATABASE_SECRET=$(param drone/database-secret)
    echo "jenkins-provision: recreating drone-server without the direct :80 publish"
    docker rm -f drone-server
    docker run -d --name drone-server --restart unless-stopped \
      --network drone \
      -v /var/lib/drone:/data \
      -e DRONE_GITHUB_CLIENT_ID="$GITHUB_CLIENT_ID" \
      -e DRONE_GITHUB_CLIENT_SECRET="$GITHUB_CLIENT_SECRET" \
      -e DRONE_RPC_SECRET="$DRONE_RPC_SECRET" \
      -e DRONE_DATABASE_SECRET="$DRONE_DATABASE_SECRET" \
      -e DRONE_SERVER_HOST="${ci_hostname}" \
      -e DRONE_SERVER_PROTO=https \
      -e DRONE_USER_CREATE="username:${admin_username},admin:true" \
      -e DRONE_USER_FILTER="${admin_username}" \
      drone/drone:2
  fi
fi

CI_PROXY_CONFIG_HASH=$(sha256sum /etc/ci-proxy/Caddyfile | awk '{print $1}')
recreate_if_needed ci-proxy caddy:2 "$CI_PROXY_CONFIG_HASH" \
  --restart unless-stopped \
  --network drone \
  -p 80:80 \
  -p 443:443 \
  -p 443:443/udp \
  -v /etc/ci-proxy/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v /var/lib/caddy-data:/data \
  -v /var/lib/caddy-config:/config

# Health check: `docker run -d` only proves creation, not serving. Review
# round 1, finding 5 split this into two genuinely different questions,
# checked and treated differently:
#
#   (a) Is the PROXY ROUTING correct at all -- Caddy is up, its config is
#       valid, and it forwards /jenkins/login to Jenkins? This is a
#       configuration/container problem if it fails, has nothing to do with
#       DNS or ACME, and stays a hard failure: `-k` is used ONLY for this
#       local liveness probe, to keep it independent of whether a
#       certificate has been issued yet. --resolve still pins the hostname
#       to this host's own loopback (this runs ON the CI host, so it can't
#       rely on the DNS updater having already propagated externally by the
#       time this line runs) -- `-k` here is about the CERTIFICATE'S
#       validity, not the hostname routing, which --resolve already gets
#       right.
#   (b) Does ci_hostname now present a REAL, browser/GitHub-trusted
#       certificate? This depends on Let's Encrypt actually having issued
#       one, which can take a while on a first-ever boot and is NOT this
#       script's job to force -- Caddy keeps retrying on its own
#       regardless. A long wait here that only WARNS on timeout (never
#       fails the apply) reflects that: the box is already usable per (a),
#       and a still-pending certificate resolves itself without any
#       operator action.
docker exec ci-proxy caddy validate --config /etc/caddy/Caddyfile

routing_elapsed=0
routing_timeout_s=120
routing_poll_s=5
while :; do
  if curl -sfk -o /dev/null --resolve "${ci_hostname}:443:127.0.0.1" "https://${ci_hostname}/jenkins/login"; then
    echo "jenkins-provision: ci-proxy is routing to Jenkins over HTTPS (certificate not yet verified)."
    break
  fi
  if [ "$routing_elapsed" -ge "$routing_timeout_s" ]; then
    echo "jenkins-provision: https://${ci_hostname}/jenkins/login never came up through ci-proxy within $${routing_timeout_s}s -- this is a proxy/container problem, not a DNS/certificate one" >&2
    exit 1
  fi
  sleep "$routing_poll_s"
  routing_elapsed=$((routing_elapsed + routing_poll_s))
done

cert_elapsed=0
cert_timeout_s=600
cert_poll_s=10
while :; do
  if curl -sf -o /dev/null --resolve "${ci_hostname}:443:127.0.0.1" "https://${ci_hostname}/jenkins/login"; then
    echo "jenkins-provision: ci-proxy is presenting a valid certificate for ${ci_hostname}."
    break
  fi
  if [ "$cert_elapsed" -ge "$cert_timeout_s" ]; then
    echo "jenkins-provision: WARNING -- no valid certificate for ${ci_hostname} within $${cert_timeout_s}s; Caddy will keep retrying issuance on its own -- not failing this run over it" >&2
    break
  fi
  sleep "$cert_poll_s"
  cert_elapsed=$((cert_elapsed + cert_poll_s))
done
