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
# region streams in during play -- where a freeze is felt), hotan, ferry (the
# Donwhang-region ferry landing 90/143, reeds and river in view; round 648),
# mobs (the Jangan spawn with SRREVAMP_QA_MOBS=500: a 500-monster list of 24
# real species over the 5 x 5-region window, delivered during the loading
# drain as a server's list would be -- the density the server will send;
# round 655. A base without the hook draws no monsters there: gate it against
# a base that has the hook), crowd (the Jangan spawn with 2,500 monsters of 17
# real species packed within 1,920 of the player -- SRREVAMP_QA_MOBS=2500 and
# SRREVAMP_QA_MOBS_SPREAD=1920 -- the density round 660's swapped spots put in
# view: 1,378 bodies at the Europe starter field, 2,412 at the densest window;
# round 664. A base without the SPREAD hook spreads them over the whole load
# window instead: gate it against a base that has the hook).
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
# One build, two settings (round 667): `--ab-env "SRREVAMP_NATIVE=0"` runs the
# BASE side on the head's own copy with those variables added, so the gate
# compares one build both ways -- the native readers against the GDScript ones
# (client/tools/README.md, "Native readers A/B"). No base revision is shipped
# and no base cache is read or written in that mode.
#
# `--cold` (round 667) evicts the game archives from the page cache before
# every run, so their reads come off the disk: the storage-bound case. The
# box's container cannot write /proc/sys/vm/drop_caches (read-only there), so
# each *.pk2 under PK2_DIR is dropped with posix_fadvise(POSIX_FADV_DONTNEED),
# which any process that can open a file may do, and `fincore` confirms how
# much stayed resident (written to <log>.cold). Godot, the project and the
# shader cache stay cached: the archives are what a load reads.
#
# The working tree ships the native readers when built: client/*.gdextension
# and client/native_bin (native/build.sh). A --head revision ships neither.
#
# Environment: RENDER_HOST, PK2_DIR, PERF_LANE (dir suffix; default: branch).
set -euo pipefail

RENDER_HOST="${RENDER_HOST:-root@192.168.10.78}"
PK2_DIR="${PK2_DIR:-/opt/sro-files/client}"
GODOT="${RENDER_GODOT:-/opt/godot-bin/Godot_v4.2.2-stable_linux.x86_64}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

base="" head="" sites="jangan,reeds,cross" runs=3 frames=3000 ab_env="" cold=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --head) head="$2"; shift 2 ;;
    --sites) sites="$2"; shift 2 ;;
    --runs) runs="$2"; shift 2 ;;
    --frames) frames="$2"; shift 2 ;;
    --ab-env) ab_env="$2"; shift 2 ;;
    --cold) cold=1; shift ;;
    *) echo "usage: $0 [--base REV] [--head REV] [--sites jangan,reeds,cross,hotan,ferry,mobs,crowd] [--runs N] [--frames N] [--ab-env 'VAR=value ...'] [--cold]" >&2; exit 2 ;;
  esac
done
cd "$repo_root"
if [ -n "$ab_env" ]; then
  [ -z "$base" ] || { echo "--ab-env compares the head with itself: give no --base" >&2; exit 2; }
  base="${head:-HEAD}"
fi
[ -n "$base" ] || base="$(git merge-base HEAD origin/dev 2>/dev/null || git merge-base HEAD dev)"
base_short="$(git rev-parse --short "$base")"
head_label="${head:-working tree}"
lane="${PERF_LANE:-$(git rev-parse --abbrev-ref HEAD | tr -c 'a-zA-Z0-9\n' '-')}"
# The base is a fixed revision, so its client copy is shared by every lane and
# gate that measures it: shipped and imported once, reused after (the ship and
# the import were a large part of each gate).
base_full_rev="$(git rev-parse "$base")"
box_base="/opt/srrevamp-client-perf-base-${base_full_rev:0:12}"
box_head="/opt/srrevamp-client-perf-${lane}-head"
[ -n "$ab_env" ] && box_base="$box_head"
work="/var/tmp/perf-${lane}"

