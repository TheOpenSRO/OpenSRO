#!/bin/bash
# Installs what the native readers' release build needs on a CI runner (round 668;
# native/README.md, "CI"): mingw-w64 for the Windows .dll (x86_64-pc-windows-gnu); zig and
# cargo-zigbuild for the Linux .so, which is linked against glibc 2.28 whatever the runner's
# own glibc is (native/build.sh linux-release); and rustup with the pinned toolchain
# ($RUST_TOOLCHAIN) and the Windows target. zig and cargo-zigbuild are pinned and their
# downloads checked against SHA-256 sums. Idempotent: an existing rustup, zig or
# cargo-zigbuild is reused, and packages already present are not reinstalled.
#
# The runner (kakariko-runner) is an ephemeral pod. It is not assumed to be root: apt runs
# through `sudo -n` when the user is not root, and the script stops with a clear message
# when neither is possible.
set -euo pipefail
toolchain="${RUST_TOOLCHAIN:?set RUST_TOOLCHAIN, e.g. 1.98.1}"

echo "runner: user $(id -un) (uid $(id -u)), $(. /etc/os-release && echo "$PRETTY_NAME"), $(nproc) cores"

need=()
# A host C linker: build scripts and proc-macros are compiled for the runner itself.
command -v cc >/dev/null 2>&1 || need+=(gcc libc6-dev)
command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 || need+=(gcc-mingw-w64-x86-64)
command -v x86_64-w64-mingw32-objdump >/dev/null 2>&1 || need+=(binutils-mingw-w64-x86-64)
command -v curl >/dev/null 2>&1 || need+=(curl ca-certificates)
command -v unzip >/dev/null 2>&1 || need+=(unzip)
command -v xz >/dev/null 2>&1 || need+=(xz-utils)
command -v objdump >/dev/null 2>&1 || need+=(binutils)
if [ "${#need[@]}" -gt 0 ]; then
  if [ "$(id -u)" = 0 ]; then
    sudo=()
  elif sudo -n true 2>/dev/null; then
    sudo=(sudo -n)
  else
    echo "::error::missing ${need[*]} and no root or passwordless sudo to install them" >&2
    exit 1
  fi
  echo "installing: ${need[*]}"
  "${sudo[@]}" apt-get update -qq
  "${sudo[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${need[@]}"
fi

export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v rustup >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain none --no-modify-path
fi
rustup toolchain install "$toolchain" --profile minimal --target x86_64-pc-windows-gnu
rustup default "$toolchain"
if [ -n "${GITHUB_PATH:-}" ]; then echo "$HOME/.cargo/bin" >> "$GITHUB_PATH"; fi

# zig 0.15.2 (sum from https://ziglang.org/download/index.json) and cargo-zigbuild 0.23.4
# (sum from its release's .sha256 file), both read on 2026-09-30.
tools="$HOME/.local/srrevamp-ci"
zig_dir="$tools/zig-x86_64-linux-0.15.2"
if [ ! -x "$zig_dir/zig" ]; then
  mkdir -p "$tools"
  curl -sSfL -o "$tools/zig.tar.xz" https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz
  echo "02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239  $tools/zig.tar.xz" | sha256sum -c -
  tar -xJf "$tools/zig.tar.xz" -C "$tools" && rm "$tools/zig.tar.xz"
fi
if [ ! -x "$HOME/.cargo/bin/cargo-zigbuild" ]; then
  curl -sSfL -o "$tools/czb.tar.xz" https://github.com/rust-cross/cargo-zigbuild/releases/download/v0.23.4/cargo-zigbuild-x86_64-unknown-linux-musl.tar.xz
  echo "9e3cf73485edbd45905c8aadbc0fdf869c7ddc3848f0c898229f2680db52e44b  $tools/czb.tar.xz" | sha256sum -c -
  tar -xJf "$tools/czb.tar.xz" -C "$tools"
  install -m 755 "$tools/cargo-zigbuild-x86_64-unknown-linux-musl/cargo-zigbuild" "$HOME/.cargo/bin/"
  rm -rf "$tools/czb.tar.xz" "$tools/cargo-zigbuild-x86_64-unknown-linux-musl"
fi
# cargo-about 0.9.2 (sum from its release's .sha256 file, read 2026-10-01): the crates'
# full licence texts for THIRD_PARTY_NOTICES.txt (native/third_party_notice.sh).
if [ ! -x "$HOME/.cargo/bin/cargo-about" ]; then
  mkdir -p "$tools"
  curl -sSfL -o "$tools/about.tar.gz" https://github.com/EmbarkStudios/cargo-about/releases/download/0.9.2/cargo-about-0.9.2-x86_64-unknown-linux-musl.tar.gz
  echo "9099a59e820c38a68b9d65f300662a567d56562f9a10f6aa4c7e86c17c2566af  $tools/about.tar.gz" | sha256sum -c -
  tar -xzf "$tools/about.tar.gz" -C "$tools"
  install -m 755 "$tools/cargo-about-0.9.2-x86_64-unknown-linux-musl/cargo-about" "$HOME/.cargo/bin/"
  rm -rf "$tools/about.tar.gz" "$tools/cargo-about-0.9.2-x86_64-unknown-linux-musl"
fi
export PATH="$zig_dir:$PATH"
if [ -n "${GITHUB_PATH:-}" ]; then echo "$zig_dir" >> "$GITHUB_PATH"; fi

rustc --version
zig version
# cargo-zigbuild treats its own arguments as the zigbuild subcommand's (probe run
# 36808132225): ask cargo for the subcommand's help to prove it is installed.
cargo zigbuild --help > /dev/null && echo "cargo-zigbuild 0.23.4 installed"
cargo --version
cargo-about --version
x86_64-w64-mingw32-gcc --version | head -1
cc --version | head -1
