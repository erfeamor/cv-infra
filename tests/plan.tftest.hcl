# Run with: terraform test
# Uses a mocked AWS provider so the plan runs without credentials or network
# access — data sources return the mock defaults below.

# T-061: CloudFront only accepts ACM certificates from us-east-1, so the root
# module declares a second, aliased provider; the tests need a matching mock
# or they would reach for real credentials.
mock_provider "aws" {
  alias = "us_east_1"
}

mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = {
      id         = "vpc-00000000000000000"
      cidr_block = "172.31.0.0/16" # the default VPC's real range (T-068 carves a /24 out of it)
    }
  }

  # T-068: CloudFront's managed VPC-origin security group (exists once a VPC
  # origin does); read at apply time, mocked here.
  mock_data "aws_security_group" {
    defaults = {
      id = "sg-0000000000000cf01"
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
      name    = "erfeamor.com" # the real data source has no trailing dot (found by the T-061 plan)
    }
  }

  # T-068: aws_cloudfront_vpc_origin validates its target as an ARN, and the
  # mock's random string is not one.
  mock_resource "aws_instance" {
    defaults = {
      arn = "arn:aws:ec2:eu-west-3:123456789012:instance/i-0123456789abcdef0"
    }
  }

  # T-068: the IPv6 block AWS assigns to the default VPC (a /56).
  mock_resource "aws_vpc_ipv6_cidr_block_association" {
    defaults = {
      ipv6_cidr_block = "2600:1f23:1234:5600::/56"
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

# T-035: the shared AMI mock above defaults to x86_64, so the app host's arm64
# lookup gets its own value (what the real lookup returns for the arm64 name + filter).
override_data {
  target = data.aws_ami.al2023_arm64
  values = {
    id           = "ami-00000000000000001"
    architecture = "arm64"
  }
}

variables {
  db_password = "test-password-not-real"

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
  # the unknown-until-apply ARNs elsewhere in this file: aws_sns_topic.budget_alerts.arn is
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
  # `command = plan` -- same documented limitation as
  # aws_sns_topic.budget_alerts.arn above. Those checks live in the
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
    condition     = aws_ebs_volume.mysql_data_v2.availability_zone == var.availability_zone
    error_message = "aws_ebs_volume.mysql_data_v2.availability_zone must come from var.availability_zone -- the same pinned source that selects aws_instance.domain_service's subnet, never a separately-computed AZ"
  }

  # Regression guard: the domain-service box MUST keep replacing on user_data
  # edits -- that's what makes this task's own acceptance criterion (apply twice,
  # prove the database survives replacement) a real test rather than a no-op.
  assert {
    condition     = aws_instance.domain_service.user_data_replace_on_change == true
    error_message = "aws_instance.domain_service must keep user_data_replace_on_change = true -- removing it means a bootstrap edit never re-provisions the box (this bug has shipped once already)"
  }

  assert {
    condition     = aws_ebs_volume.mysql_data_v2.size == 2 && aws_ebs_volume.mysql_data_v2.type == "gp3"
    error_message = "aws_ebs_volume.mysql_data_v2 should be a 2 GiB gp3 volume (T-066) -- a size/class bump is cost drift and needs an explicit, recorded decision (CLAUDE.md review guidance)"
  }

  assert {
    condition     = aws_ebs_volume.mysql_data_v2.encrypted == true
    error_message = "aws_ebs_volume.mysql_data_v2 must be encrypted at rest"
  }

  # aws_volume_attachment.mysql_data.volume_id/.instance_id and
  # aws_ebs_volume.mysql_data_v2.id are unknown-until-apply under `command =
  # plan` (same documented limitation as aws_s3_bucket.backup.arn above), and targeting them for a `command =
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
# above. mock_provider makes an apply of these two resources safe -- and
# plan_options.target below restricts this run to exactly the two backup
# resources and their dependencies.
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

# T-022 scoped 8080 to CloudFront's prefix list; T-068 removes the public
# address altogether and admits only CloudFront's VPC origins. These assertions
# pin that so a later edit cannot quietly widen it -- the failure they guard
# against reads as a working plan.
run "domain_service_ingress_scoped_to_cloudfront" {
  command = plan

  # The only way in is a standalone rule whose source is the managed
  # VPC-origin security group. That group is read at apply time (it exists
  # only once the origins do), so its id can't be compared here; check-static
  # pins the wiring.
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.domain_service_api.from_port == 8080 &&
      aws_vpc_security_group_ingress_rule.domain_service_api.to_port == 8080 &&
      aws_vpc_security_group_ingress_rule.domain_service_api.ip_protocol == "tcp"
    )
    error_message = "The 8080 ingress must be tcp/8080 (its source, CloudFront's VPC-origin group, is unknown at plan time; scripts/check-static.sh pins it)"
  }

  assert {
    condition     = data.aws_security_group.cloudfront_vpc_origins.name == "CloudFront-VPCOrigins-Service-SG"
    error_message = "The source must be CloudFront's managed VPC-origin security group"
  }

  # No CIDR or prefix list on either rule, so a public path can't reappear.
  assert {
    condition = alltrue([
      for r in [
        aws_vpc_security_group_ingress_rule.domain_service_api,
        aws_vpc_security_group_ingress_rule.bff_node,
      ] : r.cidr_ipv4 == null && r.cidr_ipv6 == null && r.prefix_list_id == null
    ])
    error_message = "The ingress rules may reference only the CloudFront VPC-origin security group (no CIDR, no prefix list)"
  }

  # IPv6 egress is how the host reaches AWS now.
  assert {
    condition = alltrue([
      for g in [aws_security_group.domain_service, aws_security_group.bff_node] :
      anytrue([for e in g.egress : contains(coalesce(e.ipv6_cidr_blocks, []), "::/0")])
    ])
    error_message = "The app host security groups must allow IPv6 egress (the host has no IPv4 route out)"
  }
}

