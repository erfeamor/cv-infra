#!/usr/bin/env bash
# Offline test harness for scripts/drone-reseed-secrets.sh (T-008 cases
# 6-8). Runs entirely without AWS or network access:
#   - `aws` is stubbed (scripts/tests/stub-bin/aws), driven by env-var
#     fixtures, so no real SSM call ever happens.
#   - the Drone API is stubbed by a tiny python3 http.server
#     (scripts/tests/stub_drone_server.py) on 127.0.0.1, tracking secrets
#     in memory so idempotency (case 7) is actually observable.
#
# Usage: bash scripts/tests/run-drone-reseed-tests.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
reseed_script="$repo_root/scripts/drone-reseed-secrets.sh"

workdir="$(mktemp -d)"
# Review round 1, finding 8: initialised BEFORE the trap is installed, not
# after the server is started -- if anything between here and the
# `server_pid=$!` assignment below fails (e.g. the `python3 -c` port probe),
# the EXIT trap still fires and references $server_pid; under `set -u` an
# unset reference there would abort the trap itself with "unbound variable",
# masking the real failure behind a confusing second one.
server_pid=""
trap '[ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; rm -rf "$workdir"' EXIT

export STUB_DRONE_REQUESTS_LOG="$workdir/requests.log"
export STUB_DRONE_SECRETS_LOG="$workdir/secrets.json"
export STUB_DRONE_VIOLATIONS_LOG="$workdir/violations.log"
: >"$STUB_DRONE_REQUESTS_LOG"
: >"$STUB_DRONE_VIOLATIONS_LOG"

# Ask the OS for a free port instead of hardcoding one, so this harness
# doesn't collide with anything already listening.
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

python3 "$here/stub_drone_server.py" "$port" &
server_pid=$!

for _ in $(seq 1 50); do
  if curl -s -o /dev/null "http://127.0.0.1:${port}/"; then
    break
  fi
  sleep 0.1
done

export PATH="$here/stub-bin:$PATH"
export DRONE_SERVER="http://127.0.0.1:${port}"
export DRONE_TOKEN="fixture-drone-token-not-real-9f2c"
export DRONE_REPO="erfeamor/cv-admin-react"

FIXTURE_ACCESS_KEY_ID="AKIAFIXTURETESTVALUE"
FIXTURE_SECRET_ACCESS_KEY="fixture/secret+access+key/value=="
FIXTURE_DRONE_TOKEN="$DRONE_TOKEN"

pass=0
fail=0

check() {
  if [ "$1" = "0" ]; then
    echo "  ok: $2"
    pass=$((pass + 1))
  else
    echo "  FAIL: $2"
    fail=$((fail + 1))
  fi
}

# --- Case 6: a missing SSM value exits non-zero, calls the Drone API      -
#     zero times, and writes nothing.                                     -
echo "case 6: missing SSM value fails closed"
: >"$STUB_DRONE_REQUESTS_LOG"
rm -f "$STUB_DRONE_SECRETS_LOG"
set +e
STUB_AWS_ACCESS_KEY_ID_VALUE="$FIXTURE_ACCESS_KEY_ID" \
  STUB_AWS_SECRET_ACCESS_KEY_VALUE="$FIXTURE_SECRET_ACCESS_KEY" \
  STUB_AWS_MISSING_PARAM_SUFFIX="secret-access-key" \
  STUB_AWS_CALLS_LOG="$workdir/aws-calls.log" \
  bash "$reseed_script" >"$workdir/case6.out" 2>"$workdir/case6.err"
case6_status=$?
set -e

check "$([ "$case6_status" -ne 0 ] && echo 0 || echo 1)" "exits non-zero (got status $case6_status)"
check "$([ ! -s "$STUB_DRONE_REQUESTS_LOG" ] && echo 0 || echo 1)" "makes no Drone API call"
check "$([ ! -f "$STUB_DRONE_SECRETS_LOG" ] && echo 0 || echo 1)" "writes no secret to Drone"

# --- Case 7: idempotent -- two runs converge on the same end state,       -
#     create-then-update across runs, not double-create.                  -
echo "case 7: idempotent across two runs"
: >"$STUB_DRONE_REQUESTS_LOG"
rm -f "$STUB_DRONE_SECRETS_LOG"
: >"$STUB_DRONE_VIOLATIONS_LOG"

# Review round 1, finding 8: `set +e`/`set -e` around each invocation, same
# as case 6 -- without it, a non-zero exit from the reseed script would
# trip this harness's OWN `set -e` and abort the whole suite right here,
# instead of being captured and reported as a normal failed check below.
set +e
STUB_AWS_ACCESS_KEY_ID_VALUE="$FIXTURE_ACCESS_KEY_ID" \
  STUB_AWS_SECRET_ACCESS_KEY_VALUE="$FIXTURE_SECRET_ACCESS_KEY" \
  bash "$reseed_script" >"$workdir/case7-run1.out" 2>"$workdir/case7-run1.err"
run1_status=$?
set -e

