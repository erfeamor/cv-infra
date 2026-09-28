#!/usr/bin/env bash
# T-008: two properties `terraform test` cannot check under `command = plan`,
# because both are about things that are either invisible in plan output
# (an output's `sensitive` flag never appears there) or unknown-until-apply
# (aws_iam_user_policy.drone_deploy.policy embeds S3/CloudFront ARNs) -- see
# the comments in tests/plan.tftest.hcl's "drone_deploy_credentials" run and
# bootstrap/check-static.sh, which exists for the identical class of gap.
#
# Run alongside fmt/validate/test as part of this module's offline gate.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0

# --- Check 1 (case 3): no output exposes the drone-deploy access key ------
# unless it is explicitly marked sensitive. Terraform allows an `output`
# block in ANY .tf file, not just outputs.tf -- review round 1 caught that
# this originally only scanned outputs.tf itself, which would miss one
# added to, say, a new single-concern file. Scans every *.tf in the module
# root for an output block referencing aws_iam_access_key.drone_deploy; if
# none exists anywhere, that's the expected/current state and this check
# passes trivially -- it exists to catch a FUTURE output added without
# sensitive = true, not to demand one exist today. Single self-contained
# awk pass per file, `#` comments stripped, tracking both "references the
# key resource" and "has sensitive = true" per block.
#
# Deliberately does NOT try to strip /* */ block comments: none of this
# module's .tf files use them (grep-confirmed), and a naive index()-based
# /* scan false-positives on the wildcard ARNs this codebase is full of
# (e.g. "${aws_s3_bucket.frontend.arn}/*") -- a real bug this script hit
# and fixed against itself before being committed. Do not reintroduce that
# handling without also excluding matches inside quoted strings.
unsafe_output=""
for tf_file in *.tf; do
  found_in_file=$(awk '
    function strip_comments(line,    h) {
      h = index(line, "#")
      if (h > 0) line = substr(line, 1, h - 1)
      return line
    }
    BEGIN { depth = 0; inblock = 0; refs = 0; sens = 0 }
    {
      line = strip_comments($0)
      if (!inblock) {
        if (line ~ /^output[ \t]+"[^"]+"[ \t]*{/) { inblock = 1; depth = 0; refs = 0; sens = 0; name = line }
        else next
      }
      if (line ~ /aws_iam_access_key\.drone_deploy/) refs = 1
      if (line ~ /^[ \t]*sensitive[ \t]*=[ \t]*true[ \t]*$/) sens = 1
      n = gsub(/\{/, "{", line); depth += n
      m = gsub(/\}/, "}", line); depth -= m
      if (depth == 0) {
        inblock = 0
        if (refs && !sens) { print name }
      }
    }
  ' "$tf_file")
  if [ -n "$found_in_file" ]; then
    unsafe_output="${unsafe_output}${tf_file}: ${found_in_file}
"
  fi
done

if [ -n "$unsafe_output" ]; then
  echo "FAIL: an output references aws_iam_access_key.drone_deploy without sensitive = true:" >&2
  printf '%s' "$unsafe_output" >&2
  fail=1
else
  echo "OK: no output in any *.tf file exposes aws_iam_access_key.drone_deploy (or every such output is sensitive = true)"
fi

# --- Check 2 (case 4): aws_iam_user_policy.drone_deploy is byte-identical
# (comments stripped) to the version this task shipped against -- T-008
# adds an access key, it does not touch this policy's actions/resources.
# Same "#`-only, no /* */" rationale as check 1 above -- this resource's
# body embeds wildcard ARNs too (.../*").
extract_block() {
  awk -v pat="$1" '
    BEGIN { depth = 0; found = 0 }
    {
      line = $0
      h = index(line, "#")
      if (h > 0) line = substr(line, 1, h - 1)

      if (!found) {
        if (line ~ pat) { found = 1; depth = 0 } else next
      }
      n = gsub(/\{/, "{", line); depth += n
      m = gsub(/\}/, "}", line); depth -= m
      print line
      if (depth == 0) exit
    }
  '
}

EXPECTED_POLICY_SHA256=2b3cf748ef9bce16ba6d273f59ac1dfd70e0f3818977f858613ec8f92d243845

policy_block=$(extract_block '^resource[ \t]+"aws_iam_user_policy"[ \t]+"drone_deploy"[ \t]*{' <iam.tf)

if [ -z "$policy_block" ]; then
  echo "FAIL: resource \"aws_iam_user_policy\" \"drone_deploy\" { ... } not found in iam.tf" >&2
  fail=1
else
  actual_sha256=$(printf '%s\n' "$policy_block" | sha256sum | cut -d' ' -f1)
  if [ "$actual_sha256" != "$EXPECTED_POLICY_SHA256" ]; then
    echo "FAIL: aws_iam_user_policy.drone_deploy in iam.tf has changed since T-008 pinned it (expected sha256 $EXPECTED_POLICY_SHA256, got $actual_sha256)." >&2
    echo "T-008's H1 decision was that this task adds an access key and does NOT widen this policy. If a change here is intentional, get it reviewed as its own decision and update EXPECTED_POLICY_SHA256 in this script." >&2
    fail=1
  else
    echo "OK: aws_iam_user_policy.drone_deploy is unchanged from T-008's baseline (sha256 $actual_sha256)"
  fi
fi

exit $fail
