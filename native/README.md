# opensro_native: the native (Rust) asset readers

Round 667's spike (docs/WORLD_ISSUES.md, "Six-hundred-and-sixty-seventh round"): a GDExtension
that does, in Rust, the asset-reading work the world load measured as most expensive in
GDScript. It is optional. Without the library the client reads everything in GDScript exactly as
before.

## What is in it

| Piece | Replaces (GDScript) | Where |
|---|---|---|
| pk2 archive: open, directory read + Blowfish decrypt, name index, path lookup, positional file read | `Pk2Reader` internals and `ObjectLoader.find_file`'s scan | `src/core/pk2.rs`, `src/core/blowfish.rs` |
| `.pk3` (zip) asset pack (round 789, OURS): central directory incl. zip64, case-insensitive path index, stored reads, deflate (miniz_oxide) into a buffer of the declared size with its CRC-32 checked, the safety refusals | `Pk3Reader`'s GDScript reader (its twin and reference) | `src/core/pk3.rs`, binding `SrNativePk3` in `src/gd.rs` (interface 6) |
| `.ddj` per-pixel decodes: uncompressed (channel masks) and A16B16G16R16F (`q`) | the two looping branches of `DdjReader.to_image` | `src/core/ddj.rs` |
| the DXT1 transparent-texel scan (round 695): does any block of a DXT1 mark a texel transparent, so Forward+ needs it as RGBA8 | `DdjReader.dxt1_has_transparent`'s block loop | `src/core/dxt.rs` (`ddj_dxt1_has_transparent`; interface still 5: an additive method, called behind `has_method`, so an older library keeps the other readers); `examples/dxt1_alpha_census.rs` counts them in an archive |
| `.bms` mesh: header, vertices (either record size), skin (with its part-way refusal), indices, box, motion and link sections; `to_arrays`' winding and skin arrays | `BmsReader.parse` and `to_arrays` (round 669) | `src/core/bms.rs`, binding `src/gd_models.rs` |
| `.ban` animation: header, key times, every bone's keyframes | `BanReader.parse` (round 669) | `src/core/ban.rs`, binding `src/gd_models.rs` |
| `.bsk` skeleton: the announce-then-resolve walk, both record shapes | `BskReader.parse` (round 669) | `src/core/bsk.rs`, binding `src/gd_models.rs` |
| the UTF-16 text tables (round 671): the decode, the line and tab splits and each reader's row loop for characterdata, npcpos, itemdata, the UI string tables and skilleffect | `NpcTableReader`'s ten parsers, `ItemTableReader.parse`, `UiTextTable.parse`, `SkillEffectReader.parse_all` | `src/core/tables.rs`, binding `src/gd_tables.rs` |
| the lightmap term's per-byte loop; the `.m` (JMXVMAPM) and `.nvm` (JMXVNVM) decodes, proven but not on the load path (round 670) | `MapmTerrainBuilder.lightmap_term`'s loop; `MapmReader.parse` and `NvmReader.parse` through their `parse_native` | `src/core/terrain.rs`, binding `src/gd_terrain.rs` |
| the per-vertex cloth (round 794): Dynamic Animation's step (retail `CCompChar::FUN_00c0d010`), the pinned vertices' skin and the vertex stream Godot draws | `ClothSim` (its twin; `cloth_test.gd` holds the two together) | `src/core/cloth.rs`; binding `src/gd_cloth.rs` (`SrCloth`, its own `cloth_api` 1, so core::API is unchanged) |
| the effect simulation (round 763): EfpSim's per-frame stepping, EfpSimBatch's ordered particle cap on a Rust thread pool, and the MultiMesh buffers and Link chains of what it draws | `EfpSim.advance` / `step` / `growth_bounds` and `EfpSimBatch.run` for EquipFx's masters; `EfpEffect._update_draws`' arithmetic and `EfpLinks.gather_from` | `src/core/efp_sim.rs`, `efp_batch.rs`, `efp_out.rs`, `gdmath.rs`, `pool.rs`; binding `src/gd_efp.rs` |

- `src/core/` is plain Rust with no Godot types. It is unit-tested with `cargo test` and can sit
  behind a C ABI and be linked statically into custom export templates later, if antivirus
  software objects to a separate DLL.
