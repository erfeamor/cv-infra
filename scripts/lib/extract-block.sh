#!/usr/bin/env bash
# extract_block: print one brace-balanced HCL block (the line matching $1 through
# its closing brace) from stdin, with `#` comments stripped. Sourced by
# scripts/check-static.sh.
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
