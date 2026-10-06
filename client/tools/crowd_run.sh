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
DIR="$1"; LOG="$2"; N="$3"; STEPS="$4"; shift 4
PK2_DIR="${PK2_DIR:-/opt/sro-files/client}"
GODOT="${GODOT:-/opt/godot-bin/Godot_v4.2.2-stable_linux.x86_64}"
export OPENSRO_PK2_PATH=$PK2_DIR/Data.pk2 OPENSRO_MAP_PK2_PATH=$PK2_DIR/Map.pk2 OPENSRO_MEDIA_PK2_PATH=$PK2_DIR/Media.pk2
export OPENSRO_PARTICLES_PK2_PATH=$PK2_DIR/Particles.pk2 OPENSRO_MUSIC_PK2_PATH=$PK2_DIR/Music.pk2
export OPENSRO_MAPM_PATH='97\168.m' OPENSRO_QA_AT=1002,1020 OPENSRO_QA_YAW=0 OPENSRO_QA_LOCAL_NPCS=1
export OPENSRO_QA_LINEUP=all OPENSRO_QA_LINEUP_COUNT=$N OPENSRO_QA_LINEUP_PLUS=13 OPENSRO_QA_LINEUP_COLUMNS=40
export OPENSRO_QA_LINEUP_SPACING=8,10 OPENSRO_QA_LINEUP_PHASE=100000 OPENSRO_QA_DIST=90 OPENSRO_QA_PITCH=-15
export OPENSRO_QA_CROWD_STEPS="$STEPS" OPENSRO_QA_CROWD_SECONDS=6 OPENSRO_QA_CROWD_QUIT=1
for kv in "$@"; do export "$kv"; done
others() { pgrep -af "^$GODOT" | grep -v -- "--path $DIR " | wc -l; }
for i in $(seq 1 360); do [ "$(others)" = 0 ] && break; sleep 5; done
rm -f "$LOG.others"
( while :; do n=$(others); [ "$n" -gt 0 ] && echo "$n" >> "$LOG.others"; sleep 2; done ) & W=$!
timeout -k 10 1500 "$DIR/tools/xwl_run.sh" -s 1920x1080 "$GODOT" --rendering-method forward_plus --rendering-driver vulkan \
  --resolution 1920x1080 --path "$DIR" res://scenes/World3D.tscn --quit-after 400000 --print-fps --disable-vsync > "$LOG" 2>&1
kill $W 2>/dev/null
echo "== $LOG n=$N overlap: $(sort -n "$LOG.others" 2>/dev/null | tail -1 | grep . || echo 0)"
rm -f "$LOG.others"
grep -m1 -E "^(Vulkan|OpenGL) API" "$LOG"
grep -E "LINEUP: |QA CROWD (step|arrival|census: all|net)|other player bod|SCRIPT ERROR" "$LOG" | head -60
