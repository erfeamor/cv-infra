"""Start the CI host when GitHub says something was pushed (T-019 ruling 3).

Reached through a Lambda Function URL with authorization_type = NONE, which is
not a shortcut: GitHub webhooks cannot produce SigV4, so the only authentication
available is the HMAC signature GitHub itself sends. Everything in this handler
before start_instances() exists to make that check unbypassable, because an
unauthenticated endpoint that starts EC2 instances is a cost-denial-of-service
tool against an account whose credits are finite and on a deadline.

Order matters here. The signature is verified against the RAW body before the
JSON is parsed and before any AWS call is made, so an unsigned request costs
nothing but a log line.
"""

import base64
import hashlib
import hmac
import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")

INSTANCE_ID = os.environ["INSTANCE_ID"]
SECRET_PARAM = os.environ["WEBHOOK_SECRET_PARAM"]
ALLOWED_REPOS = {r.strip() for r in os.environ.get("ALLOWED_REPOS", "").split(",") if r.strip()}

# Cached across warm invocations: the secret changes about never, and a
# GetParameter on every webhook is a needless dependency on SSM being up.
_secret_cache = None


def _webhook_secret():
    global _secret_cache
    if _secret_cache is None:
        _secret_cache = ssm.get_parameter(Name=SECRET_PARAM, WithDecryption=True)["Parameter"]["Value"]
    return _secret_cache


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


def handler(event, context):
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

    try:
        state = ec2.describe_instances(InstanceIds=[INSTANCE_ID])["Reservations"][0]["Instances"][0]["State"]["Name"]
    except (ClientError, IndexError, KeyError):
        log.exception("could not read instance state")
        return _response(500, "could not read instance state")

    if state == "running":
        log.info("%s already running for %s; nothing to do", INSTANCE_ID, repo)
        return _response(200, "already running")

    if state != "stopped":
        # 'stopping' is the interesting one: StartInstances fails against it, and
        # the reaper is mid-shutdown. Report it rather than retrying in-process —
        # the next push wakes the box, and Jenkins' periodic scan (ruling 1) will
        # pick up whatever was missed, which is the whole point of that design.
        log.info("%s in transitional state %s; not starting", INSTANCE_ID, state)
        return _response(202, "instance is %s, not started" % state)

    ec2.start_instances(InstanceIds=[INSTANCE_ID])
    log.info("started %s on push to %s", INSTANCE_ID, repo)
    return _response(200, "starting")
