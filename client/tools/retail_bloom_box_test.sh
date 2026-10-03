#!/bin/bash
# The Bloom row under Compatibility draws a picture, not a black frame (round 707). Runs ON THE
# RENDER BOX (it starts Godot on the GPU), against a client copy, under the caller's lock:
#
#   client/tools/retail_bloom_box_test.sh <client dir> [out dir]
#
# Round 705 found every Compatibility frame with Bloom on (0, 0, 0): a 3D pass that reads the depth
# texture (WorldFog's) made Godot 4.2.2's GLES3 create the back buffer without a colour texture, so
# RetailBloom's screen reads sampled nothing (RetailBloom's header). Round 702 had measured the
# bloom in a canvas-only scene, which never showed it. Two checks, both under Compatibility:
#   1. tools/measure_retail_bloom.gd at 1280 x 720 WITH a depth-reading 3D pass: the frame is not
#      black, the bloom is within the tolerance against the CPU's 512 pipeline, no echo peak.
#   2. the game itself (World3D at the Jangan spawn, needs the pk2s), started with Bloom off (so
#      the world's 3D pass makes the back buffer before any bloom exists, the harder order), then
#      OPENSRO_QA_VIDEO_STEPS bloom=1 and bloom=0, a frame of each: the bloom's frame keeps at
#      least half the mean grey of the plain one (it raises contrast about 0.5: it never halves a
#      picture).
# Prints PASS/FAIL per check and exits 1 on any FAIL. Needs xvfb-run, vglrun and ImageMagick's
# convert. About 2.5 minutes. Run it after any change to RetailBloom, WorldFog or the 3D passes'
# screen or depth reads.
set -u
D="${1:?client dir}"; O="${2:-/var/tmp/retail-bloom-test.$$}"
G="${GODOT:-/opt/godot-bin/Godot_v4.2.2-stable_linux.x86_64}"
P="${PK2_DIR:-/opt/sro-files/client}"
mkdir -p "$O"
fail=0
check() { if [ "$1" = 0 ]; then echo "PASS $2"; else echo "FAIL $2"; fail=1; fi; }
gl() { # size log [godot args...]
  local size=$1 log=$2; shift 2
  ( cd "$D" && timeout -k 10 600 xvfb-run -a -s "-screen 0 ${size}x24" vglrun -d egl0 "$G" --rendering-driver opengl3 \
      --resolution "$size" --path . "$@" > "$log" 2>&1 )
}
banner() { grep -m1 -E "^(Vulkan|OpenGL) API" "$1"; }

gl 1280x720 "$O/measure.log" --script res://tools/measure_retail_bloom.gd
rc=$?
banner "$O/measure.log" | grep -q " - Compatibility - " && ! banner "$O/measure.log" | grep -q llvmpipe
check $? "1. the measurement ran on Compatibility on the GPU ($(banner "$O/measure.log" | cut -c1-70))"
grep -q "^FRAME gl_compatibility" "$O/measure.log" && [ "$rc" = 0 ] && ! grep -q "^FAIL" "$O/measure.log"
check $? "1. ... with a depth-reading 3D pass the bloom's frame is a picture, within tolerance, no echo ($(grep -E '^(FRAME|BLOOM)' "$O/measure.log" | sed 's/ vs the 512 pipeline//' | tr '\n' ' ' | cut -c1-220))"

export OPENSRO_PK2_PATH=$P/Data.pk2 OPENSRO_MAP_PK2_PATH=$P/Map.pk2 OPENSRO_MEDIA_PK2_PATH=$P/Media.pk2 \
  OPENSRO_PARTICLES_PK2_PATH=$P/Particles.pk2 OPENSRO_MAPM_PATH='97\168.m' OPENSRO_QA_AT=1002,1020 \
  OPENSRO_QA_YAW=0 OPENSRO_QA_PITCH=-15 OPENSRO_QA_DIST=40 OPENSRO_QA_RADIUS=1 OPENSRO_QA_NOUI=1 \
  OPENSRO_QA_VIDEO=bloom=0 OPENSRO_QA_VIDEO_STEPS='bloom=1|bloom=0' OPENSRO_QA_VIDEO_SHOT_DIR="$O" OPENSRO_QA_VIDEO_QUIT=1
rm -f "$O/step_0.png" "$O/step_1.png"
gl 1280x720 "$O/world.log" res://scenes/World3D.tscn
banner "$O/world.log" | grep -q " - Compatibility - "
check $? "2. the world ran on Compatibility ($(banner "$O/world.log" | cut -c1-70))"
mean() { convert "$1" -alpha off -colorspace gray -format '%[fx:255*mean]' info: 2>/dev/null; }
if [ -s "$O/step_0.png" ] && [ -s "$O/step_1.png" ]; then
  on=$(mean "$O/step_0.png"); off=$(mean "$O/step_1.png")
  awk -v a="${on:-0}" -v b="${off:-0}" 'BEGIN { exit !(b > 10 && a >= 0.5 * b) }'
  check $? "2. ... the Jangan spawn with Bloom on keeps its picture: mean grey ${on:-?} against ${off:-?} with Bloom off"
else
  check 1 "2. ... no step frames were written (see $O/world.log)"
fi
echo "logs: $O"
[ $fail = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
