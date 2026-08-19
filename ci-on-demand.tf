# T-019: start the CI host on push, stop it when quiet.
#
# The CI host is the single largest line on this account's bill (~$17.24/mo,
# 46%) and a portfolio project pushes a handful of times a week. Rather than
# pay for the idle 95%, GitHub rings a doorbell (a Lambda behind a Function
# URL) which starts the instance, and a scheduled reaper stops it once Jenkins
# reports nothing running.
#
# Two design decisions are load-bearing and are NOT free to change without
# re-reading T-019's rulings:
#
#  1. The doorbell never forwards the webhook payload. The Jenkins jobs carry a
#     periodicFolderTrigger (see templates/jenkins-provision.sh), so the first
#     branch scan after boot discovers whatever was pushed while the box was
#     down. That is why there is no SQS queue and no replay machinery here.
#     Drone is NOT covered by this — it is webhook-only with no SCM polling, so
#     a push to cv-admin-react starts the box and builds nothing. Accepted
#     deliberately at T-019's H1; revisit at T-301, when that repo is worked on.
#
#  2. authorization_type = "NONE" on the Function URL is forced, not lazy:
#     GitHub webhooks cannot sign SigV4. The real authentication is the HMAC
#     check in lambda/ci_doorbell/index.py, which runs before any AWS call. An
#     unauthenticated endpoint that can start instances is a cost-DoS against a
#     finite, expiring credit pot — that check is the whole security boundary.
#
# The EIP is what makes any of this possible: aws_eip.drone (ci.tf) means the
# public IP survives a stop/start, so the webhook URL and Drone's OAuth callback
# stay valid across cycles. Do not release it to save the ~$3.65/mo.

locals {
  ci_instance_arn = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.drone.id}"

  # Repos whose pushes may start the box. A valid signature proves the sender
  # holds the secret; this proves we actually run CI for the repo.
  ci_allowed_repos = [
    "erfeamor/cv-domain-service",
    "erfeamor/cv-database",
    "erfeamor/cv-admin-react",
  ]

  # The blast radius of ruling 3, named rather than inlined, for two reasons.
  # A reviewer can see the whole EC2 grant of both Lambdas in four lines; and
  # `terraform test` can assert on these, which it CANNOT do on the policy
  # documents themselves — those interpolate computed ARNs (instance id, SSM
  # parameter ARNs), so the rendered JSON is unknown until apply and jsondecode
  # fails under `command = plan`. Same limitation the file already records for
  # aws_eip.drone.public_ip.
  #
  # If you are adding an action here, that is the moment to ask whether a
  # public unauthenticated endpoint should be able to do it.
  ci_doorbell_ec2_actions = ["ec2:StartInstances"]
  ci_reaper_ec2_actions   = ["ec2:StopInstances"]
  ci_forbidden_ec2_actions = [
    "ec2:TerminateInstances",
    "ec2:ModifyInstanceAttribute",
    "ec2:RunInstances",
    "ec2:*",
  ]
}

data "archive_file" "ci_doorbell" {
  type        = "zip"
  source_file = "${path.module}/lambda/ci_doorbell/index.py"
  output_path = "${path.module}/.terraform/ci_doorbell.zip"
}

data "archive_file" "ci_reaper" {
  type        = "zip"
  source_file = "${path.module}/lambda/ci_reaper/index.py"
  output_path = "${path.module}/.terraform/ci_reaper.zip"
}

# ---------------------------------------------------------------------------
# Doorbell — GitHub webhook -> start the instance
# ---------------------------------------------------------------------------

