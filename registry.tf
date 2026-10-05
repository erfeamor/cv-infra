# ECR repositories for cv-domain-service and cv-bff-node images.
#
# T-035: images are multi-arch (linux/amd64 + linux/arm64). A multi-arch tag is
# an image INDEX plus one manifest per architecture (plus buildx attestation
# manifests); ECR counts each as an image, and the children are untagged. The
# old "keep the 2 most recent of any tag status" rule could therefore expire
# :latest's arm64 child while :latest itself stayed. The rule below never
# touches a tagged image, and expires only UNTAGGED ones beyond the 20 newest
# (about 4 pushes' worth of children and orphans). Storage is ~100 MB/image at
# $0.10/GB-month, so the extra retention costs cents.

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
        description  = "Expire untagged images beyond the 20 newest; never a tagged one (multi-arch children, T-035)"
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ECR repository for cv-bff-node images (T-014). Mirrors domain_service above.
resource "aws_ecr_repository" "bff_node" {
  name = "${var.project_name}-bff-node"

  # Demo project: let terraform destroy remove the repo even with images in it.
  force_delete = true

  tags = {
    Project = var.project_name
  }
}

resource "aws_ecr_lifecycle_policy" "bff_node" {
  repository = aws_ecr_repository.bff_node.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images beyond the 20 newest; never a tagged one (multi-arch children, T-035)"
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = { type = "expire" }
      }
    ]
  })
}
