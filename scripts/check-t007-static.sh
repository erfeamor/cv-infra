#!/usr/bin/env bash
# T-007: two properties `terraform test` cannot see under `command = plan`,
# same class of gap scripts/check-t008-static.sh exists for -- see that
# script's own header and tests/plan.tftest.hcl's "t007_ci_host_hardening"
# run for the properties that ARE checkable there.
#
# Case 5: lifecycle meta-arguments (ignore_changes) never appear in plan
# output at all -- same limitation bootstrap/check-static.sh documents for
# prevent_destroy. aws_instance.drone's `ignore_changes` is what stops every
# unrelated apply from replacing this host (AMI churn) or stripping the
# hand-set CIKeepAlive tag (T-019) -- a regression here is invisible to
# fmt/validate/test alike.
#
# Case 8: aws_lambda_function.ci_doorbell/ci_reaper's INSTANCE_ID env var
# references aws_instance.drone.id -- a genuinely AWS-computed attribute,
# unknown-until-apply for a not-yet-created instance even under
# mock_provider (same documented limitation as aws_eip.drone.public_ip
# throughout tests/plan.tftest.hcl). Checked source-text-side instead.
#
# Run alongside fmt/validate/test/check-t008-static.sh as part of this
# module's offline gate (see cv-infra/CLAUDE.md).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0

# Reads HCL-ish text on stdin, strips `#` comments, and prints the first
# brace-balanced block whose opening line matches the given (already
# ^-anchored) regex. Same convention as scripts/check-t008-static.sh's
# extract_block -- no /* */ handling, this codebase doesn't use them.
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

# --- Case 5: ignore_changes on aws_instance.drone -------------------------
drone_block=$(extract_block '^resource[ \t]+"aws_instance"[ \t]+"drone"[ \t]*{' <ci.tf)

if [ -z "$drone_block" ]; then
  echo "FAIL: resource \"aws_instance\" \"drone\" { ... } not found in ci.tf" >&2
  fail=1
else
  lifecycle_block=$(printf '%s\n' "$drone_block" | extract_block '^[ \t]*lifecycle[ \t]*{')
  if [ -z "$lifecycle_block" ]; then
    echo "FAIL: aws_instance.drone has no lifecycle { ignore_changes = [...] } block -- AMI churn would replace this host and CIKeepAlive would be stripped on every apply" >&2
    fail=1
  else
    missing=""
    for entry in 'ami' 'tags\["CIKeepAlive"\]' 'tags_all\["CIKeepAlive"\]'; do
      if ! printf '%s\n' "$lifecycle_block" | grep -Eq "$entry"; then
        missing="${missing} ${entry}"
      fi
    done
    if [ -n "$missing" ]; then
      echo "FAIL: aws_instance.drone's ignore_changes is missing:$missing" >&2
      fail=1
    else
      echo "OK: aws_instance.drone's ignore_changes still covers ami, tags[\"CIKeepAlive\"], tags_all[\"CIKeepAlive\"]"
    fi
  fi
fi

# --- Case 8: doorbell/reaper INSTANCE_ID wired from aws_instance.drone.id -
missing_wiring=""
for fn in ci_doorbell ci_reaper; do
  fn_block=$(extract_block "^resource[ \t]+\"aws_lambda_function\"[ \t]+\"${fn}\"[ \t]*{" <ci-on-demand.tf)
  if [ -z "$fn_block" ]; then
    missing_wiring="${missing_wiring} aws_lambda_function.${fn}(not found)"
    continue
  fi
  if ! printf '%s\n' "$fn_block" | grep -Eq '^[ \t]*INSTANCE_ID[ \t]*=[ \t]*aws_instance\.drone\.id[ \t]*$'; then
    missing_wiring="${missing_wiring} aws_lambda_function.${fn}"
  fi
done

if [ -n "$missing_wiring" ]; then
  echo "FAIL: INSTANCE_ID is not wired from aws_instance.drone.id on:$missing_wiring" >&2
  fail=1
else
  echo "OK: both aws_lambda_function.ci_doorbell and aws_lambda_function.ci_reaper wire INSTANCE_ID from aws_instance.drone.id"
fi

exit $fail
