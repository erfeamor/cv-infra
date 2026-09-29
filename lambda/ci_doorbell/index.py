"""Start the CI host when GitHub says something was pushed (T-019 ruling 3),
and, for erfeamor/cv-admin-react only, redeliver Drone's webhook once the
host is back up (T-034 H1 + H1 correction).

Reached through a Lambda Function URL with authorization_type = NONE, which is
not a shortcut: GitHub webhooks cannot produce SigV4, so the only authentication
available is the HMAC signature GitHub itself sends. Everything before a
sensitive call (start_instances, the GitHub hooks API) exists to make that
check unbypassable, because an unauthenticated endpoint that starts EC2
instances is a cost-denial-of-service tool against an account whose credits
are finite and on a deadline.

Order matters here. The signature is verified against the RAW body before the
JSON is parsed and before any AWS call is made, so an unsigned request costs
nothing but a log line.

--- T-034 H1 correction: why this is redelivery, not a forward -------------

Two constraints ruled out the simpler design (relay the payload straight to
Drone):

  1. GitHub kills a webhook delivery that doesn't answer within 10 seconds.
     Starting the box, waiting for Drone's own /healthz and talking to GitHub
     again can easily take minutes, so none of it can happen before this
     handler responds.
  2. Drone verifies each webhook against a secret only it and GitHub know. A
     doorbell-signed payload replayed to Drone fails that check -- forwarding
     cannot work regardless of timing.

So Drone keeps its own hook on cv-admin-react untouched, and a SECOND,
doorbell-signed hook is added there by hand (docs/runbooks/drone.md). This
handler has two entry points, dispatched on event shape:

  - An HTTP event (has "requestContext"): the webhook itself. For
    erfeamor/cv-admin-react it does nothing but verify the signature/allowlist
    and answer 202 at once -- see _handle_webhook. All the slow work is handed
    to a SECOND, asynchronous invocation of this SAME function
    (lambda:InvokeFunction, InvocationType="Event", scoped to its own ARN --
    see ci-on-demand.tf).
  - An async task event (no "requestContext", just {"repo", "wake_time"}):
    the self-invocation. It starts the instance if needed, waits (bounded) for
    Drone's own /healthz, then redelivers -- via GitHub's own redeliver API --
    only the Drone hook's deliveries that failed at or after (a slack window
    before) the wake time. Signatures stay intact end to end: nothing this
    handler sends to Drone is doorbell-signed; it never talks to Drone
    directly here, only to GitHub, which re-sends Drone's OWN previously
    -signed delivery.

--- Review round 1 finding 1, round 2 correction: the async task authenticates
its OWN event, because the IAM layer can't be narrowed here

The public `aws_lambda_permission` on this function (ci-on-demand.tf) grants
the plain, unconditioned `lambda:InvokeFunction` action to Principal = "*" --
deliberately, and it must stay that way: T-019 (bd65353) verified LIVE that
this account's Lambda block-public-access setting makes the narrower
`lambda:InvokeFunctionUrl` grant insufficient on its own (403, zero
invocations), so IAM cannot distinguish "arrived via the Function URL" from
"arrived via a direct Invoke API call" here. That means ANY AWS principal in
ANY account can invoke this function directly, with an arbitrary payload,
bypassing the Function URL entirely -- including one shaped like the async
task event (no "requestContext").

The fix is therefore in the payload, not the transport: `_handle_webhook`
signs {repo, wake_time} with the SAME webhook secret already used for
GitHub's own signature (see `_sign_async_task`), and `_handle_async_task`
verifies that signature with `hmac.compare_digest` BEFORE anything else --
before touching EC2, before touching SSM for the hooks token, before any
GitHub call. An attacker who can invoke this function directly still cannot
produce a valid signature without the webhook secret, so they get exactly as
far as an unsigned webhook POST would: a log line and nothing else.
`_validate_async_task` (the REDELIVER_REPOS allowlist, the wake_time window)
runs strictly AFTER the signature check, as a second, independent layer --
kept because it costs nothing and narrows the blast radius further even in a
world where the secret leaked.
"""

