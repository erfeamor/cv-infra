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

# --- 1b. No output exposes the BFF service client's secret (T-043) ---------
if grep -n 'client_secret' outputs.tf | grep -v '^[0-9]*:[ \t]*#' >/dev/null; then
  bad "outputs.tf references a Cognito client_secret (the BFF service secret must only reach SSM)"
else
  ok "outputs.tf never references a Cognito client_secret"
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

# --- 2b. The public-vanilla OIDC deploy role stays master-only and admin-safe (T-045)
# The role shares the frontend bucket with the live admin (admin/), so its
# policy must keep the explicit Deny on admin/*, never use a literal or "*"
# Resource, and its trust must stay a StringEquals on the exact master `sub`.
oidc_policy=$(extract_block '^resource[ \t]+"aws_iam_role_policy"[ \t]+"public_vanilla_deploy"[ \t]*{' <github-oidc.tf)
oidc_role=$(extract_block '^resource[ \t]+"aws_iam_role"[ \t]+"public_vanilla_deploy"[ \t]*{' <github-oidc.tf)
if [ -z "$oidc_policy" ] || [ -z "$oidc_role" ]; then
  bad 'aws_iam_role/aws_iam_role_policy "public_vanilla_deploy" not found in github-oidc.tf'
else
  problems=""
  grep -qE 'Effect[ \t]*=[ \t]*"Deny"' <<<"$oidc_policy" || problems="$problems no-Deny"
  grep -qF '"${aws_s3_bucket.frontend.arn}/admin/*"' <<<"$oidc_policy" || problems="$problems no-admin-Deny-resource"
  grep -qE 'Resource[ \t]*=[ \t]*"\*"|NotAction|NotResource|:\*"' <<<"$oidc_policy" && problems="$problems wildcard-or-Not*"
  grep -qE 'StringEquals' <<<"$oidc_role" || problems="$problems trust-not-StringEquals"
  grep -qE 'StringLike|ForAnyValue' <<<"$oidc_role" && problems="$problems trust-uses-pattern-match"
  grep -qF 'ref:refs/heads/master' github-oidc.tf || problems="$problems sub-not-master"
  if [ -z "$problems" ]; then
    ok "the public-vanilla deploy role keeps its admin/* Deny, no wildcard Resource/Action, and an exact master-only StringEquals trust"
  else
    bad "github-oidc.tf public_vanilla_deploy:$problems"
  fi
fi

# --- 2c. CI deploy roles and SSM documents (T-047) ----------------------------
# The documents must never declare parameters (no injection surface), and no
# deploy role may allow ssm:SendCommand on AWS-RunShellScript or a bare "*"; the
# instance grant must carry the ssm:resourceTag/Name condition.
if [ ! -f ci-deploy.tf ]; then
  bad 'ci-deploy.tf not found (T-047)'
else
  problems=""
  stripped=$(sed 's/#.*//' ci-deploy.tf)
  grep -qE '"?parameters"?[ \t]*=' <<<"$stripped" && problems="$problems document-declares-parameters"
  grep -qE 'AWS-RunShellScript|AWS-[A-Za-z]+' <<<"$stripped" && problems="$problems references-AWS-managed-document"
  grep -qE 'NotAction|NotResource|:\*"' <<<"$stripped" && problems="$problems wildcard-action-or-Not*"
  # Every Resource = "*" must sit in a statement whose action is not SendCommand.
  python3 - ci-deploy.tf <<'PY' || problems="$problems sendcommand-unscoped"
import re, sys
src = re.sub(r"#.*", "", open(sys.argv[1]).read())
bad = False
# One chunk per policy statement: split on each `Effect = "Allow"`.
chunks = re.split(r'Effect\s*=\s*"Allow"', src)[1:]
sends = [c for c in chunks if '"ssm:SendCommand"' in c.split("Effect")[0].split("},")[0]]
if len(sends) != 6:  # three roles x (document, tagged instances)
    bad = True
for c in sends:
    body = c.split("\n      },")[0]
    if re.search(r'Resource\s*=\s*"\*"', body):
        bad = True
    if "local.app_instances_arn" in body and not re.search(r'StringEquals\s*=\s*{\s*"ssm:resourceTag/Name"\s*=\s*local\.app_host_name_tag', body):
        bad = True
    if "local.app_instances_arn" not in body and "aws_ssm_document.redeploy_" not in body:
        bad = True
