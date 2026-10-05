#!/usr/bin/env bash
# Offline harness for /usr/local/bin/cv-redeploy (T-044). The script and its
# shared library (/usr/local/lib/cv-app.sh) exist only as heredocs inside
# templates/domain-service-provision.sh, so this extracts both, fills in the
# Terraform ${...} placeholders with fixtures, points the library path at a
# temp dir, and runs cv-redeploy with `docker`, `aws` and `git` stubbed
# (scripts/tests/stub-bin-app/). No AWS, no network, no terraform needed.
#
# Usage: bash scripts/tests/run-cv-redeploy-tests.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
tpl="$repo_root/templates/domain-service-provision.sh"

pass=0
fail=0
ok() { echo "  ok: $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $*" >&2; fail=$((fail + 1)); }

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
mkdir -p "$workdir/lib" "$workdir/state"

extract() { # extract <heredoc-terminator>
  awk -v t="$1" '
    $0 ~ "<<.?" t ".?$" { c = 1; next }
    c && $0 == t { c = 0 }
    c { print }
  ' "$tpl"
}

render() {
  sed -e 's#\${aws_region}#eu-west-3#g' \
    -e 's#\${project_name}#cv-project#g' \
    -e 's#\${environment}#dev#g' \
    -e 's#\${image}#123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest#g' \
    -e 's#\${bff_image}#123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest#g' \
    -e 's#\${db_name}#cvdb#g' \
    -e 's#\${db_username}#cvuser#g' \
    -e 's#\${cloudfront_domain}#d111.cloudfront.net#g' \
    -e 's#\$\${#${#g' \
    -e "s#/usr/local/lib/cv-app.sh#$workdir/lib/cv-app.sh#g"
}

extract CV_APP_LIB | render >"$workdir/lib/cv-app.sh"
extract CV_REDEPLOY | render >"$workdir/cv-redeploy"
chmod +x "$workdir/cv-redeploy"

[ -s "$workdir/lib/cv-app.sh" ] && [ -s "$workdir/cv-redeploy" ] || { echo "could not extract the library/cv-redeploy from the template" >&2; exit 1; }

calls="$workdir/calls.log"
out="$workdir/out.log"

run_redeploy() { # run_redeploy <args...>; sets $rc
  : >"$calls"; rm -f "$workdir/state/digest"
  set +e
  env -i PATH="$here/stub-bin-app:/usr/bin:/bin" STUB_CALLS_LOG="$calls" STUB_STATE_DIR="$workdir/state" \
    bash "$workdir/cv-redeploy" "$@" >"$out" 2>&1
  rc=$?
  set -e
}

no_secrets() {
  if grep -qE 'SECRET-(DB-PASSWORD-1|BFF-CLIENT-2|ECR-TOKEN-3)' "$out"; then
    bad "$1: a secret value appeared in cv-redeploy's output"
  else
    ok "$1: no secret value in the output"
  fi
}

echo "case 1: domain-service recreates only domain-service"
run_redeploy domain-service
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc"
grep -q '^docker rm -f domain-service$' "$calls" && ok "removed domain-service" || bad "did not rm -f domain-service"
[ "$(grep -c '^docker rm ' "$calls")" -eq 1 ] && ok "removed exactly one container" || bad "removed more than one container"
grep -q '^docker run -d --name domain-service ' "$calls" && ok "recreated domain-service" || bad "did not run domain-service"
! grep -qE '^docker run .*--name (bff-node|mysql)|flyway' "$calls" && ok "bff-node, mysql and flyway untouched" || bad "touched another container"
grep -q '^docker pull .*cv-project-domain-service:latest$' "$calls" && ok "pulled :latest" || bad "no pull of :latest"
grep -q 'old=sha256:old new=sha256:new' "$out" && ok "printed old and new digests" || bad "digests not printed"
no_secrets "case 1"

echo "case 2: bff-node recreates only bff-node"
run_redeploy bff-node
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc"
grep -q '^docker rm -f bff-node$' "$calls" && [ "$(grep -c '^docker rm ' "$calls")" -eq 1 ] && ok "removed exactly bff-node" || bad "wrong rm"
grep -q '^docker run -d --name bff-node ' "$calls" && ok "recreated bff-node" || bad "did not run bff-node"
! grep -qE '^docker run .*--name (domain-service|mysql)|flyway' "$calls" && ok "other containers untouched" || bad "touched another container"
no_secrets "case 2"

echo "case 3: migrate refreshes the clone and runs flyway, nothing else"
run_redeploy migrate
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc"
grep -qE '^git (clone|-C /opt/cv-database pull --ff-only)' "$calls" && ok "synced the cv-database clone" || bad "no clone sync"
grep -q '^docker run --rm --network cv .*flyway/flyway:13.7.0 migrate$' "$calls" && ok "ran flyway migrate" || bad "no flyway run"
! grep -qE '^docker (rm|pull)|^docker .*--name ' "$calls" && ok "no container removed or recreated" || bad "migrate touched a container"
no_secrets "case 3"

echo "case 4: bad or missing arguments exit 2 with usage"
for args in "bogus" "" "migrate extra" "mysql"; do
  # shellcheck disable=SC2086
  run_redeploy $args
  [ "$rc" -eq 2 ] && grep -q '^usage:' "$out" && ok "'$args' -> exit 2 + usage" || bad "'$args' -> exit $rc"
  [ ! -s "$calls" ] && ok "'$args' ran nothing" || bad "'$args' ran something"
done

echo "case 5: a failing pull aborts before removing the running container"
mkdir -p "$workdir/failbin"
printf '#!/usr/bin/env bash\n[ "$1" = pull ] && exit 1\nexec "%s/docker" "$@"\n' "$here/stub-bin-app" >"$workdir/failbin/docker"
chmod +x "$workdir/failbin/docker"
: >"$calls"
set +e
env -i PATH="$workdir/failbin:$here/stub-bin-app:/usr/bin:/bin" STUB_CALLS_LOG="$calls" STUB_STATE_DIR="$workdir/state" \
  bash "$workdir/cv-redeploy" domain-service >"$out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] && ok "non-zero exit on pull failure" || bad "pull failure was swallowed"
! grep -q '^docker rm ' "$calls" && ok "the running container was left alone" || bad "removed the container despite a failed pull"

echo
echo "cv-redeploy harness: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
