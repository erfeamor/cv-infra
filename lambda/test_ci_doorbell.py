"""Offline unit tests for lambda/ci_doorbell/index.py (T-019, T-034).

Run with: python3 -m unittest discover -s lambda -p 'test_*.py'
(also invoked directly by this file's __main__ block).

No AWS credentials, no network: boto3/botocore are stubbed (testsupport.py)
and every urllib call this module makes is monkeypatched per test.

Case numbers refer to /tmp .../scratchpad/t034p1-plan.md's condensed list
(phase 1) and the task file's "Review round 1 findings" section (round 2).
RED means: at the time this test was first written, index.py did not yet
have the behaviour it asserts, and running it failed for that reason.
"""

import hashlib
import hmac
import json
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import testsupport  # noqa: E402

LAMBDA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ci_doorbell")
INDEX_PATH = os.path.join(LAMBDA_DIR, "index.py")

WEBHOOK_SECRET = "wh-secret-not-real"
HOOKS_TOKEN = "hooks-token-not-real"

ENV = {
    "INSTANCE_ID": "i-0123456789abcdef0",
    "WEBHOOK_SECRET_PARAM": "/cv-project/dev/ci/github-webhook-secret",
    "ALLOWED_REPOS": "erfeamor/cv-domain-service,erfeamor/cv-database,erfeamor/cv-admin-react",
    "REDELIVER_REPOS": "erfeamor/cv-admin-react",
    "GITHUB_HOOKS_TOKEN_PARAM": "/cv-project/dev/doorbell/github-hooks-token",
    "DRONE_HEALTHZ_URL": "http://203.0.113.10/healthz",
    "HEALTHZ_TIMEOUT_SECONDS": "480",
    "HEALTHZ_POLL_INTERVAL_SECONDS": "15",
    "SELF_FUNCTION_NAME": "cv-project-ci-doorbell",
}


def sign(secret, raw_bytes):
    return "sha256=" + hmac.new(secret.encode("utf-8"), raw_bytes, hashlib.sha256).hexdigest()


def push_event(repo, secret=WEBHOOK_SECRET, event_type="push"):
    body = json.dumps({"repository": {"full_name": repo}}).encode("utf-8")
    return {
        "requestContext": {"http": {"method": "POST"}},
        "headers": {
            "x-hub-signature-256": sign(secret, body),
            "x-github-event": event_type,
        },
        "body": body.decode("utf-8"),
        "isBase64Encoded": False,
    }


class DoorbellTestCase(unittest.TestCase):
    def setUp(self):
        self.module = testsupport.load_lambda_module("t034_ci_doorbell_index_%s" % id(self), INDEX_PATH, ENV)
        self.module.ssm.get_parameter.side_effect = self._ssm_get_parameter

    def _ssm_get_parameter(self, Name, WithDecryption=True):
        if Name == ENV["WEBHOOK_SECRET_PARAM"]:
            return {"Parameter": {"Value": WEBHOOK_SECRET}}
        if Name == ENV["GITHUB_HOOKS_TOKEN_PARAM"]:
            return {"Parameter": {"Value": HOOKS_TOKEN}}
        raise AssertionError("unexpected ssm.get_parameter(Name=%r)" % Name)

    def set_instance_state(self, state):
        self.module.ec2.describe_instances.return_value = {
            "Reservations": [{"Instances": [{"State": {"Name": state}}]}]
        }

    def now_iso(self):
        return self.module.datetime.datetime.now(self.module.datetime.timezone.utc).isoformat()


# --- Case 1 (RED): HMAC rejection unchanged, both entry points -------------


class TestHmacRejection(DoorbellTestCase):
    def test_bad_signature_rejected_for_jenkins_repo(self):
        event = push_event("erfeamor/cv-database", secret="wrong-secret")
        response = self.module.handler(event, None)
        self.assertEqual(response["statusCode"], 401)
        self.module.ec2.describe_instances.assert_not_called()

    def test_bad_signature_rejected_for_redeliver_repo(self):
        event = push_event("erfeamor/cv-admin-react", secret="wrong-secret")
        response = self.module.handler(event, None)
        self.assertEqual(response["statusCode"], 401)
        self.module.lambda_client.invoke.assert_not_called()

    def test_missing_signature_rejected(self):
        event = push_event("erfeamor/cv-admin-react")
        del event["headers"]["x-hub-signature-256"]
        response = self.module.handler(event, None)
        self.assertEqual(response["statusCode"], 401)


