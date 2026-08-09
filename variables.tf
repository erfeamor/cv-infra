variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-3"
}

variable "project_name" {
  description = "Prefix applied to all resource names/tags"
  type        = string
  default     = "cv-project"
}

variable "environment" {
  description = "Deployment environment (dev/prod)"
  type        = string
  default     = "dev"
}

variable "db_name" {
  description = "Name of the MySQL database created on the RDS instance"
  type        = string
  default     = "cv"
}

variable "db_username" {
  description = "Master username for the RDS instance"
  type        = string
  default     = "cv"
}

variable "db_password" {
  description = "Master password for the RDS instance"
  type        = string
  sensitive   = true
}

variable "domain_service_instance_type" {
  description = "EC2 instance type for cv-domain-service (Free Tier: t2.micro/t3.micro)"
  type        = string
  default     = "t3.micro"
}

variable "drone_instance_type" {
  # T-002 (H1, ratified 2026-08-04): Free Tier already covers one t3.micro
  # (this account runs two -> domain_service + drone -> so ~710 h/month was
  # already billable before this change, ~$8/mo). t3.micro (1 GB) cannot
  # host Jenkins + Maven alongside Drone without OOM risk, so this box is
  # sized up. t3.small (2 GB) ~= $16.60/mo, a net +$8/mo over today. This is
  # a deliberate, recorded exception to the workspace's Free-Tier-only rule
  # for this resource only (see terraform.tfvars.example and the T-002 PR
  # body for the same figure) -- the docs correction itself is T-003.
  description = "EC2 instance type for the Drone + Jenkins CI host"
  type        = string
  default     = "t3.small"
}

variable "drone_admin_username" {
  description = "GitHub username granted Drone admin and allowed to log in"
  type        = string
  default     = "erfeamor"
}

variable "drone_rpc_secret" {
  description = "Shared secret between the Drone server and runner (openssl rand -hex 16)"
  type        = string
  sensitive   = true
}

variable "drone_github_client_id" {
  description = "Client ID of the GitHub OAuth app used by Drone"
  type        = string
}

variable "drone_github_client_secret" {
  description = "Client secret of the GitHub OAuth app used by Drone"
  type        = string
  sensitive   = true
}

variable "jenkins_admin_username" {
  description = "Local Jenkins admin username configured via JCasC on first boot (not a secret, mirrors drone_admin_username)"
  type        = string
  default     = "erfeamor"
}

variable "jenkins_admin_password" {
  description = "Local Jenkins admin password, read from SSM by the provisioning script and injected via env var only -- never written to a file on the host or committed to tfvars (openssl rand -base64 24)"
  type        = string
  sensitive   = true
}

variable "github_pat_ci" {
  description = "GitHub PAT Jenkins uses to check out branches and post commit statuses on cv-domain-service and cv-database. Least privilege: repo:status (classic) or fine-grained Commit-statuses:read/write scoped to just those two repos -- never bare 'repo' scope."
  type        = string
  sensitive   = true
}

# T-011: budget alarm that fires on gross usage, not net-of-credit cost --
# see budgets.tf for the include_credit = false crux this task exists for.

variable "budget_limit_amount" {
  # H1 DoR decision 2: no default on purpose. The real figure is T-010's
  # console read of measured gross usage, not a guess invented here --
  # terraform.tfvars.example ships an obvious placeholder, never a number
  # that could pass for a measured one.
  description = "Monthly gross-usage budget limit, in USD (aws_budgets_budget.limit_amount). Must come from T-010's measured console figure -- do not invent a value here."
  type        = string

  # Finding 4 (review round 1): without this, an operator who fills in the
  # secrets but leaves the tfvars.example placeholder ("REPLACE_ME_...")
  # gets a clean plan and an apply that creates the SNS topic (and fires
  # real confirmation emails) before failing at CreateBudget -- leaving a
  # confirmed topic with no budget behind it. Fail this at plan instead.
  validation {
    # Two gotchas found while writing this, both confirmed empirically:
    # `&&` does not short-circuit in Terraform, so
    # `can(tonumber(x)) && tonumber(x) > 0` still evaluates the second
    # tonumber(x) and raises an uncaught conversion error instead of
    # cleanly failing validation when x isn't numeric. And can() discards
    # the wrapped expression's *value*, only reporting whether it errored
    # -- so `can(tonumber(x) > 0)` is true for x = "-5" (tonumber succeeds,
    # the comparison just evaluates to false without erroring), silently
    # accepting a non-positive limit. The ternary below short-circuits
    # correctly: the false branch is a literal, so it never re-evaluates
    # tonumber() on a value already known not to convert.
    condition     = can(tonumber(var.budget_limit_amount)) ? tonumber(var.budget_limit_amount) > 0 : false
    error_message = "budget_limit_amount must be a positive number encoded as a string (e.g. \"50\"), not a placeholder -- fill in T-010's measured console figure."
  }
}

variable "budget_notification_thresholds" {
  description = "Ascending, strictly increasing list of percentage-of-limit thresholds (of budget_limit_amount) at which both an ACTUAL and a FORECASTED notification fire (aws_budgets_budget notification.threshold, threshold_type = PERCENTAGE)."
  type        = list(number)
  default     = [50, 80, 100]

  # Finding 5 (review round 1): an empty list must fail here, explicitly --
  # not just because a zero-notification budget applies cleanly, reads
  # green, and never fires (the exact outcome this task exists to prevent),
  # but because range(length(x) - 1) is not empty-safe: range(-1) returns
  # [0], not [], so an empty list would otherwise index element 0 of an
  # empty list in the ascending check below and abort with a confusing
  # "Invalid index" instead of either authored validation message. Guard
  # both.
  validation {
    condition     = length(var.budget_notification_thresholds) > 0
    error_message = "budget_notification_thresholds must not be empty -- zero notification blocks means the budget applies cleanly and never fires."
  }

  validation {
    condition = alltrue([
      for i in range(max(length(var.budget_notification_thresholds) - 1, 0)) :
      var.budget_notification_thresholds[i] < var.budget_notification_thresholds[i + 1]
    ])
    error_message = "budget_notification_thresholds must be strictly ascending with no duplicates -- an inverted or repeated threshold either fires immediately or never."
  }

  validation {
    condition     = alltrue([for t in var.budget_notification_thresholds : t > 0])
    error_message = "budget_notification_thresholds must all be > 0."
  }
}

variable "budget_notification_emails" {
  # H1 DoR decision 2/3: no default on purpose -- this must be an address a
  # human actually reads, not a placeholder that silently ships as if it
  # were real. terraform.tfvars.example carries an obvious REPLACE_ME.
  description = "Email addresses subscribed (via SNS, DoR decision 3) to the budget-alerts topic. Must be non-empty -- a budget that notifies nobody is worse than no budget."
  type        = list(string)

  validation {
    condition     = length(var.budget_notification_emails) > 0
    error_message = "budget_notification_emails must not be empty -- a budget alarm with no subscriber notifies nobody."
  }
}
