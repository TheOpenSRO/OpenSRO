## World lane: the measured pass, and the building trap closed at its cause

Directive: a measured correctness pass over the world — count the faults per region, fix the
systemic ones at their rule, never per object, verify by trace. Run 2026-09-19 on the render box
against the real archives; every number below is from a log, none from a picture.

### 1. The sweep (before)

One boot per zone, radius 1 (nine regions each), `SRREVAMP_QA_FLOAT=400 SRREVAMP_QA_NAVGAP=1`,
`/var/tmp/world_sweep2.sh`:

| zone | regions | archive misses | floats > 12 within 400 | duplicate placements dropped (centre region) |
|---|---|---:|---:|---|
| Jangan town 97/168 @ 1002,1020 | 9 | 2 | 0 | 146 of 544 |
| Jangan palace 98/168 @ 960,830 | 9 | 2 | 0 | 113 of 389 |
| Jangan farmland 96/168 @ 130,360 | 9 | 2 | 0 | 125 of 265 |
| Alexandria 90/48 @ 663,526 | 9 | 0 | 0 | 16 of 106 |
| Hotan 92/135 @ 960,960 | 9 | 0 | 0 | 106 of 405 |
| Constantinople 104/80 @ 960,960 | 9 | 0 | 0 | 208 of 414 |
| Samarkand 106/107 @ 960,960 | 9 | 0 | 0 | 6 of 69 |

- **Misses**: the same two paths in every Jangan-cluster boot, both placed by region 97/169:
  `res\bldg\china\dunhuang\buildings\w_cd_stab_buil03_wal.bsr` and
  `res\artifact\guild\constantinople\fortress_ct_fort_in_gate01.bsr`. Checked with `pk2list`:
  neither `.bsr` exists anywhere in this `Data.pk2` under any folder or case (only their `.bms`
  pieces and lightmaps do). Per-asset gaps in the archive, not a folder or case rule; no fix.
- **Floats**: none at threshold 12 in any zone.
- **Duplicates dropped**: the `.o`/`.o2` exact-repeat merge of round 75, behaving as measured
  then. Not a fault.
- **NAVGAP** is a point probe (AABBs of what is drawn against what the graph offers at one spot)
  and cannot count trap sites; it confirmed the spawn stands on the gate object with two
  offered surfaces (−46.4 terrain, −32.6 deck). The trap needed a different measurement.

### 2. Why a player gets stuck in a building — the actual rule, from the binary

Round 162 diagnosed the Alexandria trap as physics (object trimesh colliders on layer 1 against
the player's mask 17). That is not the live path: with a graph loaded the player moves on
`NavGraph.step` and `move_and_slide` never runs. The trap was in the graph's own rule, and the
real rule was recoverable — the client's navmesh walk is in the decompiled dump. Read this
session: `CRTNavMeshTerrain::vslot_002` (0x4047a0), `RTNavMeshTerrain::FUN_00404060`,
`CRTNavMeshObj::vslot_002` (0x44b500), the entry test `RTNavMeshObj::FUN_0044a790`, the
in-object walk `CRTNavMeshObj::FUN_0044add0`, the deserializer at 0x4489b0, the `GetCell`
selectors off `objdump` (the decompiler dropped them), and the constants off `.rdata`. Written
up in `docs/protocol/NAVMESH_MOVEMENT.md`; the short form:

- A character is either on the terrain or on exactly **one** object, and the client remembers
  which. Nothing is inferred from height.
- From the terrain, an object is entered only by crossing one of its **outline edges with bit 0
  clear** (a doorway — 5.3% of all outline edges, one to three per shop). Bit 0 set is a wall,
  whatever height the floor behind it has. Edges with `0x10` are not tested at all from outside
  (the arch under a city wall).
- On an object only **that object's** edges apply: internal edges directionally (value 1 blocks
  the `cell_to` side, value 2 the `cell_from` side), outline edges as exits (value 2 or `0x10`
  refuse). The terrain's walls and other objects' do not apply — unless the object's collision
  section names an event `"event"`/`"EVENT"` (byte `+0x94`, set at 0x449395/0x4495d9, read at
  0x404c71); those are 59 fortress/dungeon/arena structures, no town object.
- Push 0.01 past a crossed edge and short of a wall (double at 0x00e1b820); slide along walls.

Our rule inferred footing from height: any surface within 12 units up was "the ground", and an
object's walls applied only to someone already on it. So a terrain mover walking at a shop whose
floor sits 5 units up was let through the wall (walls untested for terrain movers), lifted onto
the floor (within reach), and then held by the same walls from inside. That is the Alexandria
shape exactly (terrain 863, floor 868.5), and it is what the weapon shop's walled back yard does
to anyone approaching from the east.

