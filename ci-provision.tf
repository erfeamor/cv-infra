# T-009: stage the Jenkins provisioning script in S3 instead of user_data.
#
# EC2 caps user_data at 16,384 bytes. drone-user-data.sh + jenkins-provision.sh
# rendered to 16,104 (98.3%) and had grown 85.6% -> 91.1% -> 94.4% -> 95.7% ->
# 98.3% across successive tasks, with explanatory comments deleted three times
# purely to fit. Moving the Jenkins half here takes user_data to roughly 3 KB
# (~19%), which buys years of headroom rather than bytes.
#
# The failure this prevents is not "it stops fitting": exceeding the limit is
# invisible to fmt, validate and a mocked plan, and surfaces as an apply-time
# API rejection in the middle of modifying the live CI host.
#
# HOW THE BOOT PATH WORKS, and why it is shaped this way (this rationale lives
# here rather than in templates/jenkins-bootstrap.sh because that file counts
# against the 16 KB budget and this one does not -- moving prose to where it is
# free is not the same as deleting it to buy bytes, which is the toll T-009
# exists to stop paying):
#
#   user_data = drone-user-data.sh + jenkins-bootstrap.sh
#   jenkins-bootstrap.sh: aws s3 cp -> compare SHA-256 against SSM -> execute
#
# The expected checksum is in SSM rather than baked into the stub, and that is
# the load-bearing choice. Had it been inlined, every edit to
# jenkins-provision.sh would change user_data -- and a user_data change
# stop/modify/starts this instance. That is the SECOND cost T-009 names, and
# where T-002's repeated ~90s Drone outages came from. Read from SSM, the stub
# is byte-stable across script edits and the box stops cycling for provisioning
# tweaks.
#
# The re-provision signal is not lost with it: null_resource.jenkins_provision
# (ci.tf) still triggers on sha256(local.jenkins_provision_script), so editing
# the script still pushes it to the live box over SSM Run Command. What changed
# is only that the INSTANCE no longer reboots to learn about it.
#
# Failure is loud by construction: any of the three steps failing aborts under
# `set -euo pipefail` with a message on stderr and in the journal, and the box
# comes up with no Jenkins rather than with a silently stale one. A checksum
# mismatch specifically refuses to execute.
#
# Deliberately NOT reusing an existing bucket: aws_s3_bucket.frontend is served
# to the internet through CloudFront/OAC, and staging an executable there would
# publish it. aws_s3_bucket.backup is private but holds database dumps under a
# 7-day expiry lifecycle; mixing a build artifact into it would put the script
# on a deletion schedule meant for something else.

locals {
  # A plain string rather than a reference to the object, so that the IAM
  # policy and user_data below do not inherit the object's unknown-until-apply
  # status -- local.jenkins_provision_script embeds aws_eip.drone.public_ip, so
  # anything derived from the object cannot be asserted under `command = plan`.
  jenkins_provision_key = "jenkins-provision.sh"

  # Named so `terraform test` can assert on it: the rendered policy document
  # interpolates the bucket ARN, which is computed and therefore unknown under
  # mock_provider. Same reason the doorbell's EC2 actions are lifted into
  # locals in ci-on-demand.tf.
  drone_provision_s3_actions = ["s3:GetObject"]
}

resource "aws_s3_bucket" "ci_artifacts" {
  bucket        = "${var.project_name}-ci-artifacts-${var.environment}"
  force_destroy = true

  tags = {
    Name    = "${var.project_name}-ci-artifacts"
    Project = var.project_name
  }
}

# Explicit, not inherited. This bucket holds a script that is executed as root
# on a host mounting the docker socket; public read would be a direct path to
# tampering with what that host runs.
resource "aws_s3_bucket_public_access_block" "ci_artifacts" {
  bucket                  = aws_s3_bucket.ci_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ci_artifacts" {
  bucket = aws_s3_bucket.ci_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning earns its keep here: if a bad provisioning script is uploaded and
# a box boots against it, the previous object is still retrievable. Costs
# nothing at this size.
resource "aws_s3_bucket_versioning" "ci_artifacts" {
  bucket = aws_s3_bucket.ci_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "jenkins_provision" {
  bucket = aws_s3_bucket.ci_artifacts.id
  key    = local.jenkins_provision_key

  # The SAME rendered string the SSM path pushes (ci.tf). One source of truth:
  # the two delivery paths must never drift, which is the invariant T-002's
  # header comment is careful about.
  content      = local.jenkins_provision_script
  content_type = "text/x-shellscript"

  # Without this the object updates in place but nothing records that the
  # content changed in a way the boot path can detect.
  etag = md5(local.jenkins_provision_script)

  tags = {
    Project = var.project_name
  }
}

# The integrity half of the fetch-and-execute path. Lives in SSM rather than in
# user_data on purpose -- see the header of templates/jenkins-bootstrap.sh: a
# checksum baked into user_data would stop/start this instance on every
# provisioning tweak, which is the outage T-009 exists to remove alongside the
# size wall.
#
# Under /ci/ so the drone instance role's EXISTING parameter grant covers it
# (iam.tf, drone_read_ci_parameters) -- no new SSM permission is introduced.
resource "aws_ssm_parameter" "jenkins_provision_sha256" {
  name  = "/${var.project_name}/${var.environment}/ci/jenkins-provision-sha256"
  type  = "String"
  value = sha256(local.jenkins_provision_script)

  tags = {
    Project = var.project_name
  }
}

# Scoped to the single object, not the bucket and not s3:*.
#
# This widens the CI host's instance role, which is the opposite of what T-005
# is trying to do -- so, explicitly: the two are compatible. T-005's control is
# metadata_options { http_put_response_hop_limit = 1 }, which stops CONTAINERS
# reaching IMDS and therefore the role. This grant is used by the host-side
# bootstrap before any container exists, exactly like the existing param()
# helper in drone-user-data.sh. A container still cannot use it once T-005
# lands.
resource "aws_iam_role_policy" "drone_read_provision_script" {
  name = "${var.project_name}-drone-read-provision-script"
  role = aws_iam_role.drone.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = local.drone_provision_s3_actions
      Resource = "${aws_s3_bucket.ci_artifacts.arn}/${local.jenkins_provision_key}"
    }]
  })
}
