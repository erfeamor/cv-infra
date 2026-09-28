#!/usr/bin/env python3
"""Tiny stand-in for the Drone API, used only by
scripts/tests/run-drone-reseed-tests.sh to exercise
scripts/drone-reseed-secrets.sh offline (T-008 case 7's idempotency check
needs something that actually tracks whether a secret already exists).

Mirrors just the two calls the reseed script makes against
/api/repos/{repo}/secrets:
  PATCH /api/repos/{repo}/secrets/{name}  -> 200 if {name} exists, else 404
  POST  /api/repos/{repo}/secrets         -> 201, creates {name} from the body

Every request is appended to REQUESTS_LOG (one line per call: METHOD PATH),
one path component, so the test harness can assert both call sequencing
(create-then-update across two runs) and that no call happens at all when
the reseed script should have aborted before reaching the network.

Review round 1, finding 7: also validates the request before accepting it,
same as the real Drone API would reject a malformed one --
  - the Authorization header must be present and start with "Bearer "
  - the body's pull_request AND pull_request_push flags must both be
    explicitly false (a secret Drone exposes to PR builds/PR-push events by
    default is a bigger blast radius than this task intends)
A request failing either check is rejected with 400 and logged to
VIOLATIONS_LOG (one line per violation) instead of being accepted -- so a
regression that drops a flag or the auth header fails LOUDLY here, not
silently by "the stub happened to accept it anyway".
"""
import http.server
import json
import os
import sys

secrets = {}
REQUESTS_LOG = os.environ["STUB_DRONE_REQUESTS_LOG"]
SECRETS_LOG = os.environ["STUB_DRONE_SECRETS_LOG"]
VIOLATIONS_LOG = os.environ["STUB_DRONE_VIOLATIONS_LOG"]


def log_request(line):
    with open(REQUESTS_LOG, "a") as f:
        f.write(line + "\n")


def log_violation(line):
    with open(VIOLATIONS_LOG, "a") as f:
        f.write(line + "\n")


def dump_secrets():
    with open(SECRETS_LOG, "w") as f:
        json.dump(secrets, f)


class Handler(http.server.BaseHTTPRequestHandler):
    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length)

    def _check_auth(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            log_violation(f"{self.command} {self.path}: missing/malformed Authorization header ({auth!r})")
            return False
        return True

    def _check_pull_request_flags(self, body):
        ok = True
        for flag in ("pull_request", "pull_request_push"):
            if body.get(flag) is not False:
                log_violation(f"{self.command} {self.path}: {flag} must be explicitly false, got {body.get(flag)!r}")
                ok = False
        return ok

    def do_PATCH(self):
        name = self.path.rsplit("/", 1)[-1]
        log_request(f"PATCH {self.path}")
        raw_body = self._read_body()
        auth_ok = self._check_auth()
        body = json.loads(raw_body)
        flags_ok = self._check_pull_request_flags(body)
        if not (auth_ok and flags_ok):
            self.send_response(400)
            self.end_headers()
            return
        if name in secrets:
            secrets[name] = body
            dump_secrets()
            self.send_response(200)
        else:
            self.send_response(404)
        self.end_headers()

    def do_POST(self):
        log_request(f"POST {self.path}")
        raw_body = self._read_body()
        auth_ok = self._check_auth()
        body = json.loads(raw_body)
        flags_ok = self._check_pull_request_flags(body)
        if not (auth_ok and flags_ok):
            self.send_response(400)
            self.end_headers()
            return
        name = body.get("name")
        secrets[name] = body
        dump_secrets()
        self.send_response(201)
        self.end_headers()

    def log_message(self, fmt, *args):  # silence default stderr access log
        pass


if __name__ == "__main__":
    port = int(sys.argv[1])
    server = http.server.HTTPServer(("127.0.0.1", port), Handler)
    server.serve_forever()