- `src/gd.rs` is the thin gdext binding: `RefCounted` classes `SrNativePk2`, `SrNativePk3` (round 789) and
  `SrNativeParsers`. `src/gd_models.rs` (round 669) adds `SrNativeModels` for the model readers,
  reached through `NativeAssets.models()`. Results go back in bulk, as packed arrays or one Dictionary per call. There is
  never a Variant per element.
- The client never names these classes as types. `client/scripts/pk2/native_assets.gd` looks them
  up by string through `ClassDB`, so every script compiles without the library.
  `client/opensro_native.gdextension` names the library files.

## The Vulkan -> OpenGL fall back (round 693's review)

`src/vk_fallback.rs`, run from `gd.rs`'s `on_stage_init(Core)`. It is not a reader and not a
binding: no class, no `#[func]`, so `core::API` is unchanged.

- **The problem.** Forward+ is the client's default. Godot 4.2.2 has no fall back of its own: a
  machine without Vulkan gets "Unable to initialize Vulkan video driver" and the game exits (READ,
  display_server_windows.cpp; `fallback_to_opengl3` is 4.3).
- **Why at Core.** The library is loaded at Core level for the game: `min_level` is Core unless the
  command line holds `--editor` / `-e` / `--import` / `--project-manager` / `--export*`. Godot
  initialises Core in `register_core_extensions` (main.cpp 1647), before it reads the renderer
  (main.cpp 1966). No Godot API is usable there on 4.2.
- **What it does.** It opens the system's Vulkan loader at run time (`libvulkan.so.1` /
  `vulkan-1.dll`) and creates an instance with `VK_KHR_surface` plus the platform surface
  extension. It then counts the physical devices. If any step fails, it starts the game again with
  `--rendering-driver opengl3`, put before any `--`, and ends this process: `exec` on Linux,
  spawn + `TerminateProcess` on Windows.
- **The record.** `OPENSRO_VK_PROBE` carries the result (`ok N device(s) in X ms` /
  `fallback to OpenGL: <why> (X ms)`). Boot logs it, and `RendererChoice` records the Compatibility
  start in `override.cfg`.
- **When it does nothing:** a renderer, driver or display driver on the command line, `--headless`,
  the editor or an export, a set `OPENSRO_VK_PROBE` (the restarted child), or an `override.cfg`
  beside the executable that already chooses `gl_compatibility`.
- **Why the editor and imports stay at Scene.** A first `--headless --import --quit` of a project
  whose `.godot/` does not list the extension yet never finished with the library at Core.
  MEASURED: still running after 180 s; 15 s at Scene.
- **MEASURED on the box (Linux, editor binary, windowed):**
  - a plain start finds 2 devices in 28 ms and runs Forward+;
  - with `VK_ICD_FILENAMES=/dev/null` it restarts and runs Compatibility (the probe takes 0.3 ms);
  - without the library the same start stops at "Could not initialize Vulkan".
  - `client/tools/renderer_fallback_box_test.sh` is the end-to-end check.
- **NOT RUN: the Windows path.** It is compiled and checked by `check_native_library.sh`, but no
  Windows machine has run it.
- **Without the library** there is no automatic fall back. The release zips carry the Compatibility
  launcher for that case.

## The asset pack reader (round 789)

`SrNativePk3` (`src/gd.rs`) over `core::pk3::Pk3` reads a `.pk3`, a plain zip of pk2 paths (docs/TODO.md,
"Asset packs"; deploy/README.md, "Asset packs"). Everything about packs is OURS: retail has only `.pk2`.
`client/scripts/pk2/pk3_reader.gd` is the GDScript twin; both are held to one answer by
`client/scripts/pk2/pk3_reader_test.gd`'s parity case.

- **Methods** (all `&self`, safe from any thread): `open(path)`, `last_error()`, `is_zip64()`,
  `find(path)` -> `{name, kind, offset, size}` where `offset` is an id (a file's index, or a folder's;
  the root's is 0), `list_dir(id)` -> `{names, kinds, offsets, sizes}` (SrNativePk2's shape),
  `read(id)` -> `{bytes}` or `{error}`, `paths()` (every file as written), `refused()` /
  `refused_count()`, `file_count()`, `stats()`.