# T-068: the host is private. No EIP anywhere, no public IPv4, IPv6 only out.
run "t068_app_host_has_no_public_ipv4" {
  command = plan

  assert {
    condition     = aws_instance.domain_service.associate_public_ip_address == false
    error_message = "The app host must not get a public IPv4 address"
  }

  assert {
    condition     = aws_instance.domain_service.ipv6_address_count == 1
    error_message = "The app host needs an IPv6 address"
  }

  assert {
    condition     = aws_instance.domain_service.metadata_options[0].http_protocol_ipv6 == "enabled"
    error_message = "IMDS must be reachable over IPv6"
  }

  assert {
    condition     = aws_subnet.app_private.map_public_ip_on_launch == false && aws_subnet.app_private.assign_ipv6_address_on_creation == true
    error_message = "The app subnet must hand out no public IPv4 and an IPv6 address"
  }

  assert {
    condition     = aws_subnet.app_private.availability_zone == var.availability_zone && aws_ebs_volume.mysql_data_v2.availability_zone == aws_subnet.app_private.availability_zone
    error_message = "The subnet and the data volume must be in the same AZ"
  }

  # Private: ::/0 goes out through the egress-only gateway, and there is no
  # IPv4 default route at all.
  assert {
    condition     = length(aws_route_table.app_private.route) == 1 && one(aws_route_table.app_private.route).ipv6_cidr_block == "::/0"
    error_message = "The app subnet's route table must have the single ::/0 route (egress-only), nothing else"
  }

  # Two VPC origins, one per port, both targeting the instance.
  assert {
    condition = (
      aws_cloudfront_vpc_origin.domain_service_api.vpc_origin_endpoint_config[0].http_port == 8080 &&
      aws_cloudfront_vpc_origin.bff_node.vpc_origin_endpoint_config[0].http_port == 3000 &&
      aws_cloudfront_vpc_origin.domain_service_api.vpc_origin_endpoint_config[0].origin_protocol_policy == "http-only" &&
      aws_cloudfront_vpc_origin.bff_node.vpc_origin_endpoint_config[0].origin_protocol_policy == "http-only"
    )
    error_message = "The VPC origins must be http-only on 8080 (domain service) and 3000 (BFF)"
  }

  # The host pulls images through the dual-stack ECR hostname (the classic one
  # is IPv4-only).
  assert {
    condition     = local.app_host_ecr_registry == "123456789012.dkr-ecr.${var.aws_region}.on.aws"
    error_message = "The host must use the dual-stack ECR registry hostname"
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

  # Ruling 1, the crux: port 3000 gets its OWN security group (kept since
  # T-068, when the quota reason went away but the separation did not).
  # Its only way in is the standalone rule from CloudFront's VPC-origin group.
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.bff_node.from_port == 3000 &&
      aws_vpc_security_group_ingress_rule.bff_node.to_port == 3000 &&
      aws_vpc_security_group_ingress_rule.bff_node.ip_protocol == "tcp"
    )
    error_message = "The BFF's 3000 ingress must be tcp/3000 (source pinned by scripts/check-static.sh)"
  }

  # Not asserted here, deliberately: that aws_instance.domain_service's
  # vpc_security_group_ids carries BOTH groups. Both referenced security
  # groups are new resources in this plan, so their .id (and therefore the
  # instance's set attribute built from them) is unknown-until-apply --
  # same documented class of limitation as
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

  # T-068: the origin is a VPC origin (no public address), not a custom
  # origin on the EIP's DNS name.
  assert {
    condition = alltrue([
      for o in aws_cloudfront_distribution.frontend.origin :
      length(o.custom_origin_config) == 0 && length(o.vpc_origin_config) == 1
      if o.origin_id == "bff-node" || o.origin_id == "domain-service-api"
    ])
    error_message = "The bff-node and domain-service-api origins must be VPC origins"
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
# templatefile() with fixture values because aws_instance.domain_service's OWN user_data
# embeds cloudfront_domain (aws_cloudfront_distribution.frontend.domain_name),
# unknown-until-apply under `command = plan`.
# ---------------------------------------------------------------------------
run "app_host_user_data" {
  command = plan

  # H1 refresh item 4 / N2, RED FIRST: EC2's hard user_data limit is 16,384
  # bytes. T-044: the full script no longer rides in user_data (it is an S3
  # object), so this guard on the SCRIPT is only a
  # sanity bound; the real user_data wall is guarded on the stub below.
  assert {
    condition = length(templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = var.aws_region
      project_name             = var.project_name
      environment              = var.environment
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = var.db_name
      db_username              = var.db_username
      cloudfront_domain        = "d1234567890abc.cloudfront.net"
      backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = "/cv-project/cv-domain-service"
      log_group_bff_node       = "/cv-project/cv-bff-node"
    })) <= 40000
    error_message = "Rendered domain-service-provision.sh exceeds 40,000 bytes -- it is an S3 object now (T-044), not user_data, but a script this big deserves a split"
  }

  # AC: production pins Flyway 13.7.0 (T-155/T-156), riding this apply's
  # instance replacement -- was flyway/flyway:10.
  assert {
    condition = length(regexall("flyway/flyway:13\\.7\\.0 migrate", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = var.aws_region
      project_name             = var.project_name
      environment              = var.environment
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = var.db_name
      db_username              = var.db_username
      cloudfront_domain        = "d1234567890abc.cloudfront.net"
      backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = "/cv-project/cv-domain-service"
      log_group_bff_node       = "/cv-project/cv-bff-node"
    }))) == 1
    error_message = "templates/domain-service-provision.sh must pin flyway/flyway:13.7.0 at the migrate step, not :10"
  }

  # Scope 2: the BFF container -- same cv network, --restart unless-stopped,
  # --name bff-node.
  assert {
    condition = length(regexall("docker run -d --name bff-node --restart unless-stopped --network cv", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = var.aws_region
      project_name             = var.project_name
      environment              = var.environment
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = var.db_name
      db_username              = var.db_username
      cloudfront_domain        = "d1234567890abc.cloudfront.net"
      backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = "/cv-project/cv-domain-service"
      log_group_bff_node       = "/cv-project/cv-bff-node"
    }))) == 1
    error_message = "The BFF docker run must be --name bff-node --restart unless-stopped --network cv"
  }

  # Scope 2: the BFF publishes 3000 (unique to the BFF -- the domain service
  # publishes 8080).
  assert {
    condition = length(regexall("-p 3000:3000", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = var.aws_region
      project_name             = var.project_name
      environment              = var.environment
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = var.db_name
      db_username              = var.db_username
      cloudfront_domain        = "d1234567890abc.cloudfront.net"
      backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = "/cv-project/cv-domain-service"
      log_group_bff_node       = "/cv-project/cv-bff-node"
    }))) == 1
    error_message = "The BFF container must publish port 3000"
  }

  # Ruling 5/scope 2: DOMAIN_SERVICE_URL is container-to-container, NEVER the
  # public EIP -- BFF->domain traffic must not round-trip the internet.
  assert {
    condition = length(regexall("-e DOMAIN_SERVICE_URL=http://domain-service:8080", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = var.aws_region
      project_name             = var.project_name
      environment              = var.environment
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = var.db_name
      db_username              = var.db_username
      cloudfront_domain        = "d1234567890abc.cloudfront.net"
      backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = "/cv-project/cv-domain-service"
      log_group_bff_node       = "/cv-project/cv-bff-node"
    }))) == 1
    error_message = "The BFF must reach the domain service via http://domain-service:8080 on the cv network, never the public EIP"
  }

  # Ruling 5: AUTH_ENABLED=true on BOTH containers -- the BFF defaults it off
  # (meta CLAUDE.md, local dev only), which would be wrong deployed (every
  # /bff/api/v1 route would be anonymous, not just the contract's allowlist).
  assert {
    condition = length(regexall("-e AUTH_ENABLED=true", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = var.aws_region
      project_name             = var.project_name
      environment              = var.environment
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = var.db_name
      db_username              = var.db_username
      cloudfront_domain        = "d1234567890abc.cloudfront.net"
      backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = "/cv-project/cv-domain-service"
      log_group_bff_node       = "/cv-project/cv-bff-node"
    }))) == 2
    error_message = "AUTH_ENABLED=true must be set on both the domain service and the BFF containers"
  }

  # Ruling 5: the BFF reads its issuer from SSM exactly as the domain service
  # does (each cv_run_* reads cognito/issuer-uri via cv_need into its own local,
  # CV_DS_COGNITO_ISSUER_URI / CV_BFF_COGNITO_ISSUER_URI, and passes that to its
  # container -- never a literal baked into either).
  assert {
    condition = alltrue([
      for pat in [
        "-e COGNITO_ISSUER_URI=\"\\$CV_DS_COGNITO_ISSUER_URI\"",
        "-e COGNITO_ISSUER_URI=\"\\$CV_BFF_COGNITO_ISSUER_URI\"",
        ] : length(regexall(pat, templatefile("${path.module}/templates/domain-service-provision.sh", {
          aws_region               = var.aws_region
          project_name             = var.project_name
          environment              = var.environment
          image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
          bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
          db_name                  = var.db_name
          db_username              = var.db_username
          cloudfront_domain        = "d1234567890abc.cloudfront.net"
          backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
          backup_prefix            = "mysql-dumps"
          mysql_volume_id          = "vol-0123456789abcdef0"
          log_group_domain_service = "/cv-project/cv-domain-service"
          log_group_bff_node       = "/cv-project/cv-bff-node"
      }))) == 1
    ])
    error_message = "Both the domain service and the BFF must pass COGNITO_ISSUER_URI from its own SSM-sourced local (CV_DS_/CV_BFF_COGNITO_ISSUER_URI), never a literal"
  }

  # Ruling 6 (T-061: the origins now come from SSM): CORS_ALLOWED_ORIGINS on
  # the BFF is EXACTLY the SSM value -- closing quote right after the variable
  # discriminates this from the domain service's own value, which appends the
  # localhost dev origins, so this also proves the BFF does NOT inherit them.
  # cv-public-react needs no entry -- it fetches server-side under ISR, so
  # CORS never applies to it; not asserted here since there's nothing to
  # assert an absence of.
  assert {
    condition = length(regexall("-e CORS_ALLOWED_ORIGINS=\"\\$CV_BFF_CORS_ORIGINS\"", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = var.aws_region
      project_name             = var.project_name
      environment              = var.environment
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = var.db_name
      db_username              = var.db_username
      cloudfront_domain        = "d1234567890abc.cloudfront.net"
      backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = "/cv-project/cv-domain-service"
      log_group_bff_node       = "/cv-project/cv-bff-node"
    }))) == 1
    error_message = "The BFF's CORS_ALLOWED_ORIGINS must be exactly the SSM value (no localhost origins)"
  }

  # Scope 2: the same retry-until-the-image-exists pattern as the domain
  # service -- the BFF image won't exist on first boot either. Matched
  # against the rendered fixture value (bff_image is already substituted by
  # templatefile by this point, not the literal "$${bff_image}" placeholder).
  assert {
    condition = length(regexall("until docker pull \"\\$CV_BFF_IMAGE\"; do", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = var.aws_region
      project_name             = var.project_name
      environment              = var.environment
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = var.db_name
      db_username              = var.db_username
      cloudfront_domain        = "d1234567890abc.cloudfront.net"
      backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = "/cv-project/cv-domain-service"
      log_group_bff_node       = "/cv-project/cv-bff-node"
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
      aws_region               = var.aws_region
      project_name             = var.project_name
      environment              = var.environment
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = var.db_name
      db_username              = var.db_username
      cloudfront_domain        = "d1234567890abc.cloudfront.net"
      backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = "/cv-project/cv-domain-service"
      log_group_bff_node       = "/cv-project/cv-bff-node"
    }))) == 2
    error_message = "systemctl enable --now mysql-backup.timer must appear exactly once in the rendered script"
  }

  assert {
    condition = length(regexall("(?m)^cv_run_bff_node$", split("systemctl enable --now mysql-backup.timer", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = var.aws_region
      project_name             = var.project_name
      environment              = var.environment
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = var.db_name
      db_username              = var.db_username
      cloudfront_domain        = "d1234567890abc.cloudfront.net"
      backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = "/cv-project/cv-domain-service"
      log_group_bff_node       = "/cv-project/cv-bff-node"
    }))[0])) == 0
    error_message = "The BFF start (cv_run_bff_node) must NOT run before the MySQL backup timer is enabled -- a missing BFF image must never block the nightly backup from being installed (T-014 review round 1)"
  }

  assert {
    condition = length(regexall("(?m)^cv_run_bff_node$", split("systemctl enable --now mysql-backup.timer", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = var.aws_region
      project_name             = var.project_name
      environment              = var.environment
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = var.db_name
      db_username              = var.db_username
      cloudfront_domain        = "d1234567890abc.cloudfront.net"
      backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = "/cv-project/cv-domain-service"
      log_group_bff_node       = "/cv-project/cv-bff-node"
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
          aws_region               = var.aws_region
          project_name             = var.project_name
          environment              = var.environment
          image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
          bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
          db_name                  = var.db_name
          db_username              = var.db_username
          cloudfront_domain        = "d1234567890abc.cloudfront.net"
          backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
          backup_prefix            = "mysql-dumps"
          mysql_volume_id          = "vol-0123456789abcdef0"
          log_group_domain_service = "/cv-project/cv-domain-service"
          log_group_bff_node       = "/cv-project/cv-bff-node"
      }))) == 1
    ])
    error_message = "docker run for domain-service, bff-node and flyway must each appear exactly once in the provisioning script (inside their cv_run_* function), shared by boot and cv-redeploy (T-044)"
  }

  assert {
    condition = alltrue([
      for fn in ["cv_run_flyway", "cv_run_domain_service", "cv_run_bff_node"] :
      length(regexall("(?m)^${fn}\\(\\) \\{$", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region               = var.aws_region
        project_name             = var.project_name
        environment              = var.environment
        image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name                  = var.db_name
        db_username              = var.db_username
        cloudfront_domain        = "d1234567890abc.cloudfront.net"
        backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix            = "mysql-dumps"
        mysql_volume_id          = "vol-0123456789abcdef0"
        log_group_domain_service = "/cv-project/cv-domain-service"
        log_group_bff_node       = "/cv-project/cv-bff-node"
      }))) == 1
    ])
    error_message = "cv_run_flyway, cv_run_domain_service and cv_run_bff_node must each be defined exactly once (T-044)"
  }

  # The boot flow calls each function; cv-redeploy calls them by name too.
  assert {
    condition = alltrue([
      for fn in ["cv_run_flyway", "cv_run_domain_service", "cv_run_bff_node"] :
      length(regexall("(?m)^[ ]*${fn}$", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region               = var.aws_region
        project_name             = var.project_name
        environment              = var.environment
        image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name                  = var.db_name
        db_username              = var.db_username
        cloudfront_domain        = "d1234567890abc.cloudfront.net"
        backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix            = "mysql-dumps"
        mysql_volume_id          = "vol-0123456789abcdef0"
        log_group_domain_service = "/cv-project/cv-domain-service"
        log_group_bff_node       = "/cv-project/cv-bff-node"
      }))) >= 1
    ])
    error_message = "the boot flow must call cv_run_flyway, cv_run_domain_service and cv_run_bff_node (T-044)"
  }

  # Boot order: MySQL, Flyway, domain-service, backup timer, BFF last.
  assert {
    condition = alltrue([
      length(regexall("(?s)docker run -d --name mysql .*\ncv_run_flyway\n.*\ncv_run_domain_service\n.*systemctl enable --now mysql-backup\\.timer.*\ncv_run_bff_node\n", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region               = var.aws_region
        project_name             = var.project_name
        environment              = var.environment
        image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name                  = var.db_name
        db_username              = var.db_username
        cloudfront_domain        = "d1234567890abc.cloudfront.net"
        backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix            = "mysql-dumps"
        mysql_volume_id          = "vol-0123456789abcdef0"
        log_group_domain_service = "/cv-project/cv-domain-service"
        log_group_bff_node       = "/cv-project/cv-bff-node"
      }))) == 1
    ])
    error_message = "boot order must be mysql, cv_run_flyway, cv_run_domain_service, backup timer, cv_run_bff_node (T-014 round 1 ordering)"
  }

  # The images the functions use are rendered into the library.
  assert {
    condition = (
      length(regexall("CV_BFF_IMAGE=\"123456789012\\.dkr\\.ecr\\.eu-west-3\\.amazonaws\\.com/cv-project-bff-node:latest\"", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region               = var.aws_region
        project_name             = var.project_name
        environment              = var.environment
        image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name                  = var.db_name
        db_username              = var.db_username
        cloudfront_domain        = "d1234567890abc.cloudfront.net"
        backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix            = "mysql-dumps"
        mysql_volume_id          = "vol-0123456789abcdef0"
        log_group_domain_service = "/cv-project/cv-domain-service"
        log_group_bff_node       = "/cv-project/cv-bff-node"
      }))) == 1 &&
      length(regexall("CV_DOMAIN_IMAGE=\"123456789012\\.dkr\\.ecr\\.eu-west-3\\.amazonaws\\.com/cv-project-domain-service:latest\"", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region               = var.aws_region
        project_name             = var.project_name
        environment              = var.environment
        image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name                  = var.db_name
        db_username              = var.db_username
        cloudfront_domain        = "d1234567890abc.cloudfront.net"
        backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix            = "mysql-dumps"
        mysql_volume_id          = "vol-0123456789abcdef0"
        log_group_domain_service = "/cv-project/cv-domain-service"
        log_group_bff_node       = "/cv-project/cv-bff-node"
      }))) == 1
    )
    error_message = "the library must define CV_DOMAIN_IMAGE and CV_BFF_IMAGE from the ECR repo URLs"
  }

  # cv-redeploy: only the allowed verbs, root-only, strict mode, no secrets.
  assert {
    condition = (
      length(regexall("chmod 750 /usr/local/bin/cv-redeploy", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region               = var.aws_region
        project_name             = var.project_name
        environment              = var.environment
        image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name                  = var.db_name
        db_username              = var.db_username
        cloudfront_domain        = "d1234567890abc.cloudfront.net"
        backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix            = "mysql-dumps"
        mysql_volume_id          = "vol-0123456789abcdef0"
        log_group_domain_service = "/cv-project/cv-domain-service"
        log_group_bff_node       = "/cv-project/cv-bff-node"
      }))) == 1 &&
      length(regexall("(?m)^  migrate\\)", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region               = var.aws_region
        project_name             = var.project_name
        environment              = var.environment
        image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name                  = var.db_name
        db_username              = var.db_username
        cloudfront_domain        = "d1234567890abc.cloudfront.net"
        backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix            = "mysql-dumps"
        mysql_volume_id          = "vol-0123456789abcdef0"
        log_group_domain_service = "/cv-project/cv-domain-service"
        log_group_bff_node       = "/cv-project/cv-bff-node"
      }))) == 1 &&
      length(regexall("(?m)^  domain-service\\)", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region               = var.aws_region
        project_name             = var.project_name
        environment              = var.environment
        image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name                  = var.db_name
        db_username              = var.db_username
        cloudfront_domain        = "d1234567890abc.cloudfront.net"
        backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix            = "mysql-dumps"
        mysql_volume_id          = "vol-0123456789abcdef0"
        log_group_domain_service = "/cv-project/cv-domain-service"
        log_group_bff_node       = "/cv-project/cv-bff-node"
      }))) == 1 &&
      length(regexall("(?m)^  bff-node\\)", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region               = var.aws_region
        project_name             = var.project_name
        environment              = var.environment
        image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name                  = var.db_name
        db_username              = var.db_username
        cloudfront_domain        = "d1234567890abc.cloudfront.net"
        backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix            = "mysql-dumps"
        mysql_volume_id          = "vol-0123456789abcdef0"
        log_group_domain_service = "/cv-project/cv-domain-service"
        log_group_bff_node       = "/cv-project/cv-bff-node"
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

# Applied (mocked) and scoped with plan_options.target to the IAM policy --
# same rationale as backup_iam_scoping.
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
# attribute, so this is a text assertion (a regex over the source), not a CloudFront-function-execution test (CloudFront
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
      aws_ssm_parameter.bff_token_url.value == "https://auth.${var.public_domain}/oauth2/token"
    )
    error_message = "BFF SSM parameter names/values under /<project>/<env>/bff/ are wrong"
  }

  # The BFF docker run passes all four env vars, the secret from a shell
  # variable (never inlined), and still comes after the backup timer.
  assert {
    condition = alltrue([
      for pat in [
        "-e COGNITO_TOKEN_URL=\"\\$CV_BFF_TOKEN_URL\"",
        "-e SERVICE_CLIENT_ID=\"\\$CV_BFF_CLIENT_ID\"",
        "-e SERVICE_CLIENT_SECRET=\"\\$CV_BFF_CLIENT_SECRET\"",
        "-e SERVICE_TOKEN_SCOPE=\"\\$CV_BFF_TOKEN_SCOPE\"",
        ] : length(regexall(pat, templatefile("${path.module}/templates/domain-service-provision.sh", {
          aws_region               = var.aws_region
          project_name             = var.project_name
          environment              = var.environment
          image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
          bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
          db_name                  = var.db_name
          db_username              = var.db_username
          cloudfront_domain        = "d1234567890abc.cloudfront.net"
          backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
          backup_prefix            = "mysql-dumps"
          mysql_volume_id          = "vol-0123456789abcdef0"
          log_group_domain_service = "/cv-project/cv-domain-service"
          log_group_bff_node       = "/cv-project/cv-bff-node"
      }))) == 1
    ])
    error_message = "the BFF docker run (cv_run_bff_node) must pass COGNITO_TOKEN_URL, SERVICE_CLIENT_ID, SERVICE_CLIENT_SECRET, SERVICE_TOKEN_SCOPE from its CV_BFF_* locals (T-043)"
  }

  assert {
    condition = alltrue([
      for p in ["bff/service-client-id", "bff/service-client-secret", "bff/token-url", "bff/token-scope"] :
      length(regexall("cv_need CV_BFF_[A-Z_]+ ${p} ", templatefile("${path.module}/templates/domain-service-provision.sh", {
        aws_region               = var.aws_region
        project_name             = var.project_name
        environment              = var.environment
        image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
        bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
        db_name                  = var.db_name
        db_username              = var.db_username
        cloudfront_domain        = "d1234567890abc.cloudfront.net"
        backup_bucket            = "${var.project_name}-mysql-backup-${var.environment}"
        backup_prefix            = "mysql-dumps"
        mysql_volume_id          = "vol-0123456789abcdef0"
        log_group_domain_service = "/cv-project/cv-domain-service"
        log_group_bff_node       = "/cv-project/cv-bff-node"
      }))) == 1
    ])
    error_message = "user_data must read each of the four bff/* parameters once via cv_need (into the CV_BFF_* locals of cv_run_bff_node)"
  }
}

