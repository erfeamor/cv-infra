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

resource "aws_iam_role" "drone" {
  name = "${var.project_name}-drone"

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
resource "aws_iam_role_policy_attachment" "drone_ssm_core" {
  role       = aws_iam_role.drone.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The Drone host only needs the CI secrets, not the whole parameter tree.
resource "aws_iam_role_policy" "drone_read_ci_parameters" {
  name = "read-ci-parameters"
  role = aws_iam_role.drone.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${var.environment}/ci/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "drone" {
  name = "${var.project_name}-drone"
  role = aws_iam_role.drone.name
}

# Identity the cv-admin-react deploy step runs as: sync dist/ to the frontend
# bucket and invalidate CloudFront, nothing broader. Its access key is created
# manually (console/CLI) and stored as Drone secrets — creating it here would
# put the secret in Terraform state.
resource "aws_iam_user" "drone_deploy" {
  name = "${var.project_name}-drone-deploy"

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_user_policy" "drone_deploy" {
  name = "frontend-deploy"
  user = aws_iam_user.drone_deploy.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.frontend.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.frontend.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = aws_cloudfront_distribution.frontend.arn
      }
    ]
  })
}
