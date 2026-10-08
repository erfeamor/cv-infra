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
    -e 's#\${log_group_domain_service}#/cv-project/cv-domain-service#g' \
    -e 's#\${log_group_bff_node}#/cv-project/cv-bff-node#g' \
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

# cv_instance_id reads cloud-init's file (T-054), overridable via CV_INSTANCE_ID_FILE.
printf 'i-0abc123def4567890\n' >"$workdir/instance-id.ok"
printf 'not-an-instance-id\n' >"$workdir/instance-id.bad"
: >"$workdir/instance-id.empty"

run_redeploy() { # run_redeploy <args...>; sets $rc. ID_FILE selects the fixture.
  : >"$calls"; rm -f "$workdir/state/digest"
  set +e
  env -i CV_INSTANCE_ID_FILE="${ID_FILE:-$workdir/instance-id.ok}" PATH="$here/stub-bin-app:/usr/bin:/bin" STUB_CALLS_LOG="$calls" STUB_STATE_DIR="$workdir/state" \
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

# T-054: the awslogs driver, defined once in cv_run_* and so reached by both the
# boot flow and cv-redeploy.
awslogs_check() { # awslogs_check <case> <container> <group>
  local c="$1" name="$2" group="$3" line
  line=$(grep "^docker run -d --name $name " "$calls" || true)
  for want in "--log-driver awslogs" "--log-opt awslogs-region=eu-west-3" \
    "--log-opt awslogs-group=$group" "--log-opt awslogs-stream=$name-i-0abc123def4567890" \
    "--log-opt mode=non-blocking" "--log-opt max-buffer-size=4m"; do
    case "$line" in
      *" $want "*) ok "$c: $want" ;;
      *) bad "$c: missing '$want' in the $name run" ;;
    esac
  done
}

echo "case 6: awslogs on domain-service and bff-node (T-054)"
run_redeploy domain-service
awslogs_check "case 6a" domain-service /cv-project/cv-domain-service
grep '^docker run -d --name domain-service ' "$calls" | grep -q -- ' --log-opt awslogs-datetime-format=%Y-%m-%dT%H:%M:%S ' && ok "domain-service: multiline datetime format" || bad "domain-service: no awslogs-datetime-format"
run_redeploy bff-node
awslogs_check "case 6b" bff-node /cv-project/cv-bff-node
! grep '^docker run -d --name bff-node ' "$calls" | grep -q datetime-format && ok "bff-node: no datetime format" || bad "bff-node: has a datetime format"

echo "case 7: mysql and flyway do not use awslogs"
run_redeploy migrate
! grep -q 'log-driver\|log-opt' "$calls" && ok "flyway run has no log options" || bad "flyway run carries log options"
if grep -n 'docker run -d --name mysql' "$tpl" >/dev/null; then
  mysql_run=$(awk '/docker run -d --name mysql/{c=1} c{print} c&&/performance-schema/{exit}' "$tpl")
  case "$mysql_run" in
    *log-driver*|*log-opt*) bad "the mysql run carries log options" ;;
    *) ok "the mysql run carries no log options" ;;
  esac
else
  bad "could not find the mysql run in the template"
fi

echo "case 8: a missing/malformed instance-id file aborts instead of producing an empty stream"
for mode in missing bad empty; do
  for svc in domain-service bff-node; do
    if [ "$mode" = missing ]; then f="$workdir/nonexistent"; else f="$workdir/instance-id.$mode"; fi
    ID_FILE=$f run_redeploy "$svc"
    [ "$rc" -ne 0 ] && ok "$svc/$mode: non-zero exit" || bad "$svc/$mode: exit 0 despite a bad instance-id file"
    ! grep -q '^docker run ' "$calls" && ok "$svc/$mode: container not started" || bad "$svc/$mode: container started"
    ! grep -q '^docker rm ' "$calls" && ok "$svc/$mode: running container left alone" || bad "$svc/$mode: removed the running container"
    grep -q 'FATAL' "$out" && ok "$svc/$mode: clear error" || bad "$svc/$mode: no FATAL message"
  done
done

echo
echo "cv-redeploy harness: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
