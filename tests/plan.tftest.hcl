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

  # T-022: the CloudFront origin-facing managed prefix list. Mocked so the
  # 8080 ingress can be asserted offline; the real list is AWS-owned and its
  # id differs per region (pl-75b1541c in eu-west-3).
  mock_data "aws_ec2_managed_prefix_list" {
    defaults = {
      id   = "pl-00000000000000000"
      name = "com.amazonaws.global.cloudfront.origin-facing"
    }
  }

  mock_data "aws_ami" {
    defaults = {
      id           = "ami-00000000000000000"
      architecture = "x86_64"
    }
  }

  # T-034 phase 2: the human's real, pre-existing hosted zone (erfeamor.com,
  # Z0608270B7WND031GVOW) -- read as a data source, never imported (dns.tf).
  # Mocked so dns.tf's record/IAM can be asserted offline; the real zone's
  # arn/zone_id are account facts, not something this module computes.
  mock_data "aws_route53_zone" {
    defaults = {
      zone_id = "Z0608270B7WND031GVOW"
      arn     = "arn:aws:route53:::hostedzone/Z0608270B7WND031GVOW"
      name    = "erfeamor.com."
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

# T-035: the app host's AMI lookup is a separate data source from the CI
# host's; the shared mock above defaults to x86_64, so the arm64 one gets its
# own value (what the real lookup returns for the arm64 name + filter).
override_data {
  target = data.aws_ami.al2023_arm64
  values = {
    id           = "ami-00000000000000001"
    architecture = "arm64"
  }
}

variables {
  db_password                = "test-password-not-real"
  drone_rpc_secret           = "test-rpc-secret-not-real"
  drone_github_client_id     = "test-client-id"
  drone_github_client_secret = "test-client-secret-not-real"
  jenkins_admin_password     = "test-jenkins-password-not-real"
  github_pat_ci              = "test-github-pat-not-real"
  github_webhook_secret      = "test-webhook-secret-not-real"
  github_hooks_token         = "test-hooks-token-not-real"

  # T-035: pinned here so a local terraform.tfvars (which `terraform test`
  # also loads) can't change what the plan assertions see.
  domain_service_instance_type = "t4g.micro"

  # T-011: no default on budget_credit_grant_amount by design (see
  # variables.tf) -- test value only, never a number that could pass for a
  # real measured figure. budget_monthly_limit_amount is given a distinct
  # test value too (rather than relying on its real default of "30") so a
  # regression that wires the SAME variable into both budgets' limit_amount
  # -- a real bug this scope amendment fixed -- makes the identity
  # assertions below fail instead of coincidentally matching. Same trick
  # for the two threshold variables: credit_runway's and gross_usage's are
  # given disjoint test values so a regression that swaps them (the second
  # real bug this amendment fixed, caught at stage 4 against the live
  # account) fails loudly too.
  budget_credit_grant_amount      = "160"
  budget_monthly_limit_amount     = "30"
  budget_credit_runway_thresholds = [50, 80, 100]
  budget_monthly_thresholds       = [100, 120, 150]
  budget_notification_emails      = ["test-budget-alerts@example.com"]
}

run "plan_succeeds" {
  command = plan

  # Review round 1, finding 4: mock_data "aws_subnets" applies one
  # `defaults` block to EVERY aws_subnets data source, so without this
  # override, data.aws_subnets.default.ids and
  # data.aws_subnets.domain_service.ids are the identical, already-sorted
  # list under test -- the subnet regression guard below would pass just as
  # well if compute.tf were reverted to data.aws_subnets.default.ids[0]
  # (the reviewer proved this empirically). Give the pinned data source its
  # own, distinct value so that assertion actually distinguishes "wired
  # from the pinned source" from "wired from the old unordered one".
  override_data {
    target = data.aws_subnets.domain_service
    values = {
      ids = ["subnet-00000000000000009"]
    }
  }

  # MySQL is self-hosted on the domain-service EC2 (see compute.tf /
  # templates/domain-service-provision.sh) — there is no RDS instance to
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

  # NOT tested here: whether the Jenkins multibranch job configs declare
  # traits{} (and never gitHubForkDiscovery) lives inside
  # local.jenkins_provision_script. T-034 phase 2 incidentally RESOLVED the
  # reason this used to be untestable (it embedded aws_eip.drone.public_ip,
  # unknown-until-apply for the whole rendered string) -- it now renders from
  # var.ci_hostname and data.aws_route53_zone.ci.zone_id, both known at plan
  # time under this file's mocks, so `local.jenkins_provision_script` itself
  # is a genuinely knowable string here now. Still not asserted against
  # directly: doing so is an improvement orthogonal to phase 2's own scope,
  # left for a future task rather than invented here. The "ci_on_demand" run
  # below (periodicFolderTrigger, the 8 KB wall) already exercises a
  # PARALLEL re-render with fixture values instead, which is why it still
  # needs its own separate templatefile() call.

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

  # O3 -- limit must trace to gross_usage's OWN variable, not a literal
  # baked into the resource block, and NOT credit_runway's variable -- the
  # two budgets sharing a limit variable was a real bug caught before the
  # first apply (a credit-pot-sized MONTHLY limit against ~$28/month burn
  # never crosses even the 50% threshold). The mock values for the two
  # variables are deliberately distinct ("30" vs "160"), so a regression
  # that wires the wrong one in fails this instead of passing by
  # coincidence.
  assert {
    condition     = aws_budgets_budget.gross_usage.limit_amount == var.budget_monthly_limit_amount
    error_message = "gross_usage.limit_amount must come from var.budget_monthly_limit_amount, not a literal or var.budget_credit_grant_amount"
  }

  # O2b -- gross_usage must stay MONTHLY: it's the anomaly detector now,
  # not the credit-runway tracker (credit_runway, asserted further below,
  # covers ANNUALLY).
  assert {
    condition     = aws_budgets_budget.gross_usage.time_unit == "MONTHLY"
    error_message = "gross_usage must remain a MONTHLY budget -- it detects burn acceleration, not credit exhaustion"
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

  # Finding 7 (review round 1): if threshold_type were flipped to
  # ABSOLUTE_VALUE, threshold 50 would silently mean $50 instead of 50%,
  # and against a ~$28/month budget nothing would ever fire -- without this
  # assert, none of O1-O6/O8 would have caught it.
  assert {
    condition     = alltrue([for n in aws_budgets_budget.gross_usage.notification : n.threshold_type == "PERCENTAGE"])
    error_message = "Every notification must use threshold_type = PERCENTAGE, not ABSOLUTE_VALUE"
  }

  # O6 -- a budget alarm that notifies nobody is worse than no budget.
  # Checked at both ends: the human-facing subscriber list is non-empty and
  # sourced from a variable (not hardcoded), and it actually drives an SNS
  # subscription for each address (DoR decision 3: SNS over a bare email
  # subscriber, because its confirmation state is CLI-queryable).
  assert {
    condition     = length(var.budget_notification_emails) > 0
    error_message = "budget_notification_emails must be non-empty"
  }

  # Finding 2 (review round 1): a prior version of this assert compared
  # cardinality only (length == length), which passes identically whether
  # aws_sns_topic_subscription.budget_alerts_email's for_each is keyed by
  # var.budget_notification_emails or by an equally-sized but wrong,
  # hardcoded set of addresses -- QA proved this empirically. Compare
  # identity (the actual key sets), not just count.
  assert {
    condition     = toset(keys(aws_sns_topic_subscription.budget_alerts_email)) == toset(var.budget_notification_emails)
    error_message = "aws_sns_topic_subscription.budget_alerts_email must have exactly one entry per address in var.budget_notification_emails -- same addresses, not just same count"
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
  # undefined behaviour (QA confirmed: the unknown SNS topic ARN feeding
  # subscriber_sns_topic_arns on every notification block makes ordered
  # iteration over that set unreliable). So the ascending check below runs
  # against var.budget_monthly_thresholds (gross_usage's OWN thresholds
  # variable, not credit_runway's -- see the scope amendment further below)
  # -- also enforced by its own `validation` block in variables.tf, kept
  # here too as a directed regression check, not "redundant-on-purpose
  # belt-and-braces": on its own, asserting ascending-ness of the *variable*
  # proves nothing about the *resource* it's meant to feed (review round 1,
  # finding 3 -- QA proved this empirically by swapping the loop source for
  # a literal while the variable stayed unchanged and the suite still
  # passed). The set-equality assert immediately below is what actually
  # ties the two together, order-independently and plan-evaluably.
  assert {
    condition = alltrue([
      for i in range(max(length(var.budget_monthly_thresholds) - 1, 0)) :
      var.budget_monthly_thresholds[i] < var.budget_monthly_thresholds[i + 1]
    ])
    error_message = "budget_monthly_thresholds must be strictly ascending -- an inverted or duplicate threshold either fires immediately or never"
  }

  # Order-independent identity check: the set of threshold values actually
  # reaching the resource must equal the set from gross_usage's OWN
  # variable (budget_monthly_thresholds), and -- because the mock values
  # for the two threshold variables are deliberately disjoint ([100, 120,
  # 150] vs [50, 80, 100]) -- NOT equal to credit_runway's
  # (budget_credit_runway_thresholds). This is what proves
  # local.gross_usage_notifications wasn't built from some other source (a
  # stray literal, a stale copy, or -- the real bug this scope amendment
  # fixes -- credit_runway's thresholds variable).
  assert {
    condition     = toset([for n in aws_budgets_budget.gross_usage.notification : n.threshold]) == toset(var.budget_monthly_thresholds)
    error_message = "gross_usage notification thresholds must be exactly the set of values in var.budget_monthly_thresholds, not var.budget_credit_runway_thresholds"
  }

  assert {
    condition     = alltrue([for n in aws_budgets_budget.gross_usage.notification : n.threshold > 0])
    error_message = "Every notification threshold must be > 0"
  }

  # --- T-011 scope amendment (2026-08-09): aws_budgets_budget.credit_runway,
  # the cumulative credit-pot tracker added alongside the resized
  # gross_usage anomaly detector above. Same rigour, same crux, per-resource
  # rather than assumed-shared. ---

  # Crux, on the new resource too (the task's own instruction, not
  # optional): a regression here silently makes THIS budget a no-op the
  # same way it would for gross_usage -- net cost reads $0 against the
  # credit pot until the pot itself is gone, which is exactly the moment
  # this budget exists to warn about in advance.
  assert {
    condition     = aws_budgets_budget.credit_runway.cost_types[0].include_credit == false
    error_message = "aws_budgets_budget.credit_runway must track GROSS usage (cost_types.include_credit = false) -- net cost reads $0 against the credit pot until it's already gone"
  }

  assert {
    condition     = aws_budgets_budget.credit_runway.cost_types[0].include_refund == false
    error_message = "aws_budgets_budget.credit_runway must exclude refunds too (cost_types.include_refund = false) -- same metric-masking failure mode as include_credit"
  }

  # Resource shape, including the amendment's actual point: ANNUALLY, not
  # MONTHLY -- this tracks a cumulative pot, not a per-month allowance.
  assert {
    condition     = aws_budgets_budget.credit_runway.budget_type == "COST" && aws_budgets_budget.credit_runway.limit_unit == "USD"
    error_message = "credit_runway must be a COST budget denominated in USD"
  }

  assert {
    condition     = aws_budgets_budget.credit_runway.time_unit == "ANNUALLY"
    error_message = "credit_runway must be ANNUALLY -- it tracks the cumulative credit pot, not a monthly allowance (that's gross_usage's job)"
  }

  # limit_amount must trace to credit_runway's OWN variable, not
  # gross_usage's -- the two sharing one variable was a real bug. Mock
  # values for the two variables are deliberately distinct (see the
  # variables{} block above), so a regression that wires the wrong one in
  # fails here.
  assert {
    condition     = aws_budgets_budget.credit_runway.limit_amount == var.budget_credit_grant_amount
    error_message = "credit_runway.limit_amount must come from var.budget_credit_grant_amount, not a literal or var.budget_monthly_limit_amount"
  }

  # time_period_start must be set and in AWS Budgets' documented format
  # (YYYY-MM-DD_HH:MM). Deliberately NOT pinned to the exact literal chosen
  # in budgets.tf (2026-08-01_00:00) -- that value is time-relative by
  # nature (see the honesty comment in budgets.tf) and pinning it here would
  # make this assertion fail for a reason that has nothing to do with a
  # regression the day this file is next touched.
  assert {
    condition     = aws_budgets_budget.credit_runway.time_period_start != null && can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}:[0-9]{2}$", aws_budgets_budget.credit_runway.time_period_start))
    error_message = "credit_runway.time_period_start must be set, in AWS Budgets' documented YYYY-MM-DD_HH:MM format"
  }

  # Notification shape, same as O4/O5/threshold_type on gross_usage: both
  # ACTUAL and FORECASTED, GREATER_THAN, PERCENTAGE -- not re-derived from
  # gross_usage's assertions because a regression scoped to just this
  # resource's dynamic block wouldn't otherwise be caught.
  assert {
    condition = (
      contains([for n in aws_budgets_budget.credit_runway.notification : n.notification_type], "ACTUAL") &&
      contains([for n in aws_budgets_budget.credit_runway.notification : n.notification_type], "FORECASTED")
    )
    error_message = "credit_runway must have at least one ACTUAL and one FORECASTED notification"
  }

  assert {
    condition     = alltrue([for n in aws_budgets_budget.credit_runway.notification : n.comparison_operator == "GREATER_THAN"])
    error_message = "Every credit_runway notification must use comparison_operator = GREATER_THAN"
  }

  assert {
    condition     = alltrue([for n in aws_budgets_budget.credit_runway.notification : n.threshold_type == "PERCENTAGE"])
    error_message = "Every credit_runway notification must use threshold_type = PERCENTAGE, not ABSOLUTE_VALUE"
  }

  # Same shared-variable regression guard as gross_usage's O8-equivalent
  # above, mirrored: must trace to credit_runway's OWN thresholds variable
  # (budget_credit_runway_thresholds), NOT gross_usage's
  # (budget_monthly_thresholds) -- the mock values are deliberately
  # disjoint ([50, 80, 100] vs [100, 120, 150]), so a regression that swaps
  # them (the stage-4 finding: a console budget with shared thresholds
  # stuck permanently in ALARM) fails this instead of passing by
  # coincidence.
  assert {
    condition     = toset([for n in aws_budgets_budget.credit_runway.notification : n.threshold]) == toset(var.budget_credit_runway_thresholds)
    error_message = "credit_runway notification thresholds must be exactly the set of values in var.budget_credit_runway_thresholds, not var.budget_monthly_thresholds"
  }

  assert {
    condition     = alltrue([for n in aws_budgets_budget.credit_runway.notification : n.threshold > 0])
    error_message = "Every credit_runway notification threshold must be > 0"
  }

  # Not tested here, deliberately, same O7 limitation documented above for
  # gross_usage: aws_sns_topic.budget_alerts.arn is unknown-until-apply
  # under `command = plan`, so subscriber_sns_topic_arns on credit_runway's
  # notification blocks isn't assertable here either. Same S1/S5 stage-4
  # coverage applies to this resource too.

  # --- T-001: mysqldump -> S3 nightly backup, replacing RDS's managed
  # backups for the self-hosted MySQL container ---

  assert {
    condition     = aws_s3_bucket.backup.bucket == "${var.project_name}-mysql-backup-${var.environment}"
    error_message = "Backup bucket name must follow the project/environment naming convention"
  }

  # Crux of the "block ALL public access" requirement -- same posture as
  # aws_s3_bucket_public_access_block.frontend.
  assert {
    condition = (
      aws_s3_bucket_public_access_block.backup.block_public_acls == true &&
      aws_s3_bucket_public_access_block.backup.block_public_policy == true &&
      aws_s3_bucket_public_access_block.backup.ignore_public_acls == true &&
      aws_s3_bucket_public_access_block.backup.restrict_public_buckets == true
    )
    error_message = "Backup bucket must block ALL public access -- all four settings must be true"
  }

  # aws_s3_bucket.backup.id/.arn and everything downstream of them (the
  # public access block's own `bucket` link, the IAM policy's rendered JSON,
  # aws_instance.domain_service.user_data) are unknown-until-apply under
  # `command = plan` -- same documented limitation as aws_eip.drone.public_ip
  # and aws_sns_topic.budget_alerts.arn above. Those checks live in the
  # `command = apply` run block below instead (safe under mock_provider,
  # since nothing real gets created).

  # Retention: a handful of daily dumps, not indefinite accumulation --
  # credit-funded (T-010), so this must stay negligible.
  assert {
    condition = anytrue([
      for rule in aws_s3_bucket_lifecycle_configuration.backup.rule :
      rule.status == "Enabled" && rule.expiration[0].days > 0 && rule.expiration[0].days <= 14
    ])
    error_message = "Backup bucket must have an enabled lifecycle rule expiring dumps within roughly two weeks -- retention should stay negligible against the credit burn"
  }

  # The lifecycle rule must actually scope to the backup prefix -- an
  # unscoped rule would still pass a naive "does a rule exist" check but
  # wouldn't prove it targets the right objects.
  assert {
    condition = anytrue([
      for rule in aws_s3_bucket_lifecycle_configuration.backup.rule :
      length(rule.filter) > 0 && rule.filter[0].prefix == "${local.mysql_backup_prefix}/"
    ])
    error_message = "The expiration rule must filter on the mysql-dumps/ prefix"
  }

  # --- T-018: MySQL's data directory moves onto a dedicated EBS volume ---

  # Ruling 1, the crux: the instance's subnet and the volume's AZ must trace
  # to the SAME pinned source (var.availability_zone) so they can never
  # diverge -- an EBS volume is AZ-locked.
  assert {
    condition     = aws_ebs_volume.mysql_data.availability_zone == var.availability_zone
    error_message = "aws_ebs_volume.mysql_data.availability_zone must come from var.availability_zone -- the same pinned source that selects aws_instance.domain_service's subnet, never a separately-computed AZ"
  }

  # Proves the instance's subnet is actually wired from the new pinned data
  # source (network.tf), not still off data.aws_subnets.default's unordered
  # list -- a regression here would silently reintroduce the AZ-drift risk
  # ruling 1 exists to close.
  assert {
    condition     = aws_instance.domain_service.subnet_id == sort(data.aws_subnets.domain_service.ids)[0]
    error_message = "aws_instance.domain_service.subnet_id must come from data.aws_subnets.domain_service (filtered on var.availability_zone), not data.aws_subnets.default"
  }

  # Regression guard, mirrored from the equivalent Drone assertion but with
  # the opposite polarity: unlike Drone (provisioned out-of-band, must NEVER
  # replace), the domain-service box MUST keep replacing on user_data edits
  # -- that's what makes this task's own acceptance criterion (apply twice,
  # prove the database survives replacement) a real test rather than a no-op.
  assert {
    condition     = aws_instance.domain_service.user_data_replace_on_change == true
    error_message = "aws_instance.domain_service must keep user_data_replace_on_change = true -- removing it means a bootstrap edit never re-provisions the box (this bug has shipped once already)"
  }

  assert {
    condition     = aws_ebs_volume.mysql_data.size == 8 && aws_ebs_volume.mysql_data.type == "gp3"
    error_message = "aws_ebs_volume.mysql_data should stay an 8 GiB gp3 volume -- a size/class bump is cost drift and needs an explicit, recorded decision (CLAUDE.md review guidance)"
  }

  assert {
    condition     = aws_ebs_volume.mysql_data.encrypted == true
    error_message = "aws_ebs_volume.mysql_data must be encrypted at rest"
  }

  # aws_volume_attachment.mysql_data.volume_id/.instance_id and
  # aws_ebs_volume.mysql_data.id are unknown-until-apply under `command =
  # plan` (same documented limitation as aws_s3_bucket.backup.arn and
  # aws_eip.drone.public_ip above), and targeting them for a `command =
  # apply` run pulls in aws_instance.domain_service -> its user_data ->
  # aws_cloudfront_distribution.frontend, which is the exact combination
  # already confirmed (see the backup_iam_scoping run's own comment) to fail
  # at destroy/teardown under mock_provider. So the attachment's wiring
  # (right volume, right instance) is covered by `terraform validate` +
  # code review instead of an assertion here, deliberately, not omitted by
  # oversight.
  assert {
    condition     = aws_volume_attachment.mysql_data.device_name == "/dev/sdf"
    error_message = "aws_volume_attachment.mysql_data.device_name is a Terraform/EC2-API label only -- nitro remaps it at the kernel, see ruling 2 -- kept stable here so a change doesn't go unnoticed"
  }

}

# --- T-001 identity/ARN assertions, run under `command = apply` ---
# aws_s3_bucket.backup.arn/.id and aws_iam_role.domain_service.id are
# computed and unknown-until-apply, so the assertions that actually prove
# IAM scoping (the ones a reviewer will check hardest) need an applied plan
# to have concrete values to compare -- same rationale as the O7/N5 comments
# above. mock_provider makes an apply of these two resources safe -- EXCEPT
# that an unscoped/full-module apply would also create
# null_resource.jenkins_provision (ci.tf), whose local-exec provisioner
# shells out to real `aws ssm` commands regardless of the AWS provider being
# mocked (confirmed empirically: it ran for real and only failed because the
# mock instance ID doesn't exist). plan_options.target below restricts this
# run to exactly the two backup resources and their dependencies, so
# aws_instance.drone / null_resource.jenkins_provision are never reached.
run "backup_iam_scoping" {
  command = apply

  plan_options {
    target = [
      aws_iam_role_policy.mysql_backup_upload,
      aws_s3_bucket_public_access_block.backup,
    ]
  }

  assert {
    condition     = aws_iam_role_policy.mysql_backup_upload.role == aws_iam_role.domain_service.id
    error_message = "The backup upload policy must attach to the domain_service role -- that's the role the backup timer runs under"
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.mysql_backup_upload.policy).Statement[0].Action == ["s3:PutObject"]
    error_message = "The backup upload policy must grant only s3:PutObject -- not s3:*, not a broader action set"
  }

  # The assertion a reviewer will check hardest (task's own words): the
  # Resource ARN must visibly show scoping to the backup prefix -- not the
  # bucket root, not a wildcard bucket ARN, not s3:*.
  assert {
    condition     = jsondecode(aws_iam_role_policy.mysql_backup_upload.policy).Statement[0].Resource == "${aws_s3_bucket.backup.arn}/${local.mysql_backup_prefix}/*"
    error_message = "The backup upload policy's Resource must be scoped to the backup bucket's mysql-dumps/ prefix specifically -- not the bucket ARN alone (bucket root) and not a bare wildcard"
  }

  # Negative check: the Resource must NOT be the bucket ARN by itself (that
  # would grant PutObject bucket-wide, defeating prefix scoping).
  assert {
    condition     = jsondecode(aws_iam_role_policy.mysql_backup_upload.policy).Statement[0].Resource != aws_s3_bucket.backup.arn
    error_message = "The backup upload policy's Resource must not be the bare bucket ARN -- that grants PutObject bucket-wide instead of prefix-scoped"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.backup.bucket == aws_s3_bucket.backup.id
    error_message = "The public access block must target the backup bucket, not some other bucket"
  }

  # NOT tested here, deliberately, same O7/N5-style limitation documented
  # above: proving aws_instance.domain_service.user_data actually contains
  # the backup bucket name would need targeting the instance itself, which
  # pulls in aws_cloudfront_distribution.frontend and its dependents --
  # confirmed empirically to fail at destroy/teardown under mock_provider
  # (invalid mock ARN format rejected by aws_cloudfront_function's
  # function_association). The wiring is covered by `terraform validate` +
  # code review instead of an assertion here.
}

# ---------------------------------------------------------------------------
# T-019 -- on-demand CI host. The doorbell is an unauthenticated public
# endpoint that can start EC2 instances, so most of what follows is about
# proving the blast radius stays small when someone edits this later.
# ---------------------------------------------------------------------------
run "ci_on_demand" {
  command = plan

  # --- The size wall, now enforced at T-009's threshold ---------------------
  # Tightened from 16,384 to 8,192 once T-009 moved jenkins-provision.sh to S3:
  # the render dropped from 16,104 B (98.3%) to roughly 3 KB, so an 8 KB ceiling
  # leaves generous room while still failing long BEFORE the real EC2 limit.
  # Exceeding 16,384 is not caught by fmt, validate or a mocked plan -- it
  # surfaces as an apply-time API rejection on the live CI host, which is a far
  # worse place to discover it than a red test.
  assert {
    condition = length(join("\n", [
      templatefile("${path.module}/templates/drone-user-data.sh", {
        aws_region     = var.aws_region
        project_name   = var.project_name
        environment    = var.environment
        ci_hostname    = "203.0.113.10"
        admin_username = var.drone_admin_username
      }),
      templatefile("${path.module}/templates/jenkins-bootstrap.sh", {
        aws_region      = var.aws_region
        project_name    = var.project_name
        environment     = var.environment
        artifact_bucket = "test-bucket"
        artifact_key    = "jenkins-provision.sh"
      }),
    ])) < 8192
    error_message = "Rendered user_data for aws_instance.drone exceeds 8 KB. The provisioning script already lives in S3 (T-009), so something substantial has been inlined back into user_data -- move it out rather than trimming comments to fit."
  }

  # Ruling 1: the periodic scan is what makes the doorbell able to stay a pure
  # doorbell. Delete it and every cold start silently builds nothing.
  assert {
    condition = length(regexall("periodicFolderTrigger", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 2
    error_message = "Both multibranch jobs must carry a periodicFolderTrigger -- without it a push that arrives while the CI host is stopped is never built (T-019 ruling 1)"
  }

  # --- T-034 phase 2 + T-033 (case 10): Caddyfile routing parity with the old
  # nginx config, checked against the actual rendered template content, not a
  # separate hand-copied fixture. ---------------------------------------------
  assert {
    condition = length(regexall("handle /jenkins/\\* \\{[^}]*reverse_proxy jenkins:8080", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 1
    error_message = "The Caddyfile must route /jenkins/* to jenkins:8080 via `handle` (not `handle_path`, which would strip the prefix --prefix=/jenkins expects)"
  }

  assert {
    condition = length(regexall("reverse_proxy drone-server:80", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 1
    error_message = "The Caddyfile must route everything else (GitHub /hook, Drone OAuth) to drone-server:80, unchanged from the old nginx `location /`"
  }

  # --- Case 11: the HTTP->HTTPS redirect is explicit, not left implicit -----
  assert {
    condition = length(regexall("redir https://\\{host\\}\\{uri\\} permanent", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 1
    error_message = "The Caddyfile must carry an explicit permanent HTTP->HTTPS redirect, not rely on Caddy's implicit default going ungrepped"
  }

  # --- Certs/state persist on the host, not the container's own filesystem --
  assert {
    condition = length(regexall("-v /var/lib/caddy-data:/data", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 1
    error_message = "ci-proxy must bind-mount its Let's Encrypt cert storage onto the host -- otherwise every stop/start (T-019) or reboot re-issues a certificate, and LE's production CA rate-limits duplicate certs to 5/week"
  }

  # --- Review round 1, finding 1: a catch-all answers non-2xx to any Host
  # that isn't ci_hostname ----------------------------------------------------
  assert {
    condition = length(regexall(":443 \\{[^}]*respond 421", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 1
    error_message = "The Caddyfile must answer a mismatched-Host request on :443 with a non-2xx (421) -- otherwise a misdirected delivery looks like success to GitHub instead of a failure the doorbell would redeliver"
  }

  assert {
    condition = length(regexall(":80 \\{[^}]*respond 421", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 1
    error_message = "The Caddyfile must answer a mismatched-Host request on :80 with a non-2xx (421) too"
  }

  # --- Review round 1, finding 6: no manual header_up lines left -----------
  assert {
    condition = length(regexall("header_up", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 0
    error_message = "No manual header_up lines should remain in the Caddyfile -- Caddy's reverse_proxy defaults already set X-Forwarded-For/Proto/Host correctly"
  }

  # --- Review round 1, finding 2: the re-run timer is present and enabled --
  assert {
    condition = length(regexall("ci-dns-updater\\.timer", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 2 # the unit file is written under its own name, and "systemctl enable --now ci-dns-updater.timer" enables it
    error_message = "ci-dns-updater.timer must be written and enabled, re-running the updater periodically (not just once at boot)"
  }

  assert {
    condition = length(regexall("StartLimitIntervalSec=600", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 1
    error_message = "ci-dns-updater.service must set a start limit (StartLimitIntervalSec, in [Unit]) alongside Restart=on-failure"
  }

  assert {
    condition = length(regexall("OnUnitActiveSec=5min", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 1
    error_message = "The timer must re-run every 5 minutes"
  }

  # --- Review round 1, finding 3: Restart=on-failure with a start limit, and
  # the boot-time enable is not allowed to abort the rest of provisioning --
  assert {
    condition = length(regexall("Restart=on-failure", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 1
    error_message = "ci-dns-updater.service must set Restart=on-failure"
  }

  assert {
    condition = length(regexall("if ! systemctl enable --now ci-dns-updater\\.service", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 1
    error_message = "the boot-time `systemctl enable --now ci-dns-updater.service` must be guarded (an `if !`) so a failure logs loudly but does not abort the rest of provisioning under set -e"
  }

  # --- Review round 2, finding 2(a): the ExecStop sentinel unit ------------
  assert {
    condition = length(regexall("ExecStop=/usr/local/bin/ci-dns-sentinel\\.sh", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 1
    error_message = "ci-dns-sentinel.service must run scripts/ci-dns-sentinel.sh on ExecStop"
  }

  assert {
    condition = length(regexall("RemainAfterExit=yes", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 1
    error_message = "ci-dns-sentinel.service must set RemainAfterExit=yes -- otherwise it's never 'active' for ExecStop to fire against"
  }

  # --- T-041: ExecStop must not race networking down. systemd stops units in
  # the REVERSE of their start order, so After=network-online.target on this
  # unit keeps networkd/resolved up until ExecStop (scripts/ci-dns-sentinel.sh)
  # returns -- Before=docker.service alone only governed START order. Scoped
  # to the ci-dns-sentinel.service block specifically (not just "somewhere in
  # the file"): ci-dns-updater.service already carries the same two lines, so
  # an unscoped count would pass even if this unit never got them.
  assert {
    condition = length(regexall("Description=UPSERT ci\\.example\\.test to a sentinel on shutdown[^\\n]*\\nWants=network-online\\.target\\nAfter=network-online\\.target\\nBefore=docker\\.service", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 1
    error_message = "ci-dns-sentinel.service must set Wants=network-online.target and After=network-online.target (in that order, ahead of Before=docker.service) so ExecStop runs before networking is torn down (T-041)"
  }

  # --- Review round 2, finding 4: the local, never-proxied health path -----
  assert {
    condition = length(regexall("http://localhost \\{[^}]*__ci_proxy_health", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 1
    error_message = "The Caddyfile must serve /__ci_proxy_health on the Host: localhost block, never proxied, so the routing probe has zero TLS/cert/DNS dependency"
  }

  assert {
    condition = length(regexall("-H \"Host: localhost\" \"http://127\\.0\\.0\\.1/__ci_proxy_health\"", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      ci_hostname            = "ci.example.test"
      route53_zone_id        = "Z00000000000000000000"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
      dns_updater_script     = "#!/usr/bin/env bash\necho fixture\n"
      dns_sentinel_script    = "#!/usr/bin/env bash\necho sentinel-fixture\n"
      dns_sentinel_ip        = "192.0.2.1"
    }))) == 1
    error_message = "The routing probe must hit the local health path over plain HTTP with an explicit Host header, not the TLS/--resolve-based /jenkins/login probe (which depends on a certificate existing)"
  }

  # --- T-009: the fetch-and-execute path ------------------------------------
  # The script is executed as root on a host mounting the docker socket, so a
  # publicly readable bucket would be a direct route to controlling what that
  # host runs.
  assert {
    condition = (aws_s3_bucket_public_access_block.ci_artifacts.block_public_acls &&
      aws_s3_bucket_public_access_block.ci_artifacts.block_public_policy &&
      aws_s3_bucket_public_access_block.ci_artifacts.ignore_public_acls &&
    aws_s3_bucket_public_access_block.ci_artifacts.restrict_public_buckets)
    error_message = "The CI artifact bucket must block public access on all four flags -- it holds a script executed as root on the CI host"
  }

  # It must never be staged in the bucket CloudFront serves to the internet.
  assert {
    condition     = aws_s3_bucket.ci_artifacts.bucket != aws_s3_bucket.frontend.bucket
    error_message = "The provisioning script must NOT be staged in the public frontend bucket"
  }

  # NOT asserted, and worth saying why rather than leaving the gap silent:
  # that the S3 object and the SSM-pushed script carry identical bytes, and
  # that the SSM checksum is the hash of what was uploaded. Both are true by
  # construction -- all three read local.jenkins_provision_script, the single
  # expression that renders the script -- but neither is checkABLE here,
  # because that local embeds aws_eip.drone.public_ip and is therefore unknown
  # under `command = plan` (the limitation this file documents in several other
  # places). The real proof is the boot itself: a mismatch makes the bootstrap
  # stub abort with "checksum mismatch" and the box comes up with no Jenkins,
  # which stage 4 exercises directly.

  # Single object, not the bucket, not s3:*.
  assert {
    condition     = join(",", local.drone_provision_s3_actions) == "s3:GetObject"
    error_message = "The CI host's new S3 grant must be s3:GetObject only -- it is read-only access to one artifact"
  }

  # --- Ruling 3: the security boundary -------------------------------------
  # authorization_type = NONE is forced (GitHub cannot sign SigV4), so this
  # assertion is not "NONE is fine" -- it pins the fact that the HMAC check in
  # the handler is the ONLY thing standing in front of ec2:StartInstances.
  assert {
    condition     = aws_lambda_function_url.ci_doorbell.authorization_type == "NONE"
    error_message = "The doorbell Function URL must be NONE (GitHub cannot sign SigV4); its authentication is the HMAC check in lambda/ci_doorbell/index.py"
  }

  assert {
    condition     = aws_lambda_function.ci_doorbell.environment[0].variables["WEBHOOK_SECRET_PARAM"] == aws_ssm_parameter.github_webhook_secret.name
    error_message = "The doorbell must read its HMAC secret from the SSM parameter, never from a literal"
  }

  assert {
    condition     = aws_ssm_parameter.github_webhook_secret.type == "SecureString"
    error_message = "The GitHub webhook secret must be a SecureString"
  }

  # The permission whose ABSENCE made the whole deployment inert: without an
  # unconditioned lambda:InvokeFunction grant, this account's default Lambda
  # public-access block makes the Function URL answer 403 and the handler is
  # never reached. Every other assertion in this file passed while that was
  # broken, which is why it gets one of its own.
  #
  # Review round 1 (0567f6a) tried narrowing this to lambda:InvokeFunctionUrl
  # (finding 1(a)); round 2 (driver review) reverted it -- T-019 (bd65353)
  # verified LIVE that InvokeFunctionUrl alone is insufficient on this
  # account. Pinned to InvokeFunction here so a future edit fails THIS
  # assertion at review time instead of silently 403ing the doorbell on the
  # next apply. Finding 1's real fix is the async task's own HMAC (see
  # lambda/ci_doorbell/index.py's _async_task_signature_ok).
  assert {
    condition     = aws_lambda_permission.ci_doorbell_public_invoke.action == "lambda:InvokeFunction"
    error_message = "The doorbell needs an unconditioned lambda:InvokeFunction grant or its Function URL returns 403 without ever invoking the handler (verified live 2026-08-19, T-019 bd65353; re-verified round 2 of T-034's review -- do not narrow this to InvokeFunctionUrl without a live test)"
  }

  assert {
    condition     = aws_lambda_permission.ci_doorbell_public_invoke.principal == "*"
    error_message = "The public invoke grant must be Principal=* -- the auth boundary is the HMAC check in index.py (both the webhook body signature and, for the async task, its own signature), not this permission"
  }

  # The doorbell may START the one instance and nothing else.
  #
  # NOT asserted on the rendered policy JSON, and this is a real limitation
  # rather than laziness: the documents interpolate computed ARNs (the instance
  # id, the SSM parameter ARNs), so under `command = plan` the whole string is
  # unknown and jsondecode cannot run on it. The unlike-for-unlike case already
  # in this file (mysql_backup_upload) works only because S3 bucket ARNs ARE
  # known at plan time. The action lists are therefore lifted into named locals
  # in ci-on-demand.tf, which is where the security property actually lives and
  # is what these assertions pin. Resource scoping is covered by code review
  # and by stage-4 verification against the live policy.
  assert {
    condition     = join(",", local.ci_doorbell_ec2_actions) == "ec2:StartInstances"
    error_message = "The doorbell role must grant StartInstances only -- no terminate, modify, or run (T-019 ruling 3)"
  }

  assert {
    condition     = join(",", local.ci_reaper_ec2_actions) == "ec2:StopInstances"
    error_message = "The reaper role must grant StopInstances only"
  }

  # The check that actually catches a careless edit: whatever the action lists
  # grow into, they may never intersect the destructive set.
  assert {
    condition = length(setintersection(
      toset(concat(local.ci_doorbell_ec2_actions, local.ci_reaper_ec2_actions)),
      toset(local.ci_forbidden_ec2_actions)
    )) == 0
    error_message = "Neither CI Lambda may grant terminate/modify/run on EC2 -- the worst a compromised public endpoint should manage is turning the CI box on or off"
  }

  # --- Ruling 2: the reaper -------------------------------------------------
  assert {
    condition     = aws_cloudwatch_event_rule.ci_reaper.schedule_expression == "rate(5 minutes)"
    error_message = "The reaper must run on a schedule; without it the host never stops and the task saves nothing"
  }

  # Asserted by rule name, not by ARN: Lambda ARNs are computed, so an
  # ARN-to-ARN comparison is unknown under `command = plan` (same limitation
  # documented throughout this file).
  assert {
    condition     = aws_cloudwatch_event_target.ci_reaper.rule == aws_cloudwatch_event_rule.ci_reaper.name
    error_message = "The reaper's schedule target must be attached to the reaper rule"
  }

  assert {
    condition     = aws_lambda_permission.ci_reaper_events.function_name == aws_lambda_function.ci_reaper.function_name
    error_message = "EventBridge must be granted lambda:InvokeFunction on the reaper -- without it the schedule fires and nothing happens"
  }

  assert {
    condition     = tonumber(aws_lambda_function.ci_reaper.environment[0].variables["IDLE_WINDOW_MINUTES"]) >= 15
    error_message = "The idle window must stay long enough that a gap between pipeline stages cannot trip it (T-019 ruling 2)"
  }

  # The reaper reads Jenkins' password from SSM. Asserted via the Lambda's
  # env var rather than the policy document, for the unknown-ARN reason above:
  # the parameter NAME is known at plan time, the ARN is not.
  assert {
    condition     = aws_lambda_function.ci_reaper.environment[0].variables["JENKINS_PASSWORD_PARAM"] == aws_ssm_parameter.jenkins_admin_password.name
    error_message = "The reaper must read the Jenkins admin password from SSM, never from a literal or an env var baked at apply"
  }

  # Cost guard: this task exists to save money, so it must not add a billed
  # always-on resource. A Function URL is free; an API Gateway in front of the
  # same Lambda would not be. Asserting the URL is attached to the doorbell is
  # the plan-time proxy for "no gateway was introduced".
  #
  # NOT asserted, same unknown-until-apply limitation already documented above
  # for aws_eip.drone.public_ip: aws_lambda_function_url.ci_doorbell.function_url
  # itself is computed at apply, so its value cannot be checked under
  # `command = plan`. Do not add a `command = apply` run block to force it --
  # that would create real AWS resources from a test suite that is meant to run
  # offline. The URL is verified for real at stage 4, by ringing it.
  assert {
    condition     = aws_lambda_function_url.ci_doorbell.function_name == aws_lambda_function.ci_doorbell.function_name
    error_message = "The Function URL must be attached to the doorbell Lambda -- an API Gateway would add cost this task cannot justify"
  }
}

# ---------------------------------------------------------------------------
# T-034 H1 correction -- the doorbell redelivers Drone's own (previously
# GitHub-signed) webhook deliveries for erfeamor/cv-admin-react instead of
# forwarding the payload itself, and self-invokes (InvocationType=Event) to
# do the slow work (start the box, wait for /healthz, call GitHub) outside
# GitHub's 10-second webhook budget. Cases 12-14 of the plan; case 13's IAM
# resource scoping (Resource = aws_lambda_function.ci_doorbell.arn) is NOT
# checkable here -- same unknown-until-apply limitation as every other IAM
# policy assertion in this file (the ARN is computed) -- and is covered by
# scripts/check-static.sh instead (case 15).
# ---------------------------------------------------------------------------
run "t034_doorbell_redelivery" {
  command = plan

  # --- Case 12: the hooks token lives outside ci/*, as a SecureString ------
  assert {
    condition     = aws_ssm_parameter.github_hooks_token.type == "SecureString"
    error_message = "The GitHub hooks token must be a SecureString"
  }

  assert {
    condition     = startswith(aws_ssm_parameter.github_hooks_token.name, "/${var.project_name}/${var.environment}/doorbell/")
    error_message = "github_hooks_token must live outside ci/* -- the CI host's role only reads ci/*, and this token must stay unreadable from a build container running on it (same reasoning as drone_deploy's key, iam.tf)"
  }

  # --- Case 13: self-invoke is InvokeFunction only, and only the doorbell's
  # own actions grow to include it (never the reaper's) ---------------------
  assert {
    condition     = join(",", local.ci_doorbell_lambda_actions) == "lambda:InvokeFunction"
    error_message = "The doorbell's self-invoke grant must be InvokeFunction only"
  }

  assert {
    condition     = aws_lambda_function.ci_doorbell.environment[0].variables["GITHUB_HOOKS_TOKEN_PARAM"] == aws_ssm_parameter.github_hooks_token.name
    error_message = "The doorbell must read the hooks token from SSM by name, never from a literal"
  }

  assert {
    condition     = aws_lambda_function.ci_doorbell.environment[0].variables["SELF_FUNCTION_NAME"] == aws_lambda_function.ci_doorbell.function_name
    error_message = "The doorbell must self-invoke by its OWN function name -- a literal or mismatched name would either fail at runtime or (worse) target a different function"
  }

  assert {
    condition     = aws_lambda_function.ci_doorbell.environment[0].variables["REDELIVER_REPOS"] == "erfeamor/cv-admin-react"
    error_message = "Only erfeamor/cv-admin-react gets the redeliver path (H1) -- Drone verifies each webhook against its own per-repo secret, so nothing this handler could send it directly would pass that check, and the Jenkins repos already have periodicFolderTrigger discovery"
  }

  # --- Case 14: the waiting invocation's timeout ----------------------------
  # Review round 1, finding 4 replaced the bare ">= 540" with the actual
  # budget the timeout is built from (local.ci_doorbell_healthz_timeout_seconds
  # + local.ci_doorbell_github_work_budget_seconds, ci-on-demand.tf) -- see
  # the t034_review_round1 run below for the budget's own assertions.
  assert {
    condition     = aws_lambda_function.ci_doorbell.timeout == local.ci_doorbell_timeout_seconds
    error_message = "aws_lambda_function.ci_doorbell.timeout must come from local.ci_doorbell_timeout_seconds, not a bare literal that could silently drift from the healthz+GitHub-work budget it represents"
  }
}

# ---------------------------------------------------------------------------
# T-034 review round 1 (0567f6a) findings 4, 7 -- async retries are disabled,
# the timeout budget is named and bounded, and the reaper's grace variable is
# actually wired to the Lambda that reads it. Finding 1(a) (the public invoke
# permission) was tried here as lambda:InvokeFunctionUrl-only and REVERTED in
# round 2 (driver review) -- T-019 (bd65353) verified live that this account
# needs the unconditioned InvokeFunction grant; that assertion now lives back
# in the "ci_on_demand" run above, pinned to InvokeFunction. Finding 1's real
# fix is the async task's own HMAC signature -- see the
# t034_async_task_signature run in test_ci_doorbell.py (code-level, not
# Terraform: the signature covers repo+wake_time, not any IAM-visible
# property). Finding 10 (one local for the CI host's public address) is a
# text-level property (aws_eip.drone.public_ip is unknown under
# `command = plan`, same limitation this file documents throughout) and is
# covered by scripts/check-static.sh instead, not here.
# ---------------------------------------------------------------------------
run "t034_review_round1" {
  command = plan

  # --- Finding 4: async retries disabled, and the timeout budget -----------
  assert {
    condition     = aws_lambda_function_event_invoke_config.ci_doorbell.function_name == aws_lambda_function.ci_doorbell.function_name
    error_message = "The event-invoke config must target the doorbell function"
  }

  assert {
    condition     = aws_lambda_function_event_invoke_config.ci_doorbell.maximum_retry_attempts == 0
    error_message = "Async retries must stay disabled -- a Lambda-initiated retry of the wake+redeliver task would re-run redeliver_failed_deliveries, defeating findings 2/3's single-pass dedup guarantees"
  }

  # Review round 3, finding 6: the budget grew from two named pieces to four
  # -- the original sum undercounted the worst-case async-task path (a
  # `stopping` instance waited out, THEN the full healthz wait; plus one
  # healthz probe's own request-level overshoot). Review round 2, finding
  # 2(b) added a fifth: the DNS-convergence wait now runs before healthz
  # too. See the locals' comment in ci-on-demand.tf for what each piece
  # mirrors in lambda/ci_doorbell/index.py.
  assert {
    condition = local.ci_doorbell_timeout_seconds == (
      local.ci_doorbell_stopping_wait_seconds +
      local.ci_doorbell_dns_wait_seconds +
      local.ci_doorbell_healthz_timeout_seconds +
      local.ci_doorbell_healthz_probe_timeout_seconds +
      local.ci_doorbell_github_work_budget_seconds
    )
    error_message = "local.ci_doorbell_timeout_seconds must equal the sum of all five named pieces -- a bare override would hide the budget this number is supposed to make legible"
  }

  assert {
    condition     = local.ci_doorbell_dns_wait_seconds == 120
    error_message = "The DNS-convergence wait budget drifted from the documented 120s (doubled from 60s, live failure 2026-09-30: a cold Lambda's resolver cache outlasted the old 60s ceiling)"
  }

  assert {
    condition     = local.ci_doorbell_timeout_seconds <= 900
    error_message = "900s is Lambda's hard ceiling on any function timeout; the budget must never exceed it"
  }

  # --- Finding 7: the reaper's grace variable is actually wired ------------
  assert {
    condition     = aws_lambda_function.ci_reaper.environment[0].variables["POST_START_GRACE_MINUTES"] == tostring(var.ci_post_start_grace_minutes)
    error_message = "POST_START_GRACE_MINUTES must be wired from var.ci_post_start_grace_minutes -- the variable existed but was never actually passed to the reaper Lambda (review round 1, finding 7), so it silently did nothing"
  }
}

# ---------------------------------------------------------------------------
# T-034 phase 2 + T-033: a stable DNS name (dns.tf) replaces the EIP, and
# Caddy replaces nginx to terminate TLS. Cases 1, 3, 5, 6 of the plan.
# Case 2 (the DNS-update IAM statement's exact shape: one action, the zone
# ARN, all three conditions) is a check-static.sh check (check 10) instead,
# per the plan -- even though data.aws_route53_zone.ci.arn is a MOCKED data
# source (genuinely known here, unlike every computed resource ARN
# elsewhere in this file), for consistency with how every other IAM
# exactness check in this module is done. Case 4 (the SG) needed no new
# assertion -- the existing "exactly 2 ingress rules" assertion above
# already covers "unchanged". Case 7 (no aws_eip.drone reference anywhere)
# only makes sense AFTER the EIP-removal commit; asserting it here, while
# aws_eip.drone still legitimately exists (dns.tf's initial `records`
# value), would be checking the wrong commit.
# ---------------------------------------------------------------------------
run "t034_phase2_dns_tls" {
  command = plan

  # --- Case 1: the record's shape -------------------------------------------
  assert {
    condition     = aws_route53_record.ci.zone_id == data.aws_route53_zone.ci.zone_id
    error_message = "The CI A record must live in the zone dns.tf reads, not a literal zone id"
  }

  assert {
    condition     = aws_route53_record.ci.name == var.ci_hostname
    error_message = "The CI A record's name must be var.ci_hostname, not a second literal that could drift from it"
  }

  assert {
    condition     = aws_route53_record.ci.type == "A"
    error_message = "The CI record must be an A record -- the boot updater UPSERTs an IPv4 address"
  }

  assert {
    condition     = aws_route53_record.ci.ttl == 60
    error_message = "TTL must be 60s -- short enough that a stop/start's new IP propagates quickly, per H1"
  }

  # ignore_changes = [records] is NOT visible here (a lifecycle
  # meta-argument, like aws_instance.drone's own ignore_changes elsewhere in
  # this file) -- covered by scripts/check-static.sh check 10 instead.

  # Review round 1, finding 4: without allow_overwrite = true, creating this
  # record would fail outright if one already existed at this name/type
  # (e.g. a manual record from before Terraform managed it) -- UPSERT
  # semantics all the way down, matching the boot updater's own.
  assert {
    condition     = aws_route53_record.ci.allow_overwrite == true
    error_message = "aws_route53_record.ci must set allow_overwrite = true"
  }

  # --- Review round 1, finding 5: the read-only IAM additions --------------
  assert {
    condition     = join(",", local.ci_dns_read_actions) == "route53:ListResourceRecordSets"
    error_message = "The updater's idempotency check needs exactly route53:ListResourceRecordSets"
  }

  assert {
    condition     = join(",", local.ci_dns_get_change_actions) == "route53:GetChange"
    error_message = "The updater's INSYNC wait needs exactly route53:GetChange"
  }

  assert {
    condition     = join(",", local.ci_dns_get_change_resources) == "arn:aws:route53:::change/*"
    error_message = "route53:GetChange has no zone- or record-scoped ARN -- change/* is the narrowest Resource this action can ever take (documented in iam.tf)"
  }

  # --- Case 3: no wildcard names/types/zone in the DNS-update IAM grant ----
  assert {
    condition     = join(",", local.ci_dns_update_record_names) == var.ci_hostname
    error_message = "The DNS-update IAM condition must name exactly var.ci_hostname, never a wildcard"
  }

  assert {
    condition     = join(",", local.ci_dns_update_record_types) == "A"
    error_message = "The DNS-update IAM condition must allow only the A record type"
  }

  assert {
    condition     = join(",", local.ci_dns_update_actions_types) == "UPSERT"
    error_message = "The DNS-update IAM condition must allow only UPSERT, never DELETE or CREATE"
  }

  # --- Case 5: ci_public_host is the hostname; URLs are https --------------
  assert {
    condition     = local.ci_public_host == var.ci_hostname
    error_message = "local.ci_public_host must be var.ci_hostname now that the EIP is gone -- see ci-on-demand.tf"
  }

  assert {
    condition     = startswith(aws_lambda_function.ci_doorbell.environment[0].variables["DRONE_HEALTHZ_URL"], "https://")
    error_message = "DRONE_HEALTHZ_URL must be https:// now that Caddy terminates TLS (T-033)"
  }

  assert {
    condition     = startswith(aws_lambda_function.ci_reaper.environment[0].variables["JENKINS_BASE_URL"], "https://")
    error_message = "JENKINS_BASE_URL must be https:// now that Caddy terminates TLS (T-033)"
  }

  # --- Case 6: outputs are https --------------------------------------------
  # Knowable here (unlike before phase 2): drone_server_url no longer
  # embeds aws_eip.drone.public_ip, so it's no longer unknown-until-apply.
  assert {
    condition     = output.drone_server_url == "https://${var.ci_hostname}"
    error_message = "drone_server_url must be https and must use the DNS name, not the (now-removed) EIP"
  }
}

# ---------------------------------------------------------------------------
# T-034 phase 2 review round 2: the DNS sentinel (finding 2) and the
# doorbell's DNS-convergence wait (finding 2(b)). The reaper's new grant
# reuses iam.tf's drone_dns_update locals (already asserted exact there);
# what's new here is that ci_reaper's OWN policy actually includes a
# statement built from them, and both Lambdas' new env vars are wired.
# ---------------------------------------------------------------------------
run "t034_phase2_dns_sentinel" {
  command = plan

  assert {
    condition     = aws_lambda_function.ci_doorbell.environment[0].variables["CI_HOSTNAME"] == var.ci_hostname
    error_message = "The doorbell must read CI_HOSTNAME from var.ci_hostname, never a literal, for its DNS-convergence wait"
  }

  assert {
    condition     = aws_lambda_function.ci_doorbell.environment[0].variables["DNS_WAIT_TIMEOUT_SECONDS"] == tostring(local.ci_doorbell_dns_wait_seconds)
    error_message = "DNS_WAIT_TIMEOUT_SECONDS must come from the named budget local, not a second literal"
  }

  assert {
    condition     = aws_lambda_function.ci_reaper.environment[0].variables["CI_HOSTNAME"] == var.ci_hostname
    error_message = "The reaper must read CI_HOSTNAME from var.ci_hostname for its post-stop sentinel UPSERT"
  }

  assert {
    condition     = aws_lambda_function.ci_reaper.environment[0].variables["ROUTE53_ZONE_ID"] == data.aws_route53_zone.ci.zone_id
    error_message = "The reaper must read ROUTE53_ZONE_ID from the zone data source, never a literal"
  }

  assert {
    condition     = aws_lambda_function.ci_reaper.environment[0].variables["DNS_SENTINEL_IP"] == local.ci_dns_sentinel_ip
    error_message = "The reaper's sentinel value must be local.ci_dns_sentinel_ip -- the same one dns.tf's placeholder and the ExecStop unit use"
  }

  assert {
    condition     = local.ci_dns_sentinel_ip == "192.0.2.1"
    error_message = "The DNS sentinel must be TEST-NET-1 (192.0.2.1, RFC 5737) -- guaranteed never to route anywhere real"
  }

  # The reaper's new statement itself, in the same style as the doorbell
  # Caddyfile-parity checks: assert against the ACTUAL rendered policy is
  # not possible (data.aws_route53_zone.ci.arn is a computed-looking
  # reference even though mocked -- same reasoning iam.tf's own comment
  # documents), so this reuses the SAME named locals iam.tf's grant already
  # asserts exactly elsewhere in this file; what matters here is only that
  # ci_reaper's policy resource references them at all, which check-static
  # (check 15) verifies textually.

  # --- Live failure, 2026-09-30: the doorbell's own authoritative-DNS read -
  # (wait_for_dns_to_match_instance now reads Route 53 directly instead of
  # trusting the Lambda's own, cacheable, local resolver). The grant's exact
  # shape (one read-only action, the zone ARN only, no wildcard) is
  # scripts/check-static.sh's job (same "unknown until apply" limitation the
  # comment above already explains for the reaper's own grant) -- what's
  # asserted here is only that the doorbell actually has ROUTE53_ZONE_ID
  # wired from the zone data source, never a literal.
  assert {
    condition     = aws_lambda_function.ci_doorbell.environment[0].variables["ROUTE53_ZONE_ID"] == data.aws_route53_zone.ci.zone_id
    error_message = "The doorbell must read ROUTE53_ZONE_ID from the zone data source, never a literal -- it needs this for its own authoritative-DNS read (live failure, 2026-09-30)"
  }
}

# ---------------------------------------------------------------------------
# T-034 phase 2 review round 1, finding 10: var.ci_hostname's validation
# block, checked the way `terraform test` checks any validation -- a `plan`
# run whose variables are EXPECTED to fail, asserted via `expect_failures`.
# ---------------------------------------------------------------------------
run "t034_ci_hostname_validation" {
  command = plan

  variables {
    ci_hostname = "CI.Erfeamor.com" # uppercase -- must be rejected
  }

  expect_failures = [var.ci_hostname]
}

run "t034_ci_hostname_validation_trailing_dot" {
  command = plan

  variables {
    ci_hostname = "ci.erfeamor.com." # trailing dot -- must be rejected
  }

  expect_failures = [var.ci_hostname]
}

run "t034_ci_hostname_validation_single_label" {
  command = plan

  variables {
    ci_hostname = "localhost" # single label, not a valid FQDN here -- must be rejected
  }

  expect_failures = [var.ci_hostname]
}

# ---------------------------------------------------------------------------
# T-007 -- CI host replaced onto a plain AL2023 AMI with a measured root,
# IMDSv2 hardening, and DRONE_DATABASE_SECRET. Cases 1-3 and 6 are knowable
# under `command = plan`: the AMI filter, root_block_device and
# metadata_options are all explicit config on aws_instance.drone (not
# AWS-computed), and the rendered user_data is a pure function of the
# templatefile() inputs. Case 4 (the SSM param's value) needs `command =
# apply` -- random_password.result is generated at Create time, so it is
# unknown-until-apply even under mock_provider (same class of limitation as
# aws_eip.drone.public_ip elsewhere in this file). Case 5 (lifecycle
# ignore_changes) and case 8 (the Lambda env vars, which reference
# aws_instance.drone.id -- a genuinely AWS-computed attribute, unknown at
# plan for a not-yet-created instance) aren't visible to `terraform test` at
# all -- both are covered by scripts/check-static.sh instead, which checks
# the source text for exactly this class of gap.
# ---------------------------------------------------------------------------
run "t007_ci_host_hardening" {
  command = plan

  # Case 1: the premise correction (2026-09-25) established that ci.tf's
  # aws_instance.drone already resolves data.aws_ami.al2023 -- the SAME
  # plain-AL2023 data source domain_service uses -- and that ignore_changes
  # alone is what has kept the live host on the old ECS-optimized image.
  # Nothing about the filter itself needed to change; this pins that so a
  # future edit can't silently point either instance back at an
  # ECS-optimized filter without failing here.
  # data.aws_ami.al2023.filter is a set of objects (no addressable index),
  # so every check below flattens across the whole set rather than indexing
  # element 0.
  assert {
    condition     = anytrue([for f in data.aws_ami.al2023.filter : f.name == "name"])
    error_message = "data.aws_ami.al2023 must filter on the AMI name"
  }

  assert {
    condition     = alltrue(flatten([for f in data.aws_ami.al2023.filter : [for v in f.values : !can(regex("ecs", v))]]))
    error_message = "data.aws_ami.al2023's filter values must not match the ECS-optimized AMI variant"
  }

  assert {
    condition     = contains(flatten([for f in data.aws_ami.al2023.filter : f.values]), "al2023-ami-2023.*-x86_64")
    error_message = "data.aws_ami.al2023 must keep the plain AL2023 filter -- a looser pattern also matches the ECS-optimized variant"
  }

  assert {
    condition     = aws_instance.drone.ami == data.aws_ami.al2023.id
    error_message = "aws_instance.drone must resolve its AMI from the plain AL2023 data source"
  }

  # Case 2: explicit, measured root -- not the plain AMI's 8 GB default.
  assert {
    condition     = aws_instance.drone.root_block_device[0].volume_size == 20
    error_message = "aws_instance.drone's root volume must be sized to 20 GB (T-007 H1 decision 2, from the ~17 GiB measured in use) -- the plain AL2023 AMI defaults to 8 GB, which would not fit today's contents"
  }

  assert {
    condition     = aws_instance.drone.root_block_device[0].volume_type == "gp3"
    error_message = "aws_instance.drone's root volume must be gp3, matching the rest of this module's convention"
  }

  assert {
    condition     = aws_instance.drone.root_block_device[0].encrypted == true
    error_message = "aws_instance.drone's root volume must be encrypted at rest"
  }

  # Case 3: IMDSv2 required, hop limit 1 (T-007 H1 decision 3 / T-005).
  assert {
    condition     = aws_instance.drone.metadata_options[0].http_tokens == "required"
    error_message = "aws_instance.drone must require IMDSv2 tokens"
  }

  assert {
    condition     = aws_instance.drone.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "aws_instance.drone's metadata hop limit must be 1, so a container cannot reach IMDS through a Docker network hop"
  }

  # Case 4 (plan-time half): the parameter exists, is a SecureString, and
  # lives under ci/drone/ -- the value itself (traced to random_password,
  # not a literal) needs `command = apply`, see the run below.
  assert {
    condition     = aws_ssm_parameter.drone_database_secret.type == "SecureString"
    error_message = "DRONE_DATABASE_SECRET must be stored as a SecureString"
  }

  assert {
    condition     = aws_ssm_parameter.drone_database_secret.name == "/${var.project_name}/${var.environment}/ci/drone/database-secret"
    error_message = "DRONE_DATABASE_SECRET must live at ci/drone/database-secret -- under ci/*, so the Drone host's own instance role (drone_read_ci_parameters) can read it, matching every other Drone boot secret"
  }

  # Case 6 and case 7 (review round 1, finding 9: dropped from here, not
  # duplicated): the <8 KB user_data wall against this exact templatefile()
  # call is already asserted once, in "ci_on_demand" above -- re-asserting
  # the identical computed value under a second name proves nothing extra
  # and doubles the maintenance cost of the 8192 constant. Likewise
  # `aws_instance.drone.user_data_replace_on_change != true` is already
  # asserted in "plan_succeeds" above. Both keep working unchanged by this
  # task; see those two run blocks instead of repeating them here.

  # Review round 1, finding 9 -- RED FIRST: DRONE_DATABASE_SECRET must
  # actually reach the drone-server container (not just exist in SSM), and
  # the param() path it's read from must be the exact path segment that
  # builds aws_ssm_parameter.drone_database_secret.name above
  # ("drone/database-secret", under the ci/ prefix param() always
  # prepends) -- a typo in either place would pass every other assertion in
  # this run and still leave DRONE_DATABASE_SECRET unset or fetched from
  # the wrong SSM path at boot.
  assert {
    condition = length(regexall("-e DRONE_DATABASE_SECRET=", templatefile("${path.module}/templates/drone-user-data.sh", {
      aws_region     = var.aws_region
      project_name   = var.project_name
      environment    = var.environment
      ci_hostname    = "203.0.113.10"
      admin_username = var.drone_admin_username
    }))) == 1
    error_message = "templates/drone-user-data.sh must pass -e DRONE_DATABASE_SECRET to the drone-server container exactly once"
  }

  assert {
    condition = length(regexall("param drone/database-secret", templatefile("${path.module}/templates/drone-user-data.sh", {
      aws_region     = var.aws_region
      project_name   = var.project_name
      environment    = var.environment
      ci_hostname    = "203.0.113.10"
      admin_username = var.drone_admin_username
    }))) == 1
    error_message = "templates/drone-user-data.sh must read DRONE_DATABASE_SECRET via `param drone/database-secret` -- the same ci/drone/database-secret path aws_ssm_parameter.drone_database_secret.name builds"
  }

  # Review round 1, finding 9 -- RED FIRST: the prune timer must run the
  # PO-decided commands (image/build-cache only, age-filtered, never
  # containers/networks), never the broader `docker system prune`.
  # Anchored on the literal `ExecStart=` prefix, not a bare substring search
  # -- this script's own explanatory comments quote these exact commands by
  # name (both the wanted ones and, in the "deliberately NOT" sentence, the
  # unwanted one), so a substring-only search would double-count against
  # the comment text and could never legitimately assert "0 occurrences" of
  # the forbidden command below.
  assert {
    condition = (
      length(regexall("ExecStart=/usr/bin/docker image prune -af --filter until=168h", templatefile("${path.module}/templates/drone-user-data.sh", {
        aws_region     = var.aws_region
        project_name   = var.project_name
        environment    = var.environment
        ci_hostname    = "203.0.113.10"
        admin_username = var.drone_admin_username
      }))) == 1 &&
      length(regexall("ExecStart=/usr/bin/docker builder prune -af --filter until=168h", templatefile("${path.module}/templates/drone-user-data.sh", {
        aws_region     = var.aws_region
        project_name   = var.project_name
        environment    = var.environment
        ci_hostname    = "203.0.113.10"
        admin_username = var.drone_admin_username
      }))) == 1
    )
    error_message = "docker-prune.service must run `docker image prune -af --filter until=168h` and `docker builder prune -af --filter until=168h` as ExecStart lines (PO decision, review round 1 finding 3)"
  }

  assert {
    condition = length(regexall("ExecStart=.*docker system prune", templatefile("${path.module}/templates/drone-user-data.sh", {
      aws_region     = var.aws_region
      project_name   = var.project_name
      environment    = var.environment
      ci_hostname    = "203.0.113.10"
      admin_username = var.drone_admin_username
    }))) == 0
    error_message = "docker-prune.service must not run `docker system prune` -- it also removes stopped containers and unused networks, not just images/build cache (review round 1, finding 3)"
  }

  assert {
    condition = (
      length(regexall("After=docker.service", templatefile("${path.module}/templates/drone-user-data.sh", {
        aws_region     = var.aws_region
        project_name   = var.project_name
        environment    = var.environment
        ci_hostname    = "203.0.113.10"
        admin_username = var.drone_admin_username
      }))) == 1 &&
      length(regexall("Requires=docker.service", templatefile("${path.module}/templates/drone-user-data.sh", {
        aws_region     = var.aws_region
        project_name   = var.project_name
        environment    = var.environment
        ci_hostname    = "203.0.113.10"
        admin_username = var.drone_admin_username
      }))) == 1
    )
    error_message = "docker-prune.service must declare After=docker.service and Requires=docker.service"
  }
}

# Case 4 (value half): random_password.result is generated at apply, so this
# needs `command = apply` -- safe under mock_provider (aws_ssm_parameter's
# create is mocked; random_password computes locally, no network either
# way). Scoped to just these two resources so null_resource.jenkins_provision
# (ci.tf) -- whose local-exec shells out to real `aws ssm` regardless of the
# AWS provider being mocked -- is never reached, same rationale as
# "backup_iam_scoping" above.
run "t007_drone_database_secret_value" {
  command = apply

  plan_options {
    target = [
      aws_ssm_parameter.drone_database_secret,
    ]
  }

  assert {
    condition     = aws_ssm_parameter.drone_database_secret.value == random_password.drone_database_secret.result
    error_message = "aws_ssm_parameter.drone_database_secret must store random_password.drone_database_secret.result, not a tfvars literal or a separately-typed value"
  }

  assert {
    condition     = length(random_password.drone_database_secret.result) == 32
    error_message = "random_password.drone_database_secret must generate a 32-character (32-byte ASCII) secret -- the format Drone's DRONE_DATABASE_SECRET expects"
  }
}

# ---------------------------------------------------------------------------
# T-008 -- the drone-deploy IAM user's own access key moves into Terraform +
# SSM (iam.tf, ssm.tf), so the CI host's Drone SQLite stops being the only
# copy of this credential. Everything here is known at plan time: the user's
# `name` is a plain variable interpolation (no AWS-generated ARN involved),
# and the two SSM parameter names/types are literal too.
# ---------------------------------------------------------------------------
run "drone_deploy_credentials" {
  command = plan

  # Case 1, RED FIRST: the access key attaches to the SAME existing user
  # that already carries the frontend-deploy policy -- not a new/parallel
  # IAM identity.
  assert {
    condition     = aws_iam_access_key.drone_deploy.user == aws_iam_user.drone_deploy.name
    error_message = "aws_iam_access_key.drone_deploy must attach to aws_iam_user.drone_deploy, not a different or new IAM user"
  }

  # Case 2, RED FIRST: both parameters are SecureStrings...
  assert {
    condition     = aws_ssm_parameter.drone_deploy_access_key_id.type == "SecureString"
    error_message = "The drone-deploy access key ID must be stored as a SecureString"
  }

  assert {
    condition     = aws_ssm_parameter.drone_deploy_secret_access_key.type == "SecureString"
    error_message = "The drone-deploy secret access key must be stored as a SecureString"
  }

  # ...at the deploy/ path...
  assert {
    condition     = aws_ssm_parameter.drone_deploy_access_key_id.name == "/${var.project_name}/${var.environment}/deploy/drone-deploy/access-key-id"
    error_message = "The access key ID parameter must live at the deploy/drone-deploy path"
  }

  assert {
    condition     = aws_ssm_parameter.drone_deploy_secret_access_key.name == "/${var.project_name}/${var.environment}/deploy/drone-deploy/secret-access-key"
    error_message = "The secret access key parameter must live at the deploy/drone-deploy path"
  }

  # ...NOT under ci/ -- that's what the Drone host's own instance role can
  # read, and build containers on that host can reach it until T-007/T-005.
  assert {
    condition = (
      !can(regex("/ci/", aws_ssm_parameter.drone_deploy_access_key_id.name)) &&
      !can(regex("/ci/", aws_ssm_parameter.drone_deploy_secret_access_key.name))
    )
    error_message = "Neither drone-deploy SSM parameter may live under the ci/ prefix -- that's what the Drone host's own instance role can read"
  }

  # Negative half of case 2, the CI-host role: aws_iam_role_policy.
  # drone_read_ci_parameters is scoped to ci/* only -- pin its Resource
  # string exactly (fully known at plan, built only from variables, no
  # AWS-generated ARN involved) so a later widening (e.g. to deploy/* or
  # the whole tree) fails here instead of silently handing a build
  # container its own deploy key.
  assert {
    condition     = jsondecode(aws_iam_role_policy.drone_read_ci_parameters.policy).Statement[0].Resource == "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${var.environment}/ci/*"
    error_message = "aws_iam_role_policy.drone_read_ci_parameters must stay scoped to ci/* -- widening it would let a build container on the Drone host read its own deploy key out of SSM"
  }

  # --- Security review round 2 (Medium, accepted): the APP host's own role
  # is NOT isolated from deploy/ the same way -- aws_iam_role_policy.
  # read_parameters (iam.tf) grants ssm:GetParameter* on the WHOLE
  # /${project}/* tree (it legitimately needs db/, cognito/, observability/,
  # etc across the tree), which already covered deploy/drone-deploy/* before
  # this fix, and this host has no metadata_options (IMDSv1 on) and runs
  # containers reachable by SSRF/RCE. "Outside ci/*" alone only isolates the
  # CI host's role; this pair of assertions is what actually isolates the
  # app host's role too, via an explicit Deny (which IAM always evaluates
  # ahead of any Allow, regardless of statement order). Since T-005 the
  # Allow is also narrowed (below); the Deny stays as defense in depth. ---
  # T-005: the Allow is now the exact set of parameters the app host reads
  # (bootstrap stub, provision script / cv-app.sh param(), backup script),
  # one ARN each -- no tree-wide or prefix wildcard. Names are known at plan,
  # so no apply is needed.
  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.read_parameters.policy).Statement :
      s.Resource if s.Effect == "Allow"
      ])) == toset([
      for p in ["app/provision-sha256", "db/password", "cognito/issuer-uri", "bff/service-client-id", "bff/service-client-secret", "bff/token-url", "bff/token-scope"] :
      "arn:aws:ssm:${var.aws_region}:123456789012:parameter/${var.project_name}/${var.environment}/${p}"
    ])
    error_message = "read_parameters must Allow exactly the 7 parameters the app host reads, by full ARN (T-005)"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.read_parameters.policy).Statement :
      s.Effect == "Deny" || (
        !anytrue([for r in flatten([try(s.Resource, [])]) : strcontains(r, "*")]) &&
        !contains(s.Action, "ssm:GetParametersByPath")
      )
    ])
    error_message = "read_parameters Allow must carry no wildcard Resource and no GetParametersByPath (T-005)"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.read_parameters.policy).Statement :
      s.Effect == "Deny" && contains(s.Action, "ssm:GetParameter") && try(s.Resource, "") == "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${var.environment}/deploy/*"
    ])
    error_message = "aws_iam_role_policy.read_parameters must explicit-Deny ssm:GetParameter* on the deploy/ prefix -- otherwise the app host's own role (IMDSv1, no metadata_options) can read the frontend deploy key via an SSRF/RCE in the domain service (T-008 security review round 2)"
  }

  # T-005 round 1: AmazonSSMManagedInstanceCore (attached to both roles) grants
  # ssm:GetParameter(s) on "*", so the inline Allows alone narrow nothing.
  # Each role therefore carries an explicit Deny + NotResource on the four
  # read actions: everything outside the role's own parameter set is denied.
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.read_parameters.policy).Statement :
      s.Effect == "Deny" && try(s.Resource, null) == null &&
      toset(s.Action) == toset(["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"]) &&
      toset(flatten([try(s.NotResource, [])])) == toset([
        for p in ["app/provision-sha256", "db/password", "cognito/issuer-uri", "bff/service-client-id", "bff/service-client-secret", "bff/token-url", "bff/token-scope"] :
        "arn:aws:ssm:${var.aws_region}:123456789012:parameter/${var.project_name}/${var.environment}/${p}"
      ])
    ])
    error_message = "read_parameters must Deny the four ssm read actions with NotResource = exactly the app host's 7 parameter ARNs (the managed AmazonSSMManagedInstanceCore grants GetParameter on * otherwise) (T-005 round 1)"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.drone_read_ci_parameters.policy).Statement :
      s.Effect == "Deny" && try(s.Resource, null) == null &&
      toset(s.Action) == toset(["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"]) &&
      toset(flatten([try(s.NotResource, [])])) == toset(["arn:aws:ssm:${var.aws_region}:123456789012:parameter/${var.project_name}/${var.environment}/ci/*"])
    ])
    error_message = "drone_read_ci_parameters must Deny the four ssm read actions with NotResource = exactly the ci/* parameter ARN (T-005 round 1)"
  }

  # No Allow was widened by the fix: the CI host's Allow stays ci/* only.
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.drone_read_ci_parameters.policy).Statement :
      s.Effect == "Deny" || try(s.Resource, "") == "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${var.environment}/ci/*"
    ])
    error_message = "drone_read_ci_parameters Allow must stay ci/* only (T-005 round 1)"
  }

  # Ties the Deny's literal Resource pattern to the REAL parameter names
  # created in ssm.tf, rather than trusting two independently-typed string
  # literals to agree with each other -- a Deny on the wrong prefix would
  # still pass the assertion above (both sides are just string literals)
  # without actually covering these parameters.
  assert {
    condition = (
      startswith(aws_ssm_parameter.drone_deploy_access_key_id.name, "/${var.project_name}/${var.environment}/deploy/") &&
      startswith(aws_ssm_parameter.drone_deploy_secret_access_key.name, "/${var.project_name}/${var.environment}/deploy/")
    )
    error_message = "The Deny's deploy/ prefix must actually cover both drone-deploy SSM parameter names"
  }

  # Case 4/5 (the part checkable under `command = plan`): aws_iam_user_policy.
  # drone_deploy is NOT reasserted here -- its Resource fields embed
  # aws_s3_bucket.frontend.arn / aws_cloudfront_distribution.frontend.arn,
  # which are unknown-until-apply under `command = plan` (same documented
  # limitation as aws_s3_bucket.backup.arn and aws_eip.drone.public_ip
  # elsewhere in this file; confirmed empirically the same way). This task
  # does not touch that resource at all -- verified by code review (git
  # diff shows no edit to its block) and by scripts/check-static.sh,
  # which fails if the policy widens beyond its exact least-privilege action
  # set, effects and frontend-only resources.
}

# T-022: the domain service used to answer the whole internet on 8080, which
# made CloudFront optional as an entry point and served /v3/api-docs
# unauthenticated. These assertions pin the fix so a later edit cannot quietly
# widen it back -- the failure they guard against reads as a working plan.
run "domain_service_ingress_scoped_to_cloudfront" {
  command = plan

  # The rule must reference the managed prefix list, and it must be THE
  # CloudFront one -- asserting "some prefix list" would pass against any list.
  assert {
    condition = alltrue([
      for rule in aws_security_group.domain_service.ingress :
      contains(coalesce(rule.prefix_list_ids, []), data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id)
      if rule.from_port == 8080
    ])
    error_message = "The 8080 ingress must be scoped to the CloudFront origin-facing prefix list, not to a CIDR"
  }

  assert {
    condition     = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.name == "com.amazonaws.global.cloudfront.origin-facing"
    error_message = "The prefix list must be CloudFront's origin-facing list -- any other list would scope 8080 to the wrong senders"
  }

  # The point of the task: no open CIDR survives anywhere on this group's
  # ingress. Checked across every rule, not just the 8080 one, so re-adding an
  # open rule on another port also fails here.
  assert {
    condition = alltrue([
      for rule in aws_security_group.domain_service.ingress :
      !contains(coalesce(rule.cidr_blocks, []), "0.0.0.0/0")
    ])
    error_message = "No ingress rule on the domain-service security group may be open to 0.0.0.0/0 -- T-022 closed the direct-to-origin path and this is what keeps it closed"
  }

  # DoR §3 / network.tf: description is ForceNew on a group with no
  # create_before_destroy, so changing it destroys a group still attached to
  # the live instance. Pinning the exact string makes that an explicit
  # decision rather than an accident during unrelated tidying.
  assert {
    condition     = aws_security_group.domain_service.description == "Allows inbound HTTP(S) and SSH to the domain service EC2 instance"
    error_message = "Do not edit aws_security_group.domain_service.description -- it is ForceNew and would replace a group attached to the running instance (see the comment in network.tf)"
  }

  # Port 22 has never been open here and must not arrive by accident: shell
  # access is SSM Session Manager (CLAUDE.md, "No SSH anywhere").
  assert {
    condition = alltrue([
      for rule in aws_security_group.domain_service.ingress :
      rule.from_port != 22 && rule.to_port != 22
    ])
    error_message = "No port-22 ingress: shell access is SSM Session Manager"
  }
}

# ---------------------------------------------------------------------------
# T-014 -- deploy cv-bff-node: registry, container, edge route. See the task
# file's seven DoR rulings + the 2026-10-01 H1 refresh for the reasoning
# behind each assertion below. No new mock_data needed: every data source
# this task reads (aws_vpc, aws_ec2_managed_prefix_list) is already mocked
# above, reused rather than duplicated.
# ---------------------------------------------------------------------------
run "bff_node_registry_and_edge" {
  command = plan

  # Scope 1: the registry mirrors domain_service.
  assert {
    condition     = aws_ecr_repository.bff_node.name == "${var.project_name}-bff-node"
    error_message = "ECR repository name for the BFF must follow the project prefix convention"
  }

  assert {
    condition     = aws_ecr_repository.bff_node.force_delete == true
    error_message = "aws_ecr_repository.bff_node must keep force_delete = true, mirroring domain_service (demo project, parity)"
  }

  # Lifecycle rules: see run "t050_ecr_lifecycle_rules".

  # Ruling 1, the crux: port 3000 gets its OWN security group -- never a
  # second rule on aws_security_group.domain_service (prefix-list quota, see
  # network.tf). Scoped to the CloudFront origin-facing prefix list, not a
  # CIDR, and definitely not 0.0.0.0/0.
  assert {
    condition = alltrue([
      for rule in aws_security_group.bff_node.ingress :
      contains(coalesce(rule.prefix_list_ids, []), data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id)
      if rule.from_port == 3000
    ])
    error_message = "The BFF's 3000 ingress must be scoped to the CloudFront origin-facing prefix list, not a CIDR"
  }

  assert {
    condition = alltrue([
      for rule in aws_security_group.bff_node.ingress :
      !contains(coalesce(rule.cidr_blocks, []), "0.0.0.0/0")
    ])
    error_message = "No ingress rule on the BFF security group may be open to 0.0.0.0/0"
  }

  assert {
    condition = alltrue([
      for rule in aws_security_group.bff_node.ingress :
      rule.from_port != 22 && rule.to_port != 22
    ])
    error_message = "No port-22 ingress on the BFF security group: shell access is SSM Session Manager"
  }

  assert {
    condition     = length(aws_security_group.bff_node.ingress) == 1
    error_message = "The BFF security group should expose exactly one ingress rule (port 3000) -- anything more is unreviewed scope creep"
  }

  # The quota reason ruling 1 exists for: the pre-existing group must NOT
  # gain a second prefix-list rule (46 + 46 entries would exceed the
  # 60-rule-per-SG quota and fail the apply).
  assert {
    condition     = length(aws_security_group.domain_service.ingress) == 1
    error_message = "aws_security_group.domain_service must NOT gain a second ingress rule for port 3000 -- the BFF needs its own security group (prefix-list quota, T-014 ruling 1)"
  }

  # Not asserted here, deliberately: that aws_instance.domain_service's
  # vpc_security_group_ids carries BOTH groups. Both referenced security
  # groups are new resources in this plan, so their .id (and therefore the
  # instance's set attribute built from them) is unknown-until-apply --
  # same documented class of limitation as aws_eip.drone.public_ip and
  # aws_s3_bucket.backup.arn elsewhere in this file (confirmed empirically:
  # `terraform test` errors "Condition expression could not be evaluated").
  # Covered by `terraform validate` + code review (compute.tf's
  # vpc_security_group_ids literal) instead.

  # Ruling 3: same EIP, new port, http-only -- no new EIP, no new instance.
  # The `if` clause (not an && inside the expression body) is what keeps this
  # safe to index: variables.tf's own review notes document that `&&` does
  # NOT short-circuit in Terraform, so an && guard ahead of
  # custom_origin_config[0] would still evaluate that index for the
  # frontend-s3 origin (which has no custom_origin_config at all) and error.
  # Filtering via `if` excludes that origin from the expression entirely.
  assert {
    condition = length([
      for o in aws_cloudfront_distribution.frontend.origin : o
      if o.origin_id == "bff-node"
    ]) == 1
    error_message = "Exactly one CloudFront origin with origin_id = \"bff-node\" is expected"
  }

  # domain_name is NOT compared to aws_eip.domain_service.public_dns here --
  # that attribute is itself unknown-until-apply (same documented limitation
  # as aws_eip.drone.public_ip elsewhere in this file), confirmed
  # empirically. Code review covers that the origin block literally reuses
  # aws_eip.domain_service.public_dns (frontend.tf), exactly like the
  # pre-existing domain-service-api origin does -- no new EIP is created,
  # which IS checkable (there is no second aws_eip resource anywhere in this
  # module).
  assert {
    condition = alltrue([
      for o in aws_cloudfront_distribution.frontend.origin :
      o.custom_origin_config[0].http_port == 3000 &&
      o.custom_origin_config[0].origin_protocol_policy == "http-only"
      if o.origin_id == "bff-node"
    ])
    error_message = "The bff-node CloudFront origin must be port 3000, http-only"
  }


  # The /bff/* behavior: routes to the new origin, no-cache (mirrors /api/*'s
  # TTLs-0 posture -- the aggregate is revalidated by ISR upstream), and
  # forwards Authorization (the BFF's non-public routes need it, ruling 5/6).
  assert {
    condition = anytrue([
      for b in aws_cloudfront_distribution.frontend.ordered_cache_behavior :
      b.path_pattern == "/bff/*" &&
      b.target_origin_id == "bff-node" &&
      b.min_ttl == 0 && b.default_ttl == 0 && b.max_ttl == 0 &&
      length(b.forwarded_values) > 0 &&
      contains(b.forwarded_values[0].headers, "Authorization")
    ])
    error_message = "CloudFront must have a no-cache /bff/* behavior targeting bff-node, forwarding Authorization"
  }

  # Ruling 2: /bff/* and /api/* are disjoint path prefixes (no shadowing), so
  # there's no ordering constraint between them -- just confirm exactly the
  # two expected behaviors exist (both still precede the default behavior
  # structurally).
  assert {
    condition     = length([for b in aws_cloudfront_distribution.frontend.ordered_cache_behavior : b.path_pattern]) == 2
    error_message = "Exactly two ordered_cache_behavior blocks are expected: /api/* and /bff/*"
  }
}

# ---------------------------------------------------------------------------
# T-014 -- the rendered app-host user_data: the BFF container block, the
# Flyway pin, and the 16,384-byte EC2 limit. Rendered directly via
# templatefile() with fixture values (same pattern the drone/jenkins size
# checks above use) because aws_instance.domain_service's OWN user_data
# embeds cloudfront_domain (aws_cloudfront_distribution.frontend.domain_name),
# unknown-until-apply under `command = plan` -- same documented limitation as
# aws_eip.drone.public_ip elsewhere in this file.
# ---------------------------------------------------------------------------
run "app_host_user_data" {
  command = plan

  # H1 refresh item 4 / N2, RED FIRST: EC2's hard user_data limit is 16,384
  # bytes. T-044: the full script no longer rides in user_data (it is an S3
  # object, like T-009's Jenkins script), so this guard on the SCRIPT is only a
  # sanity bound; the real user_data wall is guarded on the stub below.
  assert {
    condition = length(templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region        = var.aws_region
      project_name      = var.project_name
      environment       = var.environment
      image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name           = var.db_name
      db_username       = var.db_username
      cloudfront_domain = "d1234567890abc.cloudfront.net"
      backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix     = "mysql-dumps"
      mysql_volume_id   = "vol-0123456789abcdef0"
    })) <= 40000
    error_message = "Rendered domain-service-provision.sh exceeds 40,000 bytes -- it is an S3 object now (T-044), not user_data, but a script this big deserves a split"
  }

  # AC: production pins Flyway 13.7.0 (T-155/T-156), riding this apply's
  # instance replacement -- was flyway/flyway:10.
  assert {
    condition = length(regexall("flyway/flyway:13\\.7\\.0 migrate", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region        = var.aws_region
      project_name      = var.project_name
      environment       = var.environment
      image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name           = var.db_name
      db_username       = var.db_username
      cloudfront_domain = "d1234567890abc.cloudfront.net"
      backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix     = "mysql-dumps"
      mysql_volume_id   = "vol-0123456789abcdef0"
    }))) == 1
    error_message = "templates/domain-service-provision.sh must pin flyway/flyway:13.7.0 at the migrate step, not :10"
  }

  # Scope 2: the BFF container -- same cv network, --restart unless-stopped,
  # --name bff-node.
  assert {
    condition = length(regexall("docker run -d --name bff-node --restart unless-stopped --network cv", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region        = var.aws_region
      project_name      = var.project_name
      environment       = var.environment
      image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name           = var.db_name
      db_username       = var.db_username
      cloudfront_domain = "d1234567890abc.cloudfront.net"
      backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix     = "mysql-dumps"
      mysql_volume_id   = "vol-0123456789abcdef0"
    }))) == 1
    error_message = "The BFF docker run must be --name bff-node --restart unless-stopped --network cv"
  }

  # Scope 2: the BFF publishes 3000 (unique to the BFF -- the domain service
  # publishes 8080).
  assert {
    condition = length(regexall("-p 3000:3000", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region        = var.aws_region
      project_name      = var.project_name
      environment       = var.environment
      image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name           = var.db_name
      db_username       = var.db_username
      cloudfront_domain = "d1234567890abc.cloudfront.net"
      backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix     = "mysql-dumps"
      mysql_volume_id   = "vol-0123456789abcdef0"
    }))) == 1
    error_message = "The BFF container must publish port 3000"
  }

  # Ruling 5/scope 2: DOMAIN_SERVICE_URL is container-to-container, NEVER the
  # public EIP -- BFF->domain traffic must not round-trip the internet.
  assert {
    condition = length(regexall("-e DOMAIN_SERVICE_URL=http://domain-service:8080", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region        = var.aws_region
      project_name      = var.project_name
      environment       = var.environment
      image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name           = var.db_name
      db_username       = var.db_username
      cloudfront_domain = "d1234567890abc.cloudfront.net"
      backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix     = "mysql-dumps"
      mysql_volume_id   = "vol-0123456789abcdef0"
    }))) == 1
    error_message = "The BFF must reach the domain service via http://domain-service:8080 on the cv network, never the public EIP"
  }

  # Ruling 5: AUTH_ENABLED=true on BOTH containers -- the BFF defaults it off
  # (meta CLAUDE.md, local dev only), which would be wrong deployed (every
  # /bff/api/v1 route would be anonymous, not just the contract's allowlist).
  assert {
    condition = length(regexall("-e AUTH_ENABLED=true", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region        = var.aws_region
      project_name      = var.project_name
      environment       = var.environment
      image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name           = var.db_name
      db_username       = var.db_username
      cloudfront_domain = "d1234567890abc.cloudfront.net"
      backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix     = "mysql-dumps"
      mysql_volume_id   = "vol-0123456789abcdef0"
    }))) == 2
    error_message = "AUTH_ENABLED=true must be set on both the domain service and the BFF containers"
  }

  # Ruling 5: the BFF reads its issuer from SSM exactly as the domain service
  # does (COGNITO_ISSUER_URI is read once at boot into $COGNITO_ISSUER_URI,
  # then passed to both containers -- never a literal baked into either).
  assert {
    condition = length(regexall("-e COGNITO_ISSUER_URI=\"\\$COGNITO_ISSUER_URI\"", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region        = var.aws_region
      project_name      = var.project_name
      environment       = var.environment
      image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name           = var.db_name
      db_username       = var.db_username
      cloudfront_domain = "d1234567890abc.cloudfront.net"
      backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix     = "mysql-dumps"
      mysql_volume_id   = "vol-0123456789abcdef0"
    }))) == 2
    error_message = "Both the domain service and the BFF must read COGNITO_ISSUER_URI from the same SSM-sourced shell variable, never a literal"
  }

  # Ruling 6: CORS_ALLOWED_ORIGINS on the BFF is EXACTLY https://<cloudfront
  # domain> -- closing quote right after the domain discriminates this from
  # the domain service's own (longer, comma-separated) CORS value, so this
  # also proves the BFF does NOT inherit the localhost dev origins.
  # cv-public-react needs no entry -- it fetches server-side under ISR, so
  # CORS never applies to it; not asserted here since there's nothing to
  # assert an absence of.
  assert {
    condition = length(regexall("-e CORS_ALLOWED_ORIGINS=\"https://d1234567890abc\\.cloudfront\\.net\"", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region        = var.aws_region
      project_name      = var.project_name
      environment       = var.environment
      image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name           = var.db_name
      db_username       = var.db_username
      cloudfront_domain = "d1234567890abc.cloudfront.net"
      backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix     = "mysql-dumps"
      mysql_volume_id   = "vol-0123456789abcdef0"
    }))) == 1
    error_message = "The BFF's CORS_ALLOWED_ORIGINS must include https://<cloudfront_domain>"
  }

  # Scope 2: the same retry-until-the-image-exists pattern as the domain
  # service -- the BFF image won't exist on first boot either. Matched
  # against the rendered fixture value (bff_image is already substituted by
  # templatefile by this point, not the literal "$${bff_image}" placeholder).
  assert {
    condition = length(regexall("until docker pull \"\\$CV_BFF_IMAGE\"; do", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region        = var.aws_region
      project_name      = var.project_name
      environment       = var.environment
      image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name           = var.db_name
      db_username       = var.db_username
      cloudfront_domain = "d1234567890abc.cloudfront.net"
      backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix     = "mysql-dumps"
      mysql_volume_id   = "vol-0123456789abcdef0"
    }))) == 1
    error_message = "The BFF image pull must retry until the image exists, same pattern as the domain service's own pull loop"
  }

  # Review round 1 (T-014): the BFF block must run AFTER the MySQL backup
  # service/timer are installed and enabled, not before -- otherwise an
  # absent BFF image blocks forever in the `until docker pull` loop and the
  # nightly backup (T-001) is silently never installed. Split the rendered
  # script on the backup timer's `systemctl enable --now` line (present
  # exactly once) and assert the BFF's `docker run` line exists only in the
  # half AFTER that split, never in the half before it.
  assert {
    condition = length(split("systemctl enable --now mysql-backup.timer", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region        = var.aws_region
      project_name      = var.project_name
      environment       = var.environment
      image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name           = var.db_name
      db_username       = var.db_username
      cloudfront_domain = "d1234567890abc.cloudfront.net"
      backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix     = "mysql-dumps"
      mysql_volume_id   = "vol-0123456789abcdef0"
    }))) == 2
    error_message = "systemctl enable --now mysql-backup.timer must appear exactly once in the rendered script"
  }

  assert {
    condition = length(regexall("(?m)^cv_run_bff_node$", split("systemctl enable --now mysql-backup.timer", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region        = var.aws_region
      project_name      = var.project_name
      environment       = var.environment
      image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name           = var.db_name
      db_username       = var.db_username
      cloudfront_domain = "d1234567890abc.cloudfront.net"
      backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix     = "mysql-dumps"
      mysql_volume_id   = "vol-0123456789abcdef0"
    }))[0])) == 0
    error_message = "The BFF start (cv_run_bff_node) must NOT run before the MySQL backup timer is enabled -- a missing BFF image must never block the nightly backup from being installed (T-014 review round 1)"
  }

  assert {
    condition = length(regexall("(?m)^cv_run_bff_node$", split("systemctl enable --now mysql-backup.timer", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region        = var.aws_region
      project_name      = var.project_name
      environment       = var.environment
      image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name           = var.db_name
      db_username       = var.db_username
      cloudfront_domain = "d1234567890abc.cloudfront.net"
      backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix     = "mysql-dumps"
      mysql_volume_id   = "vol-0123456789abcdef0"
    }))[1])) == 1
    error_message = "The BFF start (cv_run_bff_node) must run AFTER the MySQL backup timer is enabled (T-014 review round 1)"
  }

  # T-044: ONE definition of each container's run arguments. Every docker run
  # for these four containers' services sits in exactly one place (the library
  # written to /usr/local/lib/cv-app.sh) and is sourced by both the boot flow
  # and cv-redeploy -- so each appears exactly once in the script.
  assert {
    condition = alltrue([
      for pat in [
        "docker run -d --name domain-service ",
        "docker run -d --name bff-node ",
        "flyway/flyway:13\\.7\\.0 migrate",
        ] : length(regexall(pat, templatefile("${path.module}/templates/domain-service-provision.sh", {
          aws_region        = var.aws_region
          project_name      = var.project_name
          environment       = var.environment
          image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
          bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
          db_name           = var.db_name
          db_username       = var.db_username
          cloudfront_domain = "d1234567890abc.cloudfront.net"
          backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
          backup_prefix     = "mysql-dumps"
          mysql_volume_id   = "vol-0123456789abcdef0"
      }))) == 1
    ])
    error_message = "docker run for domain-service, bff-node and flyway must each appear exactly once in the provisioning script (inside their cv_run_* function), shared by boot and cv-redeploy (T-044)"
  }

  assert {
    condition = alltrue([
      for fn in ["cv_run_flyway", "cv_run_domain_service", "cv_run_bff_node"] :
      length(regexall("(?m)^${fn}\\(\\) \\{$", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region        = var.aws_region
        project_name      = var.project_name
        environment       = var.environment
        image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name           = var.db_name
        db_username       = var.db_username
        cloudfront_domain = "d1234567890abc.cloudfront.net"
        backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix     = "mysql-dumps"
        mysql_volume_id   = "vol-0123456789abcdef0"
      }))) == 1
    ])
    error_message = "cv_run_flyway, cv_run_domain_service and cv_run_bff_node must each be defined exactly once (T-044)"
  }

  # The boot flow calls each function; cv-redeploy calls them by name too.
  assert {
    condition = alltrue([
      for fn in ["cv_run_flyway", "cv_run_domain_service", "cv_run_bff_node"] :
      length(regexall("(?m)^[ ]*${fn}$", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region        = var.aws_region
        project_name      = var.project_name
        environment       = var.environment
        image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name           = var.db_name
        db_username       = var.db_username
        cloudfront_domain = "d1234567890abc.cloudfront.net"
        backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix     = "mysql-dumps"
        mysql_volume_id   = "vol-0123456789abcdef0"
      }))) >= 1
    ])
    error_message = "the boot flow must call cv_run_flyway, cv_run_domain_service and cv_run_bff_node (T-044)"
  }

  # Boot order: MySQL, Flyway, domain-service, backup timer, BFF last.
  assert {
    condition = alltrue([
      length(regexall("(?s)docker run -d --name mysql .*\ncv_run_flyway\n.*\ncv_run_domain_service\n.*systemctl enable --now mysql-backup\\.timer.*\ncv_run_bff_node\n", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region        = var.aws_region
        project_name      = var.project_name
        environment       = var.environment
        image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name           = var.db_name
        db_username       = var.db_username
        cloudfront_domain = "d1234567890abc.cloudfront.net"
        backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix     = "mysql-dumps"
        mysql_volume_id   = "vol-0123456789abcdef0"
      }))) == 1
    ])
    error_message = "boot order must be mysql, cv_run_flyway, cv_run_domain_service, backup timer, cv_run_bff_node (T-014 round 1 ordering)"
  }

  # The images the functions use are rendered into the library.
  assert {
    condition = (
      length(regexall("CV_BFF_IMAGE=\"123456789012\\.dkr\\.ecr\\.eu-west-3\\.amazonaws\\.com/cv-project-bff-node:latest\"", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region        = var.aws_region
        project_name      = var.project_name
        environment       = var.environment
        image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name           = var.db_name
        db_username       = var.db_username
        cloudfront_domain = "d1234567890abc.cloudfront.net"
        backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix     = "mysql-dumps"
        mysql_volume_id   = "vol-0123456789abcdef0"
      }))) == 1 &&
      length(regexall("CV_DOMAIN_IMAGE=\"123456789012\\.dkr\\.ecr\\.eu-west-3\\.amazonaws\\.com/cv-project-domain-service:latest\"", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region        = var.aws_region
        project_name      = var.project_name
        environment       = var.environment
        image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name           = var.db_name
        db_username       = var.db_username
        cloudfront_domain = "d1234567890abc.cloudfront.net"
        backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix     = "mysql-dumps"
        mysql_volume_id   = "vol-0123456789abcdef0"
      }))) == 1
    )
    error_message = "the library must define CV_DOMAIN_IMAGE and CV_BFF_IMAGE from the ECR repo URLs"
  }

  # cv-redeploy: only the allowed verbs, root-only, strict mode, no secrets.
  assert {
    condition = (
      length(regexall("chmod 750 /usr/local/bin/cv-redeploy", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region        = var.aws_region
        project_name      = var.project_name
        environment       = var.environment
        image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name           = var.db_name
        db_username       = var.db_username
        cloudfront_domain = "d1234567890abc.cloudfront.net"
        backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix     = "mysql-dumps"
        mysql_volume_id   = "vol-0123456789abcdef0"
      }))) == 1 &&
      length(regexall("(?m)^  migrate\\)", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region        = var.aws_region
        project_name      = var.project_name
        environment       = var.environment
        image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name           = var.db_name
        db_username       = var.db_username
        cloudfront_domain = "d1234567890abc.cloudfront.net"
        backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix     = "mysql-dumps"
        mysql_volume_id   = "vol-0123456789abcdef0"
      }))) == 1 &&
      length(regexall("(?m)^  domain-service\\)", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region        = var.aws_region
        project_name      = var.project_name
        environment       = var.environment
        image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name           = var.db_name
        db_username       = var.db_username
        cloudfront_domain = "d1234567890abc.cloudfront.net"
        backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix     = "mysql-dumps"
        mysql_volume_id   = "vol-0123456789abcdef0"
      }))) == 1 &&
      length(regexall("(?m)^  bff-node\\)", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region        = var.aws_region
        project_name      = var.project_name
        environment       = var.environment
        image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name           = var.db_name
        db_username       = var.db_username
        cloudfront_domain = "d1234567890abc.cloudfront.net"
        backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix     = "mysql-dumps"
        mysql_volume_id   = "vol-0123456789abcdef0"
      }))) == 1
    )
    error_message = "cv-redeploy must be installed 0750 and handle exactly migrate, domain-service and bff-node (T-044)"
  }
}

