# T-044: the app host's provisioning script lives in S3, not in user_data.
#
# user_data had reached ~14.6 KB of EC2's 16,384-byte cap. Same fix as the CI
# host's (T-009, ci-provision.tf): the real script is a private S3 object in
# aws_s3_bucket.ci_artifacts, checked against a hash in SSM, run by a tiny stub
# (templates/domain-service-bootstrap.sh).
#
# Difference from T-009, by H1 decision: the stub EMBEDS the script's SHA-256.
# A script edit therefore changes user_data and replaces the host, which is the
# app host's long-standing behavior (user_data_replace_on_change = true,
# compute.tf). What no longer needs a host replacement is a new IMAGE or a new
# MIGRATION: /usr/local/bin/cv-redeploy (written by the script) rolls those,
# see docs/runbooks/app-host-deploy.md.
#
# The stub still compares the downloaded file against the SSM parameter too,
# so a tampered S3 object is refused by two independent checks.

locals {
  # Plain strings (not object attributes) so the IAM policy and tests do not
  # inherit unknown-until-apply values.
  app_host_provision_key = "app-host/provision.sh"

  app_host_provision_script = templatefile("${path.module}/templates/domain-service-provision.sh", {
    aws_region        = var.aws_region
    project_name      = var.project_name
    environment       = var.environment
    image             = "${aws_ecr_repository.domain_service.repository_url}:latest"
    bff_image         = "${aws_ecr_repository.bff_node.repository_url}:latest"
    db_name           = var.db_name
    db_username       = var.db_username
    cloudfront_domain = aws_cloudfront_distribution.frontend.domain_name
    backup_bucket     = aws_s3_bucket.backup.bucket
    backup_prefix     = local.mysql_backup_prefix
    # T-018 ruling 2: resolved by volume ID via /dev/disk/by-id, never by
    # device name. See templates/domain-service-provision.sh.
    mysql_volume_id = aws_ebs_volume.mysql_data.id
  })

  app_host_provision_sha256 = sha256(local.app_host_provision_script)
}

resource "aws_s3_object" "app_host_provision" {
  bucket       = aws_s3_bucket.ci_artifacts.id
  key          = local.app_host_provision_key
  content      = local.app_host_provision_script
  content_type = "text/x-shellscript"
  etag         = md5(local.app_host_provision_script)

  tags = {
    Project = var.project_name
  }
}

# Under /<project>/<env>/app/. The app host role reads it through its exact
# ARN in iam.tf's app_host_ssm_parameter_names (T-005); a new parameter the
# app host reads must be added there.
resource "aws_ssm_parameter" "app_host_provision_sha256" {
  name  = "/${var.project_name}/${var.environment}/app/provision-sha256"
  type  = "String"
  value = local.app_host_provision_sha256

  tags = {
    Project = var.project_name
  }
}

# Exactly the one object -- not the bucket, not a wildcard. (The CI host's role
# has the same shape for its own key, ci-provision.tf.)
resource "aws_iam_role_policy" "app_read_provision_script" {
  name = "${var.project_name}-app-read-provision-script"
  role = aws_iam_role.domain_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.ci_artifacts.arn}/${local.app_host_provision_key}"
    }]
  })
}
