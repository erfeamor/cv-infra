# Run with: terraform test
# Uses a mocked AWS provider so the plan runs without credentials or network
# access — data sources return the mock defaults below.

mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = {
      id = "vpc-00000000000000000"
    }
  }

  mock_data "aws_subnets" {
    defaults = {
      ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
    }
  }

  mock_data "aws_ami" {
    defaults = {
      id = "ami-00000000000000000"
    }
  }
}

variables {
  db_password = "test-password-not-real"
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

  assert {
    condition     = aws_instance.domain_service.iam_instance_profile == aws_iam_instance_profile.domain_service.name
    error_message = "EC2 must carry the instance profile that grants SSM access"
  }
}
