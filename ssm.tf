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
