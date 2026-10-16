# Asset packs: `.pk3` beside `.pk2`

**Everything in this document is OURS.** Retail Silkroad reads only its `.pk2` archives; asset
packs, their layering and the converter are this project's own design (decided with the user
2026-10-01, docs/TODO.md "Asset packs"; built in round 789). Facts about the retail archives below
are **MEASURED** on the operator's retail client (`/opt/sro-files/client/` on the render box,
round 789) and say so.

A `.pk3` is a plain zip archive (`.zip` is accepted too). It holds files at their pk2 paths, so
adding an asset and overriding a retail one are the same operation.

The **Rules** section is the contract every reader implements identically: the Go tools
(`server/internal/assetfs`, section **Go**) and the client (GDScript and Rust; lane K adds its
section **Client**). A reader that differs from the Rules is a bug in that reader.

## Rules

### 1. Layers

A lookup checks layers from the highest down; **the first layer that has the path serves it.**

1. **`custom/`**, a loose folder: a path overlay (development, modding, and round 678's branding
   files, which live there too). By default it is the folder named `custom` **beside** the archive
   folder (a player's archives are in `pk2/`, and `custom/` is next to it); the client and the Go
   tools agree on this since round 789's merge.
2. **Packs**: every `*.pk3`, `*.zip` and `*.pk2` in the archive folder whose name is not one of the
   five base names. They cascade by name (rule 2).
3. **The base archives** `Data`, `Map`, `Media`, `Music`, `Particles` (as `.pk2`, or `.pk3`/`.zip`
   converted from them): **always the bottom**, whatever a pack is called, or `assets.pk3` would sort
   before `Data.pk2` and lose to it. There are five, not the four the TODO first listed.

Only the archive folder itself is scanned (no subfolders). An archive file may be a symbolic link;
nothing inside a pack or `custom/` may be.

### 2. The cascade by name

Archives are ordered by **file stem, lower-cased** (rule 4's folding), compared code point by code
point; for the same stem `.pk2` < `.zip` < `.pk3`; a tie after that (two names differing only in
case, on a case-sensitive disk) is broken by the exact file name in byte order. **Later in that
order wins.** So, highest first, for the TODO's example:

```
custom/  >  z_assets.pk3  >  z_assets.pk2  >  assets.pk3  >  Particles  >  Music  >  Media  >  Map  >  Data
```

Note the sort is textual: `pack10` sorts before `pack9`. The base archives cascade among themselves
by the same rule (rule 3 says why that rarely matters).

### 3. Volumes: a lookup names its base archive

The base archives are **not one namespace.** 40 paths exist in two of the five retail archives, and
**5 of them differ in content** (MEASURED, round 789):

| path | in | |
|---|---|---|
| `object.ifo` | Data, Map | differ (231,229 / 231,665 bytes); the world resolves against Map's (AGENTS.md) |
| `objectstring.ifo` | Data, Map | differ (47,388 / 40,444) |
| `regioninfo.txt` | Data, Map | differ (54,037 / 130,700) |
| `mapinfo.mfo` | Data, Map | differ (same size, other bytes) |
| `resinfo\itemtypenumber.txt` | Data, Media | differ (10,825 / 5,008) |
| `water\water101..130.ddj`, `objext.ifo`, `tile2d.ifo` | Data, Map | identical |
| `res\item\europe\shield\shield_16.bsr` | Data, Media | identical |
| `shader\vsp0.c`, `shader\vstech_p11.c` | Data, Particles | identical |

So a lookup is **scoped to a volume**, the base archive the caller means (the client always knows:
every `find_file` names its archive): `custom/`, then every pack, then **only that volume's** base
layers (`Data.pk3` above `Data.pk2` when both are there, rule 2). Packs and `custom/` overlay every
volume: a pack's `object.ifo` replaces both Data's and Map's. An **unscoped** lookup (a tool that does
not care which archive) sees the bases cascaded like packs (Particles over ... over Data).

OPEN: a pack cannot yet target one volume only (e.g. replace Map's `object.ifo` but not Data's).

### 4. Paths

- A path is the pk2's own: segments separated by `\` or `/`, alike.
- **Matching ignores case**: each name is folded with the **Unicode simple lower-case mapping, code
  point by code point**. For the Latin-1 code points a pk2 name holds that is: `A-Z` and
  U+00C0-U+00DE except U+00D7 move down by 0x20, nothing else changes (Godot's `to_lower` and
  `native/src/core/pk2.rs`'s `lower` do exactly this for those code points; above U+00FF, a reader
  must use the simple mapping, not Rust's full `to_lowercase`).
- **A pk2 name's bytes are Latin-1 code points**, one byte a character (what the client's
  `Pk2Reader` and `pk2.rs` already do). Retail has non-ASCII names (CP949 Korean bytes; MEASURED:
  Data 7, Media 3, Music 7, Particles 2, Map 0), e.g. Music's `\xb5\xb7\xc8\xb2.ogg`. Under this
  folding no two names in one retail folder collide (MEASURED: 0 shadowed entries in all five).
- **Zip entry names** are UTF-8 when the entry's general-purpose flag bit 11 is set (or the name is
  plain ASCII); otherwise they are read one byte a character (Latin-1; **not** CP437). The converter
  writes a pk2 name's Latin-1 code points as UTF-8 with bit 11 set, so `\xb5\xb7` becomes `µ·`.
