# CI host for the demo: Drone (cv-admin-react) and, since T-002, Jenkins
# (cv-domain-service, cv-database) co-located on the same instance rather
# than a third box. GitHub must reach it for webhooks and Drone's OAuth
# callback, so it keeps a stable Elastic IP. A reverse proxy container
# fronts both services on the existing 80/443 ingress -- see
# templates/jenkins-provision.sh.
#
# Manual steps Terraform cannot do:
#   1. Create a GitHub OAuth app (org erfeamor) with authorization callback
#      http://<drone_server_url>/login and put its credentials in tfvars.
#   2. After first login, activate cv-admin-react in the Drone UI.
#   3. Create an access key for the drone-deploy IAM user (see iam.tf) and
#      store it as Drone secrets for the deploy step.
#   4. Create the GitHub PAT for Jenkins (repo:status only, or fine-grained
#      Commit-statuses:read/write on cv-domain-service + cv-database) and
#      put it in terraform.tfvars as github_pat_ci -- it lands in SSM as a
#      SecureString (see ssm.tf), never committed.
#   5. Add a webhook on cv-domain-service and cv-database (Settings ->
#      Webhooks) pointing at http://<drone_server_url>/jenkins/github-webhook/
#      for events push + pull_request -- mirrors the cv-admin-react -> Drone
#      hook. This needs a token/user with hook-admin rights; the PAT above
#      is deliberately scoped to repo:status only and cannot create hooks
#      itself, so this step stays manual by design (least privilege).
#
# T-002 (H1 decision 1): Jenkins is installed on the *live* instance
# out-of-band via SSM Run Command (null_resource.jenkins_provision below),
# not by editing user_data alone -- aws_instance.drone has no
# user_data_replace_on_change, so a user_data-only edit updates Terraform
# state without cloud-init ever re-running on a box that's already up (see
# compute.tf; this exact bug shipped once). user_data is still updated, in
# parallel, purely so a *future* replacement instance self-provisions
# Jenkins from a clean boot -- these two paths are a deliberate split, not
# an inconsistency.

locals {
  # Same template rendered twice (see the header comment): once concatenated
  # into user_data for a future clean boot, once pushed out-of-band via SSM
  # to the box that's live today. Single source of truth, no drift between
  # the two paths.
  jenkins_provision_script = templatefile("${path.module}/templates/jenkins-provision.sh", {
    aws_region             = var.aws_region
    project_name           = var.project_name
    environment            = var.environment
    server_host            = aws_eip.drone.public_ip
    admin_username         = var.drone_admin_username
    jenkins_admin_username = var.jenkins_admin_username
  })
}

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

  # Concatenated so a *future* replacement instance boots straight into
  # Drone + Jenkins + proxy. Deliberately NOT paired with
  # user_data_replace_on_change (see header comment) -- on the box that is
  # live today this changes Terraform state only; Jenkins gets installed on
  # it via null_resource.jenkins_provision instead.
  user_data = join("\n", [
    templatefile("${path.module}/templates/drone-user-data.sh", {
      aws_region     = var.aws_region
      project_name   = var.project_name
      environment    = var.environment
      server_host    = aws_eip.drone.public_ip
      admin_username = var.drone_admin_username
    }),
    local.jenkins_provision_script,
  ])

  # user_data reads the CI parameters at first boot, so they must exist first.
  depends_on = [
    aws_ssm_parameter.drone_rpc_secret,
    aws_ssm_parameter.drone_github_client_id,
    aws_ssm_parameter.drone_github_client_secret,
    aws_ssm_parameter.jenkins_admin_password,
    aws_ssm_parameter.github_pat_ci,
  ]

  # AMI churn must never replace this host: Drone's state (repo activations,
  # secrets) is SQLite on the instance volume.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name    = "${var.project_name}-drone"
    Project = var.project_name
  }
}

resource "aws_eip_association" "drone" {
  instance_id   = aws_instance.drone.id
  allocation_id = aws_eip.drone.id
}

# Stages the rendered script on disk (gitignored, see .gitignore) so the
# local-exec command below never has to embed a large multi-line value
# inside a shell heredoc -- nesting a Terraform heredoc around a bash
# heredoc around a script that itself contains heredocs is a quoting trap
# (Terraform's indentation dedent is keyed off the *smallest* indentation
# across every line, including this script's own column-0 lines, so it
# would silently fail to strip the surrounding wrapper's indentation and
# could desync the inner heredoc terminator). A real file + --rawfile
# sidesteps all of that.
resource "local_file" "jenkins_provision_script" {
  filename        = "${path.module}/generated/jenkins-provision.sh"
  content         = local.jenkins_provision_script
  file_permission = "0600"
}

# T-002 (H1 decision 1): out-of-band provisioning of the *live* instance.
# Runs the exact same script as the user_data path above via SSM Run
# Command instead of relying on cloud-init re-executing, which it will not
# (see header comment). Idempotent: the script itself guards every
# docker/network operation, so re-running this -- e.g. after editing the
# script and re-applying -- never fails on "container name already in use"
# and never duplicates state.
#
# Requires the AWS CLI and jq on the machine running `terraform apply`
# (not the instance role) with ssm:SendCommand / ssm:GetCommandInvocation
# permission. Provisioners only run on apply, never on plan/test, so this
# is inert for the offline gates.
resource "null_resource" "jenkins_provision" {
  triggers = {
    script_sha  = sha256(local.jenkins_provision_script)
    instance_id = aws_instance.drone.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      payload_file=$(mktemp)
      trap 'rm -f "$payload_file"' EXIT
      jq -n --rawfile s "${local_file.jenkins_provision_script.filename}" --arg iid "${aws_instance.drone.id}" \
        '{"InstanceIds":[$iid],"DocumentName":"AWS-RunShellScript","Comment":"cv-infra T-002: provision Jenkins + reverse proxy","Parameters":{"commands":[$s]}}' \
        >"$payload_file"
      cmd_id=$(aws ssm send-command --region "${var.aws_region}" \
        --cli-input-json "file://$payload_file" \
        --query "Command.CommandId" --output text)
      aws ssm wait command-executed --region "${var.aws_region}" \
        --command-id "$cmd_id" --instance-id "${aws_instance.drone.id}"
    EOT
  }

  depends_on = [
    aws_eip_association.drone,
    aws_ssm_parameter.jenkins_admin_password,
    aws_ssm_parameter.github_pat_ci,
    local_file.jenkins_provision_script,
  ]
}