# T-045 -- GitHub Actions OIDC provider + the cv-public-vanilla deploy role.
# ---------------------------------------------------------------------------
# Applied under mock_provider, scoped with plan_options.target to the
# role/policy/provider -- same rationale as "backup_iam_scoping". The
# bucket, distribution and provider ARNs are unknown at plan, which would make
# both policy documents unknown strings; under apply the mock fills them in,
# so the decoded policy JSON is compared against the resource ARNs by
# reference. The SPA-router function is overridden because the mock's random
# ARN fails provider validation. What stays unassertable
# offline: that the real ARNs have the right format and that AWS accepts the
# provider/trust (T-045's live simulate-principal-policy criterion covers it).
# ---------------------------------------------------------------------------
run "github_oidc_public_vanilla_deploy" {
  # T-068: this was a targeted apply run asserting the decoded role and policy
  # documents. The distribution now reaches the app host through VPC origins,
  # so applying it, even targeted, created the host and the MySQL volume in
  # the test state, and the volume's prevent_destroy fails the teardown. As a
  # plan run, the documents embed ARNs that are unknown until apply, so only
  # the plan-known facts are asserted here; the trust, the exact actions and
  # resources, the admin/* Deny and the absence of wildcards are pinned by
  # scripts/check-static.sh check 2b instead.
  command = plan

  override_resource {
    target = aws_cloudfront_function.spa_router
    values = {
      arn = "arn:aws:cloudfront::123456789012:function/spa-router"
    }
  }

  # T-061: the distribution's viewer_certificate reads the certificate ARN, and
  # the provider validates its format; a mock apply would invent a bare string.
  override_resource {
    target = aws_acm_certificate.site
    values = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
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

  assert {
    condition     = aws_iam_role.public_vanilla_deploy.max_session_duration == 3600
    error_message = "the deploy role keeps the default 1 h session (T-045)"
  }
}

# T-063 -- the cv-admin-react deploy role (admin/* only). Plan-known facts only;
# the trust and policy documents embed ARNs unknown until apply, so
# check-static.sh check 32 pins them (sub/aud, prefix scope).
run "github_oidc_admin_deploy" {
  command = plan

  override_resource {
    target = aws_cloudfront_function.spa_router
    values = {
      arn = "arn:aws:cloudfront::123456789012:function/spa-router"
    }
  }

  override_resource {
    target = aws_acm_certificate.site
    values = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    }
  }

  assert {
    condition     = aws_iam_role.admin_deploy.name == "${var.project_name}-admin-deploy"
    error_message = "the admin deploy role is named <project>-admin-deploy (T-063)"
  }

  assert {
    condition     = aws_iam_role.admin_deploy.max_session_duration == 3600
    error_message = "the admin deploy role keeps the 1 h session (T-063)"
  }

  assert {
    condition     = aws_iam_role_policy.admin_deploy.name == "frontend-admin-deploy"
    error_message = "the admin deploy inline policy is named frontend-admin-deploy (T-063)"
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

  assert {
    condition     = aws_instance.domain_service.ami == data.aws_ami.al2023_arm64.id
    error_message = "the app host must use the arm64 AMI lookup (data.aws_ami.al2023_arm64)"
  }

  assert {
    condition     = contains(flatten([for f in data.aws_ami.al2023_arm64.filter : f.values]), "al2023-ami-2023.*-arm64") && contains(flatten([for f in data.aws_ami.al2023_arm64.filter : f.values]), "arm64")
    error_message = "data.aws_ami.al2023_arm64 must filter the plain AL2023 name pattern AND architecture = arm64"
  }

  assert {
    condition     = alltrue(flatten([for f in data.aws_ami.al2023_arm64.filter : [for v in f.values : !can(regex("ecs", v))]]))
    error_message = "the arm64 lookup must not match the ECS-optimized variant"
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
# Apply is scoped with plan_options.target (as the T-045 run above).
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

# ---------------------------------------------------------------------------
# T-054: container logs to CloudWatch (awslogs). Plan-only, target-scoped to
# the new policy and the S3 object that carries the rendered provision script.
# The awslogs driver runs in dockerd on the host, so the grant is on the app
# host's role: CreateLogStream + PutLogEvents on the two groups' streams, no
# CreateLogGroup (the groups exist), no DescribeLogStreams, no wildcard.
# ---------------------------------------------------------------------------
run "t054_app_container_logs" {
  command = plan

  plan_options {
    target = [
      aws_iam_role_policy.app_write_container_logs,
      aws_cloudwatch_log_group.domain_service,
      aws_cloudwatch_log_group.bff_node,
    ]
  }

  # The real script's content is unknown-until-apply (cloudfront_domain), so
  # render with fixtures for the unknowns and the real plan-known group names.
  # Same pattern as app_host_user_data above.
  assert {
    condition     = aws_iam_role_policy.app_write_container_logs.role == aws_iam_role.domain_service.id
    error_message = "the container-logs grant must attach to the domain_service (app host) role"
  }

  assert {
    condition     = local.app_container_logs_actions == ["logs:CreateLogStream", "logs:PutLogEvents"]
    error_message = "the grant must be exactly logs:CreateLogStream and logs:PutLogEvents (no CreateLogGroup, DescribeLogStreams or wildcard)"
  }

  # The group ARNs are unknown until apply, so the two stream ARNs themselves
  # (<group arn>:*, no doubled :*) are guarded by scripts/check-static.sh check 22.
  assert {
    condition     = length(local.app_container_logs_resources) == 2
    error_message = "the grant must cover exactly the two groups' stream ARNs"
  }

  # The rendered provision script (the S3 object's content) names both groups.
  assert {
    condition = length(regexall("--log-opt awslogs-group=\"/cv-project/cv-domain-service\"", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = "eu-west-3"
      project_name             = "cv-project"
      environment              = "dev"
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = "cvdb"
      db_username              = "cvuser"
      cloudfront_domain        = "d1234567890abc.cloudfront.net"
      backup_bucket            = "cv-project-mysql-backup-dev"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = aws_cloudwatch_log_group.domain_service.name
      log_group_bff_node       = aws_cloudwatch_log_group.bff_node.name
    }))) == 1
    error_message = "the rendered provision script must pass /cv-project/cv-domain-service as the domain-service awslogs group"
  }

  assert {
    condition = length(regexall("--log-opt awslogs-group=\"/cv-project/cv-bff-node\"", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = "eu-west-3"
      project_name             = "cv-project"
      environment              = "dev"
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = "cvdb"
      db_username              = "cvuser"
      cloudfront_domain        = "d1234567890abc.cloudfront.net"
      backup_bucket            = "cv-project-mysql-backup-dev"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = aws_cloudwatch_log_group.domain_service.name
      log_group_bff_node       = aws_cloudwatch_log_group.bff_node.name
    }))) == 1
    error_message = "the rendered provision script must pass /cv-project/cv-bff-node as the bff-node awslogs group"
  }

  assert {
    condition = length(regexall("--log-driver awslogs", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = "eu-west-3"
      project_name             = "cv-project"
      environment              = "dev"
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = "cvdb"
      db_username              = "cvuser"
      cloudfront_domain        = "d1234567890abc.cloudfront.net"
      backup_bucket            = "cv-project-mysql-backup-dev"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = aws_cloudwatch_log_group.domain_service.name
      log_group_bff_node       = aws_cloudwatch_log_group.bff_node.name
    }))) == 2
    error_message = "exactly two containers (domain-service, bff-node) use the awslogs driver"
  }

  assert {
    condition = length(regexall("--log-opt awslogs-datetime-format='%Y-%m-%dT%H:%M:%S'", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = "eu-west-3"
      project_name             = "cv-project"
      environment              = "dev"
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = "cvdb"
      db_username              = "cvuser"
      cloudfront_domain        = "d1234567890abc.cloudfront.net"
      backup_bucket            = "cv-project-mysql-backup-dev"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = aws_cloudwatch_log_group.domain_service.name
      log_group_bff_node       = aws_cloudwatch_log_group.bff_node.name
    }))) == 1
    error_message = "only domain-service sets awslogs-datetime-format (stack traces stay one event)"
  }
}

