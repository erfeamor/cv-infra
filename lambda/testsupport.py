"""Shared test scaffolding for the CI on-demand Lambdas (T-019/T-034).

Both lambda/ci_doorbell/index.py and lambda/ci_reaper/index.py import boto3
and botocore at module load time, and this repo's offline gate has no AWS
SDK installed -- deliberately: these Lambdas ship as a single index.py with
no vendored dependencies (see ci-on-demand.tf's data.archive_file). Tests
therefore stub both packages in sys.modules before importing the handler
module under test.

Each handler is loaded by explicit file path under a distinct module name,
never by adding its directory to sys.path -- ci_doorbell/index.py and
ci_reaper/index.py share the literal filename "index.py" and would collide
on the same top-level module name otherwise. Loading fresh (not caching in
sys.modules across calls) also means module-level state -- the webhook
secret cache, the hooks-token cache -- starts empty in every test.

Not named test_*.py, so `python3 -m unittest discover -s lambda -p
'test_*.py'` never tries to run this file itself as a test module.
"""

import importlib.util
import os
import sys
import types


def install_boto3_stub():
    """Insert a fake boto3 / botocore.exceptions into sys.modules.

    boto3.client(name) returns a fresh unittest.mock.MagicMock on every call;
    each test replaces the module-level clients it cares about (ec2, ssm,
    lambda_client, cloudwatch) with its own mock afterwards, so this stub only
    has to make `import boto3` and `from botocore.exceptions import
    ClientError` succeed without ever touching a real AWS SDK.
    """
    from unittest import mock

    if not (isinstance(sys.modules.get("boto3"), types.ModuleType) and getattr(sys.modules.get("boto3"), "_cv_stub", False)):
        boto3_stub = types.ModuleType("boto3")
        boto3_stub._cv_stub = True
        boto3_stub.client = lambda *a, **k: mock.MagicMock()
        sys.modules["boto3"] = boto3_stub

    if "botocore.exceptions" not in sys.modules:
        botocore_stub = types.ModuleType("botocore")
        botocore_exceptions_stub = types.ModuleType("botocore.exceptions")

        class ClientError(Exception):
            pass

        botocore_exceptions_stub.ClientError = ClientError
        botocore_stub.exceptions = botocore_exceptions_stub
        sys.modules["botocore"] = botocore_stub
        sys.modules["botocore.exceptions"] = botocore_exceptions_stub


def load_lambda_module(module_name, index_path, env):
    """Import a Lambda's index.py fresh, under module_name, with env set.

    Module-level code reads its required configuration via os.environ[...]
    at import time, so os.environ is swapped for exactly the given env for
    the duration of the import and restored immediately after -- this lets
    one test process import both Lambdas, with different and non-overlapping
    env, without either seeing the other's variables.
    """
    install_boto3_stub()
    old_environ = dict(os.environ)
    os.environ.clear()
    os.environ.update(env)
    try:
        spec = importlib.util.spec_from_file_location(module_name, index_path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        spec.loader.exec_module(module)
        return module
    finally:
        os.environ.clear()
        os.environ.update(old_environ)
