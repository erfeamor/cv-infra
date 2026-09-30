#!/usr/bin/env bash
# Offline test harness for scripts/ci-dns-updater.sh (T-034 phase 2, plan
# case 9, extended for review round 1). Runs entirely without AWS or network
# access: `curl` and `aws` are stubbed (scripts/tests/stub-bin-dns/), driven
# by env-var fixtures, exactly like scripts/tests/run-drone-reseed-tests.sh
# does for T-008 -- a separate stub-bin directory so this harness can never
# affect that one's fixtures.
#
# Usage: bash scripts/tests/run-ci-dns-updater-tests.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
updater="$repo_root/scripts/ci-dns-updater.sh"

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

run_updater() {
  # Isolated env per call: only PATH (for the stubs) and whatever the caller
  # exported survive: :- guards below stop unbound-variable errors under set -u
  # from the harness's OWN unrelated exported vars leaking in as empty strings.
  env -i \
    PATH="$here/stub-bin-dns:/usr/bin:/bin" \
    AWS_REGION="${AWS_REGION:-}" \
    CI_HOSTNAME="${CI_HOSTNAME:-}" \
    ROUTE53_ZONE_ID="${ROUTE53_ZONE_ID:-}" \
    RETRY_MAX_ATTEMPTS="${RETRY_MAX_ATTEMPTS:-}" \
    RETRY_BASE_DELAY_SECONDS="${RETRY_BASE_DELAY_SECONDS:-}" \
    INSYNC_MAX_ATTEMPTS="${INSYNC_MAX_ATTEMPTS:-}" \
    INSYNC_POLL_SECONDS="${INSYNC_POLL_SECONDS:-}" \
    STUB_CURL_CALLS_LOG="${STUB_CURL_CALLS_LOG:-}" \
    STUB_CURL_TOKEN_VALUE="${STUB_CURL_TOKEN_VALUE:-}" \
    STUB_CURL_EMPTY_TOKEN="${STUB_CURL_EMPTY_TOKEN:-}" \
    STUB_CURL_TOKEN_FAIL_TIMES_FILE="${STUB_CURL_TOKEN_FAIL_TIMES_FILE:-}" \
    STUB_CURL_PUBLIC_IP="${STUB_CURL_PUBLIC_IP:-}" \
    STUB_CURL_EMPTY_PUBLIC_IP="${STUB_CURL_EMPTY_PUBLIC_IP:-}" \
    STUB_AWS_CALLS_LOG="${STUB_AWS_CALLS_LOG:-}" \
    STUB_AWS_LIST_FAIL="${STUB_AWS_LIST_FAIL:-}" \
    STUB_AWS_CHANGE_FAIL="${STUB_AWS_CHANGE_FAIL:-}" \
    STUB_AWS_GET_CHANGE_FAIL="${STUB_AWS_GET_CHANGE_FAIL:-}" \
    STUB_AWS_CURRENT_VALUE="${STUB_AWS_CURRENT_VALUE:-}" \
    STUB_AWS_CHANGE_ID="${STUB_AWS_CHANGE_ID:-}" \
    STUB_AWS_CHANGE_STATUS="${STUB_AWS_CHANGE_STATUS:-}" \
    bash "$updater"
}

reset_fixtures() {
  unset STUB_CURL_TOKEN_VALUE STUB_CURL_EMPTY_TOKEN STUB_CURL_PUBLIC_IP STUB_CURL_EMPTY_PUBLIC_IP STUB_CURL_TOKEN_FAIL_TIMES_FILE
  unset STUB_AWS_LIST_FAIL STUB_AWS_CHANGE_FAIL STUB_AWS_GET_CHANGE_FAIL STUB_AWS_CHANGE_ID STUB_AWS_CHANGE_STATUS
  AWS_REGION="eu-west-3"
  CI_HOSTNAME="ci.erfeamor.com"
  ROUTE53_ZONE_ID="Z0608270B7WND031GVOW"
  # No retries by default -- fast, deterministic tests. Case 8 below
  # overrides this specifically to prove retries actually happen.
  RETRY_MAX_ATTEMPTS=1
  RETRY_BASE_DELAY_SECONDS=0
  # Same reasoning for the INSYNC poll: 1 attempt, 0 delay, keeps every test
  # fast regardless of whether it's exercising the INSYNC-reached path or
  # the give-up-after-timeout path.
  INSYNC_MAX_ATTEMPTS=1
  INSYNC_POLL_SECONDS=0
  STUB_CURL_CALLS_LOG="$workdir/curl-calls.log"
  STUB_AWS_CALLS_LOG="$workdir/aws-calls.log"
  # Deliberately NOT equal to any test's public IP fixture, so the
  # idempotency skip (case 3b) never fires by accident in a test that isn't
  # testing it.
  STUB_AWS_CURRENT_VALUE="198.51.100.1"
  : >"$STUB_CURL_CALLS_LOG"
  : >"$STUB_AWS_CALLS_LOG"
}

