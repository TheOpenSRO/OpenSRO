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

## A real gap: most referenced texture files are missing, but not all of them

**Checked directly, and widened (2026-08-23)**: most of the real `.ddj` filenames this table
references (`c_dust_fld_01.ddj`, `c_grass_fld_03.ddj`, `wc_grass00.ddj`, `stormdesert_stone01.ddj`,
and others checked) don't exist anywhere across the real pk2 archives this project's client
install has. `environment.ifo` (the other real per-block lookup `.m`'s `EnvironmentID` field
references) is **entirely absent too** — not present at pk2 root or under `navmesh\` in this real
`Data.pk2`, unlike `object.ifo`/`objectstring.ifo`/`objext.ifo`/`tile2d.ifo`, which are all real
and present there.

**Corrected, not total absence (2026-08-23, via `NVM_FORMAT.md`)**: checking the *specific* real
texture IDs a real `.nvm` file's `TileMap` actually uses for one real region (rather than an
arbitrary early sample of `tile2d.ifo`'s own list) found the real files live under
`Prim\Mtrl\Nature\<region-folder>\...` — a path this project hadn't checked — and **one of them
genuinely exists**: `Prim\Mtrl\Nature\asia minor\asiaminor_stone01.ddj`. A systematic check of all
719 real `tile2d.ifo` filenames against every real `.ddj` path in `Data.pk2` found **6 real
matches (0.8%)** — small, but real and non-zero. This is most likely a real client-version/asset
mismatch (this specific retail build may predate or postdate whatever patch shipped most of these
files, keeping only a handful still referenced from elsewhere), not a parsing bug or a search
miss — the `tile2d.ifo` table itself parses perfectly and its `TileType` classifications are
internally consistent and plausible. Given the real coverage is too sparse (0.8%) to build a
complete ground-texture system on, this project's `TileType`-driven color coding remains the
practical approach for now.

This means the real ground *texture* files themselves remain unrecovered, same open gap
`MAPM_FORMAT.md` already flagged. What this table *does* give, independent of the missing texture
files: a real, confirmed per-ID `TileType` classification, useful on its own for real,
semantically-grounded (not arbitrary) terrain coloring — see "Implementation" below.

## Implementation

`client/scripts/tile2d/tile_index_reader.gd` (`TileIndexReader`) parses the real structure above
and is re-verified against the real 719-entry sample. `MapmTerrainBuilder._vertex_color()` uses a
parsed table (when available) to map a vertex's real `TextureInfo.ID` to a real `TileType`, then to
a real-world-plausible stand-in color for that category (grass green, sand tan, snow white, water
blue, etc. — not sampled from any real texture, since the real texture files aren't available).
Falls back to the previous data-driven hue-sweep coloring when no table is loaded. `World3D.gd`
loads and caches the real table once per scene from `SRREVAMP_PK2_PATH`'s `Data.pk2`.

**Live-verified** against a real Shape B region: the rendered terrain shows real, distinct,
semantically plausible dirt/grass patches following the terrain's own real contours — a
categorical improvement over the previous arbitrary green-to-brown gradient, and a much more
game-like result even without the real texture files themselves.