- **Open** reads the end record (and the zip64 locator and end record when present), then the whole
  central directory once, and indexes every file and folder by its lower-cased `/` path. Folders are
  made from the files' paths; a file whose name is also a folder's is refused, and of two entries
  with one name the first is kept (the pk2 index keeps the first too).
- **Read**: a stored entry is read positionally (pread / seek_read), as `pk2.rs` reads; a deflated
  one is inflated by `miniz_oxide::inflate::decompress_slice_iter_to_slice` into a buffer of exactly
  its declared size, so it cannot grow past it, and its CRC-32 is checked (`crc32fast`: a
  byte-at-a-time table made the native read of all of Data.pk3 slower than Godot's zlib, 15.1 s
  against 11.0 s; with it 8.5 s, MEASURED by `client/tools/pk3_parity.gd`).
- **Lookups** follow docs/protocol/asset_packs.md rule 4, as `pk2.rs`'s `find` does from round 789
  (`pk2::path_segments`): `\` and `/` alike, empty segments skipped, a `.`/`..` segment, a `:` or
  a NUL finds nothing; names fold with the Unicode SIMPLE lower-case mapping (`pk2::lower`, which
  no longer uses Rust's full `to_lowercase`: U+0130 folds to `i`). Allocation is fallible
  (`try_reserve_exact`), as `pk2.rs`'s: an untrusted size never aborts the process.
- **Refused at open** (left out, counted, the first 64 named; asset_packs.md "Safety"): a name with
  `..` or `.` segments, an absolute path, a drive letter or any `:`, a NUL or an empty segment; an
  encrypted entry; a method other than stored (0) or deflate (8); a symbolic link (a Unix-made
  entry's mode); a declared size over 256 MiB (twelve times the largest retail file, MEASURED:
  Data.pk2's `navmesh\ainavdata_32773.dat`, 21,352,219 bytes); an entry over 64 bytes declaring
  more than 1100 times its packed size; data past the end of the file. A pack whose entries
  together declare more than 1100 times the file's size (the overlapping "better zip bomb"), a
  split archive, a central directory past the file or over 4 million entries / 1 GiB refuses the
  whole archive.
- **The crates**: `miniz_oxide` 0.9.1 (`MIT OR Zlib OR Apache-2.0`; cargo-about takes MIT) and its
  dependency `adler2` 2.0.1 (`0BSD OR MIT OR Apache-2.0`); `crc32fast` 1.5.2 and its dependency
  `cfg-if` 1.0.5 (`MIT OR Apache-2.0`). All plain Rust. `third_party_notice.sh` lists the four
  (checked: its run names them).
- **Tests**: `cargo test --no-default-features pk3` (9: stored and deflated with and without zip64,
  unsafe names and lookups, bombs, lies and a symlink entry, the whole-pack ratio, conflicts,
  non-zips, an empty zip, 8 threads on one archive, the CRC's check value).
  `core::pk3::synth::build` writes the synthetic zips. On real data, `client/tools/pk3_parity.gd`
  reads every file of lane G's converted Data/Map/Media/Music/Particles `.pk3` through both readers
  against the `.pk2` (all 121,262 identical, round 789).

## The model readers (round 669)

`SrNativeModels` has `bms_parse`, `bms_wound_indices`, `bms_skin_arrays`, `ban_parse` and
`bsk_parse`. Each
returns one Dictionary of packed arrays, or `{error}`.

- **The GDScript reader is the reference, and the native one answers what it answers.** Every
  float has the GDScript bit pattern. A float there goes f32 -> f64 (`decode_float`) -> f32
  (`Vector3`, `PackedFloat32Array`), which quiets a signalling NaN; `gd_f32` does the same. Strings
  are `get_string_from_ascii`'s: the bytes up to the first NUL, each a Latin-1 code point. A skin
  refused at vertex *i* keeps the bones and weights of vertices 0..*i*-1 and no palette, exactly
  as `_parse_skin`'s early return leaves them.
- **`{error}` always means "GDScript answers".** It is returned wherever the GDScript reader
  returns null, and for the input whose GDScript answer depends on Godot's negative indexing (a
  `.bms` header pointer at or above 2^31, which `PackedInt32Array` makes negative). The reader
  then runs its GDScript code, which reports its own error. So no input gets a different answer
  natively; at worst it gets the GDScript one.
- **A natively parsed `.bms` keeps its vertices as packed arrays.** `ParsedMesh.vertices` is a
  property: its getter builds the `Vertex` objects from the arrays on first access, the values
  identical. `to_arrays`, `vertex_count()` and `positions()` read the arrays. The world's objects
  and the monster assembler never build the objects. Building them was most of what the GDScript
  parse cost.
- **A `.ban`'s keyframes come back flat** (`key_counts`, `rotations` x/y/z/w, `positions`).
  `BanReader` builds the same `Bone` and `Keyframe` objects from them, because the per-frame code
  (`MonsterCrowd`, `Skeleton3DBuilder`) reads `track.keyframes` directly, and a getter there would
  cost every frame.
- Every offset read from the file is bounds-checked; nothing is allocated before the data is
  shown to hold it (`vec_with`, `try_reserve`). Truncated and randomly corrupted input returns an
  error and never panics (`truncated_and_random_input_never_panics`, in both modules).

## The effect simulation (round 763)

`SrEfpTemplate`, `SrEfpSim` and `SrEfpBatch` (`src/gd_efp.rs`), reached through
`client/scripts/efp/efp_sim_native.gd` (`EfpSimNative extends EfpSim`). EquipFx's masters use it
(`EfpEffect.use_native_sim`); every other effect stays GDScript.

- **The GDScript is the reference, bit for bit.** `core/efp_sim.rs` follows `efp_sim.gd` function by
  function. `core/gdmath.rs` is Godot 4.7.2's own f32 arithmetic in the engine's operand order
  (`Basis::operator*`'s `tdotx`, `xform`, `invert`'s cofactors, `orthonormalize`, `get_quaternion`,
  `Vector3::normalize`) with no fused multiply-add, and keeps in f64 what GDScript keeps in a
  `float` (an emitter's accumulator, the clock, the cone's angles, the scale graph's time). The
  random stream is Godot's `RandomPCG` (pcg32 with Godot's increment, `randf`'s clz/ldexp form);
  `sin`/`cos` are the C library's, as the engine's are -- so the bit-exact parity is Linux's
  (glibc both sides); the Windows DLL's mingw `sincos` (x87 `fsincos`) may differ in the last digit,
  which is cosmetic (round 763's review, I2). Two inputs where the GDScript itself
  differs between builds are taken as the editor/debug build does them: a singular basis's
  inverse is returned unchanged (`ERR_FAIL_COND(det == 0)` under MATH_CHECKS; a release template
  divides by zero).
- **Dead particles stay readable.** A GDScript particle is RefCounted: a dead parent's frozen
  position is still its children's parent position. The arena counts a particle's references (the
  list, its children) and frees it at zero; an emitter whose owner died is dropped, and a stale
  generation makes any later write to it a no-op (the GDScript writes to an orphaned object).
- **The batch** (`core/efp_batch.rs`) is round 761's ordered cap: spawn at own change d taken iff
  `base_i + d < limit_i`, base_i known exactly once the effects before have finished and bounded
  before that by each effect's published `growth_bounds`; an undecided spawn waits on a condition
  variable woken by every bound published and every effect finished. Claims are in list order, so
  the first unfinished effect never waits, at any pool size.
- **No cap** (USER DECISION 2026-10-09, round 763): the native masters' limit is unbounded
  (`EfpSimNative.limit_native`) and they count their particles apart (`live_native`), so
  `EfpSim`'s 2,000 cap applies to the GDScript effects only. The admission takes an unbounded limit
  as any other and decides every spawn at once.
- **The pool** (`core/pool.rs`): persistent helper threads that sleep between batches; the calling
  (main) thread always works too, so 0 helpers is one core. `EfpSimNative.configure` sizes it:
  `min(4, cores, Godot's WorkerThreadPool size)` threads in all by default, `OPENSRO_EFP_THREADS=<n>`
  to set it, `OPENSRO_QA_EFP_THREADS=0` for the main thread alone.
  Round 763's review: a batch under `POOL_MIN_WORK` (4,000 particle-steps; the swarm's are about
  520) runs on the main thread alone, so a helper descheduled on a busy machine cannot hold up a
  small batch; `OPENSRO_EFP_POOL_MIN_WORK=<n>` sets it (0: the pool whenever there are helpers).
