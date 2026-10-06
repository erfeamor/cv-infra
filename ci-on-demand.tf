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
# T-034 phase 2 released the EIP that used to back this paragraph's claim --
# there is no more aws_eip.drone (ci.tf; scripts/check-static.sh check 13
# pins its absence). Stability across a stop/start now comes from
# var.ci_hostname instead (dns.tf's Route 53 record, kept current on every
# boot by scripts/ci-dns-updater.sh) -- the webhook URL (the doorbell's own
# Function URL, unaffected either way) and Drone's OAuth callback
# (https://ci.erfeamor.com/login) both address the box by that name, never
# by its public IP directly, so a different IP on every cycle is fine.

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

  # T-048: the doorbell stamps this operational tag on an already-running CI
  # host when a push to a Jenkins repo arrives (Jenkins only finds it on its
  # next scan); the reaper reads it from DescribeInstances (no new grant) and
  # holds off stopping. The grant is CreateTags on the CI instance only, and
  # only for this one tag key -- a compromised doorbell cannot retag anything
  # else (e.g. clear CIKeepAlive or touch Name).
  ci_push_tag_key         = "CILastPush"
  ci_doorbell_tag_actions = ["ec2:CreateTags"]
  ci_doorbell_tag_condition = {
    "ForAllValues:StringEquals" = { "aws:TagKeys" = [local.ci_push_tag_key] }
  }
  ci_forbidden_ec2_actions = [
    "ec2:TerminateInstances",
    "ec2:ModifyInstanceAttribute",
    "ec2:RunInstances",
    "ec2:*",
  ]

  # T-034 H1 correction: the doorbell self-invokes (InvocationType=Event)
  # rather than standing up a second Lambda for the slow redeliver path --
  # named here for the same reason as the EC2 action lists above: a reviewer
  # sees the whole grant in one line, and `terraform test` can assert on it
  # even though the rendered policy JSON (which embeds this function's own
  # computed ARN) cannot be jsondecode'd under `command = plan`.
  ci_doorbell_lambda_actions = ["lambda:InvokeFunction"]

  # Named apart from the function resource so the resource's own
  # `function_name` argument and this env var can both reference it without
  # aws_lambda_function.ci_doorbell.function_name being a self-reference
  # (Terraform rejects a resource referencing its own attribute from within
  # its own body, even when — as here — the value is a literal known at plan
  # time, not a computed one).
  ci_doorbell_function_name = "${var.project_name}-ci-doorbell"

  # H1: redelivery (not forwarding) applies to this repo only. Drone
  # verifies each webhook against a per-repo secret only it and GitHub know,
  # so nothing this handler could send Drone directly would pass that check
  # anyway — the Jenkins repos keep ruling 1's periodicFolderTrigger
  # discovery and never touch this path.
  ci_redeliver_repos = ["erfeamor/cv-admin-react"]

  # Review round 1, finding 10: the CI host's one public address, named once.
  # Phase 2 (T-034) landed: the EIP is replaced by var.ci_hostname (dns.tf's
  # aws_route53_record, kept current by scripts/ci-dns-updater.sh on every
  # boot) -- every consumer below (the reaper's Jenkins URL, the doorbell's
  # Drone healthz URL) references this local, never the hostname variable or
  # any address literal directly, so a future re-point (a new domain, say)
  # changes exactly this one line. Enforced textually by
  # scripts/check-static.sh check 9.
  ci_public_host = var.ci_hostname

  # T-034 phase 2 review round 1, finding 2 (second half): the reaper and
  # doorbell still address the host by local.ci_public_host (the DNS name),
  # NOT by the instance's public IP from their own ec2:DescribeInstances
  # call, even though that call is already made for other reasons.
  # Deliberate, not an oversight -- addressing by raw IP would fight the
  # very security fix finding 1 added: Caddy's catch-all now answers 421 to
  # any request whose Host isn't ci_hostname (templates/jenkins-provision.sh),
  # and a raw-IP request's Host header/TLS SNI would BE the IP, not the
  # hostname -- so switching to IP addressing would need the Lambdas to
  # connect-by-IP-but-verify/SNI-as-the-hostname (Python's http.client
  # supports this, but it is real, fragile, untested-here complexity that
  # re-adds exactly the kind of address coupling T-034 phase 2 exists to
  # remove). The risk this would guard against -- stale DNS right after a
  # cold start making the reaper misread Jenkins as unreachable -- is
  # already bounded three ways without it: (a) jenkins_is_idle() already
  # treats unreachable as BUSY (T-019 ruling 2, deliberate: cost over
  # safety), never as a reason to act; (b) the reaper's own post-start grace
  # (var.ci_post_start_grace_minutes, 15 min) means idleness is never even
  # evaluated until long after DNS has converged (the updater runs at boot,
  # Before=docker.service, and the propagation TTL is 60s); (c) the review's
  # own finding 2 (first half) added a 5-minute re-run timer
  # (scripts/ci-dns-updater.sh) on top of that. A genuinely broken DNS
  # record costs money (the box stays running) but never breaks a build --
  # the same trade-off T-019 ruling 2 already made on purpose.
  #
  # Review round 2, finding 2(b) update: the doorbell DOES now read the
  # instance's raw public IP -- but only to COMPARE it against what
  # CI_HOSTNAME resolves to (wait_for_dns_to_match_instance,
  # lambda/ci_doorbell/index.py), never as the address it actually connects
  # to. Every real request (healthz, and Drone/GitHub traffic) still goes to
  # https://ci_hostname/..., so the reasoning above is unaffected.

  # Review round 2, finding 2: the shared placeholder ALL of dns.tf's
  # record, the reaper's post-stop UPSERT, and templates/jenkins-provision.sh's
  # ExecStop unit use -- named once so the three can never drift apart.
  # 192.0.2.1 is TEST-NET-1 (RFC 5737): guaranteed to never route anywhere
  # real, so "the record currently says this" unambiguously means "this
  # host is not up," never a stale-but-plausible address someone could
  # mistake for a live one.
  ci_dns_sentinel_ip = "192.0.2.1"

  # Review round 1, finding 4: the budget behind aws_lambda_function.ci_doorbell's
  # timeout, named piece by piece so a reviewer can see where the number comes
  # from instead of trusting a bare literal. Review round 3, finding 6 added
  # the first and third pieces below -- the original two-piece budget
  # undercounted the worst-case async-task path (a `stopping` instance that
  # needs waiting out, index.py's _wait_for_instance_stopped, THEN the full
  # healthz wait; and the healthz wait's own final poll can itself overshoot
  # its nominal ceiling by up to one HTTP request timeout before urlopen gives
  # up). All four mirror named Python constants in lambda/ci_doorbell/index.py
  # (kept in sync by hand -- there is no wiring between them beyond this
  # comment and the env vars actually passed below):
  #   - stopping_wait  <-> INSTANCE_STOPPING_WAIT_TIMEOUT_SECONDS
  #   - dns_wait       <-> DNS_WAIT_TIMEOUT_SECONDS (review round 2, finding
  #     2(b) -- waits for the AUTHORITATIVE Route 53 record value (read via
  #     route53:ListResourceRecordSets, lambda/ci_doorbell/index.py's
  #     _route53_record_ip) to match the instance's OWN current public IP
  #     before ever probing healthz, so a probe can never hit a stale
  #     address or the reaper's own DNS sentinel, finding 2(a))
  #   - healthz        <-> HEALTHZ_TIMEOUT_SECONDS (PO-settled ceiling, t034p1-plan.md)
  #   - probe_timeout  <-> HTTP_TIMEOUT_SECONDS (the one extra overshoot noted above)
  #   - github_work    <-> the budget for bounded hooks/deliveries pagination
  #     (MAX_LIST_PAGES pages each) and up to MAX_REDELIVERIES_PER_RUN
  #     redelivery POSTs, each itself capped at HTTP_TIMEOUT_SECONDS
  # Sum is 895s, comfortably inside Lambda's 900s hard ceiling with 5s to
  # spare -- see the <= 900 assertion in tests/plan.tftest.hcl.
  # github_work_budget dropped from 290 to 230 to make room for dns_wait
  # (60s) at the same 895s total -- nothing about the GitHub work itself
  # changed, only how the same ceiling is divided.
  #
  # Live failure, 2026-09-30: dns_wait doubled from 60 to 120 because 60s was
  # observed live to be too tight against a genuinely cold Lambda execution
  # environment -- the boot-time updater's UPSERT converges the AUTHORITATIVE
  # Route 53 value within its own run (about 30-60s after boot), but the
  # OLD code compared against the Lambda's local resolver instead, which held
  # the DNS sentinel (192.0.2.1, TTL 60) cached from before the record was
  # updated. The fix (this commit) reads the Route 53 API directly, which is
  # never subject to that cache, but 120s is kept as the wait's ceiling
  # anyway to give the updater's own convergence window comfortable room
  # without eating further into github_work_budget than necessary.
  # github_work_budget dropped a further 60s (230 -> 170) to pay for it,
  # keeping the total at the same 895s.
  ci_doorbell_stopping_wait_seconds         = 120
  ci_doorbell_dns_wait_seconds              = 120
  ci_doorbell_healthz_timeout_seconds       = 480
  ci_doorbell_healthz_probe_timeout_seconds = 5
  ci_doorbell_github_work_budget_seconds    = 170
  ci_doorbell_timeout_seconds = (
    local.ci_doorbell_stopping_wait_seconds +
    local.ci_doorbell_dns_wait_seconds +
    local.ci_doorbell_healthz_timeout_seconds +
    local.ci_doorbell_healthz_probe_timeout_seconds +
    local.ci_doorbell_github_work_budget_seconds
  )
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
        # T-048: stamp CILastPush on the CI instance (only), for that tag key
        # (only) -- see local.ci_push_tag_key.
        Effect    = "Allow"
        Action    = local.ci_doorbell_tag_actions
        Resource  = local.ci_instance_arn
        Condition = local.ci_doorbell_tag_condition
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
        # T-034: the fine-grained hooks token, scoped to this single
        # parameter -- see ssm.tf for why it lives outside ci/*.
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.github_hooks_token.arn
      },
      {
        # T-034 H1 correction: the async redelivery path self-invokes.
        # Resource-scoped to this function's OWN arn only -- a compromised
        # doorbell gains nothing by this grant beyond re-queuing itself.
        Effect   = "Allow"
        Action   = local.ci_doorbell_lambda_actions
        Resource = aws_lambda_function.ci_doorbell.arn
      },
      {
        # Live failure, 2026-09-30: the DNS-convergence wait
        # (wait_for_dns_to_match_instance, lambda/ci_doorbell/index.py) can no
        # longer trust the Lambda's own local resolver -- a cold execution
        # environment can hold the DNS sentinel cached past the point Route
        # 53's record was actually updated. This grant lets it read the
        # AUTHORITATIVE record value straight from the API instead, which is
        # never subject to that cache. Read-only, reusing iam.tf's
        # ci_dns_read_actions local (the same action already granted to the
        # boot-time updater's own idempotency check), scoped to this zone's
        # ARN only -- Route 53 has no record-level ARNs, so the zone is the
        # narrowest Resource this action can ever take.
        Effect   = "Allow"
        Action   = local.ci_dns_read_actions
        Resource = data.aws_route53_zone.ci.arn
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
  function_name = local.ci_doorbell_function_name
  role          = aws_iam_role.ci_doorbell.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  # T-034: this same function runs the async wake+redeliver task (self
  # invocation), which waits up to HEALTHZ_TIMEOUT_SECONDS for Drone's own
  # /healthz before redelivering, then does bounded GitHub work. See
  # local.ci_doorbell_timeout_seconds for the budget this number comes from
  # (review round 1, finding 4) -- the webhook entry point itself still
  # answers in low single-digit seconds; this timeout is a ceiling, not how
  # long a normal invocation runs.
  timeout          = local.ci_doorbell_timeout_seconds
  filename         = data.archive_file.ci_doorbell.output_path
  source_code_hash = data.archive_file.ci_doorbell.output_base64sha256

  environment {
    variables = {
      INSTANCE_ID                   = aws_instance.drone.id
      WEBHOOK_SECRET_PARAM          = aws_ssm_parameter.github_webhook_secret.name
      ALLOWED_REPOS                 = join(",", local.ci_allowed_repos)
      REDELIVER_REPOS               = join(",", local.ci_redeliver_repos)
      PUSH_TAG                      = local.ci_push_tag_key
      GITHUB_HOOKS_TOKEN_PARAM      = aws_ssm_parameter.github_hooks_token.name
      CI_HOSTNAME                   = local.ci_public_host
      ROUTE53_ZONE_ID               = data.aws_route53_zone.ci.zone_id
      DRONE_HEALTHZ_URL             = "https://${local.ci_public_host}/healthz"
      DNS_WAIT_TIMEOUT_SECONDS      = tostring(local.ci_doorbell_dns_wait_seconds)
      HEALTHZ_TIMEOUT_SECONDS       = tostring(local.ci_doorbell_healthz_timeout_seconds)
      HEALTHZ_POLL_INTERVAL_SECONDS = "15"
      SELF_FUNCTION_NAME            = local.ci_doorbell_function_name
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

# WITHOUT THIS THE FUNCTION URL RETURNS 403 AND THE LAMBDA IS NEVER INVOKED.
#
# Found at stage-4 verification, not by reading anything: every request to the
# URL came back as AWS's own AccessDeniedException with zero invocations
# logged, while a direct `lambda invoke` of the same function worked perfectly.
#
# Accounts created after ~2024 — this one dates to 2026-07 — have Lambda's
# "block public access" behaviour on by default. Under it, the
# `lambda:InvokeFunctionUrl` grant that `aws_lambda_function_url` creates for
# an AuthType=NONE url is NOT sufficient on its own: the block specifically
# stops that permission from conferring public access. An unconditioned
# `lambda:InvokeFunction` grant is what actually opens the path.
#
# Note the asymmetry, because it wastes an hour otherwise: this statement must
# NOT carry function_url_auth_type. AWS rejects that outright —
# "FunctionUrlAuthType is only supported for lambda:InvokeFunctionUrl action".
#
# On Principal = "*", which a reviewer should stop at: it is genuinely
# unconditioned, and it means anyone may invoke this function. That is
# acceptable here for one specific reason — **the authentication is in the
# handler, not in the transport**. index.py verifies GitHub's HMAC over the raw
# body before it touches the EC2 API, so an unsigned invocation, by any route,
# returns 401 and starts nothing. Verified live: an unsigned POST through this
# URL returns "bad signature" and the instance is untouched. If that check is
# ever weakened, this grant becomes a genuine cost-DoS hole.
#
# Review round 1 (0567f6a) tried narrowing this to lambda:InvokeFunctionUrl +
# function_url_auth_type = "NONE" (finding 1(a)) to stop a direct
# lambda:InvokeFunction call from reaching _handle_async_task unauthenticated.
# Round 2 (driver review) reverted that: T-019 (bd65353) verified LIVE that
# this account's Lambda block-public-access setting makes InvokeFunctionUrl
# alone insufficient (403, zero invocations) and that the unconditioned
# InvokeFunction grant is what actually opens the path -- narrowing it here
# would silently break the doorbell for the Jenkins repos too on the next
# apply. Finding 1's real fix now lives one layer down: every async task
# event must itself carry a valid HMAC over (repo, wake_time), verified in
# _handle_async_task before anything else happens (index.py) -- so a direct,
# unconditioned InvokeFunction call still reaches the handler, but with
# nothing to act on unless it also holds the webhook secret. Do NOT narrow
# this permission again without a LIVE test proving InvokeFunctionUrl alone
# still works on this account (terraform test pins the action below so a
# future edit here fails loudly, not silently, at review time).
resource "aws_lambda_permission" "ci_doorbell_public_invoke" {
  statement_id  = "AllowPublicInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ci_doorbell.function_name
  principal     = "*"
}

# Review round 1, finding 4: Lambda's default async-invoke behaviour retries
# a failing/erroring event up to twice more, minutes apart. A retry of the
# wake+redeliver task would re-run ec2:StartInstances (harmless -- idempotent
# against a running instance) but ALSO re-run redeliver_failed_deliveries,
# which is exactly the double-redelivery this task spent findings 2/3
# avoiding within a single run; disabling retries keeps "one wake -> at most
# one redelivery pass" true across the whole async path, not just inside one
# invocation. maximum_event_age_in_seconds is short because a wake+redeliver
# task queued but not yet started is only useful while still fresh -- a
# heavily throttled/delayed first attempt run minutes later would revalidate
# against a now-stale wake_time (index.py's WAKE_TIME_MAX_AGE_SECONDS) and be
# rejected anyway, so there is nothing to gain by letting Lambda hold it
# longer.
resource "aws_lambda_function_event_invoke_config" "ci_doorbell" {
  function_name                = aws_lambda_function.ci_doorbell.function_name
  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = 60
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
      {
        # Review round 2, finding 2(a): right after stopping the instance,
        # the reaper UPSERTs the same DNS sentinel the CI host's own
        # ExecStop unit does (templates/jenkins-provision.sh) -- covers a
        # GRACEFUL stop; the host's own unit covers an ungraceful one. Same
        # exact shape as iam.tf's drone_dns_update grant (reusing its named
        # locals, not duplicating the literals): one action, the zone ARN
        # (Route 53 has no record-level ARNs), conditioned to this one
        # record name, type A, UPSERT only.
        Effect   = "Allow"
        Action   = local.ci_dns_update_actions
        Resource = data.aws_route53_zone.ci.arn
        Condition = {
          "ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = local.ci_dns_update_record_names
            "route53:ChangeResourceRecordSetsRecordTypes"           = local.ci_dns_update_record_types
            "route53:ChangeResourceRecordSetsActions"               = local.ci_dns_update_actions_types
          }
        }
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
      JENKINS_BASE_URL       = "https://${local.ci_public_host}/jenkins"
      JENKINS_USER           = var.jenkins_admin_username
      JENKINS_PASSWORD_PARAM = aws_ssm_parameter.jenkins_admin_password.name
      IDLE_WINDOW_MINUTES    = tostring(var.ci_idle_window_minutes)
      CPU_BUSY_PERCENT       = tostring(var.ci_cpu_busy_percent)
      # Review round 1, finding 7: this was defined in variables.tf
      # (var.ci_post_start_grace_minutes) but never actually wired to the
      # Lambda that reads it -- lambda/ci_reaper/index.py's
      # POST_START_GRACE_MINUTES has a hardcoded "15" fallback, which meant
      # the variable silently did nothing.
      POST_START_GRACE_MINUTES = tostring(var.ci_post_start_grace_minutes)
      # T-048: don't stop the host for this long after the doorbell stamped a
      # push on it (Jenkins scans every 5 minutes; two scan periods of slack).
      PUSH_TAG           = local.ci_push_tag_key
      PUSH_GRACE_MINUTES = "10"
      # Review round 2, finding 2(a): the DNS sentinel UPSERT after stopping.
      CI_HOSTNAME     = local.ci_public_host
      ROUTE53_ZONE_ID = data.aws_route53_zone.ci.zone_id
      DNS_SENTINEL_IP = local.ci_dns_sentinel_ip
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
