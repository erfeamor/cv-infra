"""Stop the CI host once it has genuinely gone quiet (T-019 ruling 2).

Runs on an EventBridge schedule. The hard requirement is the one T-019 states:
never kill a build in progress. Everything below is arranged so that any
uncertainty resolves to "leave it running" — an instance left up costs about
$0.024/hour, a killed release build costs someone's afternoon.

Two independent signals must agree before the instance is stopped:

  1. Jenkins says so, authoritatively — nothing queued and no executor busy.
     Unreachable Jenkins counts as BUSY, which is what keeps the reaper from
     stopping a box that is still booting.

  2. CloudWatch says CPU has been quiet for the whole idle window. This is the
     Drone half of ruling 2, and it is a deliberate substitution: Drone's API
     needs a user token that exists ONLY inside /var/lib/drone/database.sqlite
     (T-008 established this — the credentials are not in SSM, not in Terraform
     state, not reconstructable), so there is no way to ask Drone directly from
     a Lambda. A running Drone pipeline burns CPU, so the window covers it.

CPU is a VETO, never the sole signal — the failure mode ruling 2 rejected was
inferring idleness FROM CPU, which kills a build that is waiting on a download.
Here a low-CPU build is still protected by signal 1.

T-034 finding 2026-09-27 added a THIRD, unconditional check ahead of both: a
post-start grace period. A single post-boot CloudWatch datapoint (low boot
CPU, before anything has actually started building) was observed satisfying
signal 2 within seconds of a cold start, stopping the box while a just-queued
Drone build sat at "pending" with nowhere to run. No amount of tuning signals
1/2 fixes that — the box must simply be left alone for a while after every
start, full stop, before either signal is trusted at all. Deliberately NOT a
Drone busy check: T-034 H1 settled on CPU alone covering Drone's builds,
deferring an actual Drone-queue signal (same SQLite-token limitation as
above).
"""

import datetime
import json
import logging
import os
import urllib.error
import urllib.request

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")
cloudwatch = boto3.client("cloudwatch")
route53 = boto3.client("route53")

INSTANCE_ID = os.environ["INSTANCE_ID"]
JENKINS_BASE_URL = os.environ["JENKINS_BASE_URL"].rstrip("/")
JENKINS_USER = os.environ["JENKINS_USER"]
JENKINS_PASSWORD_PARAM = os.environ["JENKINS_PASSWORD_PARAM"]
IDLE_WINDOW_MINUTES = int(os.environ.get("IDLE_WINDOW_MINUTES", "20"))

# Review round 2, finding 2(a): the DNS-update grant (iam.tf's
# drone_dns_update, mirrored here for this role) needs both to build the
# same UPSERT this reaper makes.
CI_HOSTNAME = os.environ["CI_HOSTNAME"]
ROUTE53_ZONE_ID = os.environ["ROUTE53_ZONE_ID"]
# TEST-NET-1 (RFC 5737): guaranteed to never route anywhere real, so once
# the record says this, nothing (GitHub, a stale client, a scanner) can
# reach whatever AWS reassigns this stopped instance's old public IP to.
DNS_SENTINEL_IP = os.environ.get("DNS_SENTINEL_IP", "192.0.2.1")
CPU_BUSY_PERCENT = float(os.environ.get("CPU_BUSY_PERCENT", "10"))
KEEPALIVE_TAG = os.environ.get("KEEPALIVE_TAG", "CIKeepAlive")
POST_START_GRACE_MINUTES = int(os.environ.get("POST_START_GRACE_MINUTES", "15"))
# T-048: the doorbell stamps this tag when a push lands on an already-running
# host; Jenkins only finds it on its next 5-minute scan, so the host must not be
# stopped until PUSH_GRACE_MINUTES have passed.
PUSH_TAG = os.environ.get("PUSH_TAG", "CILastPush")
PUSH_GRACE_MINUTES = int(os.environ.get("PUSH_GRACE_MINUTES", "10"))
HTTP_TIMEOUT_SECONDS = 5