run1_posts=$(grep -c '^POST ' "$STUB_DRONE_REQUESTS_LOG" || true)
run1_patches=$(grep -c '^PATCH ' "$STUB_DRONE_REQUESTS_LOG" || true)

: >"$STUB_DRONE_REQUESTS_LOG"
set +e
STUB_AWS_ACCESS_KEY_ID_VALUE="$FIXTURE_ACCESS_KEY_ID" \
  STUB_AWS_SECRET_ACCESS_KEY_VALUE="$FIXTURE_SECRET_ACCESS_KEY" \
  bash "$reseed_script" >"$workdir/case7-run2.out" 2>"$workdir/case7-run2.err"
run2_status=$?
set -e

run2_posts=$(grep -c '^POST ' "$STUB_DRONE_REQUESTS_LOG" || true)
run2_patches=$(grep -c '^PATCH ' "$STUB_DRONE_REQUESTS_LOG" || true)

check "$([ "$run1_status" -eq 0 ] && [ "$run2_status" -eq 0 ] && echo 0 || echo 1)" "both runs exit 0"
check "$([ "$run1_posts" -eq 2 ] && echo 0 || echo 1)" "run 1 (nothing exists yet) creates both secrets via POST (got $run1_posts)"
check "$([ "$run2_posts" -eq 0 ] && echo 0 || echo 1)" "run 2 (already exist) creates nothing via POST (got $run2_posts)"
check "$([ "$run2_patches" -eq 2 ] && echo 0 || echo 1)" "run 2 updates both secrets via PATCH (got $run2_patches)"
check "$(grep -q "$FIXTURE_ACCESS_KEY_ID" "$STUB_DRONE_SECRETS_LOG" && grep -q "$FIXTURE_SECRET_ACCESS_KEY" "$STUB_DRONE_SECRETS_LOG" && echo 0 || echo 1)" "end state holds the latest fixture values"
check "$([ ! -s "$STUB_DRONE_VIOLATIONS_LOG" ] && echo 0 || echo 1)" "every request sets pull_request=false, pull_request_push=false, and a Bearer Authorization header (0 stub violations, got $(wc -l <"$STUB_DRONE_VIOLATIONS_LOG"))"

# --- Case 8: no secret in stdout/stderr, even under `bash -x`.            -
echo "case 8: no secret leaks to stdout/stderr, including under -x"
: >"$STUB_DRONE_REQUESTS_LOG"
rm -f "$STUB_DRONE_SECRETS_LOG"
: >"$STUB_DRONE_VIOLATIONS_LOG"

set +e
STUB_AWS_ACCESS_KEY_ID_VALUE="$FIXTURE_ACCESS_KEY_ID" \
  STUB_AWS_SECRET_ACCESS_KEY_VALUE="$FIXTURE_SECRET_ACCESS_KEY" \
  bash "$reseed_script" >"$workdir/case8-quiet.out" 2>"$workdir/case8-quiet.err"
case8_quiet_status=$?
set -e

set +e
STUB_AWS_ACCESS_KEY_ID_VALUE="$FIXTURE_ACCESS_KEY_ID" \
  STUB_AWS_SECRET_ACCESS_KEY_VALUE="$FIXTURE_SECRET_ACCESS_KEY" \
  bash -x "$reseed_script" >"$workdir/case8-verbose.out" 2>"$workdir/case8-verbose.err"
case8_verbose_status=$?
set -e

check "$([ "$case8_quiet_status" -eq 0 ] && [ "$case8_verbose_status" -eq 0 ] && echo 0 || echo 1)" "both quiet and -x verbose runs exit 0"

leak_found=1
if ! grep -qF "$FIXTURE_ACCESS_KEY_ID" "$workdir"/case8-quiet.out "$workdir"/case8-quiet.err \
  "$workdir"/case8-verbose.out "$workdir"/case8-verbose.err 2>/dev/null \
  && ! grep -qF "$FIXTURE_SECRET_ACCESS_KEY" "$workdir"/case8-quiet.out "$workdir"/case8-quiet.err \
    "$workdir"/case8-verbose.out "$workdir"/case8-verbose.err 2>/dev/null \
  && ! grep -qF "$FIXTURE_DRONE_TOKEN" "$workdir"/case8-quiet.out "$workdir"/case8-quiet.err \
    "$workdir"/case8-verbose.out "$workdir"/case8-verbose.err 2>/dev/null; then
  leak_found=0
fi
check "$leak_found" "neither fixture secret value NOR the DRONE_TOKEN fixture appears in stdout/stderr, quiet or -x verbose"
# Anchored to the start of the (whitespace-trimmed) line so this matches an
# actual `set -x` command, not the header comment's prose discussing why
# toggling set -x is the wrong fix (that prose necessarily contains the
# literal substring, always inside a `#`-led comment line).
check "$(grep -qE '^[[:space:]]*set[[:space:]]+-x' "$reseed_script" && echo 1 || echo 0)" "the script itself never sets -x"

echo
echo "drone-reseed-secrets tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
