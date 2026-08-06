# Run with: terraform test
# Uses a mocked AWS provider so the plan runs without credentials or network
# access — data sources return the mock defaults below.

mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = {
      id = "vpc-00000000000000000"
    }
  }

  mock_data "aws_subnets" {
    defaults = {
      ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
    }
  }

  mock_data "aws_ami" {
    defaults = {
      id = "ami-00000000000000000"
    }
  }
}

variables {
  db_password                = "test-password-not-real"
  drone_rpc_secret           = "test-rpc-secret-not-real"
  drone_github_client_id     = "test-client-id"
  drone_github_client_secret = "test-client-secret-not-real"
  jenkins_admin_password     = "test-jenkins-password-not-real"
  github_pat_ci              = "test-github-pat-not-real"
}

run "plan_succeeds" {
  command = plan

  # MySQL is self-hosted on the domain-service EC2 (see compute.tf /
  # templates/domain-service-user-data.sh) — there is no RDS instance to
  # assert on anymore.
  assert {
    condition     = aws_instance.domain_service.instance_type == var.domain_service_instance_type
    error_message = "EC2 instance type should come from var.domain_service_instance_type"
  }

  assert {
    condition     = aws_instance.domain_service.iam_instance_profile == aws_iam_instance_profile.domain_service.name
    error_message = "EC2 must carry the instance profile that grants SSM access"
  }

  assert {
    condition     = aws_instance.drone.instance_type == var.drone_instance_type
    error_message = "Drone instance type should come from var.drone_instance_type (Free Tier)"
  }

  assert {
    condition     = aws_instance.drone.iam_instance_profile == aws_iam_instance_profile.drone.name
    error_message = "Drone host must carry the instance profile that grants SSM access"
  }

  assert {
    condition     = !contains([for rule in aws_security_group.drone.ingress : rule.from_port], 22)
    error_message = "No SSH ingress on the Drone host — shell access is SSM Session Manager only"
  }

  # T-002: Jenkins must never get its own internet-facing ingress rule — it
  # is reached only via the reverse proxy on the existing 80 rule.
  assert {
    condition     = !contains([for rule in aws_security_group.drone.ingress : rule.from_port], 8080)
    error_message = "No direct ingress rule for the raw Jenkins port — it must stay behind the reverse proxy on 80/443"
  }

  assert {
    condition     = length([for rule in aws_security_group.drone.ingress : rule]) == 2
    error_message = "Drone SG should still expose exactly 80 and 443 — Jenkins must not add a third ingress rule"
  }

  # H1 decision 2: sizing exception, recorded here and in variables.tf / the PR.
  assert {
    condition     = aws_instance.drone.instance_type == "t3.small"
    error_message = "Drone/Jenkins host must be t3.small per the ratified T-002 Free Tier exception"
  }

  assert {
    condition     = aws_ssm_parameter.jenkins_admin_password.type == "SecureString"
    error_message = "Jenkins admin password must be stored as a SecureString"
  }

  assert {
    condition     = aws_ssm_parameter.github_pat_ci.type == "SecureString"
    error_message = "The Jenkins GitHub PAT must be stored as a SecureString"
  }

  assert {
    condition     = aws_ssm_parameter.github_pat_ci.name == "/${var.project_name}/${var.environment}/ci/github-pat"
    error_message = "The Jenkins GitHub PAT must follow the existing /project/env/ci/... SSM naming convention"
  }

  # NOT tested here, deliberately: whether the Jenkins multibranch job
  # configs declare traits{} (and never gitHubForkDiscovery) lives inside
  # local.jenkins_provision_script, which embeds aws_eip.drone.public_ip
  # (via templatefile's server_host argument). That EIP doesn't exist yet
  # in this run's plan, so its public_ip -- and therefore the whole
  # rendered string -- is unknown-until-apply, not just at this specific
  # spot but for the entire templatefile() output. Terraform test's
  # `command = plan` cannot evaluate a condition against an unknown value
  # (confirmed by trying: "Condition expression could not be evaluated...
  # execute an `apply` command from this `run` block"), so no assertion
  # against this local's content -- strong or weak -- has purchase here.
  # A real check would need a `command = apply` run (safe under
  # mock_provider, since nothing real gets created, but a bigger change to
  # this test file's structure than this directed fix warrants) or a
  # parallel test-only render that doesn't actually verify the deployed
  # artifact. Left for a future task rather than invented here.

  # Review finding N5: catches a copy-paste that assigns the wrong variable
  # to a secret parameter -- it would otherwise pass every assertion above.
  assert {
    condition     = aws_ssm_parameter.github_pat_ci.value == var.github_pat_ci
    error_message = "aws_ssm_parameter.github_pat_ci must store var.github_pat_ci, not some other variable"
  }

  assert {
    condition     = aws_ssm_parameter.jenkins_admin_password.value == var.jenkins_admin_password
    error_message = "aws_ssm_parameter.jenkins_admin_password must store var.jenkins_admin_password, not some other variable"
  }

  # Review finding N5: this is the single load-bearing invariant of the
  # whole out-of-band-provisioning approach (H1 decision 1) -- if this ever
  # flips to true, aws_instance.drone gets destroyed/recreated on every
  # user_data edit instead of being provisioned out-of-band, wiping Drone's
  # SQLite state. Assert it explicitly so a future edit can't reintroduce it
  # silently.
  assert {
    # Left unset in config, this attribute plans as null rather than a
    # resolved false -- assert it's not explicitly true rather than
    # requiring exact equality with false.
    condition     = aws_instance.drone.user_data_replace_on_change != true
    error_message = "aws_instance.drone must NOT set user_data_replace_on_change -- Jenkins is provisioned out-of-band via SSM specifically so this box is never replaced (H1 decision 1)"
  }

  assert {
    condition     = aws_ecr_repository.domain_service.name == "${var.project_name}-domain-service"
    error_message = "ECR repository name must follow the project prefix convention"
  }

  assert {
    condition     = contains([for b in aws_cloudfront_distribution.frontend.ordered_cache_behavior : b.path_pattern], "/api/*")
    error_message = "CloudFront must route /api/* to the domain service (mixed-content fix for the SPAs)"
  }
}