# ---------------------------------------------------------------------------
# T-044 -- the app host's user_data is a small fetch-verify-run stub; the full
# script is a private S3 object whose SHA-256 is in SSM AND embedded in the
# stub (so a script edit still replaces the host).
# ---------------------------------------------------------------------------
run "app_host_bootstrap_stub" {
  command = plan

  assert {
    condition = length(templatefile("${path.module}/templates/domain-service-bootstrap.sh", {
      aws_region       = var.aws_region
      project_name     = var.project_name
      environment      = var.environment
      artifact_bucket  = "cv-project-ci-artifacts-dev"
      artifact_key     = "app-host/provision.sh"
      provision_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    })) <= 2048
    error_message = "the app host's user_data stub must stay <= 2,048 bytes (T-044): the real script lives in S3"
  }

  assert {
    condition = (
      length(regexall("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", templatefile("${path.module}/templates/domain-service-bootstrap.sh", {
        aws_region       = var.aws_region
        project_name     = var.project_name
        environment      = var.environment
        artifact_bucket  = "cv-project-ci-artifacts-dev"
        artifact_key     = "app-host/provision.sh"
        provision_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      }))) >= 1 &&
      length(regexall("s3://cv-project-ci-artifacts-dev/app-host/provision\\.sh", templatefile("${path.module}/templates/domain-service-bootstrap.sh", {
        aws_region       = var.aws_region
        project_name     = var.project_name
        environment      = var.environment
        artifact_bucket  = "cv-project-ci-artifacts-dev"
        artifact_key     = "app-host/provision.sh"
        provision_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      }))) >= 1 &&
      length(regexall("/cv-project/dev/app/provision-sha256", templatefile("${path.module}/templates/domain-service-bootstrap.sh", {
        aws_region       = var.aws_region
        project_name     = var.project_name
        environment      = var.environment
        artifact_bucket  = "cv-project-ci-artifacts-dev"
        artifact_key     = "app-host/provision.sh"
        provision_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      }))) >= 1
    )
    error_message = "the stub must embed the script hash, fetch s3://<bucket>/app-host/provision.sh, and read /cv-project/<env>/app/provision-sha256 (T-044)"
  }

  assert {
    condition     = aws_instance.domain_service.user_data_replace_on_change == true
    error_message = "aws_instance.domain_service must keep user_data_replace_on_change = true (T-044 H1 point 1)"
  }

  assert {
    condition     = aws_s3_object.app_host_provision.key == "app-host/provision.sh"
    error_message = "the app host provisioning script must live at app-host/provision.sh in the ci_artifacts bucket"
  }

  assert {
    condition     = aws_ssm_parameter.app_host_provision_sha256.name == "/${var.project_name}/${var.environment}/app/provision-sha256" && aws_ssm_parameter.app_host_provision_sha256.type == "String"
    error_message = "the script hash must be the String parameter /<project>/<env>/app/provision-sha256"
  }
}

