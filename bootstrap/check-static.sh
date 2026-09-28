#!/usr/bin/env bash
# T-004 review round 1, finding 3 (round 2, finding 5): `terraform test`
# cannot see lifecycle meta-arguments (they never appear in plan output),
# so prevent_destroy on the state bucket is checked here instead -- part
# of this module's gate, run alongside fmt/validate/test (see
# cv-infra/CLAUDE.md and bootstrap/README.md).
#
# Round 1's version was a bare `grep -n prevent_destroy` over the whole
# file: it matched this file's own comments, AND it would have passed just
# as happily if `prevent_destroy = true` moved to a *different* resource
# (e.g. the lock table) -- neither is what the check claims to verify.
# This version is scoped to exactly resource "aws_s3_bucket" "tfstate"'s
# own body (brace-balanced, so nested blocks like `tags {}` don't confuse
# it), with `#` and `/* */` comments stripped first, and only then
# requires an uncommented `lifecycle { prevent_destroy = true }` inside
# that specific block.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

FILE=state-backend.tf

# Reads HCL-ish text on stdin, strips `#` and `/* ... */` comments, and
# prints the first brace-balanced block whose opening line matches the
# given (already ^-anchored) regex. Not a real HCL parser -- good enough
# for this one file, whose style is known.
extract_block() {
  awk -v pat="$1" '
    BEGIN { depth = 0; found = 0; inbc = 0 }
    {
      line = $0
      while (1) {
        if (inbc) {
          e = index(line, "*/")
          if (e > 0) { line = substr(line, e + 2); inbc = 0 } else { line = ""; break }
        }
        s = index(line, "/*")
        if (s > 0) {
          rest = substr(line, s + 2)
          e2 = index(rest, "*/")
          if (e2 > 0) { line = substr(line, 1, s - 1) substr(rest, e2 + 2) }
          else { line = substr(line, 1, s - 1); inbc = 1; break }
        } else break
      }
      h = index(line, "#")
      if (h > 0) line = substr(line, 1, h - 1)

      if (!found) {
        if (line ~ pat) { found = 1; depth = 0 } else next
      }
      n = gsub(/\{/, "{", line); depth += n
      m = gsub(/\}/, "}", line); depth -= m
      print line
      if (depth == 0) exit
    }
  '
}

resource_block=$(extract_block '^resource[ \t]+"aws_s3_bucket"[ \t]+"tfstate"[ \t]*{' <"$FILE")

if [ -z "$resource_block" ]; then
  echo "FAIL: resource \"aws_s3_bucket\" \"tfstate\" { ... } not found (comments stripped) in $FILE" >&2
  exit 1
fi

lifecycle_block=$(printf '%s\n' "$resource_block" | extract_block '^[ \t]*lifecycle[ \t]*{')

if [ -z "$lifecycle_block" ] || ! printf '%s\n' "$lifecycle_block" | grep -Eq '^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true[[:space:]]*$'; then
  echo "FAIL: no uncommented 'lifecycle { prevent_destroy = true }' inside resource \"aws_s3_bucket\" \"tfstate\" in $FILE" >&2
  echo "The state bucket must refuse destroy -- see state-backend.tf's aws_s3_bucket.tfstate lifecycle block." >&2
  exit 1
fi

echo "OK: prevent_destroy = true present inside aws_s3_bucket.tfstate's lifecycle block in $FILE"
