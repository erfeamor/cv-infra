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
    see ci-on-demand.tf). Self-invoking was chosen over a second Lambda: one
    deployment artifact, one IAM role, one log group, and the only new grant
    needed is a single Resource-scoped lambda:InvokeFunction on this
    function's own ARN -- narrower than the blast radius of standing up and
    wiring a whole second function for a path this small. The Jenkins repos
    are unaffected; they keep ruling 1's synchronous start/no-op/transitional
    response exactly as before.
  - An async task event (no "requestContext", just {"repo", "wake_time"}):
    the self-invocation. It starts the instance if needed, waits (bounded) for
    Drone's own /healthz, then redelivers -- via GitHub's own redeliver API --
    only the Drone hook's deliveries that failed at or after the wake time.
    Signatures stay intact end to end: nothing this handler sends to Drone is
    doorbell-signed: it never talks to Drone directly at all here, only to
    GitHub, which re-sends Drone's OWN previously-signed delivery.
"""

import base64
import datetime
import hashlib
import hmac
import json
import logging
import os
import time
import urllib.error
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
# thread past.
REDELIVER_REPOS = {r.strip() for r in os.environ.get("REDELIVER_REPOS", "").split(",") if r.strip()}

GITHUB_HOOKS_TOKEN_PARAM = os.environ["GITHUB_HOOKS_TOKEN_PARAM"]
DRONE_HEALTHZ_URL = os.environ["DRONE_HEALTHZ_URL"]
HEALTHZ_TIMEOUT_SECONDS = int(os.environ.get("HEALTHZ_TIMEOUT_SECONDS", "480"))
HEALTHZ_POLL_INTERVAL_SECONDS = int(os.environ.get("HEALTHZ_POLL_INTERVAL_SECONDS", "15"))
SELF_FUNCTION_NAME = os.environ["SELF_FUNCTION_NAME"]

GITHUB_API = "https://api.github.com"
HTTP_TIMEOUT_SECONDS = 5

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
    except (urllib.error.URLError, urllib.error.HTTPError, ValueError, TimeoutError):
        return False


def wait_for_drone_healthz(url, timeout_seconds, poll_interval_seconds, check_fn=None, sleep_fn=time.sleep, clock_fn=time.monotonic):
    """Poll url until it answers 200, or give up after timeout_seconds.

    check_fn/sleep_fn/clock_fn default to the real thing but are injectable so
    tests never sleep for real minutes to exercise the timeout path.
    """
    check_fn = check_fn or _drone_healthz_ok
    deadline = clock_fn() + timeout_seconds
    while True:
        if check_fn(url):
            return True
        if clock_fn() >= deadline:
            return False
        sleep_fn(poll_interval_seconds)


def _github_request(method, path, token, body=None):
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
    hooks = _github_request("GET", "/repos/%s/hooks" % repo, token) or []
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


def redeliver_failed_deliveries(repo, wake_time_iso):
    """Redeliver, via GitHub's own API, only Drone hook deliveries that both
    failed AND were attempted at or after the wake time -- a delivery that
    failed hours ago while the box was legitimately stopped is not this
    handler's business, and a delivery GitHub already retried successfully on
    its own must not be sent twice."""
    token = _hooks_token()
    hook_id = find_drone_hook_id(repo, token)
    if hook_id is None:
        return 0

    wake_time = datetime.datetime.fromisoformat(wake_time_iso)
    deliveries = _github_request("GET", "/repos/%s/hooks/%s/deliveries" % (repo, hook_id), token) or []

    seen_ids = set()
    redelivered = 0
    for delivery in deliveries:
        delivery_id = delivery.get("id")
        if delivery_id is None or delivery_id in seen_ids:
            # Idempotency guard: GitHub's delivery list should not contain the
            # same id twice, but nothing about this handler's correctness
            # should depend on that holding -- a duplicate must never become a
            # second POST.
            continue
        seen_ids.add(delivery_id)

        delivered_at = (delivery.get("delivered_at") or "").replace("Z", "+00:00")
        try:
            when = datetime.datetime.fromisoformat(delivered_at)
        except ValueError:
            continue
        if when < wake_time:
            continue

        status_code = delivery.get("status_code")
        if status_code is not None and 200 <= status_code < 300:
            continue  # GitHub already delivered this one successfully

        _github_request("POST", "/repos/%s/hooks/%s/deliveries/%s/attempts" % (repo, hook_id, delivery_id), token)
        redelivered += 1

    log.info("redelivered %d failed Drone webhook deliveries for %s since %s", redelivered, repo, wake_time_iso)
    return redelivered


def _start_instance_if_stopped(repo):
    """The pre-T-034 synchronous behaviour, unchanged: still used directly by
    the Jenkins-repo webhook path, and by the async task for cv-admin-react."""
    try:
        state = ec2.describe_instances(InstanceIds=[INSTANCE_ID])["Reservations"][0]["Instances"][0]["State"]["Name"]
    except (ClientError, IndexError, KeyError):
        log.exception("could not read instance state")
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


def _handle_async_task(event):
    """The self-invoked half of the T-034 redeliver path. Never reachable
    from the Function URL: it has no "requestContext" and this handler is
    only ever invoked this way by _self_invoke, whose Lambda permission is
    scoped to this function's own ARN."""
    repo = event.get("repo")
    wake_time_iso = event.get("wake_time")
    log.info("async wake+redeliver task starting for %s (wake_time=%s)", repo, wake_time_iso)

    state = _start_instance_if_stopped(repo)
    if state is None:
        return {"ok": False, "reason": "describe failed"}

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
    http = event.get("requestContext", {}).get("http", {})
    method = http.get("method", "")
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
        # -- happens in the async self-invocation.
        wake_time_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()
        _self_invoke({"repo": repo, "wake_time": wake_time_iso})
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