# Applied (mocked) and scoped with plan_options.target to the IAM policy so
# null_resource.jenkins_provision's real local-exec is never reached -- same
# rationale as backup_iam_scoping.
run "app_host_provision_iam_scoping" {
  command = apply

  plan_options {
    target = [
      aws_iam_role_policy.app_read_provision_script,
    ]
  }

  assert {
    condition     = aws_iam_role_policy.app_read_provision_script.role == aws_iam_role.domain_service.id
    error_message = "the provision-script read grant must attach to the domain_service role"
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.app_read_provision_script.policy).Statement) == 1 &&
      jsondecode(aws_iam_role_policy.app_read_provision_script.policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.app_read_provision_script.policy).Statement[0].Action == ["s3:GetObject"]
    )
    error_message = "the grant must be a single Allow of exactly s3:GetObject"
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.app_read_provision_script.policy).Statement[0].Resource == "${aws_s3_bucket.ci_artifacts.arn}/app-host/provision.sh"
    error_message = "the grant's Resource must be exactly the app-host/provision.sh object ARN -- not the bucket, not a wildcard"
  }
}

# ---------------------------------------------------------------------------
# T-014 ruling 4 -- /metrics and /health must never rewrite to the SPA shell.
# functions/spa-router.js is plain JS read via file(), not a resource
# attribute, so this is a text assertion (same class as the CI Caddyfile
# regex checks above), not a CloudFront-function-execution test (CloudFront
# Functions don't run under mock_provider).
# ---------------------------------------------------------------------------
run "spa_router_excludes_metrics_and_health" {
  command = plan

  assert {
    condition     = length(regexall("uri === '/metrics' \\|\\| uri === '/health'", file("${path.module}/functions/spa-router.js"))) == 1
    error_message = "functions/spa-router.js must exclude /metrics and /health from the SPA rewrite so they never return the public shell (T-014 ruling 4)"
  }

  # The exclusion must return the request as-is, ahead of both the /admin/
  # and default rewrite branches -- not merely be present anywhere in the
  # file (e.g. in a comment).
  assert {
    condition     = length(regexall("uri === '/metrics' \\|\\| uri === '/health'\\) \\{\n    return request;\n  \\}", file("${path.module}/functions/spa-router.js"))) == 1
    error_message = "The /metrics /health exclusion must return the request unrewritten, ahead of the SPA rewrite branches"
  }
}

