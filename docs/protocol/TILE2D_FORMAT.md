# 2D tile index format (JMXV2DTI, `tile2d.ifo`)

`tile2d.ifo` is the real answer to what a `.m` region file's real per-vertex `TextureInfo.ID`
field (see [MAPM_FORMAT.md](MAPM_FORMAT.md)) actually resolves to: a real, plain-text table of
ground-tile types, one per real texture ID.

## Source and real location

**Source**: the same public private-server community documentation
([`JellyBitz/srodevs-docs`](https://github.com/JellyBitz/srodevs-docs)) that solved `.m` and `.t` —
per [`docs/LEGAL.md`](../LEGAL.md) point 3, this is fair game as a public protocol spec.

**Confirmed present** in a real client install at **both** `tile2d.ifo` (pk2 root) and
`navmesh\tile2d.ifo` (identical 36,629-byte file at both paths) inside a real `Data.pk2` — the same
`navmesh\` location `object.ifo` turned out to really live at (see `MAPO_FORMAT.md`), not pk2 root
as an earlier pass in this project assumed for that file.

## Structure

Like `object.ifo` (see `MAPO_FORMAT.md`), this is **not a binary container** — after the magic
line, it's read line by line as plain ASCII text:

```
JMXV2DTI1001
<TileCount>
<one line per tile, see below>
```

Each tile line: `%05d 0x%08x "<Category>" "<Filename>"`, optionally followed by a trailing
`{a,b}` grass-placement hint (a real `object.ifo` index + a random grass-amount count — not needed
for ground-texture identification, so not decoded further here). Real example lines from a real
`tile2d.ifo`:

```
00000 0x00000000 "CJfild" "c_dust_fld_01.ddj"
00002 0x0000000a "CJfild" "c_grass_fld_03.ddj"
00007 0x0000000a "HMfild" "c_grass_hmfld_01.ddj" {757,64}
```

The `0x%08x` field is a real `TileType` enum (per the public documentation):

```
Dirt=0, Sand=1, Ashfield=2, Stone=3, Metal=4, Wood=5, Mud=6,
Water=7, DeepWater=8, Snow=9, Grass=10, LongGrass=11, Forest=12, Cloud=13
```

## Verified against a real sample

Pulled a real `tile2d.ifo` (36,629 bytes) directly from `Data.pk2` and parsed it: **719 real
entries**, in strict sequential ID order starting at 0, every line matching the documented shape
exactly (36 of the 719 have the optional trailing grass-placement field). The real `TileType`
values actually seen in this one sample (`0, 1, 3, 6, 7, 9, 10, 11, 12` — a subset of the full
14-value enum) all decode to plausible, sensible categories given their real filenames (e.g. ID 2,
type `0x0000000a` = `Grass`, filename `c_grass_fld_03.ddj`).

## Corrected 2026-08-23: the real texture files were never missing — wrong archive

An earlier pass (2026-08-23, same day) declared these real `.ddj` filenames
(`c_dust_fld_01.ddj`, `c_grass_fld_03.ddj`, `wc_grass00.ddj`, `stormdesert_stone01.ddj`, etc.)
absent after checking `Data.pk2`, `Media.pk2`, and `Particles.pk2`. That conclusion was wrong, and
avoidably so: this project's own client-install listing (see `NVM_FORMAT.md`'s file-size table)
also has a `Map.pk2`, which that pass never checked, on the reasoning that everything else
per-region (`.m`/`.o`/`.o2`/`.t`) lives at `Map.pk2`'s *root*, not a named subfolder — a pattern
match that turned out not to generalize. A user push-back on that "exhausted" conclusion prompted
re-checking every real archive systematically (`server/cmd/pk2list` against all 5 real pk2 files),
which found a real `Tile2D\` folder inside `Map.pk2` containing **752 real `.ddj` files** — every
one of the filenames above included, byte-identical in name to their `tile2d.ifo` entries. The
earlier "0.8% partial, mostly a coincidental name collision" framing (from checking `Data.pk2`'s
unrelated `Prim\Mtrl\Nature\` prop-texture folder — see below) is retracted as the real answer;
that near-hit really was a coincidental prop-texture collision, but the *actual* ground textures
were sitting one archive over the whole time.

**Real format**: `Map.pk2\Tile2D\<filename>` is a `.ddj` file — a small, real, confirmed 20-byte
wrapper (`JMXVDDJ 1000` magic, a size field) around a completely standard embedded DDS (mostly
DXT1-compressed, with real mipmaps), the same real container format already reverse-engineered for
other assets — see `docs/protocol/DDJ_FORMAT.md` and `client/scripts/ddj/ddj_reader.gd`
(`DdjReader`), which needed no changes to read these once the real path was found.

**Live-verified**: extracted `Tile2D\c_grass_fld_03.ddj` (174,924 bytes) directly and decoded it —
a real 512x512 DXT1 texture with 10 real mip levels, genuinely a tileable grass ground texture (not
a prop atlas like the earlier `asiaminor_stone01.ddj` near-hit). Wiring the full set into
`MapmTerrainBuilder` (see "Implementation" below) and rendering real region `100/100` shows
unmistakably real gravel/stone, sand-grain, and grass textures, not flat debug colors.

**The earlier near-hit, still correctly identified as unrelated**: checking the *specific* real
texture IDs a real `.nvm` file's `TileMap` uses (rather than an arbitrary early sample of
`tile2d.ifo`'s own list) had found `Prim\Mtrl\Nature\asia minor\asiaminor_stone01.ddj` inside
`Data.pk2` — a real file, but part of a complete, separate `.bsr`/`.bms`/`.bmt`/`.ddj` object-prop
asset (a standalone rock-formation model), not ground art. That specific finding still stands; it
was the broader "therefore ground textures don't exist" conclusion drawn around it that was wrong.

`environment.ifo` (the other real per-block lookup `.m`'s `EnvironmentID` field references) is
still not found at pk2 root or under `navmesh\` in `Data.pk2` — but per the correction above, that
absence hasn't been re-checked against `Map.pk2` specifically yet; treat it as unconfirmed, not
settled, until it has.

## Implementation

`client/scripts/tile2d/tile_index_reader.gd` (`TileIndexReader`) parses the real structure above
and is re-verified against the real 719-entry sample. `MapmTerrainBuilder.build_full_region_mesh_textured()`
resolves each real vertex's `TextureInfo.ID` through a parsed table to a real `tile2d.ifo`
filename, which `World3D._load_real_ground_textures()` loads from `Map.pk2\Tile2D\<filename>` via
`DdjReader` (cached by filename across regions) and passes back in as a real per-ID texture lookup
— each real quad gets its own real texture on its own mesh surface. A quad whose resolved ID has no
real texture (or when no `SRREVAMP_MAP_PK2_PATH` is set at all) falls back to
`_vertex_color()`'s `TileType`-driven color coding, unchanged from before this correction.

**Live-verified** against a real Shape B region (`100/100`, both a wide 3x3-region top-down render
and a close-up): the rendered terrain shows real gravel/stone texture, real sand-grain texture, and
real grass texture, following the terrain's own real contours and real per-quad tile assignment —
not a plausible-looking stand-in color, the actual real game art.
