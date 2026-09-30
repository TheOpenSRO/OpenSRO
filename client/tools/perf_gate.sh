#!/bin/bash
# Performance gate: does this branch make the game slower than its base --
# in milliseconds a frame, or in seconds of loading and freezing?
#
# Round 645 (animated map objects) shipped its review with the cost measured
# only at the Dunhuang reeds at 320x180. The Jangan spawn at 1280x720 cost
# +3.3 ms a frame (90 fps -> 70), found only by the final integration review,
# and fixing it took a new round and a new review: about 3.5 of the batch's
# 8.5 hours (2026-09-29). This gate measures the same fixed views on every
# world round, before its review, so a cost is caught in the round that made it.
#
#   client/tools/perf_gate.sh                       # working tree vs its merge-base with dev
#   client/tools/perf_gate.sh --base 8658370 --head c306c51
#   client/tools/perf_gate.sh --sites jangan --runs 5
#
# Four numbers per run, all from the client's own log:
#   frame    ms per frame standing still: the mean of the last 30 of
#            `--print-fps`'s per-second samples (1280x720, vsync off);
#   entry    the world entry a player waits through: `region grid loaded in
#            N ms` (the real loading drain, SRREVAMP_QA_FORCE_LOADING=1);
#   freeze   the longest main-thread frame: the largest `longest work frame
#            W ms` of the run's LoadTimings summaries (round 561);
#   hitches  frames over 100 ms: the summaries' `H over 100 ms`, summed.
# Sites: jangan (the spawn, the densest town), reeds (Dunhuang, the most
# animated objects in view), cross (a walk west from 97/168 into 97/167, so a
# region streams in during play -- where a freeze is felt), hotan.
#
# How it measures (the method the reviews of rounds 645-647 settled on):
# - runs are interleaved base, head, base, head ... so drift hits both;
# - the CPU is the resource lanes share, not the GPU (measured 2026-09-30
#   with amdgpu_top and vmstat: one render uses about 3.3 of the box's 10
#   cores and 17 % of the GPU; six at once put the CPU at 89 % busy with a
#   run queue of 12 on 10 cores, frames 2.8x slower, while the GPU averaged
#   37 % and never reached 90 %). So every run first waits until no other
#   lane's Godot is running -- a headless test suite loads the CPU too -- and
#   a run another Godot overlapped is repeated. Gates queue on one lock.
#
# Verdict per site and number, on the medians of the runs (thresholds OURS):
#   SLOWER  worse by more than the threshold AND no head run beats a base run
#           frame +max(0.5 ms, 5 %); entry +max(1 s, 10 %);
#           freeze +max(100 ms, 25 %); hitches +2
#   FASTER  the same the other way
#   SAME    otherwise
# The script exits 1 if anything is SLOWER. A round that is slower on purpose
# (a feature that costs time) says so in its WORLD_ISSUES entry with these
# numbers, and the user decides; the gate never passes it silently.
#
# Environment: RENDER_HOST, PK2_DIR, PERF_LANE (dir suffix; default: branch).
set -euo pipefail

RENDER_HOST="${RENDER_HOST:-root@192.168.10.78}"
PK2_DIR="${PK2_DIR:-/opt/sro-files/client}"
GODOT="${RENDER_GODOT:-/opt/godot-bin/Godot_v4.2.2-stable_linux.x86_64}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

base="" head="" sites="jangan,reeds,cross" runs=3 frames=3000
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --head) head="$2"; shift 2 ;;
    --sites) sites="$2"; shift 2 ;;
    --runs) runs="$2"; shift 2 ;;
    --frames) frames="$2"; shift 2 ;;
    *) echo "usage: $0 [--base REV] [--head REV] [--sites jangan,reeds,cross,hotan] [--runs N] [--frames N]" >&2; exit 2 ;;
  esac
done
cd "$repo_root"
[ -n "$base" ] || base="$(git merge-base HEAD origin/dev 2>/dev/null || git merge-base HEAD dev)"
base_short="$(git rev-parse --short "$base")"
head_label="${head:-working tree}"
lane="${PERF_LANE:-$(git rev-parse --abbrev-ref HEAD | tr -c 'a-zA-Z0-9\n' '-')}"
box_base="/opt/srrevamp-client-perf-${lane}-base"
box_head="/opt/srrevamp-client-perf-${lane}-head"
work="/var/tmp/perf-${lane}"

