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

resource "aws_ssm_parameter" "cognito_issuer_uri" {
  name  = "/${var.project_name}/${var.environment}/cognito/issuer-uri"
  type  = "String"
  value = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.cv.id}"

  tags = {
    Project = var.project_name
  }
}
