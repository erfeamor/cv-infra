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

data "aws_caller_identity" "current" {}

resource "aws_sns_topic" "budget_alerts" {
  name = "${var.project_name}-${var.environment}-budget-alerts"

  tags = {
    Project = var.project_name
  }
}

resource "aws_sns_topic_policy" "budget_alerts" {
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
  # DoR decision 2 (H1): thresholds/limit are variables with placeholder
  # defaults -- this task must not invent a credit balance, or ship a guess
  # as if it were the measured figure from T-010's console read.
  limit_amount = var.budget_limit_amount
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # The crux -- see file header. Non-negotiable per H1 DoR decision 1.
  cost_types {
    include_credit = false
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
}
