#!/bin/bash
# known.sh <term> [more terms...] -- what does this project ALREADY know about X?
#
# Run this BEFORE going to the dump, the binary or the game tables. The standing
# rule in docs/RE_LOOP.md is "grep the docs before the dump"; rounds 370, 371 and
# 372 each broke it and each re-derived work this project had already written
# down -- the stat graph and the slot-combination rules (both recorded
# 2026-09-15), and magicoption.txt's packed tag vocabulary (recorded 2026-09-16).
#
# The rule kept being broken because obeying it meant remembering which of ~60
# docs to grep. This makes it one command.
#
# Searches every recovered-knowledge surface: the prose docs, the recovered-name
# and handler tables, and the Go sources' own citations (many findings live only
# in a doc comment next to the constant they justify).
set -u
[ $# -lt 1 ] && { echo "usage: tools/known.sh <term> [term...]"; exit 2; }

root=$(cd "$(dirname "$0")/.." && pwd)
status=1
for term in "$@"; do
  echo "=============== $term"
  for scope in "docs" "server:*.go" "client/scripts:*.gd"; do
    dir=${scope%%:*}; pat=${scope#*:}
    [ "$dir" = "$pat" ] && pat=""
    if [ -n "$pat" ]; then
      hits=$(grep -rniI --include="$pat" -- "$term" "$root/$dir" 2>/dev/null)
    else
      hits=$(grep -rniI -- "$term" "$root/$dir" 2>/dev/null)
    fi
    [ -z "$hits" ] && continue
    status=0
    n=$(printf '%s\n' "$hits" | wc -l)
    echo "--- $dir ($n)"
    printf '%s\n' "$hits" | sed "s|$root/||" | cut -c1-160 | head -12
    [ "$n" -gt 12 ] && echo "    ... $((n-12)) more"
  done
done
# Exit 0 when SOMETHING is known -- so `tools/known.sh foo && echo "read it first"`
# reads the way the rule does.
exit $status