- **Crash safety** (round 763's review, M1): every step runs under `catch_unwind`, on the pool's
  threads and the main thread. A panicking effect is marked broken and counted finished (nothing
  waits on it), the batch returns `{error}`, every lock survives a poisoned mutex, and the client
  turns the native simulation off for the session, its masters carrying on in GDScript. A sim
  listed twice in one batch is refused (L1). `SrEfpSim.qa_panic_next_step` is the test hook.
- **The outputs** (`core/efp_out.rs`), built on the thread that stepped the effect: one
  `PackedFloat32Array` a draw node in `RenderingServer.multimesh_set_buffer`'s layout (rows and
  origin, colour, custom data: 20 floats an instance), sized as `_update_draws` sizes the
  MultiMesh; and every Link node's chains as `gather_from` gathers them. The main thread hands
  them over (`EfpEffect._apply_native_draws`, `_update_links(native)`).
- **Its own interface number** (`SrEfpBatch.efp_api()`, `EfpSimNative.EFP_API`, 2 from round 785:
  a dead ancestor followed by its frozen state, `set_origin`'s `step_due`, `step_due`,
  `take_pass_moved`; 1 before): the classes are additive, so `core::API` is unchanged; a library
  without them (or with another number) leaves the masters in GDScript. `OPENSRO_EFP_NATIVE=0` forces that (the A/B);
  `OPENSRO_NATIVE=0` turns off every native piece.
