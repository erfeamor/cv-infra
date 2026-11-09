#!/usr/bin/env bash
# Static checks for invariants `terraform test` cannot see under
# `command = plan`: lifecycle meta-arguments, computed attributes that are
# unknown until apply, output `sensitive` flags, and the bash templates that
# boot the app host. Each check guards a property whose regression would pass
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

# --- 1b. No output exposes the BFF service client's secret (T-043) ---------
if grep -n 'client_secret' outputs.tf | grep -v '^[0-9]*:[ \t]*#' >/dev/null; then
  bad "outputs.tf references a Cognito client_secret (the BFF service secret must only reach SSM)"
else
  ok "outputs.tf never references a Cognito client_secret"
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
# Any grant of exactly ["ssm:GetParameter"] must reference a specific
# aws_ssm_parameter.<name>.arn, never a literal ARN that could be a wildcard.
# (The tree-scoped role grants and the app host's Deny are asserted in
# tests/plan.tftest.hcl.)
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

# --- 21. The app host role Denies SSM reads outside its own set -----------
# T-005 round 1: AmazonSSMManagedInstanceCore grants ssm:GetParameter(s) on
# "*", which swallows any inline Allow. So the role must carry an explicit
# Deny + NotResource on the four read actions while the managed policy is
# attached. (Section 20 checks the host's reads fall inside that set.)
ssm_actions_local=$(sed 's/#.*//' iam.tf | awk '/ssm_parameter_read_actions[ \t]*=[ \t]*\[/ {f=1} f {print} f && /\]/ {exit}')
actions_ok=1
for a in GetParameter GetParameters GetParametersByPath GetParameterHistory; do
  printf '%s\n' "$ssm_actions_local" | grep -Eq "\"ssm:$a\"" || actions_ok=0
done
for pair in "domain_service:read_parameters:local.app_host_ssm_parameter_arns"; do
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

