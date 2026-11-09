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

resource "aws_ssm_parameter" "cognito_issuer_uri" {
  name  = "/${var.project_name}/${var.environment}/cognito/issuer-uri"
  type  = "String"
  value = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.cv.id}"

  tags = {
    Project = var.project_name
  }
}

# T-043: the BFF's client-credentials identity, read at boot by
# templates/domain-service-provision.sh. The secret is also in Terraform
# state (like the other generated secrets here); it is never an output.
resource "aws_ssm_parameter" "bff_service_client_id" {
  name  = "/${var.project_name}/${var.environment}/bff/service-client-id"
  type  = "String"
  value = aws_cognito_user_pool_client.bff_service.id

  tags = {
    Project = var.project_name
  }
}

resource "aws_ssm_parameter" "bff_service_client_secret" {
  name  = "/${var.project_name}/${var.environment}/bff/service-client-secret"
  type  = "SecureString"
  value = aws_cognito_user_pool_client.bff_service.client_secret

  tags = {
    Project = var.project_name
  }
}

resource "aws_ssm_parameter" "bff_token_url" {
  name  = "/${var.project_name}/${var.environment}/bff/token-url"
  type  = "String"
  value = "https://${aws_cognito_user_pool_domain.custom.domain}/oauth2/token"

  # The URL is known as soon as the Cognito domain exists, but the name only
  # resolves once the alias to Cognito's distribution is in DNS; without this a
  # cv-redeploy in that window would point the BFF at nothing (T-062).
  depends_on = [aws_route53_record.auth_alias]

  tags = {
    Project = var.project_name
  }
}

resource "aws_ssm_parameter" "bff_token_scope" {
  name  = "/${var.project_name}/${var.environment}/bff/token-scope"
  type  = "String"
  value = "${aws_cognito_resource_server.cv_domain.identifier}/${one(aws_cognito_resource_server.cv_domain.scope).scope_name}"

  tags = {
    Project = var.project_name
  }
}
