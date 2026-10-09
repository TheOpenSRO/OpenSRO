#!/bin/bash
# Checks a release zip carries the native readers' library where the exported game looks for
# it (round 668; native/README.md, "CI").
#   client/tools/check_release_zip.sh dist/opensro-windows.zip windows
#   client/tools/check_release_zip.sh dist/opensro-linux.zip linux [--run]
#
# Every zip must hold, in its one top-level folder: the executable, its .pck, the library
# NEXT TO the executable (Godot exports a GDExtension library beside the executable,
# editor_export_platform_pc.cpp, and OS::open_dynamic_library falls back to the
# executable's folder when res://native_bin/... is not a real file; 4.2.2 and 4.7.2 alike), and
# THIRD_PARTY_NOTICES.txt. The .pck must carry opensro_native.gdextension and the
# .godot/extension_list.cfg that names it, or the exported game never loads the library.
# The library itself goes through check_native_library.sh (imports, export, stripped).
# Round 760 (Godot 4.7.2): the executable must be an engine the library accepts -- its
# version string (`4.7.2.stable.official` in the 4.7.2 templates) at or above the
# .gdextension's compatibility_minimum (4.7) -- or the game would refuse its own library and
# read everything in GDScript; and the notices must name the same Godot release.
#
# --run (linux only) also runs the exported game headless, twice:
#   - as shipped: the log must say "native readers ON" and "native effect simulation ON"
#     (round 763) and hold no GDExtension error;
#   - with the library renamed to .off (the fallback test): the log must say the library was
#     not found and that the GDScript readers (and effect simulation) are used.
# Round 763: the library must also carry the effect simulation's classes (both zips).
# Exits 1 on any failure.
set -euo pipefail
zip="${1:?zip path}"
kind="${2:?windows|linux}"
run="${3:-}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
bad() { echo "FAIL $*"; fail=1; }

case "$kind" in
  windows) top=opensro-windows; exe=OpenSRO.exe; lib=opensro_native.dll; launcher=opensro-compatibility.bat ;;
  linux) top=opensro-linux; exe=OpenSRO.x86_64; lib=libopensro_native.so; launcher=opensro-compatibility.sh ;;
  *) echo "usage: $0 <zip> windows|linux [--run]" >&2; exit 2 ;;
esac

listing=$(unzip -Z1 "$zip")
# The Compatibility launcher (round 693): the way in for a machine without Vulkan.
for f in "$exe" OpenSRO.pck "$lib" THIRD_PARTY_NOTICES.txt "$launcher"; do
  grep -qx "$top/$f" <<< "$listing" || bad "$zip has no $top/$f"
done
echo "$zip: $(grep -c . <<< "$listing") entries"

tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}/check_release_zip.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
unzip -q "$zip" -d "$tmp"
dir="$tmp/$top"
if [ -f "$dir/OpenSRO.pck" ]; then
  pck=$(LC_ALL=C grep -aoE 'res://opensro_native\.gdextension|opensro_native\.gdextension|\.godot/extension_list\.cfg' "$dir/OpenSRO.pck" | sort -u || true)
  grep -q 'opensro_native.gdextension' <<< "$pck" || bad "OpenSRO.pck does not carry opensro_native.gdextension"
  grep -q 'extension_list.cfg' <<< "$pck" || bad "OpenSRO.pck does not carry .godot/extension_list.cfg"
fi
# The engine in the zip against the library's floor (round 760).
floor=$(sed -n 's/^compatibility_minimum *= *"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' "$here/../opensro_native.gdextension" | head -1)
engine=""
if [ -f "$dir/$exe" ]; then
  engine=$(LC_ALL=C grep -aoE '[0-9]+\.[0-9]+(\.[0-9]+)?\.stable\.official' "$dir/$exe" | head -1 | sed 's/\.stable\.official//' || true)
  echo "engine: Godot ${engine:-unknown}; the library's floor: ${floor:-unknown}"
  if [ -z "$engine" ] || [ -z "$floor" ]; then
    bad "could not read the engine version from $exe or the floor from opensro_native.gdextension"
  elif [ "$(printf '%s\n%s\n' "$floor" "$engine" | sort -V | head -1)" != "$floor" ]; then
    bad "$exe is Godot $engine, below the native library's compatibility_minimum $floor"
  fi
