# Secrets for the app services, resolved at deploy/runtime instead of being
# baked into images or env files.

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.project_name}/${var.environment}/db/password"
  type  = "SecureString"
  value = var.db_password

  tags = {
    Project = var.project_name
  }
}

# T-007: DRONE_DATABASE_SECRET encrypts sensitive data (repo OAuth tokens,
# activated-repo secrets) at rest in Drone's SQLite. Drone has run without
# one since it was first stood up (T-002) -- docs/drone-host-backup-and-cutover.md
# recorded that gap explicitly. Generated here, not typed into tfvars by
# hand, so the only copies are Terraform state and this SecureString.
#
# Format: Drone reads this as an opaque string and uses it as an AES-256 key
# to encrypt values before they touch SQLite, so it must be exactly 32 bytes.
# random_password's default character set (letters + digits, no special
# chars here -- see override below) makes each character exactly 1 byte in
# UTF-8, so length = 32 yields a 32-byte ASCII key -- satisfies both "32
# bytes" and "32-char string" without relying on a hex/base64 encoding Drone
# would then have to decode.
resource "random_password" "drone_database_secret" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "drone_database_secret" {
  name  = "/${var.project_name}/${var.environment}/ci/drone/database-secret"
  type  = "SecureString"
  value = random_password.drone_database_secret.result

  tags = {
    Project = var.project_name
  }
}

# CI secrets the Drone host reads at boot (see templates/drone-user-data.sh).
resource "aws_ssm_parameter" "drone_rpc_secret" {
  name  = "/${var.project_name}/${var.environment}/ci/drone-rpc-secret"
  type  = "SecureString"
  value = var.drone_rpc_secret

  tags = {
    Project = var.project_name
  }
}

resource "aws_ssm_parameter" "drone_github_client_id" {
  name  = "/${var.project_name}/${var.environment}/ci/github-client-id"
  type  = "String"
  value = var.drone_github_client_id

  tags = {
    Project = var.project_name
  }
}

resource "aws_ssm_parameter" "drone_github_client_secret" {
  name  = "/${var.project_name}/${var.environment}/ci/github-client-secret"
  type  = "SecureString"
  value = var.drone_github_client_secret

  tags = {
    Project = var.project_name
  }
}

# Jenkins CI secrets the Drone/Jenkins host reads at boot (see
# templates/jenkins-provision.sh). Naming and sensitivity mirror the
# existing Drone CI parameters above -- least privilege enforced at the
# PAT's GitHub scope, not here.
resource "aws_ssm_parameter" "jenkins_admin_password" {
  name  = "/${var.project_name}/${var.environment}/ci/jenkins-admin-password"
  type  = "SecureString"
  value = var.jenkins_admin_password

  tags = {
    Project = var.project_name
  }
}

# repo:status (classic) or fine-grained Commit-statuses:read/write on
# cv-domain-service + cv-database only -- see variable description. Bare
# 'repo' scope is a blocking finding at /security-review.
resource "aws_ssm_parameter" "github_pat_ci" {
  name  = "/${var.project_name}/${var.environment}/ci/github-pat"
  type  = "SecureString"
  value = var.github_pat_ci

  tags = {
    Project = var.project_name
  }
}

# T-008 H1 decision 1: the drone-deploy IAM user's own access key
# (aws_iam_access_key.drone_deploy, iam.tf), so the Drone SQLite on the CI
# host stops being the only copy of this credential.
#
# Deliberately OUTSIDE .../ci/* -- that prefix is what
# aws_iam_role_policy.drone_read_ci_parameters (iam.tf) grants the Drone
# HOST's own instance role, and build containers running on that host can
# reach it until T-007/T-005 land. If this credential lived under ci/*, a
# compromised build container could read out the very key that lets it
# push to the frontend bucket and invalidate CloudFront -- i.e. mint itself
# deploy access from inside a build.
#
# Security review round 2 (Medium, accepted): being outside ci/* only
# isolates this path from the Drone HOST's role -- it does NOT isolate it
# from the APP host's role. aws_iam_role_policy.read_parameters (iam.tf)
# grants that role ssm:GetParameter* on the whole /${var.project_name}/*
# tree, which already covers this deploy/ prefix; that host also has no
# metadata_options (IMDSv1 on) and runs containers reachable by an
# SSRF/RCE. So this path is protected two different ways, not one: scope
# (outside ci/*) keeps it from the CI host's role, and an explicit Deny on
# read_parameters (iam.tf) keeps it from the app host's role. Both are
# needed; neither alone is sufficient. It is read only by an operator's own
# credentials, off-host, via scripts/drone-reseed-secrets.sh (see
# docs/drone-host-backup-and-cutover.md).
resource "aws_ssm_parameter" "drone_deploy_access_key_id" {
  name  = "/${var.project_name}/${var.environment}/deploy/drone-deploy/access-key-id"
  type  = "SecureString"
  value = aws_iam_access_key.drone_deploy.id

  tags = {
    Project = var.project_name
  }
}

resource "aws_ssm_parameter" "drone_deploy_secret_access_key" {
  name  = "/${var.project_name}/${var.environment}/deploy/drone-deploy/secret-access-key"
  type  = "SecureString"
  value = aws_iam_access_key.drone_deploy.secret

  tags = {
    Project = var.project_name
  }
}

resource "aws_ssm_parameter" "cognito_issuer_uri" {
  name  = "/${var.project_name}/${var.environment}/cognito/issuer-uri"
  type  = "String"
  value = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.cv.id}"

  tags = {
    Project = var.project_name
  }
}

# T-019 ruling 4: the doorbell's HMAC check needs a shared secret, and no
# webhook secret existed anywhere in this project — T-005 listed one under
# "also worth doing" and it was never built. Set the SAME value in each GitHub
# webhook (see the manual steps in ci.tf); without it the Function URL would be
# an unauthenticated endpoint that starts EC2 instances.
resource "aws_ssm_parameter" "github_webhook_secret" {
  name  = "/${var.project_name}/${var.environment}/ci/github-webhook-secret"
  type  = "SecureString"
  value = var.github_webhook_secret

  tags = {
    Project = var.project_name
  }
}