echo "case 1: happy path -- UPSERTs with the current public IP, waits for INSYNC"
reset_fixtures
STUB_CURL_TOKEN_VALUE="tok-abc123" STUB_CURL_PUBLIC_IP="203.0.113.10"
if run_updater >"$workdir/out.log" 2>"$workdir/err.log"; then
  ok "exits 0"
else
  bad "exited non-zero on the happy path: $(cat "$workdir/err.log")"
fi
if grep -q 'change-resource-record-sets eu-west-3 Z0608270B7WND031GVOW' "$STUB_AWS_CALLS_LOG"; then
  ok "called change-resource-record-sets with the right region/zone"
else
  bad "did not call change-resource-record-sets as expected"
fi
if grep -q '"Value":"203.0.113.10"' "$STUB_AWS_CALLS_LOG" && grep -q '"Name":"ci.erfeamor.com"' "$STUB_AWS_CALLS_LOG" \
  && grep -q '"Type":"A"' "$STUB_AWS_CALLS_LOG" && grep -q '"TTL":60' "$STUB_AWS_CALLS_LOG" && grep -q '"Action":"UPSERT"' "$STUB_AWS_CALLS_LOG"; then
  ok "change-batch carries the current IP, the right name, A, TTL 60, UPSERT"
else
  bad "change-batch is missing an expected field: $(cat "$STUB_AWS_CALLS_LOG")"
fi
if grep -q '^get-change' "$STUB_AWS_CALLS_LOG"; then
  ok "waited for the change to reach INSYNC (get-change called)"
else
  bad "never called get-change to confirm INSYNC"
fi

echo "case 2: IMDSv2 -- the metadata call carries the exact token from the token call"
reset_fixtures
STUB_CURL_TOKEN_VALUE="tok-xyz789" STUB_CURL_PUBLIC_IP="203.0.113.11"
run_updater >/dev/null 2>&1
if grep -q '^token$' "$STUB_CURL_CALLS_LOG" && grep -q '^metadata:tok-xyz789$' "$STUB_CURL_CALLS_LOG"; then
  ok "the token call happened, and the metadata call carried that exact token as a header"
else
  bad "IMDSv2 flow not observed as expected: $(cat "$STUB_CURL_CALLS_LOG")"
fi

echo "case 3a (RED): idempotent -- record already matches, no write at all"
reset_fixtures
STUB_CURL_TOKEN_VALUE="tok" STUB_CURL_PUBLIC_IP="203.0.113.12" STUB_AWS_CURRENT_VALUE="203.0.113.12"
if run_updater >"$workdir/out.log" 2>"$workdir/err.log"; then
  ok "exits 0 when the record already matches"
else
  bad "exited non-zero when the record already matched: $(cat "$workdir/err.log")"
fi
if grep -q 'change-resource-record-sets\|get-change' "$STUB_AWS_CALLS_LOG"; then
  bad "wrote or waited on a change despite the record already matching: $(cat "$STUB_AWS_CALLS_LOG")"
else
  ok "made no write (and no INSYNC wait) when the record already matched -- a read-only no-op"
fi

echo "case 3b: a genuine address change still UPSERTs"
reset_fixtures
STUB_CURL_TOKEN_VALUE="tok" STUB_CURL_PUBLIC_IP="203.0.113.12" STUB_AWS_CURRENT_VALUE="203.0.113.99"
run_updater >/dev/null 2>&1
if [ "$(grep -c '^change-resource-record-sets' "$STUB_AWS_CALLS_LOG")" = "1" ]; then
  ok "UPSERTed exactly once when the current record differs from the live IP"
else
  bad "expected exactly 1 change-resource-record-sets call, got: $(cat "$STUB_AWS_CALLS_LOG")"
fi

echo "case 4 (RED): fails loudly -- empty IMDS token"
reset_fixtures
STUB_CURL_EMPTY_TOKEN=1
if run_updater >"$workdir/out.log" 2>"$workdir/err.log"; then
  bad "exited 0 despite an empty IMDSv2 token"
else
  ok "exited non-zero on an empty IMDSv2 token"
fi
grep -qi "token" "$workdir/err.log" && ok "logged a message naming the token failure" || bad "no log line about the token failure: $(cat "$workdir/err.log")"