# --- Case 2: allowlist -------------------------------------------------


class TestAllowlist(DoorbellTestCase):
    def test_unlisted_repo_rejected(self):
        event = push_event("erfeamor/some-other-repo")
        response = self.module.handler(event, None)
        self.assertEqual(response["statusCode"], 403)

    def test_jenkins_repo_unchanged_behaviour(self):
        self.set_instance_state("stopped")
        event = push_event("erfeamor/cv-database")
        response = self.module.handler(event, None)
        self.assertEqual(response["statusCode"], 200)
        self.module.ec2.start_instances.assert_called_once_with(InstanceIds=[ENV["INSTANCE_ID"]])
        self.module.lambda_client.invoke.assert_not_called()


# --- Case 3 (RED): 202 before any Drone/GitHub call -------------------------


class TestAsyncScheduling(DoorbellTestCase):
    def test_admin_react_returns_202_and_only_schedules(self):
        event = push_event("erfeamor/cv-admin-react")
        response = self.module.handler(event, None)
        self.assertEqual(response["statusCode"], 202)
        self.module.ec2.describe_instances.assert_not_called()
        self.module.ec2.start_instances.assert_not_called()
        self.module.lambda_client.invoke.assert_called_once()
        _, kwargs = self.module.lambda_client.invoke.call_args
        self.assertEqual(kwargs["FunctionName"], ENV["SELF_FUNCTION_NAME"])
        self.assertEqual(kwargs["InvocationType"], "Event")
        payload = json.loads(kwargs["Payload"])
        self.assertEqual(payload["repo"], "erfeamor/cv-admin-react")
        self.assertIn("wake_time", payload)

    def test_admin_react_never_reads_hooks_token_synchronously(self):
        event = push_event("erfeamor/cv-admin-react")
        self.module.handler(event, None)
        for call in self.module.ssm.get_parameter.call_args_list:
            self.assertNotEqual(call.kwargs.get("Name") or call.args[0], ENV["GITHUB_HOOKS_TOKEN_PARAM"])


# --- Review round 1, finding 1(b)+(c) (RED): the async task revalidates ----


class TestAsyncTaskRevalidation(DoorbellTestCase):
    """A direct, unauthenticated-by-HTTP invocation of the async task shape
    (no requestContext) must not be trusted just because it reached the
    function -- see the module docstring. These exercise handler() with a
    hand-built task event, as if something other than _self_invoke had
    called this function directly."""

    def test_rejects_repo_outside_redeliver_allowlist(self):
        with self.assertLogs(self.module.log, level="ERROR"):
            result = self.module.handler({"repo": "erfeamor/some-other-repo", "wake_time": self.now_iso()}, None)
        self.assertFalse(result["ok"])
        self.module.ec2.describe_instances.assert_not_called()

    def test_rejects_repo_that_is_allowed_but_not_a_redeliver_repo(self):
        # erfeamor/cv-database is a real, allowed repo -- just not one that
        # gets the async redeliver path. It must be rejected here exactly
        # like an unknown repo would be.
        with self.assertLogs(self.module.log, level="ERROR"):
            result = self.module.handler({"repo": "erfeamor/cv-database", "wake_time": self.now_iso()}, None)
        self.assertFalse(result["ok"])
        self.module.ec2.describe_instances.assert_not_called()

    def test_rejects_unparseable_wake_time(self):
        with self.assertLogs(self.module.log, level="ERROR"):
            result = self.module.handler({"repo": "erfeamor/cv-admin-react", "wake_time": "not-a-timestamp"}, None)
        self.assertFalse(result["ok"])
        self.module.ec2.describe_instances.assert_not_called()

    def test_rejects_missing_wake_time(self):
        with self.assertLogs(self.module.log, level="ERROR"):
            result = self.module.handler({"repo": "erfeamor/cv-admin-react"}, None)
        self.assertFalse(result["ok"])
        self.module.ec2.describe_instances.assert_not_called()

    def test_rejects_wake_time_older_than_15_minutes(self):
        stale = (self.module.datetime.datetime.now(self.module.datetime.timezone.utc) - self.module.datetime.timedelta(minutes=20)).isoformat()
        with self.assertLogs(self.module.log, level="ERROR"):
            result = self.module.handler({"repo": "erfeamor/cv-admin-react", "wake_time": stale}, None)
        self.assertFalse(result["ok"])
        self.module.ec2.describe_instances.assert_not_called()

    def test_rejects_wake_time_in_the_future(self):
        future = (self.module.datetime.datetime.now(self.module.datetime.timezone.utc) + self.module.datetime.timedelta(minutes=5)).isoformat()
        with self.assertLogs(self.module.log, level="ERROR"):
            result = self.module.handler({"repo": "erfeamor/cv-admin-react", "wake_time": future}, None)
        self.assertFalse(result["ok"])
        self.module.ec2.describe_instances.assert_not_called()

    def test_accepts_recent_wake_time_for_redeliver_repo(self):
        self.set_instance_state("running")
        with mock.patch.object(self.module, "wait_for_drone_healthz", return_value=True), mock.patch.object(
            self.module, "redeliver_failed_deliveries"
        ) as redeliver_mock:
            result = self.module.handler({"repo": "erfeamor/cv-admin-react", "wake_time": self.now_iso()}, None)
        self.assertTrue(result["ok"])
        redeliver_mock.assert_called_once()