# --- T-061: erfeamor.com on CloudFront -------------------------------------
# Plan-time facts only: ARNs, the distribution's domain and validation
# records are unknown until apply, so their wiring (certificate -> validation
# -> viewer_certificate, the CORS value) is pinned by check-static.sh check 25.
run "t061_custom_domain" {
  command = plan

  assert {
    condition     = aws_route53_record.react.name == "react.erfeamor.com" && aws_route53_record.react.type == "CNAME" && one(aws_route53_record.react.records) == var.react_cname_target
    error_message = "react.<apex> is a CNAME to the Vercel target (T-410)"
  }

  assert {
    condition     = aws_acm_certificate.site.domain_name == "erfeamor.com"
    error_message = "the certificate's primary name is the apex"
  }

  assert {
    condition = (
      length(aws_acm_certificate.site.subject_alternative_names) == 2 &&
      contains(aws_acm_certificate.site.subject_alternative_names, "www.erfeamor.com") &&
      contains(aws_acm_certificate.site.subject_alternative_names, "auth.erfeamor.com")
    )
    error_message = "the certificate covers www and auth.erfeamor.com (auth is included now so T-062 never replaces an attached certificate)"
  }

  assert {
    condition     = aws_acm_certificate.site.validation_method == "DNS"
    error_message = "the certificate validates through DNS in the Route 53 zone"
  }

  assert {
    condition     = toset(keys(aws_route53_record.site_cert_validation)) == toset(["erfeamor.com", "www.erfeamor.com", "auth.erfeamor.com"])
    error_message = "one validation record per certificate name"
  }

  assert {
    condition     = aws_cloudfront_distribution.frontend.aliases == toset(["erfeamor.com", "www.erfeamor.com"])
    error_message = "the distribution answers to the apex and www only (auth.erfeamor.com is Cognito's own CloudFront)"
  }

  assert {
    condition     = aws_cloudfront_distribution.frontend.is_ipv6_enabled
    error_message = "IPv6 is enabled on the distribution"
  }

  assert {
    condition = (
      aws_cloudfront_distribution.frontend.viewer_certificate[0].ssl_support_method == "sni-only" &&
      aws_cloudfront_distribution.frontend.viewer_certificate[0].minimum_protocol_version == "TLSv1.2_2021" &&
      coalesce(aws_cloudfront_distribution.frontend.viewer_certificate[0].cloudfront_default_certificate, false) == false
    )
    error_message = "the custom certificate is served over SNI (no dedicated-IP fee) with TLS 1.2 or newer"
  }

  assert {
    condition = toset([for k, r in aws_route53_record.site_alias : "${r.name}/${r.type}"]) == toset([
      "erfeamor.com/A", "erfeamor.com/AAAA", "www.erfeamor.com/A", "www.erfeamor.com/AAAA",
    ])
    error_message = "the apex and www each get an A and an AAAA alias to the distribution"
  }

  assert {
    condition     = contains(local.app_host_ssm_parameter_names, aws_ssm_parameter.cors_allowed_origins.name)
    error_message = "the app host role may read app/cors-allowed-origins"
  }

  assert {
    condition     = aws_ssm_parameter.cors_allowed_origins.name == "/cv-project/dev/app/cors-allowed-origins"
    error_message = "the CORS parameter lives under app/ like provision-sha256"
  }

  assert {
    condition     = aws_cloudfront_function.spa_router.runtime == "cloudfront-js-2.0"
    error_message = "the router function keeps the JS 2.0 runtime (startsWith)"
  }

  assert {
    condition = (
      length(regexall("https://react\\.erfeamor\\.com", aws_cloudfront_function.spa_router.code)) >= 1 &&
      length(regexall("www\\.erfeamor\\.com", aws_cloudfront_function.spa_router.code)) >= 1 &&
      length(regexall("\\$\\{apex\\}", aws_cloudfront_function.spa_router.code)) == 0
    )
    error_message = "templatefile filled the router function's $${apex} placeholders"
  }

  # The CORS origins are no longer baked into the provision script: they are
  # read from SSM, so a new origin is a cv-redeploy, not a host replacement.
  assert {
    condition = length(regexall("cv_need CV_DS_CORS_ORIGINS app/cors-allowed-origins", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = "eu-west-3"
      project_name             = "cv-project"
      environment              = "dev"
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = "cvdb"
      db_username              = "cvuser"
      backup_bucket            = "cv-project-mysql-backup-dev"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = aws_cloudwatch_log_group.domain_service.name
      log_group_bff_node       = aws_cloudwatch_log_group.bff_node.name
    }))) == 1
    error_message = "domain-service reads its CORS origins from SSM through cv_need"
  }

  assert {
    condition = length(regexall("cv_need CV_BFF_CORS_ORIGINS app/cors-allowed-origins", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = "eu-west-3"
      project_name             = "cv-project"
      environment              = "dev"
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = "cvdb"
      db_username              = "cvuser"
      backup_bucket            = "cv-project-mysql-backup-dev"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = aws_cloudwatch_log_group.domain_service.name
      log_group_bff_node       = aws_cloudwatch_log_group.bff_node.name
    }))) == 1
    error_message = "bff-node reads its CORS origins from SSM through cv_need"
  }
}

