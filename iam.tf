resource "aws_iam_role" "domain_service" {
  name = "${var.project_name}-domain-service"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

# Session Manager access — replaces SSH (no port 22, no key distribution).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.domain_service.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Boot script pulls the cv-domain-service image from ECR.
resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.domain_service.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Lets the app host read exactly the SSM parameters its scripts read (T-005).
#
# The Allow is an enumerated list of full parameter ARNs, no wildcard: this
# role used to read the whole `/${var.project_name}/*` tree, including every
# `ci/*` secret and `deploy/*`, though it needs a handful of paths. The set is
# what templates/domain-service-bootstrap.sh (app/provision-sha256),
# domain-service-provision.sh and the /usr/local/lib/cv-app.sh library it
# writes (param(): db/password, cognito/issuer-uri, bff/*), and the backup
# script (db/password) read. Nothing reads by path, so GetParametersByPath is
# gone. scripts/check-static.sh cross-checks the templates against this list:
# a new `param x` / `get-parameter --name` there needs its parameter added
# here, or the next boot fails.
#
# The explicit Deny on `deploy/*` (T-008) stays as defense in depth; IAM
# evaluates an explicit Deny before any Allow.
#
# AmazonSSMManagedInstanceCore (attached above, needed for Session Manager and
# Run Command) itself grants ssm:GetParameter(s) on "*", so the Allow above
# narrows nothing on its own. The Deny + NotResource below is what actually
# limits the role: every read of a parameter outside the list is denied
# (T-005 round 1). Do not detach the managed policy; the agent needs its
# other actions.
locals {
  app_host_ssm_parameter_names = [
    aws_ssm_parameter.app_host_provision_sha256.name,
    aws_ssm_parameter.db_password.name,
    aws_ssm_parameter.cognito_issuer_uri.name,
    aws_ssm_parameter.bff_service_client_id.name,
    aws_ssm_parameter.bff_service_client_secret.name,
    aws_ssm_parameter.bff_token_url.name,
    aws_ssm_parameter.bff_token_scope.name,
    aws_ssm_parameter.cors_allowed_origins.name,
  ]
  # Parameter names start with "/", which an ARN's resource part also does
  # not repeat after "parameter".
  app_host_ssm_parameter_arns = [
    for n in local.app_host_ssm_parameter_names :
    "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${n}"
  ]
}

locals {
  ssm_parameter_read_actions = [
    "ssm:GetParameter",
    "ssm:GetParameters",
    "ssm:GetParametersByPath",
    "ssm:GetParameterHistory",
  ]
}

resource "aws_iam_role_policy" "read_parameters" {
  name = "read-cv-parameters"
  role = aws_iam_role.domain_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = local.app_host_ssm_parameter_arns
      },
      {
        Effect   = "Deny"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${var.environment}/deploy/*"
      },
      {
        Effect      = "Deny"
        Action      = local.ssm_parameter_read_actions
        NotResource = local.app_host_ssm_parameter_arns
      }
    ]
  })
}

# Nightly mysqldump upload (T-001) -- scoped to the backup prefix only,
# never the bucket root and never s3:*. AbortMultipartUpload is deliberately
# omitted: these are small logical dumps of a test-data database uploaded
# with a single `aws s3 cp`, well under the multipart threshold, so the
# extra permission has no justified use today (see the lifecycle rule's
# abort_incomplete_multipart_upload in backup.tf for cleanup instead).
resource "aws_iam_role_policy" "mysql_backup_upload" {
  name = "mysql-backup-upload"
  role = aws_iam_role.domain_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.backup.arn}/${local.mysql_backup_prefix}/*"
      }
    ]
  })
}

# T-070: `cv-redeploy migrate` reads the migration SQL tarball from S3 (once
# T-068 removes its public IPv4 the host cannot reach github.com). GetObject on
# that one key. ListBucket on the bucket is what turns a missing key into a 404
# instead of a 403, and the script falls back to git only on a 404. No s3:prefix
# condition: a missing-key GET carries no prefix, so one would turn the 404 back
# into a 403. The bucket holds only dumps and this object. Accepted: the bucket
# is unversioned and the host does not pin a checksum, so whoever may PutObject
# the key (only the cv-database master role) controls the SQL run in production.
resource "aws_iam_role_policy" "app_read_migration_sql" {
  name = "read-migration-sql"
  role = aws_iam_role.domain_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.backup.arn}/${local.migration_sql_key}"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.backup.arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "domain_service" {
  name = "${var.project_name}-domain-service"
  role = aws_iam_role.domain_service.name
}