# --- Case 4 (RED): bounded healthz wait -------------------------------------


class TestHealthzWait(DoorbellTestCase):
    def test_succeeds_after_n_polls(self):
        check_fn = mock.Mock(side_effect=[False, False, True])
        sleep_fn = mock.Mock()
        clock_fn = mock.Mock(side_effect=[0, 0, 0, 0])
        result = self.module.wait_for_drone_healthz(
            "http://x/healthz", 480, 15, check_fn=check_fn, sleep_fn=sleep_fn, clock_fn=clock_fn
        )
        self.assertTrue(result)
        self.assertEqual(check_fn.call_count, 3)
        self.assertEqual(sleep_fn.call_count, 2)

    def test_gives_up_at_timeout_without_redelivering(self):
        clock = {"t": 0}

        def clock_fn():
            return clock["t"]

        def sleep_fn(seconds):
            clock["t"] += seconds

        check_fn = mock.Mock(return_value=False)
        result = self.module.wait_for_drone_healthz(
            "http://x/healthz", 480, 15, check_fn=check_fn, sleep_fn=sleep_fn, clock_fn=clock_fn
        )
        self.assertFalse(result)
        self.assertGreaterEqual(clock["t"], 480)

    def test_async_task_skips_redelivery_when_healthz_never_succeeds(self):
        self.set_instance_state("running")
        with mock.patch.object(self.module, "wait_for_drone_healthz", return_value=False) as wait_mock, mock.patch.object(
            self.module, "redeliver_failed_deliveries"
        ) as redeliver_mock:
            result = self.module.handler({"repo": "erfeamor/cv-admin-react", "wake_time": self.now_iso()}, None)
        wait_mock.assert_called_once()
        redeliver_mock.assert_not_called()
        self.assertFalse(result["ok"])


# --- Review round 1, finding 9 (RED): the healthz probe's exception set ----


class TestHealthzProbeExceptions(DoorbellTestCase):
    def test_os_error_reads_as_not_ready(self):
        with mock.patch.object(self.module.urllib.request, "urlopen", side_effect=OSError("connection reset")):
            self.assertFalse(self.module._drone_healthz_ok("http://x/healthz"))

    def test_http_exception_reads_as_not_ready(self):
        with mock.patch.object(
            self.module.urllib.request, "urlopen", side_effect=self.module.http.client.BadStatusLine("garbage")
        ):
            self.assertFalse(self.module._drone_healthz_ok("http://x/healthz"))


# --- Review round 1, finding 6 (RED): a `stopping` instance is waited out --


class TestInstanceStopping(DoorbellTestCase):
    def test_async_task_waits_for_stopping_then_starts(self):
        states = iter(["stopping", "stopping", "stopped"])
        self.module.ec2.describe_instances.side_effect = lambda **kw: {
            "Reservations": [{"Instances": [{"State": {"Name": next(states)}}]}]
        }
        with mock.patch.object(self.module.time, "sleep") as sleep_mock, mock.patch.object(
            self.module, "wait_for_drone_healthz", return_value=True
        ), mock.patch.object(self.module, "redeliver_failed_deliveries"):
            result = self.module.handler({"repo": "erfeamor/cv-admin-react", "wake_time": self.now_iso()}, None)
        self.assertTrue(result["ok"])
        self.module.ec2.start_instances.assert_called_once_with(InstanceIds=[ENV["INSTANCE_ID"]])
        self.assertTrue(sleep_mock.called)

    def test_async_task_gives_up_if_stuck_stopping(self):
        self.module.ec2.describe_instances.return_value = {
            "Reservations": [{"Instances": [{"State": {"Name": "stopping"}}]}]
        }
        clock = {"t": 0}
        with mock.patch.object(self.module.time, "monotonic", side_effect=lambda: clock["t"]), mock.patch.object(
            self.module.time, "sleep", side_effect=lambda s: clock.update(t=clock["t"] + s)
        ), mock.patch.object(self.module, "wait_for_drone_healthz") as healthz_mock:
            with self.assertLogs(self.module.log, level="ERROR"):
                result = self.module.handler({"repo": "erfeamor/cv-admin-react", "wake_time": self.now_iso()}, None)
        self.assertFalse(result["ok"])
        self.module.ec2.start_instances.assert_not_called()
        healthz_mock.assert_not_called()