import base64
import datetime
import hashlib
import hmac
import http.client
import json
import logging
import os
import time
import urllib.error
import urllib.parse
import urllib.request

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")
lambda_client = boto3.client("lambda")

INSTANCE_ID = os.environ["INSTANCE_ID"]
SECRET_PARAM = os.environ["WEBHOOK_SECRET_PARAM"]
ALLOWED_REPOS = {r.strip() for r in os.environ.get("ALLOWED_REPOS", "").split(",") if r.strip()}

# T-034: repos that get the doorbell-signed hook + GitHub-redelivery path,
# instead of today's synchronous start. Per H1, this is cv-admin-react only --
# the Jenkins repos discover a cold-start push via periodicFolderTrigger
# (ruling 1) and have no per-repo secret a redelivery would even need to
# thread past. Also the async task's re-validated allowlist (see module
# docstring, review round 1 finding 1) -- not just the webhook entry point's.
REDELIVER_REPOS = {r.strip() for r in os.environ.get("REDELIVER_REPOS", "").split(",") if r.strip()}

GITHUB_HOOKS_TOKEN_PARAM = os.environ["GITHUB_HOOKS_TOKEN_PARAM"]
DRONE_HEALTHZ_URL = os.environ["DRONE_HEALTHZ_URL"]
HEALTHZ_TIMEOUT_SECONDS = int(os.environ.get("HEALTHZ_TIMEOUT_SECONDS", "480"))
HEALTHZ_POLL_INTERVAL_SECONDS = int(os.environ.get("HEALTHZ_POLL_INTERVAL_SECONDS", "15"))
SELF_FUNCTION_NAME = os.environ["SELF_FUNCTION_NAME"]

GITHUB_API = "https://api.github.com"
HTTP_TIMEOUT_SECONDS = 5

# Review round 1, finding 2: a delivery attempted slightly BEFORE the async
# task's own wake_time timestamp (clock skew between this Lambda and GitHub,
# or a delivery already in flight the instant the push landed) must not be
# treated as "before the wake" and skipped -- the window's start is pulled
# back by this much slack.
REDELIVERY_BACKWARD_SLACK_SECONDS = 300

# Finding 1: how old a self-invoked task's own wake_time may be before this
# function refuses to act on it. Matches the reaper's post-start grace
# (var.ci_post_start_grace_minutes) only by coincidence of round numbers, not
# by any shared meaning -- the two are unrelated constants.
WAKE_TIME_MAX_AGE_SECONDS = 900

# Finding 4: bounds on the GitHub work done after healthz succeeds, so a repo
# with an unusually large delivery backlog cannot run this invocation past its
# own timeout (see ci-on-demand.tf's timeout budget comment) or hammer GitHub
# indefinitely. Left-over failed deliveries beyond the cap are picked up by
# the next wake, or by the manual fallback (docs/runbooks/drone.md).
MAX_REDELIVERIES_PER_RUN = 20

# Finding 8: GitHub paginates at up to 100 items/page; this bounds how many
# pages this handler will ever follow for one hooks/deliveries list, so a
# malformed or malicious `Link` header cannot cause an unbounded loop.
MAX_LIST_PAGES = 10

# Finding 6: how long to wait for a `stopping` instance to actually reach
# `stopped` before giving up, rather than plunging into an 8-minute healthz
# wait against a host that may never come back up from this state.
INSTANCE_STOPPING_WAIT_TIMEOUT_SECONDS = 120
INSTANCE_STOPPING_POLL_INTERVAL_SECONDS = 10

# Cached across warm invocations: neither secret changes about never, and a
# GetParameter on every webhook/redelivery is a needless dependency on SSM
# being up.
_secret_cache = None
_hooks_token_cache = None


def _webhook_secret():
    global _secret_cache
    if _secret_cache is None:
        _secret_cache = ssm.get_parameter(Name=SECRET_PARAM, WithDecryption=True)["Parameter"]["Value"]
    return _secret_cache