sys.exit(1 if bad else 0)
PY
  # T-049: the migrate role gets no ECR at all, and its trust is exactly
  # StringEquals aud + sub = cv-database master; its own document is the only
  # document it may send.
  python3 - ci-deploy.tf <<'PY' || problems="$problems migrate-role-shape"
import re, sys
src = re.sub(r"#.*", "", open(sys.argv[1]).read())
def block(kind, name):
    m = re.search(r'resource\s+"%s"\s+"%s"\s*{' % (kind, name), src)
    if not m:
        return None
    i, depth = m.end(), 1
    while depth and i < len(src):
        depth += {"{": 1, "}": -1}.get(src[i], 0)
        i += 1
    return src[m.start():i]
role = block("aws_iam_role", "database_migrate")
pol = block("aws_iam_role_policy", "database_migrate")
doc = block("aws_ssm_document", "redeploy_migrate")
# The policy's statements are split between the resource and a named local.
loc = re.search(r'database_migrate_known_statements\s*=\s*\[.*?\n  \]\n', src, re.S)
bad = not (role and pol and doc and loc)
if loc:
    pol = pol + loc.group(0)
if not bad:
    if re.search(r'ecr|ECR', pol):
        bad = True
    if "aws_ssm_document.redeploy_migrate.arn" not in pol or re.search(r"aws_ssm_document\.redeploy_(?!migrate)", pol):
        bad = True
    if not re.search(r'StringEquals\s*=\s*{\s*"token\.actions\.githubusercontent\.com:aud"\s*=\s*"sts\.amazonaws\.com"\s*"token\.actions\.githubusercontent\.com:sub"\s*=\s*"repo:\${local\.github_org}/cv-database:ref:refs/heads/master"\s*}', role):
        bad = True
    if re.search(r'StringLike|ForAnyValue|ForAllValues', role):
        bad = True
    if '"/usr/local/bin/cv-redeploy migrate"' not in doc:
        bad = True
sys.exit(1 if bad else 0)
PY
  if [ -z "$problems" ]; then
    ok "ci-deploy.tf: documents take no parameters; SendCommand is never * or AWS-RunShellScript and instances are tag-conditioned; the migrate role has no ECR and an exact cv-database master trust"
  else
    bad "ci-deploy.tf:$problems"
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

# --- 4. aws_instance.drone's ignore_changes keeps its five elements --------
# `ami` stops AMI churn from replacing the CI host on unrelated applies;
# the CIKeepAlive tag entries let an operator pause the reaper without drift;
# the CILastPush entries (T-048) keep the doorbell's push marker from drifting.
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
  for want in 'ami' 'tags["CIKeepAlive"]' 'tags_all["CIKeepAlive"]' 'tags["CILastPush"]' 'tags_all["CILastPush"]'; do
    hit=0
    for el in "${elements[@]}"; do [ "$el" = "$want" ] && hit=1 && break; done
    [ "$hit" -eq 0 ] && missing="$missing $want"
  done
  if [ -n "$missing" ]; then
    bad "aws_instance.drone's ignore_changes is missing (as exact list elements):$missing"
  else
    ok "aws_instance.drone's ignore_changes covers ami and the CIKeepAlive and CILastPush tags"
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

# --- 13. null_resource.jenkins_provision waits on the DNS grant + record ---
# T-034 phase 2 review round 1, finding 4: this SSM push's own first action
# is `systemctl enable --now ci-dns-updater.service`, which calls Route 53
# using the instance role -- both the IAM grant and the record it UPSERTs
# into must already exist, or the very first run fails. `depends_on` is a
# meta-argument, invisible to `terraform test` (same class of gap as check
# #4/#12 above), so this checks the source text directly.
provision_block=$(extract_block '^resource[ \t]+"null_resource"[ \t]+"jenkins_provision"[ \t]*{' <ci.tf)
if [ -z "$provision_block" ]; then
  bad 'resource "null_resource" "jenkins_provision" { ... } not found in ci.tf'
