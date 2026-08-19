
# T-009: fetch jenkins-provision.sh from S3 and run it. All that remains of the
# Jenkins half inside user_data. Full rationale in ci-provision.tf -- kept there
# rather than here because THIS file has a 16 KB budget and that one does not.
#
# The checksum check is not a formality: this executes a script fetched at boot
# as root, on a host that mounts the docker socket. Do not reorder it after the
# execution, and do not downgrade it to a warning.

set -euo pipefail

bootstrap_fail() {
  echo "jenkins-bootstrap: $*" >&2
  logger -t jenkins-bootstrap "FAILED: $*"
  exit 1
}

provision_script=/root/jenkins-provision.sh

aws s3 cp "s3://${artifact_bucket}/${artifact_key}" "$provision_script" \
  --region "${aws_region}" \
  || bootstrap_fail "could not download s3://${artifact_bucket}/${artifact_key}"

expected_sha=$(aws ssm get-parameter --region "${aws_region}" \
  --name "/${project_name}/${environment}/ci/jenkins-provision-sha256" \
  --query Parameter.Value --output text) \
  || bootstrap_fail "could not read the expected checksum from SSM"

actual_sha=$(sha256sum "$provision_script" | awk '{print $1}')

if [ "$actual_sha" != "$expected_sha" ]; then
  bootstrap_fail "checksum mismatch (expected $expected_sha, got $actual_sha) -- refusing to execute"
fi

chmod 700 "$provision_script"
bash "$provision_script"