def _canonical_async_task(repo, wake_time_iso):
    """The exact bytes _sign_async_task signs over. A fixed, simple format
    (not json.dumps) so signing and verifying can never disagree about key
    order or whitespace -- the classic way a "sign the dict" scheme quietly
    breaks."""
    return "%s|%s" % (repo, wake_time_iso)


def _sign_async_task(repo, wake_time_iso):
    """HMAC over (repo, wake_time), using the SAME secret GitHub's own webhook
    signature already relies on (_webhook_secret) -- no new secret to
    provision. This is round 2's fix for review round 1 finding 1: see the
    module docstring for why the IAM layer alone can't close this."""
    return hmac.new(
        _webhook_secret().encode("utf-8"),
        _canonical_async_task(repo, wake_time_iso).encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()


def _async_task_signature_ok(event):
    """True only if event carries a `sig` that verifies against event's OWN
    repo/wake_time. compare_digest, not ==, for the same timing reason as the
    webhook body check. Deliberately tolerant of missing/wrong-typed fields
    (returns False, never raises) -- a malformed forgery attempt is exactly
    as unauthenticated as a well-formed one."""
    repo = event.get("repo")
    wake_time_iso = event.get("wake_time")
    sig = event.get("sig")
    if not isinstance(sig, str) or not sig or repo is None or wake_time_iso is None:
        return False
    expected = _sign_async_task(repo, wake_time_iso)
    return hmac.compare_digest(sig, expected)


def _hooks_token():
    """The fine-grained PAT (Webhooks read/write on cv-admin-react only).

    Never logged on any path -- every place this value could reach a log
    line uses %r/%s on OTHER fields only. Cached exactly like the webhook
    secret, for the same reason.
    """
    global _hooks_token_cache
    if _hooks_token_cache is None:
        _hooks_token_cache = ssm.get_parameter(Name=GITHUB_HOOKS_TOKEN_PARAM, WithDecryption=True)["Parameter"]["Value"]
    return _hooks_token_cache


def _response(status, message):
    return {
        "statusCode": status,
        "headers": {"content-type": "text/plain"},
        "body": message,
    }


def _raw_body(event):
    """The bytes GitHub signed — not the decoded string.

    A Function URL sets isBase64Encoded per content type, and re-encoding a
    decoded string is not guaranteed to reproduce the original bytes for
    non-ASCII payloads. Commit messages contain non-ASCII regularly, so this
    is a real signature-mismatch source rather than a theoretical one.
    """
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        return base64.b64decode(body)
    return body.encode("utf-8")


def _self_invoke(payload):
    """Hand the slow work to a second, asynchronous invocation of THIS
    function. InvocationType="Event" is what makes this fire-and-forget:
    Lambda queues it and returns immediately, which is what lets the webhook
    entry point answer GitHub inside its 10-second budget."""
    lambda_client.invoke(
        FunctionName=SELF_FUNCTION_NAME,
        InvocationType="Event",
        Payload=json.dumps(payload).encode("utf-8"),
    )


def _drone_healthz_ok(url):
    try:
        with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT_SECONDS) as response:
            return response.status == 200
    except (urllib.error.URLError, urllib.error.HTTPError, ValueError, TimeoutError, OSError, http.client.HTTPException):
        # Finding 9: OSError covers connection-level failures urllib doesn't
        # always wrap in URLError (e.g. a bare ConnectionResetError bubbling
        # from the socket layer), and HTTPException covers a malformed
        # response from a half-started Drone. Both must read as "not ready
        # yet", exactly like every other failure mode here -- never as a
        # crash that aborts the whole wait.
        return False