else
  # extract_block only brace-balances ({}), not brackets ([]), so it can't
  # isolate the depends_on = [ ... ] list on its own -- these two resource
  # addresses are distinctive enough (and depends_on is the only place
  # either could legitimately appear in this resource) to grep for directly
  # within the whole already-extracted resource body instead.
  missing=""
  for want in 'aws_iam_role_policy.drone_dns_update,' 'aws_route53_record.ci,'; do
    printf '%s' "$provision_block" | grep -qF "$want" || missing="$missing $want"
  done
  if [ -n "$missing" ]; then
    bad "null_resource.jenkins_provision's depends_on is missing:$missing"
  else
    ok "null_resource.jenkins_provision depends_on covers aws_iam_role_policy.drone_dns_update and aws_route53_record.ci"
  fi
fi

# --- 14. The reaper's DNS-sentinel grant reuses the SAME named locals as
# drone_dns_update -- nothing wider, nothing duplicated. -------------------
# T-034 phase 2 review round 2, finding 2(a): aws_iam_role_policy.ci_reaper
# (ci-on-demand.tf) has several OTHER statements (EC2 stop, describe,
# cloudwatch, ssm, logs), so unlike check #10 this can't assert the WHOLE
# body -- it checks that the DNS-specific piece exists, referencing the
# exact same locals check #10 already verifies the VALUES of (so this check
# does not re-verify those values -- only that this SECOND policy actually
# uses them).
reaper_policy_block=$(extract_block '^resource[ \t]+"aws_iam_role_policy"[ \t]+"ci_reaper"[ \t]*{' <ci-on-demand.tf)
if [ -z "$reaper_policy_block" ]; then
  bad 'resource "aws_iam_role_policy" "ci_reaper" { ... } not found in ci-on-demand.tf'