# --- Case 5: Drone hook discovered by config.url ending in /hook -----------


class TestFindDroneHook(DoorbellTestCase):
    def test_found(self):
        with mock.patch.object(
            self.module,
            "_github_list",
            return_value=[
                {"id": 1, "config": {"url": "https://example.com/doorbell"}},
                {"id": 2, "config": {"url": "http://203.0.113.10/hook"}},
            ],
        ):
            hook_id = self.module.find_drone_hook_id("erfeamor/cv-admin-react", HOOKS_TOKEN)
        self.assertEqual(hook_id, 2)

    def test_missing_logs_clear_error_and_returns_none(self):
        with mock.patch.object(self.module, "_github_list", return_value=[{"id": 1, "config": {"url": "https://x/other"}}]):
            with self.assertLogs(self.module.log, level="ERROR") as logs:
                hook_id = self.module.find_drone_hook_id("erfeamor/cv-admin-react", HOOKS_TOKEN)
        self.assertIsNone(hook_id)
        self.assertTrue(any("hook" in m.lower() for m in logs.output))

    def test_repo_is_escaped_in_the_hooks_path(self):
        captured = {}

        def fake_list(path, token, stop_predicate=None):
            captured["path"] = path
            return []

        with mock.patch.object(self.module, "_github_list", side_effect=fake_list):
            self.module.find_drone_hook_id("erfeamor/repo with spaces", HOOKS_TOKEN)
        self.assertNotIn(" ", captured["path"])


# --- Review round 1, findings 2+3 (RED): backward slack + dedup by guid ----


class TestRedeliverFailedDeliveries(DoorbellTestCase):
    WAKE = "2026-09-29T00:45:00+00:00"

    def _run(self, deliveries):
        with mock.patch.object(self.module, "find_drone_hook_id", return_value=42), mock.patch.object(
            self.module, "_github_list", return_value=deliveries
        ), mock.patch.object(self.module, "_github_request") as github_request:
            self.module.redeliver_failed_deliveries("erfeamor/cv-admin-react", self.WAKE)
        return [c for c in github_request.call_args_list if c.args[0] == "POST"]

    def test_backward_slack_includes_a_delivery_just_before_wake_time(self):
        # 00:41:00 is 4 minutes before wake (00:45:00) -- inside the 5-minute
        # backward slack, so it must still be considered, not skipped as
        # "before the wake".
        deliveries = [{"id": 1, "guid": "g1", "delivered_at": "2026-09-29T00:41:00Z", "status_code": 500}]
        calls = self._run(deliveries)
        self.assertEqual(len(calls), 1)

    def test_outside_the_slack_window_is_not_redelivered(self):
        # 00:39:00 is 6 minutes before wake -- outside the 5-minute slack.
        deliveries = [{"id": 1, "guid": "g1", "delivered_at": "2026-09-29T00:39:00Z", "status_code": 500}]
        calls = self._run(deliveries)
        self.assertEqual(len(calls), 0)

    def test_dedup_by_guid_skips_guid_with_any_2xx_entry(self):
        # Same guid, two attempts in the window: first failed, second (a
        # GitHub-side redelivery) succeeded. Must not be redelivered again.
        deliveries = [
            {"id": 10, "guid": "gA", "delivered_at": "2026-09-29T00:46:00Z", "status_code": 500},
            {"id": 11, "guid": "gA", "delivered_at": "2026-09-29T00:47:00Z", "status_code": 200, "redelivery": True},
        ]
        calls = self._run(deliveries)
        self.assertEqual(len(calls), 0)

    def test_dedup_by_guid_redelivers_latest_failed_attempt_once(self):
        deliveries = [
            {"id": 20, "guid": "gB", "delivered_at": "2026-09-29T00:46:00Z", "status_code": 500},
            {"id": 21, "guid": "gB", "delivered_at": "2026-09-29T00:47:00Z", "status_code": 502},
        ]
        calls = self._run(deliveries)
        self.assertEqual(len(calls), 1)
        self.assertIn("/deliveries/21/attempts", calls[0].args[1])

    def test_distinct_guids_each_redelivered_once(self):
        deliveries = [
            {"id": 30, "guid": "gC", "delivered_at": "2026-09-29T00:46:00Z", "status_code": 500},
            {"id": 31, "guid": "gD", "delivered_at": "2026-09-29T00:46:05Z", "status_code": 502},
        ]
        calls = self._run(deliveries)
        self.assertEqual(len(calls), 2)

    def test_delivery_id_and_hook_id_are_escaped_in_the_attempts_path(self):
        deliveries = [{"id": 30, "guid": "gC", "delivered_at": "2026-09-29T00:46:00Z", "status_code": 500}]
        with mock.patch.object(self.module, "find_drone_hook_id", return_value=42), mock.patch.object(
            self.module, "_github_list", return_value=deliveries
        ), mock.patch.object(self.module, "_github_request") as github_request:
            self.module.redeliver_failed_deliveries("erfeamor/repo with spaces", self.WAKE)
        post_calls = [c for c in github_request.call_args_list if c.args[0] == "POST"]
        self.assertEqual(len(post_calls), 1)
        self.assertNotIn(" ", post_calls[0].args[1])