def wait_for_drone_healthz(url, timeout_seconds, poll_interval_seconds, check_fn=None, sleep_fn=None, clock_fn=None):
    """Poll url until it answers 200, or give up after timeout_seconds.

    check_fn/sleep_fn/clock_fn default to the real thing but are injectable so
    tests never sleep for real minutes to exercise the timeout path.

    The three are resolved to time.sleep/time.monotonic HERE, inside the
    function body, rather than as `sleep_fn=time.sleep` in the signature: a
    default parameter value is bound ONCE, at def time, to whatever object
    `time.sleep` was at that moment -- a test that later does
    `mock.patch.object(module.time, "sleep", ...)` changes the `time`
    module's attribute, but a caller relying on this function's OWN default
    (as the real _handle_async_task path does) would still get the
    already-captured original, real time.sleep, and hang for real minutes.
    Resolving here, on every call, reads the `time` module's CURRENT
    attribute instead.
    """
    check_fn = check_fn or _drone_healthz_ok
    sleep_fn = sleep_fn or time.sleep
    clock_fn = clock_fn or time.monotonic
    deadline = clock_fn() + timeout_seconds
    while True:
        if check_fn(url):
            return True
        if clock_fn() >= deadline:
            return False
        sleep_fn(poll_interval_seconds)


def _quote_repo(repo):
    """repo is attacker-influenced (it comes from the async task's own event,
    which review round 1 finding 1 already restricts to REDELIVER_REPOS, but
    finding 1(c) asks for this independently): never interpolate it into a
    URL path unescaped. safe="/" keeps the owner/repo separator readable."""
    return urllib.parse.quote(repo, safe="/")


def _next_link(link_header):
    """The RFC 5988 `Link` header's rel="next" URL, or None on the last page.

    GitHub's pagination is entirely driven by this header; the `page` query
    parameter is not guaranteed stable across API versions, so this parses
    the header rather than incrementing a counter.
    """
    if not link_header:
        return None
    for part in link_header.split(","):
        segments = part.split(";")
        url_part = segments[0].strip()
        if not (url_part.startswith("<") and url_part.endswith(">")):
            continue
        if any(segment.strip() == 'rel="next"' for segment in segments[1:]):
            return url_part[1:-1]
    return None


def _github_list(path, token, stop_predicate=None):
    """GET path and every subsequent page (Link: rel="next"), up to
    MAX_LIST_PAGES. stop_predicate(item), if given, is checked against every
    item on each page; the FIRST page containing a match is still included in
    full, but no further page is fetched -- the caller filters precisely
    afterwards. Used for both the hooks list and the deliveries list (finding
    8); the deliveries list is newest-first, so a stop_predicate that means
    "this item predates the window" makes this stop as soon as it's true.
    """
    items = []
    url = GITHUB_API + path
    for _ in range(MAX_LIST_PAGES):
        if not url:
            break
        request = urllib.request.Request(url, method="GET")
        request.add_header("Authorization", "Bearer " + token)
        request.add_header("Accept", "application/vnd.github+json")
        request.add_header("X-GitHub-Api-Version", "2022-11-28")
        request.add_header("User-Agent", "cv-project-ci-doorbell")
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            raw = response.read()
            page_items = json.loads(raw) if raw else []
            items.extend(page_items)
            if stop_predicate and any(stop_predicate(item) for item in page_items):
                break
            url = _next_link(response.headers.get("Link"))
    return items


def _github_request(method, path, token, body=None):
    """A single-shot GitHub API call (no pagination) -- used for the
    redelivery POST, which returns no list to page through."""
    url = GITHUB_API + path
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", "Bearer " + token)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("X-GitHub-Api-Version", "2022-11-28")
    request.add_header("User-Agent", "cv-project-ci-doorbell")
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
        raw = response.read()
        return json.loads(raw) if raw else None


def find_drone_hook_id(repo, token):
    """Drone's own hook on repo, identified by config.url ending in "/hook"
    (its webhook path -- see templates/jenkins-provision.sh's nginx config).
    The doorbell-signed hook added per docs/runbooks/drone.md points at the
    Function URL instead, so this never picks that one up by accident."""
    hooks = _github_list("/repos/%s/hooks?per_page=100" % _quote_repo(repo), token)
    for hook in hooks:
        url = (hook.get("config") or {}).get("url", "")
        if url.endswith("/hook"):
            return hook.get("id")
    log.error(
        "no Drone hook found on %s (looked for a hook whose config.url ends in /hook); "
        "redelivery skipped -- see docs/runbooks/drone.md for manual redelivery",
        repo,
    )
    return None


