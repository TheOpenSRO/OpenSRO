# Navigation mesh format (JMXVNVM, `.nvm`)

`.nvm` files are the real per-region navigation mesh: real walkability/pathfinding data,
independent of (but closely related to) `.m`'s terrain heightmap.

## Real, confirmed location — not where every other per-region file lives

Unlike `.m`/`.o`/`.o2`/`.t` (all in `Map.pk2`, named `<x>\<y>.ext`), real `.nvm` files live in
**`Data.pk2`**'s `navmesh\` folder (**6,543 real files** in the one client install checked),
named by a real **packed region ID** in hex: `nv_<hex>.nvm`. Confirmed the packing scheme
directly: region `100/100`'s `.m`/`.o` files are `100\100.m`/`100\100.o`, and the real navmesh
file for that same region is `navmesh\nv_6464.nvm` — `100 = 0x64`, packed as `(Y << 8) | X =
0x6464`. This packing scheme is also confirmed independently below (see "Real cross-region
linking, confirmed") via a real global edge's `AssocRegionIdFrom`/`To` fields — not just this one
filename. (A same-day guess that this scheme also explained a previously-unexplained constant in
`.o2`'s own entries didn't hold up under closer checking — see `MAPO2_FORMAT.md`'s own retraction
of that specific claim; this `.nvm` filename-encoding finding itself is unaffected.)

## Source and structure

**Source**: the same public documentation ([`JellyBitz/srodevs-docs`](https://github.com/JellyBitz/srodevs-docs))
that solved `.m`/`.t`/`tile2d.ifo` — fair game per [`docs/LEGAL.md`](../LEGAL.md) point 3.

**Verified byte-for-byte against a real sample** (`navmesh\nv_6464.nvm`, 113,053 bytes) — parses
**with zero leftover bytes on the first attempt**:

```
12  string  Signature          // "JMXVNVM 1000" -- note the real literal space before "1000"
2   short   ObjectCount
foreach(ObjectCount): MapObject (30-byte fixed header + LinkedEdgeCount + that many 6-byte LinkedEdges)
4   uint    CellCount
4   uint    WalkableCellCount
foreach(CellCount): Cell (16-byte rect + 1-byte ObjectIndexCount + that many 2-byte indices)
4   uint    GlobalEdgeCount
foreach(GlobalEdgeCount): Edge, 27 bytes (16-byte line + flags + 2 dirs + 2 cell indices + 2 real region IDs)
4   uint    InternalEdgeCount
foreach(InternalEdgeCount): Edge, 23 bytes (same, minus the 2 real region IDs)
Tile TileMap[96*96]     // 8 bytes each: CellIndex(u32) + Flags(u16) + TextureID(u16)
float HeightMap[97*97]  // real float32 heights
byte PlaneTypeMap[6*6]
float PlaneHeightMap[6*6]
```

The one real sample checked had 0 real objects, 16 real cells (11 walkable), 20 real global edges,
29 real internal edges — all consumed exactly, landing precisely on the file's real 113,053-byte
end.

## Independent cross-validation: an exact match with `.m`

The real embedded `HeightMap` (97×97 = 9,409 real `float32` values) was checked against this
project's own, separately-parsed real `100/100.m` heightmap (via `MapmReader`'s confirmed
block/vertex structure — see `MAPM_FORMAT.md`) for the exact same region: **every single one of
the 9,409 real values matches exactly, zero deviation.** This is an exceptionally strong
independent confirmation of *both* formats at once — two completely different real files, parsed
via two completely different (and independently found/documented) formats, produce byte-identical
real terrain heights.

## Real cross-region linking, confirmed

A real global edge at region `100/100`'s north boundary (`y = 1920`, the region's max real
Y-extent) has `AssocRegionIdFrom = 0x6464` (this region) and `AssocRegionIdTo = 0x6564` (`101 =
0x65`, `100 = 0x64` → region `100/101`, the real north neighbor) — a real, sensible, directly
confirmed cross-region navmesh link, matching this project's own `World3D.gd` region-grid
convention exactly (`dy` increasing north).

## Real, useful data beyond what `.m` already provides

- **Real per-tile `Flags`** (walkability, 96×96 grid — the same real concept as `.m`'s own 16×16
  per-block tile-flag grid, just carried in a different real file for this client build):
  the one real sample checked has **8 of 9,216 tiles genuinely flagged** (non-zero), unlike every
  real `.m` sample this project checked, which had **zero** flagged tiles anywhere. This project's
  `.m`-only tile-flag grid appears to be real but consistently unused in this specific client
  build's terrain files; `.nvm`'s copy is the one that's actually populated.
- **Real per-tile `TextureID`** (indexes `tile2d.ifo`, same real ID space `MapmTerrainBuilder`
  already uses for vertex color — see `TILE2D_FORMAT.md`): the one real sample checked has 13
  distinct real texture IDs, resolving to real, geographically sensible categories for this exact
  region (`"Asia minor"`/`"East Eurpoe"` grass/dust/stone — plausible for a real
  mountainous/frontier zone). Documented as being used for real footstep sounds, not necessarily
  ground rendering, but it's independent, real, per-tile confirmation that the terrain really is
  textured with real variety at runtime, even where this project can't recover the actual texture
  files (see `TILE2D_FORMAT.md`'s "real, but ultimately unusable, near-hit" section).
- **Real cells/edges** — an actual walkable-area graph, useful for future real pathfinding/AI work
  this project hasn't built yet.

## Real ground textures: found (2026-08-23 correction) — see `TILE2D_FORMAT.md`

Checking the *specific* real texture IDs this real `.nvm` sample's `TileMap` actually uses (rather
than an arbitrary early sample of `tile2d.ifo`'s own list) found one real filename match,
`Prim\Mtrl\Nature\asia minor\asiaminor_stone01.ddj` inside `Data.pk2` — but checking *that* further
(see `TILE2D_FORMAT.md`) found it's a complete, separate `.bsr`/`.bms`/`.bmt`/`.ddj` object-prop
asset (a standalone rock-formation model, the same real pipeline as this project's already-placed
trees and grass), not a flat ground texture — a real coincidental name collision, not usable ground
art. That specific finding still stands. What was wrong was the broader conclusion drawn from it at
the time (that real ground textures were absent from this client install entirely): they were
found shortly after, in `Map.pk2`'s real `Tile2D\` folder — an archive this investigation hadn't
checked — and are now wired into `MapmTerrainBuilder.build_full_region_mesh_textured()`. See
`TILE2D_FORMAT.md`'s "Corrected 2026-08-23" section for the full account.

## Implementation

`client/scripts/nvm/nvm_reader.gd` (`NvmReader`) parses the full real structure above,
deterministically (every count is real and self-describing, no resync needed). Full test coverage
with a real byte-exact synthetic fixture, re-verified against the real `nv_6464.nvm` sample.
No renderer/gameplay wiring yet (this is the reader only) — the real, non-zero walkability flags
found above are a concrete, well-scoped next step for anyone adding real collision/pathfinding
refinement beyond the terrain mesh's own already-correct geometric collision.
