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
# A MISS IS WHEN THE INDEX IS MOST USEFUL, so print it on the way out.
#
# Round 407 probed "log string naming", got nothing, went to the dump, and
# rebuilt a module map that `docs/protocol/source_files.tsv` had already held
# for weeks -- with the original `D:\WORK2005\...` paths this round could not
# recover. Round 331 had already written the fix down: "LIST docs/protocol
# FIRST; the file names are the index." That lesson sat in the RE_COMPLETION
# ledger and never reached this tool or docs/RE_LOOP.md, so it could not be
# obeyed by anyone who had not read that round.
#
# A FILENAME GREP WOULD NOT HAVE SAVED IT EITHER -- no sensible phrasing of
# "module map" matches "source_files.tsv". Only reading the names does. So the
# tool fails loudly: zero hits prints every artifact, because the operator is
# about to spend a tick and this is the last cheap moment to notice.
if [ $status -ne 0 ]; then
  echo
  echo "=== NOTHING KNOWN. Before going to the dump, read the artifact index:"
  ls "$root/docs/protocol" 2>/dev/null | column -c 100 2>/dev/null \
    || ls "$root/docs/protocol" 2>/dev/null
  echo "=== ^ a file name is often the answer a phrase search cannot match."
fi
# Exit 0 when SOMETHING is known -- so `tools/known.sh foo && echo "read it first"`
# reads the way the rule does.
exit $status
