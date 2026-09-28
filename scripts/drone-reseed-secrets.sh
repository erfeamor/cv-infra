#!/usr/bin/env bash
# T-008 H1 decision 1 + the PO's settlement on how the reseed runs: sets the
# drone-deploy AWS credentials as Drone repo secrets on cv-admin-react,
# reading them from SSM with the OPERATOR's own credentials -- never the CI
# host's, which gets no new IAM grant for this.
#
# Run OFF-HOST:
#   1. Fetch both SecureStrings locally (this script's `aws ssm
#      get-parameter --with-decryption` calls run under YOUR credentials).
#   2. Separately, open an SSM port-forwarding tunnel to the CI host's
#      Drone server (`aws ssm start-session --document-name
#      AWS-StartPortForwardingSession ...` -- see
#      docs/drone-host-backup-and-cutover.md) and point DRONE_SERVER at the
#      LOCAL end of that tunnel, e.g. http://127.0.0.1:8080. The Drone API
#      is only ever called over that tunnel -- never over the open
#      internet with these values.
#   3. Export DRONE_TOKEN yourself (Drone's user-settings personal token).
#      This script never stores it, never prints it, and never passes it
#      as a command-line argument (that would show up in `ps`).
#
# Usage:
#   DRONE_SERVER=http://127.0.0.1:8080 \
#   DRONE_TOKEN=*** \
#   AWS_REGION=eu-west-3 PROJECT_NAME=cv-project ENVIRONMENT=dev \
#   ./scripts/drone-reseed-secrets.sh
#
# AWS_REGION/PROJECT_NAME/ENVIRONMENT default to this repo's usual values;
# DRONE_REPO defaults to erfeamor/cv-admin-react, the only repo that reads
# these two secrets (see cv-admin-react/.drone.yml's `from_secret` steps,
# verified 2026-09-28).
#
# HOW SECRETS ARE KEPT OUT OF STDOUT/STDERR, INCLUDING UNDER `bash -x`
# (case 8): bash's xtrace prints the RESOLVED value of every variable
# assignment (`+ var=value`) and every command/function argument
# (`+ cmd arg`), verbatim -- toggling `set +x`/`set -x` around a "secret
# handling" block does not change that (it only stops NEW commands from
# being traced, and is exactly the fragile pattern this task said not to
# rely on). So this script never lets a secret value become a bash
# variable's value or an argument: every secret-bearing SSM read is
# redirected straight to a 0600 temp file, every downstream use reads that
# file inside a heredoc (heredoc BODIES -- including command substitutions
# and variable expansions inside them -- are never printed by xtrace,
# verified empirically) or via curl's `--data @file` / `-K configfile`
# (which trace only as a filename). The one thing every command in this
# script ever takes as an argument is a path, never a value.
set -euo pipefail

: "${DRONE_SERVER:?DRONE_SERVER not set -- point this at the local end of the SSM tunnel to the CI host, e.g. http://127.0.0.1:8080}"

# NOT `: "${DRONE_TOKEN:?msg}"` -- review round 1: when DRONE_TOKEN IS set,
# `${DRONE_TOKEN:?msg}` expands to the token itself, so `bash -x` traces
# `+ : <the actual token>` verbatim (xtrace shows a command's arguments
# AFTER expansion, regardless of what the command does with them). Same
# reasoning rules out `[ -z "$DRONE_TOKEN" ]` -- xtrace would show the value
# there too. `${DRONE_TOKEN+x}` (presence, not value) and `${#DRONE_TOKEN}`
# (a length, not the string) are the only two expansions of this variable
# anywhere in this script that never put its content in a trace.
if [ -z "${DRONE_TOKEN+x}" ] || [ "${#DRONE_TOKEN}" -eq 0 ]; then
  echo "drone-reseed-secrets: DRONE_TOKEN not set -- export it in your own shell, never on a command line" >&2
  exit 1
fi

AWS_REGION="${AWS_REGION:-eu-west-3}"
PROJECT_NAME="${PROJECT_NAME:-cv-project}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
DRONE_REPO="${DRONE_REPO:-erfeamor/cv-admin-react}"