- **Parity.** `cargo test` (the batch equals sequential stepping at 0-7 helpers with the cap
  binding; the pool; the PCG stream). `client/scripts/efp/efp_native_test.gd` (synthetic effects:
  every command family and follow level, one effect and the batch at 8 / 33 / 60 with the cap
  binding at 1 / 2 / 4 / every core, the draw buffers and chains). On the real files:
  `client/tools/efp_native_parity.gd` (every particle of every master every frame, prints
  `PARITY OK|FAIL`; `--time=1` times each mode):

```
client/tools/remote_godot.sh script res://tools/efp_native_parity.gd -- --n=60 --frames=600 --fps=30
```

## The text tables (round 671)

`src/core/tables.rs` ports each table reader's row loop one to one (its header lists which
function is which), with Godot 4.2.2's own string rules ported from `core/string/ustring.cpp`:
`parse_utf16` (a second BOM, FFFE byte-swapping, the stop at the first NUL), `strip_edges`,
`split`, `is_valid_int`, `to_int`, `is_valid_float` and `to_float` (`built_in_strtod`, which is not
a correctly rounded parse; `"1.5e"` is 15). `SrNativeTables` (`src/gd_tables.rs`) answers one
Dictionary of packed columns per call: the kept rows, in file order.

What stays in GDScript, on purpose:
- The merge into the caller's Dictionary, in row order, so a later duplicate id still overwrites
  an earlier one ("last wins"), and UiTextTable's "first wins" check.
- Building the readers' objects (`Item`, `Spawn`, `Vector3`, `Vector2`): their API is unchanged.
- Every `to_lower`/`to_upper` whose result is KEPT: a key formed by Godot's full-Unicode case
  tables (`ucaps.h`) stays with the engine that defines it rather than being ported (OURS). A
  test of a lower-cased value against a fixed ASCII string (`.bsr`, `.ddj`, `.efp`, `xxx`, `none`)
  is ported as an ASCII case-insensitive compare, which is exact because no code point outside
  ASCII lower-cases into ASCII in Godot 4.2.2 (MEASURED by round 671's review over every code
  point; 'I' lower-cases to 'i', its {0x0049, 0x0131} entry being commented out at ucaps.h:716).

