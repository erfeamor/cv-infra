resource "aws_cloudwatch_log_group" "domain_service" {
  name              = "/${var.project_name}/cv-domain-service"
  retention_in_days = 14

  tags = {
    Project = var.project_name
  }
}

resource "aws_cloudwatch_log_group" "bff_node" {
  name              = "/${var.project_name}/cv-bff-node"
  retention_in_days = 14

  tags = {
    Project = var.project_name
  }
}

# T-019: the on-demand CI Lambdas. Created explicitly rather than left to
# Lambda's implicit creation so retention is bounded and the IAM policies can
# scope logs:PutLogEvents to a known ARN instead of "*".
resource "aws_cloudwatch_log_group" "ci_doorbell" {
  name              = "/aws/lambda/${var.project_name}-ci-doorbell"
  retention_in_days = 14

  tags = {
    Project = var.project_name
  }
}

resource "aws_cloudwatch_log_group" "ci_reaper" {
  name              = "/aws/lambda/${var.project_name}-ci-reaper"
  retention_in_days = 14

  tags = {
    Project = var.project_name
  }
}
