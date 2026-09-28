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

# Lets the services read their secrets from SSM Parameter Store at runtime.
#
# T-008 security review round 2 (Medium, accepted): the Allow below is
# `/${var.project_name}/*` -- the whole parameter tree, including
# `deploy/drone-deploy/*` (ssm.tf), which this app host's own role has no
# business reading. Being outside `ci/*` only isolates that credential from
# the DRONE host's role; it does nothing against THIS role, which is
# broader by design (it legitimately needs db/, cognito/, observability/,
# etc across the tree). This host also has no `metadata_options` set (IMDSv1
# is on) and runs containers that could reach instance credentials via an
# SSRF/RCE in the domain service -- so an explicit Deny on `deploy/*` closes
# that path without narrowing the Allow itself (narrowing the Allow to an
# enumerated list is T-005 work; a missed path there would break this
# host's own boot, which an explicit Deny cannot do since it only ever
# subtracts). IAM evaluates an explicit Deny before any Allow, regardless
# of statement order or which policy/role it's attached through, so this
# holds even though it's declared after the Allow.
resource "aws_iam_role_policy" "read_parameters" {
  name = "read-cv-parameters"
  role = aws_iam_role.domain_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/*"
      },
      {
        Effect   = "Deny"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${var.environment}/deploy/*"
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

resource "aws_iam_instance_profile" "domain_service" {
  name = "${var.project_name}-domain-service"
  role = aws_iam_role.domain_service.name
}

resource "aws_iam_role" "drone" {
  name = "${var.project_name}-drone"

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
resource "aws_iam_role_policy_attachment" "drone_ssm_core" {
  role       = aws_iam_role.drone.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The Drone host only needs the CI secrets, not the whole parameter tree.
resource "aws_iam_role_policy" "drone_read_ci_parameters" {
  name = "read-ci-parameters"
  role = aws_iam_role.drone.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${var.environment}/ci/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "drone" {
  name = "${var.project_name}-drone"
  role = aws_iam_role.drone.name
}

# Identity the cv-admin-react deploy step runs as: sync dist/ to the frontend
# bucket and invalidate CloudFront, nothing broader.
resource "aws_iam_user" "drone_deploy" {
  name = "${var.project_name}-drone-deploy"

  tags = {
    Project = var.project_name
  }
}

# T-008 H1 decision 1: the key is created HERE, in Terraform, instead of
# out-of-band. Before this task the secret's only copy was in Drone's
# SQLite on the CI host's unencrypted root volume; creating it here means
# it's also written to SSM (ssm.tf) and lands in Terraform state, which has
# been in the encrypted S3 backend since T-004 -- that tradeoff no longer
# favors keeping it out-of-band. No output references this resource (see
# outputs.tf); the secret leaves this module only via the SSM parameters.
resource "aws_iam_access_key" "drone_deploy" {
  user = aws_iam_user.drone_deploy.name
}

resource "aws_iam_user_policy" "drone_deploy" {
  name = "frontend-deploy"
  user = aws_iam_user.drone_deploy.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.frontend.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.frontend.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = aws_cloudfront_distribution.frontend.arn
      }
    ]
  })
}
