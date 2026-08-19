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
  github_webhook_secret      = "test-webhook-secret-not-real"

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

  # --- The size wall T-009 exists to prevent -------------------------------
  # This is the assertion T-009 asks for: user_data has grown 85.6% -> 91.1%
  # -> 94.4% -> 95.7% -> 98.3% across successive tasks, and exceeding 16,384 B
  # is NOT caught by fmt, validate, or a mocked plan -- it surfaces as an
  # apply-time API rejection while the live CI host is being modified. A red
  # test is a much better place to find out.
  assert {
    condition = length(join("\n", [
      templatefile("${path.module}/templates/drone-user-data.sh", {
        aws_region     = var.aws_region
        project_name   = var.project_name
        environment    = var.environment
        server_host    = "203.0.113.10"
        admin_username = var.drone_admin_username
      }),
      templatefile("${path.module}/templates/jenkins-provision.sh", {
        aws_region             = var.aws_region
        project_name           = var.project_name
        environment            = var.environment
        server_host            = "203.0.113.10"
        admin_username         = var.drone_admin_username
        jenkins_admin_username = var.jenkins_admin_username
      }),
    ])) < 16384
    error_message = "Rendered user_data for aws_instance.drone exceeds EC2's 16,384 byte limit. Do NOT fix this by trimming explanatory comments again -- that is the toll T-009 exists to stop paying. Move the provisioning script to S3 (T-009) instead."
  }

  # Ruling 1: the periodic scan is what makes the doorbell able to stay a pure
  # doorbell. Delete it and every cold start silently builds nothing.
  assert {
    condition = length(regexall("periodicFolderTrigger", templatefile("${path.module}/templates/jenkins-provision.sh", {
      aws_region             = var.aws_region
      project_name           = var.project_name
      environment            = var.environment
      server_host            = "203.0.113.10"
      admin_username         = var.drone_admin_username
      jenkins_admin_username = var.jenkins_admin_username
    }))) == 2
    error_message = "Both multibranch jobs must carry a periodicFolderTrigger -- without it a push that arrives while the CI host is stopped is never built (T-019 ruling 1)"
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
  assert {
    condition     = aws_lambda_permission.ci_doorbell_public_invoke.action == "lambda:InvokeFunction"
    error_message = "The doorbell needs an unconditioned lambda:InvokeFunction grant or its Function URL returns 403 without ever invoking the handler (verified live 2026-08-19)"
  }

  assert {
    condition     = aws_lambda_permission.ci_doorbell_public_invoke.principal == "*"
    error_message = "The public invoke grant must be Principal=* -- the auth boundary is the HMAC check in index.py, not this permission"
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
