output "domain_service_public_ip" {
  value = aws_eip.domain_service.public_ip
}

output "domain_service_ecr_repository_url" {
  value = aws_ecr_repository.domain_service.repository_url
}

output "cognito_admin_client_id" {
  value = aws_cognito_user_pool_client.admin_react.id
}

output "database_endpoint" {
  value = aws_db_instance.cv.endpoint
}

output "frontend_bucket_name" {
  value = aws_s3_bucket.frontend.bucket
}

output "frontend_cloudfront_domain" {
  value = aws_cloudfront_distribution.frontend.domain_name
}

output "drone_server_url" {
  value = "http://${aws_eip.drone.public_ip}"
}

output "frontend_cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.frontend.id
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.cv.id
}

output "cognito_hosted_ui_domain" {
  value = aws_cognito_user_pool_domain.cv.domain
}
