#!/bin/bash
# Runs on the render box: every test suite in the list on stdin, headless,
# JOBS at a time. `remote_godot.sh tests` calls it once, holding the lane's lock.
#
#   run_suites.sh <client dir> <godot binary> <jobs> <timeout seconds>  < list
#
# Until 2026-09-30 `tests` ran the suites one at a time, each through its own
# ssh, su and lock: 167 suites took a median 318 s, and a batch of rounds ran
# the whole list many times. The suites are headless (no GPU) and the box has
# 10 cores, so they run side by side here. A suite fails on a non-zero exit
# (124: the timeout) or on its own FAIL, FAILURES, Parse Error or SCRIPT ERROR
# lines, exactly as before; the output keeps `remote_godot.sh`'s wording.
set -uo pipefail
dir="$1" godot="$2" jobs="$3" limit="$4"
out="$(mktemp -d /var/tmp/suites.XXXXXX)"
trap 'rm -rf "$out"' EXIT
cat > "$out/list"

run1() {
  local f="$1" key
  key="$(echo "$f" | tr '/' '_')"
  timeout -k 10 "$limit" "$godot" --headless --path "$dir" --script "res://$f" > "$out/$key.log" 2>&1
  echo $? > "$out/$key.rc"
}
export -f run1
export dir godot limit out
xargs -a "$out/list" -P "$jobs" -I{} bash -c 'run1 "$1"' _ {}

fail_re='FAIL|FAILURES|Parse Error|SCRIPT ERROR'
count=0
failed=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  count=$((count + 1))
  key="$(echo "$f" | tr '/' '_')"
  rc="$(cat "$out/$key.rc" 2>/dev/null || echo missing)"
  log="$out/$key.log"
  if [ "$rc" != 0 ] || grep -qE "$fail_re" "$log"; then
    echo "FAILED: res://$f"
    if ! grep -qE "$fail_re" "$log"; then
      echo "  (no FAIL line: the run exited $rc -- 124 is a timeout after $limit s)"
    fi
    grep -E "FAIL|Parse Error" "$log" | head -5 || true
    grep -E -A1 "SCRIPT ERROR" "$log" | head -10 || true
    failed=$((failed + 1))
  fi
done < "$out/list"
echo "ran $count suite(s), $failed failing"
[ "$failed" -eq 0 ]