def _parse_delivered_at(raw):
    if not raw:
        return None
    try:
        return datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def _is_success(status_code):
    return status_code is not None and 200 <= status_code < 300


def redeliver_failed_deliveries(repo, wake_time_iso):
    """Redeliver, via GitHub's own API, only Drone hook deliveries that are
    still failing as of the wake -- a delivery that failed hours ago while the
    box was legitimately stopped is not this handler's business, and a
    delivery GitHub (or an earlier redelivery) already got a 2xx for must not
    be sent again.

    Grouped by `guid`, not `id` (review round 1 finding 3): GitHub gives every
    delivery ATTEMPT -- including each redelivery -- its own `id`, but every
    attempt of the SAME original event shares one `guid`. Deduplicating by
    `id` alone would happily redeliver a guid that already succeeded on a
    later attempt than the failed one this handler happened to see first.
    """
    token = _hooks_token()
    hook_id = find_drone_hook_id(repo, token)
    if hook_id is None:
        return 0

    quoted_repo = _quote_repo(repo)
    wake_time = datetime.datetime.fromisoformat(wake_time_iso)
    window_start = wake_time - datetime.timedelta(seconds=REDELIVERY_BACKWARD_SLACK_SECONDS)

    def predates_window(delivery):
        when = _parse_delivered_at(delivery.get("delivered_at"))
        return when is not None and when < window_start

    deliveries = _github_list(
        "/repos/%s/hooks/%s/deliveries?per_page=100" % (quoted_repo, hook_id),
        token,
        stop_predicate=predates_window,
    )

    in_window = []
    for delivery in deliveries:
        when = _parse_delivered_at(delivery.get("delivered_at"))
        if when is not None and when >= window_start:
            in_window.append((when, delivery))

    succeeded_guids = {d.get("guid") for _, d in in_window if _is_success(d.get("status_code"))}

    latest_failed_by_guid = {}
    for when, delivery in in_window:
        guid = delivery.get("guid")
        if guid is None or guid in succeeded_guids or _is_success(delivery.get("status_code")):
            continue
        existing = latest_failed_by_guid.get(guid)
        if existing is None or when > existing[0]:
            latest_failed_by_guid[guid] = (when, delivery)

    redelivered = 0
    for guid, (_when, delivery) in latest_failed_by_guid.items():
        if redelivered >= MAX_REDELIVERIES_PER_RUN:
            log.warning(
                "hit MAX_REDELIVERIES_PER_RUN (%d) for %s; remaining failed deliveries are left for the next wake "
                "or manual redelivery (docs/runbooks/drone.md)",
                MAX_REDELIVERIES_PER_RUN,
                repo,
            )
            break
        delivery_id = delivery.get("id")
        if delivery_id is None:
            continue
        try:
            _github_request(
                "POST",
                "/repos/%s/hooks/%s/deliveries/%s/attempts" % (quoted_repo, hook_id, urllib.parse.quote(str(delivery_id), safe="")),
                token,
            )
            redelivered += 1
        except (urllib.error.URLError, urllib.error.HTTPError) as exc:
            # Finding 4: one failed redelivery POST must not stop the rest --
            # a transient GitHub error on guid A has nothing to do with guid B.
            log.warning("redelivery POST failed for guid=%s delivery_id=%s: %s", guid, delivery_id, exc)

    log.info(
        "redelivered %d/%d still-failing Drone webhook deliveries for %s since %s (-%ds slack)",
        redelivered,
        len(latest_failed_by_guid),
        repo,
        wake_time_iso,
        REDELIVERY_BACKWARD_SLACK_SECONDS,
    )
    return redelivered


def _describe_instance_state():
    try:
        return ec2.describe_instances(InstanceIds=[INSTANCE_ID])["Reservations"][0]["Instances"][0]["State"]["Name"]
    except (ClientError, IndexError, KeyError):
        log.exception("could not read instance state")
        return None


