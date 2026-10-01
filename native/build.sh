#!/bin/bash
# Builds the native readers and puts the library where client/srrevamp_native.gdextension
# looks for it (client/native_bin/, git-ignored). native/README.md has the toolchain.
#   native/build.sh            # linux.x86_64  -> client/native_bin/libsrrevamp_native.so
#   native/build.sh windows    # windows.x86_64 (x86_64-pc-windows-gnu, mingw-w64) -> srrevamp_native.dll
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/../client/native_bin"
mkdir -p "$out"
cargo="${CARGO:-cargo}"
command -v "$cargo" >/dev/null || cargo="$HOME/.cargo/bin/cargo"
case "${1:-linux}" in
  linux)
    "$cargo" build --release --locked --manifest-path "$here/Cargo.toml"
    cp "$here/target/release/libsrrevamp_native.so" "$out/" ;;
  windows)
    "$cargo" build --release --locked --manifest-path "$here/Cargo.toml" --target x86_64-pc-windows-gnu
    cp "$here/target/x86_64-pc-windows-gnu/release/srrevamp_native.dll" "$out/" ;;
  *) echo "usage: $0 [linux|windows]" >&2; exit 2 ;;
esac
ls -la "$out"
