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

The toolchain is Rust stable (built with 1.98.1). `godot` is pinned to `=0.5.5` with `api-4-2`
and `experimental-threads`. Cargo.lock is committed, and the builds use `--locked`.

```
curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
native/build.sh            # Linux: client/native_bin/libsrrevamp_native.so
native/build.sh windows    # Windows: client/native_bin/srrevamp_native.dll
```

`client/native_bin/`, `native/target/` and every `.so`/`.dll` are git-ignored. **Never commit a
built library.**

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
gives the perf-gate recipe (`--ab-env`, `--cold`).

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
Initialize godot-rust (API v4.2.stable.official, runtime v4.2.2.stable.official, ...)
NativeAssets: native readers ON (library loaded, srrevamp_native 0.1.0)
```

`native readers OFF (library not loaded)` together with a `GDExtension dynamic library not found`
error means the DLL was not found. Godot carries on in GDScript.

**Unsigned DLLs.** The DLL is unsigned, like the client exe. SmartScreen and some antivirus
products treat a fresh, unsigned DLL with no download reputation as suspicious, and may quarantine
it. The client then just runs without it, in GDScript. If that happens to players, there are two
fixes: sign the binaries (an Authenticode certificate), or link the core statically into custom
export templates. Static linking is why the core is kept free of Godot types.

## Exports and CI (not changed in this spike)

`client/export_presets.cfg` excludes `srrevamp_native.gdextension` from both presets. Godot 4.2.2's
exporter adds a library the `.gdextension` names to the export's shared objects and fails the
export if the file is missing (`editor/export/editor_export_platform_pc.cpp`, `da->copy`). The
release workflow does not build the library yet, so without this exclusion every tagged release
would fail.

To ship the library:
1. On `kakariko-runner` in `release.yml`, install rustup (with the `x86_64-pc-windows-gnu` target)
   and `gcc-mingw-w64-x86-64`, or cache them on the runner.
2. Before the export steps, run `native/build.sh` and `native/build.sh windows`.
3. Remove the exclusion from `export_presets.cfg`.

The exporter then copies each platform's library next to the exe.
