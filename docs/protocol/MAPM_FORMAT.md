# MAPM terrain/heightmap format (JMXVMAPM)

`.m` files inside `Map.pk2` (one per map region, alongside that region's `.o` object-placement
file — see [MAPO_FORMAT.md](MAPO_FORMAT.md)) are the terrain/heightmap data.

## Real per-region world size confirmed: 1920.0 units

Found via a real class, `CRegionManagerBody` (`sro_client.exe`), located through the full RTTI
chain (raw mangled name `.?AVCRegionManagerBody@@` in memory → `TypeDescriptor` →
`RTTICompleteObjectLocator` → vtable → real constructor confirmed calling it, then a real
constructor-only global singleton instance). Decompiling its real 32-slot vtable found a real
cross-region movement/pathing method, confirmed via its own literal embedded source path
(`D:\vss-od\JMX_Library\navmesh\RegionManagerBody.cpp`), which adjusts a position's local
coordinates by a fixed constant every time it steps across a region boundary. That constant is a
real, compile-time `double` (`FLD double ptr [addr]`, zero write-sites anywhere in the binary —
confirmed not runtime-computed) with value **1920.0**.

`client/scripts/assets/mapm_terrain_builder.gd`'s `TILE_SIZE` now derives from this real value
(`1920.0 / (GRID_WIDTH - 1)`), assuming the already-confirmed 17-wide column field spans one whole
real region rather than a sub-patch — not proven, but the cleanest reading available (no evidence
of sub-patches, and the arithmetic lands on an exact round number, 120.0). This also happens to
make real elevation changes read as far gentler slopes than the previous arbitrary spacing, purely
as a side effect of spacing samples 6x further apart along the same real height data.

## Real row-layout mystery: one more attempt, still unsolved (2026-08-22)

