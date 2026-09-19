# How the client moves a character on its navigation meshes

Recovered 2026-09-19 from `sro_client.exe`'s own code (the decompiled dump on the render box,
`/var/tmp/decomp_client`, plus `objdump` where the decompiler dropped a register), and measured
against every object navigation mesh the object index names. This is the rule
`client/scripts/nav/nav_graph.gd` implements; the formats themselves are in
[NVM_FORMAT.md](NVM_FORMAT.md) (terrain) and [BMS_FORMAT.md](BMS_FORMAT.md) (objects).

## The functions

| Address | Name (RTTI / this project's) | Role |
|---|---|---|
| `0x4047a0` | `CRTNavMeshTerrain::vslot_002` | The move. Walks the terrain cell by cell; for the cell's object instances runs the per-instance test; if the mover is on an object, runs only that object's walk (or the terrain's too — see the "event" byte). |
| `0x404060` | `RTNavMeshTerrain::FUN_00404060` | Per-instance test: transforms the move into the instance's local frame (`+0x60..+0x98`, the inverse world matrix), calls the object navmesh's `vslot_002`, transforms back, and handles the flags it returns (bit 4 = now on this instance; bit 2 = a linked edge, resolved through the instance's link list at `+0xa0`). |
| `0x44b500` | `CRTNavMeshObj::vslot_002` | Dispatch: if the mover's current cell belongs to this object → the in-object walk; else → the entry test. |
| `0x44a790` | `RTNavMeshObj::FUN_0044a790` | **Entry test** for a mover not on the object. |
| `0x44add0` | `CRTNavMeshObj::FUN_0044add0` | **In-object walk**, recursive cell to cell. |
| `0x4489b0` | the object navmesh deserializer | Reads the `.bms` collision section into runtime cells (0x8c bytes) and edges (0x3c bytes); the edge's file flag byte is stored as-is at edge `+0`. |
| `0x45db20` | edge cell accessor | `GetCell(0)` = `cell_from` (`+0xc`), `GetCell(1)` = `cell_to` (`+0x10`). |

The position the walk carries is `{cell*, instance*, u16 region, x, y, z}`: the character is
**always either on the terrain (`instance == 0`) or on exactly one object instance**, and the
client remembers which. Nothing is inferred from height.

## The entry test (mover on the terrain, `0x44a790`)

For every outline edge in the object's lookup grid along the move, **skipping edges whose flag
has bit 4 (`0x10`) set**, find the nearest crossing (a plain 2D segment test, `0x447b30`). At
that edge:

```
if (flags & 0x80)  result |= 0x80  (+0x100 if the object's +0x98 has bit 3); the hit point is
                                    recorded in a global -- not a movement effect
if (flags & 0x20)  result |= 0x08
if (flags & 0x01 && collide_mode)   -> BLOCKED: position = the crossing pushed 0.01 along the
                                       edge normal; result |= 1; stay on the terrain cell
else                                -> ENTER: position = the crossing; result |= 4;
                                       the object's cell becomes the current cell
```

There is **no height test anywhere in it**. A character steps onto an object at whatever height
its cell has. Walking *under* something is expressed by the `0x10` flag, not by geometry.

## The in-object walk (mover on the object, `0x44add0`)

From the current cell, test the move against the cell's three edges (minus the one just
crossed). At the first crossed edge, with `bVar5 = flags`:

```
event gates:     the wide-record extra byte of the edge (+0x38) and of the cells (+0x8b) is
                 checked against the region's event state when its 0xc0 bits are set
                 (0x44a720) -- fortress gates, dungeon doors; can return BLOCKED
if (bVar5 & 0x80) / (bVar5 & 0x20)  -> as above
if (bVar5 & 0x04)  INTERNAL edge:
    if (bVar5 & 0x02) and GetCell(0) == current   -> BLOCKED   (value 2: blocks the cell_from side)
    if (bVar5 & 0x01) and GetCell(1) == current   -> BLOCKED   (value 1: blocks the cell_to side)
    else                                          -> recurse into the neighbouring cell
else               OUTLINE edge:
    if (bVar5 & 0x08)  result |= 2 and the edge's index is looked up in the object's link
                       list (a linked edge -- the mover hands over to the linked object)
    if (collide_mode && (bVar5 & 0x12))           -> BLOCKED   (value 2, or 0x10: no exit here)
    else                                          -> EXIT: result |= 0x10, position = the
                                                     crossing pushed 0.01 out; back on the terrain
```

The two `GetCell` selectors were read off the disassembly (`44b1d5: xor eax,eax` before the
first `call 0x45db20`, `44b1f3: mov eax,1` before the second); the decompiler had dropped them.

**Only the object's own edges are tested while on it.** `vslot_002` at `0x404c71` reads one byte
of the object navmesh, `+0x94`: when it is 0 the move calls the per-instance test for the current
instance alone; when it is 1 it first runs the whole terrain walk with the current instance
excluded (so the terrain's walls and every other object still apply), then the instance's own.
The deserializer sets that byte to 1 at `0x449395`/`0x4495d9` when the collision section's event
list holds a five-character name equal to `"event"` (`0xe14e04`) or `"EVENT"` (`0xe14e0c`) —
exactly those two spellings.

Constants read from `.rdata`: the push distance is the double `0.01` at `0x00e1b820`; the
region span `1920.0` (double) at `0x00e1b800`; the double `1.0` at `0x00e1b7f0` and a float
`1.0` at `0x00e1b7f8` (a same-instance-across-regions distance check, `|Δpos|² > 1` → refuse).

## What the flags mean, then

| bit | value | meaning |
|---:|---:|---|
| 0 | `0x01` | blocks a mover on the edge's `cell_to` side (for an outline edge: from outside — the wall as seen by someone walking in) |
| 1 | `0x02` | blocks a mover on the edge's `cell_from` side (from inside — the wall as seen from the object) |
| 2 | `0x04` | internal edge: joins two cells of the same object |
| 3 | `0x08` | linked edge: stitched to another object's edge (`MapObject.linked_edges` in the `.nvm`) |
| 4 | `0x10` | ignored by a mover who is not on the object; a wall for one who is — the underpass flag |
| 5 | `0x20` | reported upward as result bit 3; no movement effect found |
| 7 | `0x80` | reported upward as result bit 7 and the hit point recorded; no movement effect found |

So `(flags & 3) != 0`, the test [NVM_FORMAT.md](NVM_FORMAT.md) recovered for the terrain, is
"blocked from at least one side"; on object meshes the two bits are used separately.

## Measured over the whole object index

`client/tools/sweep_object_edge_flags.gd`, run against the real `Data.pk2`/`Map.pk2` on
2026-09-19: 2,858 objects, 2,043 with a navigation mesh.

| outline edges (62,120) | | | internal edges (90,018) | | |
|---|---:|---:|---|---:|---:|
| `0x00` open — a doorway | 3,320 | 5.3% | `0x04` open | 84,805 | 94.2% |
| `0x01` | 76 | 0.1% | `0x05` one-way | 13 | |
| `0x03` wall both ways | 50,401 | 81.1% | `0x06` one-way | 12 | |
| `0x08` linked | 242 | 0.4% | `0x07` wall between two cells | 3,402 | 3.8% |
| `0x10` underpass | 553 | 0.9% | `0x14` | 214 | 0.2% |
| `0x18` | 8 | | `0x84` | 60 | 0.1% |
| `0x80` | 296 | 0.5% | `0x86` | 1 | |
| `0x83` wall | 7,168 | 11.5% | `0x87` wall | 1,511 | 1.7% |
| `0x88` | 2 | | | | |
| `0x90` | 54 | 0.1% | | | |

484 objects have at least one open outline edge (can be walked onto); 1,559 are sealed. The
shapes are what the rule predicts: Jangan's shops have one to three doorways against dozens of
walls (`cj_weapon.bsr` 3 open / 31 wall, `cj_armo.bsr` 1 / 44, `cj_luxury.bsr` 2 / 23), the
palace interior ten (`cj_pal_indoor.bsr` 10 / 56), the palace stairs two each (foot and head),
the bamboo trees six open and no walls (a patch you walk over), and the city walls carry the
underpass flag exactly where their walkway crosses a gate (`cj_s.bsr` 121 walls, 21 `0x10`;
`cj_w.bsr` 202 / 26; `cj_e.bsr` 233 / 16).

The `"event"`/`"EVENT"` marker is on 59 objects, all fortress-war structures, dungeon doors and
arena start pads (`barricade_*`, `fort_gate`, `guard_tower`, `togui_door0*`, `colosseum_start0*`,
`bagh_masin_*_door`) — dynamic structures dropped onto the terrain, where the terrain's own walls
must keep applying. No static town object carries it. The 115 objects that name any event at all
otherwise name fortress structure positions (`structure_pos_ja_defensive_01_r0`) and gates
(`gate_jinsi_out`), which the `0xc0`-bit event gates above refer to.

## Confirmed by walking real Jangan

`client/tools/walk_probe.gd` builds region 97/168's graph from the real files and walks it,
printing every doorway and wall (headless, ~10 s a run). Against the weapon shop
(object 33, `cj_weapon`):

- from the terrain north of it, heading south: **onto** the shop through its open north edge at
  z = 1542, across its floor at y 4.6–4.7, **off** through its open south edge at z = 1404, back
  on the terrain, no wall met;
- on its floor heading east: wall at x = 57.3 (its east wall, flag 3), stopped;
- from the terrain east of its walled yard, heading west: wall at x = 220, stopped **on the
  terrain**. This is the case the old height-inferred rule got wrong — the yard floor sits within
  reach, so it lifted the character through the wall onto it, and the yard's walls then held them.

## What is not implemented

- Linked edges (`0x08`) are not followed through the `.nvm` link table; the mover exits the one
  span and the neighbouring span's own coincident edge (also `0x08`, so enterable) takes it,
  with a same-height hand-off covering the exactly-coincident case.
- The event gates (`0xc0` bits of the wide-record byte) are not read; no fortress or dungeon
  door is dynamic here yet. `BmsReader` still discards that byte as padding.
- A terrain mover already inside an outline (a teleport, a gap in an outline) is let back out
  through a wall; the client's entry test has no notion of sides and would refuse. A disclosed
  choice against traps in states the game itself cannot reach.