def _start_instance_if_stopped(repo):
    """The pre-T-034 synchronous behaviour, unchanged: still used directly by
    the Jenkins-repo webhook path. NOT used by the async task any more --
    see _handle_async_task, which additionally waits out a `stopping` state
    (finding 6) before deciding whether to start."""
    state = _describe_instance_state()
    if state is None:
        return None

    if state == "running":
        log.info("%s already running for %s; nothing to do", INSTANCE_ID, repo)
        return state

    if state != "stopped":
        # 'stopping' is the interesting one: StartInstances fails against it, and
        # the reaper is mid-shutdown. Report it rather than retrying in-process —
        # the next push wakes the box, and Jenkins' periodic scan (ruling 1) will
        # pick up whatever was missed, which is the whole point of that design.
        log.info("%s in transitional state %s; not starting", INSTANCE_ID, state)
        return state

    ec2.start_instances(InstanceIds=[INSTANCE_ID])
    log.info("started %s on push to %s", INSTANCE_ID, repo)
    return state


def _wait_for_instance_stopped(
    timeout_seconds=INSTANCE_STOPPING_WAIT_TIMEOUT_SECONDS,
    poll_interval_seconds=INSTANCE_STOPPING_POLL_INTERVAL_SECONDS,
    sleep_fn=None,
    clock_fn=None,
):
    """Bounded wait for a `stopping` instance to reach `stopped`. Returns the
    LAST observed state (which may still be "stopping" on timeout, or None if
    a describe call failed) -- never raises, and never waits the full 8-minute
    healthz budget against a host that may never finish stopping.

    sleep_fn/clock_fn resolved here rather than as signature defaults -- see
    wait_for_drone_healthz's docstring for why that distinction matters.
    """
    sleep_fn = sleep_fn or time.sleep
    clock_fn = clock_fn or time.monotonic
    deadline = clock_fn() + timeout_seconds
    while True:
        state = _describe_instance_state()
        if state != "stopping":
            return state
        if clock_fn() >= deadline:
            return state
        sleep_fn(poll_interval_seconds)


def _validate_async_task(event):
    """Defense in depth against direct invocation (module docstring, finding
    1): independently re-check what _handle_webhook already checked before
    scheduling this task. Returns (repo, wake_time_iso) or None."""
    repo = event.get("repo")
    if repo not in REDELIVER_REPOS:
        log.error("async task rejected: repo %r is not in REDELIVER_REPOS", repo)
        return None

    wake_time_iso = event.get("wake_time")
    try:
        wake_time = datetime.datetime.fromisoformat(wake_time_iso)
    except (TypeError, ValueError):
        log.error("async task rejected: wake_time %r does not parse as ISO-8601", wake_time_iso)
        return None

    now = datetime.datetime.now(datetime.timezone.utc)
    earliest = now - datetime.timedelta(seconds=WAKE_TIME_MAX_AGE_SECONDS)
    if not (earliest <= wake_time <= now):
        log.error(
            "async task rejected: wake_time %s is outside [now-%ds, now] (now=%s)",
            wake_time_iso,
            WAKE_TIME_MAX_AGE_SECONDS,
            now.isoformat(),
        )
        return None

    return repo, wake_time_iso