Whole-index measurement (`client/tools/sweep_object_edge_flags.gd`, 2,043 object navmeshes,
62,120 outline + 90,018 internal edges): outline 81.1% flag 3, 11.5% `0x83`, 5.3% flag 0, 0.9%
`0x10`, 0.4% `0x08`; internal 94.2% flag 4, 3.8% flag 7, 25 genuinely one-way. 484 objects
enterable, 1,559 sealed. `cj_weapon` 3 doorways / 31 walls, `cj_armo` 1 / 44, `cj_pal_indoor`
10 / 56, `cj_pal_center_stair` 2 / 6, `cj_s` (city wall) 121 walls + 21 underpass edges.

### 3. The fix

`client/scripts/nav/nav_graph.gd` now walks the move edge by edge with a tracked footing
(`step_tracked(from, motion, standing_on) -> StepResult`): enter through open outline edges,
exit through them, block and slide on walls, directional internal edges, `0x10`, the
`"event"` marker, the 0.01 push, a same-height hand-off across coincident edges (stair head
onto a deck, bridge span to span). `PlacedObject` keeps every edge with its flags, list and
from-side; `surface_at`/`landing_height_at` are unchanged and now only settle footing after a
teleport, a region change or a landing. `World3D._move_on_nav_graph` carries the footing from
frame to frame and re-settles it only when something else moved the player (> 1 unit) or the
graph changed; `QA_WALK`/`SRREVAMP_QA_NAVTRACE` print every doorway, exit and wall as `NAV`
lines, and the QA position line reports the tracked footing.

One disclosed deviation: a terrain mover already inside an outline (after a teleport, or through
a gap) is let out through a wall; the client's entry test has no notion of sides. Chosen against
traps in states the game cannot reach.

Unit tests (`nav_graph_test.gd`, 55 checks, ALL PASS on the box): ramp climb and descent with
tracked footing, wall from both sides, doorway both ways at a 5.5-unit floor, another object's
wall not applying / applying with the event marker, terrain walls not applying on an object,
`0x10` under and on, one-way internal edges, the coincident-edge hand-off, landing on the 13.8
deck. Whole client: `remote_godot.sh check` ALL LOAD.

### 4. Verification by trace, real data

`client/tools/walk_probe.gd` (new, headless, ~10 s): builds a region's real graph and walks it,
printing footing, doorways and walls. Jangan 97/168, weapon shop (object 33):

| walk | result |
|---|---|
| terrain north of the shop, heading local −z | **onto** at z 1542.0 (open edge 9), floor y 4.6–4.7, **off** at z 1404.0 (open edge 10), terrain, no wall |
| on the floor, heading +x | wall at x 57.3 (east wall, flag 3), stopped on the shop |
| terrain east of the walled yard, heading −x | wall at x 220.0, stopped **on the terrain** — the trap case: the old rule lifted the mover into the yard |

Live client (`qa_shot.sh --walk`, NAV lines): from local 240,1470 heading world 270 the player
stopped at 220.0,1470 `on terrain` (yard wall); after the spawn roof-escape relocated a start
onto the shop floor, walking north followed the floor's own cells down from y 4.6 to −0.9 and
stopped at the wall at 47.4,1542.1 `on object cj_weapon`. World heading 270 is local −x and
world 180 is local +z (mirrored z), for anyone aiming a walk from `walk_probe` output.

### 5. Left as found

- `_avoid_spawning_under_roof` still relocates a spawn by render-mesh ceilings and terrain
  rays; twice in these runs it moved a QA start 45–60 units, once onto a shop floor. It does not
  consult the graph. Worth a look, since it can place a player where walking could not.
- Object render-mesh colliders stay on layer 1 (camera, clicks); the player does not use them
  while a graph covers them, so round 162's deferred re-layering is moot rather than done.
- Linked edges (`0x08`) are not followed through the `.nvm` link table; the event gates
  (`0xc0` bits of the wide-record byte) are not read. Both are documented, neither is in a town.
- Lighting: not touched. Round 136's `light()` scaling of sun by diffuse/ambient needs the
  material colours read per object (BMT_FORMAT.md has the layout); no measurement was taken this
  round, so nothing was written.

Proposed tag: `v0.1.3xx — Buildings hold: the client's own navmesh walk (doorways, walls,
underpasses) replaces height-guessed footing; NAV traces; edge-flag survey and walk probe tools.`
