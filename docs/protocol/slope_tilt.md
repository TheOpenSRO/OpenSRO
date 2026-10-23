# Slope tilt: who leans with the ground, and how (round 813)

The original leans monsters and COS (pets, horses, transports) with the ground they stand on and keeps
players, NPCs and guards upright; a rider sits on its mount's saddle, so it leans with the mount. OpenSRO:
`client/scripts/world/slope_tilt.gd` (SlopeTilt), `NavGraph.ground_normal_at`,
`NvmCollision.terrain_normal`, `NpcTableReader.parse_slope_tilt`, World3D's "slope tilt" section.

Labels: **READ** = from `sro_client.exe` (decompile `/var/tmp/decomp_client`, asm `/var/tmp/sro_client.asm`
on the render box); **MEASURED** = counted in the user's archives; **INFERRED**; **OURS**; **OPEN**.

## Who (READ)

- Every CICharactor's constructor (`CICharactor::FUN_009d2ad0`, asm 0x9d2cb6..0x9d2d64) sets up two
  eases: the normal at `+0x2e8` (a 16-float lerp: current, from, to, delta, done, t, duration 0.3 from
  0xd82f00, speed 1/0.3; `FUN_009c96c0`) starting at (0, 1, 0), and a factor pair at `+0x328` (current,
  from, to, delta, done, t, duration 0.1 at 0xe1b7fc, speed 10.0 at 0xd81a88) snapped to (0, 0)
  (`FUN_009c8e50`). The "enabled" byte `+0x2e4` is 0.
- The appear, `GlobalDataManager::FUN_009d17e0` (CICharactor slot 27; CICMonster's `vslot_025` 0x9d3850
  does the same), runs only for an object that **IsKindOf** (`FUN_00b94b90`, the parent chain at
  descriptor `+0xc`) CICMonster (descriptor 0xef1a84) or CICCos (0xeef6f0):
  - `+0x74c` = the row's common block `+0x204`, which the characterdata parser (`FUN_00971450`) files at
    record `+0x20c`: **column 80** (the word after ExpToGive, col 79 at `+0x208`);
  - `FUN_009c78f0` fills a table at `+0x358` from its bytes, each / 100.0 (0xe1b7d8): pair 0 =
    (byte 3, byte 2), pair 1 = (byte 1, byte 0);
  - `FUN_009c9350(0)` eases the factors from where they are to pair 0. No caller passes another index
    (the two callers, 0x9d17e0 and 0x9d3850, both push 0).
- The classes (the object factory 0x9c2030 by TypeID, and the descriptors' static initialisers):
  1/2/1 is CICMonster, 1/2/1/5 CICMonsterNPC (parent CICMonster, `0xd65650`): both tilt; 1/2/3 is
  CICCos: tilts; 1/2/2 CICNPC, 1/2/4 CICGuard (parent CICNPC, `0xd76410`), 1/1 CICPlayer and the rest
  never reach it, so `+0x74c` stays 0 and nothing ever tilts them.

MEASURED (Media.pk2 characterdata, service rows, last definition of an id):

| TypeID | rows | column 80 |
|---|--:|---|
| 1/2/1 monsters | 7,604 | 0x14141414 (0.2, 0.2) 6,403; 0 (never tilts) 621; 0x64646464 (1.0, 1.0) 412 (ghosts); 0x000041cb 86 (towers: pair 0 is (0, 0)); 0x64146414 (1.0, 0.2) 82 (tigers, demon horses) |
| 1/2/3 COS | 7,272 | 0x64146414 (1.0, 0.2) every horse, pet and transport; 0x14141414 the 2,100 guild soldiers; six quest COS mixed |
| 1/2/2, 1/2/4, 1/1 | | carry values (0x14141414 on players and NPCs) the client never reads for them |

## When (READ)

- Slot 15's events: the position setter (`FUN_009c4610`) sends 2, the heading setter (`FUN_009c4260`, the
  angle at `+0x8c`) sends 3; CICharactor's slot 15 (`0x9cf1b0`, jump table 0x9cf260) marks the normal
  stale (`+0x750` = 1) for both while `+0x74c` is not 0 (0x9cf23c..0x9cf245); for 3 it also turns the
  object's ride (0x9cf222).
- The update (`GlobalDataManager::FUN_009d1d60`, CICharactor slot 9): if stale and the character has a
  cell (`+0x74`), it clears the mark and asks for the normal -- straight up (0xee5c54) when the region id
  at `+0x7c` has bit 0x8000 (a dungeon), else the cell's slot 4 with the position -- then
  `FUN_009c93e0` sets `+0x2e4` and restarts the normal's ease from where it is (`FUN_009c8ac0`).
  While a character moves, every frame restarts it: an exponential approach, 1/0.3 per second.
