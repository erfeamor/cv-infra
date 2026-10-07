# ECR repositories for cv-domain-service and cv-bff-node images.
#
# T-035: images are multi-arch (linux/amd64 + linux/arm64). A multi-arch tag is
# an image INDEX plus one manifest per architecture (plus buildx attestation
# manifests); ECR counts each as an image, and the children are untagged. The
# old "keep the 2 most recent of any tag status" rule could therefore expire
# :latest's arm64 child while :latest itself stayed. The rule below never
# touches a tagged image, and expires only UNTAGGED ones beyond the 20 newest
# (about 4 pushes' worth of children and orphans; T-050 added tagged rules
# sized to fit that budget, see local.ecr_lifecycle_policy). Storage is ~100 MB/image at
# $0.10/GB-month, so the extra retention costs cents.

# T-050: retention, one policy shared by both repos so they cannot drift.
#
# Each deploy pushes a multi-arch INDEX tagged `latest` and `<sha>`, plus 2-4
# UNTAGGED child manifests (per-arch, plus buildx attestations). A kept tag
# only pulls while its children exist, so the tagged budget must fit the
# untagged one: (latest + 4 shas) = 5 indexes x at most 4 children = 20,
# which is rule 3. Raise rule 2 without raising rule 3 and the children of
# kept shas get expired, leaving tags that no longer pull.
#
# Rule 1 exists only to CLAIM `latest`: ECR never lets a lower-priority rule
# expire an image that a higher-priority rule's tag selection matched, so
# :latest (and whatever sha it also carries, even after a rollback re-tags an
# older image) is out of rule 2's reach. Only one image ever carries `latest`,
# so countNumber 1 means rule 1 itself never expires anything. Rule 2 then
# counts only the other tagged images and keeps the 4 newest. A `tagged` rule
# needs tagPrefixList or tagPatternList; the `*` wildcard is only valid in
# tagPatternList.
locals {
  ecr_lifecycle_policy = {
    rules = [
      {
        rulePriority = 1
        description  = "Claim :latest so no lower rule can expire it; never expires anything (one image holds it)"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["latest"]
          countType     = "imageCountMoreThan"
          countNumber   = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 4 newest other tagged images (:<sha>); latest + 4 = 5 indexes x <=4 children fits rule 3"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 4
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "Expire untagged images beyond the 20 newest; never a tagged one (multi-arch children, T-035)"
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = { type = "expire" }
      },
    ]
  }
}

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

  policy = jsonencode(local.ecr_lifecycle_policy)
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

  policy = jsonencode(local.ecr_lifecycle_policy)
}