Tried a fresh angle this project didn't have available during the original investigation: `.m`'s
magic isn't a literal embedded string in any binary (confirmed again — real magic strings in this
codebase are built up byte-by-byte in code, same as `.bsr`; a raw string search only turns up
truncated 4-byte fragments), so searched `SR_GameServer.exe` (the real main gameplay server,
imported into this project's RE environment well after `.m` was first investigated) for the same
literal `JMXV` 4-byte constant used in `CMP`/`MOV` instructions, the technique that found other
real formats' construction sites this session. **Zero hits.** Most likely explanation: the real
world server validates movement/collision against the separate real `navmesh\*.ifo` files (found
live this session — `object.ifo`, `objectstring.ifo`, `objext.ifo`, `tile2d.ifo`, all under a real
`navmesh\` folder), not `.m` heightmap data at all — visual terrain height and server-side walkable
navigation are plausibly two entirely separate real subsystems. This closes off another real,
concrete angle rather than leaving it untried, but doesn't move the row-layout mystery itself
forward. Still unsolved; still empirically-derived-only, as below.

**Practical engineering workaround, not a research answer**: `client/scripts/assets/
mapm_terrain_builder.gd`'s `build_mesh` now accepts an optional `max_rows` cap. Without one, a real
region's rows are chained in raw file order (the only order this project can confirm — see below),
producing an extremely elongated ribbon rather than anything resembling a real region's actual
footprint (confirmed live: a real `100/100.m` parsed to 777 rows, a ~320×15,500 unit strip).
Capping at `GRID_WIDTH` (17) rows reshapes that ribbon into an actual square, using only the same
already-confirmed real per-tile data — this is what let `World3D.gd` build a real, walkable
multi-region grid (`_load_region_neighborhood`, see its doc comment and `README.md`) by tiling
these squares at a fixed, **this project's own designed** spacing. Real per-region world scale and
real adjacency between regions remain unconfirmed either way.

**Real bug found and fixed (2026-08-22)**: the first version of this grid had each tile
independently force its own near-row-middle vertex to world Y=0, guaranteeing a cliff at *every*
seam between tiles and trapping the camera in overlapping geometry (confirmed via live screenshot
testing against real pk2 files). Fixed by anchoring the whole grid to the center tile's own
`near_height` instead of letting every tile reset itself independently — see
`_load_region_neighborhood`'s doc comment. This does not (and can't, without real cross-region
data) make neighboring tiles seamlessly continuous, and does not fix the separate fact that even a
*single* tile's real data can be steep enough on its own to enclose the camera near a given spawn
point — both remain blocked on the row-layout mystery above.

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

## The real `.m` loader function: found (2026-08-22), correcting an earlier wrong conclusion

**This project previously stated no decompiled loader was ever found for `.m` in `sro_client.exe`
or `EternityLib.dll`. That's now wrong, and is corrected here rather than left standing.**

Found by searching for the literal real path-format string this project hadn't tried yet:
`"%d\%d.m"` (a plain ASCII string, unlike the byte-by-byte-constructed magic). It exists once in
`sro_client.exe`, referenced by exactly one real function (`FUN_0042a6e0`), which:

- Builds the path with `sprintf_s(..., "%d\\%d.m", <Y sector>, <X sector>, ...)` and opens it
  through a real virtual file-open call — a real, concrete, first-ever-found loader entry point
  for this format.
- Is confirmed, via multiple literal embedded source-path/assert strings, to belong to
  **`D:\vss-od\JMX_Library\navmesh\MapLoader.cpp`** — real member name `m_s2DTileInfo` and real
  local variable name `w2DTile` both appear in real assert strings (`"w2DTile <
  m_s2DTileInfo.size()"`).
- **Corrects an earlier real mistake in this project**: a previous pass found a real class
  `CMapLoader` via RTTI and concluded it was "the navmesh loader, a different real subsystem
  entirely, not the visual terrain/texture system" — i.e. that navmesh and `.m` were unrelated.
  That conclusion is now shown to be wrong: the real navmesh `MapLoader.cpp` **does** open and
  parse `.m` files directly. Navmesh (walkability) and the real heightmap grid this project
  already renders are evidently built from the same source file, not two independent systems —
  retracted here rather than left standing, same discipline as this project's other corrections.
- Later in the same function, also builds and opens `"%d\%d.o2"` (a real second, already-known
  sibling file — see `MAPO_FORMAT.md`) for the same region.

**Real structural clues found in this function, not yet fully decoded into a confirmed algorithm**
(the function is ~300 lines of dense, heavily-optimized nested loops — recording what's solidly
visible without rushing a guess at the full picture):

- A real **6×6 outer loop structure** (two nested loops, each running exactly 6 iterations)
  processes the loaded region in that many sub-units.
- A real inner bound of **`0x121` (289 = 17×17)** appears in the per-sub-unit tile-assembly logic —
  the same real `17` column width this project already confirmed independently via `.m`'s own
  per-tile column field, now also showing up structurally in the real loader itself.
- A real stride value **`0x61` (97 decimal)** recurs as an array/loop stride — consistent with the
  classic public "97×97 vertex grid → 96×96 quads" terrain-patch convention long documented by the
  private-server community for this MMO family, previously guessed at and *retracted* earlier in
  this same file's history (misread as a common tile byte value, not a dimension) — this is new,
  independent, structural evidence for that same number showing up for a real reason, via a
  completely different (loader-code) signal than the original guess.

**A second real loader function was then found, and it changes the reading above rather than
confirming it** — searched for the same `"%d\%d.m"` string's other real reference (`FUN_00a361b0`)
and found it belongs to a *different* real source file, **`D:\vss-od\Silkroad\Client\Landscape\
MapEngine\MapCallBack.cpp`** — the actual visual-rendering "Landscape/MapEngine" subsystem, as
opposed to the first function's navmesh subsystem. This function also opens both `.m` and `.o2` for
the region, and has its own real 6×6 outer loop (confirmed precisely via its real loop increments:
inner stride `0x31`=49 six times, outer stride `0x126`=294 (`= 6×49`) six times, bound `0x6e4`=1764
`= 6×294`). **But this loop's body reads three separate real counted lists per sub-cell** (a
16-bit count, then that many entries, three times per iteration) — the same real shape as
placed-object/event data (matching the real `"event"`/`"EVENT"` tag handling found earlier this
session in a related function), not a per-tile height read. **This is most likely the real spatial
index for `.o2`'s object/event placements (a 6×6 grid of lookup sectors per region), not `.m`'s
height grid** — a real, concrete correction to this doc's own first guess (recorded a few
paragraphs up) that the `MapLoader.cpp` function's 6×6/289/97 numbers described `.m`'s row/column
layout directly. They may still be related (both functions process the same region), but this
second function's evidence points at object indexing, not heightmap dimensions, so that link isn't
asserted here. Where either function actually reads the real per-tile *height* floats into a grid
has not been located in either decompilation pass — genuinely still open, not guessed at.

