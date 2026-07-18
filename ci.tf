# Drone CI host for cv-admin-react pipelines: one Free Tier instance running
# the Drone 2.x server and a docker runner. GitHub must reach it for webhooks
# and the OAuth callback, so it keeps a stable Elastic IP.
#
# Manual steps Terraform cannot do:
#   1. Create a GitHub OAuth app (org erfeamor) with authorization callback
#      http://<drone_server_url>/login and put its credentials in tfvars.
#   2. After first login, activate cv-admin-react in the Drone UI.
#   3. Create an access key for the drone-deploy IAM user (see iam.tf) and
#      store it as Drone secrets for the deploy step.

resource "aws_eip" "drone" {
  domain = "vpc"

  tags = {
    Name    = "${var.project_name}-drone"
    Project = var.project_name
  }
}

resource "aws_instance" "drone" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.drone_instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.drone.id]
  iam_instance_profile   = aws_iam_instance_profile.drone.name

  user_data = templatefile("${path.module}/templates/drone-user-data.sh", {
    aws_region     = var.aws_region
    project_name   = var.project_name
    environment    = var.environment
    server_host    = aws_eip.drone.public_ip
    admin_username = var.drone_admin_username
  })

  # user_data reads the CI parameters at first boot, so they must exist first.
  depends_on = [
    aws_ssm_parameter.drone_rpc_secret,
    aws_ssm_parameter.drone_github_client_id,
    aws_ssm_parameter.drone_github_client_secret,
  ]

  tags = {
    Name    = "${var.project_name}-drone"
    Project = var.project_name
  }
}

resource "aws_eip_association" "drone" {
  instance_id   = aws_instance.drone.id
  allocation_id = aws_eip.drone.id
}
