#!/usr/bin/env bash
# Offline test harness for scripts/ci-dns-sentinel.sh (T-034 phase 2 review
# round 2, finding 2(a)). Reuses stub-bin-dns/aws (already understands
# change-resource-record-sets) -- this script never calls curl, so the
# curl stub is irrelevant here but harmless to have on PATH.
#
# Usage: bash scripts/tests/run-ci-dns-sentinel-tests.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
sentinel_script="$repo_root/scripts/ci-dns-sentinel.sh"

pass=0
fail=0
ok() {
  echo "  ok: $*"
  pass=$((pass + 1))
}
bad() {
  echo "  FAIL: $*" >&2
  fail=$((fail + 1))
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

run_sentinel() {
  env -i \
    PATH="$here/stub-bin-dns:/usr/bin:/bin" \
    AWS_REGION="${AWS_REGION:-}" \
    CI_HOSTNAME="${CI_HOSTNAME:-}" \
    ROUTE53_ZONE_ID="${ROUTE53_ZONE_ID:-}" \
    SENTINEL_IP="${SENTINEL_IP:-}" \
    STUB_AWS_CALLS_LOG="${STUB_AWS_CALLS_LOG:-}" \
    STUB_AWS_CHANGE_FAIL="${STUB_AWS_CHANGE_FAIL:-}" \
    bash "$sentinel_script"
}

reset_fixtures() {
  unset SENTINEL_IP STUB_AWS_CHANGE_FAIL
  AWS_REGION="eu-west-3"
  CI_HOSTNAME="ci.erfeamor.com"
  ROUTE53_ZONE_ID="Z0608270B7WND031GVOW"
  STUB_AWS_CALLS_LOG="$workdir/aws-calls.log"
  : >"$STUB_AWS_CALLS_LOG"
}

echo "case 1: happy path -- UPSERTs the default sentinel (192.0.2.1)"
reset_fixtures
if run_sentinel >"$workdir/out.log" 2>"$workdir/err.log"; then
  ok "exits 0"
else
  bad "exited non-zero on the happy path: $(cat "$workdir/err.log")"
fi
if grep -q '"Value":"192.0.2.1"' "$STUB_AWS_CALLS_LOG" && grep -q '"Name":"ci.erfeamor.com"' "$STUB_AWS_CALLS_LOG" \
  && grep -q '"Action":"UPSERT"' "$STUB_AWS_CALLS_LOG"; then
  ok "UPSERTed the sentinel, the right name, UPSERT"
else
  bad "change-batch missing an expected field: $(cat "$STUB_AWS_CALLS_LOG")"
fi

echo "case 2: a custom SENTINEL_IP is honoured"
reset_fixtures
SENTINEL_IP="192.0.2.99"
run_sentinel >/dev/null 2>&1
grep -q '"Value":"192.0.2.99"' "$STUB_AWS_CALLS_LOG" && ok "used the custom sentinel" || bad "did not use SENTINEL_IP: $(cat "$STUB_AWS_CALLS_LOG")"

echo "case 3 (RED): a failed Route 53 call still exits 0 (best-effort, never blocks shutdown)"
reset_fixtures
STUB_AWS_CHANGE_FAIL=1
if run_sentinel >"$workdir/out.log" 2>"$workdir/err.log"; then
  ok "still exits 0 despite the Route 53 call failing"
else
  bad "exited non-zero -- this must never block shutdown"
fi
grep -qi "failed\|timed out" "$workdir/err.log" && ok "logged the failure" || bad "no log line about the failure: $(cat "$workdir/err.log")"

echo "case 4: missing required env vars fail loudly (still caught before any AWS call)"
reset_fixtures
CI_HOSTNAME=""
if run_sentinel >"$workdir/out.log" 2>"$workdir/err.log"; then
  bad "exited 0 with CI_HOSTNAME unset"
else
  ok "exited non-zero with CI_HOSTNAME unset"
fi

echo
echo "ci-dns-sentinel tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
