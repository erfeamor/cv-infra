#!/usr/bin/env bash
# T-007: properties `terraform test` cannot see under `command = plan`,
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
# Check C (review round 1, finding 8): the two independent
# `docker run ... drone/drone:...` invocations (templates/drone-user-data.sh's
# first boot, templates/jenkins-provision.sh's :80-remediation path) must
# both carry -e DRONE_DATABASE_SECRET -- these two copies already drifted
# once (that remediation block exists because of a drift between them), so
# this is checked directly rather than trusted to stay in sync.
#
# Check D (review round 2, BLOCKER): `cloud-init status --wait` must live
# ONLY in ci.tf's null_resource.jenkins_provision SSM command, never inside
# templates/jenkins-provision.sh itself -- that script also runs INSIDE
# cloud-init on the user_data path, so a wait embedded in it deadlocks.
#
# Run alongside fmt/validate/test/check-t008-static.sh as part of this
# module's offline gate (see cv-infra/CLAUDE.md).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=lib/extract-block.sh
source scripts/lib/extract-block.sh

fail=0

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
    # Review round 1, finding 10: match list ELEMENTS, not substrings -- a
    # bare `grep -Eq "ami"` would also "pass" against an unrelated word that
    # merely contains "ami" (e.g. a future "primary" or "estimate" entry),
    # proving nothing about the actual list contents. Join the block to one
    # line, isolate the `[...]` list body, split on commas, and trim.
    joined=$(printf '%s' "$lifecycle_block" | tr '\n' ' ')
    list_content=$(printf '%s' "$joined" | sed -n 's/.*ignore_changes[ \t]*=[ \t]*\[\(.*\)\].*/\1/p')
    if [ -z "$list_content" ]; then
      echo "FAIL: could not find an ignore_changes = [ ... ] list inside aws_instance.drone's lifecycle block" >&2
      fail=1
    else
      IFS=',' read -ra raw_elements <<<"$list_content"
      elements=()
      for raw in "${raw_elements[@]}"; do
        trimmed=$(printf '%s' "$raw" | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//')
        elements+=("$trimmed")
      done
      missing=""
      for entry in 'ami' 'tags["CIKeepAlive"]' 'tags_all["CIKeepAlive"]'; do
        found=0
        for el in "${elements[@]}"; do
          if [ "$el" = "$entry" ]; then
            found=1
            break
          fi
        done
        if [ "$found" -eq 0 ]; then
          missing="${missing} ${entry}"
        fi
      done
      if [ -n "$missing" ]; then
        echo "FAIL: aws_instance.drone's ignore_changes is missing (as an exact list element, not a substring):$missing" >&2
        fail=1
      else
        echo "OK: aws_instance.drone's ignore_changes still covers ami, tags[\"CIKeepAlive\"], tags_all[\"CIKeepAlive\"] (as exact list elements)"
      fi
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

# --- Check C: every `docker run ... drone/drone:...` passes
# -e DRONE_DATABASE_SECRET, in EITHER template that defines one. -----------
drone_run_violations=""
for tf_file in templates/drone-user-data.sh templates/jenkins-provision.sh; do
  violation=$(awk '
    BEGIN { collecting = 0; has_secret = 0; is_drone_run = 0 }
    {
      line = $0
      if (!collecting) {
        if (line ~ /^[ \t]*docker run /) {
          collecting = 1
          has_secret = (line ~ /-e DRONE_DATABASE_SECRET=/) ? 1 : 0
          is_drone_run = (line ~ /drone\/drone:/) ? 1 : 0
        }
        next
      }
      if (line ~ /-e DRONE_DATABASE_SECRET=/) has_secret = 1
      if (line ~ /drone\/drone:/) is_drone_run = 1
      if (line !~ /\\[ \t]*$/) {
        if (is_drone_run && !has_secret) print "VIOLATION"
        collecting = 0; has_secret = 0; is_drone_run = 0
      }
    }
  ' "$tf_file")
  if [ -n "$violation" ]; then
    drone_run_violations="${drone_run_violations}${tf_file} "
  fi
done

if [ -n "$drone_run_violations" ]; then
  echo "FAIL: a 'docker run ... drone/drone:...' invocation is missing -e DRONE_DATABASE_SECRET in: $drone_run_violations" >&2
  fail=1
else
  echo "OK: every 'docker run ... drone/drone:...' invocation (drone-user-data.sh, jenkins-provision.sh) passes -e DRONE_DATABASE_SECRET"
fi

# --- Check D (review round 2, BLOCKER): `cloud-init status --wait` must
# NEVER appear inside templates/jenkins-provision.sh -- that script also
# runs INSIDE cloud-init on the user_data path
# (templates/jenkins-bootstrap.sh's `bash "$provision_script"`), so a wait
# embedded in it deadlocks (it would be waiting for the very cloud-init run
# it is a part of). The wait belongs only in ci.tf's
# null_resource.jenkins_provision, as a command that runs BEFORE the
# script's own content over SSM -- a path that is never itself inside
# cloud-init. Checked both ways: absent from the shared script, present in
# the SSM command path.
if grep -q "cloud-init status --wait" templates/jenkins-provision.sh; then
  echo "FAIL: templates/jenkins-provision.sh calls 'cloud-init status --wait' -- this deadlocks on the user_data path, where this script runs INSIDE cloud-init (see ci.tf's null_resource.jenkins_provision for where the wait belongs instead)" >&2
  fail=1
else
  echo "OK: templates/jenkins-provision.sh does not call 'cloud-init status --wait' (would deadlock on the user_data path)"
fi

if grep -q "cloud-init status --wait" ci.tf; then
  echo "OK: ci.tf still runs 'cloud-init status --wait' (in null_resource.jenkins_provision's SSM command, ahead of the script's own content)"
else
  echo "FAIL: ci.tf no longer runs 'cloud-init status --wait' anywhere -- the fresh-replace race with drone-user-data.sh's Docker install (T-007 review round 1, finding 5) is unguarded again" >&2
  fail=1
fi

exit $fail
