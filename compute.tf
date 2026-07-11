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

resource "aws_instance" "domain_service" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.domain_service_instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.domain_service.id]
  iam_instance_profile   = aws_iam_instance_profile.domain_service.name

  tags = {
    Name    = "${var.project_name}-domain-service"
    Project = var.project_name
  }
}
