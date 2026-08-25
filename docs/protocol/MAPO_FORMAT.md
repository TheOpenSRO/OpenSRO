# MAPO object-placement format (JMXVMAPO)

`.o` files inside `Map.pk2` (one per map region, alongside a matching `.m` heightmap/terrain file
and, in some regions, `.o2`/`.t` files not yet inspected at all) are the **object placement
list** for that region — this is very likely where a `.bsr` object actually gets positioned in
the game world, since `.bsr` itself carries no such data (see [BSR_FORMAT.md](BSR_FORMAT.md)).

No decompiled loader was found for this format in either `sro_client.exe` or `EternityLib.dll`
(both fully Ghidra-analyzed, RTTI class names checked — same negative result as `.m`, see
[MAPM_FORMAT.md](MAPM_FORMAT.md)), so this is confirmed entirely empirically, the same way
[BSK_FORMAT.md](BSK_FORMAT.md) was: by brute-force scanning a real, populated 105-record sample
(`102/101.o`) for every byte offset where a small, plausible type ID is immediately followed by 3
non-garbage floats. That scan recovered 95 real object placements — clustered into just 4 type
IDs, with world-position magnitudes matching the scale of real `.bms`/`.bsk` data — and, critically,
revealed the *actual* record boundaries, which don't line up with the fixed-stride guess an
earlier version of this doc made.

## Structure

| Field | Encoding |
|---|---|
| Magic | `"JMXVMAPO"` (8 bytes) |
| Version | 4 bytes, ASCII — real files seen with both `"1000"` and `"1001"`. **Not a reliable populated/empty signal** — see below. |
| Header (2 unconfirmed `uint32`s, usually) | at offset 0x0c — see "The header isn't a fixed size" below |
| Object records | see below, until the resync scan can no longer find a plausible next record |

The version tag doesn't reliably distinguish empty from populated regions the way an earlier pass
at this format assumed: every real `"1000"` region checked so far genuinely has zero objects, but
`"1001"` regions were found both populated (`102/101.o`, `100/100.o`, ...) **and** genuinely empty
(`100/103.o`, `100/104.o` — all-zero after the header, same shape as a `"1000"` file). A reader
has to check the actual content, which both readers here already do (an empty result is a normal,
successful parse either way, not an error).

## The header isn't a fixed size

Objects were originally found to start at a fixed file offset `0x14` (magic 8 + version 4 + 2
`uint32`s = 20 bytes), confirmed against the one sample this format was originally cracked
against. Cross-checking against more real samples (pulled from `Map.pk2` directly via this
project's own `server/internal/pk2` reader) found real files where the first object instead
starts at `0x12` — **2 bytes narrower**. What causes the difference isn't confirmed (maybe one of
the 2 header `uint32`s is sometimes narrower, maybe something else) — rather than guess, both
readers now find the header/record boundary the same way every other ambiguous boundary in this
project's formats was resolved: scan forward (bounded) from right after the version tag for the
first byte offset that looks like a plausible object record, instead of trusting either fixed
length.

## Object record

- `uint32` **type ID** — a catalog/resource index into some other table this project hasn't
  identified (small values confirmed real: `1159`, `1798`, `1800`, `1805` — only 4 distinct IDs
  across 95 real placements in the one sample checked, i.e. 4 kinds of object populate this
  region).
- 3× `float32` **position** (x, y, z) — world-scale magnitudes (hundreds to low thousands),
  consistent with the position scale seen in real `.bms`/`.bsk` files.
