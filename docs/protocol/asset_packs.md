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
   files, which live there too).
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
| `.ddj` | 24.8% Particles, 40.0% Media, 59.4% Data, 80.3% Map | deflated |
| `.bms` 41.7%, `.ban` 64.5%, `.nvm` 26.6%, `.t` 6.3%, `.m` 33.7%, `.efp` 17.9%, `.txt` 28.1% | | deflated |

So the policy (`assetfs.StoredExtensions`) stores `.ogg`, `.rar`, `.png` (MEASURED) and the formats
that are compressed by construction (`.jpg`, `.jpeg`, `.mp3`, `.zip`, `.pk3`, `.7z`, `.gz`,
`.webp`; INFERRED from the formats, none is in retail) and deflates everything else; an entry
that deflate does not make smaller is stored anyway. **`.ddj` is deflated**, against the TODO's
first assumption that it is "already compressed": its DXT blocks still deflate to 25-80%. An
operator who wants textures readable without inflating passes `-store .ddj` (Data.pk3 then grows
by about 0.63 GB).

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
  Rules; `custom/` defaults to `<dir>/custom`. `OpenArchive(path)` opens one archive as one layer.
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

(Lane K, round 789: the GDScript and Rust readers, the `custom/` folder's place beside `pk2/`, the
source-mode setting and the "which layer served this" QA hook. To be written there; the Rules
above are the contract.)

## OPEN

- A volume-scoped pack (rule 3).
- The server naming the packs a client needs, with their hashes, and the auto-updater fetching
  them (docs/TODO.md).
- Loading time against `.pk2` (the perf gate; the client lane).
