#!/bin/bash
# Builds the native readers and puts the library where client/opensro_native.gdextension
# looks for it (client/native_bin/, git-ignored). native/README.md has the toolchain.
#   native/build.sh            # linux.x86_64  -> client/native_bin/libopensro_native.so
#   native/build.sh windows    # windows.x86_64 (x86_64-pc-windows-gnu, mingw-w64) -> opensro_native.dll
#   native/build.sh linux-release  # the release .so: linked by zig (cargo-zigbuild) against glibc
#                                  # $GLIBC_FLOOR (2.28, Godot's own floor: 4.2.2 and 4.7.2 alike), native/README.md "CI"
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/../client/native_bin"
mkdir -p "$out"
cargo="${CARGO:-cargo}"
command -v "$cargo" >/dev/null || cargo="$HOME/.cargo/bin/cargo"
case "${1:-linux}" in
  linux)
    "$cargo" build --release --locked --manifest-path "$here/Cargo.toml"
    cp "$here/target/release/libopensro_native.so" "$out/" ;;
  linux-release)
    floor="${GLIBC_FLOOR:-2.28}"
    "$cargo" zigbuild --release --locked --manifest-path "$here/Cargo.toml" --target "x86_64-unknown-linux-gnu.$floor"
    cp "$here/target/x86_64-unknown-linux-gnu/release/libopensro_native.so" "$out/" ;;
  windows)
    "$cargo" build --release --locked --manifest-path "$here/Cargo.toml" --target x86_64-pc-windows-gnu
    cp "$here/target/x86_64-pc-windows-gnu/release/opensro_native.dll" "$out/" ;;
  *) echo "usage: $0 [linux|linux-release|windows]" >&2; exit 2 ;;
esac
ls -la "$out"
