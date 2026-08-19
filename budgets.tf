# T-011: a budget alarm that fires on GROSS usage, not on the invoice.
#
# T-020 §4, decided 2026-08-19: LEAVE THESE LIMITS ALONE. Recorded here because
# "we looked and deliberately changed nothing" is otherwise indistinguishable
# from "nobody looked".
#
# The board expected this file to need retuning: at the $37.30/month rate the
# 2026-08-08 CI-host resize produced, the $30 monthly limit was structurally
# exceeded (~124%), so its 100/120% thresholds would have fired every month
# from September onward -- and an alarm that always fires stops being a signal,
# which is the exact failure that made the deleted $5 console budget useless.
#
# That premise expired before it was acted on. Measured 2026-08-19, with the CI
# host now stopped between builds (T-019), the real rate is ~$0.68/day ≈
# $21/month: September projects to ~68% of this limit, not 124%. August still
# breaches once (~$34.68, 116%) on the strength of its first half, which is
# history rather than a trend.
#
# So a $30 monthly limit against a ~$21/month rate is now a working DEVIATION
# alarm, and it fires on precisely the one behaviour worth being told about:
# the CI host being left running, which adds ~$17/month and moves credit
# exhaustion forward by ~8 weeks. Retuning the limit down to hug the current
# rate would trade that signal for noise.
#
# The credit_runway limit stays at $160 for the reason cv-infra#14 recorded and
# T-010 verified: raising it to $200 pushes the 100% alert past the date the
# account is paused, so the alarm would stay green until it could no longer
# help. That reasoning is unaffected by the new numbers.
#
# The crux (H1 DoR decision 1, non-negotiable): aws_budgets_budget's
# cost_types block defaults include_credit = true, which makes the budget's
# metric NET cost. On this account credits currently absorb ~100% of usage,
# so net cost is $0 and stays $0 until the credit pool is exhausted -- a
# budget left at defaults applies cleanly, reads green in the console, and
# never fires, right up to the moment the account gets paused. Setting
# include_credit = false below is the entire reason this file exists.
#
# Second, independent silent-failure path (H1 DoR): AWS Budgets publishes to
# SNS as a service principal, not as an IAM identity in this account. Without
# an explicit topic policy granting budgets.amazonaws.com permission to
# publish (scoped with aws:SourceAccount), the notification fails to
# publish and nothing in `describe-budgets` or
# `describe-notifications-for-budget` reveals it -- see
# aws_sns_topic_policy.budget_alerts below.
#
# Scope amendment (H1, ratified 2026-08-09): the account's credit pot
# (plan = AWS Free plan -- exhaustion PAUSES the account rather than
# billing it) is CUMULATIVE, not a monthly figure. A single MONTHLY budget
# set to a credit-pot-sized amount would read a small fraction of limit
# every month and never cross even the lowest 50% threshold while the pot
# drains to zero -- the same never-fires failure class this file exists to
# prevent, one level up. Fix: two budgets that answer two different
# questions, both tracking gross usage (the crux applies to both):
#   - aws_budgets_budget.gross_usage   (MONTHLY, below)  -- "did this
#     month's burn exceed expectations?" Limit is expected monthly spend
#     (var.budget_monthly_limit_amount, $30), with its own thresholds
#     (var.budget_monthly_thresholds, 100/120/150) that fire on deviation,
#     not on progress toward a ceiling.
#   - aws_budgets_budget.credit_runway (ANNUALLY, further below) -- "are we
#     about to run out of credit?" Tracks the credit pot via
#     var.budget_credit_grant_amount, with its own thresholds
#     (var.budget_credit_runway_thresholds, 50/80/100, genuine depletion
#     milestones).
# Neither the limit variables nor the threshold variables are shared
# between the two budgets -- sharing either was a real bug: sharing the
# limit was caught before the first apply (a credit-pot-sized MONTHLY
# budget never fires); sharing thresholds was caught AT stage 4 against the
# live account -- a console-created $5 budget with the shared 50/80/100 set
# sat permanently in ALARM, because ordinary burn (~$28/month as measured
# then; ~$21/month now) crosses both 50% and 80% of $5 every month. An alarm that always fires is one nobody
# reads, which is exactly the failure this file exists to prevent, from the
# opposite direction.

data "aws_caller_identity" "current" {}