**Where this leaves the row-layout mystery**: two real, previously-never-found loader functions
now exist to trace further (`FUN_0042a6e0` in `MapLoader.cpp`, `FUN_00a361b0` in
`MapCallBack.cpp`), a real, independent confirmation that `17` and `97` both show up structurally
in real loader code (not just this project's own statistical/column-field analysis), and a real,
concrete open question (which part of either function reads height floats into a 2D grid, and at
what real stride) for whoever continues this. Not resolved this pass, but a real, substantial step
closer than "no loader has ever been found," which was this doc's honest state before today.

## A real, unopened sibling file: `.t` (`JMXVMAPT1001`) — a possible ground-texture blend map

Every real `Map.pk2` region folder also contains a `.t` file alongside its `.m`/`.o`/`.o2` files
(magic `JMXVMAPT1001`) — never decoded before this project went looking for a real ground-texture
system to answer why rendered terrain looked like flat color instead of the actual game. Real
structural findings so far:

- Every real `.t` file is **exactly 140436 bytes**, fixed across every region checked — unlike
  `.m`/`.o`/`.o2`, which vary in size per region.
- **Header size confirmed (2026-08-22): 16 bytes**, not just plausible -- the literal 12-byte
  magic string `JMXVMAPT1001` (confirmed via direct hex dump of a real `100/100.t`) plus a real
  4-byte field right after it whose value doesn't look like a small version/flags number
  (`0xFFB2CC99`), meaning it's something else not yet identified -- but 16 is the *only* header
  size in a small tested range (0-24 bytes) that divides the remaining body cleanly into whole
  `uint32` cells that are *also* cleanly divisible by 17, so it's confirmed by more than one line
  of evidence now, not just plausibility.
- The 140420-byte body divides cleanly by **17** — the same real column width `.m`'s Shape A
  confirmed above. Read as 35105 `uint32` (little-endian) cells, that count also divides cleanly
  by 17. **This numeric fact holds, but see the new negative result below for why it doesn't mean
  17 is confirmed as this file's real row-major width.**
- 80% of those cells are exactly `0x00000000` or `0xFFFFFFFF`; the remaining 20% spread across
  2408 distinct intermediate values. This is a real, structural pattern — not noise — consistent
  with a multi-channel blend/weight map (mostly "pure" single-texture cells, with blended values
  clustering at texture-boundary transitions), the shape a real ground-texture splat map would
  take.

**New real, concrete negative result (2026-08-22)**: pulled a real `100/100.t` and tested whether
its 35105 cells actually form a coherent row-major 2D raster at any of the widths that divide the
cell count cleanly (`5, 7, 17, 35, 59, 85, 119, 295, ...` -- the factors of `5×7×17×59`). A real
2D blend/weight map should show real neighboring-cell similarity (low byte-value differences
between adjacent cells) well *below* a random-shuffle baseline at its true width. Measured on each
of the 4 individual byte channels within each `uint32` cell (not the raw 32-bit value as one unit,
since a real multi-channel blend map would only show false incoherence if compared that way):
**every single candidate width, 17 included, scored** ***worse*** **than randomly shuffling the
same bytes** (~210-220 mean absolute difference vs. a ~126 random baseline). This rules out the
simplest hypothesis (a plain row-major `W×H` raster at any of `.t`'s own clean-divisor widths,
17 included) rather than confirming it -- a real, informative negative result, not just "still
unknown." Most likely explanations: the file's real cell order matches whatever internal tile
order `.m` itself uses (the very row/column mystery this file was hoped to help solve
independently, meaning it's encoded in the same unresolved order rather than a plain raster), or
the real layout involves tiled/swizzled memory blocks rather than simple row-major scanning.
Recorded so a future pass doesn't re-try the same naive raster-width scan.

**Not decoded further yet**: the exact row/column layout, and whether it cross-validates against
a matching `.m` file's tile grid, are both still open. Even if fully decoded, a blend/weight map
by itself would only say *where* textures blend, not *which* real texture files fill each channel
— no such texture lookup/table has been found anywhere in this project's available real data. The
real terrain pixel shaders found alongside this investigation (`terrainps14.psh`,
`terrainpsn10.psh`, `terrainpsp10.psh`, and their `detail` variants) all sample a single continuous
`TEX_TERRAIN_COLOR` texture stage, not a multi-layer type-index blend, and no generic tileable
ground texture (grass/dirt/sand/rock/snow, as opposed to a creature/prop texture) was found
anywhere in this project's available real client data — a real gap this project's own RE
environment couldn't close at first, not one that was given up on early. Flagged here as a real,
promising, unresolved lead for a future pass, not a solved format.

**Revisited**: searched `sro_client.exe`/`EternityLib.dll`/`GFXFileManager.dll` for a real magic
string, class-name strings ("Terrain", "MapData", etc.), and RTTI type descriptors that might lead
to a real `.t` loader function, the same technique that found `ResObject::Load` for `.bsr` (see
`BSR_FORMAT.md`). No literal `.t`/`JMXVMAPT` magic string exists in any of the three binaries (the
format likely validates its magic byte-for-byte against constructed bytes, like `.bsr` does, not
via an embedded string literal — so this search technique can't find it this way). The one
promising real class name found (`CMapLoader`, via a real `CSingletonT<CMapLoader>` RTTI
descriptor, plus a real `"D:\...\navmesh\MapLoader.cpp"` string) turned out to be the **navmesh**
(AI pathfinding) loader, a different real subsystem entirely, not the visual terrain/texture
system — a real, confirmed-wrong lead, not a guess. No further real entry point was found in the
time spent. This remains a genuine, currently-unsolved RE gap, same conclusion as before, now with
one more specific dead branch (`CMapLoader`/navmesh) ruled out and recorded so a future pass
doesn't re-check it.

## What actually shipped instead: a real per-region minimap image, via `server/cmd/pk2list`

The RE environment used throughout this project turned out to also have a genuine full retail
client install (`/opt/sro-files/client/*.pk2`), not just the private-server package tree every
other real sample in this project came from. `server/cmd/pk2list` (a small Go CLI, `-filter
<substring>` to search, `-extract <path> -out <file>` to pull one real file out) found
`Media.pk2\minimap\<region_x>x<region_y>.ddj` — a real, per-region, painted top-down texture
(256×256, decoded successfully with this project's own `DdjReader`) keyed by the exact same region
coordinates as `Map.pk2`'s `<x>/<y>.m` files.

This is **not** a claim that this is the live 3D ground texture the real client's terrain shaders
sample at runtime (see the section above — that still hasn't been found or confirmed). It's real,
region-accurate painted art standing in for it, which is why `World3D.gd` documents it the same
way. See `README.md`'s `SRREVAMP_MAPM_TEXTURE_PATH`/`SRREVAMP_MEDIA_PK2_PATH` and
`docs/PROGRESS.md` for the real screenshot this produced.

## Real samples available for future verification

`Map.pk2` → `<region>/<region>.m` — 25 pulled in this environment across two passes: `0/0.m`,
`0/1.m`, `0/2.m`, `1/0.m`, `1/1.m` (Shape A) and `100/100.m`-`104/100.m` (Shape B, covering
region-name suffixes `_100` through `_104`). Extracted directly from a real `Map.pk2` (1.5GB) via
this project's own `server/internal/pk2` reader (used and deleted twice — not kept in this
environment between sessions, re-extract on demand rather than assuming it's still there).
