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
#   --panels-in-place leave them where they place themselves (the main
#                     popup's tab side) instead of centring/tiling them
#   --worldmap [mode] open the world map window; mode "world" or "both"
#   --gender g        the gender a character created for --server is given
#                     (china_man or china_woman)
#   --attack          attack the nearest monster every second (needs --server)
#                     A --server run whose question is about the GROUND under a
#                     monster or another player passes the zone's own centre as
#                     --region ('97\168.m' for Jangan): the world is centred on
#                     --region (default 98\168.m) before the session is looked
#                     at, and the server's coordinates are in the zone-centre
#                     frame, so the default drew a Jangan monster on 98/168's
#                     ground (round 557; _qa_columns_report says the same).
#   --teleport <id>   (round 578; needs --server and OPENSRO_QA_CLICK=gate)
#                     once the gate's talk box is up, choose its teleport
#                     line, then click the talk box's destination line for
#                     this teleportdata id (round 603; 2 = Donwhang from
#                     Jangan): the log carries
#                     `QA TELEPORT: requested <gate> -> <id>`, the receipt,
#                     and the arrival's second region grid
#   --debug           open the debug panel (F3) once the first region loads
#   --columns "x,z;.." report what the walkable graph knows at these columns
#   --equip "s=id,.." dress the player (no server) from a "slot=item_id"
#                     loadout, e.g. "1=3637,4=3638,5=3639,6=3632"
#   --nofog           disable fog, for high overview shots
#   --free            let the camera pass through geometry
#   --reconnect <when> leave the world and re-enter it in the SAME process --
#                     the tester's "disconnect and reconnect without closing
#                     the client", after which the ground was white (round
#                     558). <when> is a QA tick (60 a second of game time,
#                     one a movie frame) or "drain", the first tick that
#                     finds the entry's loading screen up, i.e. a drop while
#                     the world is still loading. Exports
#                     OPENSRO_QA_FORCE_LOADING=1 (both entries take the
#                     real loading-screen drain; the QA path would build the
#                     grid in one frame and "drain" could never fire) and
#                     OPENSRO_QA_NOUI=1 (the run's product is a frame-colour
#                     statistic over the lower part of the picture, where
#                     the chat log and hotbar sit). Every OPENSRO_QA_* hook
#                     re-arms on the second entry, so --shots names each
#                     viewpoint twice: `QA SHOT <name> frame <n>` once per
#                     entry, and each entry prints `QA ENTRY <n> ...` and
#                     `QA TEXPROBE <n> ...` lines to grep (World3D.gd's QA
#                     header). Direct by default: World3D -> World3D.
#   --reconnect-via-login  route the reconnect the way a tester's goes:
#                     World3D -> Login -> CharacterSelect -> World3D, the
#                     front-end screens signing back in with the QA account
#                     (needs --server)
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
#
# RENDERER (round 693): forward_plus or gl_compatibility; unset, the client
# copy's own project.godot decides (Forward+ from round 693), as a plain
# launch would. Forward+ runs on Vulkan through tools/xwl_run.sh (a private
# headless weston + Xwayland, which RADV can present to; Xvfb cannot --
# docs/RENDER_BOX.md, "Vulkan (Forward+)"); QA_VK_PRESENT=sw runs it on Xvfb
# with Mesa's software presentation instead (correct frames, but ~17 ms of
# CPU copy a 1280x720 frame: never for timings). gl_compatibility runs as
# before, VirtualGL on Xvfb. The run's own banner (`Vulkan API ... - Forward+
# - Using Vulkan Device #0: ...` or `OpenGL API ... - Compatibility - ...`) is
# repeated on stderr at the end, and a run that landed on llvmpipe says so.
#
# QA_SHOT_REAP=0 (round 693) skips the start-up reap below: for a lane that
# runs under its own GODOT_LOCK, where killing every Godot on the box would
# kill other lanes' runs.
set -euo pipefail