resource "aws_iam_role" "ci_doorbell" {
  name = "${var.project_name}-ci-doorbell"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy" "ci_doorbell" {
  name = "${var.project_name}-ci-doorbell"
  role = aws_iam_role.ci_doorbell.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Start only, scoped to the one instance. Deliberately no
        # TerminateInstances, ModifyInstanceAttribute or RunInstances: the
        # worst a compromised doorbell can do is turn the CI box on.
        Effect   = "Allow"
        Action   = local.ci_doorbell_ec2_actions
        Resource = local.ci_instance_arn
      },
      {
        # ec2:DescribeInstances has no resource-level permissions in IAM — it
        # is "*" or nothing. Read-only and account-scoped; noted rather than
        # left looking like carelessness.
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.github_webhook_secret.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.ci_doorbell.arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "ci_doorbell" {
  function_name    = "${var.project_name}-ci-doorbell"
  role             = aws_iam_role.ci_doorbell.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 10
  filename         = data.archive_file.ci_doorbell.output_path
  source_code_hash = data.archive_file.ci_doorbell.output_base64sha256

  environment {
    variables = {
      INSTANCE_ID          = aws_instance.drone.id
      WEBHOOK_SECRET_PARAM = aws_ssm_parameter.github_webhook_secret.name
      ALLOWED_REPOS        = join(",", local.ci_allowed_repos)
    }
  }

  depends_on = [aws_cloudwatch_log_group.ci_doorbell]

  tags = {
    Project = var.project_name
  }
}

resource "aws_lambda_function_url" "ci_doorbell" {
  function_name = aws_lambda_function.ci_doorbell.function_name

  # See the header: GitHub cannot sign SigV4, so the HMAC check inside the
  # handler is the authentication. Changing this to AWS_IAM would not harden
  # anything — it would simply stop GitHub being able to call it at all.
  authorization_type = "NONE"
}

# ---------------------------------------------------------------------------
# Reaper — scheduled idle check -> stop the instance
# ---------------------------------------------------------------------------

resource "aws_iam_role" "ci_reaper" {
  name = "${var.project_name}-ci-reaper"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy" "ci_reaper" {
  name = "${var.project_name}-ci-reaper"
  role = aws_iam_role.ci_reaper.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = local.ci_reaper_ec2_actions
        Resource = local.ci_instance_arn
      },
      {
        # Same IAM limitation as the doorbell's describe.
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        # cloudwatch:GetMetricStatistics likewise takes no resource ARN.
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricStatistics"]
        Resource = "*"
      },
      {
        # A separate identity from the instance profile, reading exactly one
        # parameter. This narrows the shared-credential picture T-005 is
        # concerned with rather than widening it.
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.jenkins_admin_password.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.ci_reaper.arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "ci_reaper" {
  function_name    = "${var.project_name}-ci-reaper"
  role             = aws_iam_role.ci_reaper.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.ci_reaper.output_path
  source_code_hash = data.archive_file.ci_reaper.output_base64sha256

  environment {
    variables = {
      INSTANCE_ID            = aws_instance.drone.id
      JENKINS_BASE_URL       = "http://${aws_eip.drone.public_ip}/jenkins"
      JENKINS_USER           = var.jenkins_admin_username
      JENKINS_PASSWORD_PARAM = aws_ssm_parameter.jenkins_admin_password.name
      IDLE_WINDOW_MINUTES    = tostring(var.ci_idle_window_minutes)
      CPU_BUSY_PERCENT       = tostring(var.ci_cpu_busy_percent)
    }
  }

  depends_on = [aws_cloudwatch_log_group.ci_reaper]

  tags = {
    Project = var.project_name
  }
}

resource "aws_cloudwatch_event_rule" "ci_reaper" {
  name                = "${var.project_name}-ci-reaper"
  description         = "T-019: check whether the CI host has gone idle and stop it if so"
  schedule_expression = "rate(5 minutes)"

  tags = {
    Project = var.project_name
  }
}

resource "aws_cloudwatch_event_target" "ci_reaper" {
  rule      = aws_cloudwatch_event_rule.ci_reaper.name
  target_id = "ci-reaper"
  arn       = aws_lambda_function.ci_reaper.arn
}

resource "aws_lambda_permission" "ci_reaper_events" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ci_reaper.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ci_reaper.arn
}