# ---------------------------------------------------------------------------
# T-043 -- the BFF's Cognito service token (client credentials): resource
# server + read scope, a secret-bearing client with only that flow, the SSM
# parameters, and the BFF container's env.
# ---------------------------------------------------------------------------
run "bff_service_token" {
  command = plan

  assert {
    condition = (
      aws_cognito_resource_server.cv_domain.identifier == "cv-domain" &&
      length(aws_cognito_resource_server.cv_domain.scope) == 1 &&
      one(aws_cognito_resource_server.cv_domain.scope).scope_name == "read"
    )
    error_message = "the cv-domain resource server must define exactly one scope, \"read\" (T-043)"
  }

  assert {
    condition     = aws_cognito_user_pool_client.bff_service.generate_secret == true
    error_message = "the BFF service client must have a secret (client credentials needs one)"
  }

  assert {
    condition = (
      aws_cognito_user_pool_client.bff_service.allowed_oauth_flows_user_pool_client == true &&
      toset(aws_cognito_user_pool_client.bff_service.allowed_oauth_flows) == toset(["client_credentials"]) &&
      length(aws_cognito_user_pool_client.bff_service.allowed_oauth_flows) == 1
    )
    error_message = "the BFF service client must allow ONLY the client_credentials flow"
  }

  assert {
    condition = (
      length(aws_cognito_user_pool_client.bff_service.allowed_oauth_scopes) == 1 &&
      one(aws_cognito_user_pool_client.bff_service.allowed_oauth_scopes) == "cv-domain/read"
    )
    error_message = "the BFF service client must have exactly the one scope cv-domain/read"
  }

  assert {
    condition = (
      aws_cognito_user_pool_client.bff_service.access_token_validity == 24 &&
      one(aws_cognito_user_pool_client.bff_service.token_validity_units).access_token == "hours"
    )
    error_message = "the BFF service client access token must be valid 24 hours (H1: ~$0.07/month)"
  }

  assert {
    condition = (
      aws_ssm_parameter.bff_service_client_secret.type == "SecureString" &&
      aws_ssm_parameter.bff_service_client_id.type == "String" &&
      aws_ssm_parameter.bff_token_url.type == "String" &&
      aws_ssm_parameter.bff_token_scope.type == "String"
    )
    error_message = "the BFF client secret must be a SecureString; id, token URL and scope are plain Strings"
  }

  assert {
    condition = (
      aws_ssm_parameter.bff_service_client_id.name == "/${var.project_name}/${var.environment}/bff/service-client-id" &&
      aws_ssm_parameter.bff_service_client_secret.name == "/${var.project_name}/${var.environment}/bff/service-client-secret" &&
      aws_ssm_parameter.bff_token_url.name == "/${var.project_name}/${var.environment}/bff/token-url" &&
      aws_ssm_parameter.bff_token_scope.name == "/${var.project_name}/${var.environment}/bff/token-scope" &&
      aws_ssm_parameter.bff_token_scope.value == "cv-domain/read" &&
      aws_ssm_parameter.bff_token_url.value == "https://${var.project_name}-${var.environment}.auth.${var.aws_region}.amazoncognito.com/oauth2/token"
    )
    error_message = "BFF SSM parameter names/values under /<project>/<env>/bff/ are wrong"
  }

  # The BFF docker run passes all four env vars, the secret from a shell
  # variable (never inlined), and still comes after the backup timer.
  assert {
    condition = alltrue([
      for pat in [
        "-e COGNITO_TOKEN_URL=\"\\$BFF_TOKEN_URL\"",
        "-e SERVICE_CLIENT_ID=\"\\$BFF_CLIENT_ID\"",
        "-e SERVICE_CLIENT_SECRET=\"\\$BFF_CLIENT_SECRET\"",
        "-e SERVICE_TOKEN_SCOPE=\"\\$BFF_TOKEN_SCOPE\"",
        ] : length(regexall(pat, templatefile("${path.module}/templates/domain-service-provision.sh", {
          aws_region        = var.aws_region
          project_name      = var.project_name
          environment       = var.environment
          image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
          bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
          db_name           = var.db_name
          db_username       = var.db_username
          cloudfront_domain = "d1234567890abc.cloudfront.net"
          backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
          backup_prefix     = "mysql-dumps"
          mysql_volume_id   = "vol-0123456789abcdef0"
      }))) == 1
    ])
    error_message = "the BFF docker run (cv_run_bff_node) must pass COGNITO_TOKEN_URL, SERVICE_CLIENT_ID, SERVICE_CLIENT_SECRET, SERVICE_TOKEN_SCOPE from shell variables (T-043)"
  }

  assert {
    condition = alltrue([
      for p in ["bff/service-client-id", "bff/service-client-secret", "bff/token-url", "bff/token-scope"] :
      length(regexall("\\(param ${p}\\)", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region        = var.aws_region
        project_name      = var.project_name
        environment       = var.environment
        image             = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image         = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name           = var.db_name
        db_username       = var.db_username
        cloudfront_domain = "d1234567890abc.cloudfront.net"
        backup_bucket     = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix     = "mysql-dumps"
        mysql_volume_id   = "vol-0123456789abcdef0"
      }))) == 1
    ])
    error_message = "user_data must read each of the four bff/* parameters once via param()"
  }
}