_password_cache = None


def _jenkins_password():
    global _password_cache
    if _password_cache is None:
        _password_cache = ssm.get_parameter(Name=JENKINS_PASSWORD_PARAM, WithDecryption=True)["Parameter"]["Value"]
    return _password_cache


def _jenkins_get(path):
    request = urllib.request.Request(JENKINS_BASE_URL + path)
    credentials = "%s:%s" % (JENKINS_USER, _jenkins_password())
    import base64

    request.add_header("Authorization", "Basic " + base64.b64encode(credentials.encode()).decode())
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
        return json.loads(response.read())


def jenkins_is_idle():
    """True only if Jenkins answers AND reports nothing running.

    Any failure to get a clear answer returns False (= busy). Jenkins takes a
    while to come up after a cold start, and during that window it refuses
    connections — reading that as 'idle' would stop the box moments after the
    doorbell started it, which is the most obvious way to build an automation
    that looks exactly like broken CI.
    """
    try:
        queue = _jenkins_get("/queue/api/json?tree=items[id]")
        if queue.get("items"):
            log.info("busy: %d item(s) queued", len(queue["items"]))
            return False
        computer = _jenkins_get("/computer/api/json?tree=busyExecutors")
        busy = computer.get("busyExecutors", 0)
        if busy:
            log.info("busy: %d executor(s) running", busy)
            return False
        return True
    except (urllib.error.URLError, urllib.error.HTTPError, ValueError, TimeoutError) as exc:
        log.info("treating as BUSY — Jenkins did not answer cleanly: %s", exc)
        return False


def cpu_quiet_over_window():
    """True if CPU stayed below the threshold for the whole idle window.

    Uses Maximum, not Average: a five-minute average smooths a burst of real
    work into something that looks idle.
    """
    end = datetime.datetime.now(datetime.timezone.utc)
    start = end - datetime.timedelta(minutes=IDLE_WINDOW_MINUTES)
    stats = cloudwatch.get_metric_statistics(
        Namespace="AWS/EC2",
        MetricName="CPUUtilization",
        Dimensions=[{"Name": "InstanceId", "Value": INSTANCE_ID}],
        StartTime=start,
        EndTime=end,
        Period=300,
        Statistics=["Maximum"],
    )
    points = stats.get("Datapoints", [])
    if not points:
        # No datapoints means the instance has not been up long enough to report
        # a full period. Too new to judge — leave it alone.
        log.info("no CPU datapoints yet; treating as busy")
        return False
    peak = max(p["Maximum"] for p in points)
    if peak >= CPU_BUSY_PERCENT:
        log.info("busy: CPU peaked at %.1f%% over %d min", peak, IDLE_WINDOW_MINUTES)
        return False
    log.info("cpu quiet: peak %.1f%% over %d min across %d datapoints", peak, IDLE_WINDOW_MINUTES, len(points))
    return True


def within_post_start_grace(launch_time, grace_minutes, now=None):
    """True while the instance is still within grace_minutes of its own
    LaunchTime. now is injectable so tests never depend on wall-clock time."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    return now < launch_time + datetime.timedelta(minutes=grace_minutes)


def within_push_grace(last_push, grace_minutes, now=None):
    """True while now is within grace_minutes after last_push (a datetime).
    A timestamp in the future never counts, so a bad clock or hand-edited
    tag cannot hold the host up forever. now is injectable for tests."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    return last_push <= now < last_push + datetime.timedelta(minutes=grace_minutes)