# --- 25. The custom domain's wiring (T-061) -----------------------------------
# What plan-time tests can't see, because ARNs and validation records are
# unknown until apply: (a) the certificate and its validation use the
# us-east-1 provider (CloudFront reads certificates from nowhere else); (b) the
# distribution takes its certificate ARN from the VALIDATION resource, so it
# isn't updated before ACM has validated the names; (c) the CORS parameter
# carries both the custom domain and the cloudfront.net origin; (d) the
# provision script reads CORS from SSM and bakes no origin in; (e) the Cognito
# admin client accepts the custom domain.
strip_hash() { sed -e 's/[[:space:]]*#.*$//' "$@"; }
dom=$(strip_hash domain.tf)
fe=$(strip_hash frontend.tf)
au=$(strip_hash auth.tf)
tpl=$(strip_hash templates/domain-service-provision.sh)
t61_problems=""
for res in aws_acm_certificate.site aws_acm_certificate_validation.site; do
  type=${res%%.*}; name=${res#*.}
  region_ok=$(printf '%s\n' "$dom" | awk -v t="$type" -v n="$name" '$0 ~ "^resource \""t"\" \""n"\"" {f=1} f && /provider[ \t]*=[ \t]*aws\.us_east_1/ {print "yes"; exit} f && /^}/ {exit}')
  [ "$region_ok" = yes ] || t61_problems="$t61_problems; $res is not on provider aws.us_east_1"
done
printf '%s\n' "$fe" | grep -qE 'acm_certificate_arn[[:space:]]*=[[:space:]]*aws_acm_certificate_validation\.site\.certificate_arn' \
  || t61_problems="$t61_problems; the distribution's acm_certificate_arn must come from aws_acm_certificate_validation.site"
printf '%s\n' "$fe" | grep -qE 'aliases[[:space:]]*=[[:space:]]*\[local\.public_apex,[[:space:]]*local\.public_www\]' \
  || t61_problems="$t61_problems; the distribution's aliases must be exactly [local.public_apex, local.public_www]"
printf '%s\n' "$dom" | grep -qE 'value[[:space:]]*=[[:space:]]*"https://\$\{local\.public_apex\},https://\$\{aws_cloudfront_distribution\.frontend\.domain_name\}"' \
  || t61_problems="$t61_problems; app/cors-allowed-origins must be https://<apex>,https://<cloudfront domain>"
if printf '%s\n' "$tpl" | grep -E 'CORS_ALLOWED_ORIGINS=' | grep -qE 'https://'; then
  t61_problems="$t61_problems; the provision script bakes a CORS origin in instead of reading app/cors-allowed-origins"
fi
printf '%s\n' "$tpl" | grep -qE 'CORS_ALLOWED_ORIGINS="\$CV_DS_CORS_ORIGINS,' \
  || t61_problems="$t61_problems; domain-service's CORS_ALLOWED_ORIGINS must start from \$CV_DS_CORS_ORIGINS"
printf '%s\n' "$tpl" | grep -qE 'CORS_ALLOWED_ORIGINS="\$CV_BFF_CORS_ORIGINS"' \
  || t61_problems="$t61_problems; bff-node's CORS_ALLOWED_ORIGINS must be exactly \$CV_BFF_CORS_ORIGINS"
[ "$(printf '%s\n' "$au" | grep -cE '"https://\$\{local\.public_apex\}/admin/"')" -eq 2 ] \
  || t61_problems="$t61_problems; the admin Cognito client needs https://<apex>/admin/ as both callback and logout URL"
if [ -n "$t61_problems" ]; then
  bad "custom domain wiring (T-061):${t61_problems#;}"
else
  ok "the custom domain's certificate is us-east-1 and validated before the distribution uses it; CORS comes from SSM (T-061)"
fi

# --- 26. Cognito's custom domain (T-062) ---------------------------------------
# What plan-time tests can't see: (a) the domain takes its certificate from the
# VALIDATION resource, so Cognito never gets an unvalidated one; (b) it waits for
# the apex alias record (Cognito checks the parent domain resolves); (c) classic
# managed login (1), because version 2 needs a branding resource or the login
# page breaks; (d) the BFF token URL is built from the custom domain, not the
# prefix one; (e) the prefix domain is still declared (the admin build uses it
# until T-306); (f) auth.<apex> aliases to the distribution COGNITO creates, not
# the site's.
sdom=$(strip_hash domain.tf)
ssm=$(strip_hash ssm.tf)
t62_block=$(printf '%s\n' "$au" | awk '/^resource "aws_cognito_user_pool_domain" "custom"/ {f=1} f {print} f && /^}/ {exit}')
t62_problems=""
printf '%s\n' "$t62_block" | grep -qE 'certificate_arn[[:space:]]*=[[:space:]]*aws_acm_certificate_validation\.site\.certificate_arn' \
  || t62_problems="$t62_problems; the custom domain's certificate_arn must come from aws_acm_certificate_validation.site"
printf '%s\n' "$t62_block" | grep -qE 'site_alias\["apex-A"\]' && printf '%s\n' "$t62_block" | grep -qE 'site_alias\["apex-AAAA"\]' \
  || t62_problems="$t62_problems; the custom domain must depend on the apex alias records"
printf '%s\n' "$t62_block" | grep -qE 'managed_login_version[[:space:]]*=[[:space:]]*1([^0-9]|$)' \
  || t62_problems="$t62_problems; the custom domain must pin managed_login_version = 1"
printf '%s\n' "$ssm" | grep -qE 'value[[:space:]]*=[[:space:]]*"https://\$\{aws_cognito_user_pool_domain\.custom\.domain\}/oauth2/token"' \
  || t62_problems="$t62_problems; bff/token-url must be built from aws_cognito_user_pool_domain.custom"
ssm_token_block=$(printf '%s\n' "$ssm" | awk '/^resource "aws_ssm_parameter" "bff_token_url"/ {f=1} f {print} f && /^}/ {exit}')
printf '%s\n' "$ssm_token_block" | grep -qE 'depends_on[[:space:]]*=[[:space:]]*\[aws_route53_record\.auth_alias\]' \
  || t62_problems="$t62_problems; bff/token-url must wait for the auth.<apex> alias record"
printf '%s\n' "$au" | grep -qE '^resource "aws_cognito_user_pool_domain" "cv"' \
  || t62_problems="$t62_problems; the prefix domain must stay declared until T-306"
auth_alias=$(printf '%s\n' "$sdom" | awk '/^resource "aws_route53_record" "auth_alias"/ {f=1} f {print} f && /^}/ {exit}')
printf '%s\n' "$auth_alias" | grep -qE 'name[[:space:]]*=[[:space:]]*aws_cognito_user_pool_domain\.custom\.cloudfront_distribution$' \
  || t62_problems="$t62_problems; auth.<apex> must alias to the distribution Cognito creates (cloudfront_distribution)"
printf '%s\n' "$auth_alias" | grep -qE 'zone_id[[:space:]]*=[[:space:]]*aws_cognito_user_pool_domain\.custom\.cloudfront_distribution_zone_id' \
  || t62_problems="$t62_problems; auth.<apex>'s alias zone_id must be Cognito's cloudfront_distribution_zone_id"
if [ -n "$t62_problems" ]; then
  bad "Cognito custom domain wiring (T-062):${t62_problems#;}"
else
  ok "Cognito's custom domain uses the validated certificate and the apex alias, pins managed login 1, and feeds the BFF token URL (T-062)"
fi

# --- 27. The MySQL volume swap (T-066) ------------------------------------------
# What plan-time tests can't see: (a) the old 8 GiB volume is FORGOTTEN
# (removed {destroy = false}), never destroyed -- losing that block turns the
# swap into the destruction of the only copy until the restore is verified;
# (b) the new volume keeps prevent_destroy, takes its size from the variable and
# is the one the attachment and the provision script use; (c) nothing still
# declares the old volume as a managed resource (it would fight the removed
# block); (d) the mysql container expires binlogs, because 2 GiB is small.
stor=$(strip_hash storage.tf)
aph=$(strip_hash app-host-provision.tf)
t66_problems=""
removed_block=$(printf '%s\n' "$stor" | awk '/^removed \{/ {f=1} f {print} f && /^}/ {exit}')
printf '%s\n' "$removed_block" | grep -qE 'from[[:space:]]*=[[:space:]]*aws_ebs_volume\.mysql_data$' \
  || t66_problems="$t66_problems; storage.tf needs a removed block for aws_ebs_volume.mysql_data"
printf '%s\n' "$removed_block" | grep -qE 'destroy[[:space:]]*=[[:space:]]*false' \
  || t66_problems="$t66_problems; the removed block must set destroy = false (forget the old volume, never destroy it)"
if printf '%s\n' "$stor" | grep -qE '^resource "aws_ebs_volume" "mysql_data"'; then
  t66_problems="$t66_problems; aws_ebs_volume.mysql_data is declared again beside its removed block"
fi
v2_block=$(printf '%s\n' "$stor" | awk '/^resource "aws_ebs_volume" "mysql_data_v2"/ {f=1} f {print} f && /^}/ {exit}')
printf '%s\n' "$v2_block" | grep -qE 'prevent_destroy[[:space:]]*=[[:space:]]*true' \
  || t66_problems="$t66_problems; mysql_data_v2 must keep prevent_destroy = true"
printf '%s\n' "$v2_block" | grep -qE 'size[[:space:]]*=[[:space:]]*var\.mysql_volume_size_gb' \
  || t66_problems="$t66_problems; mysql_data_v2's size must come from var.mysql_volume_size_gb"
printf '%s\n' "$stor" | grep -qE 'volume_id[[:space:]]*=[[:space:]]*aws_ebs_volume\.mysql_data_v2\.id' \
  || t66_problems="$t66_problems; the attachment must use aws_ebs_volume.mysql_data_v2"
printf '%s\n' "$aph" | grep -qE 'mysql_volume_id[[:space:]]*=[[:space:]]*aws_ebs_volume\.mysql_data_v2\.id' \
  || t66_problems="$t66_problems; the provision script must be given aws_ebs_volume.mysql_data_v2's id"
printf '%s\n' "$tpl" | grep -qE -- '--binlog-expire-logs-seconds=[0-9]+' \
  || t66_problems="$t66_problems; the mysql container must set --binlog-expire-logs-seconds (the volume is 2 GiB)"
if [ -n "$t66_problems" ]; then
  bad "MySQL volume swap (T-066):${t66_problems#;}"
else
  ok "the old MySQL volume is forgotten, not destroyed; the 2 GiB volume is protected and wired; binlogs expire (T-066)"
fi

# --- 28. Migration SQL through S3 (T-070) -----------------------------------
# The app host reads one key; the cv-database role writes that same key. Both
# policies name the key through local.migration_sql_key (never a prefix wildcard
# or s3:*), and each is attached to the right role.
t70_problems=""
iam_src=$(strip_hash iam.tf)
cid_src=$(strip_hash ci-deploy.tf)
rd_block=$(printf '%s\n' "$iam_src" | awk '/^resource "aws_iam_role_policy" "app_read_migration_sql"/ {f=1} f {print} f && /^}/ {exit}')
wr_block=$(printf '%s\n' "$cid_src" | awk '/^resource "aws_iam_role_policy" "database_migrate_publish_sql"/ {f=1} f {print} f && /^}/ {exit}')
printf '%s\n' "$rd_block" | grep -qE 'role[[:space:]]*=[[:space:]]*aws_iam_role\.domain_service\.id' \
  || t70_problems="$t70_problems; app_read_migration_sql must attach to the app host role"
printf '%s\n' "$rd_block" | grep -qE 'Resource[[:space:]]*=[[:space:]]*"\$\{aws_s3_bucket\.backup\.arn\}/\$\{local\.migration_sql_key\}"' \
  || t70_problems="$t70_problems; the app host's GetObject must name local.migration_sql_key exactly"
printf '%s\n' "$wr_block" | grep -qE 'role[[:space:]]*=[[:space:]]*aws_iam_role\.database_migrate\.id' \
  || t70_problems="$t70_problems; database_migrate_publish_sql must attach to the cv-database role"
printf '%s\n' "$wr_block" | grep -qE 'Resource[[:space:]]*=[[:space:]]*"\$\{aws_s3_bucket\.backup\.arn\}/\$\{local\.migration_sql_key\}"' \
  || t70_problems="$t70_problems; the cv-database role's PutObject must name local.migration_sql_key exactly"
if printf '%s\n%s\n' "$rd_block" "$wr_block" | grep -qE 's3:\*|"\*"|/\*"'; then
  t70_problems="$t70_problems; no s3:* and no wildcard resources in the migration SQL grants"
fi
if [ -n "$t70_problems" ]; then
  bad "migration SQL through S3 (T-070):${t70_problems#;}"
else
  ok "the migration SQL is one S3 key: read by the app host, written by the cv-database role, no wildcards (T-070)"
fi
# --- 29. The app host is private (T-068) -----------------------------------
# No EIP and no public IPv4; the only ingress is a standalone rule per port from
# CloudFront's managed VPC-origin group; the shared groups have no inline
# ingress; origins are VPC origins; the host script has no git fallback and
# carries the dual-stack settings. Also the public-vanilla OIDC policy contents
# that run "github_oidc_public_vanilla_deploy" used to assert (apply-only).
t68_problems=""
net_src=$(strip_hash network.tf)
cmp_src=$(strip_hash compute.tf)
fe_src=$(strip_hash frontend.tf)
oidc_src=$(strip_hash github-oidc.tf)
prov_src=$(strip_hash templates/domain-service-provision.sh)
if grep -rqE '^[[:space:]]*resource[[:space:]]+"aws_eip(_association)?"[[:space:]]+"domain_service"' --include='*.tf' .; then
  t68_problems="$t68_problems; aws_eip/aws_eip_association domain_service must stay gone"
fi
printf '%s\n' "$cmp_src" | grep -qE 'associate_public_ip_address[[:space:]]*=[[:space:]]*false' \
  || t68_problems="$t68_problems; the app host must set associate_public_ip_address = false"
for sg in domain_service bff_node; do
  sg_block=$(printf '%s\n' "$net_src" | awk -v n="$sg" '$0 ~ "^resource \"aws_security_group\" \""n"\"" {f=1} f {print} f && /^}/ {exit}')
  if printf '%s\n' "$sg_block" | grep -qE '^[[:space:]]*ingress[[:space:]]*\{'; then
    t68_problems="$t68_problems; aws_security_group.$sg must have no inline ingress (a cycle, and it hides rules from Terraform)"
  fi
  if ! printf '%s\n' "$sg_block" | grep -qE 'ipv6_cidr_blocks[[:space:]]*=[[:space:]]*\["::/0"\]'; then
    t68_problems="$t68_problems; aws_security_group.$sg needs IPv6 egress"
  fi
done
for r in domain_service_api bff_node; do
  r_block=$(printf '%s\n' "$net_src" | awk -v n="$r" '$0 ~ "^resource \"aws_vpc_security_group_ingress_rule\" \""n"\"" {f=1} f {print} f && /^}/ {exit}')
  printf '%s\n' "$r_block" | grep -qE 'referenced_security_group_id[[:space:]]*=[[:space:]]*data\.aws_security_group\.cloudfront_vpc_origins\.id' \
    || t68_problems="$t68_problems; ingress rule $r must take the CloudFront VPC-origin group as its only source"
  if printf '%s\n' "$r_block" | grep -qE 'cidr_ipv[46]|prefix_list_id'; then
    t68_problems="$t68_problems; ingress rule $r must not carry a CIDR or prefix list"
  fi
done
if printf '%s\n' "$net_src" | grep -qE 'aws_ec2_managed_prefix_list'; then
  t68_problems="$t68_problems; the CloudFront prefix list must no longer be used"
fi
printf '%s\n' "$net_src" | grep -qE 'name[[:space:]]*=[[:space:]]*"CloudFront-VPCOrigins-Service-SG"' \
  || t68_problems="$t68_problems; the managed group must be looked up by its exact name"
if printf '%s\n' "$fe_src" | grep -qE 'custom_origin_config|aws_eip'; then
  t68_problems="$t68_problems; frontend.tf origins must be VPC origins (no custom_origin_config)"
fi
if [ "$(printf '%s\n' "$fe_src" | grep -cE '^[[:space:]]*vpc_origin_config[[:space:]]*\{')" -ne 2 ]; then
  t68_problems="$t68_problems; exactly two vpc_origin_config blocks expected (domain service, BFF)"
fi
if printf '%s\n' "$prov_src" | grep -qE 'git (clone|-C)|github\.com'; then
  t68_problems="$t68_problems; the host script must not reach github.com (no IPv6)"
fi
printf '%s\n' "$prov_src" | grep -qF '{"Agent":{"UseDualStackEndpoint":true}}' \
  || t68_problems="$t68_problems; the SSM agent dual-stack config is missing"
if [ "$(printf '%s\n' "$prov_src" | grep -cF 'awslogs-endpoint="https://logs.')" -ne 2 ]; then
  t68_problems="$t68_problems; both containers need the dual-stack awslogs-endpoint"
fi
if [ "$(printf '%s\n' "$prov_src" | grep -cF 'export AWS_USE_DUALSTACK_ENDPOINT=true')" -lt 3 ]; then
  t68_problems="$t68_problems; AWS_USE_DUALSTACK_ENDPOINT=true must be exported in the script, cv-app.sh and the backup script"
fi
# Containers need IPv6 egress too (found live after the first apply): Docker
# IPv6 + NAT66, accept_ra=2 so IPv6 forwarding does not drop the host's only
# default route, the cv network created with an IPv6 subnet, and the JVM
# preferring IPv6 (it tries IPv4 first, a blackhole here).
for needle in \
  '"ipv6": true' '"ip6tables": true' 'net.ipv6.conf.all.accept_ra = 2' \
  'docker network create --ipv6 --subnet' \
  '-e JAVA_TOOL_OPTIONS=-Djava.net.preferIPv6Addresses=true'; do
  printf '%s\n' "$prov_src" | grep -qF -- "$needle" || t68_problems="$t68_problems; the host script lost container IPv6 egress: $needle"
done
# The public-vanilla OIDC policy (T-045), moved here from the apply-only run.
for needle in \
  'Action   = ["s3:ListBucket"]' \
  'Action   = ["s3:PutObject", "s3:DeleteObject"]' \
  'Action   = ["cloudfront:CreateInvalidation"]' \
  'Resource = aws_cloudfront_distribution.frontend.arn' \
  'Resource = "${aws_s3_bucket.frontend.arn}/admin/*"' \
  'Resource = "${aws_s3_bucket.frontend.arn}/*"'; do
  printf '%s\n' "$oidc_src" | grep -qF "$needle" || t68_problems="$t68_problems; github-oidc.tf lost: $needle"
done
if [ -n "$t68_problems" ]; then
  bad "private app host (T-068):${t68_problems#;}"
else
  ok "the app host is private: no EIP, no public IPv4, ingress only from CloudFront's VPC-origin group, VPC origins, dual-stack config, no git (T-068)"
fi

# --- 31. VPC origins are replaced create-before-destroy with the host (T-068) --
# AWS rejects updating/deleting a VPC origin that a distribution uses (409), so
# a host replacement must replace the origins, new one first.
vo_problems=""
for r in domain_service_api bff_node; do
  blk=$(awk -v r="$r" '$0 ~ "^resource \"aws_cloudfront_vpc_origin\" \""r"\"" {f=1} f{print} f&&/^}/{exit}' frontend.tf)
  printf '%s\n' "$blk" | grep -qF 'create_before_destroy = true' || vo_problems="$vo_problems; $r lacks create_before_destroy"
  printf '%s\n' "$blk" | grep -qF 'replace_triggered_by  = [aws_instance.domain_service.id]' || vo_problems="$vo_problems; $r lacks replace_triggered_by the instance"
  printf '%s\n' "$blk" | grep -qF '${substr(aws_instance.domain_service.id, 2, 8)}' || vo_problems="$vo_problems; $r name must change with the instance (old and new coexist)"
done
if [ -n "$vo_problems" ]; then
  bad "VPC origins (T-068):${vo_problems#;}"
else
  ok "both VPC origins are replaced create-before-destroy with the host, under a new name"
fi

# --- 32. The cv-admin-react OIDC deploy role writes admin/* only (T-063) -------
# The role shares the frontend bucket with the public site, so its policy must
# stay confined to the admin/ prefix: Put/Delete only on ".../admin/*", no
# bucket-wide object resource, no GetObject, ListBucket carrying the s3:prefix
# condition, CreateInvalidation on the distribution ARN only, exact trust.
adm_policy=$(extract_block '^resource[ \t]+"aws_iam_role_policy"[ \t]+"admin_deploy"[ \t]*{' <github-oidc.tf)
adm_role=$(extract_block '^resource[ \t]+"aws_iam_role"[ \t]+"admin_deploy"[ \t]*{' <github-oidc.tf)
if [ -z "$adm_policy" ] || [ -z "$adm_role" ]; then
  bad 'aws_iam_role/aws_iam_role_policy "admin_deploy" not found in github-oidc.tf'
else
  problems=""
  grep -qE 'StringEquals' <<<"$adm_role" || problems="$problems trust-not-StringEquals"
  grep -qE 'StringLike|ForAnyValue|ForAllValues|\*' <<<"$adm_role" && problems="$problems trust-uses-pattern-or-wildcard"
  grep -qF 'token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"' <<<"$adm_role" || problems="$problems no-aud"
  grep -qF 'token.actions.githubusercontent.com:sub" = local.github_admin_react_sub' <<<"$adm_role" || problems="$problems sub-not-admin-local"
  grep -qE 'github_admin_react_sub[ \t]*=[ \t]*"repo:\$\{local\.github_org\}/cv-admin-react:ref:refs/heads/master"' github-oidc.tf || problems="$problems admin-sub-not-master"
  grep -qF 'Action   = ["s3:PutObject", "s3:DeleteObject"]' <<<"$adm_policy" || problems="$problems put-delete-actions"
  grep -qF 'Resource = "${aws_s3_bucket.frontend.arn}/admin/*"' <<<"$adm_policy" || problems="$problems no-admin-prefix-resource"
  grep -qE '\.arn\}/\*"' <<<"$adm_policy" && problems="$problems bucket-wide-object-resource"
  grep -qE 'GetObject|s3:\*|"\*"|NotAction|NotResource|Deny|Put[A-Za-z]*(Acl|Policy)|iam:|PassRole' <<<"$adm_policy" && problems="$problems getobject-or-wildcard"
  grep -qF '"s3:prefix"' <<<"$adm_policy" || problems="$problems listbucket-no-prefix-condition"
  grep -qF 'StringLike' <<<"$adm_policy" || problems="$problems listbucket-no-StringLike"
  grep -qF '["admin/*", "admin/"]' <<<"$adm_policy" || problems="$problems prefix-values"
  grep -qF 'Resource = aws_s3_bucket.frontend.arn' <<<"$adm_policy" || problems="$problems listbucket-resource"
  grep -qF 'Action   = ["cloudfront:CreateInvalidation"]' <<<"$adm_policy" || problems="$problems no-CreateInvalidation"
  grep -qF 'Resource = aws_cloudfront_distribution.frontend.arn' <<<"$adm_policy" || problems="$problems invalidation-not-distribution-arn"
  [ "$(grep -cE '^[ \t]*Effect[ \t]*=' <<<"$adm_policy")" = 3 ] || problems="$problems not-exactly-3-statements"
  # nothing else may attach to the role besides its one inline policy
  for tf_file in *.tf; do
    awk -v me="$tf_file" '
      /^resource[ \t]+"aws_iam_(role_policy_attachment|policy_attachment|role_policy)"/ { n=$3; f=1 }
      f && /aws_iam_role\.admin_deploy|-admin-deploy/ && !(me=="github-oidc.tf" && n=="\"admin_deploy\"") { print "x" }
      /^}/ { f=0 }' "$tf_file" | grep -q x && problems="$problems extra-policy-or-attachment-on-admin_deploy-in-$tf_file"
  done
  if [ -z "$problems" ]; then
    ok "the admin deploy role writes admin/* only (no GetObject, no bucket-wide object resource), lists with the s3:prefix condition, invalidates this distribution, and has an exact master-only StringEquals trust (T-063)"
  else
    bad "github-oidc.tf admin_deploy:$problems"
  fi
fi

exit $fail
