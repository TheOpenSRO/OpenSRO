# srrevamp_native: the native (Rust) asset readers

Round 667's spike (docs/WORLD_ISSUES.md, "Six-hundred-and-sixty-seventh round"): a GDExtension
that does, in Rust, the asset-reading work the world load measured as most expensive in
GDScript. It is optional. Without the library the client reads everything in GDScript exactly as
before.

## What is in it

| Piece | Replaces (GDScript) | Where |
|---|---|---|
| pk2 archive: open, directory read + Blowfish decrypt, name index, path lookup, positional file read | `Pk2Reader` internals and `ObjectLoader.find_file`'s scan | `src/core/pk2.rs`, `src/core/blowfish.rs` |
| `.ddj` per-pixel decodes: uncompressed (channel masks) and A16B16G16R16F (`q`) | the two looping branches of `DdjReader.to_image` | `src/core/ddj.rs` |

- `src/core/` is plain Rust with no Godot types. It is unit-tested with `cargo test` and can sit
  behind a C ABI and be linked statically into custom export templates later, if antivirus
  software objects to a separate DLL.
- `src/gd.rs` is the thin gdext binding: two `RefCounted` classes, `SrNativePk2` and
  `SrNativeParsers`. Results go back in bulk, as packed arrays or one Dictionary per call. There is
  never a Variant per element.
- The client never names these classes as types. `client/scripts/pk2/native_assets.gd` looks them
  up by string through `ClassDB`, so every script compiles without the library.
  `client/srrevamp_native.gdextension` names the library files.

## Build

The toolchain is Rust 1.98.1 (pinned in release.yml and ci.yml). `godot` is pinned to `=0.5.5` with `api-4-2`
and `experimental-threads`. Cargo.lock is committed, and the builds use `--locked`.

```
curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
native/build.sh            # Linux: client/native_bin/libsrrevamp_native.so
native/build.sh windows    # Windows: client/native_bin/srrevamp_native.dll
native/build.sh linux-release  # the release .so, glibc floor 2.28 (needs zig + cargo-zigbuild; see "CI")
```

`client/native_bin/`, `native/target/` and every `.so`/`.dll` are git-ignored. **Never commit a
built library.**

**The interface number.** `API` in `src/core/mod.rs` and `NATIVE_API` in
`client/scripts/pk2/native_assets.gd` are the same constant. **Bump both** with any change to a
binding's name, arguments or results, or to what a parser returns.

The client uses a library only when its `api()` returns exactly its own number. Since
`client/native_bin` is git-ignored, it survives a pull, so a stale library is the expected failure.
The client refuses it with one log line naming both numbers, then reads in GDScript:

```
NativeAssets: native readers OFF (library REFUSED: API 0, this client needs API 2 -- a stale library, rebuild it with native/build.sh) -- using the GDScript readers
```

The same line catches the release case: a DLL from an older release left next to a newer exe by an
update that could not replace it (round 668, `docs/NATIVE_ON_WINDOWS.md`).

Round 667's builds before the number existed answer API 0. `remote_godot.sh` also mirrors
`client/native_bin` onto the box exactly: when the local tree has no library, the box's copy is
deleted.

**glibc.** A library linked by the host's own toolchain needs the glibc of the machine that built
it. `native/build.sh` on the `claude` LXC (Ubuntu 24.04) gives **GLIBC_2.34**, from `dlsym` and
`pthread_key_*` (checked with `objdump -T`). The render box (Debian 13, glibc 2.41) is fine. **The
release `.so` is built against glibc 2.28** with `native/build.sh linux-release` (zig through
cargo-zigbuild), which is Godot 4.2.2's own floor (round 668, "CI and the release" below).

Why `experimental-threads`: World3D calls the readers from WorkerThreadPool tasks while the main
thread also calls them. Without the feature, gdext's instance binding is single-threaded. Every
method takes `&self`. The archive keeps its directory cache behind a mutex, and it reads by
position (`pread` / `seek_read`), so threads share no file cursor.

