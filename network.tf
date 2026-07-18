# Uses the account's default VPC to stay within Free Tier scope for the demo
# instead of standing up a dedicated VPC/NAT gateway (NAT gateways are not
# free-tier eligible).

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "domain_service" {
  name        = "${var.project_name}-domain-service"
  description = "Allows inbound HTTP(S) and SSH to the domain service EC2 instance"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "App port"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # No SSH ingress: shell access goes through SSM Session Manager, which
  # needs only the instance profile (see iam.tf) and outbound HTTPS.

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = var.project_name
  }
}

resource "aws_security_group" "drone" {
  name        = "${var.project_name}-drone"
  description = "Allows inbound HTTP(S) from GitHub (webhooks, OAuth callback) to the Drone CI host"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Drone web UI / webhooks"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS (when TLS is added in front of Drone)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # No SSH ingress: shell access goes through SSM Session Manager, same as the
  # domain service instance.

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = var.project_name
  }
}

resource "aws_security_group" "database" {
  name        = "${var.project_name}-database"
  description = "Allows inbound MySQL from the domain service security group"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "MySQL from domain service"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.domain_service.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = var.project_name
  }
}
