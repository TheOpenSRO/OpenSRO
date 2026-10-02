#!/bin/bash
# The renderer choice and the Vulkan fall back, end to end, in real windowed starts (round 693's
# review). Runs ON THE RENDER BOX (it starts Godot), against a client copy, under the caller's lock:
#
#   client/tools/renderer_fallback_box_test.sh <client dir> [out dir]
#
# Each case boots the game's own main scene (Boot -> Login) for 200 frames on xwl_run.sh's
# Xwayland, with SRREVAMP_OVERRIDE_CFG naming a fresh file (RendererChoice writes there instead of
# beside the executable), and checks Godot's banner and that file:
#   1. `--rendering-driver opengl3` (the Compatibility launcher's start): Compatibility runs, and
#      the file records gl_compatibility -- so plain starts and the updater's relaunch stay there.
#   2. a plain start with Vulkan: Forward+ runs, nothing is recorded.
#   3. a plain start with no Vulkan driver (VK_ICD_FILENAMES=/dev/null): the native library's probe
#      restarts the game on OpenGL (vk_fallback.rs) -- Compatibility runs, and it is recorded.
#      Needs the native library in the copy (native_bin/); without it the case is reported SKIP.
# Prints PASS/FAIL per check and exits 1 on any FAIL.
set -u
D="${1:?client dir}"; O="${2:-/var/tmp/renderer-fallback-test.$$}"
G="${GODOT:-/opt/godot-bin/Godot_v4.2.2-stable_linux.x86_64}"
P="${PK2_DIR:-/opt/sro-files/client}"
mkdir -p "$O"
export SRREVAMP_PK2_PATH=$P/Data.pk2 SRREVAMP_MAP_PK2_PATH=$P/Map.pk2 SRREVAMP_MEDIA_PK2_PATH=$P/Media.pk2
fail=0
check() { if [ "$1" = 0 ]; then echo "PASS $2"; else echo "FAIL $2"; fail=1; fi; }
boot() { # name [env...] -- [godot args...]
  local n=$1; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  rm -f "$O/$n.cfg"
  ( cd "$D" && env SRREVAMP_OVERRIDE_CFG="$O/$n.cfg" "${envs[@]}" timeout 120 "$D/tools/xwl_run.sh" "$G" --path . --quit-after 200 "$@" > "$O/$n.log" 2>&1 )
}
banner() { grep -m1 -E "^(Vulkan|OpenGL) API" "$O/$1.log"; }
recorded() { grep -s "renderer/rendering_method=\"gl_compatibility\"" "$O/$1.cfg" >/dev/null; }

boot launcher -- --rendering-driver opengl3
banner launcher | grep -q " - Compatibility - "; check $? "1. the launcher's start runs Compatibility ($(banner launcher | cut -c1-60))"
recorded launcher; check $? "1. ... and records it for the next start ($(grep -m1 -o 'RENDERER: .*' "$O/launcher.log" | grep -o 'chosen=.*' | cut -c1-120))"

boot vulkan --
banner vulkan | grep -q " - Forward+ - "; check $? "2. a plain start with Vulkan runs Forward+ ($(banner vulkan | cut -c1-60))"
[ ! -f "$O/vulkan.cfg" ]; check $? "2. ... and records nothing"

if [ -d "$D/native_bin" ]; then
  boot novulkan VK_ICD_FILENAMES=/dev/null --
  banner novulkan | grep -q " - Compatibility - "; check $? "3. a plain start with no Vulkan driver falls back to Compatibility ($(banner novulkan | cut -c1-60))"
  grep -q "vulkan_probe=\"fallback to OpenGL" "$O/novulkan.log"; check $? "3. ... the native probe says why ($(grep -m1 -o 'vulkan_probe="[^"]*"' "$O/novulkan.log"))"
  recorded novulkan; check $? "3. ... and records Compatibility"
else
  echo "SKIP 3. no native_bin/ in $D: without the library there is no automatic fall back"
fi
echo "logs: $O"
[ $fail = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
