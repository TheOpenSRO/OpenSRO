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

## Real per-tile record layout, recovered from the client (2026-09-03)

Decompiling the real client's navmesh load path pinned down what a tile record
actually is, and — importantly — what its fields are *for*.

The loader chain is `FUN_00429780` (builds the filename) → `FUN_00403450` (parses
the file). The filename format string is literally `navmesh\nv_%04x.nvm` and is
called as `sprintf_s(buf, 0x400, "navmesh\\nv_%04x.nvm", regionId & 0xffff)`,
which independently confirms the real packing this project uses:
**`(x << 8) | y`** (e.g. real region 98/168 is `nv_62a8.nvm`).

The tile array is read as a single `0x12000`-byte block. That is 9,216 tiles of
**8 bytes each**, matching the real 96x96 grid.

After reading it, the client runs a 96x96 double loop that rewrites every tile:

```
uVar1 = tile.u16 at offset 6;            // the tile's TextureID
tile.u16 at offset 6 = 0;
tile.dword at offset 4 |= tile2d_entry[uVar1].field_0x1c << 16;
```

`tile2d_entry` is a table of 0x20-byte in-memory records — the loaded
`tile2d.ifo` (see `TILE2D_FORMAT.md`). So at runtime the upper half of each
tile's second dword stops being a texture ID and becomes **the ground material
value that texture maps to** (`tile2d.ifo`'s `0x%08X` field: DIRT, SAND, STONE,
WATER, GRASS, and so on).

### What this means for walkability

The per-tile data is a **ground material lookup**, not a collision mask — which
matches the public documentation's note that the TextureID is used for footstep
sounds. It also independently explains a real measured negative result (see
`docs/WORLD_ISSUES.md`'s fifty-ninth round): reading tile flag bit 0 as
"blocked" and correlating it against where real objects stand found no
relationship at all (57.6% of blocked tiles had an object above them versus
49.1% of free tiles in Jangan, and the correlation inverted in 97/167).

Real walkability therefore lives in the **cell/edge graph**, not the tile grid.
Real observed edge flags are narrow: global edges are all flag 8, and internal
edges are only ever flag 2 or flag 4 (Jangan: 259 flag-4, 411 flag-2). Which of
those means "blocking" was not established at the time of that round, and no
collision was built on a guess about it — see the next section, which settles it
from the client's movement code.

## Edge flag semantics: solved (2026-09-05)

**`(m_nFlag & 3) != 0` means the edge blocks movement.** Given the only real
values observed, that resolves to **flag 2 = blocking (a wall), flag 4 =
passable, flag 8 (global) = passable region hand-off**. Established three
independent ways, all agreeing.

### 1. The real in-memory edge layout, from the deserializers

The client's real edge classes are `CRTNavEdge` (base), `CRTNavEdgeInternal`
and `CRTNavEdgeGlobal` — real names, recovered from the client's own RTTI, along
with the real source paths `JMX_Library\navmesh\RTNavEdge.cpp` and
`NavMeshBuilder.cpp`.

Each edge is an outer object holding the real `NavEdge` data sub-object at
`+0x10`. The base deserializer (`FUN_0040f040`) reads, in order:

```
16 bytes -> sub +0x04   the line
 1 byte  -> sub +0x20   Flags
 1 byte  -> sub +0x21   dir 0
 1 byte  -> sub +0x22   dir 1
 2 bytes -> sub +0x24   cell index 0
 2 bytes -> sub +0x26   cell index 1
                        = 23 bytes, exactly the documented InternalEdge size
```

`CRTNavEdgeGlobal`'s deserializer (`FUN_0040efd0`) calls that base, then reads
two more `u16` into `+0x28`/`+0x2a` (the two region IDs) — **27 bytes, exactly
the documented GlobalEdge size**. The Serialize mirrors (`FUN_0040eda0` /
`FUN_0040ed40`) write the identical field set back out. So `Flags` is at sub
`+0x20`, i.e. **`+0x30` in the outer object** — independently confirmed by the
real one-line accessors `GetFlag` (`0x40f570`: `mov al,[ecx+0x30]; ret`) and
`SetFlag` (`0x40f590`: `mov [ecx+0x30],al; ret`).

### 2. The real blocking test in the movement walk

`CRTNavMeshTerrain`'s real collision traversal (`FUN_004047a0`) walks the
movement segment cell by cell. When it reaches an edge it calls two real virtual
predicates on that edge:

```
outer vtable +0x10  ->  0x40f5c0 (internal) / 0x40f500 (global):
                        testb $0x3, 0x30(%ecx)   ; return (Flags & 3) != 0
outer vtable +0x14  ->  IsGlobalEdge()
```

`IsGlobalEdge` is a real compile-time constant per class — `return 0` for
internal (`0x40f1c0`), `return 1` for global (`0x40ed20`) — and its sibling slot
is `IsLocalLinker`, constant the other way round (`1` internal / `0` global).
That pairing is confirmed by the client's own real assertions in
`NavMeshBuilder.cpp`, which require `!pEdgeData->IsLocalLinker()` for the global
edge list and `pEdgeData->IsLocalLinker()` for the internal one.

The real control flow is therefore:

```
on reaching an edge:
    if (Flags & 3)      -> stop / slide along it        (BLOCKING)
    else if IsGlobalEdge -> hand off to the neighbouring region's navmesh
    else                 -> pass through into the adjacent cell
```

The polarity is not a guess. Every real global edge carries flag 8, and
`8 & 3 == 0`, so global edges are never blocking — which is *required*, since
they are the only way to leave a region. Had the mask meant "passable" instead,
every region would be a sealed 1920-unit box.

### 3. Independent confirmation from the real data

Checked against **264 real `.nvm` files** (a separate, already-extracted set from
the server-side files, not the Jangan sample used in earlier rounds); every one
parsed with **zero leftover bytes**, which re-validates this document's format
against real files far beyond the original single sample:

| internal edge flag | count | both cells valid & walkable | one side `0xFFFF` (no cell) |
|---|---:|---:|---:|
| 2 (`&3` set → blocking) | 75,739 | 0 | **75,739** |
| 4 (`&3` clear → passable) | 58,999 | **58,999** | 0 |

All 10,636 real global edges carried flag 8 and none had `&3` set.

The separation is total, with zero counterexamples: **every** flag-2 edge has no
cell on one side — structurally a wall — and **every** flag-4 edge joins two real
walkable cells. This also explains the client's own real assertions
`edge.GetLinkedCellCount() == 1` and `== 2`: the 1-cell case is exactly the
flag-2 wall, the 2-cell case exactly the flag-4 connection.

### What this unblocks

Real edge-graph collision can now be built without guessing: treat an internal
edge as solid when `(flags & 3) != 0`, treat flag-4 internal edges as open
connections between the two cells it names, and treat global edges as the
region-boundary hand-off. No reader change is needed — `NvmReader` already
recovers `flags` and both cell indices.
