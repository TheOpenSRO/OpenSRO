#!/bin/bash
# Round 785: samples what the X server actually shows of a window while a
# command runs -- the presented frames, not the movie writer's. Run inside the
# X session that hosts the command (qa_shot.sh puts it after xwl_run.sh when
# QA_SHOT_XCAPTURE names a directory):
#
#   xcapture.sh <dir> <command> [args...]
#
# Starts the command, waits for its first window (xdotool search --pid), then
# grabs that window with xwd as fast as it can until the command exits. Each
# grab is <dir>/c<unix ns at the grab's start>.xwd; xcapture_series.py turns
# them into a per-grab series (what the screen showed, and when). The movie
# writer (--write-movie) cannot answer "what did the player see, for how
# long": it reads each frame back synchronously, which a real run never does,
# and under the separate render thread presentation is the render thread's.
#
# QA_XCAPTURE_START=<seconds> skips grabs until that long after start (a
# world takes ~15 s to come up); QA_XCAPTURE_SECONDS=<n> stops grabbing after
# n seconds of grabbing (the command keeps running); QA_XCAPTURE_SLEEP=<s>
# pauses between grabs (a grab alone takes ~4 ms at 640x360). Grabs are ~0.9 MB
# each at 640x360; delete the directory when done (/var/tmp is the box's disk).
set -u
dir="$1"; shift
mkdir -p "$dir"
"$@" &
pid=$!
start=$(date +%s)
win=""
for _ in $(seq 1 600); do
  win=$(xdotool search --pid "$pid" 2>/dev/null | head -1)
  [ -n "$win" ] && break
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
done
if [ -z "$win" ]; then
  echo "xcapture: no window for pid $pid -- nothing grabbed" >&2
  wait "$pid"; exit $?
fi
echo "xcapture: grabbing window $win of pid $pid into $dir" >&2
from=$((start + ${QA_XCAPTURE_START:-0}))
until_s=""
n=0
while kill -0 "$pid" 2>/dev/null; do
  now=$(date +%s)
  if [ "$now" -lt "$from" ]; then sleep 0.2; continue; fi
  [ -z "$until_s" ] && until_s=$((now + ${QA_XCAPTURE_SECONDS:-60}))
  [ "$now" -ge "$until_s" ] && break
  t=$(date +%s%N)
  xwd -silent -id "$win" > "$dir/c$t.xwd" 2>/dev/null || rm -f "$dir/c$t.xwd"
  n=$((n + 1))
  [ -n "${QA_XCAPTURE_SLEEP:-}" ] && sleep "$QA_XCAPTURE_SLEEP"
done
echo "xcapture: $n grab(s) in $dir" >&2
wait "$pid"
