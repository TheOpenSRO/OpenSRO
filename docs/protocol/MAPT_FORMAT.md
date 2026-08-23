# MAPT terrain lighting/shadow format (JMXVMAPT)

`.t` files inside `Map.pk2` exist alongside a region's `.m`/`.o`/`.o2` files (this content used to
live inline in [MAPM_FORMAT.md](MAPM_FORMAT.md); split out into its own doc once fully solved,
matching the `.o`/`.o2` precedent).

## Solved (2026-08-23): a real per-region shadow map + embedded DDS lightmap texture

**Source**: [`JellyBitz/srodevs-docs`](https://github.com/JellyBitz/srodevs-docs) (the same public
private-server community reference that solved `.m` — see MAPM_FORMAT.md's own citation and
`docs/LEGAL.md` point 3 on why this is fair game), specifically its `jmxvmapt.md` page.

**The real structure**, verified byte-for-byte against a real `100/100.t` sample (140,436 bytes):

- 12-byte header: magic `"JMXVMAPT"` + a 4-byte ASCII version (e.g. `"1001"`).
- A real, fixed **9,216-byte ShadowMap** (`96×96` bytes) — per the public doc, "a simplified map
  used to check if an object is inside shadow."
- `TextureLength` (`uint32`, real, confirmed to count *itself and `TextureType` together* — i.e.
  the real embedded texture's own byte length is `TextureLength - 8`) + `TextureType` (`uint32`,
  a real Direct3D9 `D3DRESOURCETYPE` value — `3` = `D3DRTYPE_TEXTURE` in the one real sample
  checked).
- The `Texture` field itself: a real, complete, standard **embedded DDS file** (literally starts
  with the `"DDS "` magic and a real, standard 124-byte `DDS_HEADER` + `DDS_PIXELFORMAT`) — not a
  raw pixel blob at some inferred offset, which is exactly where an earlier same-day pass on this
  format went wrong (see "History" below). Parsed the real sample's own DDS header directly: real
  `Width`/`Height` = `512`/`512`, real pixel-format FourCC = `"DXT1"`, real pixel data starts at
  DDS byte offset `128` (4-byte magic + 124-byte header) and is exactly `131,072` bytes (a clean
  single-mip `512×512` DXT1 payload — `(512/4)×(512/4)×8`).
- **Total real bytes consumed, exactly**: `12 + 9,216 + 8 + 131,200 (the whole real embedded DDS,
  128-byte header + 131,072-byte pixel payload) = 140,436` — matching the real file's own size
  *exactly*, zero leftover. This is what the earlier same-day pass's `9,340`-byte "unexplained
  gap" actually was: the real `ShadowMap` (9,216 bytes) plus the real DDS's own header (124 bytes,
  4-byte-magic-inclusive) — `9,216 + 124 = 9,340` exactly.

**Decoded and visually verified** (both with `ImageMagick` and Godot's own `Image` class, cross-
checked): the real embedded texture is a genuine, plausible **grayscale lightmap** — soft gray
shadow-patch clusters (matching real object/terrain shadow shapes) on an otherwise white (fully
lit) background. This is a categorically different, far more plausible result than the earlier
same-day pass's decode (see "History" below), which used the wrong byte offset and produced
garish, implausible color noise.

## What this still doesn't tell us

- The real `ShadowMap`'s own per-byte meaning beyond "a simplified in-shadow check" (the public
  doc's own description) — not independently decoded byte-by-byte.
- Real ground *albedo* texture (as opposed to this lighting/shadow layer) remains unfound — see
  `MAPM_FORMAT.md`'s own note that the real terrain pixel shaders sample one continuous
  `TEX_TERRAIN_COLOR` stage this project hasn't located a source file for.
## Implemented and live-verified (2026-08-23)

`client/scripts/mapt/mapt_reader.gd` (`MapTReader`) parses the real structure above — the 12-byte
header, the raw 9,216-byte ShadowMap, and the embedded DDS (decoded via `Image.create_from_data`
using the DDS's own real width/height/FourCC). **Caught a real off-by-4 bug in the DDS pixelformat
field offset via live testing against a real sample**: a self-consistent-but-wrong synthetic test
fixture wrote and read back the FourCC at the same wrong offset, passing cleanly, while the real
file's genuine `DDS_PIXELFORMAT` offset (relative to the header, after the 4-byte magic) is `72`,
not `76` — the real sample decoded to `null` until this was found and fixed in both the reader and
the test fixture.

Wired into `World3D.gd`'s terrain material via Godot's built-in `ao_enabled`/`ao_texture`/
`ao_light_affect` (ambient occlusion) — the real embedded texture's white-background/gray-shadow
shape is exactly what Godot's AO darkening expects, no custom shader needed. **Live-verified with
an unobstructed top-down debug camera against a real Shape B region**: a soft, plausible,
subtle shadow-patch pattern visible on the terrain — categorically different from (and a real
improvement over) the earlier, reverted direct-color-overlay attempt's jarring glitch static.

## History: the earlier same-day investigation (kept in full, corrected rather than deleted)

This section is the real, honest record of how this format was investigated *before* the public
documentation was found, including a real decompiled loader function this project found
independently and a wrong structural guess that a live-rendering test caught and this doc's
"Solved" section above then corrected. Kept per this project's standing discipline of recording
mistakes rather than silently overwriting them.

### A real, unopened sibling file: a possible ground-texture blend map

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
unknown." (This is now understood: DXT1 block compression, not a plain raster — see "Solved"
above.)

