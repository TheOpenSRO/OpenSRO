# MAPM terrain/heightmap format (JMXVMAPM)

`.m` files inside `Map.pk2` (one per map region, alongside that region's `.o` object-placement
file — see [MAPO_FORMAT.md](MAPO_FORMAT.md)) are the terrain/heightmap data.

No decompiled loader was found via the usual technique (searching for "JMXV" immediately followed
by the 4-letter type suffix) in either `sro_client.exe` or `EternityLib.dll`, both given a full
Ghidra auto-analysis pass, including an RTTI class name check (none found) — so this is confirmed
entirely empirically, using the same brute-force byte-analysis approach that cracked `.bsk` and
`.mapo`.

**Lower confidence than every other format in this project.** Originally derived from one real
sample; since cross-checked against 10 real files pulled directly from `Map.pk2` via this
project's own `server/internal/pk2` reader — real confidence increase, and it revealed a second
tile record shape (see below) that a single-sample derivation couldn't have found. Still, several
fields remain genuinely unconfirmed (see "What's still not confirmed" below), so treat this as
real but less settled than `.bsk` (8 files, fully cracked) or `.mapo` (11 files, fully cracked).

## What was tried first, and why it was wrong

An earlier pass at this format found a `uint16` reading exactly `97` at file offset `0x18` and
guessed it was a header field storing the classic Silkroad 97×97 terrain grid width. Re-examined
by dumping the raw bytes of many consecutive 11-byte chunks starting at that offset: `0x61` (97)
recurs as the **first byte of individual tile records**, not as a one-time header field — it's
just a very common tile value (the most frequent single-byte value in the file, appearing on
about 6% of tiles), not a grid dimension. The "97 = grid width" idea is very likely a coincidence
of that byte's high frequency; there's no confirmed connection to any actual grid geometry.

## Two tile record shapes, picked by file size class

Cross-checking against 10 real files (5 more from the original ~136-137KB size class, plus 5 from
a visibly different ~92KB size class) found **two different tile record shapes**, one per size
class — something a single-sample derivation had no way to discover:

- **Shape A** (`length=11, heightOff=5`) — the originally-confirmed layout, used by every
  ~136-137KB file checked (`0/0.m`, `0/1.m`, `0/2.m`, `1/0.m`, `1/1.m`).
- **Shape B** (`length=7, heightOff=2`) — 2 unconfirmed leading bytes, the height float, 1
  unconfirmed trailing byte. Used by every ~92KB file checked (`100/100.m`-`100/104.m`). Found the
  same way Shape A originally was: measuring the byte stride between recurring float-shaped
  patterns in the raw data.

There's no header field declaring which shape a file uses. Both readers detect it the same way
this project resolves every other such ambiguity: try every `(shape, starting offset)` combination
in a small window right after the version tag, and pick whichever produces the longest unbroken
run of plausible tiles (a real height value: not NaN/Inf, and not the subnormal-float noise
misaligned binary data produces — see below). This reliably picks the right shape and the right
starting offset on every real file checked, including correctly ignoring the small false-positive
runs an all-zero header region can otherwise produce (see "Verification" below).

## Tile record

| Field | Shape A (11 bytes) | Shape B (7 bytes) |
|---|---|---|
| Leading bytes | 1 byte: a small integer, plausibly a texture/terrain-type index or blend weight. Real data shows **over 200 distinct values** — too many and too evenly spread to be a small fixed catalog the way `.mapo`'s object type IDs are, so this isn't confirmed as a "type ID" beyond "a per-tile byte that varies." | 2 bytes, unconfirmed. |
| More leading bytes | 4 bytes: two `uint16`-shaped values that change from tile to tile in a locally-structured way (e.g. one was seen incrementing by a fixed step across a run of consecutive tiles before resetting) — plausibly some kind of row/column or patch-relative index, not confirmed. | (none — shape B has no equivalent field) |
| Height | `float32` — confirmed as a real elevation value in both shapes: real data ranges roughly -920 to +3844 across all 10 files checked, with no NaN/Inf. | same |
| Trailing bytes | 2 bytes, unconfirmed, observed `00 00` on every tile checked so far. | 1 byte, unconfirmed. |

