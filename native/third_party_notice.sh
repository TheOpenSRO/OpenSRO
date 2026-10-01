#!/bin/bash
# Writes THIRD_PARTY_NOTICES.txt for a release zip (round 668): the crates built into the
# native readers' library, their licences, and where each one's exact source lives. The
# godot-rust crates are MPL-2.0, whose section 3.2(a) asks that recipients of an
# executable be told how to obtain the source; crates.io keeps every published version.
#   native/third_party_notice.sh x86_64-pc-windows-gnu   > THIRD_PARTY_NOTICES.txt
#   native/third_party_notice.sh x86_64-unknown-linux-gnu > THIRD_PARTY_NOTICES.txt
# Generated from Cargo.lock through `cargo tree`, so it cannot drift from what was built.
set -euo pipefail
target="${1:?target triple}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cargo="${CARGO:-cargo}"
command -v "$cargo" >/dev/null || cargo="$HOME/.cargo/bin/cargo"

case "$target" in
  *windows*) lib="srrevamp_native.dll" ;;
  *) lib="libsrrevamp_native.so" ;;
esac

# name vX.Y.Z[ (proc-macro)]|licence|repository, once each. Normal and build edges: the
# build-time crates (code generators, proc-macros) shape the library's code too.
rows=$("$cargo" tree --locked --manifest-path "$here/Cargo.toml" -e normal,build \
  --target "$target" --prefix none --format '{p}|{l}|{r}' | sed 's/ (\*)$//' | sort -u)

cat <<EOF
THIRD-PARTY NOTICES

$lib, next to the game's executable, is srrevamp's native asset reader (the source is
the srrevamp repository's native/ folder, MIT licence). It is built from the Rust crates
below. Each line gives the crate, its licence, and where its exact source can be
downloaded; https://crates.io/crates/<name>/<version> shows the same.

The godot-rust crates (godot, godot-core, godot-ffi, godot-cell, godot-macros,
godot-bindings, godot-codegen, gdextension-api) are licensed under the Mozilla Public
License 2.0 (https://mozilla.org/MPL/2.0/). Their source code form is available at the
crates.io links below and at https://github.com/godot-rust/gdext. They are used
unmodified.

Licence texts: MIT https://opensource.org/license/mit ; Apache-2.0
https://www.apache.org/licenses/LICENSE-2.0 ; MPL-2.0 https://mozilla.org/MPL/2.0/ ;
Unicode-3.0 https://www.unicode.org/license.txt

Crates ($target):
EOF
while IFS='|' read -r pkg licence repo; do
  name="${pkg%% *}"
  rest="${pkg#* v}"
  version="${rest%% *}"
  note=""
  case "$pkg" in *"(proc-macro)"*) note=" (build time only)" ;; esac
  if [ "$name" = srrevamp_native ]; then
    echo "  srrevamp_native $version  $licence  (this project, native/)"
    continue
  fi
  echo "  $name $version  $licence$note"
  echo "      source: https://crates.io/api/v1/crates/$name/$version/download${repo:+  (repository $repo)}"
done <<< "$rows"

cat <<EOF

The Rust standard library is linked in as well (MIT OR Apache-2.0,
https://github.com/rust-lang/rust).
EOF
case "$target" in
  *windows-gnu*) cat <<'EOF'
The Windows build links the mingw-w64 runtime's startup objects and libgcc's support
routines statically (mingw-w64: ZPL-2.1 and other permissive licences,
https://www.mingw-w64.org ; libgcc: GPL-3.0 with the GCC Runtime Library Exception,
https://gcc.gnu.org/onlinedocs/libstdc++/manual/license.html).
EOF
  ;;
esac
