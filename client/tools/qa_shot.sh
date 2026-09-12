#!/usr/bin/env bash
# Runs the client against real pk2 archives, frames a specific place, and
# leaves the captured frames in an output directory.
#
# It exists so that checking how the world looks does not need anyone to load
# the game and walk there by hand -- see the QA screenshot harness in
# client/scripts/World3D.gd for the hooks it drives.
#
# Usage:
#   qa_shot.sh --region 98\\168.m --at 960,830 --yaw 180 --frames 120 --out /var/tmp/shot
#
# Options (all optional except --out):
#   --scene <res://>  boot this scene instead of the world -- a front-end
#                     screen like res://scenes/Login.tscn (region/camera
#                     hooks are ignored; Media.pk2 is still available)
#   --region <path>   region .m to load, e.g. '98\168.m'   (default 98\168.m)
#   --at x,z          region-local spot to stand at
#   --yaw deg         camera yaw, 0 looks along +Z
#   --pitch deg       camera pitch, -90 straight down
#   --dist n          camera distance
#   --walk deg        walk continuously on this heading
#   --frames n        frames to render (default 120)
#   --size WxH        render size (default 1280x720)
#   --radius n        load an n-region radius instead of the default 2
#   --shots "..."     visit several viewpoints in one run (see below)
#   --panels "a,b,c"  open these HUD windows (ids from HudPanels.PANELS)
#   --worldmap [mode] open the world map window; mode "world" or "both"
#   --gender g        the gender a character created for --server is given
#                     (china_man or china_woman)
#   --attack          attack the nearest monster every second (needs --server)
#   --debug           open the debug panel (F3) once the first region loads
#   --columns "x,z;.." report what the walkable graph knows at these columns
#   --nofog           disable fog, for high overview shots
#   --free            let the camera pass through geometry
#   --out <dir>       where to write frames (required)
#
# Startup dominates a run -- roughly 65 seconds of loading against 0.33
# seconds a frame -- so six pictures as six runs pays that six times.
# --shots pays it once, visiting each viewpoint in one boot:
#
#   --shots "square@1002,1020:0,-25,700;gate@1062,1600:0,0,40"
#
# Each viewpoint prints "QA SHOT <name> frame <n>" in the log; pull that
# numbered frame out of the output directory.
#
# Environment: CLIENT_DIR and PK2_DIR default to the RE box's own layout.
set -euo pipefail

CLIENT_DIR="${CLIENT_DIR:-/opt/srrevamp-client}"
PK2_DIR="${PK2_DIR:-/opt/sro-files/client}"
GODOT="${GODOT:-/opt/godot-bin/Godot_v4.2.2-stable_linux.x86_64}"

REGION='98\168.m'; FRAMES=120; SIZE=1280x720; OUT=""; SCENE="res://scenes/World3D.tscn"
AT=""; YAW=""; PITCH=""; DIST=""; WALK=""; NOFOG=""; FREE=""; RADIUS=""; SHOTS=""
PANELS=""; WORLDMAP=""; SAY=""; SERVER=""; GENDER=""; ATTACK=""; DEBUG=""; COLUMNS=""; SERVER_BIN="${SERVER_BIN:-/opt/srrevamp-server/srrevamp-server}"

