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
- **12 more raw bytes**, present on every record — unconfirmed meaning, kept raw rather than
  mislabeled (same policy as `.bsk`'s transform bytes). That's 28 bytes fixed per record; an
  earlier version of this doc guessed this 28-byte figure too, but as the *whole* record size,
  which drifted out of alignment after a couple of records on the real sample.
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

**The real file**: `object.ifo` (root level in `Data.pk2`), magic `JMXVOBJI1000`. Unlike every
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

## What's still not confirmed

- What causes the header-length difference (18 vs 20 bytes).
- The 12 fixed unconfirmed bytes per record, and the trailing variable block's exact meaning
  (kept raw on `Object.Fixed12` / `Object.Extra`).
- Rotation: no field in this record obviously looks like a rotation (quaternion or Euler angles)
  — either it's encoded in a way not yet recognized (e.g. inside the unconfirmed 12 fixed bytes
  or the variable trailer), or rotation isn't stored per-placement at all for these object types.
- Whether the 2 unconfirmed header `uint32`s (offset 0x0c) are meaningful (e.g. an object count)
  — a real object count wasn't cross-checked against the parsed count yet.
- Real-world placement scale/position relative to a player's true spawn coordinate (i.e. how a
  region index like `100/100` combines with a `.o`/`.m` file's own local coordinates into one
  real world-space position) — attempted and not found. A real `1920.0f` float constant does
  exist in `sro_client.exe` (a plausible real region-size guess, never confirmed), but decompiling
  its two referencing functions (`FUN_004e72a0`, `FUN_004e5e00`) shows it's used inside what reads
  as real keyframe/spline interpolation code, not a coordinate transform — a real negative result,
  not a coincidence to keep chasing without new evidence. No RTTI/exported symbol naming
  "region"/"sector"/"world" turned up a transform function either (same negative result the
  original `.m`/`.o` cracking effort got). Recorded here so a future pass doesn't re-run the same
  search.

## Real samples available for future verification

`Map.pk2` → `<region>/<region>.o`, e.g. `102/101.o` (2960 bytes) and the `100/*.o` region files
(the largest populated samples found in this environment) — only 19 region folders exist here,
`0`, `1`, `100`-`116`, a small subset of a full world map. Extracted directly from a real
`Map.pk2` (1.5GB) via this project's own `server/internal/pk2` reader, not any external tool.
