# Dungeons (region ids with bit 15)

Round 773. Labels: READ = recovered from the binary (address given); MEASURED = parsed from a
real archive on the render box (names and counts only, nothing reproduced); INFERRED; OURS =
OpenSRO's own choice; OPEN = not settled.

## 1. Which files make a dungeon

### `Dungeon\dungeoninfo.txt` (Data.pk2)

READ `MapLoader::FUN_00426fe0` (client; the server's twin is `MapLoader::FUN_009a8b10`): tab
separated, column 1 the enable flag (a row is read only when it is non-zero), column 2 `iRid`
(asserted `0 <= iRid <= 0x7FFF`), column 3 the quoted `.dof` path. The dungeon's region id is
`iRid | 0x8000`. MEASURED: 32 rows, ids 1..32, all enabled; 0x8001 is the Donwhang cave
(`Dungeon\wchina\Dunhwang_Cv.dof`, 151 blocks), 0x8002..0x8007 the Qin-Shi tomb's floors B6..B1
(`jinsi_floor06..01.dof`), 0x8010 the Job temple. The u16 stored inside a `.dof` is stale (several
files carry another dungeon's) and is not used.

`SWorld::vslot_001` (0x00a178b0, READ): a region id with bit 15 loads that dungeon's `.dof`
through the region manager (slot 0x4c -> the DungeonInfo's path); one dungeon object at a time.
A dungeon has no `.m`, `.o` or `.nvm`.

### The `.dof` ("JMXVDOF 0101")

READ: the renderer's loader `ResourceMgr::FUN_00bebee0` (header `DungeonObj::FUN_00c209a0`,
body `FUN_00c24b90`, each block `RTDunBlock::FUN_00c6f1d0`) and the navmesh's
`RTNavMeshDungeon::FUN_0043e8c0` (each block `FUN_0043d220`, links `FUN_0043dc40`, stitching
`FUN_0043ed30`). MEASURED: this layout walks every one of the 32 referenced files with each
section ending exactly where the next begins (`tools/dof_probe.gd`; the reader refuses a file
that does not).

Header: magic (12 bytes), then eight u32 section pointers P0..P7 -- P0 the blocks (0x74), P1 the
links, P2 a spatial grid, P3 editor groups, P4 the name lists, P5/P6 0, P7 the dungeon's AABB
(0x44: min xyz, max xyz).

P0, per block (room):

| field | notes |
|---|---|
| str mesh path | the room's `.bsr` (`res\dun\...`), an ordinary JMXVRES whose navigation `.bms` is the room's walkable surface |
| str name, u32 | the u32 is 0 everywhere MEASURED |
| vec3 position, f32 yaw | dungeon space; the block transform is a row-vector Y rotation, local (x, z) -> (x cos - z sin + px, x sin + z cos + pz) (READ `FUN_0043d220`) |
| u32 flags | bit 0 an entrance block |
| 6 x f32 | block-local AABB |
| u32 colour (block +0x6c) | the dungeon draw's light: a directional D3D light (type 3) with diffuse and specular 0 and this as its ambient /255 (READ `Map::FUN_00a255c0` via `CRTDunBlock::vslot_006`) |
| u32 colour, 3 x f32 (block +0x70 record) | the fog: D3DRS_FOGCOLOR, FOGSTART, FOGEND, FOGDENSITY and the object shader's fog constants (READ `CObjRendererVS::FUN_00c31450` via `vslot_005`); the landscape step chooses vertex fog LINEAR for a bit-15 region (WorldFog's header, 0xa276fc), so the density is unused |
| u8 + 4 x f32, u8 + 7 x f32 | optional; the first goes to the object renderer with the fog record (`FUN_00c31450`'s `+0x3c` call), meaning OPEN |
| str label, u32 room, u32 floor | indices into P4's lists (-1 none) |
| u32 n + n x u32, twice | the blocks whose linked (0x08) outline edges meet this one's (navmesh +0x108); a superset (+0x118, INFERRED the visible set) |
| u32 objects, u32 obstacles | then per object: str name, str `.bsr`, vec3 position (dungeon space), vec3 Euler rotation, vec3 scale, u32 flags (bit 2: an obstacle cylinder for the navmesh, bit 4: one more u32 follows), u32, f32 radius |
| u32 lights | then per light: str name, 15 x f32 (position first; the rest INFERRED colours and attenuation) |

P1: u32 block count (asserted equal), then a u32-counted list per block. P4: two u32-counted
string lists, the room names and the floor names -- textzonename keys (`DH_A01_FLOOR01` "1F",
`QT_A01_FLOOR02` "B2").

MEASURED (round 773, `dof_probe.gd --stitch`): placing every room's navigation mesh with the
block yaw as read, 724 of 1,154 linked outline edges of B4 meet another room's (870 of 1,106 in B3);
with the yaw negated 394 and 478. The rest are seams split differently on the two sides.

## 2. Positions

A dungeon position is the region id (bit 15) and x, y, z in the `.dof`'s space: absolute,
negative allowed, y a real height (there is no terrain). teleportdata's dungeon points, npcpos's
1,924 dungeon rows (all inside their dungeon's AABB, MEASURED) and objectstring's dungeon rows use
it.

The wire (READ, rounds 737/749; OURS where both OpenSRO sides chose):
- 0x7021: `u16 region` then three i32 when bit 15 is set (three i16 region-local in the field).
- 0xB021's source: `u16 region`, x x10 and z x10 as i32 in a dungeon (u16 in the field), y f32.
  That the dungeon's i32 is also x10 is INFERRED; OpenSRO's server and client both use it.
- 0xB023, the spawn records, the party position: the region and dungeon-space floats.

OURS, OpenSRO's frame: a dungeon is the zone label `dungeon/<rid>` (decimal, `dungeon/32769`),
its FrameRegion the same label, its hub bucket the label itself (never merged under
-single-frame), and a server world point there is `(dx, dy, -dz)` -- the field's one z mirror. The
client draws the dungeon under one group with `scale.z = -1`, so the group's local space is
dungeon space.

## 3. Drawing (client)

`client/scripts/dungeon/`: `DofReader` (the formats above), `DungeonWorld` (the build). World3D
`_load_dungeon` puts each room's `.bsr` at its block transform and each object at its position,
Euler y negated as the field's yaw (INFERRED for objects: their x and z angles are 0 in every file
MEASURED), builds one walkable graph over the rooms' navigation meshes
(`NavGraph.build_dungeon`: an unbounded footprint index, no terrain, and an exit through a room's
outline with no room beyond is a wall -- OURS), hides the sky and sun, and applies the current
block's light and fog. The group is named `RealTerrain_<rid high byte>_<rid low byte>` and its
graph filed under that region key, so the paths keyed by a record's region (NPCs, heights) find
the dungeon.

Minimap (READ `UI_SILKMALL::FUN_00661ce0`): tile column `floor(x / 1920) + 0x80`, row
`floor(z / 1920) + 0x80` of the dungeon-space position, file
`minimap_d\<folder>\<floor>_<column>x<row>.ddj`, no X/Y readout. The floor is the player's block's
floor name lower-cased (INFERRED: the names match the files); the folder's source
(`RegionManagerBody::FUN_00412ef0`, a table at +0xb8) is OPEN and OpenSRO maps rid -> folder from
the six folders Media.pk2 has (OURS).

Not drawn: the rooms' light maps (`Prim\LightMap\Dun`, loader OPEN), the block lights, 64
`lamp.bsr` and 2 `404_sunbeams.bsr` objects of the cave that build no mesh (their material path
is not found), the visible-set culling.

## 4. Walk-in teleports (region events)

READ (SR_GameServer): a TELEPORT event zone is a navigation-mesh trigger -- a cell's (+0x8b) or
edge's (+0x38) extra byte, bits 6-7 the mode (enter / leave), the low 6 bits an index into the
mesh's event names. `eventzonedata.txt`'s TELEPORT rows name a teleportdata point by codename;
`navmesh\objectstring.ifo` (Data.pk2) gives each zone's centre
(`uid 0 rx rz x y z yaw "NAME"`, floats as hex bit patterns, region `(rz << 8) | rx`, a dungeon
row `rz = 128`). `CGObjPC::vslot_309` (0x4ef480): refuse when already teleporting; the point must
have exactly one link; that link's restrictions are evaluated (level, item) with no fee; a
refusal goes on the 0xb05a reply; otherwise the teleport state is set, broadcast (0x30bf kind
0xb), and 0.01 s later the character moves to the link's destination. The client sends nothing:
the walk-in is the server's.

MEASURED: 85 TELEPORT zones, 68 with an objectstring entry; two in the open world --
`GATE_DUNGEON_DH_IN` (0x6A93, level 50+) into the cave and `GATE_JINSI_OUT` (0x66AC, level 70+)
into the tomb -- and 66 inside dungeons (the tomb's floor-to-floor gates, the cave's way out).

OpenSRO (server `internal/teleport/walkin.go`, `session/walkin.go`; the export
`export-refdata -mode teleport ... eventzonedata.txt objectstring.ifo` writes `walkin.csv`):
- OURS: a zone is a circle of radius 15 about the centre (the three trigger squares MEASURED are
  28-32 wide) and, in a dungeon only, a height band of 40; tested along each mover's path every
  mover pass and on each position a client reports; it fires on entering only, so a character that
  arrives standing in one must walk out first.
- OURS: the refusal and the receipt go on OpenSRO's teleport reply (as the NPC teleport's do); no
  0x30bf.

## 5. Server

`internal/worldmap` (`DungeonZone`, `ParseDungeonZone`, `DungeonToWorld`), `session/dungeon.go`:
a teleport serves a dungeon point whose WorldID is the open world's (1): every rid a WorldID-1
link lands in is a served dungeon (on the box's export 0x8001..0x8007). Instanced worlds (the Job
temple, 60; Medusa / Solo / Zealot, 96..170) stay refused. Each served dungeon's entry (OURS) is
the destination of the link from the open field, else the lowest-id point a link lands on: a zone
change into it, /unstuck there and a saved place with no frame land there; GM `/goto dungeon/<rid>`
goes there. Monsters (`-full-map`'s nests) and NPCs of served dungeons are placed at their own y
in the dungeon's bucket; monster AI wanders in x/z at that height (OURS).

The server has no navigation mesh in the field or in a dungeon: a move is bounded by speed and
height as in the field (round 749).