- **12 more raw bytes**, present on every record. That's 28 bytes fixed per record; an earlier
  version of this doc guessed this 28-byte figure too, but as the *whole* record size, which
  drifted out of alignment after a couple of records on the real sample. Of these 12 bytes:
  - Bytes `[0:2]` — an unconfirmed 2-byte flag, observed only as `0x0000` or `0xffff`.
  - Bytes `[2:6]` — **SOLVED (2026-08-24): the object's real Y-axis (yaw) rotation**, a `float32`
    in radians. Confirmed two independent ways: (1) decompiled the real object-construction
    function reached through this placement class's own real vtable (a real client build's
    `FUN_009f2c20`) and found it loads a single float from one stack slot *twice in a row*,
    immediately before two back-to-back real FPU calls (cosine-then-sine, same input both times)
    whose results are packed into a real `(cos, 0, sin)`-shaped direction vector alongside a
    separate `(0, 1, 0)` triple — the standard yaw-angle-to-forward-vector construction. (2)
    Checked empirically against a real, densely-populated Jangan-area region (`98/168.o`, 273 real
    objects): every single value at this byte offset, read as `float32`, falls in the real
    `[0, 2*pi]` range — 100%, not just "mostly", which a coincidental misread of unrelated bytes
    wouldn't produce. Several real values also round to whole real degrees (e.g. `6.1261 rad` =
    `351.0 deg`) when converted, consistent with a level-editor angle-snap tool. Implemented as
    `Object.Rotation` (Go) / `ObjectPlacement.rotation` (GDScript) and wired into `World3D.gd`'s
    real object placement (`node.rotation.y`) — live-rendered against real Jangan data and
    confirmed visually: a real city-wall run that previously showed a small floating/disjointed
    panel now reads as one continuous, correctly-aligned wall.
  - Bytes `[6:12]` — still unconfirmed. Byte 6 looks like a small per-object counter (values like
    `1, 2, 3...` within a same-type-ID group in the real sample checked); byte 7 climbs in a
    stepped pattern whose values divided by 4 land in `0-35` — the same range as this format's
    real 6x6=36 sub-block grid, suggesting a block/sub-region locator rather than more transform
    data. Not yet cross-checked against a decompiled consumer the way rotation was.
- **0 or more further trailing bytes** before the next record starts — real records were seen
  with 0 to 40 of these, always an even count, and every non-empty one checked was zero padding
  followed by a small nonzero 2-byte tail value (`1`, `3`, `5`, ... observed) — plausibly some
  kind of sub-index or link count, but not confirmed, and not exposed as a parsed field.

**There's no length field anywhere for that trailing block**, so a reader can't just add up fixed
offsets — it has to find each record's real end the same way this format was cracked: after the
fixed 28 bytes, scan forward for the next byte offset that itself looks like a plausible record
(small type ID, sane position floats), and treat everything skipped as that record's opaque
trailer. This is exactly the same kind of "verify plausibility, don't trust a fixed layout"
approach `.bsk` needed for its Type A/Type B disambiguation — just applied to record *length*
here instead of record *shape*.

"Plausible record start" — the same check the format was originally discovered with — is: a
`uint32` type ID in `(0, 10000)`, and 3 `float32`s that are each either exactly `0.0` or have
magnitude strictly between `0.001` and `20000` (rejecting NaN/Inf and the near-zero
subnormal-float garbage that misaligned binary data produces, which was a real source of false
positives during development — see `docs/PROGRESS.md`).

## Verification

Both readers (`server/internal/mapo`, `client/scripts/mapo/mapo_reader.gd`) were run against 11
real samples (the original `102/101.o`, plus 10 more pulled directly from `Map.pk2`) and produce
identical results on both sides:

- `102/101.o` (populated, version `"1001"`, 2960 bytes): 95 objects, all 4 type IDs, positions
  matching real map-region scale. No leftover garbage records — every "plausible record" scan hit
  clustered exactly to just 4 IDs, with no stray singleton type IDs (an earlier iteration of the
  resync logic that used the wrong fixed-record size produced several bogus singleton-count type
  IDs from mis-scanning into the trailing-bytes region; fixed by using the full 28-byte fixed
  record, not just the 16-byte type+position prefix, as the resync starting point).
- `100/100.o`, `100/101.o`, `100/102.o` (populated, `"1001"`, all using the narrower 18-byte
  header): 58, 50, and 12 objects respectively, up to 11 distinct type IDs across them — a real
  bug caught here during this cross-check (the reader originally returned 0 objects for all three,
  silently, since a fixed 20-byte header offset landed inside real record data and failed the
  plausibility check) and fixed by the header-scanning approach above.
