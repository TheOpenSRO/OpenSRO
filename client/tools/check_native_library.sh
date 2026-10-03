#!/bin/bash
# Checks a built native-readers library before it ships (round 668; native/README.md, "CI").
#   client/tools/check_native_library.sh <opensro_native.dll> windows
#   client/tools/check_native_library.sh <libopensro_native.so> linux
#
# windows: the DLL must stand alone. Every DLL it imports must be a Windows system DLL --
#   no MinGW runtime (libgcc_s_seh-1.dll, libwinpthread-1.dll, libstdc++-6.dll) and nothing
#   else a player would have to install. It must export gdext_rust_init (the entry symbol
#   client/opensro_native.gdextension names) and carry no debug sections or COFF symbols.
# linux: the .so must export gdext_rust_init, need only base system libraries, ask for no
#   glibc symbol newer than $GLIBC_FLOOR (default 2.28: Godot 4.2.2's own Linux binary
#   needs GLIBC_2.28 at most, MEASURED round 668), and be stripped.
# Prints the imports and the size, and exits 1 on any failure.
set -euo pipefail
lib="${1:?library path}"
kind="${2:?windows|linux}"
[ -f "$lib" ] || { echo "FAIL $lib does not exist"; exit 1; }
fail=0
bad() { echo "FAIL $*"; fail=1; }

size=$(stat -c %s "$lib")
echo "$lib: $size bytes ($(awk -v s="$size" 'BEGIN{printf "%.2f MiB", s/1048576}'))"

case "$kind" in
  windows)
    od=x86_64-w64-mingw32-objdump
    command -v "$od" >/dev/null || od=objdump
    # Read into variables, then grep: `objdump | grep -q` under pipefail fails on SIGPIPE.
    pe=$("$od" -p "$lib")
    imports=$(sed -n 's/^\s*DLL Name: //p' <<< "$pe")
    echo "imports: $(echo "$imports" | tr '\n' ' ')"
    [ -n "$imports" ] || bad "no import table read from $lib"
    # Windows system DLLs: the ones rustc's std and the windows-gnu target link against,
    # plus the API-set forwarders (api-ms-win-*), which resolve inside Windows itself.
    while read -r dll; do
      [ -z "$dll" ] && continue
      case "${dll,,}" in
        kernel32.dll|ntdll.dll|msvcrt.dll|userenv.dll|ws2_32.dll|bcryptprimitives.dll|advapi32.dll|bcrypt.dll|user32.dll|shell32.dll|ole32.dll|api-ms-win-*.dll) ;;
        *) bad "imports $dll, which is not a Windows system DLL (link it statically)" ;;
      esac
    done <<< "$imports"
    # The export table's name column: "[   0] gdext_rust_init" (binutils 2.42) or
    # "[   0] +base[   1]  0000 gdext_rust_init" (binutils 2.44).
    grep -qE '^\s*\[ *[0-9]+\] .*\bgdext_rust_init$' <<< "$pe" || bad "does not export gdext_rust_init"
    if grep -q '\.debug_' <<< "$("$od" -h "$lib")"; then bad "has debug sections (not stripped)"; fi
    nsyms=$(grep -c '^\[' <<< "$("$od" -t "$lib" 2>/dev/null)" || true)
    [ "$nsyms" -eq 0 ] || bad "carries $nsyms COFF symbols (not stripped)"
    ;;
  linux)
    needed=$(sed -n 's/^\s*NEEDED\s*//p' <<< "$(objdump -p "$lib")")
    echo "needs: $(echo "$needed" | tr '\n' ' ')"
    while read -r so; do
      [ -z "$so" ] && continue
      case "$so" in
        libc.so.6|libm.so.6|libgcc_s.so.1|libpthread.so.0|libdl.so.2|ld-linux-x86-64.so.2) ;;
        *) bad "needs $so, which is not part of a base Linux system" ;;
      esac
    done <<< "$needed"
    dyn=$(objdump -T "$lib")
    grep -q '\bgdext_rust_init$' <<< "$dyn" || bad "does not export gdext_rust_init"
    floor="${GLIBC_FLOOR:-2.28}"
    newest=$(grep -o 'GLIBC_[0-9.]*' <<< "$dyn" | sed 's/GLIBC_//' | sort -uV | tail -1)
    echo "newest glibc symbol: ${newest:-none} (floor $floor)"
    if [ -n "$newest" ] && [ "$(printf '%s\n%s\n' "$newest" "$floor" | sort -V | tail -1)" != "$floor" ]; then
      bad "needs GLIBC_$newest, above the floor $floor (build with native/build.sh linux-release)"
    fi
    if grep -qE '\.debug_|\.symtab' <<< "$(objdump -h "$lib")"; then bad "has debug sections or a symbol table (not stripped)"; fi
    ;;
  *) echo "usage: $0 <library> windows|linux" >&2; exit 2 ;;
esac

if [ "$fail" = 0 ]; then echo "ok  $lib ($kind) stands alone, exports gdext_rust_init, stripped"; fi
exit "$fail"
