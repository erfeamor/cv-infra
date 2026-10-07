# ECR repositories for cv-domain-service and cv-bff-node images.
#
# T-035: images are multi-arch (linux/amd64 + linux/arm64). A multi-arch tag is
# an image INDEX plus one manifest per architecture (plus buildx attestation
# manifests); ECR counts each as an image, and the children are untagged. The
# old "keep the 2 most recent of any tag status" rule could therefore expire
# :latest's arm64 child while :latest itself stayed. T-035's untagged rule
# expires only UNTAGGED images beyond the newest few; T-050 added tagged rules
# that DO expire old `:<sha>` images (keeping `latest` + 4 previous), with the
# untagged budget sized to fit them (see local.ecr_lifecycle_policy). Storage
# is ~100 MB/image at # $0.10/GB-month, so the extra retention costs cents.

# T-050: retention, one policy shared by both repos so they cannot drift.
#
# Each deploy pushes a multi-arch INDEX tagged `latest` and `<sha>`, plus
# UNTAGGED child manifests (one per arch). Both workflows build with
# `provenance: false` (cv-domain-service deploy.yml, cv-bff-node ci.yml), so
# each deploy leaves exactly 2 children. A kept tag only pulls while its
# children exist, so the untagged budget (rule 3) is sized from the tagged one:
#   rule 3 = ecr_keep_tagged x ecr_children_per_index + ecr_orphan_headroom
# The headroom absorbs per-arch digests from a deploy whose merge job failed
# (children pushed, no index), de-tagged indexes and children after a same-sha
# re-run, and older orphans. If provenance or SBOM attestations are turned on
# in either workflow, each deploy leaves 4 children: set
# ecr_children_per_index = 4 (and re-check the headroom) in the same change.
#
# Rule 1 only CLAIMS `latest`: ECR never lets a lower-priority rule expire an
# image a higher-priority rule's tag selection matched (so :latest stays safe,
# even after a rollback re-tags an older image). It is an exact tagPatternList
# match (a tagPrefixList would also catch `latest-rc` etc.). Only one image
# holds `latest`, so countNumber 1 means rule 1 never expires anything.
#
# Rule 2: lower-priority rules still COUNT images a higher rule matched, as if
# they were not expired, and `*` matches `latest`. So rule 2 does not select
# "other" tagged images; it counts latest too, and ecr_keep_tagged = 5 keeps
# `latest` + the 4 previous `<sha>` images. A `tagged` rule needs
# tagPrefixList or tagPatternList; `*` is only valid in tagPatternList.
locals {
  ecr_keep_tagged        = 5  # latest + 4 previous shas
  ecr_children_per_index = 2  # amd64 + arm64, provenance: false
  ecr_orphan_headroom    = 10 # see above

  ecr_lifecycle_policy = {
    rules = [
      {
        rulePriority = 1
        description  = "Claim :latest (exact) so no lower rule can expire it; never expires anything (one image holds it)"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["latest"]
          countType      = "imageCountMoreThan"
          countNumber    = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 5 newest tagged images (the count includes :latest, so latest + 4 previous :<sha>)"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = local.ecr_keep_tagged
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "Expire untagged images beyond keep x children + orphan headroom (multi-arch children, T-035/T-050)"
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = local.ecr_keep_tagged * local.ecr_children_per_index + local.ecr_orphan_headroom
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
