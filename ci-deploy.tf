# T-047: CI deploy from GitHub Actions. No deploy credential lives on the CI
# host (Jenkins/Drone mount docker.sock, so any build is root there; T-005).
# Each service repo's workflow assumes its own OIDC role (the provider is
# aws_iam_openid_connect_provider.github_actions, github-oidc.tf), pushes a
# multi-arch image to its own ECR repo, then runs ITS OWN parameterless SSM
# document, which only runs `cv-redeploy <svc>` on the app host. The role cannot
# send AWS-RunShellScript, the other service's document, or reach the CI host.
#
# The app host is replaced often, so the workflows target it by tag
# (--targets Key=tag:Name,Values=<project>-domain-service) and SendCommand on
# instances is scoped by the ssm:resourceTag/Name condition, not an instance id.

locals {
  app_host_name_tag = "${var.project_name}-domain-service"
  app_instances_arn = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
}

# --- domain-service ---

# No `parameters` block on purpose: nothing a caller sends reaches the shell.
resource "aws_ssm_document" "redeploy_domain_service" {
  name            = "cv-redeploy-domain-service"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "T-047: run cv-redeploy domain-service on the app host. Takes no parameters."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "redeploy"
        inputs = {
          runCommand     = ["/usr/local/bin/cv-redeploy domain-service"]
          timeoutSeconds = "600"
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role" "domain_service_deploy" {
  name                 = "${var.project_name}-domain-service-deploy"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = "repo:${local.github_org}/cv-domain-service:ref:refs/heads/master"
          }
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy" "domain_service_deploy" {
  name = "ecr-push-and-redeploy"
  role = aws_iam_role.domain_service_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ECR requires Resource "*" for GetAuthorizationToken.
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        # Own repository only (buildx may read the base manifest/layers).
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = aws_ecr_repository.domain_service.arn
      },
      {
        # SendCommand authorizes against the document and the instances; the
        # document carries no tags, so it gets its own unconditioned statement.
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = aws_ssm_document.redeploy_domain_service.arn
      },
      {
        # Instances: only those tagged Name=<app host>, so a replaced host is
        # still reachable but the CI host (a different Name) is not.
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = local.app_instances_arn
        Condition = {
          StringEquals = { "ssm:resourceTag/Name" = local.app_host_name_tag }
        }
      },
      {
        # These two do not support resource-level permissions.
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      },
    ]
  })
}

output "domain_service_deploy_role_arn" {
  description = "T-047: role the cv-domain-service GitHub workflow assumes via OIDC (master only). Not a secret; set as a repo variable."
  value       = aws_iam_role.domain_service_deploy.arn
}

output "domain_service_redeploy_document" {
  description = "T-047: SSM document the cv-domain-service workflow sends (target the app host by tag Name=<project>-domain-service)."
  value       = aws_ssm_document.redeploy_domain_service.name
}

# --- bff-node ---

# No `parameters` block on purpose: nothing a caller sends reaches the shell.
resource "aws_ssm_document" "redeploy_bff_node" {
  name            = "cv-redeploy-bff-node"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "T-047: run cv-redeploy bff-node on the app host. Takes no parameters."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "redeploy"
        inputs = {
          runCommand     = ["/usr/local/bin/cv-redeploy bff-node"]
          timeoutSeconds = "600"
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role" "bff_node_deploy" {
  name                 = "${var.project_name}-bff-node-deploy"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = "repo:${local.github_org}/cv-bff-node:ref:refs/heads/master"
          }
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy" "bff_node_deploy" {
  name = "ecr-push-and-redeploy"
  role = aws_iam_role.bff_node_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ECR requires Resource "*" for GetAuthorizationToken.
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        # Own repository only (buildx may read the base manifest/layers).
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = aws_ecr_repository.bff_node.arn
      },
      {
        # SendCommand authorizes against the document and the instances; the
        # document carries no tags, so it gets its own unconditioned statement.
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = aws_ssm_document.redeploy_bff_node.arn
      },
      {
        # Instances: only those tagged Name=<app host>, so a replaced host is
        # still reachable but the CI host (a different Name) is not.
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = local.app_instances_arn
        Condition = {
          StringEquals = { "ssm:resourceTag/Name" = local.app_host_name_tag }
        }
      },
      {
        # These two do not support resource-level permissions.
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      },
    ]
  })
}

output "bff_node_deploy_role_arn" {
  description = "T-047: role the cv-bff-node GitHub workflow assumes via OIDC (master only). Not a secret; set as a repo variable."
  value       = aws_iam_role.bff_node_deploy.arn
}

output "bff_node_redeploy_document" {
  description = "T-047: SSM document the cv-bff-node workflow sends (target the app host by tag Name=<project>-domain-service)."
  value       = aws_ssm_document.redeploy_bff_node.name
}