while [ $# -gt 0 ]; do
  case "$1" in
    # Boot a scene other than the world -- a front-end screen (Login,
    # CharacterSelect). The region/AT/camera hooks are then ignored; the
    # Media.pk2 env is still exported so the screen loads its real art.
    --scene)  SCENE="$2";  shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --at)     AT="$2";     shift 2 ;;
    --yaw)    YAW="$2";    shift 2 ;;
    --pitch)  PITCH="$2";  shift 2 ;;
    --dist)   DIST="$2";   shift 2 ;;
    --walk)   WALK="$2";   shift 2 ;;
    --frames) FRAMES="$2"; shift 2 ;;
    --size)   SIZE="$2";   shift 2 ;;
    --out)    OUT="$2";    shift 2 ;;
    --radius) RADIUS="$2"; shift 2 ;;
    --shots)  SHOTS="$2";  shift 2 ;;
    --panels) PANELS="$2"; shift 2 ;;
    # bare: the map for wherever the player is; "world": the whole world;
    # "both": the city map, then the world part way through the run.
    --worldmap)
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then WORLDMAP="$2"; shift 2
      else WORLDMAP=1; shift; fi ;;
    # --server with no value starts SERVER_BIN in-memory on a spare port and
    # signs in to it; --server host:port uses one that is already running.
    --say)    SAY="$2";    shift 2 ;;
    --gender) GENDER="$2"; shift 2 ;;
    --attack) ATTACK=1;    shift ;;
    --debug)  DEBUG=1;     shift ;;
    --columns) COLUMNS="$2"; shift 2 ;;
    --server)
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then SERVER="$2"; shift 2
      else SERVER="start"; shift; fi ;;
    --nofog)  NOFOG=1;     shift ;;
    --free)   FREE=1;      shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] || { echo "--out is required" >&2; exit 2; }

# Never leave a previous run behind: two clients at once exhausted the RE box's
# memory once already, and -- the flaky-startup cause -- leftovers from a killed
# run made the next one fail. Killing only "Godot_v4.2.2-stable_linux" both
# missed the Xvfb that xvfb-run spawns AND matched xvfb-run's own command line
# (its args carry the godot path), so xvfb-run was SIGKILLed before it could
# tear its Xvfb down. Stray Xvfb servers then piled up, and a stale in-memory
# server still holding the fixed port kept the next server from binding -- so
# the client connected to nothing and hung. Reap the whole stack: the godot
# binary (by its real path, not the wrapper), any prior xvfb-run, every leftover
# Xvfb, and any stale in-memory QA server.
pkill -9 -f "godot-bin/Godot_v4.2.2" 2>/dev/null || true
pkill -9 -f "xvfb-run" 2>/dev/null || true   # only prior ones; ours starts below
pkill -9 -x Xvfb 2>/dev/null || true
pkill -9 -f "srrevamp-server -in-memory" 2>/dev/null || true
sleep 1
rm -rf "$OUT"; mkdir -p "$OUT"

# A full disk does not fail a render: the movie writer keeps going and
# writes 0-byte frames, and nothing says so until they are opened. Frame
# dumps are the usual culprit -- a day's QA runs left 8 GB of them here --
# so say it up front, and say what to delete.
free_kb=$(df -Pk "$OUT" | awk 'NR==2 {print $4}')
if [ "${free_kb:-0}" -lt 2000000 ]; then
  echo "qa_shot: only $((free_kb / 1024)) MB free under $OUT -- frames will come out EMPTY on a full disk." >&2
  echo "qa_shot: old frame directories under $(dirname "$OUT") are regenerable; delete them first." >&2
fi

cd "$CLIENT_DIR"

# Hardware GL when the machine can offer it, software when it cannot.
#
# Godot's Linux OpenGL backend draws through GLX on X11, and Xvfb has no
# DRI, so a GPU sitting in the machine goes unused and every frame is
# rasterised on the CPU -- which is why a screenshot used to cost minutes.
# VirtualGL bridges the two: it services GLX through EGL on the render
# node, and glxinfo then reports the real card instead of llvmpipe.
VGL=""
if command -v vglrun >/dev/null && [ -e /dev/dri/renderD128 ] && [ -r /dev/dri/renderD128 ]; then
  VGL="vglrun -d egl0"
  echo "qa_shot: hardware GL via VirtualGL on /dev/dri/renderD128" >&2
else
  export LIBGL_ALWAYS_SOFTWARE=1
  echo "qa_shot: no usable render node -- falling back to software GL (slow)" >&2
