#!/bin/bash
# T-044: the app host's user_data. Fetches the real provisioning script from
# the private ci_artifacts bucket, verifies its SHA-256, and runs it. Rationale
# in app-host-provision.tf (kept there: this file is user_data, budget 2 KB).
#
# The hash below is embedded ON PURPOSE: a script change changes user_data and
# therefore replaces the host (user_data_replace_on_change). Expected script SHA-256:
# ${provision_sha256}
set -euo pipefail

fail() {
  echo "domain-service-bootstrap: $*" >&2
  logger -t domain-service-bootstrap "FAILED: $*"
  exit 1
}

script=/root/domain-service-provision.sh

aws s3 cp "s3://${artifact_bucket}/${artifact_key}" "$script" --region "${aws_region}" \
  || fail "could not download s3://${artifact_bucket}/${artifact_key}"

ssm_sha=$(aws ssm get-parameter --region "${aws_region}" \
  --name "/${project_name}/${environment}/app/provision-sha256" \
  --query Parameter.Value --output text) \
  || fail "could not read the expected checksum from SSM"

actual=$(sha256sum "$script" | awk '{print $1}')

[ "$actual" = "${provision_sha256}" ] || fail "checksum mismatch vs the embedded hash (expected ${provision_sha256}, got $actual) -- refusing to execute"
[ "$actual" = "$ssm_sha" ] || fail "checksum mismatch vs SSM (expected $ssm_sha, got $actual) -- refusing to execute"

chmod 700 "$script"
exec bash "$script"