# The fixed views: MAPM path | QA_AT (region-local x,z) | yaw | walk heading ('' = stand).
view() {
  case "$1" in
    jangan) echo '97\168.m|1002,1020|0|' ;;   # the game's own spawn
    reeds)  echo '98\157.m|900,900|0|' ;;     # Dunhuang reeds (round 647)
    cross)  echo '97\168.m|120,1020|270|270' ;; # walk west into 97/167 (client/tools/README.md, "Load benchmark" (b))
    hotan)  echo '92\135.m|960,960|0|' ;;     # Hotan, the zone landing
    *) echo "unknown site $1" >&2; exit 2 ;;
  esac
}
for s in ${sites//,/ }; do view "$s" >/dev/null; done

files="client/scripts client/tools client/scenes client/docs client/project.godot"
ship() { # $1 box dir, $2 rev ('' = working tree)
  ssh -n "$RENDER_HOST" "rm -rf '$1' && mkdir -p '$1'"
  if [ -z "$2" ]; then
    tar cf - -C "$repo_root" $files
  else
    git -C "$repo_root" archive "$2" $files
  fi | ssh "$RENDER_HOST" "tar xf - -C '$1' --strip-components=1 && chown -R ghidra:ghidra '$1'"
  ssh -n "$RENDER_HOST" "su - ghidra -c \"flock '$work/import.lock' $GODOT --headless --path '$1' --import --quit\"" >/dev/null 2>&1 || true
}

echo "perf gate: base $base_short vs head $head_label; sites $sites; $runs run(s) each; box dirs $box_base, $box_head"
ssh -n "$RENDER_HOST" "mkdir -p '$work' && chown ghidra:ghidra '$work'"
ship "$box_base" "$base"
ship "$box_head" "$head"

# One run on the box: waits until no other lane runs Godot, boots,
# and prints "<frame ms> <entry ms> <freeze ms> <hitches> <other renders seen>".
ssh "$RENDER_HOST" "cat > '$work/run1.sh'" <<EOF
#!/bin/bash
# run1.sh <client dir> <log> <mapm> <x,z> <yaw> [walk heading]
export SRREVAMP_PK2_PATH=$PK2_DIR/Data.pk2 SRREVAMP_MAP_PK2_PATH=$PK2_DIR/Map.pk2 SRREVAMP_MEDIA_PK2_PATH=$PK2_DIR/Media.pk2
export SRREVAMP_PARTICLES_PK2_PATH=$PK2_DIR/Particles.pk2 SRREVAMP_MUSIC_PK2_PATH=$PK2_DIR/Music.pk2
export SRREVAMP_MAPM_PATH="\$3" SRREVAMP_QA_AT="\$4" SRREVAMP_QA_YAW="\$5" SRREVAMP_QA_FORCE_LOADING=1
[ -n "\${6:-}" ] && export SRREVAMP_QA_WALK="\$6"
# Another lane's Godot, rendered or headless (both load the CPU, the shared
# resource): a Godot process whose --path is not this run's client dir.
DIR="\$1"   # captured here: inside others() \$1 is the function's own (empty) argument
others() { pgrep -af "^/opt/godot-bin/Godot_v4" | grep -v -- "--path \$DIR " | wc -l; }
for i in \$(seq 1 120); do [ "\$(others)" = 0 ] && break; sleep 5; done
rm -f "\$2.others"
( while :; do n=\$(others); [ "\$n" -gt 0 ] && echo \$n >> "\$2.others"; sleep 2; done ) & W=\$!
xvfb-run -a -s "-screen 0 1280x720x24" vglrun -d egl0 $GODOT --rendering-driver opengl3 \
  --resolution 1280x720 --path "\$1" res://scenes/World3D.tscn --quit-after $frames \
  --print-fps --disable-vsync > "\$2" 2>&1 &
G=\$!; wait \$G
kill \$W 2>/dev/null
ms=\$(grep -o "([0-9.]* mspf)" "\$2" | tr -d "(" | awk '{print \$1}' | tail -30 | awk '{s+=\$1;n++} END {if(n>=10) printf "%.2f", s/n; else print "none"}')
entry=\$(grep -m1 -o "region grid loaded in [0-9]* ms" "\$2" | grep -o "[0-9]*" || echo none)
freeze=\$(grep -o "longest work frame [0-9.]* ms" "\$2" | grep -o "[0-9.]*" | sort -n | tail -1 | grep . || echo none)
hitches=\$(grep -o "; [0-9]* over 100 ms" "\$2" | grep -o "[0-9]* over" | grep -o "[0-9]*" | awk '{s+=\$1} END {print s+0}')
echo "\$ms \$entry \$freeze \$hitches \$(sort -n "\$2.others" 2>/dev/null | tail -1 | grep . || echo 0)"
EOF
ssh -n "$RENDER_HOST" "chmod +x '$work/run1.sh'"

median() { tr ' ' '\n' | grep . | sort -n | awk '{a[NR]=$1} END {if(NR%2) print a[(NR+1)/2]; else printf "%.2f\n", (a[NR/2]+a[NR/2+1])/2}'; }
minof() { tr ' ' '\n' | grep . | sort -n | head -1; }
maxof() { tr ' ' '\n' | grep . | sort -n | tail -1; }
# verdict <base values> <head values> <abs threshold> <relative threshold>
verdict() {
  local b h
  b=$(echo $1 | median); h=$(echo $2 | median)
  awk -v h="$h" -v b="$b" -v hmin="$(echo $2 | minof)" -v hmax="$(echo $2 | maxof)" \
    -v bmin="$(echo $1 | minof)" -v bmax="$(echo $1 | maxof)" -v a="$3" -v r="$4" 'BEGIN {
      t = r * b; if (t < a) t = a
      if (h - b > t && hmin > bmax) v = "SLOWER"
      else if (b - h > t && hmax < bmin) v = "FASTER"
      else v = "SAME"
      printf "base %s  head %s  (%+.1f)  %s", b, h, h - b, v }'
}