Inputs the port hands back with `{"fallback": why}`, so the GDScript reads them exactly as before:
a decode that comes out empty (the readers then try UTF-8), an unpaired UTF-16 surrogate (Godot
keeps a lone trail as a character, which a Rust `String` cannot hold, and on a lone lead followed by
another character Godot 4.2.2 reads uninitialised memory), a U+FEFF anywhere after the leading
BOM, a negative UI language column, and a float exponent long enough to overflow the C++ `int`.
The U+FEFF rule is round 671's review: gdext 0.5.5 turns a Rust `&str` into a Godot `String`
through `string_new_with_utf8_chars_and_len`, that is `String::parse_utf8`, which skips a
LEADING UTF-8 BOM (READ, ustring.cpp 4.2.2), so a field that began with U+FEFF came back without
it while the GDScript (whose `strip_edges` keeps it) had it. `NativeAssets.table_rows()` turns a fallback
into `{}` and the caller runs its own loop.

The parity check is `client/tools/table_parity.gd` (below); the synthetic one is
`client/scripts/npc/native_tables_test.gd`, which runs every reader both ways on tables built to
hit the traps (BOMs, CRLF, comments, trailing tabs, duplicates, surrogates, number quirks) and from
8 worker threads at once.

### The terrain parsers (round 670)

`SrNativeTerrain` (`src/gd_terrain.rs`) is its own class, reached through
`NativeAssets.terrain()`. It is stateless; one instance serves every thread, made on the first
call under a lock.

- **On the load path: `lightmap_add(rgb, r, g, b)`.** It is `MapmTerrainBuilder.lightmap_term`'s
  per-byte loop: each RGB8 channel raised by the environment's TerrainShadowColor and saturated
  at 255. It took 28 ms a region in GDScript and takes 1.2 ms. On input that is not whole pixels
  it returns an empty array, and the GDScript loop runs and reports the problem.
- **Ported and proven, but not on the load path: `mapm_parse(bytes)` and `nvm_parse(bytes)`.**
  - Each returns one Dictionary of packed columns, one array per field, or `{error}` with the
    GDScript reader's own message.
  - `MapmReader.parse_native` and `NvmReader.parse_native` rebuild the reader's own
    `ParsedRegion` from those columns (`_from_native`).
  - `parse()` stays in GDScript, because round 670 measured no gain.
    - The decode takes about 0.1 ms a file.
    - Building the reader's objects from the columns costs as much as the whole GDScript parse:
      10,404 `Vertex` objects for a `.m`, and 9,216 `Tile` objects plus the cells and edges for
      a `.nvm`.
    - The numbers are in WORLD_ISSUES, round 670.
  - The parity tool and `terrain_native_test.gd` hold `parse_native` to `parse` on every real
    file. That makes it the decode the next step needs: keeping the columns on the region and
    moving its readers onto them (TerrainCollision, MapmTerrainBuilder, MapmWater, NavGraph).
    That step changes the API (docs/TODO.md).
- **Floats keep GDScript's bits.** GDScript widens each float32 to a 64-bit float and narrows it
  again, and on x86-64 that sets a signalling NaN's quiet bit. `f32_gd` does the same.
- **Not ported, measured too small:**
  - `.o2` (`MapO2Reader.parse`): 13 ms an entry.
  - The object index (`ObjidxReader`): 7 ms, once.
  - `tile2d.ifo`: 2 ms, once.
  - `.t` (`MapTReader.parse`): 33 ms an entry, most of it the engine's own DXT1 decompress.

## Build

The toolchain is Rust 1.98.1 (pinned in release.yml and ci.yml). `godot` is pinned to `=0.5.5` with `api-4-2`
and `experimental-threads`. Cargo.lock is committed, and the builds use `--locked`.