# The fixed views: MAPM path | QA_AT (region-local x,z) | yaw | walk heading ('' = stand) | [frames, at least] | [extra VAR=value ..., space-separated].
view() {
  case "$1" in
    jangan) echo '97\168.m|1002,1020|0|' ;;   # the game's own spawn
    reeds)  echo '98\157.m|900,900|0||9000' ;;     # Dunhuang reeds (round 647); 9000 frames: at 4.5 ms a frame (round 648) 3000 gave 13 samples, barely over the minimum of 10
    cross)  echo '97\168.m|120,1020|270|270' ;; # walk west into 97/167 (client/tools/README.md, "Load benchmark" (b))
    hotan)  echo '92\135.m|960,960|0|' ;;     # Hotan, the zone landing
    ferry)  echo '90\143.m|464,879|270||12000' ;;   # Donwhang-region ferry GATE_NPC_WC_FERRY4, looking at the dock over the reeds (round 648); 12000 frames: at 2.6 ms a frame 3000 gave 8 samples, under the minimum of 10 (the figure averages the last 30)
    mobs)   echo '97\168.m|1002,1020|0||3000|SRREVAMP_QA_MOBS=500' ;;   # the spawn with 500 monsters (round 655)
    crowd)  echo '97\168.m|1002,1020|0||3000|SRREVAMP_QA_MOBS=2500 SRREVAMP_QA_MOBS_SPREAD=1920' ;;   # 2,500 monsters within 1,920 (round 664)
    *) echo "unknown site $1" >&2; exit 2 ;;
  esac
}
for s in ${sites//,/ }; do view "$s" >/dev/null; done

files="client/scripts client/tools client/scenes client/docs client/project.godot"
# The native readers, when the working tree has them built (round 667).
native_files="$(cd "$repo_root" && { ls client/*.gdextension 2>/dev/null; [ -d client/native_bin ] && echo client/native_bin; } || true)"
ship() { # $1 box dir, $2 rev ('' = working tree)
  ssh -n "$RENDER_HOST" "rm -rf '$1' && mkdir -p '$1'"
  if [ -z "$2" ]; then
    # shellcheck disable=SC2086
    tar cf - -C "$repo_root" $files $native_files
  else
    git -C "$repo_root" archive "$2" $files
  fi | ssh "$RENDER_HOST" "tar xf - -C '$1' --strip-components=1 && chown -R ghidra:ghidra '$1'"
  ssh -n "$RENDER_HOST" "su - ghidra -c \"flock '$work/import.lock' $GODOT --headless --path '$1' --import --quit\"" >/dev/null 2>&1 || true
}

base_label="$base_short"
[ -n "$ab_env" ] && base_label="$head_label with $ab_env"
echo "perf gate: base $base_label vs head $head_label; sites $sites; $runs run(s) each$([ $cold = 1 ] && echo ', COLD page cache'); box dirs $box_base, $box_head"
ssh -n "$RENDER_HOST" "mkdir -p '$work' && chown ghidra:ghidra '$work'"
if [ -z "$ab_env" ]; then
# The shared base copy: built once, under a per-revision lock on the box, and
# marked .shipped when complete. A gate that finds it complete (or waits for
# another lane to finish it) just discards its own stream.
ssh -n "$RENDER_HOST" "mkdir -p /var/tmp/perf-cache"
git -C "$repo_root" archive "$base" $files | ssh "$RENDER_HOST" "flock '/var/tmp/perf-cache/ship-${base_full_rev:0:12}.lock' sh -c '
  if [ -f \"$box_base/.shipped\" ]; then cat >/dev/null; echo \"perf gate: reusing the shared base copy $box_base\";
  else rm -rf \"$box_base\" && mkdir -p \"$box_base\" && tar xf - -C \"$box_base\" --strip-components=1 &&
    chown -R ghidra:ghidra \"$box_base\" &&
    { su - ghidra -c \"$GODOT --headless --path $box_base --import --quit\" >/dev/null 2>&1 || true; } &&
    touch \"$box_base/.shipped\" && echo \"perf gate: shipped the shared base copy $box_base\"; fi'"
fi
ship "$box_head" "$head"

# One run on the box: waits until no other lane runs Godot, boots,
# and prints "<frame ms> <entry ms> <freeze ms> <hitches> <other renders seen>".
ssh "$RENDER_HOST" "cat > '$work/run1.sh'" <<EOF
#!/bin/bash
# run1.sh <client dir> <log> <mapm> <x,z> <yaw> [walk heading] [frames] [VAR=value] [cold: 1]
export SRREVAMP_PK2_PATH=$PK2_DIR/Data.pk2 SRREVAMP_MAP_PK2_PATH=$PK2_DIR/Map.pk2 SRREVAMP_MEDIA_PK2_PATH=$PK2_DIR/Media.pk2
export SRREVAMP_PARTICLES_PK2_PATH=$PK2_DIR/Particles.pk2 SRREVAMP_MUSIC_PK2_PATH=$PK2_DIR/Music.pk2
export SRREVAMP_MAPM_PATH="\$3" SRREVAMP_QA_AT="\$4" SRREVAMP_QA_YAW="\$5" SRREVAMP_QA_FORCE_LOADING=1
[ -n "\${6:-}" ] && export SRREVAMP_QA_WALK="\$6"
read -r -a kvs <<< "\${8:-}"; for kv in "\${kvs[@]}"; do export "\$kv"; done  # split on spaces, no globbing
# Another lane's Godot, rendered or headless (both load the CPU, the shared
# resource): a Godot process whose --path is not this run's client dir.
DIR="\$1"   # captured here: inside others() \$1 is the function's own (empty) argument
others() { pgrep -af "^/opt/godot-bin/Godot_v4" | grep -v -- "--path \$DIR " | wc -l; }
for i in \$(seq 1 120); do [ "\$(others)" = 0 ] && break; sleep 5; done
if [ "\${9:-0}" = 1 ]; then  # --cold, after the wait so no other run re-reads them: the archives off the page cache (see the header)
  python3 -c 'import os,sys
for p in sys.argv[1:]:
    fd = os.open(p, os.O_RDONLY); os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED); os.close(fd)' $PK2_DIR/*.pk2
  fincore -b $PK2_DIR/*.pk2 > "\$2.cold" 2>&1
fi
rm -f "\$2.others"
( while :; do n=\$(others); [ "\$n" -gt 0 ] && echo \$n >> "\$2.others"; sleep 2; done ) & W=\$!
xvfb-run -a -s "-screen 0 1280x720x24" vglrun -d egl0 $GODOT --rendering-driver opengl3 \
  --resolution 1280x720 --path "\$1" res://scenes/World3D.tscn --quit-after "\${7:-$frames}" \
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
base_full="$(git rev-parse "$base")"
cache="/var/tmp/perf-cache"
ssh -n "$RENDER_HOST" "mkdir -p '$cache'"

# one1 <base|head> <run tag>: one booted run, repeated if another lane's Godot
# overlapped it; prints "ms entry freeze hitches" (progress goes to stderr).
one1() {
  local b=$1 tag=$2 dir="$box_base" out ms entry freeze hitches seen
  [ "$b" = head ] && dir="$box_head"
  for try in 1 2 3; do
    local env="$extra"
    [ "$b" = base ] && [ -n "$ab_env" ] && env="$(echo "$extra $ab_env" | xargs)"
    out=$(ssh -n "$RENDER_HOST" "flock /var/tmp/perf-gate.lock '$work/run1.sh' '$dir' '$work/${s}_${b}_$tag.log' '$mapm' '$at' '$yaw' '$walk' '$run_frames' '$env' '$cold'")
    read -r ms entry freeze hitches seen <<<"$out"
    if [ "$ms" = none ] || [ "$entry" = none ] || [ "$freeze" = none ]; then
      echo "  $s $b run $tag: missing numbers ($out) -- see $RENDER_HOST:$work/${s}_${b}_$tag.log" >&2; exit 1
    fi
    [ "$seen" = 0 ] && break
    echo "  $s $b run $tag: another render overlapped it ($seen) -- repeating" >&2
  done
  echo "  $s $b run $tag: frame $ms ms, entry $entry ms, freeze $freeze ms, $hitches hitch(es)" >&2
  echo "$ms $entry $freeze $hitches"
}
add() { # add <base|head> "<ms entry freeze hitches>"
  local ms entry freeze hitches; read -r ms entry freeze hitches <<<"$2"
  vals[$1.frame]="${vals[$1.frame]:-} $ms"; vals[$1.entry]="${vals[$1.entry]:-} $entry"
  vals[$1.freeze]="${vals[$1.freeze]:-} $freeze"; vals[$1.hitches]="${vals[$1.hitches]:-} $hitches"
}

for s in ${sites//,/ }; do
  IFS='|' read -r mapm at yaw walk site_frames extra <<<"$(view "$s")"
  # A cheap view (the ferry: 2.6 ms a frame) is over before 3000 frames give
  # enough once-a-second samples (the minimum is 10), so a site may ask for
  # more: max(--frames, the site's own).
  run_frames=$frames
  [ -n "$site_frames" ] && [ "$site_frames" -gt "$frames" ] && run_frames=$site_frames
  declare -A vals=()
  # A base revision's numbers are the same for every lane that branches from
  # it: on 2026-09-30 four lanes re-measured dev's base at Jangan and queued
  # ~25 min for it. So a base is measured in full once per (revision, view,
  # frames) and cached on the box; a later gate runs ONE fresh base run first
  # and keeps the cache only if that run's frame time is within the gate's own
  # SLOWER threshold of the cached median -- a drifted box is measured again.
  cfile="$cache/${base_full}_${s}_${run_frames}.vals"
  cached=""
  # Same-build A/B and cold runs never use or fill the base cache: neither is
  # the base revision's ordinary warm measurement.
  [ -z "$ab_env" ] && [ $cold = 0 ] && cached=$(ssh -n "$RENDER_HOST" "cat '$cfile' 2>/dev/null" || true)
  ncached=$(printf '%s\n' "$cached" | grep -c . || true)
  use_cache=0
  if [ "$ncached" -ge "$runs" ]; then
    fresh=$(one1 base check) || exit 1
    cmed=$(printf '%s\n' "$cached" | awk '{print $1}' | median)
    if awk -v f="${fresh%% *}" -v c="$cmed" 'BEGIN {t = 0.05 * c; if (t < 0.5) t = 0.5; d = f - c; if (d < 0) d = -d; exit !(d <= t)}'; then
      use_cache=1
      echo "  $s base: $ncached cached run(s) for ${base_full:0:7}; the fresh check (${fresh%% *} ms) is within the threshold of their median ($cmed ms) -- using them" >&2
      while IFS= read -r line; do [ -n "$line" ] && add base "$line"; done <<<"$cached"
      add base "$fresh"
    else
      echo "  $s base: the fresh check (${fresh%% *} ms) is off the cached median ($cmed ms) -- the box drifted; measuring the base in full" >&2
      ssh -n "$RENDER_HOST" "rm -f '$cfile'"
    fi
  fi
  newbase=""
  for i in $(seq 1 "$runs"); do
    if [ $use_cache = 0 ]; then
      r=$(one1 base "$i") || exit 1; add base "$r"; newbase="$newbase$r"$'\n'
    fi
    r=$(one1 head "$i") || exit 1; add head "$r"
  done
  if [ $use_cache = 0 ] && [ -n "$newbase" ] && [ -z "$ab_env" ] && [ $cold = 0 ]; then
    printf '%s' "$newbase" | ssh "$RENDER_HOST" "cat > '$cfile'"
  fi
  for m in "frame ms|0.5|0.05" "entry ms|1000|0.10" "freeze ms|100|0.25" "hitches|2|0"; do
    IFS='|' read -r label abs rel <<<"$m"; key=${label%% *}
    line=$(verdict "${vals[base.$key]}" "${vals[head.$key]}" "$abs" "$rel")
    case "$line" in *SLOWER) slower=1 ;; esac
    report="$report$(printf '%-7s %-10s %s' "$s" "$label" "$line")"$'\n'
  done
  unset vals
done

echo
echo "perf gate: base $base_label vs head $head_label (1280x720, median of $runs run(s)$([ $cold = 1 ] && echo ', cold page cache'))"
printf '%s' "$report"
if [ $slower = 1 ]; then
  echo "SLOWER: the head is slower than its base. Fix it, or record the cost and ask the user." >&2
  exit 1
fi