# T-045 -- GitHub Actions OIDC provider + the cv-public-vanilla deploy role.
# ---------------------------------------------------------------------------
# Applied under mock_provider, scoped with plan_options.target to the
# role/policy/provider so null_resource.jenkins_provision (real `aws ssm`
# local-exec) is never reached -- same rationale as "backup_iam_scoping". The
# bucket, distribution and provider ARNs are unknown at plan, which would make
# both policy documents unknown strings; under apply the mock fills them in,
# so the decoded policy JSON is compared against the resource ARNs by
# reference. The SPA-router function is overridden because the mock's random
# ARN fails provider validation. What stays unassertable
# offline: that the real ARNs have the right format and that AWS accepts the
# provider/trust (T-045's live simulate-principal-policy criterion covers it).
# ---------------------------------------------------------------------------
run "github_oidc_public_vanilla_deploy" {
  command = apply

  plan_options {
    target = [
      aws_iam_role_policy.public_vanilla_deploy,
      aws_iam_role.public_vanilla_deploy,
      output.public_vanilla_deploy_role_arn,
    ]
  }

  override_resource {
    target = aws_cloudfront_function.spa_router
    values = {
      arn = "arn:aws:cloudfront::123456789012:function/spa-router"
    }
  }

  assert {
    condition = (
      aws_iam_openid_connect_provider.github_actions.url == "https://token.actions.githubusercontent.com" &&
      toset(aws_iam_openid_connect_provider.github_actions.client_id_list) == toset(["sts.amazonaws.com"]) &&
      length(aws_iam_openid_connect_provider.github_actions.client_id_list) == 1
    )
    error_message = "the GitHub OIDC provider must be token.actions.githubusercontent.com with the single client id sts.amazonaws.com (T-045)"
  }

  # Trust: one statement, federated principal = our provider, web-identity
  # only, exact aud and exact master-only sub (StringEquals, no wildcard).
  assert {
    condition = (
      length(jsondecode(aws_iam_role.public_vanilla_deploy.assume_role_policy).Statement) == 1 &&
      jsondecode(aws_iam_role.public_vanilla_deploy.assume_role_policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role.public_vanilla_deploy.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(aws_iam_role.public_vanilla_deploy.assume_role_policy).Statement[0].Principal == {
        Federated = aws_iam_openid_connect_provider.github_actions.arn
      }
    )
    error_message = "the deploy role must trust only sts:AssumeRoleWithWebIdentity from the GitHub OIDC provider (T-045)"
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.public_vanilla_deploy.assume_role_policy).Statement[0].Condition == {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:erfeamor/cv-public-vanilla:ref:refs/heads/master"
        }
      }
    )
    error_message = "the trust condition must be exactly StringEquals aud=sts.amazonaws.com and sub=repo:erfeamor/cv-public-vanilla:ref:refs/heads/master, nothing else (T-045)"
  }

  assert {
    condition     = aws_iam_role.public_vanilla_deploy.max_session_duration == 3600
    error_message = "the deploy role keeps the default 1 h session (T-045)"
  }

  # Permissions.
  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.public_vanilla_deploy.policy).Statement) == 4 &&
      length([for s in jsondecode(aws_iam_role_policy.public_vanilla_deploy.policy).Statement : s if s.Effect == "Allow"]) == 3 &&
      length([for s in jsondecode(aws_iam_role_policy.public_vanilla_deploy.policy).Statement : s if s.Effect == "Deny"]) == 1
    )
    error_message = "the deploy policy must be exactly three Allow statements and one Deny (T-045)"
  }

  assert {
    condition = contains([
      for s in jsondecode(aws_iam_role_policy.public_vanilla_deploy.policy).Statement :
      jsonencode({ Effect = s.Effect, Action = sort(tolist(flatten([s.Action]))), Resource = sort(tolist(flatten([s.Resource]))) })
    ], jsonencode({ Effect = "Allow", Action = ["s3:ListBucket"], Resource = [aws_s3_bucket.frontend.arn] }))
    error_message = "must Allow s3:ListBucket on the frontend bucket ARN only (T-045)"
  }

  assert {
    condition = contains([
      for s in jsondecode(aws_iam_role_policy.public_vanilla_deploy.policy).Statement :
      jsonencode({ Effect = s.Effect, Action = sort(tolist(flatten([s.Action]))), Resource = sort(tolist(flatten([s.Resource]))) })
    ], jsonencode({ Effect = "Allow", Action = ["s3:DeleteObject", "s3:PutObject"], Resource = ["${aws_s3_bucket.frontend.arn}/*"] }))
    error_message = "must Allow s3:PutObject and s3:DeleteObject on <frontend bucket>/* only (T-045)"
  }

  assert {
    condition = contains([
      for s in jsondecode(aws_iam_role_policy.public_vanilla_deploy.policy).Statement :
      jsonencode({ Effect = s.Effect, Action = sort(tolist(flatten([s.Action]))), Resource = sort(tolist(flatten([s.Resource]))) })
    ], jsonencode({ Effect = "Allow", Action = ["cloudfront:CreateInvalidation"], Resource = [aws_cloudfront_distribution.frontend.arn] }))
    error_message = "must Allow cloudfront:CreateInvalidation on the frontend distribution ARN only (T-045)"
  }

  # The live admin shares the bucket; the site deploys to the root.
  assert {
    condition = contains([
      for s in jsondecode(aws_iam_role_policy.public_vanilla_deploy.policy).Statement :
      jsonencode({ Effect = s.Effect, Action = sort(tolist(flatten([s.Action]))), Resource = sort(tolist(flatten([s.Resource]))) })
    ], jsonencode({ Effect = "Deny", Action = ["s3:DeleteObject", "s3:PutObject"], Resource = ["${aws_s3_bucket.frontend.arn}/admin/*"] }))
    error_message = "must explicitly Deny s3:PutObject and s3:DeleteObject on <frontend bucket>/admin/* (T-045)"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.public_vanilla_deploy.policy).Statement :
      alltrue([for a in flatten([s.Action]) : a != "*" && !endswith(a, ":*")]) &&
      alltrue([for r in flatten([s.Resource]) : r != "*"]) &&
      !contains(keys(s), "NotAction") && !contains(keys(s), "NotResource")
    ])
    error_message = "the deploy policy must have no wildcard action, no bare \"*\" resource, and no NotAction/NotResource (T-045)"
  }

  assert {
    condition     = output.public_vanilla_deploy_role_arn == aws_iam_role.public_vanilla_deploy.arn
    error_message = "output public_vanilla_deploy_role_arn must expose the deploy role ARN (T-045)"
  }
}

