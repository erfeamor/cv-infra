#!/usr/bin/env bash
# T-004 review round 1, finding 3: `terraform test` cannot see lifecycle
# meta-arguments (they never appear in plan output), so prevent_destroy on
# the state bucket is checked here instead -- part of this module's gate,
# run alongside fmt/validate/test (see cv-infra/CLAUDE.md and
# bootstrap/README.md).
#
# Anchored and requires an uncommented assignment: a bare `grep -n
# prevent_destroy` also matches this file's own comments (including the
# one you're reading), which would make the check pass even if the real
# assignment were deleted or commented out.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if ! grep -Enq '^\s*prevent_destroy\s*=\s*true' state-backend.tf; then
  echo "FAIL: no uncommented 'prevent_destroy = true' found in state-backend.tf" >&2
  echo "The state bucket must refuse destroy -- see state-backend.tf's aws_s3_bucket.tfstate lifecycle block." >&2
  exit 1
fi

echo "OK: prevent_destroy = true present in state-backend.tf"