resource "aws_sns_topic" "budget_alerts" {
  name = "${var.project_name}-${var.environment}-budget-alerts"

  tags = {
    Project = var.project_name
  }
}

resource "aws_sns_topic_policy" "budget_alerts" {
  # Non-blocking (review round 1): both reviewers independently raised
  # adding an aws:SourceArn condition alongside aws:SourceAccount, and
  # neither judged it exploitable given the account condition already in
  # place. Not added here: aws_budgets_budget.gross_usage now has an
  # explicit depends_on this policy (finding 1), so scoping SourceArn to
  # that budget's ARN would create a cycle (policy needing the budget's
  # ARN, budget needing the policy applied first). Logged, not acted on.
  #
  # Also non-blocking, informational only: this policy replaces SNS's
  # __default_statement_ID rather than appending to it -- no default
  # statement existed on a freshly created topic, so there is nothing lost.
  arn = aws_sns_topic.budget_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowBudgetsPublish"
        Effect    = "Allow"
        Principal = { Service = "budgets.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.budget_alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# DoR decision 3 (H1): SNS over a bare email subscriber, because an SNS
# subscription's confirmation state is CLI-queryable
# (list-subscriptions-by-topic -> PendingConfirmation), while a direct email
# subscriber attached straight to the budget is not queryable at all. This
# is what makes "did this actually reach anyone" testable instead of an act
# of faith (stage-4 checks S6/S7).
resource "aws_sns_topic_subscription" "budget_alerts_email" {
  for_each = toset(var.budget_notification_emails)

  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# DoR decision 2 (H1): one ACTUAL and one FORECASTED notification per
# threshold, built from each budget's OWN thresholds variable so ordering
# and value are variable-sourced rather than hand-duplicated per type.
# Two separate locals, not one shared: gross_usage and credit_runway have
# different threshold variables (see the file header) and must not
# accidentally converge on a shared list the way the pre-stage-4 shape did.
locals {
  gross_usage_notifications = flatten([
    for threshold in var.budget_monthly_thresholds : [
      { threshold = threshold, notification_type = "ACTUAL" },
      { threshold = threshold, notification_type = "FORECASTED" },
    ]
  ])

  credit_runway_notifications = flatten([
    for threshold in var.budget_credit_runway_thresholds : [
      { threshold = threshold, notification_type = "ACTUAL" },
      { threshold = threshold, notification_type = "FORECASTED" },
    ]
  ])
}

resource "aws_budgets_budget" "gross_usage" {
  name        = "${var.project_name}-${var.environment}-gross-usage"
  budget_type = "COST"
  # Scope amendment: this is now an ANOMALY DETECTOR, not the credit-runway
  # tracker -- its limit is var.budget_monthly_limit_amount ($30, expected
  # monthly spend now that burn is back under $1/day post-RDS-teardown),
  # deliberately NOT var.budget_credit_grant_amount. See the file header
  # for why sharing a limit variable between this and credit_runway (below)
  # was a real bug.
  limit_amount = var.budget_monthly_limit_amount
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # The crux -- see file header. Non-negotiable per H1 DoR decision 1.
  # include_refund is set false alongside include_credit for the same
  # reason: every cost_types sub-attribute defaults to true independently,
  # and a refund posted to the account nets against tracked spend exactly
  # like a credit does -- same metric-masking failure mode, in a file whose
  # entire purpose is un-netting the metric. Fixing one and not the other
  # would be an inconsistency, not a deliberate choice.
  cost_types {
    include_credit = false
    include_refund = false
  }

  # Own thresholds (var.budget_monthly_thresholds via
  # local.gross_usage_notifications, NOT credit_runway's) -- 100/120/150 by
  # default: at $30 expected spend, only exceeding it is news. Steady-state
  # burn (~$21/month, measured 2026-08-19) produces zero notifications here.
  dynamic "notification" {
    for_each = local.gross_usage_notifications
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value.threshold
      threshold_type            = "PERCENTAGE"
      notification_type         = notification.value.notification_type
      subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
    }
  }

  # Finding 1 (review round 1): aws_budgets_budget only *references*
  # aws_sns_topic.budget_alerts.arn, which makes it a graph sibling of
  # aws_sns_topic_policy.budget_alerts, not a dependent -- Terraform would
  # otherwise be free to create the budget before the policy attaches.
  # AWS validates publish permission at CreateBudget time, so that ordering
  # makes a fresh apply fail nondeterministically. Force the policy first.
  depends_on = [aws_sns_topic_policy.budget_alerts]
}

# Scope amendment (H1, ratified 2026-08-09): the credit-runway tracker.
# Answers a different question than gross_usage above -- not "did this
# month's burn accelerate?" but "are we about to run out of credit?". Same
# crux applies (cost_types.include_credit = false below): the default NET
# metric would read $0 against this limit too, for the same reason.
resource "aws_budgets_budget" "credit_runway" {
  name        = "${var.project_name}-${var.environment}-credit-runway"
  budget_type = "COST"
  # The TOTAL credit grant for the calendar year ($160 as measured -- see
  # variables.tf for why this is the grant, not the remaining balance),
  # not a monthly figure. Deliberately NOT var.budget_monthly_limit_amount;
  # the two budgets must not share a limit variable. Expected to become
  # $200 once two more credit-earning activities complete -- update the
  # real (gitignored) terraform.tfvars value when that happens, this
  # comment is a pointer for the next reader, not a trigger to pre-apply it.
  limit_amount = var.budget_credit_grant_amount
  limit_unit   = "USD"
  # ANNUALLY, not MONTHLY: the thing being tracked is a pot that must last
  # until it's gone, not a per-month allowance. AWS Budgets has no
  # unbounded/one-shot time_unit, so ANNUALLY is the longest built-in window
  # -- if the pot is still alive next January the resource keeps working,
  # it just resets to tracking spend against the same limit_amount from the
  # new calendar year's stub period (see time_period_start note below); a
  # human still has to re-measure and update budget_credit_grant_amount
  # periodically regardless of window choice, since AWS Budgets has no way
  # to decrement a limit as credits are consumed.
  time_unit = "ANNUALLY"

  # time_period_start: CORRECTED at stage 4, against the live account.
  # The original comment here assumed time_period_start constrains what
  # spend gets counted -- it does not. Applied evidence: with
  # time_period_start = "2026-08-01_00:00" below, the live budget reported
  # `actual = $39.339`, not August's $16.435 -- the difference is exactly
  # July's $22.904. So an ANNUALLY budget accumulates spend over the WHOLE
  # CALENDAR YEAR (Jan 1 onward) regardless of the time_period_start value
  # supplied; that value only anchors which day-of-year the period nominally
  # "starts" for AWS's own bookkeeping (e.g. renewal timing in later years),
  # it does not gate what spend counts toward `actual`/`forecasted` in the
  # current period. There is no way to start a clean $0 baseline "from
  # roughly now" for an ANNUALLY budget -- all 2026 spend counts, full stop.
  # This is why var.budget_credit_grant_amount must hold the TOTAL grant
  # ($160), not the remaining balance measured on some later date ($121.03
  # as of 2026-08-09): against calendar-year spend, only the grant total
  # makes the percentage thresholds land on true depletion. The instinct to
  # prefer over- to under-counting (kept as time_period_start's value below,
  # for whatever marginal effect it has on AWS's internal bookkeeping) was
  # directionally right and is why this was caught before it caused a
  # silent under-alarm rather than after.
  time_period_start = "2026-08-01_00:00"

  # Same crux as gross_usage, same reasoning (see file header): every
  # cost_types sub-attribute defaults true independently, so both credit and
  # refund must be excluded for this to actually track gross burn against
  # the credit pot instead of reading net-of-credit $0.
  cost_types {
    include_credit = false
    include_refund = false
  }

  # Same notification shape as gross_usage (H1 DoR decision 4): both ACTUAL
  # and FORECASTED per threshold, same topic -- but its OWN thresholds
  # variable (var.budget_credit_runway_thresholds via
  # local.credit_runway_notifications, NOT gross_usage's), genuine
  # depletion milestones (50/80/100 by default).
  dynamic "notification" {
    for_each = local.credit_runway_notifications
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value.threshold
      threshold_type            = "PERCENTAGE"
      notification_type         = notification.value.notification_type
      subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
    }
  }

  # Same real apply-race fix as gross_usage's depends_on (review round 1,
  # finding 1) -- this budget only references the topic ARN, which makes it
  # a graph sibling of the topic policy, not a dependent, without this.
  depends_on = [aws_sns_topic_policy.budget_alerts]
}
