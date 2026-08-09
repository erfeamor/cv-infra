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

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      id         = "123456789012"
      user_id    = "AIDACKCEVSQ6C2EXAMPLE"
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

  # T-011: no defaults on these two by design (see variables.tf) -- test
  # values only, never a number that could pass for the real T-010 figure.
  budget_limit_amount        = "1"
  budget_notification_emails = ["test-budget-alerts@example.com"]
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

  # --- T-011: budget alarm that fires on gross usage, not net-of-credit ---

  # O1 -- the crux. A regression here silently makes the whole feature a
  # no-op: aws_budgets_budget defaults include_credit = true (net cost),
  # which reads $0 on this account until the credit pool is exhausted.
  assert {
    condition     = aws_budgets_budget.gross_usage.cost_types[0].include_credit == false
    error_message = "aws_budgets_budget must track GROSS usage (cost_types.include_credit = false) -- net cost reads $0 on this account until credits run out"
  }

  # O2 -- resource shape.
  assert {
    condition     = aws_budgets_budget.gross_usage.budget_type == "COST" && aws_budgets_budget.gross_usage.limit_unit == "USD"
    error_message = "Budget must be a COST budget denominated in USD"
  }

  # O3 -- limit must trace to a variable, not a literal baked into the
  # resource block (the real figure is T-010's measured console read).
  assert {
    condition     = aws_budgets_budget.gross_usage.limit_amount == var.budget_limit_amount
    error_message = "limit_amount must come from var.budget_limit_amount, not a literal in budgets.tf"
  }

  # O4 -- both notification types must be present: forecast buys warning
  # time at the known ~$0.92/day burn rate, actual confirms it.
  assert {
    condition = (
      contains([for n in aws_budgets_budget.gross_usage.notification : n.notification_type], "ACTUAL") &&
      contains([for n in aws_budgets_budget.gross_usage.notification : n.notification_type], "FORECASTED")
    )
    error_message = "Budget must have at least one ACTUAL and one FORECASTED notification"
  }

  # O5 -- wrong operator here fires immediately (LESS_THAN) or never
  # (a stray EQUAL_TO) -- classic copy-paste bug.
  assert {
    condition     = alltrue([for n in aws_budgets_budget.gross_usage.notification : n.comparison_operator == "GREATER_THAN"])
    error_message = "Every notification must use comparison_operator = GREATER_THAN"
  }

  # O6 -- a budget alarm that notifies nobody is worse than no budget.
  # Checked at both ends: the human-facing subscriber list is non-empty and
  # sourced from a variable (not hardcoded), and it actually drives an SNS
  # subscription per address (DoR decision 3: SNS over a bare email
  # subscriber, because its confirmation state is CLI-queryable).
  assert {
    condition     = length(var.budget_notification_emails) > 0
    error_message = "budget_notification_emails must be non-empty"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.budget_alerts_email) == length(var.budget_notification_emails)
    error_message = "One aws_sns_topic_subscription must exist per address in var.budget_notification_emails"
  }

  # O7 -- NOT tested here, deliberately, same documented limitation as
  # aws_eip.drone.public_ip above: aws_sns_topic.budget_alerts.arn is
  # unknown-until-apply under `command = plan`, and it feeds
  # subscriber_sns_topic_arns on every notification block, so nothing
  # downstream of that ARN is assertable under mock_provider's plan output
  # either. A real check needs a `command = apply` run (safe under
  # mock_provider) or S1/S5 at stage 4 against the live account -- not
  # invented here, per the task's own instruction not to add one.

  # O8 -- thresholds must be > 0 and ascending, catching an
  # inverted/duplicate threshold. The notification block is a TypeSet
  # (confirmed via `terraform providers schema -json`), so its plan-output
  # order is not guaranteed to reflect declaration order -- asserting
  # "ascending" against that iteration order would be asserting on
  # undefined behaviour. Instead this asserts ascending against
  # var.budget_notification_thresholds itself (also enforced by its own
  # `validation` block in variables.tf, so this is redundant-on-purpose
  # belt-and-braces) -- the source local.budget_notifications, and
  # therefore every notification block, is built directly from that list --
  # plus a direct, order-independent check that every threshold reaching
  # the resource is > 0.
  assert {
    condition = alltrue([
      for i in range(length(var.budget_notification_thresholds) - 1) :
      var.budget_notification_thresholds[i] < var.budget_notification_thresholds[i + 1]
    ])
    error_message = "budget_notification_thresholds must be strictly ascending -- an inverted or duplicate threshold either fires immediately or never"
  }

  assert {
    condition     = alltrue([for n in aws_budgets_budget.gross_usage.notification : n.threshold > 0])
    error_message = "Every notification threshold must be > 0"
  }
}