fi
export SRREVAMP_PK2_PATH="$PK2_DIR/Data.pk2"
export SRREVAMP_MAP_PK2_PATH="$PK2_DIR/Map.pk2"
export SRREVAMP_MEDIA_PK2_PATH="$PK2_DIR/Media.pk2"
export SRREVAMP_MAPM_PATH="$REGION"
[ -n "$AT" ]    && export SRREVAMP_QA_AT="$AT"
[ -n "$YAW" ]   && export SRREVAMP_QA_YAW="$YAW"
[ -n "$PITCH" ] && export SRREVAMP_QA_PITCH="$PITCH"
[ -n "$DIST" ]  && export SRREVAMP_QA_DIST="$DIST"
[ -n "$WALK" ]  && export SRREVAMP_QA_WALK="$WALK"
[ -n "$NOFOG" ] && export SRREVAMP_QA_NOFOG=1
[ -n "$FREE" ]  && export SRREVAMP_QA_FREE=1
[ -n "$RADIUS" ] && export SRREVAMP_QA_RADIUS="$RADIUS"
[ -n "$SHOTS" ]  && export SRREVAMP_QA_SHOTS="$SHOTS"
[ -n "$PANELS" ] && export SRREVAMP_QA_PANELS="$PANELS"
[ -n "$WORLDMAP" ] && export SRREVAMP_QA_WORLDMAP="$WORLDMAP"

# A render with a server behind it. Without one the client shows an
# undressed character, a blank HP bar and an empty inventory, because none
# of that is the client's to know.
if [ "$SERVER" = "start" ]; then
  if [ ! -x "$SERVER_BIN" ]; then
    echo "qa_shot: no server binary at $SERVER_BIN (set SERVER_BIN)" >&2
    exit 1
  fi
  SERVER_PORT="${SERVER_PORT:-15899}"
  "$SERVER_BIN" -in-memory -addr "127.0.0.1:$SERVER_PORT" >"$OUT/server.log" 2>&1 &
  SERVER_PID=$!
  # SIGKILL, not SIGTERM: the in-memory server did not always die on TERM, so
  # servers piled up on the port between runs (the startup reap above now clears
  # them, but do not leave them behind in the first place).
  trap 'kill -9 "$SERVER_PID" 2>/dev/null || true' EXIT
  # Wait for the server to actually be listening -- and fail loudly if it is
  # not, rather than launch a client that connects to nothing and hangs (the
  # symptom that read as "flaky startup"). Stop early if the server dies.
  server_ready=""
  for _ in $(seq 1 50); do
    if grep -q "gateway listening" "$OUT/server.log" 2>/dev/null; then server_ready=1; break; fi
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.2
  done
  if [ -z "$server_ready" ]; then
    echo "qa_shot: in-memory server never reported 'gateway listening' (port $SERVER_PORT busy, or it crashed) -- see $OUT/server.log" >&2
    kill -9 "$SERVER_PID" 2>/dev/null || true
    exit 1
  fi
  echo "qa_shot: in-memory server on 127.0.0.1:$SERVER_PORT (pid $SERVER_PID)" >&2
  SERVER="127.0.0.1:$SERVER_PORT"
fi
[ -n "$SERVER" ] && export SRREVAMP_QA_SERVER="$SERVER"
[ -n "$SAY" ] && export SRREVAMP_QA_SAY="$SAY"
[ -n "$GENDER" ] && export SRREVAMP_QA_GENDER="$GENDER"
[ -n "$ATTACK" ] && export SRREVAMP_QA_ATTACK=1
[ -n "$DEBUG" ] && export SRREVAMP_QA_DEBUG=1
[ -n "$COLUMNS" ] && export SRREVAMP_QA_COLUMNS="$COLUMNS"

# --resolution as well as the X screen: Godot renders at the project's own
# window size otherwise, so asking for a square screen alone still produced
# 16:9 frames -- which quietly ruins any comparison against square authored
# art like a region minimap.
xvfb-run -a -s "-screen 0 ${SIZE}x24" $VGL "$GODOT" \
  --rendering-driver opengl3 --resolution "$SIZE" --path . "$SCENE" \
  --write-movie "$OUT/f.png" --quit-after "$FRAMES"
