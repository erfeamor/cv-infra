# T-011: a budget alarm that fires on GROSS usage, not on the invoice.
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
# Scope amendment (H1, ratified 2026-08-09): the account's remaining credit
# balance ($121.03, plan = AWS Free plan -- exhaustion PAUSES the account
# rather than billing it) is a CUMULATIVE pot, not a monthly figure. A
# single MONTHLY budget set to that amount would read ~23% of limit every
# month (burn is ~$28/mo) and never cross even the lowest 50% threshold
# while the pot drains to zero -- the same never-fires failure class this
# file exists to prevent, one level up. Fix: two budgets that answer two
# different questions, both tracking gross usage (the crux applies to both):
#   - aws_budgets_budget.gross_usage   (MONTHLY, below)  -- "did this month's
#     burn accelerate?" Resized to ~$35, an anomaly-detector margin over the
#     known ~$28/month baseline, driven by its own var.budget_monthly_limit_amount.
#   - aws_budgets_budget.credit_runway (ANNUALLY, further below) -- "are we
#     about to run out of credit?" Tracks the $121.03 pot via
#     var.budget_credit_balance_amount. These two variables are deliberately
#     separate -- sharing one between the two budgets was the bug.

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
# threshold, built from var.budget_notification_thresholds so ordering
# and value are variable-sourced rather than hand-duplicated per type.
locals {
  budget_notifications = flatten([
    for threshold in var.budget_notification_thresholds : [
      { threshold = threshold, notification_type = "ACTUAL" },
      { threshold = threshold, notification_type = "FORECASTED" },
    ]
  ])
}

resource "aws_budgets_budget" "gross_usage" {
  name        = "${var.project_name}-${var.environment}-gross-usage"
  budget_type = "COST"
  # Scope amendment: this is now an ANOMALY DETECTOR, not the credit-runway
  # tracker -- its limit is var.budget_monthly_limit_amount (~$35, a margin
  # over the known ~$28/month baseline), deliberately NOT
  # var.budget_credit_balance_amount. See the file header for why sharing a
  # limit variable between this and credit_runway (below) was the bug the
  # amendment fixes.
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

  dynamic "notification" {
    for_each = local.budget_notifications
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
  # The CUMULATIVE remaining credit balance ($121.03 as measured), not a
  # monthly figure -- see variables.tf. Deliberately NOT
  # var.budget_monthly_limit_amount; the two budgets must not share a limit
  # variable.
  limit_amount = var.budget_credit_balance_amount
  limit_unit   = "USD"
  # ANNUALLY, not MONTHLY: the thing being tracked is a pot that must last
  # until it's gone, not a per-month allowance. AWS Budgets has no
  # unbounded/one-shot time_unit, so ANNUALLY is the longest built-in window
  # -- if the pot is still alive next January the resource keeps working,
  # it just resets to tracking spend against the same limit_amount from the
  # new calendar year's stub period (see time_period_start note below); a
  # human still has to re-measure and update budget_credit_balance_amount
  # periodically regardless of window choice, since AWS Budgets has no way
  # to decrement a limit as credits are consumed.
  time_unit = "ANNUALLY"

  # time_period_start: AWS Budgets aligns a budget's periods to calendar
  # boundaries of its time_unit (year boundaries here) regardless of the
  # start date supplied -- the *first* period runs from time_period_start to
  # the end of the current calendar year as a stub, then subsequent periods
  # are full calendar years. There is no "start tracking exactly at this
  # instant, carry a clean $0 baseline" option; the only real choice is
  # which calendar-month boundary to anchor the stub period to. Anchoring to
  # the 1st of the CURRENT month (2026-08-01) rather than NEXT month
  # (2026-09-01) is deliberate, not a default-of-convenience:
  #   - Chose 2026-08-01: this DOUBLE-COUNTS the ~$16.06 of gross usage
  #     already burned between 2026-08-01 and today (2026-08-09, per the
  #     task doc's recorded Aug-to-date figure) -- spend that already
  #     reduced the $121.03 balance before this budget existed. The runway
  #     budget will therefore read ~$16 higher than the credit pot's actual
  #     remaining burn at any given moment this month.
  #   - The alternative, 2026-09-01, UNDER-counts instead: it would ignore
  #     the ~$20 of expected gross usage between today and end of August
  #     (~22 remaining days x ~$0.92/day), delaying every threshold crossing
  #     by roughly that much.
  # Between over- and under-counting, over-counting is the safer error for
  # a budget this task exists to make fire reliably: it moves every
  # threshold crossing slightly EARLIER, not later or not-at-all. Recorded
  # here rather than silently absorbed so a future reader isn't misled into
  # thinking this figure is exact.
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
  # and FORECASTED per threshold, same thresholds variable, same topic.
  dynamic "notification" {
    for_each = local.budget_notifications
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