```
curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
native/build.sh            # Linux: client/native_bin/libopensro_native.so
native/build.sh windows    # Windows: client/native_bin/opensro_native.dll
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
NativeAssets: native readers OFF (library REFUSED: API 0, this client needs API 6 -- a stale library, rebuild it with native/build.sh) -- using the GDScript readers
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
cd native && cargo test --no-default-features          # the core: Blowfish vectors, a synthetic pk2, ddj decodes, bms/ban/bsk

cd native && cargo test --no-default-features          # the core: Blowfish vectors, a synthetic pk2, ddj decodes, text tables

cd native && cargo test --no-default-features          # the core: Blowfish vectors, a synthetic pk2, ddj decodes, synthetic .m/.nvm (round 670)

cd native && cargo test --no-default-features          # ... and the effect simulation, its batch and pool (round 763)
client/tools/remote_godot.sh script res://scripts/efp/efp_native_test.gd       # the effect simulation, both ways, on the box
client/tools/remote_godot.sh script res://scripts/pk2/native_assets_test.gd   # both paths, synthetic input, on the box
client/tools/remote_godot.sh script res://scripts/npc/native_tables_test.gd    # the text tables, synthetic, both ways
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

**The negative.** `cargo build --release --features parity-negative` makes a library with
deliberate, subtle bugs: it drops the 20th entry slot of each directory block, it leaves an
uncompressed texture's BGR unswizzled, it rounds a `.bms` vertex's skin blend to f32, it makes
a `.ban`'s last key time a millisecond late, it adds a space to a `.bsk`'s last parent name, and
it reads a one-colour DXT1 block as four-colour, missing its transparent texels (round 695). The parity tools and `native_assets_test.gd` /
`native_models_test.gd` must FAIL against it, and so must `cargo test --features parity-negative`.

The model readers have their own pass, over **every** `.bms` and `.ban` of the four archives
(round 669; the counts are in its WORLD_ISSUES entry):

```
client/tools/remote_godot.sh script res://tools/native_parity_models.gd -- --pk2-dir=/opt/sro-files/client
client/tools/remote_godot.sh script res://scripts/bms/native_models_test.gd    # synthetic, both ways
```

deliberate, subtle bugs: it drops the 20th entry slot of each directory block, and it leaves an
uncompressed texture's BGR unswizzled. Both the parity tool and `native_assets_test.gd` must FAIL
against it, and so must `cargo test --features parity-negative`. Round 671 adds three in the text
tables: a characterdata model column keeps its whole comma list (not the first file), a UI table
drops the first row of a duplicated token, and `to_float` uses Rust's correctly rounded parse.
`table_parity.gd` and `native_tables_test.gd` must FAIL against it.

The text tables have their own parity check, over every `.txt` in every archive (round 671):

```
client/tools/remote_godot.sh script res://tools/table_parity.gd -- --pk2-dir=/opt/sro-files/client
```

It compares the decode and both split shapes cell for cell, Godot's number rules on every distinct
cell (floats by bit pattern), every ported reader's whole result both ways (keys, key order, every
value), and the characterdata and itemdata parts merged in World3D's order. A table the port hands
back must be one whose UTF-16 really is not plain, and every reader must hand it back.

deliberate, subtle bugs:
- it drops the 20th entry slot of each directory block;
- it leaves an uncompressed texture's BGR unswizzled;
- (round 670) it flips the lowest bit of every terrain float read at a file offset that is 13
  modulo 97;
- (round 670) it saturates a lightmap's green at 254 instead of 255.

The parity tools, `native_assets_test.gd` and `terrain_native_test.gd` must all FAIL against it,
and so must `cargo test --features parity-negative`.

The terrain parsers have their own parity tool. It parses every `.m` and `.nvm` and
lightmap-terms every `.t`, both ways, and compares float bit patterns:

```
client/tools/remote_godot.sh script res://tools/native_parity_terrain.gd -- --pk2-dir=/opt/sro-files/client
```

## A/B

`OPENSRO_NATIVE=0` forces the GDScript path in a build that has the library. The client logs
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

On a Windows PC, put `opensro_native.dll` in `native_bin\` next to the project, or next to the
exe in an export (see below). Then check the log for:

```
NativeAssets: native readers ON (library loaded, opensro_native 0.1.0, API 6, <path of the DLL>)
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
`opensro_native.gdextension` again.

The steps, in order:
1. `native/ci_toolchain.sh` sets up the toolchain on the runner (the persistent `opensro-pve`
   runners since 2026-10-01, docs/CI_RUNNERS.md; until then the ephemeral `kakariko-runner` pod). It
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
   (`opensro-test-build`) and publishes nothing.

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