# --- Review round 1, finding 4 (RED): a failed POST doesn't abort the loop,
# and redeliveries are capped per run --------------------------------------


class TestRedeliveryResilienceAndCap(DoorbellTestCase):
    def test_one_failed_post_does_not_abort_the_remaining_redeliveries(self):
        deliveries = [
            {"id": 1, "guid": "g1", "delivered_at": "2026-09-29T00:46:00Z", "status_code": 500},
            {"id": 2, "guid": "g2", "delivered_at": "2026-09-29T00:46:05Z", "status_code": 500},
        ]
        with mock.patch.object(self.module, "find_drone_hook_id", return_value=42), mock.patch.object(
            self.module, "_github_list", return_value=deliveries
        ), mock.patch.object(self.module, "_github_request") as github_request:
            github_request.side_effect = self.module.urllib.error.URLError("boom")
            with self.assertLogs(self.module.log, level="WARNING"):
                redelivered = self.module.redeliver_failed_deliveries("erfeamor/cv-admin-react", "2026-09-29T00:45:00+00:00")
        self.assertEqual(redelivered, 0)
        post_calls = [c for c in github_request.call_args_list if c.args[0] == "POST"]
        self.assertEqual(len(post_calls), 2, "both guids must still be attempted even though each POST raises")

    def test_redeliveries_are_capped_per_run(self):
        deliveries = [
            {"id": i, "guid": "g%d" % i, "delivered_at": "2026-09-29T00:46:%02dZ" % (i % 60), "status_code": 500}
            for i in range(self.module.MAX_REDELIVERIES_PER_RUN + 5)
        ]
        with mock.patch.object(self.module, "find_drone_hook_id", return_value=42), mock.patch.object(
            self.module, "_github_list", return_value=deliveries
        ), mock.patch.object(self.module, "_github_request") as github_request:
            with self.assertLogs(self.module.log, level="WARNING"):
                redelivered = self.module.redeliver_failed_deliveries("erfeamor/cv-admin-react", "2026-09-29T00:45:00+00:00")
        self.assertEqual(redelivered, self.module.MAX_REDELIVERIES_PER_RUN)
        post_calls = [c for c in github_request.call_args_list if c.args[0] == "POST"]
        self.assertEqual(len(post_calls), self.module.MAX_REDELIVERIES_PER_RUN)


# --- Review round 1, finding 8 (RED): pagination follows Link: rel=next ----