## Test

```
cd native && cargo test --no-default-features          # the core: Blowfish vectors, a synthetic pk2, ddj decodes
client/tools/remote_godot.sh script res://scripts/pk2/native_assets_test.gd   # both paths, synthetic input, on the box
```

`remote_godot.sh` ships `client/native_bin` when it exists. `NO_NATIVE=1 client/tools/remote_godot.sh
tests` ships the `.gdextension` without the library, and removes any copy already on the box. That
is the client CI and a player without the DLL see. Godot prints four `ERROR` lines while loading the
extension, then every suite runs as before (round 667: 179 suites, 0 failing).

## Parity

`client/tools/native_parity.gd` holds the native readers to the GDScript ones on the **real**
archives on the render box. It compares every directory of every archive, lookups, file bytes,
and every per-pixel `.ddj` decode. The counts are in round 667's WORLD_ISSUES entry. Its output is
never committed.

```
client/tools/remote_godot.sh script res://tools/native_parity.gd -- --pk2-dir=/opt/sro-files/client
```

**The negative.** `cargo build --release --features parity-negative` makes a library with two
deliberate, subtle bugs: it drops the 20th entry slot of each directory block, and it leaves an
uncompressed texture's BGR unswizzled. Both the parity tool and `native_assets_test.gd` must FAIL
against it, and so must `cargo test --features parity-negative`.

## A/B

`SRREVAMP_NATIVE=0` forces the GDScript path in a build that has the library. The client logs
`NativeAssets: native readers ON|OFF (...)` once. `client/tools/README.md`, "Native readers A/B",
gives the perf-gate recipe (`--ab-env`, `--cold`). The same section has the rule that keeps the
ordinary gate from crediting a round with the native speed-up.

## Windows

`native/build.sh windows` cross-compiles for `x86_64-pc-windows-gnu` with mingw-w64
(`apt install gcc-mingw-w64-x86-64`, `rustup target add x86_64-pc-windows-gnu`).

Why GNU and not MSVC:
- It builds on the Linux runner with distribution packages alone. `cargo-xwin` would download
  Microsoft's CRT and SDK under Microsoft's licence terms.
- The resulting DLL imports only system DLLs (`KERNEL32`, `msvcrt`, `ntdll`, `USERENV`, `WS2_32`,
  `bcryptprimitives`, `api-ms-win-core-synch`). There is no MinGW runtime DLL to ship beside it.
- The GDExtension interface is a C ABI, so the C++ compiler that built Godot does not matter.

It exports `gdext_rust_init`, the entry symbol the `.gdextension` names (checked with
`x86_64-w64-mingw32-objdump -p`). **It has not been run on Windows.**

On a Windows PC, put `srrevamp_native.dll` in `native_bin\` next to the project, or next to the
exe in an export (see below). Then check the log for:

```
NativeAssets: native readers ON (library loaded, srrevamp_native 0.1.0, API 2, <path of the DLL>)
```

`native readers OFF (library not found: <path>)`, after Godot's `GDExtension dynamic library not
found` error, means the DLL was not there; Godot carries on in GDScript. Every form of the line,
and the rename test: `docs/NATIVE_ON_WINDOWS.md`.

**Unsigned DLLs.** The DLL is unsigned, like the client exe. SmartScreen and some antivirus
products treat a fresh, unsigned DLL with no download reputation as suspicious, and may quarantine
it. The client then just runs without it, in GDScript. If that happens to players, there are two
fixes: sign the binaries (an Authenticode certificate), or link the core statically into custom
export templates. Static linking is why the core is kept free of Godot types.

## CI and the release (round 668)

`release.yml` builds both libraries on every tag, before the import and the exports, and ships
each in its zip **next to the executable**. Godot 4.2.2 exports a GDExtension library there
(`editor_export_platform_pc.cpp`). At runtime, `OS::open_dynamic_library` falls back to the
executable's folder when `res://native_bin/…` is not a real file. `export_presets.cfg` includes
`srrevamp_native.gdextension` again.

