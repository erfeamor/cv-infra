# ECR repository for cv-domain-service images. Free Tier private storage is
# 500 MB, so the lifecycle policy keeps only the two most recent images
# (a Temurin JRE image runs ~200 MB compressed).

resource "aws_ecr_repository" "domain_service" {
  name = "${var.project_name}-domain-service"

  # Demo project: let terraform destroy remove the repo even with images in it.
  force_delete = true

  tags = {
    Project = var.project_name
  }
}

resource "aws_ecr_lifecycle_policy" "domain_service" {
  repository = aws_ecr_repository.domain_service.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the two most recent images (Free Tier 500 MB)"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 2
        }
        action = { type = "expire" }
      }
    ]
  })
}