class TestPagination(DoorbellTestCase):
    def test_next_link_parsed_from_header(self):
        header = '<https://api.github.com/repos/x/y/hooks?page=2>; rel="next", <https://api.github.com/repos/x/y/hooks?page=5>; rel="last"'
        self.assertEqual(self.module._next_link(header), "https://api.github.com/repos/x/y/hooks?page=2")

    def test_next_link_none_on_last_page(self):
        header = '<https://api.github.com/repos/x/y/hooks?page=1>; rel="prev"'
        self.assertIsNone(self.module._next_link(header))
        self.assertIsNone(self.module._next_link(None))

    def test_github_list_follows_link_header_across_pages(self):
        page1 = mock.Mock()
        page1.__enter__ = mock.Mock(return_value=page1)
        page1.__exit__ = mock.Mock(return_value=False)
        page1.read.return_value = json.dumps([{"id": 1}]).encode("utf-8")
        page1.headers = {"Link": '<https://api.github.com/next>; rel="next"'}

        page2 = mock.Mock()
        page2.__enter__ = mock.Mock(return_value=page2)
        page2.__exit__ = mock.Mock(return_value=False)
        page2.read.return_value = json.dumps([{"id": 2}]).encode("utf-8")
        page2.headers = {}

        with mock.patch.object(self.module.urllib.request, "urlopen", side_effect=[page1, page2]):
            items = self.module._github_list("/repos/x/y/hooks?per_page=100", HOOKS_TOKEN)
        self.assertEqual([i["id"] for i in items], [1, 2])

    def test_github_list_stops_paginating_once_stop_predicate_matches(self):
        page1 = mock.Mock()
        page1.__enter__ = mock.Mock(return_value=page1)
        page1.__exit__ = mock.Mock(return_value=False)
        page1.read.return_value = json.dumps([{"id": 1, "old": False}, {"id": 2, "old": True}]).encode("utf-8")
        page1.headers = {"Link": '<https://api.github.com/next>; rel="next"'}

        with mock.patch.object(self.module.urllib.request, "urlopen", return_value=page1) as urlopen_mock:
            items = self.module._github_list("/repos/x/y/deliveries", HOOKS_TOKEN, stop_predicate=lambda d: d["old"])
        self.assertEqual(urlopen_mock.call_count, 1, "must not fetch a further page once stop_predicate matches")
        self.assertEqual(len(items), 2)

    def test_github_list_is_bounded_even_without_a_stop_predicate(self):
        page = mock.Mock()
        page.__enter__ = mock.Mock(return_value=page)
        page.__exit__ = mock.Mock(return_value=False)
        page.read.return_value = json.dumps([{"id": 1}]).encode("utf-8")
        page.headers = {"Link": '<https://api.github.com/same>; rel="next"'}  # pathological: always "more"

        with mock.patch.object(self.module.urllib.request, "urlopen", return_value=page) as urlopen_mock:
            self.module._github_list("/repos/x/y/hooks", HOOKS_TOKEN)
        self.assertEqual(urlopen_mock.call_count, self.module.MAX_LIST_PAGES)


# --- Case 8: the token never appears in logs; cached like the webhook secret


class TestHooksTokenHandling(DoorbellTestCase):
    def test_cached_across_calls(self):
        self.module._hooks_token()
        self.module._hooks_token()
        self.assertEqual(
            sum(1 for c in self.module.ssm.get_parameter.call_args_list if c.kwargs.get("Name") == ENV["GITHUB_HOOKS_TOKEN_PARAM"]),
            1,
        )

    def test_token_never_logged(self):
        with self.assertLogs(self.module.log, level="INFO") as logs, mock.patch.object(
            self.module, "find_drone_hook_id", return_value=42
        ), mock.patch.object(self.module, "_github_list", return_value=[]):
            self.module.redeliver_failed_deliveries("erfeamor/cv-admin-react", "2026-09-29T00:00:00+00:00")
        for message in logs.output:
            self.assertNotIn(HOOKS_TOKEN, message)


# --- Case 9: Jenkins repos make zero GitHub hooks calls, no token read -----


class TestJenkinsReposUntouched(DoorbellTestCase):
    def test_no_github_hooks_calls_no_token_read(self):
        self.set_instance_state("running")
        with mock.patch.object(self.module, "_github_request") as github_request, mock.patch.object(
            self.module, "_github_list"
        ) as github_list:
            event = push_event("erfeamor/cv-domain-service")
            response = self.module.handler(event, None)
        self.assertEqual(response["statusCode"], 200)
        github_request.assert_not_called()
        github_list.assert_not_called()
        for call in self.module.ssm.get_parameter.call_args_list:
            self.assertNotEqual(call.kwargs.get("Name"), ENV["GITHUB_HOOKS_TOKEN_PARAM"])


if __name__ == "__main__":
    unittest.main()
