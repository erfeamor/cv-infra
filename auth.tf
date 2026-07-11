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
  callback_urls                        = ["http://localhost:5173"]
  logout_urls                          = ["http://localhost:5173"]
  supported_identity_providers         = ["COGNITO"]
}

resource "aws_cognito_user_pool_domain" "cv" {
  domain       = "${var.project_name}-${var.environment}"
  user_pool_id = aws_cognito_user_pool.cv.id
}
