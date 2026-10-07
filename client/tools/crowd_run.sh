#!/bin/bash
# One crowd-probe boot on the render box (round 739): r736's QaCrowdProbe recipe at the Jangan
# spawn, 1920x1080 Forward+, with a wait for no other lane's Godot and an overlap count.
#
#   flock /var/tmp/godot-lock/lock crowd_run.sh <client dir> <log> <n> <steps> [VAR=value ...]
#
# Run it ON THE BOX, under the box lock, from a shipped client (remote_godot.sh check first).
# <steps> is OPENSRO_QA_CROWD_STEPS (QaCrowdProbe's header); extra VAR=value pairs override the
# recipe (OPENSRO_QA_VIDEO=shadow_detail=2, OPENSRO_QA_LINEUP_SPACING=30,30, ...). It prints
# `== <log> n=<n> overlap: <max other Godots seen>` -- a boot with overlap above 0 shared the CPU
# with another lane and is to be repeated -- then the renderer banner and the probe's lines
# (LINEUP, QA CROWD arrival / census / step / net, the pump's drain line). Logs go where <log>
# says: keep them under /var/tmp, never /tmp (tmpfs), and delete them after.
# Round 757: CROWD_SAMPLE=1 adds per-step thread / core / GPU lines (crowd_threads.py),
# CROWD_GODOT_ARGS adds Godot arguments (`--render-thread separate`), CROWD_NOWAIT=1 skips the
# wait for other lanes (error-count runs only), CROWD_TIMEOUT sets the run's limit (1500 s).
DIR="$1"; LOG="$2"; N="$3"; STEPS="$4"; shift 4
PK2_DIR="${PK2_DIR:-/opt/sro-files/client}"
GODOT="${GODOT:-/opt/godot-bin/Godot_v4.2.2-stable_linux.x86_64}"
export OPENSRO_PK2_PATH=$PK2_DIR/Data.pk2 OPENSRO_MAP_PK2_PATH=$PK2_DIR/Map.pk2 OPENSRO_MEDIA_PK2_PATH=$PK2_DIR/Media.pk2
export OPENSRO_PARTICLES_PK2_PATH=$PK2_DIR/Particles.pk2 OPENSRO_MUSIC_PK2_PATH=$PK2_DIR/Music.pk2
export OPENSRO_MAPM_PATH='97\168.m' OPENSRO_QA_AT=1002,1020 OPENSRO_QA_YAW=0 OPENSRO_QA_LOCAL_NPCS=1
export OPENSRO_QA_LINEUP=all OPENSRO_QA_LINEUP_COUNT=$N OPENSRO_QA_LINEUP_PLUS=13 OPENSRO_QA_LINEUP_COLUMNS=40
export OPENSRO_QA_LINEUP_SPACING=8,10 OPENSRO_QA_LINEUP_PHASE=100000 OPENSRO_QA_DIST=90 OPENSRO_QA_PITCH=-15
export OPENSRO_QA_CROWD_STEPS="$STEPS" OPENSRO_QA_CROWD_SECONDS=6 OPENSRO_QA_CROWD_QUIT=1
# Round 759: CROWD_LIVE=<host:port> signs in to a running server instead of the lineup
# (OPENSRO_QA_LINEUP=none: the probe measures the server's crowd, QaCrowdProbe.live), with
# OPENSRO_QA_ACCOUNT / OPENSRO_QA_CHARACTER from the caller (never a GM account). No QA_AT and
# no local NPCs: the player stands where the server put it, the server's NPCs. <n> is ignored.
if [ -n "${CROWD_LIVE:-}" ]; then
  export OPENSRO_QA_SERVER="$CROWD_LIVE" OPENSRO_QA_LINEUP=none
  unset OPENSRO_QA_AT OPENSRO_QA_LOCAL_NPCS OPENSRO_QA_LINEUP_COUNT
fi
for kv in "$@"; do export "$kv"; done
# Round 756: any lane's Godot (the 4.7.2 spike's binary too) or xvfb-run counts, not only this
# binary's -- the box's rule for a measurement run. By process name, not command line: a run
# waiting on the box lock names the Godot binary in its arguments without running it.
others() { pgrep -a '^(Godot_v4|xvfb-run)' | grep -v -- "--path $DIR " | wc -l; }
# CROWD_NOWAIT=1 (round 757): no wait for the other lanes -- a run that counts
# errors or events, not time.
[ "${CROWD_NOWAIT:-0}" = 1 ] || for i in $(seq 1 360); do [ "$(others)" = 0 ] && break; sleep 5; done
rm -f "$LOG.others"
( while :; do n=$(others); [ "$n" -gt 0 ] && echo "$n" >> "$LOG.others"; sleep 2; done ) & W=$!
# Round 757: CROWD_SAMPLE=1 also samples the client's threads, the box's cores (crowd_threads.py)
# and the GPU (gpu_sample) for the run, and prints one `QA THREADS` line per step.
if [ "${CROWD_SAMPLE:-0}" = 1 ]; then
  rm -f "$LOG.threads" "$LOG.gpu"
  python3 "$DIR/tools/crowd_threads.py" sample "$DIR" "$LOG.threads" 0.5 & SP=$!
  gpu_sample 3000 > "$LOG.gpu" 2>/dev/null & GP=$!
fi
timeout -k 10 "${CROWD_TIMEOUT:-1500}" "$DIR/tools/xwl_run.sh" -s 1920x1080 "$GODOT" --rendering-method forward_plus --rendering-driver vulkan \
  --resolution 1920x1080 --path "$DIR" res://scenes/World3D.tscn --quit-after 400000 --print-fps --disable-vsync ${CROWD_GODOT_ARGS:-} > "$LOG" 2>&1
kill $W 2>/dev/null
if [ "${CROWD_SAMPLE:-0}" = 1 ]; then
  kill $SP 2>/dev/null; pkill -P $GP 2>/dev/null; kill $GP 2>/dev/null
fi
echo "== $LOG n=$N overlap: $(sort -n "$LOG.others" 2>/dev/null | tail -1 | grep . || echo 0)"
rm -f "$LOG.others"
grep -m1 -E "^(Vulkan|OpenGL) API" "$LOG"
grep -E "QA sign-in|QA LIVE|LINEUP: |QA CROWD (step|split|arrival|visible|page|plates|ghostcheck|census: all|census: equipment|net)|other player bod|QA DRESS|QA GHOSTS|QA BUFFS|QA RUNAT|ghost\(s\) drawn|QA EQUIPFX master|SCRIPT ERROR" "$LOG" | head -400
if [ "${CROWD_SAMPLE:-0}" = 1 ]; then
  python3 "$DIR/tools/crowd_threads.py" report "$LOG" "$LOG.threads" "$LOG.gpu"
fi