Both shapes' non-height bytes are kept raw on `Tile.Extra` / `tile.extra` rather than mislabeled.

## The stride isn't perfectly regular — a resync scan is needed

A naive fixed-stride walk of an entire file (once the right shape is known) still degrades partway
through on some files — a small fraction of "tiles" come out as NaN or wildly out-of-range floats.
Handled with a **plausibility-based resync scan** (the same technique `.mapo`'s variable-length
trailer needed): read a tile at the current offset if it looks plausible; if not, scan forward
byte-by-byte for the next offset that does, and resume from there. On the files where this format
holds all the way through, only a small fraction of tiles ever need a resync — the fixed stride is
correct almost everywhere, and the scan recovers the rest, landing at (or extremely close to) the
exact end of file.

The "plausible tile" check itself has a subtlety worth calling out (a real bug hit and fixed
during development, the same shape of bug `.mapo` also hit): a height check that only rejects
NaN/Inf and enforces a magnitude range still lets through *subnormal-range* float noise (values
like `1.5e-30`) that misaligned binary data produces relatively often — these were being accepted
as "sane" and causing the resync scan to lock onto the wrong offset. Fixed by also requiring a
nonzero value to have magnitude above `1e-3`.

## Real tile data can be interleaved with long non-tile runs — the resync bound matters