# Gates in every lane share one lock: two gates at once would each see the
# other's renders and repeat forever.
ssh -n "$RENDER_HOST" "touch /var/tmp/perf-gate.lock"
slower=0
report=""
for s in ${sites//,/ }; do
  IFS='|' read -r mapm at yaw walk <<<"$(view "$s")"
  declare -A vals=()
  for i in $(seq 1 "$runs"); do
    for b in base head; do
      dir="$box_base"; [ $b = head ] && dir="$box_head"
      for try in 1 2 3; do
        out=$(ssh -n "$RENDER_HOST" "flock /var/tmp/perf-gate.lock '$work/run1.sh' '$dir' '$work/${s}_${b}_$i.log' '$mapm' '$at' '$yaw' '$walk'")
        read -r ms entry freeze hitches seen <<<"$out"
        if [ "$ms" = none ] || [ "$entry" = none ] || [ "$freeze" = none ]; then
          echo "  $s $b run $i: missing numbers ($out) -- see $RENDER_HOST:$work/${s}_${b}_$i.log" >&2; exit 1
        fi
        [ "$seen" = 0 ] && break
        echo "  $s $b run $i: another render overlapped it ($seen) -- repeating" >&2
      done
      echo "  $s $b run $i: frame $ms ms, entry $entry ms, freeze $freeze ms, $hitches hitch(es)"
      vals[$b.frame]="${vals[$b.frame]:-} $ms"; vals[$b.entry]="${vals[$b.entry]:-} $entry"
      vals[$b.freeze]="${vals[$b.freeze]:-} $freeze"; vals[$b.hitches]="${vals[$b.hitches]:-} $hitches"
    done
  done
  for m in "frame ms|0.5|0.05" "entry ms|1000|0.10" "freeze ms|100|0.25" "hitches|2|0"; do
    IFS='|' read -r label abs rel <<<"$m"; key=${label%% *}
    line=$(verdict "${vals[base.$key]}" "${vals[head.$key]}" "$abs" "$rel")
    case "$line" in *SLOWER) slower=1 ;; esac
    report="$report$(printf '%-7s %-10s %s' "$s" "$label" "$line")"$'\n'
  done
  unset vals
done

echo
echo "perf gate: base $base_short vs head $head_label (1280x720, median of $runs run(s))"
printf '%s' "$report"
if [ $slower = 1 ]; then
  echo "SLOWER: the head is slower than its base. Fix it, or record the cost and ask the user." >&2
  exit 1
fi