def _handle_async_task(event):
    """The self-invoked half of the T-034 redeliver path. The public
    aws_lambda_permission on this function is deliberately unconditioned
    (ci-on-demand.tf), so this event may have arrived via a direct
    lambda:InvokeFunction call from any AWS principal, not only via
    _self_invoke -- see the module docstring for why. Signature verification
    MUST run before anything else: before EC2, before SSM, before any GitHub
    call. _validate_async_task runs only after a valid signature, as a second,
    independent layer."""
    if not _async_task_signature_ok(event):
        log.warning("async task rejected: missing or invalid signature")
        return {"ok": False, "reason": "bad signature"}

    validated = _validate_async_task(event)
    if validated is None:
        return {"ok": False, "reason": "invalid task event"}
    repo, wake_time_iso = validated

    log.info("async wake+redeliver task starting for %s (wake_time=%s)", repo, wake_time_iso)

    state = _describe_instance_state()
    if state is None:
        return {"ok": False, "reason": "describe failed"}

    if state == "stopping":
        # Finding 6: never plunge into an 8-minute healthz wait against a host
        # that is mid-shutdown and may not come back up as "stopped" in time.
        state = _wait_for_instance_stopped()
        if state != "stopped":
            log.error(
                "instance still %s after waiting up to %ds for it to stop; giving up rather than waiting "
                "%ds for healthz against a host that may never come up",
                state,
                INSTANCE_STOPPING_WAIT_TIMEOUT_SECONDS,
                HEALTHZ_TIMEOUT_SECONDS,
            )
            return {"ok": False, "reason": "stuck stopping"}

    if state == "stopped":
        ec2.start_instances(InstanceIds=[INSTANCE_ID])
        log.info("started %s for async wake+redeliver of %s", INSTANCE_ID, repo)
    elif state != "running":
        log.error("instance in unexpected state %s; not starting", state)
        return {"ok": False, "reason": "unexpected state %s" % state}

    if not wait_for_drone_healthz(DRONE_HEALTHZ_URL, HEALTHZ_TIMEOUT_SECONDS, HEALTHZ_POLL_INTERVAL_SECONDS):
        log.error(
            "Drone healthz did not return 200 within %ds of waking %s for %s; "
            "skipping redelivery -- see docs/runbooks/drone.md for the manual fallback",
            HEALTHZ_TIMEOUT_SECONDS,
            INSTANCE_ID,
            repo,
        )
        return {"ok": False, "reason": "healthz timeout"}

    redeliver_failed_deliveries(repo, wake_time_iso)
    return {"ok": True}


def _handle_webhook(event):
    http_ctx = event.get("requestContext", {}).get("http", {})
    method = http_ctx.get("method", "")
    if method != "POST":
        log.warning("rejected: method %s", method)
        return _response(405, "method not allowed")

    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    signature = headers.get("x-hub-signature-256", "")
    raw = _raw_body(event)

    expected = "sha256=" + hmac.new(_webhook_secret().encode("utf-8"), raw, hashlib.sha256).hexdigest()
    # compare_digest, not ==, so a wrong signature cannot be recovered byte by
    # byte from response timing.
    if not hmac.compare_digest(signature, expected):
        log.warning("rejected: bad or missing signature")
        return _response(401, "bad signature")

    event_type = headers.get("x-github-event", "")
    if event_type == "ping":
        # GitHub sends this when the hook is created. Answering it is what makes
        # the green tick appear in the webhook UI; it must not start the box.
        return _response(200, "pong")

    try:
        payload = json.loads(raw)
    except ValueError:
        return _response(400, "malformed json")

    repo = (payload.get("repository") or {}).get("full_name")
    if repo not in ALLOWED_REPOS:
        # A valid signature proves the sender holds the secret, not that this
        # repo is one we run CI for. Both checks, not either.
        log.warning("rejected: repository %s not in allowlist", repo)
        return _response(403, "repository not allowed")

    if repo in REDELIVER_REPOS:
        # T-034: answer at once (GitHub's 10s budget), do nothing else here.
        # Everything slow -- starting the box, waiting for Drone, redelivering
        # -- happens in the async self-invocation, which authenticates its own
        # event with `sig` (see module docstring, finding 1 round 2) and then
        # re-validates repo/wake_time independently as a second layer.
        wake_time_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()
        sig = _sign_async_task(repo, wake_time_iso)
        _self_invoke({"repo": repo, "wake_time": wake_time_iso, "sig": sig})
        log.info("scheduled async wake+redeliver for %s (wake_time=%s)", repo, wake_time_iso)
        return _response(202, "accepted")

    state = _start_instance_if_stopped(repo)
    if state is None:
        return _response(500, "could not read instance state")
    if state == "running":
        return _response(200, "already running")
    if state != "stopped":
        return _response(202, "instance is %s, not started" % state)
    return _response(200, "starting")


def handler(event, context):
    if "requestContext" not in event:
        return _handle_async_task(event)
    return _handle_webhook(event)