# Exactly the names cv-admin-react's .drone.yml reads via `from_secret` --
# verified 2026-09-28 (T-008 case 19). Changing these without updating
# .drone.yml in that repo breaks the deploy step silently: Drone just
# leaves the corresponding env var unset rather than erroring.
readonly SECRET_ACCESS_KEY_ID_NAME="aws_access_key_id"
readonly SECRET_SECRET_ACCESS_KEY_NAME="aws_secret_access_key"

SSM_PATH_PREFIX="/${PROJECT_NAME}/${ENVIRONMENT}/deploy/drone-deploy"

workdir="$(mktemp -d)"
chmod 700 "$workdir"
trap 'rm -rf "$workdir"' EXIT

access_key_id_file="$workdir/access-key-id"
secret_access_key_file="$workdir/secret-access-key"

# Fetches one SecureString straight to a file with the OPERATOR's own
# credentials -- never captured into a bash variable (see the header
# comment on why). Fails closed: any error here (including the real CLI's
# ParameterNotFound) is a non-zero exit, caught below, before anything
# touches the Drone API (case 6).
fetch_param_to_file() {
  aws ssm get-parameter --with-decryption --region "${AWS_REGION}" \
    --name "$1" --query 'Parameter.Value' --output text >"$2"
}

ok=1
fetch_param_to_file "${SSM_PATH_PREFIX}/access-key-id" "$access_key_id_file" || ok=0
fetch_param_to_file "${SSM_PATH_PREFIX}/secret-access-key" "$secret_access_key_file" || ok=0
# File-size checks only -- never a content comparison, which would trace
# the value under -x (`[ "$(cat f)" = ... ]` prints the compared value).
[ "$ok" = "1" ] && [ -s "$access_key_id_file" ] && [ -s "$secret_access_key_file" ] || {
  echo "drone-reseed-secrets: missing value(s) under ${SSM_PATH_PREFIX} -- aborting before any Drone API call" >&2
  exit 1
}
chmod 600 "$access_key_id_file" "$secret_access_key_file"

# Idempotent set: PATCH if the secret already exists on the repo, POST
# (create) if PATCH 404s. Two runs converge on the same end state either
# way (case 7).
set_secret() {
  local name="$1" value_file="$2" body_file auth_config status

  body_file="$workdir/body-${name}.json"
  # JSON body built inside a heredoc: the file's content is substituted via
  # $(cat ...) but never traced (see header comment). Escapes backslash and
  # double-quote only -- AWS access keys/secrets are base64-alphabet plus
  # `/+=`, never containing either in practice, but this is cheap insurance
  # against a malformed request rather than a guarantee for arbitrary input.
  cat >"$body_file" <<EOF
{"name":"${name}","data":"$(sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' "$value_file")","pull_request":false,"pull_request_push":false}
EOF
  chmod 600 "$body_file"

  # DRONE_TOKEN goes into a curl config file (-K), never a command-line
  # argument -- curl's own argv (and therefore xtrace, and `ps`) then shows
  # only a filename, never the token.
  auth_config="$workdir/curl-auth-${name}.cfg"
  cat >"$auth_config" <<EOF
header = "Authorization: Bearer ${DRONE_TOKEN}"
EOF
  chmod 600 "$auth_config"

  status=$(curl -sS -o /dev/null -w '%{http_code}' -K "$auth_config" \
    -X PATCH "${DRONE_SERVER}/api/repos/${DRONE_REPO}/secrets/${name}" \
    -H 'Content-Type: application/json' \
    --data "@${body_file}")

  if [ "$status" = "404" ]; then
    status=$(curl -sS -o /dev/null -w '%{http_code}' -K "$auth_config" \
      -X POST "${DRONE_SERVER}/api/repos/${DRONE_REPO}/secrets" \
      -H 'Content-Type: application/json' \
      --data "@${body_file}")
  fi

  case "$status" in
  200 | 201) ;;
  *)
    echo "drone-reseed-secrets: setting secret '${name}' failed (HTTP ${status})" >&2
    return 1
    ;;
  esac
}

set_secret "$SECRET_ACCESS_KEY_ID_NAME" "$access_key_id_file"
set_secret "$SECRET_SECRET_ACCESS_KEY_NAME" "$secret_access_key_file"

echo "drone-reseed-secrets: reseeded ${SECRET_ACCESS_KEY_ID_NAME} and ${SECRET_SECRET_ACCESS_KEY_NAME} on ${DRONE_REPO}"