# One run at a time on this box. The startup below kills every running
# Godot/Xvfb, so two runs launched together would kill each other; instead
# the second waits for the first. Taken by re-executing under flock, so the
# whole run (kill, server, client, frames) happens inside the lock.
GODOT_LOCK="${GODOT_LOCK:-/var/tmp/godot-lock/lock}"
if [ -z "${QA_SHOT_LOCKED:-}" ]; then
  mkdir -p "$(dirname "$GODOT_LOCK")" 2>/dev/null || true
  exec env QA_SHOT_LOCKED=1 flock "$GODOT_LOCK" "$0" "$@"
fi

CLIENT_DIR="${CLIENT_DIR:-/opt/opensro-client}"
PK2_DIR="${PK2_DIR:-/opt/sro-files/client}"
GODOT="${GODOT:-/opt/godot-bin/Godot_v4.2.2-stable_linux.x86_64}"

REGION='98\168.m'; FRAMES=120; SIZE=1280x720; OUT=""; SCENE="res://scenes/World3D.tscn"
AT=""; YAW=""; PITCH=""; DIST=""; WALK=""; NOFOG=""; FREE=""; RADIUS=""; SHOTS=""
PANELS=""; WORLDMAP=""; SAY=""; SERVER=""; GENDER=""; ATTACK=""; DEBUG=""; COLUMNS=""; EQUIP=""; SERVER_BIN="${SERVER_BIN:-/opt/opensro-server/opensro-server}"
RECONNECT=""; RECONNECT_VIA_LOGIN=""; TELEPORT=""; PANELS_IN_PLACE=""

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
    --panels-in-place) PANELS_IN_PLACE=1; shift ;;
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
    --teleport) TELEPORT="$2"; shift 2 ;;
    --debug)  DEBUG=1;     shift ;;
    --columns) COLUMNS="$2"; shift 2 ;;
    --equip)  EQUIP="$2";  shift 2 ;;
    --server)
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then SERVER="$2"; shift 2
      else SERVER="start"; shift; fi ;;
    --nofog)  NOFOG=1;     shift ;;
    --free)   FREE=1;      shift ;;
    --reconnect) RECONNECT="$2"; shift 2 ;;
    --reconnect-via-login) RECONNECT_VIA_LOGIN=1; shift ;;
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
if [ "${QA_SHOT_REAP:-1}" != 0 ]; then
pkill -9 -f "godot-bin/Godot_v4.2.2" 2>/dev/null || true
pkill -9 -f "xvfb-run" 2>/dev/null || true   # only prior ones; ours starts below
pkill -9 -x Xvfb 2>/dev/null || true
# Forward+ runs (round 693) sit on xwl_run.sh's weston + Xwayland instead.
pkill -9 -f "tools/xwl_run.sh" 2>/dev/null || true
pkill -9 -x weston 2>/dev/null || true
pkill -9 -x Xwayland 2>/dev/null || true
pkill -9 -f "opensro-server -in-memory" 2>/dev/null || true
sleep 1
fi
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
# The renderer (round 693): RENDERER, else the project's own setting.
RENDERER="${RENDERER:-$(sed -n 's/^renderer\/rendering_method="\([a-z_]*\)"$/\1/p' project.godot | head -1)}"
RENDERER="${RENDERER:-forward_plus}"   # Godot's own default when the file sets none
case "$RENDERER" in
  forward_plus|gl_compatibility) ;;
  *) echo "qa_shot: RENDERER must be forward_plus or gl_compatibility, not '$RENDERER'" >&2; exit 2 ;;
esac
VGL=""
if [ "$RENDERER" = gl_compatibility ]; then
  if command -v vglrun >/dev/null && [ -e /dev/dri/renderD128 ] && [ -r /dev/dri/renderD128 ]; then
    VGL="vglrun -d egl0"
    echo "qa_shot: Compatibility renderer, hardware GL via VirtualGL on /dev/dri/renderD128" >&2
  else
    export LIBGL_ALWAYS_SOFTWARE=1
    echo "qa_shot: no usable render node -- falling back to software GL (slow)" >&2
  fi
