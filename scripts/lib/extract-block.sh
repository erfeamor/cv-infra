#!/usr/bin/env bash
# Shared by scripts/check-t007-static.sh and scripts/check-t008-static.sh
# (T-007 review round 1, finding 10 -- the two scripts had grown identical
# copies of this function). Not used by bootstrap/check-static.sh: that
# script's own extract_block additionally strips /* */ block comments
# (bootstrap/state-backend.tf's style differs enough that duplicating that
# extra handling here isn't warranted, and bootstrap/ is a separate root
# module on purpose -- see cv-infra/CLAUDE.md's Layout section).
#
# Reads HCL-ish text on stdin, strips `#` comments, and prints the first
# brace-balanced block whose opening line matches the given (already
# ^-anchored) regex. Not a real HCL parser -- good enough for this
# codebase's style, which is grep-confirmed to use no /* */ comments.
extract_block() {
  awk -v pat="$1" '
    BEGIN { depth = 0; found = 0 }
    {
      line = $0
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