else
  reaper_dns_verdict=$(python3 -c '
import re, sys
b = sys.stdin.read()
problems = []
if not re.search(r"Action\s*=\s*local\.ci_dns_update_actions\b", b):
    problems.append("no statement with Action = local.ci_dns_update_actions")
if not re.search(r"Resource\s*=\s*data\.aws_route53_zone\.ci\.arn\b", b):
    problems.append("no statement with Resource = data.aws_route53_zone.ci.arn")
if "ForAllValues:StringEquals" not in b:
    problems.append("condition is not ForAllValues:StringEquals")
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
' <<<"$reaper_policy_block" || echo "parse error")
  if [ "$reaper_dns_verdict" = "OK" ]; then
    ok "aws_iam_role_policy.ci_reaper includes the DNS-sentinel statement, reusing iam.tf's drone_dns_update locals exactly"
  else
    bad "aws_iam_role_policy.ci_reaper: $reaper_dns_verdict"
  fi
fi

# --- 15. No LIVE reference to the released EIP survives anywhere -----------
# T-034 phase 2, COMMIT 2 of 2, case 7: aws_eip.drone and
# aws_eip_association.drone are gone from this config -- a stray reference
# in actual CODE (a rename that missed a spot) would fail `terraform
# validate` outright anyway, so this exists to catch it a layer earlier,
# with a clearer message than validate's generic "reference to undeclared
# resource". `#` comments are stripped before matching (same convention as
# every other check in this file) -- prose that deliberately DISCUSSES the
# removed resources for historical context (this file's own commits, ci.tf's
# and dns.tf's headers) is expected and fine; only a reference outside a
# comment is a real regression.
eip_ref_violations=""
for tf_file in *.tf; do
  v=$(awk '
    function strip(l,  h) { h = index(l, "#"); if (h > 0) l = substr(l, 1, h - 1); return l }
    { line = strip($0); if (line ~ /aws_eip(_association)?\.drone\y/) print line }
  ' "$tf_file")
  [ -n "$v" ] && eip_ref_violations="$eip_ref_violations $tf_file"
done
if [ -n "$eip_ref_violations" ]; then
  bad "a live (non-comment) reference to the released aws_eip.drone / aws_eip_association.drone survives in:$eip_ref_violations"
else
  ok "no reference to aws_eip.drone or aws_eip_association.drone survives anywhere"
fi

# --- 16. The doorbell's Route 53 grant is read-only and this zone only -----
# Live failure, 2026-09-30: wait_for_dns_to_match_instance now reads the
# AUTHORITATIVE record value via route53:ListResourceRecordSets instead of
# trusting the Lambda's own (cacheable) local resolver. That grant must never
# widen into a write -- a compromised doorbell (module docstring:
# lambda:InvokeFunction is unconditioned, Principal = "*") gaining
# route53:ChangeResourceRecordSets would let it repoint ci.erfeamor.com
# itself. Checked here, not tests/plan.tftest.hcl, for the same reason as
# check #10/#14: the doorbell's policy body has several OTHER statements
# (EC2 start, describe, ssm, self-invoke, logs), so this greps the WHOLE
# aws_iam_role_policy.ci_doorbell block for any route53 action wider than
# reads, and separately confirms the read grant itself is present and scoped
# to the one zone ARN.
doorbell_policy_block=$(extract_block '^resource[ \t]+"aws_iam_role_policy"[ \t]+"ci_doorbell"[ \t]*{' <ci-on-demand.tf)
if [ -z "$doorbell_policy_block" ]; then
  bad 'resource "aws_iam_role_policy" "ci_doorbell" { ... } not found in ci-on-demand.tf'
else
  doorbell_dns_verdict=$(python3 -c '
import re, sys
b = sys.stdin.read()
problems = []
route53_actions = set()
for v in re.findall(r"\bAction\s*=\s*(\[[^\]]*\]|local\.[A-Za-z0-9_]+|\"[^\"]*\")", b):
    if v.startswith("["):
        items = re.findall(r"\"[^\"]*\"", v)
        route53_actions.update(i.strip("\"") for i in items if i.strip("\"").startswith("route53:"))
    elif v.startswith("local."):
        if v == "local.ci_dns_read_actions":
            route53_actions.add("route53:ListResourceRecordSets")
        elif "dns" in v or "route53" in v:
            route53_actions.add(v)  # an unrecognized route53-shaped local -- flagged as unexpected below
    elif v.strip("\"").startswith("route53:"):
        route53_actions.add(v.strip("\""))
if not route53_actions:
    problems.append("no route53 action found (expected exactly route53:ListResourceRecordSets)")
elif route53_actions != {"route53:ListResourceRecordSets"}:
    problems.append("route53 actions [%s], expected exactly [route53:ListResourceRecordSets] -- read-only, nothing wider" % " ".join(sorted(route53_actions)))
if not re.search(r"Action\s*=\s*local\.ci_dns_read_actions\b", b):
    problems.append("no statement with Action = local.ci_dns_read_actions")
if not re.search(r"Resource\s*=\s*data\.aws_route53_zone\.ci\.arn\b", b):
    problems.append("no statement with Resource = data.aws_route53_zone.ci.arn")
print("; ".join(problems) if problems else "OK")
' <<<"$doorbell_policy_block" || echo "parse error")
  if [ "$doorbell_dns_verdict" = "OK" ]; then
    ok "aws_iam_role_policy.ci_doorbell's only route53 action is the read-only local.ci_dns_read_actions, scoped to data.aws_route53_zone.ci.arn"
  else
    bad "aws_iam_role_policy.ci_doorbell: $doorbell_dns_verdict"
  fi
fi

# --- 17. ci-dns-sentinel.service orders itself after network-online -------
# T-041: on a live host, ExecStop (scripts/ci-dns-sentinel.sh) raced
# systemd-networkd/-resolved going down first -- the unit had no ordering
# relationship to networking at all, only Before=docker.service (which
# governs start order, not stop order). systemd stops units in the REVERSE
# of their start order, so Wants=/After=network-online.target (matching
# ci-dns-updater.service's own pair, same heredoc file) keeps
# networkd/resolved up until ExecStop returns. `terraform test` can't see
# this: it's plain text inside a bash heredoc embedded via templatefile(),
# not a resource attribute.
sentinel_unit_block=$(awk '
  /cat >\/etc\/systemd\/system\/ci-dns-sentinel\.service <<.DNS_SENTINEL_UNIT_EOF./ { c = 1; next }
  c && /^DNS_SENTINEL_UNIT_EOF$/ { c = 0 }
  c { print }
' templates/jenkins-provision.sh)
if [ -z "$sentinel_unit_block" ]; then
  bad "ci-dns-sentinel.service heredoc not found in templates/jenkins-provision.sh"
else
  missing=""
  printf '%s\n' "$sentinel_unit_block" | grep -qE '^Wants=network-online\.target$' || missing="$missing Wants=network-online.target"
  printf '%s\n' "$sentinel_unit_block" | grep -qE '^After=network-online\.target$' || missing="$missing After=network-online.target"
  if [ -n "$missing" ]; then
    bad "ci-dns-sentinel.service is missing:$missing -- ExecStop can race network teardown on shutdown (T-041)"
  else
    ok "ci-dns-sentinel.service orders itself Wants=/After=network-online.target, so ExecStop runs before networking is torn down (T-041)"
  fi
fi

# --- 18. The app host waits for its S3 script, SSM hash and read grant -----
# T-044: user_data is a stub that downloads app-host/provision.sh and reads the
# hash at first boot, so the instance must depend_on all three (the stub's
# embedded hash orders the S3 object/SSM parameter only implicitly through
# the script, not through user_data's reference to them). A computed-at-apply
# ordering `terraform test` cannot see.
instance_block=$(extract_block '^resource "aws_instance" "domain_service"' <compute.tf)
missing=""
for dep in aws_s3_object.app_host_provision aws_ssm_parameter.app_host_provision_sha256 aws_iam_role_policy.app_read_provision_script aws_iam_role_policy.app_write_container_logs; do
  printf '%s\n' "$instance_block" | grep -qE "^[[:space:]]+${dep//./\\.},?[[:space:]]*$" || missing="$missing $dep"
done
if [ -n "$missing" ]; then
  bad "aws_instance.domain_service depends_on is missing:$missing (T-044)"
else
  ok "aws_instance.domain_service depends_on its S3 provisioning script, SSM hash, read grant and container-logs grant (T-044, T-054)"
fi

# --- 19. The doorbell's tagging grant stays on the CI instance, one tag key -
# T-048: ec2:CreateTags must be scoped to local.ci_instance_arn and carry
# the local.ci_doorbell_tag_condition (ForAllValues aws:TagKeys), and no
# other statement in the doorbell's policy may grant a tag action. The
# Resource is computed, so terraform test cannot see it.
doorbell_policy=$(extract_block '^resource[ \t]+"aws_iam_role_policy"[ \t]+"ci_doorbell"[ \t]*{' <ci-on-demand.tf | sed 's/#.*//')
tag_stmt=$(printf '%s\n' "$doorbell_policy" | tr '\n' ' ' | grep -Eo '\{[^{}]*local\.ci_doorbell_tag_actions[^{}]*\}' || true)
if [ -z "$tag_stmt" ]; then
  bad "the ci_doorbell policy has no statement using local.ci_doorbell_tag_actions (T-048)"
elif ! printf '%s' "$tag_stmt" | grep -Eq 'Resource[ \t]*=[ \t]*local\.ci_instance_arn[ \t]' ||
  ! printf '%s' "$tag_stmt" | grep -Eq 'Condition[ \t]*=[ \t]*local\.ci_doorbell_tag_condition'; then
  bad "the doorbell's tagging statement must use Resource = local.ci_instance_arn and Condition = local.ci_doorbell_tag_condition (T-048)"
elif printf '%s\n' "$doorbell_policy" | grep -Eq 'ec2:(\*|CreateTags|DeleteTags)'; then
  bad "the ci_doorbell policy names an ec2 tag action inline; tag grants must go through local.ci_doorbell_tag_actions (T-048)"
else
  ok "the doorbell's ec2:CreateTags is scoped to the CI instance and the CILastPush tag key (T-048)"
fi

# --- 20. The app host's SSM read is an exact list covering what it reads --
# T-005: aws_iam_role_policy.read_parameters Allows an enumerated set of
# parameter ARNs (iam.tf local app_host_ssm_parameter_names), never a
# project-wide wildcard, and every `param <path>` / `get-parameter --name`
# in the two app-host templates must be in that set -- a missed path breaks
# the next boot. Grep-based cross-check; the bff-node/domain-service
# redeploy path reads through the same cv-app.sh library.
app_policy=$(extract_block '^resource[ \t]+"aws_iam_role_policy"[ \t]+"read_parameters"[ \t]*{' <iam.tf)
allow_stmt=$(printf '%s\n' "$app_policy" | tr '\n' ' ' | grep -Eo '\{[^{}]*Effect[ \t]*=[ \t]*"Allow"[^{}]*\}' || true)
names_block=$(sed 's/#.*//' iam.tf | awk '/app_host_ssm_parameter_names[ \t]*=[ \t]*\[/ {f=1} f {print} f && /\]/ {exit}')
if [ -z "$allow_stmt" ] || [ -z "$names_block" ]; then
  bad "cannot find read_parameters' Allow statement or local.app_host_ssm_parameter_names in iam.tf (T-005)"
elif ! printf '%s' "$allow_stmt" | grep -Eq 'Resource[ \t]*=[ \t]*local\.app_host_ssm_parameter_arns[ \t]' ||
  printf '%s' "$allow_stmt" | grep -Eq '\*|GetParametersByPath'; then
  bad "read_parameters' Allow must use Resource = local.app_host_ssm_parameter_arns, with no wildcard and no GetParametersByPath (T-005)"
else
  # resource addresses in the names list -> their `name` suffix in *.tf
  covered=""
  for addr in $(printf '%s\n' "$names_block" | grep -Eo 'aws_ssm_parameter\.[a-z0-9_]+'); do
    res=${addr#aws_ssm_parameter.}
    path=$(awk -v r="$res" '$0 ~ "resource \"aws_ssm_parameter\" \""r"\"" {f=1} f && /name[ \t]*=/ {print; f=0}' *.tf | head -n1 | sed -E 's|.*\$\{var\.environment\}/||; s|".*||')
    covered="$covered $path"
  done
  needed=$(
    {
      grep -hEo '\$\(param [a-z0-9/_-]+\)' templates/domain-service-provision.sh | sed -E 's/^\$\(param //; s/\)$//'
      # T-055: cv_resolve_* reads through `cv_need <VAR> <path>`.
      grep -hEo '\bcv_need [A-Z_]+ [a-z0-9/_-]+' templates/domain-service-provision.sh | awk '{print $3}'
      grep -hEo -- '--name "/\$\{project_name\}/\$\{environment\}/[a-z0-9/_-]+"' templates/domain-service-provision.sh templates/domain-service-bootstrap.sh | sed -E 's|.*\$\{environment\}/||; s|"$||'
    } | sort -u
  )
  missing=""
  for n in $needed; do
    case " $covered " in *" $n "*) ;; *) missing="$missing $n" ;; esac
  done
  if [ -z "$needed" ]; then
    bad "found no SSM reads in the app-host templates -- the cross-check pattern is stale (T-005)"
  elif [ -n "$missing" ]; then
    bad "app-host templates read SSM parameters not in read_parameters' Allow:$missing (T-005)"
  else
    ok "read_parameters Allows an exact list (no wildcard) covering every app-host SSM read: $(echo $needed) (T-005)"
  fi
fi

# --- 21. Both instance roles Deny SSM reads outside their own set ----------
# T-005 round 1: AmazonSSMManagedInstanceCore (attached to both roles) grants
# ssm:GetParameter(s) on "*", which swallows any inline Allow. So each role
# must carry an explicit Deny + NotResource on the four read actions while
# the managed policy is attached. And every parameter the CI host's templates
# read must fall inside its NotResource set (ci/*), or the read gets
# AccessDenied.
ssm_actions_local=$(sed 's/#.*//' iam.tf | awk '/ssm_parameter_read_actions[ \t]*=[ \t]*\[/ {f=1} f {print} f && /\]/ {exit}')
actions_ok=1
for a in GetParameter GetParameters GetParametersByPath GetParameterHistory; do
  printf '%s\n' "$ssm_actions_local" | grep -Eq "\"ssm:$a\"" || actions_ok=0
done
for pair in "domain_service:read_parameters:local.app_host_ssm_parameter_arns" "drone:drone_read_ci_parameters:ci/\\*"; do
  role=${pair%%:*}
  rest=${pair#*:}
  pol=${rest%%:*}
  want=${rest#*:}
  if ! sed 's/#.*//' iam.tf | tr '\n' ' ' | grep -Eq "resource[ \t]+\"aws_iam_role_policy_attachment\"[^{]*{[^}]*aws_iam_role\.$role\.name[^}]*AmazonSSMManagedInstanceCore"; then
    bad "cannot find AmazonSSMManagedInstanceCore attached to aws_iam_role.$role -- the T-005 SSM Deny guard is stale"
    continue
  fi
  blk=$(extract_block "^resource[ \t]+\"aws_iam_role_policy\"[ \t]+\"$pol\"[ \t]*{" <iam.tf | tr '\n' ' ' | sed -E 's/\$\{[^}]*\}/X/g')
  deny=$(printf '%s\n' "$blk" | grep -Eo '\{[^{}]*Effect[ \t]*=[ \t]*"Deny"[^{}]*NotResource[^{}]*\}' || true)
  if [ -z "$deny" ] || [ "$actions_ok" = 0 ] ||
    ! printf '%s' "$deny" | grep -Eq 'Action[ \t]*=[ \t]*local\.ssm_parameter_read_actions' ||
    ! printf '%s' "$deny" | grep -Eq "NotResource[ \t]*=.*$want"; then
    bad "aws_iam_role.$role must carry a Deny + NotResource ($want) on local.ssm_parameter_read_actions (all four ssm read actions) in $pol while AmazonSSMManagedInstanceCore is attached (T-005 round 1)"
  else
    ok "aws_iam_role.$role Denies SSM parameter reads outside its NotResource set ($pol)"
  fi
done

ci_reads=$(grep -hEo -- '--name "/\$\{project_name\}/\$\{environment\}/[^"]+"' templates/drone-user-data.sh templates/jenkins-provision.sh templates/jenkins-bootstrap.sh | sed -E 's|.*\$\{environment\}/||; s|"$||')
ci_name_total=$(grep -h -A2 -- 'get-parameter' templates/drone-user-data.sh templates/jenkins-provision.sh templates/jenkins-bootstrap.sh scripts/ci-dns-updater.sh scripts/ci-dns-sentinel.sh | grep -c -- '--name')
ci_outside=""
for n in $ci_reads; do
  case "$n" in ci/*) ;; *) ci_outside="$ci_outside $n" ;; esac
done
if [ -z "$ci_reads" ] || [ "$ci_name_total" != "$(printf '%s\n' "$ci_reads" | wc -l)" ]; then
  bad "the CI-host SSM read cross-check pattern is stale: found '$ci_reads' for $ci_name_total get-parameter --name (T-005 round 1)"
elif [ -n "$ci_outside" ]; then
  bad "CI-host templates read SSM parameters outside ci/*, which drone_read_ci_parameters' Deny NotResource blocks:$ci_outside -- add their exact ARN to the NotResource list (T-005 round 1)"
else
  ok "every CI-host SSM read is inside ci/*, the NotResource set of drone_read_ci_parameters: $(echo $ci_reads) (T-005 round 1)"
fi

# --- 22. The app host role never gets logs:* or logs:CreateLogGroup (T-054) ---
# The awslogs driver only needs CreateLogStream + PutLogEvents on groups that
# Terraform already creates. Every aws_iam_role_policy attached to
# aws_iam_role.domain_service, in any .tf file, may name no other logs: action,
# and no managed CloudWatch/Logs policy may be attached to that role.
logs_bad=""
logs_seen=0
for f in *.tf; do
  blks=$(sed 's/#.*//' "$f" | awk '
    /^resource[ \t]+"aws_iam_role_policy"/ { inb = 1; buf = "" }
    inb { buf = buf " " $0 }
    inb && /^}/ { print buf; inb = 0 }')
  [ -n "$blks" ] || continue
  while IFS= read -r b; do
    printf '%s' "$b" | grep -Eq 'role[ \t]*=[ \t]*aws_iam_role\.domain_service\.' || continue
    # Actions/resources may live in named locals (plan-testable); read them too.
    for ln in $(printf '%s' "$b" | grep -Eo 'local\.app_container_logs_[a-z]+' | sed 's/local\.//' | sort -u); do
      b="$b $(sed 's/#.*//' "$f" | awk -v n="$ln" '$1 == n { inb = 1 } inb { print } inb && /\]/ { exit }' | tr '\n' ' ')"
    done
    acts=$(printf '%s' "$b" | grep -Eo '"logs:[^"]*"' || true)
    [ -n "$acts" ] && logs_seen=$((logs_seen + 1))
    for a in $acts; do
      case "$a" in
        '"logs:CreateLogStream"' | '"logs:PutLogEvents"') ;;
        *) logs_bad="$logs_bad $a($f)" ;;
      esac
    done
    if printf '%s' "$b" | grep -Eq '"(\*|logs:\*)"' && printf '%s' "$b" | grep -Eq 'logs:'; then
      logs_bad="$logs_bad wildcard-action($f)"
    fi
    # Resources: exactly the two groups' stream ARNs, referenced by address.
    if printf '%s' "$b" | grep -q 'logs:'; then
      res=$(printf '%s' "$b" | grep -Eo '"\$\{[^}]*\}[^"]*"' | grep -v '"\${var\.' || true)
      want=$(printf '%s\n' '"${aws_cloudwatch_log_group.domain_service.arn}:*"' '"${aws_cloudwatch_log_group.bff_node.arn}:*"')
      if [ "$(printf '%s\n' "$res" | sort)" != "$(printf '%s\n' "$want" | sort)" ]; then
        logs_bad="$logs_bad resources-not-the-two-group-stream-arns($f)"
      fi
    fi
  done <<<"$blks"
done
managed_logs=$(cat ./*.tf | sed 's/#.*//' | tr '\n' ' ' | grep -Eo 'resource[ \t]+"aws_iam_role_policy_attachment"[^{]*\{[^}]*\}' |
  grep -E 'aws_iam_role\.domain_service\.' | grep -E 'policy_arn[ \t]*=[^}]*(CloudWatch|Logs)' || true)
if [ -n "$managed_logs" ]; then
  logs_bad="$logs_bad managed-CloudWatch/Logs-policy-attachment"
fi
if [ -n "$logs_bad" ]; then
  bad "the app host role (aws_iam_role.domain_service) grants log actions beyond CreateLogStream/PutLogEvents (or attaches a CloudWatch/Logs managed policy):$logs_bad (T-054)"
elif [ "$logs_seen" -lt 1 ]; then
  bad "no logs: grant found on aws_iam_role.domain_service -- the T-054 awslogs policy is missing or this check is stale"
else
  ok "the app host role's only logs: actions are CreateLogStream and PutLogEvents (T-054)"
fi

# --- 23. roll() hands the rm to cv_run_*, which resolves inputs first (T-055) ---
# A failed SSM read must leave the old container serving, so roll() must not
# remove anything itself: its ONLY `docker rm` is the argument list of the
# cv_run_<svc> call (which runs it after every input is resolved), and that call
# must not be followed by `||` (a resolve failure has to propagate). Comments
# are stripped first so a comment cannot satisfy or defeat the check. The
# harness proves the behaviour; this pins the shape of the template text.
roll_body=$(awk '/^roll\(\) \{/{c=1} c{print} c&&/^\}/{exit}' templates/domain-service-provision.sh | sed 's/[[:space:]]*#.*$//')
rm_lines=$(printf '%s\n' "$roll_body" | grep -c 'docker rm' || true)
call_lines=$(printf '%s\n' "$roll_body" | grep -cE '^[[:space:]]*"cv_run_\$\$\{name//-/_\}" docker rm -f "\$name"[[:space:]]*$' || true)
if [ -z "$roll_body" ]; then
  bad "cannot find roll() in domain-service-provision.sh (T-055)"
elif [ "$rm_lines" -ne 1 ] || [ "$call_lines" -ne 1 ]; then
  bad "roll() must contain exactly one docker rm, as the arguments of its cv_run_<svc> call (\"cv_run_\$\${name//-/_}\" docker rm -f \"\$name\"), with no || after it (T-055)"
else
  ok "roll() removes the container only as cv_run_<svc>'s pre-start hook, after it resolved every input (T-055)"
fi

exit $fail