- **Lookups** split on both separators and **skip empty segments** (a leading, trailing or doubled
  separator). A `.` or `..` segment, a `:` or a NUL makes the path unsafe: no layer serves it.
- In one directory of one archive, **the first entry of a folded name wins** (the client's linear
  `find_file` scan; pk2.rs's index). Every segment but the last must be a folder. Across layers the
  rule is per path: the first layer holding the whole path serves it, so a file in a high layer and
  a folder of the same name in a lower one do not mix.

### 5. Source mode

One setting: **`pk2`** (only `.pk2` archives, base and pack: today's behaviour), **`pk3`** (only
`.pk3`/`.zip`: the retail content converted once, no `.pk2` needed), or **`mixed`**, the default
(every type). `custom/` is read in every mode.

### 6. Safety

When a pack (or `custom/`) is opened, every entry is checked; an entry that fails is **refused**
(logged, listed with its reason) and the rest of the pack loads:

- names: absolute (a leading `/` or `\`), a drive letter (`X:`), any `:`, a NUL, a `.` or `..`
  segment, an empty segment (except one trailing separator, which marks a folder entry);
- only stored (method 0) and deflated (method 8) entries; no encrypted entries;
- a duplicate of an earlier entry's folded path, or a file where an earlier entry has a folder (or
  the reverse): the first one wins;
- **size**: an entry over **256 MiB** unpacked. The largest retail entry is 21,352,219 bytes
  (Data.pk2 `navmesh\ainavdata_32773.dat`, MEASURED), so this is twelve times that;
- **ratio**: an entry (over 64 bytes) that unpacks to more than **1100x** its packed size. And a
  pack whose entries together unpack to more than 1100x **the pack file's size** is not opened at
  all. Deflate cannot pack better than about 1032:1, so no honest entry or pack passes 1100:1;
  retail itself reaches **974.6:1** (Media.pk2 `script\image\qno_script_background_white.ddj`,
  MEASURED; next Data 504:1, Map 641:1, Particles 450:1), which is why the cap is not lower. What it
  catches: a lying header (an entry claiming more than its stream holds) and overlapping entries
  that point many directory records at one compressed stream (the "better zip bomb"). An honest
  single entry can still unpack ~1032x its size; the 256 MiB cap is what bounds that.
- A reader stops at the size an entry records and checks its CRC-32.
- In `custom/`, symbolic links are refused (nothing outside the folder is reachable through it).
  Inside a pack, an entry whose mode marks it a symbolic link is refused too (both readers).

**Every override is logged at load**: one line per `custom/` or pack file that hides a lower
layer's file. An archive that cannot be opened is skipped and logged (a tool may choose to fail
instead; the Go exporters do).

### 7. Store or deflate (the converter and the pack builder)

Measured with deflate level 6 over up to 300 files (and 64 MiB) of each extension in the five
retail archives (`pk2topk3 -measure`, round 789), then over every file by the conversion itself:

| ext | packed / unpacked | |
|---|---|---|
| `.ogg` | 99.4% (sample), stored | **stored** |
| `.rar` | 98.6% | **stored** |
| `.png` | 90.3% | **stored** |
| `.wav` | 80.9% (Data, all 2,961 files) | deflated |
| `.ddj` | 24.8% Particles, 40.0% Media, 59.4% Data, 80.3% Map | **stored** (the plan's choice; see below) |
| `.bms` 41.7%, `.ban` 64.5%, `.nvm` 26.6%, `.t` 6.3%, `.m` 33.7%, `.efp` 17.9%, `.txt` 28.1% | | deflated |

So the policy (`assetfs.StoredExtensions`) stores `.ddj` (below), `.ogg`, `.rar`, `.png`
(MEASURED) and the formats that are compressed by construction (`.jpg`, `.jpeg`, `.mp3`, `.zip`,
`.pk3`, `.7z`, `.gz`, `.webp`; INFERRED from the formats, none is in retail) and deflates
everything else; an entry that deflate does not make smaller is stored anyway. **`.ddj` is
stored**, as the plan decided (docs/TODO.md, 2026-10-01), although its DXT blocks deflate to
25-80% (MEASURED, so they are not "already compressed"): the game reads textures far more often
than it installs them. MEASURED at the round's merge (`pack_bench.gd`, 20,000 Data reads,
native, medians of 5): 2,636 ms with `.ddj` deflated, 2,076 ms with it stored, 241 ms from
Data.pk2 -- storing `.ddj` saves about a fifth of the read time for 0.63 GB more on Data.pk3
(2.59 GB against 1.96), and the rest of the gap to the `.pk2` (which is not compressed at all) is
the inflate of the other deflated types; the world entry measured SAME either way (lane K). An
operator who prefers the smaller pack passes `-deflate .ddj`. (Lane G's first conversion deflated `.ddj`; the round's merge
switched the default back to the plan.)

The output is deterministic: entries in the pk2's directory order, every folder as a folder
entry, every timestamp 1980-01-01. Two conversions of Data.pk2 were byte-identical (MEASURED).

## Go

`server/internal/pk2` (the pk2 reader) gained the lookup the ten `cmd/*` tools each carried a copy
of: `Find` / `ReadPath` / `Children` (rule 4, with a per-folder name index cached for
the archive's lifetime), `Walk` (what `Find` reaches) / `WalkAll` (every entry, shadowed ones
flagged), `OpenEntry` (a positional section reader). `pk2.Fold` is rule 4's folding on raw bytes.
With the cache, `audittextures` over the real Data.pk2 runs in 1.5 s against 24.2 s (MEASURED, the
same 312 report lines; only a missing file's error wording changed).

`server/internal/assetfs` is the layered file system:

- `Open(dir, Options{Mode, CustomDir, NoCustom, Limits, Logf, Strict})` opens a folder per the
  Rules; `custom/` defaults to the `custom` folder beside `dir` (rule 1). `OpenArchive(path)` opens one archive as one layer.
- `FS` is the unscoped view; `FS.In("Media")` the scoped one (rule 3). A `View` has `Stat`, `Open`
  (streams), `ReadFile`, `ReadDir` (merged across layers), `Walk` (each path once, from its serving
  layer), `Which` (the serving layer) and `WhichAll` (every layer holding the path).
- `FS.Overrides()` / `FS.Added(layer)`, `Layer.Rejected`.
- The pack writer: `PackWriter` / `WritePack` (parallel compression, ordered output, a bounded
  in-flight budget, write to `<out>.partial`, read back, rename) and `VerifyPack` (every file by
  name, size and SHA-256 through the same reader). zip64 comes from `archive/zip`: the end record
  when there are more than 65,535 entries, the extra fields when a size or offset passes 4 GiB.
- `Inputs` / `InputFlags`: how the exporters read their tables (`-archives`).

The tools: `pk2list` (`-pk2` takes a `.pk3` too; `-archives <folder>` lists and extracts through
the layers, `-which`, `-layers`, `-overrides`, `-volume`, `-source`), `pk2topk3` (the converter),
`pk3pack` (the pack builder), `export-refdata` and `export-leveldata` (`-archives`). Operator steps
are in deploy/README.md, "Asset packs". **The server reads no archive at runtime**; it takes the
CSVs the exporters write.

### Measured (round 789, the render box, warm page cache, 8 workers)

| archive | pk2 bytes | files | folders | `.pk3` bytes | of the files | write | verify | max RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Data | 3,857,698,816 | 73,139 | 2,733 | 1,957,870,651 | 51.0% | 11.8-15.4 s | 3.4-5.0 s | 283 MB |
| Map | 1,568,534,528 | 19,411 | 100 | 307,314,889 | 23.3% | 3.2 s | 0.7 s | 60 MB |
| Media | 1,547,583,488 | 22,835 | 167 | 373,830,630 | 34.1% | 3.0 s | 0.7 s | 154 MB |
| Music | 62,140,416 | 45 | 0 | 60,075,083 | 100.0% | 0.0 s | 0.0 s | 57 MB |
| Particles | 247,545,856 | 5,832 | 39 | 48,741,769 | 21.3% | 0.5 s | 0.2 s | 37 MB |

Every file of every archive came back byte-identical through the pack reader (SHA-256), and
Python's `zipfile.testzip` (an independent reader) found no bad CRC in any of the five. Data.pk3
carries the zip64 end record (75,872 entries). A 4.7 GB pack (`pk3pack`, 18 stored 250 MiB files)
put entries past the 4 GiB offset; both `assetfs` and Python's `zipfile` read the last one back.
Memory is bounded by the in-flight budget (128 MiB; an entry larger than it takes the whole
budget), the entry being written and the directory index, not by the archive: 283 MB for the
3.9 GB Data.pk2, 516 MB for the 4.7 GB pack of 250 MiB entries.

## Client

Round 789, lane K. The client reads its archives as one set, `AssetArchives`
(`client/scripts/assets/asset_archives.gd`), opened once and shared by every scene and thread;
before it, 13 `Pk2Reader.open` sites in 9 files each opened their own handles. Its readers follow
the Rules above; this section says where each lives and what is the client's own.

**The pieces.**

| Piece | Where | Rule |
|---|---|---|
| The set: packs found and ordered, `custom/` indexed, the volumes opened when first asked for, the override log, `which(path)` | `client/scripts/assets/asset_archives.gd` (`AssetArchives`) | 1, 2, 5, 6 |
| A volume seen through the layers (a `Pk2Reader` to every caller: `find_file`, `read_file`, `read_dir`, `read_dir_at`; a merged folder lists every layer's names) | `client/scripts/assets/layered_archive.gd` (`LayeredArchive`) | 1, 3 |
| Where the base archives are, per volume and mode; the mode | `client/scripts/assets/pk2_config.gd` (`volume_chain`, `source_mode`) | 3, 5 |
| The `.pk3`/`.zip` reader, GDScript | `client/scripts/pk2/pk3_reader.gd` (`Pk3Reader`, a `Pk2Reader`) | 4, 6 |
| The `.pk3`/`.zip` reader, native | `native/src/core/pk3.rs`, binding `SrNativePk3` (`native/src/gd.rs`); interface 6 | 4, 6 |
| A lookup's path (`\` and `/`, empty segments skipped, unsafe served by no layer) | `Pk2Reader.clean_path`; `native/src/core/pk2.rs` `path_segments` (both the pk2 and the pk3 lookups) | 4 |
| Case folding | GDScript `String.to_lower`; `pk2.rs` `lower`, the simple mapping (U+0130 folds to `i`, never Rust's full `to_lowercase`) | 4 |

`ObjectLoader.find_file(archive, path)` is the client's one lookup; it asks the archive
(`Pk2Reader.find_entry`), so a `.pk2`, a `.pk3` and a layered view each answer their own way and
no caller changed. `Pk2Reader.open` opens a `.pk3`/`.zip` (by its name or a zip's magic) as a
`Pk3Reader`, so every tool that opens `Pk2Config.data_path()` reads a converted `Data.pk3` too.

**What callers get.** `AssetArchives.data()` / `map()` / `media()` / `music()` / `particles()`
(rule 3: each is a volume). When nothing overlays a volume -- no pack, no `custom/` file, one base
file -- that is the base archive's own handle, exactly as before round 789 (MEASURED below: no
slower). Otherwise a `LayeredArchive`. A volume with no base archive is null: a pack never stands
in for one (OURS).

**The client's own choices (OURS), beside the Rules.**

- **`custom/`** is round 678's folder **beside `pk2/`** (`FrontEndTheme.custom_dir`:
  `OPENSRO_CUSTOM_DIR`, else `<executable's folder>/custom`): for a player the archives are in
  `pk2/`, and the branding files already live in `custom/` beside it, which is where the Go tools
  look by default too (rule 1). Read in every source mode, branding files included; at most 20,000 files,
  16 folders deep, indexed at open (a file added later is seen after `reopen()`).
- **The mode** is `setting/config.yaml`'s `assets.source` (`ClientConfig`), or
  `OPENSRO_ASSET_SOURCE` for a test; `mixed` by default.
- **The pack folder** is the folder the Data volume resolved to, or `OPENSRO_PACK_DIR`.
- **A `.pk3` entry whose data would lie past the end of the file** is refused at open (the Go
  reader finds it when reading). **A symbolic-link entry** (a Unix-made entry whose mode is
  S_IFLNK) is refused, per rule 1's "nothing inside a pack may be" a link; the Go reader refuses it
  too since round 789's merge (`checkZipEntry`).
- **Reads.** A stored entry is read positionally, no copy. A deflated one: natively,
  `miniz_oxide` into a buffer of exactly the declared size, then `crc32fast`; in GDScript, the
  raw deflate data is wrapped as a gzip member whose trailer is the central directory's CRC-32 and
  size, so Godot's own zlib (`PackedByteArray.decompress(size, COMPRESSION_GZIP)`) inflates it and
  checks both.
- **Threads.** Every handle is shared by the main thread and WorkerThreadPool tasks: the native
  readers take `&self` and read positionally; the GDScript `Pk3Reader` holds its file under the
  per-handle lock only for the seek and the read, never for the inflate.
- **The override log**: one line per pack (its files, zip or zip64, native or GDScript), one per
  pack another shadows, the refused entries, and -- the first time each volume is opened -- the
  paths a pack or `custom/` hides in it (the first 10; `OPENSRO_PACK_LOG=all` for all).

**Which layer served this.** `/layer <path>` in the chat console; `OPENSRO_QA_WHICH="path;path"`
in any run (`QA WHICH <path> -> <layer> (<file>); also in ...`); `client/tools/which_layer.gd`
headless; the Shift+F3 debug panel lists the set. docs/DEBUG_TOOLS.md.

**For the updater (lane U; used since round 789 by "Server packs" below).** `AssetArchives.reopen()` reads the mode and the folders again and
opens a new set: every `AssetArchives.data()`/... after it sees the new packs; handles taken before
keep reading the set they came from; caches keyed by `Pk2Reader.cache_key()` (the item and NPC
tables, the UI fonts) and AudioBank's sounds are dropped with the old set. Call it where no scene
holds handles it must see change (before the login screen, or between scenes), then reopen.
`AssetArchives.current_generation()` tells a cache the set changed. (Not `reload`: that is every
GDScript class's own `Script.reload`.)

**Measured (round 789, the render box).**

- Every file of lane G's five converted archives (121,262 files, 6.2 GB unpacked) read through
  both readers equals the `.pk2`'s (`client/tools/pk3_parity.gd`), and the two readers list every
  folder alike. Opening Data.pk3's central directory (75,872 entries, zip64): 104 ms native, 543
  ms GDScript. Reading all of Data.pk3 (3,662 MB): 8.5 s native, 11.0 s GDScript.
- The Jangan entry (`perf_gate.sh --sites jangan --frames 45000`, 3 runs a side, medians): the
  branch against its base with no pack (GDScript readers both sides, as the gate runs): SAME
  (entry 9,167 against 8,777 ms, within the run-to-run spread; frame 0.87/0.88 ms). The converted
  `.pk3` archives alone against the `.pk2`, native both sides: SAME (entry 4,059 against 3,996 ms;
  freeze 783/748). Two packs over the `.pk2` (9 overlay paths) against an empty pack folder:
  SAME (entry 3,966 against 4,036 ms).
- 20,000 Data lookups and reads (`client/tools/pack_bench.gd`, medians of 5): an empty pack folder
  costs nothing (native 345 against 343 ms; GDScript 9,067 against 9,016); a pack over Data adds
  about 1.5-2 us a lookup natively (find 126-138 against 98-100 ms). From the converted Data.pk3
  the reads cost the inflate the `.pk2` does not (native 2.7 s against 0.27 s, measured with
  lane G's first conversion, which deflated `.ddj`; the converter now stores it, rule 7) while the GDScript lookups need no Blowfish directory (72 ms against 9,089).
- A real render: a pack replacing Media's `minimap\168x97.ddj` (stored, `MINIMAP/168x97.ddj` in the
  zip) changed 61.6 % of the minimap's pixels at the Jangan spawn and 0.000 % of the world
  (`frame_ab.py`, a box over each), and `QA WHICH` named the pack.

## Server packs

Round 789, lane U: **the server names the packs a client needs, with their hashes, and the client
fetches and loads them** (idTech's "pure server"). Everything here is OURS. An operator puts packs
in one folder; every player who connects gets exactly those packs, verified by hash, layered over
their base archives before character select reads item names and tables from them -- without
restarting the client.

### The exchange

Like the front-end theme (0x0005/0x0006) and the server list's status (0x0007/0x0008), it is a
question asked before login on a short connection of the client's own:

- `OpClientPacksRequest` **0x0009** (client -> server, no payload);
- `OpClientPacks` **0x000A** (server -> client): the manifest below. The server answers once per
  connection and closes a connection that has not logged in (`gateway.ErrEndSession`), as the
  theme does.

**When:** the client asks when Connect is pressed, before the connection that carries the login
(Login.gd; QaSignIn for a QA run). Not at boot: the server is chosen on the login screen, and the
answer must be the server the login goes to. Not on the game connection itself: a download can take
minutes and the gateway's pre-login connection should not sit idle that long, and the login screen
can show the download's progress before anything else happens.

**Old and new on both sides:**

| | old server (before 789) | new server |
|---|---|---|
| **old client** | -- | never asks; never sees 0x000A; plays with its own packs |
| **new client** | the request is ignored (no handler claims it); the client waits `PackQuery.TIMEOUT_MS` (2.5 s), goes on with its own packs, and does not ask that address again this run | answered at once: with `-client-packs` the list, without it "no packs named" (flags 0) |

### The manifest (wire layout)

All little-endian. Held to the hand-written vectors `client/scripts/net/testdata/
client_packs_golden.json` by both `server/internal/clientpacks` (`TestManifestGolden`) and
`client/scripts/update/pack_manifest_test.gd`.

```
u8  version (1)
u8  flags        bit 0 REQUIRED: the server names its packs (clear: no packs, the client keeps its own set)
                 bit 1 LOCAL_EXTRAS: the client may keep its own packs and custom/ too
                 other bits: refused
u16 http_port    the server's own pack listener on the gateway's host (0: none)
u8  count        0..32
count x:
  u8   name_len, name   1..64 bytes
  u64  size             1 .. 4 GiB
  [32] sha256           of the whole file
  u16  url_len, url     0..512 bytes ("" = only the server's listener)
```

The packs are in rule 2's cascade order, **lowest first**, and the client layers them in exactly
that order -- the order `pk2list -archives <server folder> -layers` shows, reversed. A decoder
refuses the whole manifest on: another version, an unknown flag bit, a trailing or missing byte,
flags 0 with a pack, a port or extras, more than 32 packs, a bad name (below), two names equal
when case is ignored, a size of 0 or over 4 GiB, more than 16 GiB together, a bad URL, a pack with
no URL when the port is 0. A manifest is one frame (32 packs of the longest name and URL are 20,224
bytes; a frame carries 32,767).

**Names** (`clientpacks.ValidName`, `PackManifest.name_problem`): ASCII letters, digits, `_`, `-`
and `.`, not starting with a dot, ending `.pk3` or `.zip` (any case), at most 64 bytes, no `..`,
and not one of the five base names (`Data.pk3` would be read as a base archive). No separator,
drive, colon, space or control character can occur, so a name never leaves the folder it is
written to. A server pack is never a `.pk2` (convert it with `pk2topk3`).

**URLs** (`ValidURL`, `url_problem`): `http://` or `https://`, printable ASCII without spaces, a
host, no user name or password, no fragment.

### The server (`-client-packs`)

`server/internal/clientpacks` and `cmd/server/clientpacks.go`. Flags (deploy/README.md, "Server
packs"):

- `-client-packs <dir>` (`OPENSRO_CLIENT_PACKS`): the folder of required packs. Only the folder
  itself is read (rule 1); a pack may be a symbolic link to a file elsewhere; folders and dot-files
  are skipped (logged); any other file -- a `.pk2`, a `readme.txt`, a name the rules call unsafe,
  a base archive's name, two names differing only in case -- **stops the server** (OURS: a server
  whose clients cannot get its content should not start, the `-npcpos-csv` rule).
- At startup every pack is opened through `assetfs.OpenArchive` with the readers' limits; **a pack
  with any refused entry is refused whole** (a client would load less than the server names); every
  entry is read back (CRC-32 and declared size checked by the reader); then the file is hashed
  (SHA-256) and its size and modified time are kept. A file that changes while it is checked is
  refused. The list is logged: `client packs: named to every client before login ... order=...`.
- `-client-packs-url <base>` (`OPENSRO_CLIENT_PACKS_URL`): each pack's URL is `<base>/<name>` (a
  CDN, or a GitHub release's `.../releases/download/<tag>`; a base with a query is refused).
- `-client-packs-listen <addr|off>` (`OPENSRO_CLIENT_PACKS_LISTEN`): the server's own listener.
  Default: `:15780` when no URL is set, off when one is (OURS). It is bound before the gateway
  opens (a port in use stops the server) and its port goes in the manifest. With both a URL and a
  listener, the client tries the URL first.
- `-client-packs-local-extras` (`OPENSRO_CLIENT_PACKS_LOCAL_EXTRAS`): sets LOCAL_EXTRAS.

**The listener** (`clientpacks.Handler`; OURS limits, `DefaultServeLimits`): `GET`/`HEAD
/packs/<name>` for exactly the names in the manifest, case-sensitive; any other path, a folder
listing, another method: 404/405. Ranges and `If-Range` (`http.ServeContent`; the ETag is the
SHA-256), so a download resumes. A file whose size or modified time is no longer what was hashed
is answered 503 and logged once ("restart the server to name the new one") -- its hash would no
longer be the one clients were told. Bounds: 16 downloads at once (503 + `Retry-After` beyond), 2
an address at once and 60 requests an address a minute (429), a write deadline moved forward
before every write so a client that stops reading is cut after 60 s, headers read within 10 s,
idle connections closed after 60 s. No bandwidth limit (OPEN). It logs one `client pack served`
line per GET (pack, address, range, bytes, ms).

### The client

`client/scripts/update/`:

| Piece | What |
|---|---|
| `PackManifest` | the wire, the name and URL rules, `url_allowed`, `sources` |
| `PackQuery` | the question (a `GatewayQuery`, as `ThemeQuery`) |
| `PackStore` | the server's folder, the hash cache, `plan`, `sweep`; `FileHasher` (SHA-256 in slices) |
| `PackDownload` | one pack's download (HTTPClient, polled) |
| `PackSync` | the whole of it, a Node: question, plan, hashes, downloads, then `ServerPacks.apply` |
| `ServerPacks` | which server's packs the set layers; the switch (`apply`), `layer_opts` for `AssetArchives` |

**Where the packs go (OURS):** `<pack folder>/servers/<host>_<port>/` -- the pack folder is
`Pk2Config.pack_dir()` (the `pk2/` folder beside the executable, or `OPENSRO_PACK_DIR`), and the
key is the gateway's host lower-cased, every character outside `[a-z0-9.-]` an underscore (an IPv6
address's colons too), and the port. Two servers in the list that ship different packs of the same
name never meet. The readers never look into subfolders, so a server's packs are read only while
that server is the one connected. The folder is the client's own: what the manifest no longer names
(packs, partials of another version) is removed from it; a file whose name the client would never
write (`notes.txt`) is left alone. OPEN: two servers that ship the same pack each download it.

**The plan** (`PackStore.plan`): per pack, **ready** (on disk at its size, and the hash cache --
`packs.json` in the folder: name -> size, modified time, SHA-256 -- says that file, unchanged since,
has the named hash), **hash** (on disk at its size but not verified since it last changed: it is
hashed, 48 MiB a frame, then ready or fetched), **fetch** (missing, another size, or a known other
version). So a second login hashes nothing and downloads nothing (MEASURED below); a pack a player
edits in place changes its modified time and is hashed again. OPEN: a player who edits a pack and
puts its old size and modified time back passes the cache (a full re-hash at every login would
cost seconds a GB; `pk3`s are not a security boundary against the player's own machine anyway --
neither are the base archives).

**A download** (`PackDownload`, polled once a frame; OURS throughout):
- written to `<name>.<first 16 hex of its SHA-256>.partial` in the server's folder, never anywhere
  else; renamed onto `<name>` only after the size and the hash match (the pack appears whole or not
  at all). The hash in the partial's name keeps an old version's partial from being resumed into a
  new one;
- a partial left by an earlier try is hashed first and continued with `Range: bytes=<n>-` and
  `If-Range: "<sha256>"`; a source that answers 200 is read from the start again; a 206 must start
  where the partial ends and name the manifest's total; a 416 starts over;
- **the manifest's size is the cap**: a 200 whose `Content-Length` is not the size is refused, and
  a body that runs past the size is stopped and its partial removed;
- a connection that drops is resumed on the same source up to 3 times, then the next source; a
  source silent for 30 s is dropped; redirects are followed up to 5 (GitHub's release downloads
  redirect to a signed URL, so a redirect's target may be up to 4,096 bytes), each held to the same
  URL rule;
- a wrong hash removes the partial; when any of the bytes came from an earlier attempt, the pack is
  fetched once more from nothing, else the download fails.
- Sources in order: the pack's URL, then the server's listener (`http://<gateway host>:<port>/
  packs/<name>`). **https from any host; plain http only from the gateway's own host** (the host
  the player connected to), the server's listener or an operator URL on it (OURS: the hash, which
  came over the game connection, is what makes the bytes trustworthy either way; this keeps a
  player's downloads off unencrypted third parties). Nothing downloaded is ever executed.
- Before downloading, free space must cover what is left to fetch plus 64 MiB (OURS).

**Purity (OURS, the default):** while connected to a server that names its packs, `AssetArchives`
layers **exactly the server's packs**, in its order, over the base archives; the player's own packs
and the `custom/` path overlay are **set aside**, and the set's log says so (`AssetArchives: set 2
layers the packs of server 127.0.0.1_15897 (2 pack(s)) / set aside while that server is connected:
pack a_mine.pk3`). So a modified local pack cannot change content the server assumes (walls,
navmesh, item tables). With LOCAL_EXTRAS the player's packs stay, below the server's, and
`custom/` stays on top (rule 1). A server that names no packs, an older server and a legacy server
leave the player's own set (switching back if another server's packs were in force). The server's
packs are read in every source mode (they are `.pk3`/`.zip` by the wire's rule; a server that
requires them is not asking the player's preference). Round 678's branding files in `custom/` are
read by `FrontEndTheme` by their own paths, so the overlay being set aside never touches them.

**The switch** (`ServerPacks.apply`): when the selection changes the layers, `AssetArchives.reopen()`
(a new generation: every `AssetArchives.data()`/... after it reads the new set; the caches keyed by
`Pk2Reader.cache_key()` -- item and NPC tables, UI fonts -- and AudioBank's sounds parse again), and
`ServerPacks.drop_caches()` forgets what the process kept in statics that do not key on the set:
the select screen's text table (`NetClient.lobby_text`), the name filter, the quest tables, the
magic option and glow tables, the damage-number art. The login screen then takes the new set's
Media for the windows it still opens and the content id it sends; what it already drew (the title)
stays as drawn. The same selection again changes nothing and reopens nothing. OPEN: the effect and
particle caches keyed by path (`EfpEffect`, `AmbientParticles`; worker threads fill them under
their own locks) are not dropped -- they fill in the world, which a first login reaches after the
switch, so this matters only for a second server with other packs in one run.

**What the player sees:** the message line says `Checking the server's packs...`, then
`Downloading z_akatsuki.pk3: 0.3 MB of 0.6 MB (50%)` (or `Checking <name>: ...` while hashing),
then the login goes out as before. A failure is said plainly on the message line and nothing is
sent: `Could not download the server's pack z_akatsuki.pk3: 127.0.0.1:15780: HTTP 404`, `The
server's pack list cannot be read (...)`, `Not enough free disk space for the server's packs: ...`,
`The server's pack ... has no download address this client accepts (...)`. Every step is a
`PACKS:` line in the log (docs/DEBUG_TOOLS.md).

### Measured (round 789, lane U)

The box, a server built from this branch with `-client-packs` holding `u789_test.pk3` (one text file
of our own, 624 bytes) and lane X's `z_akatsuki.pk3` (590,825 bytes), a client copy with an empty
pack folder: docs/rounds/r789u.md has the commands and the log lines.

- **First login:** both packs fetched from the server's listener and verified (`2 downloaded ...
  (225 ms)`), the set reopened over them, the player's own `zz_local.pk3` set aside; `QA WHICH`
  names `u789_test.pk3` for the test file and `z_akatsuki.pk3` for `itemdata.txt`,
  `textdataname.txt` and the robe's `.ddj`/`.bsr`; the world's item table knows 9,971 models
  against 9,967 without the pack (items 78901-78904).
- **Second login, through the login screen:** `0 downloaded, 0 checked, 2 verified before (91
  ms)`; the server logged no download.
- **Purity:** a local pack and a `custom/` file that both carry the test file were set aside; the
  server's pack served it.
- **A server from before this round:** the question unanswered, `no answer within 2500 ms -- the
  player's own packs`, then the login as before.

## OPEN

- A volume-scoped pack (rule 3).
- Server packs (round 789, lane U; "Server packs" above): a bandwidth limit on the server's
  listener; one copy of a pack two servers both ship; the effect and particle caches after a
  switch between two servers with different packs in one run; a pack a player edits and puts its
  old size and modified time back on passes the hash cache.
