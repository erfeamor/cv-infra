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