**Revisited**: searched `sro_client.exe`/`EternityLib.dll`/`GFXFileManager.dll` for a real magic
string, class-name strings ("Terrain", "MapData", etc.), and RTTI type descriptors that might lead
to a real `.t` loader function, the same technique that found `ResObject::Load` for `.bsr` (see
`BSR_FORMAT.md`). No literal `.t`/`JMXVMAPT` magic string exists in any of the three binaries (the
format likely validates its magic byte-for-byte against constructed bytes, like `.bsr` does, not
via an embedded string literal — so this search technique can't find it this way).

### The real `.t` loader: found (2026-08-23), correcting the "no magic string" conclusion above

**The claim above that no literal `.t`/`JMXVMAPT` magic string exists in `sro_client.exe` is
still true, but this project hadn't yet tried the same real, literal per-region *path-format*
string search that found `.m`'s and `.o2`'s loaders** (`"%d\%d.m"`, `"%d\%d.o2"` — see
`MAPM_FORMAT.md`'s "real loader function" sections). Trying the analogous `"%d\%d.t"` string found
it immediately: it exists once in `sro_client.exe`, referenced by exactly one real function,
`FUN_00a31d20` — a genuine, first-ever-found `.t` loader.

**What it actually does, precisely** (the whole function is short and clean, no ambiguity):

- Builds the path via `sprintf_s(..., "%d\\%d.t", ...)` and opens it through the same real
  virtual file-open call `.m`/`.o2` use.
- If the file **doesn't** exist: calls a thin wrapper (`FUN_00b8bcf0`) around a real virtual method
  at vtable offset `+0x5c` on a device object — the exact real argument shape
  (`Width=512, Height=512, Levels=1, Usage=0, Format=0x31545844, Pool=1, &ppTexture, pSharedHandle=
  NULL`) is a precise, unambiguous match for **Direct3D 9's `IDirect3DDevice9::CreateTexture`**,
  and `0x31545844` read as 4 ASCII bytes is literally **`"DXT1"`**. This branch creates a blank
  placeholder texture when a region has no real `.t` file.
- If the file **does** exist: reads exactly **12 bytes** into a stack buffer right after opening
  (matching the real confirmed 12-byte `"JMXVMAPT1001"` magic+version length exactly), then calls
  the **exact same** `CreateTexture(512, 512, 1, ..., DXT1, ...)` as the missing-file branch, and
  closes the file handle.

This confirmed the real intended texture format (512×512, 1-mip, DXT1) precisely, but the traced
function only reads 12 bytes before creating the texture and closing the handle — it doesn't
itself read the bulk pixel payload, so the exact byte offset where real pixel data begins wasn't
confirmed by this decompilation alone.

### A wrong guess, tested live, and corrected (2026-08-23)

Assumed the real pixel data started immediately at a `24`-byte offset (12-byte magic+version + the
12 bytes the loader function reads) and wrapped the remaining bytes in a hand-built minimal DDS
header. **Every tested offset (`0`, `12`, `16`, `24`) decoded into a real, structured (non-random)
image** — sparse, colorful blob-shaped clusters on a blank white field, with the same blob shapes
at every offset (a real property of the underlying data, not an alignment artifact) — consistent
with the doc's own earlier 80%-pure/20%-blended byte statistics.

**Tried wiring this into the renderer and reverted after live testing looked wrong**: applied the
decoded texture as a `StandardMaterial3D` detail-albedo direct color overlay. Live-verified with an
unobstructed top-down debug camera against a real Shape B region: the decoded blob-cluster shapes
applied exactly where expected, but rendered as literal color they produced jarring cyan/magenta
"glitch static," not plausible ground detail. Reverted the renderer wiring rather than ship a
visually-broken result.

This negative result is what prompted checking the trailing "9,340-byte gap" (`140,436 - 24 -
131,072`) more carefully instead of accepting the wrong `24`-byte-offset guess, which led directly
to finding the public documentation and the real structure recorded in "Solved" above — the wrong
guess wasn't wasted effort, it's what made the real gap visible enough to go looking for a better
source.
