resource "aws_cognito_user_pool" "cv" {
  name = "${var.project_name}-users"

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  auto_verified_attributes = ["email"]

  tags = {
    Project = var.project_name
  }
}

resource "aws_cognito_user_pool_client" "admin_react" {
  name         = "${var.project_name}-admin-react"
  user_pool_id = aws_cognito_user_pool.cv.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  # T-061: the custom domain joins the cloudfront.net URL, which stays until
  # T-306 has moved the admin's build and login to auth.<domain>.
  callback_urls = [
    "http://localhost:5173/admin/",
    "https://${aws_cloudfront_distribution.frontend.domain_name}/admin/",
    "https://${local.public_apex}/admin/",
  ]
  logout_urls = [
    "http://localhost:5173/admin/",
    "https://${aws_cloudfront_distribution.frontend.domain_name}/admin/",
    "https://${local.public_apex}/admin/",
  ]
  supported_identity_providers = ["COGNITO"]
}

# T-043: the BFF calls the domain service with a client-credentials token.
# The domain service validates the issuer only, so any token from this pool
# is accepted; the read-only scope is the intended limit (write scoping is
# T-116).
resource "aws_cognito_resource_server" "cv_domain" {
  identifier   = "cv-domain"
  name         = "${var.project_name}-domain"
  user_pool_id = aws_cognito_user_pool.cv.id

  scope {
    scope_name        = "read"
    scope_description = "Read-only access to the domain service"
  }
}

resource "aws_cognito_user_pool_client" "bff_service" {
  name         = "${var.project_name}-bff-service"
  user_pool_id = aws_cognito_user_pool.cv.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["${aws_cognito_resource_server.cv_domain.identifier}/${one(aws_cognito_resource_server.cv_domain.scope).scope_name}"]
  supported_identity_providers         = ["COGNITO"]

  # 24 h (T-043 H1): Cognito bills per machine-token response, so a long
  # validity keeps this at ~30 requests/month (~$0.07) instead of ~730.
  access_token_validity = 24
  token_validity_units {
    access_token = "hours"
  }
}

resource "aws_cognito_user_pool_domain" "cv" {
  domain       = "${var.project_name}-${var.environment}"
  user_pool_id = aws_cognito_user_pool.cv.id
}

# T-062: the hosted UI and the OAuth token endpoint at auth.<apex>. Cognito
# fronts a custom domain with its own CloudFront distribution, which wants (a) a
# us-east-1 certificate covering the name (domain.tf's, validated before this is
# created) and (b) the parent domain to resolve, which the apex alias record
# gives it. A pool can hold this beside the prefix domain above; that one stays
# until T-306 has moved the admin build off it. Classic managed login (1)
# matches the prefix domain; version 2 would need a branding resource first or
# the login page breaks.
resource "aws_cognito_user_pool_domain" "custom" {
  domain                = local.public_auth
  user_pool_id          = aws_cognito_user_pool.cv.id
  certificate_arn       = aws_acm_certificate_validation.site.certificate_arn
  managed_login_version = 1

  depends_on = [aws_route53_record.site_alias]
}
