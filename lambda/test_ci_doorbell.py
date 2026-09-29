"""Offline unit tests for lambda/ci_doorbell/index.py (T-019, T-034).

Run with: python3 -m unittest discover -s lambda -p 'test_*.py'
(also invoked directly by this file's __main__ block).

No AWS credentials, no network: boto3/botocore are stubbed (testsupport.py)
and every urllib call this module makes is monkeypatched per test.

Case numbers below refer to /tmp .../scratchpad/t034p1-plan.md's condensed
list. RED means: at the time this test was first written, index.py did not
yet have the behaviour it asserts, and running it failed for that reason.
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
            result = self.module.handler(
                {"repo": "erfeamor/cv-admin-react", "wake_time": "2026-09-29T00:00:00+00:00"}, None
            )
        wait_mock.assert_called_once()
        redeliver_mock.assert_not_called()
        self.assertFalse(result["ok"])


# --- Case 5: Drone hook discovered by config.url ending in /hook -----------


class TestFindDroneHook(DoorbellTestCase):
    def test_found(self):
        with mock.patch.object(
            self.module,
            "_github_request",
            return_value=[
                {"id": 1, "config": {"url": "https://example.com/doorbell"}},
                {"id": 2, "config": {"url": "http://203.0.113.10/hook"}},
            ],
        ):
            hook_id = self.module.find_drone_hook_id("erfeamor/cv-admin-react", HOOKS_TOKEN)
        self.assertEqual(hook_id, 2)

    def test_missing_logs_clear_error_and_returns_none(self):
        with mock.patch.object(self.module, "_github_request", return_value=[{"id": 1, "config": {"url": "https://x/other"}}]):
            with self.assertLogs(self.module.log, level="ERROR") as logs:
                hook_id = self.module.find_drone_hook_id("erfeamor/cv-admin-react", HOOKS_TOKEN)
        self.assertIsNone(hook_id)
        self.assertTrue(any("hook" in m.lower() for m in logs.output))


# --- Case 6 (RED) + 7 (RED): only failed deliveries at/after wake, no dupes -


class TestRedeliverFailedDeliveries(DoorbellTestCase):
    def _deliveries(self):
        return [
            {"id": 1, "delivered_at": "2026-09-29T00:10:00Z", "status_code": 500},  # before wake, failed
            {"id": 2, "delivered_at": "2026-09-29T00:50:00Z", "status_code": 200},  # after wake, ok
            {"id": 3, "delivered_at": "2026-09-29T00:49:04Z", "status_code": 502},  # after wake, failed
            {"id": 3, "delivered_at": "2026-09-29T00:49:04Z", "status_code": 502},  # duplicate of 3
        ]

    def test_only_failed_at_or_after_wake_are_redelivered(self):
        with mock.patch.object(self.module, "find_drone_hook_id", return_value=42), mock.patch.object(
            self.module, "_github_request"
        ) as github_request:
            github_request.side_effect = [self._deliveries(), None, None, None]
            self.module.redeliver_failed_deliveries("erfeamor/cv-admin-react", "2026-09-29T00:45:00+00:00")

        redeliver_calls = [c for c in github_request.call_args_list if c.args[0] == "POST"]
        self.assertEqual(len(redeliver_calls), 1, "expected exactly one redelivery POST (delivery id 3)")
        self.assertIn("/deliveries/3/attempts", redeliver_calls[0].args[1])

    def test_no_double_post_for_the_same_delivery_id(self):
        deliveries = self._deliveries() + [self._deliveries()[2]]  # id 3 appears three times total
        with mock.patch.object(self.module, "find_drone_hook_id", return_value=42), mock.patch.object(
            self.module, "_github_request"
        ) as github_request:
            github_request.side_effect = [deliveries, None]
            self.module.redeliver_failed_deliveries("erfeamor/cv-admin-react", "2026-09-29T00:45:00+00:00")
        redeliver_calls = [c for c in github_request.call_args_list if c.args[0] == "POST"]
        self.assertEqual(len(redeliver_calls), 1)


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
        ), mock.patch.object(self.module, "_github_request", return_value=[]):
            self.module.redeliver_failed_deliveries("erfeamor/cv-admin-react", "2026-09-29T00:00:00+00:00")
        for message in logs.output:
            self.assertNotIn(HOOKS_TOKEN, message)


# --- Case 9: Jenkins repos make zero GitHub hooks calls, no token read -----


class TestJenkinsReposUntouched(DoorbellTestCase):
    def test_no_github_hooks_calls_no_token_read(self):
        self.set_instance_state("running")
        with mock.patch.object(self.module, "_github_request") as github_request:
            event = push_event("erfeamor/cv-domain-service")
            response = self.module.handler(event, None)
        self.assertEqual(response["statusCode"], 200)
        github_request.assert_not_called()
        for call in self.module.ssm.get_parameter.call_args_list:
            self.assertNotEqual(call.kwargs.get("Name"), ENV["GITHUB_HOOKS_TOKEN_PARAM"])


if __name__ == "__main__":
    unittest.main()
