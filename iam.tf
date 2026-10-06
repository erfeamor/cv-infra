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
locals {
  app_host_ssm_parameter_names = [
    aws_ssm_parameter.app_host_provision_sha256.name,
    aws_ssm_parameter.db_password.name,
    aws_ssm_parameter.cognito_issuer_uri.name,
    aws_ssm_parameter.bff_service_client_id.name,
    aws_ssm_parameter.bff_service_client_secret.name,
    aws_ssm_parameter.bff_token_url.name,
    aws_ssm_parameter.bff_token_scope.name,
  ]
  # Parameter names start with "/", which an ARN's resource part also does
  # not repeat after "parameter".
  app_host_ssm_parameter_arns = [
    for n in local.app_host_ssm_parameter_names :
    "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${n}"
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


# T-034 phase 2: the boot-time DNS updater (scripts/ci-dns-updater.sh) needs
# exactly one Route 53 write. Route 53 has NO record-level ARNs -- the
# Resource is unavoidably the whole hosted zone -- so the narrowing has to
# come from the Condition block instead: this account's own T-005 gap notes
# the CI role is reachable from inside a build, so a compromised build
# container inheriting this grant must not be able to touch any OTHER record
# in the zone, any OTHER record type, or do anything but UPSERT.
# ForAllValues:StringEquals on all three keys, each a single-element list, is
# what makes this exact rather than merely "includes" -- StringEquals alone
# (without ForAllValues) would also allow a request whose value SET is a
# superset of the allowed one. scripts/check-static.sh (check 10) pins the
# single action, the zone-ARN Resource, and all three condition values
# textually, since jsondecode CAN run on this specific policy under
# `command = plan` (data.aws_route53_zone.ci.arn is a MOCKED data source,
# not a computed resource attribute, so it actually IS known here -- unlike
# every EC2/Lambda ARN elsewhere in this file) but the plan settled this as a
# static check anyway, for consistency with how every other IAM exactness
# check in this module is done.
locals {
  # Named for the same reason ci-on-demand.tf names the EC2/Lambda action
  # lists: `terraform test` can assert on these directly (case 3, no
  # wildcard names/types/actions), while the full exact-shape check (one
  # action, the zone ARN as Resource, all three conditions) is
  # scripts/check-static.sh check 10, per the plan.
  ci_dns_update_actions       = ["route53:ChangeResourceRecordSets"]
  ci_dns_update_record_names  = [var.ci_hostname]
  ci_dns_update_record_types  = ["A"]
  ci_dns_update_actions_types = ["UPSERT"]

  # Review round 1, finding 5: read-only additions for the updater's
  # idempotency check (list the current value before deciding whether to
  # write) and its INSYNC wait. Named separately from the write action above
  # so check-static's exactness check keeps verifying the WRITE grant
  # specifically, unaffected by these.
  ci_dns_read_actions = ["route53:ListResourceRecordSets"]

  # route53:GetChange has NO record- or zone-scoped ARN -- AWS's own
  # documented resource type for it is `change/<id>`, and the id is only
  # known AFTER a change is submitted, so `change/*` is the narrowest
  # Resource this action can ever take, for anyone. Safe regardless of that
  # width: GetChange is read-only (it returns a change's PENDING/INSYNC
  # propagation status, nothing about a record's content), and it grants
  # nothing about any OTHER account's changes -- change ids are scoped to
  # the account that made them, IAM evaluates this within the CI role's own
  # account only. It does not widen what this role can WRITE; that stays
  # exactly the conditioned grant above.
  ci_dns_get_change_actions   = ["route53:GetChange"]
  ci_dns_get_change_resources = ["arn:aws:route53:::change/*"]
}

resource "aws_iam_role_policy" "drone_dns_update" {
  name = "ci-dns-update"
  role = aws_iam_role.drone.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = local.ci_dns_update_actions
        Resource = data.aws_route53_zone.ci.arn
        Condition = {
          "ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = local.ci_dns_update_record_names
            "route53:ChangeResourceRecordSetsRecordTypes"           = local.ci_dns_update_record_types
            "route53:ChangeResourceRecordSetsActions"               = local.ci_dns_update_actions_types
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = local.ci_dns_read_actions
        Resource = data.aws_route53_zone.ci.arn
      },
      {
        Effect   = "Allow"
        Action   = local.ci_dns_get_change_actions
        Resource = local.ci_dns_get_change_resources
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