- `FUN_009c9400` then advances both eases by the frame's time and, only on a frame either moved, writes
  the matrix.

## The normal (READ)

- **Terrain** (`CRTNavCellQuad::vslot_004` -> `RTNavMeshTerrain::FUN_00403980`): the 20-unit tile
  (`_ftol` of x/20, z/20; 20.0 at 0xe1b830). If the tile's 6x6 PlaneTypeMap block has bit 2 and the
  character's y **equals** the block's PlaneHeight (`fucompp` 0x403a4b), straight up. Otherwise the
  face normal of the tile's triangle under the point, the tile split on its (x0,z0)-(x1,z1) diagonal:
  z fraction below x fraction -> (20(h00 - h10), 400, -20(h11 - h10)); else (-20(h11 - h01), 400,
  20(h00 - h01)); normalised. Not the bilinear surface the height query uses.
- **An object's cell** (`CRTNavCellTri::vslot_004` 0x45dee0): the triangle's face normal,
  (v1 - v0) x (v2 - v0) over its vertices in file order (`FUN_0045c420`), normalised, turned by the
  object's matrix. **Never flipped.** MEASURED: 646 of the export's 78,483 object cells (28 meshes; 12
  of them wound downward on every cell, e.g. types 3176, 3188, 3227, 3228, 3241, 3242, 3247, 3248, all
  placed in field regions) give a downward normal, which turns a character standing on one over about
  its front. OpenSRO does the same (OPEN: never seen in the original; whether anything stands there).

## The matrix (READ, `FUN_009c9400`)

With D the flat heading (-sin, 0, cos) of `+0x8c` and n the eased normal: side = n x D, forward =
side x n; forward.y x factor 0, side.y x factor 1; both normalised; up = forward x side, normalised.
Rows (side, up, forward) replace the model's rotation (its render object's slot 6 matrix); the
translation stays. Factor 0 pitches, factor 1 rolls; because they scale differently the rows are not
quite orthogonal, and the original writes them as they are.

- Facing up a slope of angle a, factor k pitches atan(k tan a); across it, rolls atan(k tan a).
- A seated rider: `ICharactor::FUN_009d05d0` runs after `FUN_009c9400` in the same update and sets the
  rider's matrix from its mount's saddle bone x the mount's matrix: a rider leans with its mount, and
  a monster seated on its own ride (Ride Type none) does not lean on its own.
- RT_DUMMY rides copy their rider's matrix (`FUN_009d0660`), so they lean with it.
- The die model keeps the lean: the dead state (0xa59cc0) saves the matrix, swaps the model
  (`FUN_009c4ec0`), and restores it.

## OpenSRO

- `NpcTableReader.parse_slope_tilt` keeps column 80 by code for 1/2/1 and 1/2/3 rows, non-zero only.
- A monster's or COS's body registers with its value at its build (`_slope_tilt_register`) and carries
  `SlopeTiltBody`: Godot's transform-changed notification files a moved or turned body in a hot set,
  the original's slot-15 events. `_step_slope_tilts` looks only at hot bodies and at bodies still
  easing (ridden mounts in `_cos_place_riders`, before the rider is seated); a standing body whose
  eases ended costs nothing. MEASURED: a first version that looked at every body every frame cost
  14 ms a frame with the perf gate's 2,500 standing monsters (3.02 -> 17.03 ms).
- A hot body whose position or model axis changed is stale. It asks `NavGraph.ground_normal_at` in
  the region's own (un-mirrored) frame (its region looked up once, kept while it stays in it) and
  eases as above.
- The matrix is built in that frame (`SlopeTilt.frame`/`tilt`) and conjugated into the scene through
  the terrain group's basis (mirrored on z). It is applied to the model node under the body about the
  feet, so the body's own yaw, used everywhere else, is untouched.
- OURS: our bodies carry no cell. The surface is the terrain or the object cell whose height is
  nearest the body's y (terrain on a tie), and "y equals the plane" is taken within 0.001.

MEASURED (round 813, the render box, a live server):
- The client's normals equal an independent Go computation from the heightmap at three points (e.g.
  (0.0584, 0.7779, -0.6257), 38.9 deg).
- A ridden pegasus leaned 11.43 deg up an 11.4 deg slope and 5.04 deg across a 12.9 deg one.
- Black tigers leaned 9.25 deg on 9.3 deg facing up it. A (0.2, 0.2) monster leaned 1.80 deg on
  8.9 deg, where atan(0.2 tan 8.9) is 1.79.