# T-061 review: dns.tf's zone is a fixed zone ID, so a public_domain that the
# zone doesn't serve must fail at plan time, not hang ACM validation.
run "t061_domain_must_match_the_zone" {
  command = plan

  variables {
    public_domain = "other.example.com"
  }

  expect_failures = [aws_acm_certificate.site]
}

# T-062: Cognito serves its hosted UI and token endpoint from auth.<apex>. The
# prefix domain stays beside it until T-306 moves the admin build (a pool can
# hold both).
run "t062_cognito_custom_domain" {
  command = plan

  assert {
    condition = (
      aws_cognito_user_pool_domain.custom.domain == "auth.${var.public_domain}" &&
      aws_cognito_user_pool_domain.custom.managed_login_version == 1
    )
    error_message = "the custom domain is auth.<apex>, on classic managed login (version 1)"
  }

  assert {
    condition     = aws_cognito_user_pool_domain.cv.domain == "${var.project_name}-${var.environment}"
    error_message = "the prefix domain stays until T-306 moves the admin build"
  }

  assert {
    condition = (
      aws_route53_record.auth_alias["A"].name == "auth.${var.public_domain}" &&
      aws_route53_record.auth_alias["AAAA"].name == "auth.${var.public_domain}" &&
      aws_route53_record.auth_alias["A"].type == "A" &&
      aws_route53_record.auth_alias["AAAA"].type == "AAAA"
    )
    error_message = "auth.<apex> has an A and an AAAA alias"
  }

  assert {
    condition     = output.cognito_hosted_ui_domain == "auth.${var.public_domain}"
    error_message = "the hosted UI output names the custom domain"
  }
}