fi
export OPENSRO_PK2_PATH="$PK2_DIR/Data.pk2"
export OPENSRO_MAP_PK2_PATH="$PK2_DIR/Map.pk2"
export OPENSRO_MEDIA_PK2_PATH="$PK2_DIR/Media.pk2"
export OPENSRO_PARTICLES_PK2_PATH="$PK2_DIR/Particles.pk2"
# Music.pk2 holds the zone music (round 611, AudioBank); without it the world is silent.
export OPENSRO_MUSIC_PK2_PATH="$PK2_DIR/Music.pk2"
export OPENSRO_MAPM_PATH="$REGION"
[ -n "$AT" ]    && export OPENSRO_QA_AT="$AT"
[ -n "$YAW" ]   && export OPENSRO_QA_YAW="$YAW"
[ -n "$PITCH" ] && export OPENSRO_QA_PITCH="$PITCH"
[ -n "$DIST" ]  && export OPENSRO_QA_DIST="$DIST"
[ -n "$WALK" ]  && export OPENSRO_QA_WALK="$WALK"
[ -n "$NOFOG" ] && export OPENSRO_QA_NOFOG=1
[ -n "$FREE" ]  && export OPENSRO_QA_FREE=1
[ -n "$RADIUS" ] && export OPENSRO_QA_RADIUS="$RADIUS"
[ -n "$SHOTS" ]  && export OPENSRO_QA_SHOTS="$SHOTS"
[ -n "$PANELS" ] && export OPENSRO_QA_PANELS="$PANELS"
[ -n "$PANELS_IN_PLACE" ] && export OPENSRO_QA_PANELS_IN_PLACE=1
[ -n "$WORLDMAP" ] && export OPENSRO_QA_WORLDMAP="$WORLDMAP"

# A render with a server behind it. Without one the client shows an
# undressed character, a blank HP bar and an empty inventory, because none
# of that is the client's to know.
if [ "$SERVER" = "start" ]; then
  if [ ! -x "$SERVER_BIN" ]; then
    echo "qa_shot: no server binary at $SERVER_BIN (set SERVER_BIN)" >&2
    exit 1
  fi
  SERVER_PORT="${SERVER_PORT:-15899}"
  # Feed the in-memory server its refdata so the shop has items to sell (and
  # prices) and learning has skills: an items/skills CSV beside the pk2s, or
  # named explicitly. Without them the shop opens but sells nothing.
  ITEMS_CSV="${OPENSRO_ITEMS_CSV:-$PK2_DIR/items.csv}"
  SKILLS_CSV="${OPENSRO_SKILLS_CSV:-$PK2_DIR/skills.csv}"
  LEVELDATA_CSV="${OPENSRO_LEVELDATA_CSV:-$PK2_DIR/leveldata.csv}"
  # The teleport network (round 575): export-refdata -mode teleport's three
  # CSVs in a teleport/ directory beside the pk2s. The server logs its counts.
  TELEPORT_DIR="${OPENSRO_TELEPORT_DIR:-$PK2_DIR/teleport}"
  # The creatable catalogue (round 682's lobby; export-refdata -mode
  # chargen): without it the server refuses every create (S1027, "no
  # creatable catalogue loaded"), the QA sign-in renders offline and a
  # --reconnect-via-login finds no character to start (round 693).
  CHARGEN_CSV="${OPENSRO_CHARGEN_CSV:-$PK2_DIR/chargen.csv}"
  SERVER_ARGS=(-in-memory -addr "127.0.0.1:$SERVER_PORT")
  [ -f "$ITEMS_CSV" ]     && SERVER_ARGS+=(-items-csv "$ITEMS_CSV")
  [ -f "$SKILLS_CSV" ]    && SERVER_ARGS+=(-skills-csv "$SKILLS_CSV")
  [ -f "$LEVELDATA_CSV" ] && SERVER_ARGS+=(-leveldata-csv "$LEVELDATA_CSV")
  [ -f "$TELEPORT_DIR/teleportdata.csv" ] && SERVER_ARGS+=(-teleport-dir "$TELEPORT_DIR")
  if [ -f "$CHARGEN_CSV" ]; then SERVER_ARGS+=(-chargen-csv "$CHARGEN_CSV")
  else echo "qa_shot: no chargen CSV at $CHARGEN_CSV (set OPENSRO_CHARGEN_CSV) -- the server can create no character" >&2; fi
  "$SERVER_BIN" "${SERVER_ARGS[@]}" >"$OUT/server.log" 2>&1 &
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
[ -n "$SERVER" ] && export OPENSRO_QA_SERVER="$SERVER"
[ -n "$SAY" ] && export OPENSRO_QA_SAY="$SAY"
[ -n "$GENDER" ] && export OPENSRO_QA_GENDER="$GENDER"
[ -n "$ATTACK" ] && export OPENSRO_QA_ATTACK=1
[ -n "$DEBUG" ] && export OPENSRO_QA_DEBUG=1
[ -n "$COLUMNS" ] && export OPENSRO_QA_COLUMNS="$COLUMNS"
[ -n "$EQUIP" ] && export OPENSRO_QA_EQUIP="$EQUIP"
if [ -n "$TELEPORT" ]; then
  export OPENSRO_QA_TELEPORT="$TELEPORT"
  [ -n "${OPENSRO_QA_CLICK:-}" ] || echo "qa_shot: --teleport without OPENSRO_QA_CLICK=gate -- nothing opens the gate's talk box, so no Move is pressed" >&2
  [ -n "$SERVER" ] || echo "qa_shot: --teleport without --server -- the request has nobody to go to" >&2