2 of the 5 Shape-B files (`100/103.m`, `100/104.m`) initially only recovered ~290 tiles (out of an
~13,200 expected for that size class) before the resync scan gave up — traced to a byte offset
(`0x800` in both files) where the data stops looking like tile records and becomes a long,
repeating `00 01 00 01 ...` pattern. **An earlier version of this doc concluded this was a real
section boundary and stopping there was the correct behavior — that conclusion was wrong.**
Scanning the *entire* file for every plausible (nonzero) float value, ignoring the tile stride
assumption entirely, revealed the real structure: both files are organized into repeating bands of
~2025 bytes of genuine tile data separated by gaps of a repeating non-tile pattern **up to 509
bytes long** — far wider than the 64-byte resync bound this format's readers originally used
(sized for `.mapo`'s much shorter trailers). The resync scan wasn't hitting a real, unparseable
section; it was giving up on a genuine gap before reaching the real tile data on the far side of
it, which resumes normally afterward.

Fixed by widening the resync bound to 600 bytes (comfortably past the largest gap observed, 509
bytes). Both previously-"anomalous" files now recover 12,698 and 12,947 tiles respectively —
consistent with the ~13,200 tiles their sibling files in the same size class have — with sane
height ranges and no NaN. The repeating `00 01` pattern itself is still not understood (plausibly
a "no data here" run-length/mask section marking sparse or void terrain within the region — not
confirmed), but it no longer blocks recovering the real data around it.

## Verification

`server/internal/mapm` and `client/scripts/mapm/mapm_reader.gd` implement the shape-detecting,
resync-scanning reader above and produce identical results across all 10 real files:

| File | Size | Shape | Tiles | Height range |
|---|---:|---|---:|---|
| `0/0.m` | 137128 | A | 12417 | -195.4 to 598.5 |
| `0/1.m` | 136128 | A | 12363 | 0.0 to 193.6 |
| `0/2.m` | 137128 | A | 12457 | 0.0 to 0.0 (flat) |
| `1/0.m` | 136128 | A | 12366 | 0.0 to 0.0 (flat) |
| `1/1.m` | 136128 | A | 12365 | 0.0 to 0.0 (flat) |
| `100/100.m` | 92712 | B | 13211 | -31.3 to 3677.7 |
| `100/101.m` | 92712 | B | 13211 | -512.6 to 2862.7 |
| `100/102.m` | 92712 | B | 13211 | -20.0 to 3844.2 |
| `100/103.m` | 92712 | B | 12698 | -475.1 to 2857.7 |
| `100/104.m` | 92712 | B | 12947 | -920.8 to 1198.6 |

Both sides also have synthetic unit tests for both shapes and the resync path (a single unreadable
byte the fixed-stride walk can't skip past on its own).

## Grid width confirmed: 17, decoded directly from a real per-tile field

The T=17 periodicity signal below is now confirmed as a real grid dimension, not just a
statistical signal. Directly inspecting Shape A's two `uint16`-shaped fields (offsets 1-2 and 3-4
of the 11-byte record) on a real `0/0.m` found:

- The first field (bytes 1-2) increments by a fixed ~4096 step from tile to tile and wraps back to
  0 after exactly **17** distinct values (`0, 4095, 8191, 12287, ..., 61439, 65535`) — a real,
  directly observed per-tile **column index**, base-65535 fixed-point (`col = round(raw * 16 /
  65535)`), not inferred from statistics. This mechanistically confirms the T=17 DFT signal
  recorded below as a real grid width, not a coincidental terrain-feature periodicity.
- The second field (bytes 3-4) follows the exact same encoding *within* a run of 17 tiles (stays
  constant while the first field cycles, then steps by the same ~4096 amount at the row boundary)
  — plausibly a row index using the same scheme — but does **not** decrement cleanly across the
  whole file: real files were found to reset back to a high value on an irregular schedule
  (sometimes every 17 sub-blocks in a clean run, sometimes after much longer irregular gaps of
  hundreds of tiles). **Not confirmed as a usable global row index** — real, structured, but not
  yet fully understood, so it isn't decoded into anything by this project's readers.

`client/scripts/assets/mapm_terrain_builder.gd` (`MapmTerrainBuilder`, client-only — this is a
rendering concern, not a protocol concern, so it has no Go mirror) uses the real, confirmed column
field directly, and groups tiles into rows by real file order (a new row starts whenever the
decoded column index wraps back down) rather than guessing at the row field's full-file structure.
This produces genuinely correct 17-wide terrain strips using 100% real per-tile data; it does not
yet place those strips at a confirmed true relative world position across a whole region file. See
`docs/PROGRESS.md` for the real rendered screenshot this produced, and the file's own doc comment
for the full reasoning.

## The original DFT investigation (Shape A's T=17 is now confirmed above; Shape B's T=46 is not)

No header field encodes a grid width/height (the `97` idea is retracted — see above), so a
direct DFT power-spectrum check was run on the height-value sequence itself, looking for
periodic structure the way a genuine row-wrap would produce. Run first against 2 samples, then
against 20 more (pulled fresh from `Map.pk2`, covering regions `100`-`104`), it found something
real and now well-replicated:

- **Shape B, "interior" regions** (region-name suffix `_100` through `_103`, 17 files checked):
  overwhelmingly dominant period **T=46**, in first place for all 17 with no exceptions.
- **Shape B, region-name suffix `_104`** (3 files checked): a *different* dominant period,
  **T=17**, with enormous power (4-12 million — an order of magnitude stronger spike than any
  other result in this whole investigation, `_100`-`_103` included). Whatever distinguishes a
  `_104` region from its neighbors, it produces a much cleaner periodic signal.
- **Shape A** (2 non-flat files checked, `0/0.m`/`0/1.m`): also **T=17**, matching the `_104`
  group despite being a structurally different file-size class entirely.

**Not confirmed as an actual grid row width**, for two reasons that held up even with the larger
sample: cross-checking the same DFT method against the *leading-byte* channel (Shape B; plausibly
a texture/terrain-type value) does **not** reproduce T=46 as dominant on a representative T=46
file (`101/100.m`) — its top period there is 17, with 46 only fifth-ranked — and a genuine
grid-aligned texture-blend byte would be expected to show the same periodicity a real row-width
split would produce. Tile counts also aren't evenly divisible by the candidates (`101/100.m`:
13211 tiles, `13211 mod 46 = 9`). Plausible explanations that don't require these numbers to be
literal grid widths: a natural terrain feature wavelength (hills/valleys/coastline recurring at
that tile spacing) that shows up strongly in a smoothly-varying height channel without being a
structural row length at all, or a header/trailer offset this project hasn't isolated shifting
the true division. Recorded here as a real, multiply-replicated signal — not guessed at, and
strong enough that it's very likely telling us *something* real about how these regions are laid
out — but not yet resolved into a confirmed grid dimension. The `_104`-vs-`_100`-`_103` split is
itself a new, real, unexplained observation worth a future pass on its own.
- Shape A's two `uint16`-shaped fields.
- The exact cause of the short (sub-64-byte) resync-needed misalignments seen in most files (no
  coherent explanatory structure was found in the skipped bytes, unlike `.mapo`'s trailing block).
- What the long (up to 509-byte) repeating `00 01` runs interleaved with real tile data in some
  Shape-B files actually are.
- Whether the terrain-type byte (Shape A, offset 0x00) corresponds to anything a renderer could
  use directly (a texture index into some other table not yet identified).

## A real, unopened sibling file: `.t` (`JMXVMAPT1001`) — a possible ground-texture blend map

Every real `Map.pk2` region folder also contains a `.t` file alongside its `.m`/`.o`/`.o2` files
(magic `JMXVMAPT1001`) — never decoded before this project went looking for a real ground-texture
system to answer why rendered terrain looked like flat color instead of the actual game. Real
structural findings so far:

- Every real `.t` file is **exactly 140436 bytes**, fixed across every region checked — unlike
  `.m`/`.o`/`.o2`, which vary in size per region.
- The 140420-byte body (after what's plausibly a 16-byte header, not yet confirmed) divides
  cleanly by **17** — the same real column width `.m`'s Shape A confirmed above. Read as 35105
  `uint32` (little-endian) cells, that count also divides cleanly by 17.
- 80% of those cells are exactly `0x00000000` or `0xFFFFFFFF`; the remaining 20% spread across
  2408 distinct intermediate values. This is a real, structural pattern — not noise — consistent
  with a multi-channel blend/weight map (mostly "pure" single-texture cells, with blended values
  clustering at texture-boundary transitions), the shape a real ground-texture splat map would
  take.

**Not decoded further yet**: the exact row/column layout, and whether it cross-validates against
a matching `.m` file's tile grid, are both still open. Even if fully decoded, a blend/weight map
by itself would only say *where* textures blend, not *which* real texture files fill each channel
— no such texture lookup/table has been found anywhere in this project's available real data. The
real terrain pixel shaders found alongside this investigation (`terrainps14.psh`,
`terrainpsn10.psh`, `terrainpsp10.psh`, and their `detail` variants) all sample a single continuous
`TEX_TERRAIN_COLOR` texture stage, not a multi-layer type-index blend, and no generic tileable
ground texture (grass/dirt/sand/rock/snow, as opposed to a creature/prop texture) was found
anywhere in this project's available real client data — a real gap this project's own RE
environment couldn't close, not one that was given up on early (see `server/cmd/pk2list`, a small
tool built specifically to let a user search their own real client pk2 archives for a real ground
texture path this project doesn't have a sample of). Flagged here as a real, promising, unresolved
lead for a future pass, not a solved format.

## Real samples available for future verification

`Map.pk2` → `<region>/<region>.m` — 25 pulled in this environment across two passes: `0/0.m`,
`0/1.m`, `0/2.m`, `1/0.m`, `1/1.m` (Shape A) and `100/100.m`-`104/100.m` (Shape B, covering
region-name suffixes `_100` through `_104`). Extracted directly from a real `Map.pk2` (1.5GB) via
this project's own `server/internal/pk2` reader (used and deleted twice — not kept in this
environment between sessions, re-extract on demand rather than assuming it's still there).