- `0/0.o`, `0/1.o`, `0/2.o`, `1/0.o`, `1/1.o` (version `"1000"`) and `100/103.o`, `100/104.o`
  (version `"1001"` but genuinely empty): 0 objects, correctly, on all 7.

## SOLVED: the real type-ID-to-resource-path mapping (`.ifo` object-index tables)

**Previously a confirmed dead end** — no such mapping was found anywhere in this project's
available data. It turned up once `server/internal/pk2`'s directory-chain bug was fixed (see
`docs/protocol/PK2_FORMAT.md`), since the file that carries it lives in a real `Data.pk2` folder
that bug was silently dropping from every listing.

**The real file**: `object.ifo`, magic `JMXVOBJI1000`. **Corrected (2026-08-22)**: this project
originally believed it lived at `Data.pk2` root; a real live playtest against a real, unmodified
retail client (via `cmd/pk2list`) found it under a real `navmesh\` folder instead
(`navmesh\object.ifo`) — the "root level" claim below was wrong (possibly true for whatever sample
this was first found against, but not a safe general assumption; `client/scripts/World3D.gd`'s
`OBJECT_INDEX_PATH` now points at the real `navmesh\` path). Unlike every
other `JMXV*`-prefixed format in this project, it's not a binary container — after the magic line,
it's a plain ASCII text table, one real object type per line, shaped exactly
`"%05d 0x%08x \"<path>\""`: a real, sequential type ID (confirmed to always equal its own line
position, in every real file checked), an unconfirmed flags word (observed values so far: `0` and
`1`), and a real, resolvable `.bsr` resource path (`res\...`, a different top-level real folder
than `Prim\...`, also confirmed to exist and resolve correctly once the pk2 chain bug was fixed).

**Confirmed against real data, not just the file's own internal consistency**: pulled a real
`100/100.o` region file, found its real type IDs (`1489`, `1748`, `669`, `1488`), looked them up in
a real `object.ifo`, and got back genuinely sensible real scenery — trees and grass
(`res\nature\europe\east eurpoe\tree\...`, `res\nature\oasis\hotang\oas_grs_weed04.bsr`) — exactly
what a real outdoor region scattering 39/11/7/1 objects of those types would plausibly place.

**Implemented**: `server/internal/objidx` (Go) and `client/scripts/objidx/objidx_reader.gd`
(GDScript) parse this table and expose `Lookup(type_id)`. `World3D.gd` uses it
(`SRREVAMP_MAPO_PATH`) to render real placed objects with their real resolved `.bsr` models
instead of a placeholder marker — see `README.md` and `docs/PROGRESS.md`.

**A real client-version mismatch, confirmed 2026-08-24, not a bug**: some real Jangan-area regions
report placements with type IDs this project's real `object.ifo` table has no entry for (up to 50
in one real region checked). Traced directly: every one of these real unresolved IDs falls in a
narrow real range (`3268`-`3296`) immediately past this table's own real size (`3268` real
entries, valid IDs `0`-`3267`) — not scattered/random values. This is a real, genuine mismatch
between this specific client install's `object.ifo` (a slightly older/smaller real build than
whatever real client version authored the Jangan region's placement data) rather than a parsing
bug in this project's own code — the same real "asset/version mismatch, not our bug" conclusion
already reached for a couple of genuinely-missing `.bsr` files elsewhere this session. Not fixable
without a newer real `object.ifo` sample; `World3D.gd` already skips these gracefully
(`skipped_unresolved`) rather than erroring.

**Traced (2026-08-22) one real consumer of this table**, chasing the unconfirmed `Flags` word:
`FUN_00a26a30` reads a placement's type ID, indexes this exact 32-byte-stride vector the same
bounds-checked way `objidx.Parse`/`Lookup` already do, and feeds the matched entry into
`FUN_00a15950`, a real resource-cache/refcount lookup that's part of the actual mesh-load path —
confirming the table really drives per-placement model loading, not just naming. Did not isolate a
specific bit-check reading `Flags` itself in this pass, so its 0-vs-1 meaning stays unconfirmed —
a real, honest dead end for now, not blocking anything since nothing in this project's rendering
currently depends on it.

**A real, separate gap this surfaced — now also solved**: real `.bsr` files in the
`res\nature\...` category (trees, grass) initially didn't parse correctly with this project's
`server/internal/bsr` (garbage `MeshPath`/`MaterialPath` fields), while `res\bldg\...` (building)
files parsed fine. Root-caused: nature-category files genuinely order these fields differently
(material path and bounding box before the mesh path, not after) — see
`docs/protocol/BSR_FORMAT.md` for the full derivation and fix. Both categories now resolve and
render correctly through `World3D.gd`'s real object loading.

## Two real sibling tables sharing the same `JMXVOBJI` magic (2026-08-23)

Found while checking a real client's `navmesh\` folder for other `.ifo` files: two more real
tables share `object.ifo`'s exact `JMXVOBJI1000` magic and general line-based text-table shape,
confirmed present in a real `Data.pk2` at both pk2 root and `navmesh\`:

- **`objectstring.ifo`** (real, 451 entries in the one sample checked) — a real
  gate/structure-placement table, not object display names despite the "strings" name. Each line:
  `0x%08x 0x%08x <count1> <count2> 0x%08x 0x%08x 0x%08x 0x%08x "<Name>"` — a real ID (always
  `0xffff` in the high 16 bits + a small varying low 16 bits, e.g. `0xffff0001`), an unconfirmed
  flags word, two small unconfirmed integers, 4 real `float32`s (plausibly position + a yaw-shaped
  rotation — one real sample's 4th float was consistently `0xbfc90fdb` ≈ `-1.5708` ≈ `-π/2` across
  several related entries), and a real, human-readable name. Real names seen: `GATE_DUNGEON_DH_OUT`,
  `GATE_JINSI_02X01_03`, `STRUCTURE_POS_JA_DEFENSIVE_02` — real dungeon/zone gate identifiers and
  real siege/fortress defensive structure position labels. This is almost certainly what
  [`MAPM_FORMAT.md`'s sibling `.nvm` format doc](https://github.com/JellyBitz/srodevs-docs) means
  by its real per-object `IsStruct` flag ("Use objectstring.ifo") — a real, separate lookup for
  named/special map objects (gates, siege points), distinct from `object.ifo`'s plain numeric
  type→model mapping. Not implemented (this project has no `.nvm` reader yet to actually consume
  it), recorded for whoever adds one.
- **`objext.ifo`** ("Map Object Extension") — real but tiny in the one sample checked: a single
  entry, `0x19500009 "" "passent01"` (an ID, an empty quoted field, and a name). Structurally
  similar to the other two but with too little real data in this one sample to say more.

## What's still not confirmed

- What causes the header-length difference (18 vs 20 bytes).
- The 12 fixed unconfirmed bytes per record, and the trailing variable block's exact meaning
  (kept raw on `Object.Fixed12` / `Object.Extra`).
- ~~Rotation: no field in this record obviously looks like a rotation~~ **SOLVED, see the "Object
  record" section above** — it's `Fixed12` bytes `[2:6]`, a `float32` yaw angle in radians. Getting
  there took a real wrong turn worth recording honestly: an initial attempt at this same empirical
  check interpreted `Fixed12` as *three* consecutive `float32`s (bytes `[0:4]`, `[4:8]`, `[8:12]`)
  and concluded the values were "wildly out-of-range for any real angle" — that was this project's
  own byte-slicing mistake (the 2-byte flag at `[0:2]` throws off a naive 3-float split, silently
  reading two unrelated bytes from the flag and from byte 6's counter into what looked like the
  first "float"), not a real property of the data. Isolating `[2:6]` alone and cross-checking it
  against a decompiled real consumer (see above) resolved it correctly. Byte 6 looks like a small
  per-object counter (values
  like `1, 2, 3...` within a same-type group); byte 7 climbs in a stepped pattern whose values
  divided by 4 land in `0-35` — the same range as this format's real 6x6=36 sub-block grid,
  suggesting byte 7 is more likely a block/sub-region locator than orientation data. An earlier
  pass this same day also tried tracing `object.ifo`'s known consumer (`FUN_00a26a30`) backward
  for a caller and hit a vtable-indirection wall (its only real cross-reference was a data pointer
  inside a vtable slot, not a call site) — that specific function wasn't the right thread to pull.
  The real one was found by walking the vtable itself (`DumpVtableAt`-style) to its neighboring
  slots, decompiling the whole-class destructor to identify the class as the real Map/MapEngine
  object (its `Assert` strings resolve to a real `D:\vss-od\Silkroad\Client\Landscape\MapEngine\
  Map.cpp`, with real members `m_Object`/`m_RegionCache`/`m_BlockCache`/`m_Dungeon`), then
  decompiling *other* slots in that same vtable until the real object-construction method
  (`FUN_009f2c20`) turned up the cos/sin construction described above.
- Whether the 2 unconfirmed header `uint32`s (offset 0x0c) are meaningful (e.g. an object count)
  — a real object count wasn't cross-checked against the parsed count yet.
- ~~Real-world placement scale/position relative to a player's true spawn coordinate~~ **SOLVED
  (2026-08-24), from a real public source, not decompilation**: an internal decompile search for
  this (see the negative result below, kept for context) turned up nothing new, but a region's
  folder-name convention this project already uses (`"98\168.m"`) turns out to be a real, public,
  already-documented scheme — confirmed via JellyBitz's `xSROMap`
  (https://github.com/JellyBitz/xSROMap), an open-source real Silkroad Online map-coordinate tool.
  Its own real coordinate-conversion JavaScript (`assets/js/xSROMap.js`) shows a region ID packs as
  `(ySector << 8) | xSector`, and a region's own local coordinates span exactly `[0, 1920)` real
  game units — i.e. `"98\168"` really is `xSector=98, ySector=168`, and `REGION_SPAN`'s real
  `1920.0` value (already used, and already confirmed correct for real terrain tiling via this
  project's own region-streaming grid) is exactly this real per-region span. This means a `.o`
  object's raw position is already real, correctly-scaled, absolute-within-its-region data needing
  no artificial recentering: it only needs the same rotation+offset transform
  `_try_load_real_terrain` already applies to that region's terrain tile. Fixed in `World3D.gd`'s
  `_try_load_real_map_objects` by parenting the real-object container under that exact terrain
  node (found by its shared, existing node-name convention) instead of computing a separate
  "recenter near the player" placement — inheriting the identical transform automatically rather
  than duplicating it. **Live-rendered and visually confirmed**: real Jangan buildings that
  previously appeared as an arbitrary clustered jumble around the player now compose into a
  coherent, walkable real gate/courtyard structure (ornate painted walls, a matching double-door
  frame, consistent floor tiling) when viewed from a fixed camera, exactly as a real placed
  structure should look.
  - **The internal decompile search that came up empty (kept for context, so a future pass doesn't
    re-run it)**: a real `1920.0f` float constant does exist in `sro_client.exe` (a plausible real
    region-size guess even before this session, never confirmed that way), but decompiling its two
    referencing functions (`FUN_004e72a0`, `FUN_004e5e00`) shows it's used inside what reads as
    real keyframe/spline interpolation code, not a coordinate transform. No RTTI/exported symbol
    naming "region"/"sector"/"world" turned up a transform function either. This is a case where
    a real public, already-published community source settled something static analysis of the
    client alone hadn't.

## Real samples available for future verification

`Map.pk2` → `<region>/<region>.o`, e.g. `102/101.o` (2960 bytes) and the `100/*.o` region files
(the largest populated samples found in this environment) — only 19 region folders exist here,
`0`, `1`, `100`-`116`, a small subset of a full world map. Extracted directly from a real
`Map.pk2` (1.5GB) via this project's own `server/internal/pk2` reader, not any external tool.
