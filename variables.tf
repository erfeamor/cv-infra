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

# T-018, ruling 1: data.aws_subnets.default.ids[0] has no ordering guarantee,
# so the domain-service instance's AZ could silently move between plans.
# aws_ebs_volume.mysql_data is AZ-locked (storage.tf), so once that volume
# exists, an AZ move breaks the attachment instead of just being invisible.
# This variable is the single pinned source: it selects the instance's
# subnet (via data.aws_subnets.domain_service in network.tf) AND sets
# aws_ebs_volume.mysql_data.availability_zone directly -- the two must never
# be computed independently.
variable "availability_zone" {
  description = "AZ pinned for the domain-service instance and its dedicated MySQL EBS volume (T-018 ruling 1) -- both trace to this one variable so they cannot diverge."
  type        = string
  default     = "eu-west-3a"

  validation {
    condition     = length(var.availability_zone) > 0
    error_message = "availability_zone must not be empty."
  }
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
#
# Scope amendment (H1, ratified 2026-08-09): the original single
# budget_limit_amount was a MONTHLY limit compared against a CUMULATIVE
# credit pot -- $121.03 of remaining credit is ~4.3x the ~$28/month burn, so
# a monthly budget set to that figure reads at ~23% and never crosses even
# the lowest 50% threshold while the pot drains to zero. That is the exact
# never-fires failure class this task exists to prevent, just relocated one
# level up. Fix: two budgets, two limit variables, two threshold variables,
# two questions -- see budgets.tf for aws_budgets_budget.credit_runway
# (ANNUALLY, tracks the credit grant) and aws_budgets_budget.gross_usage
# (MONTHLY, an anomaly detector). Neither variable pair is shared between
# the two budgets -- sharing either was a real bug, found twice (limits at
# the first scope amendment, thresholds at stage 4 against the live
# account: a console-created $5 budget with shared 50/80/100 thresholds sat
# permanently in ALARM because ordinary ~$28/month burn crosses both 50%
# and 80% every month -- an alarm that always fires is one nobody reads).

variable "budget_credit_grant_amount" {
  # H1 DoR decision 2, still binding under the amendment: no default on
  # purpose. The real figure is a console read (Billing -> Credits), not a
  # guess invented here -- terraform.tfvars.example ships an obvious
  # placeholder, never a number that could pass for a measured one.
  #
  # Renamed from budget_credit_balance_amount (stage 4 finding): AWS Budgets
  # does NOT honor time_period_start as a tracking-start boundary the way
  # the original name assumed -- an ANNUALLY budget accumulates spend over
  # the whole calendar year regardless of time_period_start (see the
  # time_period_start comment on aws_budgets_budget.credit_runway in
  # budgets.tf). So the number this variable must hold is the TOTAL credit
  # GRANT for the year, not the remaining balance at some later
  # measurement date -- against calendar-year spend, only the grant total
  # makes the percentage thresholds land on true depletion.
  #
  # Currently $160 (measured: $160 granted, $39.34 already spent this
  # year, $121.03 remaining -- consistent figures, different question).
  # DO NOT raise this to $200 when the two remaining credit-earning
  # activities land, even though the grant will genuinely become $200.
  # Reason (T-010, measured): this account is on the FREE plan, whose
  # 6-month window closes ~2027-01-12 -- BEFORE a $200 grant would be
  # exhausted (~2027-02-01 at $0.92/day). Raising the limit to $200 pushes
  # the 100% alert to 1 Feb, i.e. ~20 days AFTER the account has already
  # been paused: an alarm that fires only once it no longer matters.
  # Held at $160, the thresholds fire 24 Sep / 15 Nov / 20 Dec -- all
  # usefully before the window. So 100% here no longer means "credits
  # exhausted"; it means "~3 weeks left before the plan window closes",
  # which is the deadline that actually binds. Revisit only if the account
  # moves to the Paid plan, where credit exhaustion becomes the real limit
  # again.
  description = "Total AWS Free Tier credit GRANT for the current calendar year, in USD (aws_budgets_budget.credit_runway.limit_amount) -- credit_runway is ANNUALLY and AWS accumulates its spend over the whole calendar year regardless of time_period_start, so this must be the total grant, not a remaining balance measured partway through the year. Must come from a measured console read -- do not invent a value here."
  type        = string

  # Finding 4 (review round 1), still applicable: without this, an operator
  # who fills in the secrets but leaves the tfvars.example placeholder
  # ("REPLACE_ME_...") gets a clean plan and an apply that creates the SNS
  # topic (and fires real confirmation emails) before failing at
  # CreateBudget -- leaving a confirmed topic with no budget behind it.
  # Fail this at plan instead.
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
    condition     = can(tonumber(var.budget_credit_grant_amount)) ? tonumber(var.budget_credit_grant_amount) > 0 : false
    error_message = "budget_credit_grant_amount must be a positive number encoded as a string (e.g. \"160\"), not a placeholder -- fill in a measured console figure."
  }
}

