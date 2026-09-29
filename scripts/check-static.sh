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
# policy must never widen silently. The whole resource block is parsed (not
# line prefixes, so one-line statements and multi-line lists count too):
#   - every IAM action string anywhere in it is in EXPECTED_ACTIONS, and all
#     of them are present
#   - every Effect is "Allow"
#   - no NotAction / NotResource / Principal anywhere
#   - every Resource value is the frontend bucket, its objects, or the
#     frontend distribution, referenced by resource address (never a literal)
# A deliberate change updates EXPECTED_ACTIONS here, reviewed as its own decision.
EXPECTED_ACTIONS="cloudfront:CreateInvalidation s3:DeleteObject s3:GetObject s3:ListBucket s3:PutObject"
policy_block=$(extract_block '^resource[ \t]+"aws_iam_user_policy"[ \t]+"drone_deploy"[ \t]*{' <iam.tf)
if [ -z "$policy_block" ]; then
  bad 'resource "aws_iam_user_policy" "drone_deploy" { ... } not found in iam.tf'
else
  verdict=$(EXPECTED="$EXPECTED_ACTIONS" python3 -c '
import os, re, sys
b = sys.stdin.read()
expected = set(os.environ["EXPECTED"].split())
problems = []
if re.search(r"\b(NotAction|NotResource|Principal|NotPrincipal)\b", b):
    problems.append("uses NotAction/NotResource/Principal")
actions = set()
for v in re.findall(r"\bAction\s*=\s*(\[[^\]]*\]|\"[^\"]*\"|[A-Za-z0-9_.]+)", b):
    items = re.findall(r"\"[^\"]*\"|[A-Za-z0-9_.]+", v[1:-1]) if v.startswith("[") else [v]
    for it in items:
        actions.add(it.strip("\""))
if not actions:
    problems.append("no Action found")
if actions != expected:
    problems.append("actions [%s], expected [%s]" % (" ".join(sorted(actions)), " ".join(sorted(expected))))
effects = set(re.findall(r"\bEffect\s*=\s*\"([A-Za-z]+)\"", b))
if effects != {"Allow"}:
    problems.append("effects [%s], expected [Allow]" % " ".join(sorted(effects)))
allowed = {"aws_s3_bucket.frontend.arn", "\"${aws_s3_bucket.frontend.arn}/*\"", "aws_cloudfront_distribution.frontend.arn"}
res = re.findall(r"\bResource\s*=\s*(\[[^\]]*\]|\"[^\"]*\"|[A-Za-z0-9_.]+)", b)
if not res:
    problems.append("no Resource found")
for r in res:
    items = re.findall(r"\"[^\"]*\"|[A-Za-z0-9_.]+", r[1:-1]) if r.startswith("[") else [r]
    for it in items:
        if it not in allowed:
            problems.append("resource %s is not a frontend bucket/distribution reference" % it)
print("; ".join(problems) if problems else "OK")
' <<<"$policy_block" || echo "parse error")
  if [ "$verdict" = "OK" ]; then
    ok "aws_iam_user_policy.drone_deploy is least-privilege: [$EXPECTED_ACTIONS] on the frontend bucket/distribution only"
  else
    bad "aws_iam_user_policy.drone_deploy: $verdict"
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

# --- 8. Any self-invoke grant is scoped to the doorbell's own ARN only -----
# T-034: the async redelivery path self-invokes (lambda:InvokeFunction).
# `terraform test` cannot check the Resource value itself -- the rendered
# policy JSON embeds this function's own computed ARN, unknown under
# `command = plan` (same class of limitation ci-on-demand.tf documents for
# the EC2 action lists). Any resource file may carry a lambda:InvokeFunction
# grant, so every .tf file is scanned, matching the same
# `Action = ["..."]` / next-non-blank-line `Resource = ...` shape check #3
# already uses for ssm:GetParameter.
invoke_violations=""
for tf_file in *.tf; do
  v=$(awk '
    function strip(l,  h) { h = index(l, "#"); if (h > 0) l = substr(l, 1, h - 1); return l }
    {
      line = strip($0)
      if (line ~ /Action[ \t]*=[ \t]*\["lambda:InvokeFunction"\][ \t]*$/) { want = 1; next }
      if (!want || line ~ /^[ \t]*$/) next
      want = 0
      if (line !~ /^[ \t]*Resource[ \t]*=[ \t]*aws_lambda_function\.ci_doorbell\.arn[ \t]*$/) print line
    }
  ' "$tf_file")
  [ -n "$v" ] && invoke_violations="${invoke_violations}${tf_file}: ${v}
"
done
if [ -n "$invoke_violations" ]; then
  bad "a lambda:InvokeFunction grant does not scope Resource to aws_lambda_function.ci_doorbell.arn exactly:
${invoke_violations}"
else
  ok "every lambda:InvokeFunction grant is scoped to aws_lambda_function.ci_doorbell.arn"
fi

# --- 9. The CI host's public address is named through ONE local -----------
# Review round 1, finding 10: DRONE_HEALTHZ_URL and JENKINS_BASE_URL must
# both build from local.ci_public_host, never from a second literal or
# reference of their own -- so a future re-point changes exactly one line.
# UPDATED for T-034 phase 2 (plan case 5): local.ci_public_host is now
# var.ci_hostname, not aws_eip.drone.public_ip (which no longer exists after
# the EIP-removal commit) -- and both URLs must be https now that Caddy
# terminates TLS (T-033). `terraform test` DOES cover the "== var.ci_hostname"
# and "startswith https://" properties now (t034_phase2_dns_tls,
# tests/plan.tftest.hcl) since var.ci_hostname is known at plan time, unlike
# the EIP's public_ip -- this check covers only what that run block cannot:
# that neither URL has regressed back to a literal address or bare http.
if grep -Eq 'DRONE_HEALTHZ_URL[ \t]*=.*aws_eip\.drone\.public_ip' ci-on-demand.tf ||
  grep -Eq 'JENKINS_BASE_URL[ \t]*=.*aws_eip\.drone\.public_ip' ci-on-demand.tf; then
  bad "DRONE_HEALTHZ_URL or JENKINS_BASE_URL references aws_eip.drone.public_ip directly -- that resource no longer exists after T-034 phase 2's EIP-removal commit"
elif ! grep -Eq '^\s*ci_public_host\s*=\s*var\.ci_hostname\s*$' ci-on-demand.tf; then
  bad "local.ci_public_host (= var.ci_hostname) not found in ci-on-demand.tf -- has it been renamed without updating this check?"
elif grep -Eq 'DRONE_HEALTHZ_URL[ \t]*=[ \t]*"http://' ci-on-demand.tf || grep -Eq 'JENKINS_BASE_URL[ \t]*=[ \t]*"http://' ci-on-demand.tf; then
  bad "DRONE_HEALTHZ_URL or JENKINS_BASE_URL is plain http:// -- Caddy (T-033) terminates TLS, both must be https://"
else
  ok "DRONE_HEALTHZ_URL and JENKINS_BASE_URL both build from local.ci_public_host (= var.ci_hostname) over https"
fi

# --- 10. The DNS-update IAM grant is exactly one action, the zone ARN, and
# the three conditions the plan specifies -- nothing wider. -----------------
# T-034 phase 2 (plan case 2): Route 53 has no record-level ARNs, so the
# Resource is unavoidably the whole zone; the Condition block is the only
# thing standing between this grant and "any record, any type, any action,
# in the whole zone" -- the CI role is reachable from inside a build (T-005
# gap), so this must be checked exactly, not just "present".
dns_policy_block=$(extract_block '^resource[ \t]+"aws_iam_role_policy"[ \t]+"drone_dns_update"[ \t]*{' <iam.tf)
if [ -z "$dns_policy_block" ]; then
  bad 'resource "aws_iam_role_policy" "drone_dns_update" { ... } not found in iam.tf'
else
  dns_verdict=$(python3 -c '
import re, sys
b = sys.stdin.read()
problems = []
if re.search(r"\b(NotAction|NotResource|Principal|NotPrincipal)\b", b):
    problems.append("uses NotAction/NotResource/Principal")
if not re.search(r"Action\s*=\s*local\.ci_dns_update_actions\b", b):
    problems.append("Action is not exactly local.ci_dns_update_actions")
if not re.search(r"Resource\s*=\s*data\.aws_route53_zone\.ci\.arn\b", b):
    problems.append("Resource is not exactly data.aws_route53_zone.ci.arn (a literal or a wildcard would widen this past one zone)")
if "ForAllValues:StringEquals" not in b:
    problems.append("condition is not ForAllValues:StringEquals (StringEquals alone also allows a request whose value set is a SUPERSET of the allowed one)")
for key, local_name in [
    ("route53:ChangeResourceRecordSetsNormalizedRecordNames", "local.ci_dns_update_record_names"),
    ("route53:ChangeResourceRecordSetsRecordTypes", "local.ci_dns_update_record_types"),
    ("route53:ChangeResourceRecordSetsActions", "local.ci_dns_update_actions_types"),
]:
    m = re.search(re.escape(key) + r"\"?\s*=\s*([A-Za-z0-9_.]+)", b)
    if not m:
        problems.append("condition key %s not found" % key)
    elif m.group(1) != local_name:
        problems.append("condition key %s = %s, expected %s" % (key, m.group(1), local_name))
print("; ".join(problems) if problems else "OK")
' <<<"$dns_policy_block" || echo "parse error")
  if [ "$dns_verdict" = "OK" ]; then
    ok "aws_iam_role_policy.drone_dns_update grants exactly route53:ChangeResourceRecordSets on the zone ARN, conditioned ForAllValues:StringEquals on all three keys"
  else
    bad "aws_iam_role_policy.drone_dns_update: $dns_verdict"
  fi
fi

# --- 11. Every drone-server run pins HOST=ci_hostname and PROTO=https ------
# T-034 phase 2 extends check #6's shape: the same two `docker run …
# drone/drone:…` invocations that must carry DRONE_DATABASE_SECRET must also
# no longer point at the old EIP/http -- DRONE_SERVER_HOST must reference
# the ci_hostname placeholder and DRONE_SERVER_PROTO must be the literal
# https (a fixed value, never templated).
drone_host_proto_violations=""
for f in templates/drone-user-data.sh templates/jenkins-provision.sh; do
  v=$(awk '
    {
      if (!c) {
        if ($0 ~ /^[ \t]*docker run /) { c = 1; h = ($0 ~ /-e DRONE_SERVER_HOST="\$\{ci_hostname\}"/); p = ($0 ~ /-e DRONE_SERVER_PROTO=https/); d = ($0 ~ /drone\/drone:/) }
        next
      }
      if ($0 ~ /-e DRONE_SERVER_HOST="\$\{ci_hostname\}"/) h = 1
      if ($0 ~ /-e DRONE_SERVER_PROTO=https/) p = 1
      if ($0 ~ /drone\/drone:/) d = 1
      if ($0 !~ /\\[ \t]*$/) { if (d && !(h && p)) print "VIOLATION"; c = 0 }
    }
  ' "$f")
  [ -n "$v" ] && drone_host_proto_violations="$drone_host_proto_violations $f"
done
if [ -n "$drone_host_proto_violations" ]; then
  bad "a 'docker run … drone/drone:…' is missing -e DRONE_SERVER_HOST=\"\${ci_hostname}\" or -e DRONE_SERVER_PROTO=https in:$drone_host_proto_violations"
else
  ok "every 'docker run … drone/drone:…' pins DRONE_SERVER_HOST=\${ci_hostname} and DRONE_SERVER_PROTO=https"
fi

# --- 12. The CI A record keeps ignore_changes = [records] -------------------
# T-034 phase 2, case 1: a lifecycle meta-argument, invisible to
# `terraform test` (same class of gap as aws_instance.drone's own
# ignore_changes, check #4 above). Without it, the boot updater's own
# UPSERT (real state, outside Terraform's view) would be reverted to
# whatever `records` says in config on the next apply.
record_block=$(extract_block '^resource[ \t]+"aws_route53_record"[ \t]+"ci"[ \t]*{' <dns.tf)
if [ -z "$record_block" ]; then
  bad 'resource "aws_route53_record" "ci" { ... } not found in dns.tf'
else
  record_lifecycle_block=$(printf '%s\n' "$record_block" | extract_block '^[ \t]*lifecycle[ \t]*{')
  if printf '%s' "$record_lifecycle_block" | grep -Eq 'ignore_changes[ \t]*=[ \t]*\[records\]'; then
    ok "aws_route53_record.ci keeps ignore_changes = [records]"
  else
    bad "aws_route53_record.ci is missing lifecycle { ignore_changes = [records] } -- the boot updater's own UPSERT would be reverted on the next apply"
  fi
fi

exit $fail
