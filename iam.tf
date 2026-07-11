resource "aws_iam_role" "domain_service" {
  name = "${var.project_name}-domain-service"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

# Session Manager access — replaces SSH (no port 22, no key distribution).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.domain_service.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Lets the services read their secrets from SSM Parameter Store at runtime.
resource "aws_iam_role_policy" "read_parameters" {
  name = "read-cv-parameters"
  role = aws_iam_role.domain_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "domain_service" {
  name = "${var.project_name}-domain-service"
  role = aws_iam_role.domain_service.name
}