echo "case 5 (RED): fails loudly -- empty public IP"
reset_fixtures
STUB_CURL_TOKEN_VALUE="tok" STUB_CURL_EMPTY_PUBLIC_IP=1
if run_updater >"$workdir/out.log" 2>"$workdir/err.log"; then
  bad "exited 0 despite an empty public-ipv4"
else
  ok "exited non-zero on an empty public-ipv4"
fi
grep -qi "public-ipv4\|empty" "$workdir/err.log" && ok "logged a message naming the empty-IP failure" || bad "no log line about the empty IP: $(cat "$workdir/err.log")"
if [ -s "$STUB_AWS_CALLS_LOG" ]; then
  bad "called Route 53 despite having no IP to UPSERT"
else
  ok "never called Route 53 when there was no IP"
fi

echo "case 6 (RED): fails loudly -- the Route 53 UPSERT itself errors"
reset_fixtures
STUB_CURL_TOKEN_VALUE="tok" STUB_CURL_PUBLIC_IP="203.0.113.13" STUB_AWS_CHANGE_FAIL=1
if run_updater >"$workdir/out.log" 2>"$workdir/err.log"; then
  bad "exited 0 despite the Route 53 UPSERT call failing"
else
  ok "exited non-zero when the Route 53 UPSERT call fails"
fi

echo "case 7: missing required env vars also fail loudly"
reset_fixtures
CI_HOSTNAME=""
if run_updater >"$workdir/out.log" 2>"$workdir/err.log"; then
  bad "exited 0 with CI_HOSTNAME unset"
else
  ok "exited non-zero with CI_HOSTNAME unset"
fi

echo "case 8 (RED): retries IMDS with backoff and eventually succeeds"
reset_fixtures
STUB_CURL_TOKEN_FAIL_TIMES_FILE="$workdir/token-fail-count"
echo 2 >"$STUB_CURL_TOKEN_FAIL_TIMES_FILE" # fails twice, succeeds on the 3rd attempt
STUB_CURL_TOKEN_VALUE="tok-retried" STUB_CURL_PUBLIC_IP="203.0.113.14"
RETRY_MAX_ATTEMPTS=5 RETRY_BASE_DELAY_SECONDS=0
if run_updater >"$workdir/out.log" 2>"$workdir/err.log"; then
  ok "eventually succeeds after transient IMDS failures"
else
  bad "gave up despite RETRY_MAX_ATTEMPTS covering the transient failures: $(cat "$workdir/err.log")"
fi
if [ "$(grep -c '^token$' "$STUB_CURL_CALLS_LOG")" -ge 3 ]; then
  ok "made at least 3 attempts at the token call (2 failures + 1 success)"
else
  bad "expected at least 3 token-call attempts, got: $(cat "$STUB_CURL_CALLS_LOG")"
fi

echo "case 9 (RED): gives up after RETRY_MAX_ATTEMPTS and fails loudly"
reset_fixtures
STUB_CURL_TOKEN_FAIL_TIMES_FILE="$workdir/token-fail-count-2"
echo 99 >"$STUB_CURL_TOKEN_FAIL_TIMES_FILE" # always fails within the attempt budget
RETRY_MAX_ATTEMPTS=3 RETRY_BASE_DELAY_SECONDS=0
if run_updater >"$workdir/out.log" 2>"$workdir/err.log"; then
  bad "exited 0 despite IMDS failing on every attempt"
else
  ok "exited non-zero after exhausting RETRY_MAX_ATTEMPTS"
fi
if [ "$(grep -c '^token$' "$STUB_CURL_CALLS_LOG")" = "3" ]; then
  ok "made exactly RETRY_MAX_ATTEMPTS (3) attempts, not more, not fewer"
else
  bad "expected exactly 3 token-call attempts, got: $(cat "$STUB_CURL_CALLS_LOG")"
fi

echo "case 10: a get-change that never reaches INSYNC still succeeds overall"
reset_fixtures
STUB_CURL_TOKEN_VALUE="tok" STUB_CURL_PUBLIC_IP="203.0.113.15" STUB_AWS_CHANGE_STATUS="PENDING"
if run_updater >"$workdir/out.log" 2>"$workdir/err.log"; then
  ok "still exits 0 -- the UPSERT itself succeeded; INSYNC is a courtesy wait, not a correctness gate"
else
  bad "exited non-zero just because the change hadn't reached INSYNC yet: $(cat "$workdir/err.log")"
fi
grep -qi "insync" "$workdir/err.log" && ok "logged that it gave up waiting for INSYNC" || bad "no log line about the INSYNC timeout: $(cat "$workdir/err.log")"

echo
echo "ci-dns-updater tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
