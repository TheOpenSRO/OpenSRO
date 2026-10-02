#!/bin/bash
# Checks a release zip carries the native readers' library where the exported game looks for
# it (round 668; native/README.md, "CI").
#   client/tools/check_release_zip.sh dist/srrevamp-windows.zip windows
#   client/tools/check_release_zip.sh dist/srrevamp-linux.zip linux [--run]
#
# Every zip must hold, in its one top-level folder: the executable, its .pck, the library
# NEXT TO the executable (Godot 4.2.2 exports a GDExtension library beside the executable,
# editor_export_platform_pc.cpp, and OS::open_dynamic_library falls back to the
# executable's folder when res://native_bin/... is not a real file), and
# THIRD_PARTY_NOTICES.txt. The .pck must carry srrevamp_native.gdextension and the
# .godot/extension_list.cfg that names it, or the exported game never loads the library.
# The library itself goes through check_native_library.sh (imports, export, stripped).
#
# --run (linux only) also runs the exported game headless, twice:
#   - as shipped: the log must say "native readers ON" and hold no GDExtension error;
#   - with the library renamed to .off (the fallback test): the log must say the library was
#     not found and that the GDScript readers are used.
# Exits 1 on any failure.
set -euo pipefail
zip="${1:?zip path}"
kind="${2:?windows|linux}"
run="${3:-}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
bad() { echo "FAIL $*"; fail=1; }

case "$kind" in
  windows) top=srrevamp-windows; exe=srrevamp.exe; lib=srrevamp_native.dll; launcher=srrevamp-compatibility.bat ;;
  linux) top=srrevamp-linux; exe=srrevamp.x86_64; lib=libsrrevamp_native.so; launcher=srrevamp-compatibility.sh ;;
  *) echo "usage: $0 <zip> windows|linux [--run]" >&2; exit 2 ;;
esac

listing=$(unzip -Z1 "$zip")
# The Compatibility launcher (round 693): the way in for a machine without Vulkan.
for f in "$exe" srrevamp.pck "$lib" THIRD_PARTY_NOTICES.txt "$launcher"; do
  grep -qx "$top/$f" <<< "$listing" || bad "$zip has no $top/$f"
done
echo "$zip: $(grep -c . <<< "$listing") entries"

tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}/check_release_zip.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
unzip -q "$zip" -d "$tmp"
dir="$tmp/$top"
if [ -f "$dir/srrevamp.pck" ]; then
  pck=$(LC_ALL=C grep -aoE 'res://srrevamp_native\.gdextension|srrevamp_native\.gdextension|\.godot/extension_list\.cfg' "$dir/srrevamp.pck" | sort -u || true)
  grep -q 'srrevamp_native.gdextension' <<< "$pck" || bad "srrevamp.pck does not carry srrevamp_native.gdextension"
  grep -q 'extension_list.cfg' <<< "$pck" || bad "srrevamp.pck does not carry .godot/extension_list.cfg"
fi
if [ -f "$dir/$lib" ]; then
  bash "$here/check_native_library.sh" "$dir/$lib" "$kind" || fail=1
  sha256sum "$dir/$lib" | sed "s#$tmp/##"
fi
if [ -f "$dir/THIRD_PARTY_NOTICES.txt" ]; then
  notices="$dir/THIRD_PARTY_NOTICES.txt"
  grep -q 'MPL-2.0' "$notices" || bad "THIRD_PARTY_NOTICES.txt names no MPL-2.0 crate"
  grep -q '^Mozilla Public License Version 2.0' "$notices" || bad "THIRD_PARTY_NOTICES.txt lacks the MPL-2.0 text"
  grep -q '^FULL LICENCE TEXTS OF THE CRATES' "$notices" || bad "THIRD_PARTY_NOTICES.txt lacks the crates' licence texts"
  grep -q '^THE RUST STANDARD LIBRARY' "$notices" || bad "THIRD_PARTY_NOTICES.txt lacks the Rust standard library's texts"
  grep -q '^GODOT ENGINE 4\.2\.2' "$notices" || bad "THIRD_PARTY_NOTICES.txt lacks Godot Engine's licence and notices"
fi

if [ "$run" = "--run" ]; then
  [ "$kind" = linux ] || { echo "--run only runs the Linux build" >&2; exit 2; }
  chmod +x "$dir/$exe"
  run_game() {  # $1: log file. HOME is the scratch dir, so user:// lands there too.
    (cd "$dir" && HOME="$tmp/home" timeout 120 "./$exe" --headless --quit-after 120 > "$1" 2>&1) || true
  }
  run_game "$tmp/on.log"
  echo "--- as shipped:"
  grep -E 'NativeAssets|GDExtension|extension' "$tmp/on.log" || true
  grep -q 'NativeAssets: native readers ON' "$tmp/on.log" || bad "the exported game did not load $lib (no 'native readers ON' line)"
  if grep -qiE 'ERROR.*(GDExtension|extension)|extension.*ERROR' "$tmp/on.log"; then bad "the exported game logged a GDExtension error with the library present"; fi

  mv "$dir/$lib" "$dir/$lib.off"
  run_game "$tmp/off.log"
  echo "--- with $lib renamed to $lib.off:"
  grep -E 'NativeAssets|GDExtension|extension|ERROR' "$tmp/off.log" || true
  grep -q 'NativeAssets: native readers OFF' "$tmp/off.log" || bad "with the library renamed there is no 'native readers OFF' line"
  grep -q 'NativeAssets: native readers ON' "$tmp/off.log" && bad "with the library renamed the game still says ON"
  mv "$dir/$lib.off" "$dir/$lib"
fi

[ "$fail" = 0 ] && echo "ok  $zip ($kind)"
exit "$fail"