# T-066: the MySQL data volume is 2 GiB (the data is ~216 MB), set through
# var.mysql_volume_size_gb so growing it later is a one-line, in-place change.
# A 2 GiB disk is why binlogs expire after 7 days instead of MySQL's default 30.
run "t066_small_mysql_volume" {
  command = plan

  assert {
    condition     = var.mysql_volume_size_gb == 2 && aws_ebs_volume.mysql_data_v2.size == var.mysql_volume_size_gb
    error_message = "the MySQL volume size comes from var.mysql_volume_size_gb, which defaults to 2"
  }

  assert {
    condition = length(regexall("--binlog-expire-logs-seconds=604800", templatefile("${path.module}/templates/domain-service-provision.sh", {
      aws_region               = "eu-west-3"
      project_name             = "cv-project"
      environment              = "dev"
      image                    = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-domain-service:latest"
      bff_image                = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/cv-project-bff-node:latest"
      db_name                  = "cvdb"
      db_username              = "cvuser"
      backup_bucket            = "cv-project-mysql-backup-dev"
      backup_prefix            = "mysql-dumps"
      mysql_volume_id          = "vol-0123456789abcdef0"
      log_group_domain_service = aws_cloudwatch_log_group.domain_service.name
      log_group_bff_node       = aws_cloudwatch_log_group.bff_node.name
    }))) == 1
    error_message = "the mysql container expires binlogs after 7 days so they can't fill the 2 GiB volume"
  }
}