fi
# --reconnect (round 558): both entries take the real loading-screen drain,
# and the HUD is hidden -- see the option's note in the header.
if [ -n "$RECONNECT" ]; then
  export OPENSRO_QA_RECONNECT="$RECONNECT"
  export OPENSRO_QA_FORCE_LOADING=1
  export OPENSRO_QA_NOUI=1
fi
if [ -n "$RECONNECT_VIA_LOGIN" ]; then
  export OPENSRO_QA_RECONNECT_VIA_LOGIN=1
  [ -n "$SERVER" ] || echo "qa_shot: --reconnect-via-login without --server -- Login has nothing to sign back in to, the run will stop on the login screen" >&2
fi

# --resolution as well as the X screen: Godot renders at the project's own
# window size otherwise, so asking for a square screen alone still produced
# 16:9 frames -- which quietly ruins any comparison against square authored
# art like a region minimap.
if [ "$RENDERER" = forward_plus ]; then
  if [ "${QA_VK_PRESENT:-}" = sw ]; then
    echo "qa_shot: Forward+ on Vulkan, Xvfb with Mesa's software presentation (QA_VK_PRESENT=sw: slow frames, no timings)" >&2
    LAUNCH=(xvfb-run -a -s "-screen 0 ${SIZE}x24" env MESA_VK_WSI_DEBUG=sw)
  else
    echo "qa_shot: Forward+ on Vulkan, headless weston + Xwayland (tools/xwl_run.sh)" >&2
    LAUNCH=("$CLIENT_DIR/tools/xwl_run.sh" -s "$SIZE")
  fi
  RFLAGS=(--rendering-method forward_plus --rendering-driver vulkan)
else
  # shellcheck disable=SC2206
  LAUNCH=(xvfb-run -a -s "-screen 0 ${SIZE}x24" $VGL)
  RFLAGS=(--rendering-driver opengl3)
fi
"${LAUNCH[@]}" "$GODOT" \
  "${RFLAGS[@]}" --resolution "$SIZE" --path . "$SCENE" \
  --write-movie "$OUT/f.png" --quit-after "$FRAMES" 2>&1 | tee "$OUT/godot.log"
# What actually ran: Godot's own banner. llvmpipe is the CPU, never the GPU.
banner=$(grep -m1 -E "^(Vulkan|OpenGL) API" "$OUT/godot.log" || true)
echo "qa_shot: ran ${banner:-(no renderer banner in the log)}" >&2
case "$banner" in *llvmpipe*) echo "qa_shot: WARNING: the run rendered on llvmpipe (the CPU), not the GPU" >&2 ;; esac