The steps, in order:
1. `native/ci_toolchain.sh` sets up the toolchain on the ephemeral `kakariko-runner` pod. It
   installs mingw-w64 (and a host `cc`) through apt, as root or with `sudo -n`. It installs
   rustup with the pinned toolchain (`RUST_TOOLCHAIN`, 1.98.1, set in release.yml and ci.yml)
   and the `x86_64-pc-windows-gnu` target. It also downloads zig 0.15.2 and cargo-zigbuild
   0.23.4, each checked against a pinned SHA-256. Nothing is cached. Uncached, the install took
   43 s and both builds 36 s (MEASURED, probe run 36808460104). Saving the 1.9 GB cache was
   still running after five minutes, on top of that.
2. `native/build.sh linux-release` builds the `.so` with `cargo zigbuild --target
   x86_64-unknown-linux-gnu.2.28`.
3. `native/build.sh windows` builds the DLL with mingw-w64.
4. `client/tools/check_native_library.sh` fails the build if either library:
   - needs anything beyond base system libraries (on Windows: only system DLLs, so no
     `libgcc_s_seh-1.dll`, `libwinpthread-1.dll` or `libstdc++`);
   - does not export `gdext_rust_init`;
   - carries debug sections or symbols;
   - (the `.so` only) asks for a glibc symbol above the floor.
5. Each zip gets a `THIRD_PARTY_NOTICES.txt` from `native/third_party_notice.sh`. It is generated
   from Cargo.lock with `cargo tree` and lists every crate, its licence and its exact crates.io
   source. The godot-rust crates are MPL-2.0, and MPL section 3.2(a) asks that recipients be told
   where the source is. Then come the full texts:
   - each crate's licence, from cargo-about 0.9.2 (pinned, SHA-256 checked; `native/about.toml`,
     `native/about.hbs`);
   - the Rust standard library's COPYRIGHT and licences (`native/licenses/`);
   - Godot Engine's own licence with the copyright and licence of every third-party part built
     into it, read from the engine itself by `client/tools/print_godot_licenses.gd`.
6. `client/tools/check_release_zip.sh` checks both zips: exe, `.pck`, library next to the exe,
   notices, and the `.gdextension` and `extension_list.cfg` inside the `.pck`. It then runs the
   exported Linux game headless twice:
   - as shipped, it must log `native readers ON` and no GDExtension error;
   - with the library renamed to `.off`, it must log `native readers OFF`.
7. A `workflow_dispatch` run without a tag keeps both zips as a 3-day artifact
   (`srrevamp-test-build`) and publishes nothing.

**The glibc floor is 2.28, chosen deliberately.** Godot 4.2.2's own Linux binary and its export
template need GLIBC_2.28 at most (MEASURED with `objdump -T`, round 668). A `.so` linked on the
runner's own glibc asked for GLIBC_2.34, which would have made the library, and nothing else,
refuse to load on Debian 10, Ubuntu 20.04 or RHEL 8. Linked by zig against 2.28, the library
never asks for more than the engine already does. A system older than that cannot run Godot
4.2.2 at all. `GLIBC_FLOOR` overrides the floor for both the build and the check.

`ci.yml` keeps "Validate client" free of the library on purpose: that job is the client a player
without the DLL runs. A separate `native` job does three things:
- runs `cargo test --no-default-features`;
- builds the release `.so`;
- runs every GDScript suite with the library loaded (`client/tools/run_gd_tests.sh`), after
  checking that `native_status_test.gd` sees `native readers ON`.

What a Windows tester sees, and the rename test: `docs/NATIVE_ON_WINDOWS.md`. How the auto-updater
replaces a DLL the game has loaded: `client/scripts/update/update_installer.gd` and that page.