fi
if [ -f "$dir/$lib" ]; then
  bash "$here/check_native_library.sh" "$dir/$lib" "$kind" || fail=1
  # Round 763: the library carries the effect simulation (its classes are registered by name).
  for cls in SrEfpSim SrEfpTemplate SrEfpBatch; do
    LC_ALL=C grep -aq "$cls" "$dir/$lib" || bad "$lib lacks $cls (the effect simulation, round 763)"
  done
  sha256sum "$dir/$lib" | sed "s#$tmp/##"
fi
if [ -f "$dir/THIRD_PARTY_NOTICES.txt" ]; then
  notices="$dir/THIRD_PARTY_NOTICES.txt"
  grep -q 'MPL-2.0' "$notices" || bad "THIRD_PARTY_NOTICES.txt names no MPL-2.0 crate"
  grep -q '^Mozilla Public License Version 2.0' "$notices" || bad "THIRD_PARTY_NOTICES.txt lacks the MPL-2.0 text"
  grep -q '^FULL LICENCE TEXTS OF THE CRATES' "$notices" || bad "THIRD_PARTY_NOTICES.txt lacks the crates' licence texts"
  grep -q '^THE RUST STANDARD LIBRARY' "$notices" || bad "THIRD_PARTY_NOTICES.txt lacks the Rust standard library's texts"
  grep -q '^GODOT ENGINE 4\.' "$notices" || bad "THIRD_PARTY_NOTICES.txt lacks Godot Engine's licence and notices"
  if [ -n "$engine" ] && ! grep -q "^GODOT ENGINE ${engine}" "$notices"; then
    bad "THIRD_PARTY_NOTICES.txt names another Godot release than the executable's $engine"
  fi
fi

if [ "$run" = "--run" ]; then
  [ "$kind" = linux ] || { echo "--run only runs the Linux build" >&2; exit 2; }
  chmod +x "$dir/$exe"
  run_game() {  # $1: log file. HOME is the scratch dir, so user:// lands there too.
    (cd "$dir" && HOME="$tmp/home" timeout 120 "./$exe" --headless --quit-after 120 > "$1" 2>&1) || true
  }
  run_game "$tmp/on.log"
  echo "--- as shipped:"
  grep -E 'NativeAssets|EfpSimNative|GDExtension|extension' "$tmp/on.log" || true
  grep -q 'NativeAssets: native readers ON' "$tmp/on.log" || bad "the exported game did not load $lib (no 'native readers ON' line)"
  grep -q 'EfpSimNative: native effect simulation ON' "$tmp/on.log" || bad "the exported game does not simulate effects natively (no 'native effect simulation ON' line)"
  if grep -qiE 'ERROR.*(GDExtension|extension)|extension.*ERROR' "$tmp/on.log"; then bad "the exported game logged a GDExtension error with the library present"; fi

  mv "$dir/$lib" "$dir/$lib.off"
  run_game "$tmp/off.log"
  echo "--- with $lib renamed to $lib.off:"
  grep -E 'NativeAssets|EfpSimNative|GDExtension|extension|ERROR' "$tmp/off.log" || true
  grep -q 'NativeAssets: native readers OFF' "$tmp/off.log" || bad "with the library renamed there is no 'native readers OFF' line"
  grep -q 'NativeAssets: native readers ON' "$tmp/off.log" && bad "with the library renamed the game still says ON"
  grep -q 'EfpSimNative: native effect simulation OFF' "$tmp/off.log" || bad "with the library renamed there is no 'native effect simulation OFF' line"
  mv "$dir/$lib.off" "$dir/$lib"
fi

[ "$fail" = 0 ] && echo "ok  $zip ($kind)"
exit "$fail"
