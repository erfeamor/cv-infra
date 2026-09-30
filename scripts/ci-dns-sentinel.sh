#!/usr/bin/env bash
# T-034 phase 2 review round 2, finding 2(a): UPSERTs the CI host's DNS
# record to a sentinel address on ExecStop of ci-dns-sentinel.service
# (templates/jenkins-provision.sh) -- covers an UNGRACEFUL stop (a manual
# `ec2 stop-instances`, a crash) that never reaches the reaper Lambda's own
# sentinel UPSERT (lambda/ci_reaper/index.py). Neither alone covers both
# cases; both exist.
#
# Best-effort and FAST by design: this runs as systemd tears the host down,
# so a slow or failing call here must never hold up the rest of shutdown.
# No retry loop (unlike scripts/ci-dns-updater.sh) -- one attempt, a bounded
# `timeout`, and unconditional success either way.
#
# T-041: timeout raised 10 -> 20 now that ci-dns-sentinel.service orders
# itself after network-online.target (templates/jenkins-provision.sh) --
# networking no longer disappears mid-call, so a slow-but-real Route 53
# response has room to complete instead of being cut off by an
# artificially short budget. On failure, the AWS CLI's own stderr is now
# captured and printed (still to stderr, still after the fact) so the
# journal shows WHY the UPSERT failed, not just that it did.
#
# Reads its configuration from the environment (AWS_REGION, CI_HOSTNAME,
# ROUTE53_ZONE_ID, SENTINEL_IP), same convention as scripts/ci-dns-updater.sh,
# for the same reason: zero Terraform ${...} placeholders, so this file can
# be embedded byte-for-byte via file() with no templating collision risk.
set -uo pipefail # deliberately NOT -e -- see the header above

: "${AWS_REGION:?AWS_REGION not set}"
: "${CI_HOSTNAME:?CI_HOSTNAME not set}"
: "${ROUTE53_ZONE_ID:?ROUTE53_ZONE_ID not set}"
SENTINEL_IP="${SENTINEL_IP:-192.0.2.1}"

change_batch=$(cat <<JSON
{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"$CI_HOSTNAME","Type":"A","TTL":60,"ResourceRecords":[{"Value":"$SENTINEL_IP"}]}}]}
JSON
)

aws_err=""
if aws_err=$(timeout 20 aws route53 change-resource-record-sets --region "$AWS_REGION" \
  --hosted-zone-id "$ROUTE53_ZONE_ID" --change-batch "$change_batch" 2>&1 >/dev/null); then
  echo "ci-dns-sentinel: UPSERTed $CI_HOSTNAME -> $SENTINEL_IP"
else
  echo "ci-dns-sentinel: UPSERT to the sentinel failed or timed out (best-effort, continuing shutdown): $aws_err" >&2
fi

exit 0