# --- T-035: app host on Graviton (t4g.micro, arm64 AMI), IMDSv2, safe ECR ---
run "t035_app_host_graviton" {
  command = plan

  assert {
    condition     = var.domain_service_instance_type == "t4g.micro"
    error_message = "the app host defaults to t4g.micro (T-035, -$1.75/month vs t3.micro)"
  }

  assert {
    condition     = aws_instance.domain_service.instance_type == "t4g.micro"
    error_message = "aws_instance.domain_service must plan as t4g.micro"
  }

  # The app host and the CI host use DIFFERENT AMI lookups: the CI host stays x86.
  assert {
    condition     = aws_instance.domain_service.ami == data.aws_ami.al2023_arm64.id
    error_message = "the app host must use the arm64 AMI lookup (data.aws_ami.al2023_arm64)"
  }

  assert {
    condition     = aws_instance.drone.ami == data.aws_ami.al2023.id && data.aws_ami.al2023.id != data.aws_ami.al2023_arm64.id
    error_message = "the CI host must keep the x86 lookup (data.aws_ami.al2023), distinct from the app host's"
  }

  assert {
    condition     = contains(flatten([for f in data.aws_ami.al2023_arm64.filter : f.values]), "al2023-ami-2023.*-arm64") && contains(flatten([for f in data.aws_ami.al2023_arm64.filter : f.values]), "arm64")
    error_message = "data.aws_ami.al2023_arm64 must filter the plain AL2023 name pattern AND architecture = arm64"
  }

  assert {
    condition     = alltrue(flatten([for f in data.aws_ami.al2023_arm64.filter : [for v in f.values : !can(regex("ecs", v))]]))
    error_message = "the arm64 lookup must not match the ECS-optimized variant"
  }

  assert {
    condition     = contains(flatten([for f in data.aws_ami.al2023.filter : f.values]), "al2023-ami-2023.*-x86_64")
    error_message = "the CI host's lookup must stay x86_64"
  }

  # T-005's app-host half: IMDSv2 only, hop limit 1 (a bridge container is one hop away).
  assert {
    condition     = aws_instance.domain_service.metadata_options[0].http_tokens == "required"
    error_message = "the app host must require IMDSv2 tokens"
  }

  assert {
    condition     = aws_instance.domain_service.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "the app host's IMDS hop limit must be 1 so a bridge container gets no credentials"
  }

  assert {
    condition     = aws_instance.domain_service.metadata_options[0].http_endpoint == "enabled"
    error_message = "the app host's IMDS endpoint must stay enabled (the host's own param() reads need it)"
  }
}

