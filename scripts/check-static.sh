#!/usr/bin/env bash
# Static checks for invariants `terraform test` cannot see under
# `command = plan`: lifecycle meta-arguments, computed attributes that are
# unknown until apply, output `sensitive` flags, and the bash templates that
# boot the CI host. Each check guards a property whose regression would pass
# fmt/validate/test and only surface on a live host.
#
# Part of this module's offline gate (see ../CLAUDE.md). Needs no AWS
# credentials and no network. bootstrap/check-static.sh covers the
# bootstrap module's own equivalent (prevent_destroy on the state bucket).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=lib/extract-block.sh
source scripts/lib/extract-block.sh

fail=0
ok() { echo "OK: $*"; }
bad() {
  echo "FAIL: $*" >&2
  fail=1
}

# `#` comments are stripped before matching. `/* */` is deliberately NOT
# handled: no .tf file here uses block comments, and a naive scan
# false-positives on the wildcard ARNs this module is full of
# ("${aws_s3_bucket.frontend.arn}/*").

# --- 1. No output exposes the drone-deploy access key unless sensitive -----
# An `output` block may live in any .tf file, so every file is scanned.
unsafe_output=""
for tf_file in *.tf; do
  found=$(awk '
    function strip(l,  h) { h = index(l, "#"); if (h > 0) l = substr(l, 1, h - 1); return l }
    BEGIN { depth = 0; inblock = 0 }
    {
      line = strip($0)
      if (!inblock) {
        if (line ~ /^output[ \t]+"[^"]+"[ \t]*{/) { inblock = 1; depth = 0; refs = 0; sens = 0; name = line }
        else next
      }
      if (line ~ /aws_iam_access_key\.drone_deploy/) refs = 1
      if (line ~ /^[ \t]*sensitive[ \t]*=[ \t]*true[ \t]*$/) sens = 1
      depth += gsub(/\{/, "{", line); depth -= gsub(/\}/, "}", line)
      if (depth == 0) { inblock = 0; if (refs && !sens) print name }
    }
  ' "$tf_file")
  [ -n "$found" ] && unsafe_output="${unsafe_output}${tf_file}: ${found}
"
done
if [ -n "$unsafe_output" ]; then
  bad "an output references aws_iam_access_key.drone_deploy without sensitive = true:
${unsafe_output}"
else
  ok "no output exposes aws_iam_access_key.drone_deploy (or every such output is sensitive = true)"
fi

# --- 2. The drone-deploy user's policy stays least-privilege ---------------
# The deploy key is a long-lived static credential stored in Drone, so its
# policy must never widen silently: exactly these actions, Allow only, and
# every Resource a reference to the frontend bucket or distribution (never a
# literal, never "*"). A deliberate change updates EXPECTED_ACTIONS here.
EXPECTED_ACTIONS="cloudfront:CreateInvalidation s3:DeleteObject s3:GetObject s3:ListBucket s3:PutObject"
policy_block=$(extract_block '^resource[ \t]+"aws_iam_user_policy"[ \t]+"drone_deploy"[ \t]*{' <iam.tf)
if [ -z "$policy_block" ]; then
  bad 'resource "aws_iam_user_policy" "drone_deploy" { ... } not found in iam.tf'
else
  actions=$(printf '%s\n' "$policy_block" | grep -E '^[ \t]*Action[ \t]*=' | grep -oE '"[^"]+"' | tr -d '"' | sort -u | tr '\n' ' ' | sed 's/ $//')
  effects=$(printf '%s\n' "$policy_block" | grep -E '^[ \t]*Effect[ \t]*=' | grep -oE '"[^"]+"' | tr -d '"' | sort -u | tr '\n' ' ' | sed 's/ $//')
  bad_resources=$(printf '%s\n' "$policy_block" | grep -E '^[ \t]*Resource[ \t]*=' |
    grep -vE '^[ \t]*Resource[ \t]*=[ \t]*("\$\{)?aws_(s3_bucket|cloudfront_distribution)\.frontend\.arn(\}/\*")?[ \t]*$' || true)
  if [ "$actions" != "$EXPECTED_ACTIONS" ]; then
    bad "aws_iam_user_policy.drone_deploy actions changed: expected [$EXPECTED_ACTIONS], got [$actions]. A deliberate change is its own reviewed decision; update EXPECTED_ACTIONS here with it."
  elif [ "$effects" != "Allow" ]; then
    bad "aws_iam_user_policy.drone_deploy has statement effects [$effects]; expected Allow only"
  elif [ -n "$bad_resources" ]; then
    bad "aws_iam_user_policy.drone_deploy has a Resource that is not the frontend bucket/distribution reference:
${bad_resources}"
  else
    ok "aws_iam_user_policy.drone_deploy is least-privilege: [$actions] on the frontend bucket/distribution only"
  fi
fi

# --- 3. Single-parameter ssm:GetParameter grants name one parameter --------
# The on-demand-CI Lambdas each read exactly one parameter. Their grants must
# reference a specific aws_ssm_parameter.<name>.arn, never a literal ARN that
# could be a wildcard over deploy/*. (The tree-scoped role grants, the app
# host's Deny and the CI host's ci/* scope, are asserted in tests/plan.tftest.hcl.)
ssm_violations=""
for tf_file in *.tf; do
  v=$(awk '
    function strip(l,  h) { h = index(l, "#"); if (h > 0) l = substr(l, 1, h - 1); return l }
    {
      line = strip($0)
      if (line ~ /Action[ \t]*=[ \t]*\["ssm:GetParameter"\][ \t]*$/) { want = 1; next }
      if (!want || line ~ /^[ \t]*$/) next
      want = 0
      if (line !~ /^[ \t]*Resource[ \t]*=[ \t]*aws_ssm_parameter\.[A-Za-z0-9_]+\.arn[ \t]*$/) print line
    }
  ' "$tf_file")
  [ -n "$v" ] && ssm_violations="${ssm_violations}${tf_file}: ${v}
"
done
if [ -n "$ssm_violations" ]; then
  bad "a single-parameter ssm:GetParameter grant does not reference a specific aws_ssm_parameter.<name>.arn:
${ssm_violations}"
else
  ok "every single-parameter ssm:GetParameter grant references a specific aws_ssm_parameter.<name>.arn"
fi

# --- 4. aws_instance.drone's ignore_changes keeps its three elements -------
# `ami` stops AMI churn from replacing the CI host on unrelated applies;
# the CIKeepAlive tag entries let an operator pause the reaper without drift.
# Matched as exact list elements, not substrings.
drone_block=$(extract_block '^resource[ \t]+"aws_instance"[ \t]+"drone"[ \t]*{' <ci.tf)
lifecycle_block=$(printf '%s\n' "$drone_block" | extract_block '^[ \t]*lifecycle[ \t]*{')
list_content=$(printf '%s' "$lifecycle_block" | tr '\n' ' ' | sed -n 's/.*ignore_changes[ \t]*=[ \t]*\[\(.*\)\].*/\1/p')
if [ -z "$list_content" ]; then
  bad "no ignore_changes = [ ... ] list found in aws_instance.drone's lifecycle block (ci.tf)"
else
  IFS=',' read -ra raw <<<"$list_content"
  elements=()
  for r in "${raw[@]}"; do elements+=("$(printf '%s' "$r" | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//')"); done
  missing=""
  for want in 'ami' 'tags["CIKeepAlive"]' 'tags_all["CIKeepAlive"]'; do
    hit=0
    for el in "${elements[@]}"; do [ "$el" = "$want" ] && hit=1 && break; done
    [ "$hit" -eq 0 ] && missing="$missing $want"
  done
  if [ -n "$missing" ]; then
    bad "aws_instance.drone's ignore_changes is missing (as exact list elements):$missing"
  else
    ok "aws_instance.drone's ignore_changes covers ami, tags[\"CIKeepAlive\"], tags_all[\"CIKeepAlive\"]"
  fi
fi

# --- 5. The doorbell/reaper Lambdas target the current CI host -------------
# INSTANCE_ID must come from aws_instance.drone.id (computed, so invisible to
# plan-time tests); a literal would silently target a replaced instance.
missing_wiring=""
for fn in ci_doorbell ci_reaper; do
  fn_block=$(extract_block "^resource[ \t]+\"aws_lambda_function\"[ \t]+\"${fn}\"[ \t]*{" <ci-on-demand.tf)
  if ! printf '%s\n' "$fn_block" | grep -Eq '^[ \t]*INSTANCE_ID[ \t]*=[ \t]*aws_instance\.drone\.id[ \t]*$'; then
    missing_wiring="$missing_wiring aws_lambda_function.$fn"
  fi
done
if [ -n "$missing_wiring" ]; then
  bad "INSTANCE_ID is not wired from aws_instance.drone.id on:$missing_wiring"
else
  ok "ci_doorbell and ci_reaper wire INSTANCE_ID from aws_instance.drone.id"
fi

# --- 6. Every `docker run … drone/drone:…` passes DRONE_DATABASE_SECRET ----
# Two templates start drone-server (first boot, and jenkins-provision.sh's
# :80 remediation path). Without the key, Drone stores repo secrets
# unencrypted, or fails to decrypt ones already encrypted.
drone_run_violations=""
for f in templates/drone-user-data.sh templates/jenkins-provision.sh; do
  v=$(awk '
    {
      if (!c) {
        if ($0 ~ /^[ \t]*docker run /) { c = 1; s = ($0 ~ /-e DRONE_DATABASE_SECRET=/); d = ($0 ~ /drone\/drone:/) }
        next
      }
      if ($0 ~ /-e DRONE_DATABASE_SECRET=/) s = 1
      if ($0 ~ /drone\/drone:/) d = 1
      if ($0 !~ /\\[ \t]*$/) { if (d && !s) print "VIOLATION"; c = 0 }
    }
  ' "$f")
  [ -n "$v" ] && drone_run_violations="$drone_run_violations $f"
done
if [ -n "$drone_run_violations" ]; then
  bad "a 'docker run … drone/drone:…' is missing -e DRONE_DATABASE_SECRET in:$drone_run_violations"
else
  ok "every 'docker run … drone/drone:…' passes -e DRONE_DATABASE_SECRET"
fi

# --- 7. The cloud-init wait lives only in the SSM provisioning path --------
# templates/jenkins-provision.sh also runs INSIDE cloud-init (user_data via
# jenkins-bootstrap.sh), so a `cloud-init status --wait` there deadlocks.
# The wait belongs in ci.tf's null_resource.jenkins_provision SSM command,
# ahead of the script, to stop that path racing a fresh host's user_data.
if grep -q "cloud-init status --wait" templates/jenkins-provision.sh; then
  bad "templates/jenkins-provision.sh calls 'cloud-init status --wait' (deadlocks on the user_data path; the wait belongs in ci.tf's null_resource.jenkins_provision)"
elif ! grep -q "cloud-init status --wait" ci.tf; then
  bad "ci.tf no longer runs 'cloud-init status --wait' before the SSM provisioning script (a fresh host's user_data race is unguarded)"
else
  ok "'cloud-init status --wait' runs only in ci.tf's SSM provisioning path, not in the shared script"
fi

exit $fail
