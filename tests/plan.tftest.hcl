# Run with: terraform test
# Validates the plan succeeds with placeholder vars; does not apply anything.

variables {
  db_password   = "test-password-not-real"
  key_pair_name = "test-key-pair"
}

run "plan_succeeds" {
  command = plan

  assert {
    condition     = aws_db_instance.cv.instance_class == "db.t3.micro"
    error_message = "RDS instance must stay on the Free Tier db.t3.micro class"
  }

  assert {
    condition     = aws_instance.domain_service.instance_type == var.domain_service_instance_type
    error_message = "EC2 instance type should come from var.domain_service_instance_type"
  }
}