# An x86 type on the arm64 AMI (or vice versa) must fail at plan time.
run "t035_arch_mismatch_rejected" {
  command = plan

  variables {
    domain_service_instance_type = "t3.micro"
  }

  expect_failures = [aws_instance.domain_service]
}

# ---------------------------------------------------------------------------
# T-047: GitHub OIDC deploy roles for cv-domain-service and cv-bff-node, and one
# parameterless SSM document per service that runs only `cv-redeploy <svc>`.
# Apply is scoped with plan_options.target (as the T-045 run above), so
# null_resource.jenkins_provision's local-exec is never reached.
# ---------------------------------------------------------------------------
run "t047_ci_deploy_roles" {
  command = apply

  plan_options {
    target = [
      aws_iam_role_policy.domain_service_deploy,
      aws_iam_role_policy.bff_node_deploy,
      aws_ssm_document.redeploy_domain_service,
      aws_ssm_document.redeploy_bff_node,
      output.domain_service_deploy_role_arn,
      output.bff_node_deploy_role_arn,
      output.domain_service_redeploy_document,
      output.bff_node_redeploy_document,
    ]
  }

  # --- domain-service: trust ---
  assert {
    condition = (
      length(jsondecode(aws_iam_role.domain_service_deploy.assume_role_policy).Statement) == 1 &&
      jsondecode(aws_iam_role.domain_service_deploy.assume_role_policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role.domain_service_deploy.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(aws_iam_role.domain_service_deploy.assume_role_policy).Statement[0].Principal == {
        Federated = aws_iam_openid_connect_provider.github_actions.arn
      }
    )
    error_message = "domain-service deploy role must trust only sts:AssumeRoleWithWebIdentity from the GitHub OIDC provider (T-047)"
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.domain_service_deploy.assume_role_policy).Statement[0].Condition == {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:erfeamor/cv-domain-service:ref:refs/heads/master"
        }
      }
    )
    error_message = "domain-service trust must be exactly StringEquals aud=sts.amazonaws.com and sub=repo:erfeamor/cv-domain-service:ref:refs/heads/master (T-047)"
  }

  assert {
    condition     = aws_iam_role.domain_service_deploy.name == "${var.project_name}-domain-service-deploy" && aws_iam_role.domain_service_deploy.max_session_duration == 3600
    error_message = "domain-service deploy role name and 1 h session (T-047)"
  }

  # --- domain-service: permissions ---
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.domain_service_deploy.policy).Statement) == 5 && alltrue([for s in jsondecode(aws_iam_role_policy.domain_service_deploy.policy).Statement : s.Effect == "Allow" && !contains(keys(s), "NotAction") && !contains(keys(s), "NotResource")])
    error_message = "domain-service deploy policy must be exactly five plain Allow statements (T-047)"
  }

  assert {
    condition = contains([
      for s in jsondecode(aws_iam_role_policy.domain_service_deploy.policy).Statement :
      jsonencode({ Action = sort(tolist(flatten([s.Action]))), Resource = sort(tolist(flatten([s.Resource]))) })
    ], jsonencode({ Action = ["ecr:GetAuthorizationToken"], Resource = ["*"] }))
    error_message = "domain-service must Allow ecr:GetAuthorizationToken on * (T-047)"
  }

  assert {
    condition = contains([
      for s in jsondecode(aws_iam_role_policy.domain_service_deploy.policy).Statement :
      jsonencode({ Action = sort(tolist(flatten([s.Action]))), Resource = sort(tolist(flatten([s.Resource]))) })
      ], jsonencode({
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
        ]
        Resource = [aws_ecr_repository.domain_service.arn]
    }))
    error_message = "domain-service must push to its own ECR repository ARN only, with exactly the seven push/read actions (T-047)"
  }

  assert {
    condition = contains([
      for s in jsondecode(aws_iam_role_policy.domain_service_deploy.policy).Statement :
      jsonencode({ Action = sort(tolist(flatten([s.Action]))), Resource = sort(tolist(flatten([s.Resource]))) })
    ], jsonencode({ Action = ["ssm:SendCommand"], Resource = [aws_ssm_document.redeploy_domain_service.arn] }))
    error_message = "domain-service must ssm:SendCommand on its own document ARN only (T-047)"
  }

  # Instances: the ARN pattern, only with the app-host Name tag condition.
  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.domain_service_deploy.policy).Statement : s
      if contains(flatten([s.Action]), "ssm:SendCommand") && flatten([s.Resource]) == ["arn:aws:ec2:${var.aws_region}:123456789012:instance/*"] &&
      lookup(s, "Condition", null) == { StringEquals = { "ssm:resourceTag/Name" = "${var.project_name}-domain-service" } }
    ]) == 1
    error_message = "domain-service must ssm:SendCommand on instance/* only under StringEquals ssm:resourceTag/Name = <project>-domain-service (T-047)"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.domain_service_deploy.policy).Statement : s
      if contains(flatten([s.Action]), "ssm:SendCommand")
      ]) == 2 && alltrue([
      for s in jsondecode(aws_iam_role_policy.domain_service_deploy.policy).Statement :
      contains(flatten([s.Action]), "ssm:SendCommand") ? (!contains(flatten([s.Resource]), "*") && (contains(keys(s), "Condition") || flatten([s.Resource]) == [aws_ssm_document.redeploy_domain_service.arn])) : true
    ])
    error_message = "domain-service: exactly two SendCommand statements; never * and instances never unconditioned (T-047)"
  }

  assert {
    condition = contains([
      for s in jsondecode(aws_iam_role_policy.domain_service_deploy.policy).Statement :
      jsonencode({ Action = sort(tolist(flatten([s.Action]))), Resource = sort(tolist(flatten([s.Resource]))) })
    ], jsonencode({ Action = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"], Resource = ["*"] }))
    error_message = "domain-service must read invocations with ssm:GetCommandInvocation and ssm:ListCommandInvocations on * (no resource-level support) (T-047)"
  }

  # `*` as a resource appears only on the three actions that cannot be scoped.
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.domain_service_deploy.policy).Statement :
      contains(flatten([s.Resource]), "*") ? toset(flatten([s.Action])) == toset(["ecr:GetAuthorizationToken"]) || toset(flatten([s.Action])) == toset(["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]) : true
    ])
    error_message = "domain-service: a bare * resource is allowed only for ecr:GetAuthorizationToken and the two invocation reads (T-047)"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.domain_service_deploy.policy).Statement :
      alltrue([for a in flatten([s.Action]) : a != "*" && !endswith(a, ":*")])
    ])
    error_message = "domain-service: no wildcard actions (T-047)"
  }

  # --- domain-service: the document ---
  assert {
    condition = (
      aws_ssm_document.redeploy_domain_service.name == "cv-redeploy-domain-service" &&
      aws_ssm_document.redeploy_domain_service.document_type == "Command" &&
      jsondecode(aws_ssm_document.redeploy_domain_service.content).schemaVersion == "2.2" &&
      !contains(keys(jsondecode(aws_ssm_document.redeploy_domain_service.content)), "parameters") &&
      length(jsondecode(aws_ssm_document.redeploy_domain_service.content).mainSteps) == 1 &&
      jsondecode(aws_ssm_document.redeploy_domain_service.content).mainSteps[0].action == "aws:runShellScript" &&
      jsondecode(aws_ssm_document.redeploy_domain_service.content).mainSteps[0].inputs.runCommand == ["/usr/local/bin/cv-redeploy domain-service"] &&
      jsondecode(aws_ssm_document.redeploy_domain_service.content).mainSteps[0].inputs.timeoutSeconds == "600"
    )
    error_message = "document cv-redeploy-domain-service must be schema 2.2, take no parameters, and run exactly /usr/local/bin/cv-redeploy domain-service (T-047)"
  }

  # --- bff-node: trust ---
  assert {
    condition = (
      length(jsondecode(aws_iam_role.bff_node_deploy.assume_role_policy).Statement) == 1 &&
      jsondecode(aws_iam_role.bff_node_deploy.assume_role_policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role.bff_node_deploy.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(aws_iam_role.bff_node_deploy.assume_role_policy).Statement[0].Principal == {
        Federated = aws_iam_openid_connect_provider.github_actions.arn
      }
    )
    error_message = "bff-node deploy role must trust only sts:AssumeRoleWithWebIdentity from the GitHub OIDC provider (T-047)"
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.bff_node_deploy.assume_role_policy).Statement[0].Condition == {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:erfeamor/cv-bff-node:ref:refs/heads/master"
        }
      }
    )
    error_message = "bff-node trust must be exactly StringEquals aud=sts.amazonaws.com and sub=repo:erfeamor/cv-bff-node:ref:refs/heads/master (T-047)"
  }

  assert {
    condition     = aws_iam_role.bff_node_deploy.name == "${var.project_name}-bff-node-deploy" && aws_iam_role.bff_node_deploy.max_session_duration == 3600
    error_message = "bff-node deploy role name and 1 h session (T-047)"
  }

  # --- bff-node: permissions ---
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.bff_node_deploy.policy).Statement) == 5 && alltrue([for s in jsondecode(aws_iam_role_policy.bff_node_deploy.policy).Statement : s.Effect == "Allow" && !contains(keys(s), "NotAction") && !contains(keys(s), "NotResource")])
    error_message = "bff-node deploy policy must be exactly five plain Allow statements (T-047)"
  }

  assert {
    condition = contains([
      for s in jsondecode(aws_iam_role_policy.bff_node_deploy.policy).Statement :
      jsonencode({ Action = sort(tolist(flatten([s.Action]))), Resource = sort(tolist(flatten([s.Resource]))) })
    ], jsonencode({ Action = ["ecr:GetAuthorizationToken"], Resource = ["*"] }))
    error_message = "bff-node must Allow ecr:GetAuthorizationToken on * (T-047)"
  }

  assert {
    condition = contains([
      for s in jsondecode(aws_iam_role_policy.bff_node_deploy.policy).Statement :
      jsonencode({ Action = sort(tolist(flatten([s.Action]))), Resource = sort(tolist(flatten([s.Resource]))) })
      ], jsonencode({
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
        ]
        Resource = [aws_ecr_repository.bff_node.arn]
    }))
    error_message = "bff-node must push to its own ECR repository ARN only, with exactly the seven push/read actions (T-047)"
  }

  assert {
    condition = contains([
      for s in jsondecode(aws_iam_role_policy.bff_node_deploy.policy).Statement :
      jsonencode({ Action = sort(tolist(flatten([s.Action]))), Resource = sort(tolist(flatten([s.Resource]))) })
    ], jsonencode({ Action = ["ssm:SendCommand"], Resource = [aws_ssm_document.redeploy_bff_node.arn] }))
    error_message = "bff-node must ssm:SendCommand on its own document ARN only (T-047)"
  }

  # Instances: the ARN pattern, only with the app-host Name tag condition.
  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.bff_node_deploy.policy).Statement : s
      if contains(flatten([s.Action]), "ssm:SendCommand") && flatten([s.Resource]) == ["arn:aws:ec2:${var.aws_region}:123456789012:instance/*"] &&
      lookup(s, "Condition", null) == { StringEquals = { "ssm:resourceTag/Name" = "${var.project_name}-domain-service" } }
    ]) == 1
    error_message = "bff-node must ssm:SendCommand on instance/* only under StringEquals ssm:resourceTag/Name = <project>-domain-service (T-047)"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.bff_node_deploy.policy).Statement : s
      if contains(flatten([s.Action]), "ssm:SendCommand")
      ]) == 2 && alltrue([
      for s in jsondecode(aws_iam_role_policy.bff_node_deploy.policy).Statement :
      contains(flatten([s.Action]), "ssm:SendCommand") ? (!contains(flatten([s.Resource]), "*") && (contains(keys(s), "Condition") || flatten([s.Resource]) == [aws_ssm_document.redeploy_bff_node.arn])) : true
    ])
    error_message = "bff-node: exactly two SendCommand statements; never * and instances never unconditioned (T-047)"
  }

  assert {
    condition = contains([
      for s in jsondecode(aws_iam_role_policy.bff_node_deploy.policy).Statement :
      jsonencode({ Action = sort(tolist(flatten([s.Action]))), Resource = sort(tolist(flatten([s.Resource]))) })
    ], jsonencode({ Action = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"], Resource = ["*"] }))
    error_message = "bff-node must read invocations with ssm:GetCommandInvocation and ssm:ListCommandInvocations on * (no resource-level support) (T-047)"
  }

  # `*` as a resource appears only on the three actions that cannot be scoped.
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.bff_node_deploy.policy).Statement :
      contains(flatten([s.Resource]), "*") ? toset(flatten([s.Action])) == toset(["ecr:GetAuthorizationToken"]) || toset(flatten([s.Action])) == toset(["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]) : true
    ])
    error_message = "bff-node: a bare * resource is allowed only for ecr:GetAuthorizationToken and the two invocation reads (T-047)"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.bff_node_deploy.policy).Statement :
      alltrue([for a in flatten([s.Action]) : a != "*" && !endswith(a, ":*")])
    ])
    error_message = "bff-node: no wildcard actions (T-047)"
  }

  # --- bff-node: the document ---
  assert {
    condition = (
      aws_ssm_document.redeploy_bff_node.name == "cv-redeploy-bff-node" &&
      aws_ssm_document.redeploy_bff_node.document_type == "Command" &&
      jsondecode(aws_ssm_document.redeploy_bff_node.content).schemaVersion == "2.2" &&
      !contains(keys(jsondecode(aws_ssm_document.redeploy_bff_node.content)), "parameters") &&
      length(jsondecode(aws_ssm_document.redeploy_bff_node.content).mainSteps) == 1 &&
      jsondecode(aws_ssm_document.redeploy_bff_node.content).mainSteps[0].action == "aws:runShellScript" &&
      jsondecode(aws_ssm_document.redeploy_bff_node.content).mainSteps[0].inputs.runCommand == ["/usr/local/bin/cv-redeploy bff-node"] &&
      jsondecode(aws_ssm_document.redeploy_bff_node.content).mainSteps[0].inputs.timeoutSeconds == "600"
    )
    error_message = "document cv-redeploy-bff-node must be schema 2.2, take no parameters, and run exactly /usr/local/bin/cv-redeploy bff-node (T-047)"
  }

  assert {
    condition = (
      output.domain_service_deploy_role_arn == aws_iam_role.domain_service_deploy.arn &&
      output.bff_node_deploy_role_arn == aws_iam_role.bff_node_deploy.arn &&
      output.domain_service_redeploy_document == "cv-redeploy-domain-service" &&
      output.bff_node_redeploy_document == "cv-redeploy-bff-node"
    )
    error_message = "T-047 outputs: both role ARNs and both document names"
  }
}

