"""Offline unit tests for lambda/ci_reaper/index.py (T-019, T-034).

Run with: python3 -m unittest discover -s lambda -p 'test_*.py'

Covers T-034's added post-start grace (cases 10-11 of the plan). The
pre-existing Jenkins/CPU idle logic is exercised only enough to prove the
grace check sits ahead of it without displacing it -- it already has no
tests of its own to extend, and re-deriving full coverage for T-019's logic
is out of this task's scope.
"""

import datetime
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import testsupport  # noqa: E402

LAMBDA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ci_reaper")
INDEX_PATH = os.path.join(LAMBDA_DIR, "index.py")

ENV = {
    "INSTANCE_ID": "i-0123456789abcdef0",
    "JENKINS_BASE_URL": "http://203.0.113.10/jenkins",
    "JENKINS_USER": "admin",
    "JENKINS_PASSWORD_PARAM": "/cv-project/dev/ci/jenkins-admin-password",
    "IDLE_WINDOW_MINUTES": "20",
    "CPU_BUSY_PERCENT": "10",
    "POST_START_GRACE_MINUTES": "15",
}


def instance(state="running", launch_time=None, tags=None):
    return {
        "State": {"Name": state},
        "LaunchTime": launch_time or datetime.datetime.now(datetime.timezone.utc),
        "Tags": tags or [],
    }


class ReaperTestCase(unittest.TestCase):
    def setUp(self):
        self.module = testsupport.load_lambda_module("t034_ci_reaper_index_%s" % id(self), INDEX_PATH, ENV)

    def set_instance(self, inst):
        self.module.ec2.describe_instances.return_value = {"Reservations": [{"Instances": [inst]}]}


# --- Case 10 (RED): post-start grace blocks a stop inside 15 min -----------


class TestPostStartGrace(ReaperTestCase):
    def test_grace_blocks_stop_just_after_launch(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        self.set_instance(instance(launch_time=now - datetime.timedelta(minutes=1)))
        with mock.patch.object(self.module, "cpu_quiet_over_window", return_value=True), mock.patch.object(
            self.module, "jenkins_is_idle", return_value=True
        ):
            result = self.module.handler({}, None)
        self.assertEqual(result, {"stopped": False, "reason": "post-start grace"})
        self.module.ec2.stop_instances.assert_not_called()

    def test_grace_blocks_even_when_everything_else_says_idle(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        self.set_instance(instance(launch_time=now - datetime.timedelta(minutes=14, seconds=59)))
        with mock.patch.object(self.module, "cpu_quiet_over_window", return_value=True), mock.patch.object(
            self.module, "jenkins_is_idle", return_value=True
        ):
            result = self.module.handler({}, None)
        self.assertFalse(result["stopped"])
        self.assertEqual(result["reason"], "post-start grace")


# --- Case 11: grace expired + idle still stops ------------------------------


class TestGraceExpired(ReaperTestCase):
    def test_stops_once_grace_has_expired_and_idle(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        self.set_instance(instance(launch_time=now - datetime.timedelta(minutes=21)))
        with mock.patch.object(self.module, "cpu_quiet_over_window", return_value=True), mock.patch.object(
            self.module, "jenkins_is_idle", return_value=True
        ):
            result = self.module.handler({}, None)
        self.assertEqual(result, {"stopped": True, "reason": "idle"})
        self.module.ec2.stop_instances.assert_called_once_with(InstanceIds=[ENV["INSTANCE_ID"]])

    def test_grace_expired_but_busy_does_not_stop(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        self.set_instance(instance(launch_time=now - datetime.timedelta(minutes=21)))
        with mock.patch.object(self.module, "cpu_quiet_over_window", return_value=False):
            result = self.module.handler({}, None)
        self.assertFalse(result["stopped"])
        self.module.ec2.stop_instances.assert_not_called()


if __name__ == "__main__":
    unittest.main()