variable "budget_monthly_limit_amount" {
  # Unlike budget_credit_grant_amount, this DOES get a default: it is not a
  # cumulative pot that needs a fresh console read, it is a design margin
  # over a known, already-measured baseline ratified in the scope
  # amendment itself, the same way budget_monthly_thresholds and
  # budget_credit_runway_thresholds ship ratified defaults. Still
  # overridable, and still validated the same way so a bad override fails
  # at plan, not at CreateBudget.
  #
  # $30 (was $35): burn is back under $1/day after the RDS teardown, so $30
  # now represents expected monthly spend rather than a margin above it --
  # see budget_monthly_thresholds below, which is what turns "expected" into
  # an anomaly detector now that the limit itself IS the expectation.
  description = "Monthly gross-usage budget limit, in USD (aws_budgets_budget.gross_usage.limit_amount) -- represents expected monthly spend (burn is back under $1/day after the RDS teardown). aws_budgets_budget.gross_usage's own thresholds (budget_monthly_thresholds, not the shared 50/80/100) are what make this an anomaly detector: 100% of this limit is already 'as expected', not a milestone. Independent of budget_credit_grant_amount on purpose: the two budgets must never share a limit variable."
  type        = string
  default     = "30"

  validation {
    condition     = can(tonumber(var.budget_monthly_limit_amount)) ? tonumber(var.budget_monthly_limit_amount) > 0 : false
    error_message = "budget_monthly_limit_amount must be a positive number encoded as a string (e.g. \"30\"), not a placeholder."
  }
}

variable "budget_credit_runway_thresholds" {
  # Renamed from budget_notification_thresholds (human-ratified, stage 4):
  # once gross_usage got its own threshold variable below, the old shared
  # name read as if one list still applied to both budgets. It doesn't --
  # each budget's thresholds mean something different (see both
  # descriptions) and must never be swapped.
  description = "Ascending, strictly increasing list of percentage-of-limit thresholds for aws_budgets_budget.credit_runway ONLY, at which both an ACTUAL and a FORECASTED notification fire (notification.threshold, threshold_type = PERCENTAGE). These are genuine milestones on the way to credit depletion -- 50/80/100 by default. Independent of budget_monthly_thresholds on purpose: the two budgets must never share a thresholds variable (a console-created budget that shared 50/80/100 against ordinary monthly burn sat permanently in ALARM -- stage 4 finding, deleted)."
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
    condition     = length(var.budget_credit_runway_thresholds) > 0
    error_message = "budget_credit_runway_thresholds must not be empty -- zero notification blocks means the budget applies cleanly and never fires."
  }

  validation {
    condition = alltrue([
      for i in range(max(length(var.budget_credit_runway_thresholds) - 1, 0)) :
      var.budget_credit_runway_thresholds[i] < var.budget_credit_runway_thresholds[i + 1]
    ])
    error_message = "budget_credit_runway_thresholds must be strictly ascending with no duplicates -- an inverted or repeated threshold either fires immediately or never."
  }

  validation {
    condition     = alltrue([for t in var.budget_credit_runway_thresholds : t > 0])
    error_message = "budget_credit_runway_thresholds must all be > 0."
  }
}

variable "budget_monthly_thresholds" {
  # New (human-ratified, stage 4): gross_usage's OWN thresholds, deliberately
  # different from credit_runway's 50/80/100. budget_monthly_limit_amount
  # ($30) now represents EXPECTED spend, not a ceiling with headroom, so
  # crossing it at all is the anomaly signal: 100% = over expectation,
  # 120% = materially over, 150% = something is wrong. At steady state
  # (~$28/month actual burn against $30 expected) this produces ZERO
  # notifications -- the opposite of the shared-thresholds bug this
  # variable exists to fix (see budget_credit_runway_thresholds).
  description = "Ascending, strictly increasing list of percentage-of-limit thresholds for aws_budgets_budget.gross_usage ONLY (notification.threshold, threshold_type = PERCENTAGE). budget_monthly_limit_amount represents expected spend, so these mark deviation from it, not progress toward it: 100/120/150 by default. Independent of budget_credit_runway_thresholds on purpose -- the two budgets must never share a thresholds variable."
  type        = list(number)
  default     = [100, 120, 150]

  # Same empty-safe pattern as budget_credit_runway_thresholds (finding 5,
  # review round 1) -- range(-1) returns [0], not [], so this must be
  # guarded the same way.
  validation {
    condition     = length(var.budget_monthly_thresholds) > 0
    error_message = "budget_monthly_thresholds must not be empty -- zero notification blocks means the budget applies cleanly and never fires."
  }

  validation {
    condition = alltrue([
      for i in range(max(length(var.budget_monthly_thresholds) - 1, 0)) :
      var.budget_monthly_thresholds[i] < var.budget_monthly_thresholds[i + 1]
    ])
    error_message = "budget_monthly_thresholds must be strictly ascending with no duplicates -- an inverted or repeated threshold either fires immediately or never."
  }

  validation {
    condition     = alltrue([for t in var.budget_monthly_thresholds : t > 0])
    error_message = "budget_monthly_thresholds must all be > 0."
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