run "t066_volume_size_is_a_whole_number_of_gib_at_least_1" {
  command = plan

  variables {
    mysql_volume_size_gb = 0
  }

  expect_failures = [var.mysql_volume_size_gb]
}

# T-070: the migration SQL travels through S3. The app host reads one key (and
# may list the bucket, which turns a missing key into a 404 the script
# understands); the cv-database role writes that same key and nothing else.
run "t070_migration_sql_through_s3" {
  command = plan

  assert {
    condition     = local.migration_sql_key == "migrations/cv-database-sql.tgz" && !startswith(local.migration_sql_key, "${local.mysql_backup_prefix}/")
    error_message = "the migration SQL object must be migrations/cv-database-sql.tgz, outside the expiring mysql-dumps/ prefix (T-070)"
  }

  assert {
    condition = (
      aws_iam_role_policy.app_read_migration_sql.role == aws_iam_role.domain_service.id &&
      jsondecode(aws_iam_role_policy.app_read_migration_sql.policy).Statement[0].Action == ["s3:GetObject"] &&
      jsondecode(aws_iam_role_policy.app_read_migration_sql.policy).Statement[0].Resource == "${aws_s3_bucket.backup.arn}/${local.migration_sql_key}" &&
      jsondecode(aws_iam_role_policy.app_read_migration_sql.policy).Statement[1].Action == ["s3:ListBucket"] &&
      jsondecode(aws_iam_role_policy.app_read_migration_sql.policy).Statement[1].Resource == aws_s3_bucket.backup.arn &&
      length(jsondecode(aws_iam_role_policy.app_read_migration_sql.policy).Statement) == 2
    )
    error_message = "the app host may s3:GetObject the one migration key and s3:ListBucket the bucket, nothing else (T-070)"
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.database_migrate_publish_sql.policy).Statement) == 1 &&
      jsondecode(aws_iam_role_policy.database_migrate_publish_sql.policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.database_migrate_publish_sql.policy).Statement[0].Action == ["s3:PutObject"] &&
      jsondecode(aws_iam_role_policy.database_migrate_publish_sql.policy).Statement[0].Resource == "${aws_s3_bucket.backup.arn}/${local.migration_sql_key}"
    )
    error_message = "the cv-database role may s3:PutObject exactly the migration key (T-070)"
  }

  assert {
    condition     = output.migration_sql_bucket == "${aws_s3_bucket.backup.bucket}/${local.migration_sql_key}"
    error_message = "the migration_sql_bucket output must name bucket/key for cv-database's repo variable (T-071)"
  }
}