# ---------------------------------------------------------------------------
# T-049: the cv-database migrate role and its parameterless SSM document. Plan
# only (no apply), scoped by plan_options.target so nothing else is reached.
# The policy JSON embeds the own-document ARN (computed, unknown at plan), so
# the other two statements are asserted through their named local;
# scripts/check-static.sh 2c guards the document statement and the policy as a
# whole (no ecr) against the source.
# ---------------------------------------------------------------------------
run "t049_database_migrate" {
  command = plan

  plan_options {
    target = [
      aws_iam_role.database_migrate,
      aws_iam_role_policy.database_migrate,
      aws_ssm_document.redeploy_migrate,
      output.database_migrate_document,
    ]
  }

  # --- the document ---
  assert {
    condition = (
      aws_ssm_document.redeploy_migrate.name == "cv-redeploy-migrate" &&
      aws_ssm_document.redeploy_migrate.document_type == "Command" &&
      aws_ssm_document.redeploy_migrate.document_format == "JSON" &&
      jsondecode(aws_ssm_document.redeploy_migrate.content).schemaVersion == "2.2" &&
      !contains(keys(jsondecode(aws_ssm_document.redeploy_migrate.content)), "parameters") &&
      length(jsondecode(aws_ssm_document.redeploy_migrate.content).mainSteps) == 1 &&
      jsondecode(aws_ssm_document.redeploy_migrate.content).mainSteps[0].action == "aws:runShellScript" &&
      jsondecode(aws_ssm_document.redeploy_migrate.content).mainSteps[0].inputs.runCommand == ["/usr/local/bin/cv-redeploy migrate"] &&
      jsondecode(aws_ssm_document.redeploy_migrate.content).mainSteps[0].inputs.timeoutSeconds == "600" &&
      aws_ssm_document.redeploy_migrate.tags["Project"] == var.project_name
    )
    error_message = "document cv-redeploy-migrate must be schema 2.2, take no parameters, and run exactly /usr/local/bin/cv-redeploy migrate (T-049)"
  }

  # --- trust ---
  assert {
    condition = (
      length(jsondecode(aws_iam_role.database_migrate.assume_role_policy).Statement) == 1 &&
      jsondecode(aws_iam_role.database_migrate.assume_role_policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role.database_migrate.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(aws_iam_role.database_migrate.assume_role_policy).Statement[0].Principal == {
        Federated = aws_iam_openid_connect_provider.github_actions.arn
      }
    )
    error_message = "migrate role must trust only sts:AssumeRoleWithWebIdentity from the GitHub OIDC provider (T-049)"
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.database_migrate.assume_role_policy).Statement[0].Condition == {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:erfeamor/cv-database:ref:refs/heads/master"
        }
      }
    )
    error_message = "migrate trust must be exactly StringEquals aud=sts.amazonaws.com and sub=repo:erfeamor/cv-database:ref:refs/heads/master (T-049)"
  }

  assert {
    condition     = aws_iam_role.database_migrate.name == "${var.project_name}-database-migrate" && aws_iam_role.database_migrate.max_session_duration == 3600
    error_message = "migrate role name must be <project>-database-migrate with a 1 h session (T-049)"
  }

  # --- permissions: SSM only, no ECR ---
  assert {
    condition     = length(local.database_migrate_known_statements) == 2 && alltrue([for s in local.database_migrate_known_statements : s.Effect == "Allow" && !contains(keys(s), "NotAction") && !contains(keys(s), "NotResource")])
    error_message = "migrate: the instance-send and invocation-read statements must be plain Allows (T-049)"
  }

  assert {
    condition = alltrue([
      for s in local.database_migrate_known_statements :
      alltrue([for a in flatten([s.Action]) : startswith(a, "ssm:") && a != "ssm:*" && !endswith(a, ":*")])
    ])
    error_message = "migrate policy: only ssm: actions (no ecr:, no wildcards) (T-049)"
  }

  assert {
    condition = length([
      for s in local.database_migrate_known_statements : s
      if flatten([s.Action]) == ["ssm:SendCommand"] && flatten([s.Resource]) == ["arn:aws:ec2:${var.aws_region}:123456789012:instance/*"] &&
      lookup(s, "Condition", null) == { StringEquals = { "ssm:resourceTag/Name" = "${var.project_name}-domain-service" } }
    ]) == 1
    error_message = "migrate role must ssm:SendCommand on instance/* only under StringEquals ssm:resourceTag/Name = <project>-domain-service (T-049)"
  }

  assert {
    condition = length([for s in local.database_migrate_known_statements : s if contains(flatten([s.Action]), "ssm:SendCommand")]) == 1 && alltrue([
      for s in local.database_migrate_known_statements :
      contains(flatten([s.Action]), "ssm:SendCommand") ? (!contains(flatten([s.Resource]), "*") && contains(keys(s), "Condition")) : true
    ])
    error_message = "migrate: the instance SendCommand statement must be conditioned and never on * (T-049)"
  }

  assert {
    condition = contains([
      for s in local.database_migrate_known_statements :
      jsonencode({ Action = sort(tolist(flatten([s.Action]))), Resource = sort(tolist(flatten([s.Resource]))) })
    ], jsonencode({ Action = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"], Resource = ["*"] }))
    error_message = "migrate must read invocations with ssm:GetCommandInvocation and ssm:ListCommandInvocations on * (T-049)"
  }

  assert {
    condition     = output.database_migrate_document == "cv-redeploy-migrate"
    error_message = "database_migrate_document output must be the document name (T-049)"
  }
}

# --- T-048: the doorbell marks a push on an already-running CI host -------
# The policy JSON embeds the computed instance ARN, so (as for the other CI
# grants) the security-relevant pieces are named locals asserted here; the
# Resource scoping and ignore_changes are guarded by scripts/check-static.sh.
run "t048_push_tag" {
  command = plan

  assert {
    condition     = local.ci_push_tag_key == "CILastPush"
    error_message = "The push-marker tag key must be CILastPush (the operational tag the reaper reads)"
  }

  assert {
    condition     = join(",", local.ci_doorbell_tag_actions) == "ec2:CreateTags"
    error_message = "The doorbell's tagging grant must be ec2:CreateTags and nothing else (no DeleteTags, no wildcard)"
  }

  assert {
    condition     = jsonencode(local.ci_doorbell_tag_condition) == jsonencode({ "ForAllValues:StringEquals" = { "aws:TagKeys" = ["CILastPush"] } })
    error_message = "ec2:CreateTags must be conditioned on ForAllValues:StringEquals aws:TagKeys = [CILastPush] and nothing else -- the doorbell may stamp that one tag key, never any other"
  }

  assert {
    condition     = length(setintersection(local.ci_doorbell_tag_actions, local.ci_forbidden_ec2_actions)) == 0
    error_message = "The doorbell's tag grant intersects the forbidden destructive set"
  }

  assert {
    condition     = aws_lambda_function.ci_doorbell.environment[0].variables["PUSH_TAG"] == local.ci_push_tag_key
    error_message = "PUSH_TAG must be wired to the doorbell from local.ci_push_tag_key"
  }

  assert {
    condition     = aws_lambda_function.ci_reaper.environment[0].variables["PUSH_TAG"] == local.ci_push_tag_key
    error_message = "PUSH_TAG must be wired to the reaper from local.ci_push_tag_key (same key the doorbell writes)"
  }

  assert {
    condition     = aws_lambda_function.ci_reaper.environment[0].variables["PUSH_GRACE_MINUTES"] == "10"
    error_message = "PUSH_GRACE_MINUTES must be 10 on the reaper (T-048 H1)"
  }

  assert {
    condition     = join(",", local.ci_reaper_ec2_actions) == "ec2:StopInstances"
    error_message = "The reaper needs no new EC2 grant for T-048: it reads CILastPush from DescribeInstances"
  }
}

# T-050: ECR retention. Both repos come from one local (identical by
# construction). Rule 1 claims :latest (exact match), rule 2 keeps
# ecr_keep_tagged tagged images (`*` matches :latest too, so latest + 4 previous
# shas), rule 3 expires untagged beyond keep x children + orphan headroom.
run "t050_ecr_lifecycle_rules" {
  command = plan

  plan_options {
    target = [
      aws_ecr_lifecycle_policy.domain_service,
      aws_ecr_lifecycle_policy.bff_node,
    ]
  }

  assert {
    condition = alltrue([
      for p in [aws_ecr_lifecycle_policy.domain_service.policy, aws_ecr_lifecycle_policy.bff_node.policy] :
      length(jsondecode(p).rules) == 3 &&
      [for r in jsondecode(p).rules : r.rulePriority] == [1, 2, 3] &&
      jsondecode(p).rules[0].selection.tagStatus == "tagged" &&
      jsondecode(p).rules[0].selection.tagPatternList == ["latest"] &&
      !contains(keys(jsondecode(p).rules[0].selection), "tagPrefixList") &&
      jsondecode(p).rules[0].selection.countType == "imageCountMoreThan" &&
      jsondecode(p).rules[0].selection.countNumber == 1 &&
      jsondecode(p).rules[0].action.type == "expire" &&
      jsondecode(p).rules[1].selection.tagStatus == "tagged" &&
      jsondecode(p).rules[1].selection.tagPatternList == ["*"] &&
      jsondecode(p).rules[1].selection.countType == "imageCountMoreThan" &&
      jsondecode(p).rules[1].action.type == "expire" &&
      jsondecode(p).rules[2].selection.tagStatus == "untagged" &&
      jsondecode(p).rules[2].selection.countType == "imageCountMoreThan" &&
      jsondecode(p).rules[2].action.type == "expire"
    ])
    error_message = "both ECR policies must be: 1 = exact tagPatternList [latest] (no tagPrefixList), 2 = tagged pattern *, 3 = untagged; priorities 1,2,3"
  }

  # Rule 2 counts :latest too (lower rules still identify what a higher rule
  # matched), so 5 keeps latest + 4 previous shas.
  assert {
    condition = alltrue([
      for p in [aws_ecr_lifecycle_policy.domain_service.policy, aws_ecr_lifecycle_policy.bff_node.policy] :
      jsondecode(p).rules[1].selection.countNumber == 5
    ])
    error_message = "rule 2 must keep 5 tagged images: latest + the 4 previous shas"
  }

  # Both workflows build with provenance: false => 2 children per deploy. Rule 3
  # = 5 x 2 + 10 headroom.
  assert {
    condition = alltrue([
      for p in [aws_ecr_lifecycle_policy.domain_service.policy, aws_ecr_lifecycle_policy.bff_node.policy] :
      jsondecode(p).rules[2].selection.countNumber == 5 * 2 + 10
    ])
    error_message = "rule 3 must be keep (5) x children (2) + headroom (10) = 20"
  }

  # Headroom must absorb at least two failed deploys' orphaned children.
  assert {
    condition     = local.ecr_orphan_headroom >= 2 * local.ecr_children_per_index
    error_message = "orphan headroom must be at least 2 x children per index"
  }
}