def _parse_push_tag(raw):
    """The tag's datetime, or None (with a warning) if it is malformed."""
    try:
        return datetime.datetime.strptime(raw, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except (TypeError, ValueError):
        log.warning("ignoring malformed %s tag value %r", PUSH_TAG, raw)
        return None


def _upsert_dns_sentinel():
    """Best-effort: right after stopping the instance, UPSERT CI_HOSTNAME to
    DNS_SENTINEL_IP (review round 2, finding 2(a)). This covers a GRACEFUL
    stop (this call, from here); the instance's OWN ExecStop systemd unit
    (templates/jenkins-provision.sh) covers an UNGRACEFUL one (a manual
    `ec2 stop-instances`, a crash) that never reaches this Lambda at all --
    neither alone covers both cases, so both exist.

    Never raises: the instance is already stopped/stopping regardless of
    whether this succeeds, and a failed sentinel write must not read as the
    REAPER having failed -- the boot-time updater's next start (or this
    same call, next time the reaper runs) still gets another chance.
    """
    try:
        route53.change_resource_record_sets(
            HostedZoneId=ROUTE53_ZONE_ID,
            ChangeBatch={
                "Changes": [
                    {
                        "Action": "UPSERT",
                        "ResourceRecordSet": {
                            "Name": CI_HOSTNAME,
                            "Type": "A",
                            "TTL": 60,
                            "ResourceRecords": [{"Value": DNS_SENTINEL_IP}],
                        },
                    }
                ]
            },
        )
        log.info("UPSERTed %s -> sentinel %s after stopping %s", CI_HOSTNAME, DNS_SENTINEL_IP, INSTANCE_ID)
    except ClientError:
        log.exception("could not UPSERT the DNS sentinel for %s after stopping %s (best-effort, not treated as a reaper failure)", CI_HOSTNAME, INSTANCE_ID)


def handler(event, context):
    try:
        instance = ec2.describe_instances(InstanceIds=[INSTANCE_ID])["Reservations"][0]["Instances"][0]
    except (ClientError, IndexError, KeyError):
        log.exception("could not read instance state")
        return {"stopped": False, "reason": "describe failed"}

    state = instance["State"]["Name"]
    if state != "running":
        log.info("nothing to do; instance is %s", state)
        return {"stopped": False, "reason": "not running"}

    tags = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}
    if tags.get(KEEPALIVE_TAG, "").lower() == "true":
        # The manual override T-019 asks for: someone is being walked through CI
        # and the box must stay up. A tag rather than a config change, so it can
        # be set and cleared from the console in seconds without an apply.
        log.info("%s=true; leaving instance running", KEEPALIVE_TAG)
        return {"stopped": False, "reason": "keepalive tag set"}

    if within_post_start_grace(instance["LaunchTime"], POST_START_GRACE_MINUTES):
        # T-034: unconditional, ahead of both other signals -- see the module
        # docstring. A boot-time CPU datapoint must never count as "idle".
        log.info("within %d-minute post-start grace; leaving instance running", POST_START_GRACE_MINUTES)
        return {"stopped": False, "reason": "post-start grace"}

    if PUSH_TAG in tags:
        last_push = _parse_push_tag(tags[PUSH_TAG])
        if last_push is not None and within_push_grace(last_push, PUSH_GRACE_MINUTES):
            # T-048: a push reached the doorbell while the host was already up;
            # Jenkins finds it on its next scan, which may not have run yet.
            log.info(
                "within %d-minute push grace (last push %s); leaving instance running",
                PUSH_GRACE_MINUTES,
                tags[PUSH_TAG],
            )
            return {"stopped": False, "reason": "push grace"}

    if not cpu_quiet_over_window():
        return {"stopped": False, "reason": "cpu busy"}

    if not jenkins_is_idle():
        return {"stopped": False, "reason": "jenkins busy"}

    # Ruling 2's re-check. The signals above were read seconds ago, and a push
    # landing in that gap would have queued a build. Cheap insurance against
    # stopping the box in the one moment it started mattering again.
    if not jenkins_is_idle():
        log.info("work arrived during the check; leaving instance running")
        return {"stopped": False, "reason": "became busy during check"}

    ec2.stop_instances(InstanceIds=[INSTANCE_ID])
    log.info("stopped %s after %d idle minutes", INSTANCE_ID, IDLE_WINDOW_MINUTES)
    _upsert_dns_sentinel()
    return {"stopped": True, "reason": "idle"}
