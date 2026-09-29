#!/usr/bin/env bash
# T-034 phase 2: keeps the CI host's Route 53 A record pointed at its own
# current public IPv4. Runs on the CI host itself -- there is no more Elastic
# IP (ci.tf), so the public IP is different on every stop/start cycle
# (T-019's on-demand start/reap), and this is what keeps the DNS name
# resolving to it. Two triggers (both written by templates/jenkins-provision.sh):
# a systemd oneshot unit at boot (Before=docker.service, so it always runs
# before ci-proxy or anything else Docker restarts can attempt to serve a
# request or an ACME challenge against a stale address), and a systemd timer
# that re-runs it every 5 minutes for the rest of the time the host is up
# (review round 1, finding 2) -- belt-and-suspenders against anything that
# could otherwise leave the record stale for a whole uptime.
#
# Reads its configuration from the environment (AWS_REGION, CI_HOSTNAME,
# ROUTE53_ZONE_ID) rather than Terraform template placeholders, so this file
# has ZERO `${...}` sequences in it -- safe to embed verbatim into another
# template (jenkins-provision.sh) with no risk of the two templating passes
# colliding, and directly testable (scripts/tests/run-ci-dns-updater-tests.sh)
# by just setting env vars, no rendering step involved.
set -euo pipefail

: "${AWS_REGION:?AWS_REGION not set}"
: "${CI_HOSTNAME:?CI_HOSTNAME not set}"
: "${ROUTE53_ZONE_ID:?ROUTE53_ZONE_ID not set}"

IMDS_BASE="http://169.254.169.254/latest"

# Review round 1, finding 3: retry with backoff for IMDS and Route 53, up to
# roughly 3 minutes total, instead of failing on the first transient hiccup
# (IMDS momentarily unavailable right after boot, a throttled Route 53 call).
# Attempt-counted, not wall-clock-timed: deterministic and fast to test
# (RETRY_MAX_ATTEMPTS=1 disables retries entirely; a low
# RETRY_BASE_DELAY_SECONDS keeps a multi-attempt test from taking real
# minutes) without behaving differently in production, where the defaults
# below are what actually run. Default 9 attempts at a doubling delay capped
# at 30s (2+4+8+16+30+30+30+30 = 180s) approximates "~3 minutes" without
# pretending to hit it exactly -- the real goal is "several tries over a
# couple of minutes," not a precise deadline.
RETRY_MAX_ATTEMPTS="${RETRY_MAX_ATTEMPTS:-9}"
RETRY_BASE_DELAY_SECONDS="${RETRY_BASE_DELAY_SECONDS:-2}"

retry() {
  local attempt=1
  local delay="$RETRY_BASE_DELAY_SECONDS"
  while :; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$RETRY_MAX_ATTEMPTS" ]; then
      return 1
    fi
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    [ "$delay" -gt 30 ] && delay=30
  done
}

_fetch_token() {
  token=$(curl -sf -X PUT "$IMDS_BASE/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  [ -n "$token" ]
}

_fetch_public_ip() {
  public_ip=$(curl -sf -H "X-aws-ec2-metadata-token: $token" "$IMDS_BASE/meta-data/public-ipv4")
  [ -n "$public_ip" ]
}

_fetch_current_record_value() {
  # Empty output (a brand-new record, or a transient list failure) must not
  # be mistaken for "matches" -- current_value is explicitly cleared first so
  # a failed/empty list always falls through to the UPSERT path rather than
  # silently skipping it.
  current_value=""
  current_value=$(aws route53 list-resource-record-sets --region "$AWS_REGION" \
    --hosted-zone-id "$ROUTE53_ZONE_ID" \
    --query "ResourceRecordSets[?Name=='${CI_HOSTNAME}.' && Type=='A'].ResourceRecords[0].Value | [0]" \
    --output text)
  [ "$current_value" != "None" ] || current_value=""
}

_change_batch() {
  cat <<JSON
{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"$CI_HOSTNAME","Type":"A","TTL":60,"ResourceRecords":[{"Value":"$public_ip"}]}}]}
JSON
}

_upsert_record() {
  change_id=$(aws route53 change-resource-record-sets --region "$AWS_REGION" \
    --hosted-zone-id "$ROUTE53_ZONE_ID" \
    --change-batch "$(_change_batch)" \
    --query "ChangeInfo.Id" --output text)
  [ -n "$change_id" ] && [ "$change_id" != "None" ]
}

_change_is_insync() {
  local status
  status=$(aws route53 get-change --region "$AWS_REGION" --id "$change_id" --query "ChangeInfo.Status" --output text)
  [ "$status" = "INSYNC" ]
}

# IMDSv2 only: a token first, then the metadata call carries it as a header.
# T-007 caps the instance's hop limit at 1, but that restricts CONTAINERS
# reaching IMDS through the host's bridge network -- this script runs
# directly on the host (hop 0), so it is unaffected either way. IMDSv2 is
# used regardless because it's the only IMDS this account's instances speak.
if ! retry _fetch_token; then
  echo "ci-dns-updater: could not obtain an IMDSv2 token after $RETRY_MAX_ATTEMPTS attempts" >&2
  exit 1
fi

if ! retry _fetch_public_ip; then
  echo "ci-dns-updater: empty public-ipv4 from IMDS after $RETRY_MAX_ATTEMPTS attempts -- refusing to UPSERT a record with no address" >&2
  exit 1
fi

# Idempotency (review round 1, finding 2): a periodic timer re-runs this
# every 5 minutes for as long as the host is up, so on every run except the
# one right after a genuine address change, the record already says the
# right thing. Skipping the UPSERT (and the INSYNC wait below) on a match
# turns every one of those runs into a single cheap read instead of a write
# plus a propagation wait, several times an hour, for nothing.
if retry _fetch_current_record_value && [ "$current_value" = "$public_ip" ]; then
  echo "ci-dns-updater: $CI_HOSTNAME already -> $public_ip; nothing to do"
  exit 0
fi

echo "ci-dns-updater: UPSERT $CI_HOSTNAME -> $public_ip in $ROUTE53_ZONE_ID"
if ! retry _upsert_record; then
  echo "ci-dns-updater: change-resource-record-sets failed after $RETRY_MAX_ATTEMPTS attempts" >&2
  exit 1
fi

# Review round 1, finding 5: wait (bounded, separately from the main retry
# budget above -- this is a courtesy, not a correctness gate; the UPSERT
# already succeeded) for the change to reach INSYNC, so a caller that reads
# this script's own success as "DNS is now live" is telling the truth rather
# than guessing. A non-INSYNC timeout is NOT a failure of this script: the
# change WILL converge, Route 53 just hasn't confirmed it back yet, and
# Caddy's own certificate wait (templates/jenkins-provision.sh) already
# tolerates that on its own longer, separate timeline.
insync_attempts=0
insync_max_attempts="${INSYNC_MAX_ATTEMPTS:-12}"
insync_poll_seconds="${INSYNC_POLL_SECONDS:-5}"
while [ "$insync_attempts" -lt "$insync_max_attempts" ]; do
  if _change_is_insync; then
    echo "ci-dns-updater: change $change_id is INSYNC"
    break
  fi
  insync_attempts=$((insync_attempts + 1))
  sleep "$insync_poll_seconds"
done
if [ "$insync_attempts" -ge "$insync_max_attempts" ]; then
  echo "ci-dns-updater: change $change_id not yet INSYNC after $((insync_max_attempts * insync_poll_seconds))s -- it will converge, continuing anyway" >&2
fi

echo "ci-dns-updater: done"
