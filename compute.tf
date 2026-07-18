# Runs cv-domain-service and cv-bff-node. Kept to a single Free Tier
# t2/t3.micro instance for the demo rather than one EC2 per service.

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# Stable address: CloudFront's /api/* origin points at this EIP's public DNS,
# so the instance can be replaced without touching the distribution.
resource "aws_eip" "domain_service" {
  domain = "vpc"

  tags = {
    Name    = "${var.project_name}-domain-service"
    Project = var.project_name
  }
}

resource "aws_instance" "domain_service" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.domain_service_instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.domain_service.id]
  iam_instance_profile   = aws_iam_instance_profile.domain_service.name

  user_data = templatefile("${path.module}/templates/domain-service-user-data.sh", {
    aws_region        = var.aws_region
    project_name      = var.project_name
    environment       = var.environment
    image             = "${aws_ecr_repository.domain_service.repository_url}:latest"
    db_endpoint       = aws_db_instance.cv.endpoint
    db_name           = var.db_name
    db_username       = var.db_username
    cloudfront_domain = aws_cloudfront_distribution.frontend.domain_name
  })

  # user_data reads these parameters at first boot, so they must exist first.
  depends_on = [
    aws_ssm_parameter.db_password,
    aws_ssm_parameter.cognito_issuer_uri,
  ]

  tags = {
    Name    = "${var.project_name}-domain-service"
    Project = var.project_name
  }
}

resource "aws_eip_association" "domain_service" {
  instance_id   = aws_instance.domain_service.id
  allocation_id = aws_eip.domain_service.id
}
