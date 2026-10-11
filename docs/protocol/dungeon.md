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
| u32 colour, 3 x f32 (block +0x70 record) | the fog: colour, start, end, density. Set as D3DRS_FOGCOLOR/START/END/DENSITY and as vertex constant c16 (READ `CObjRendererVS::FUN_00c31450`, `vslot_014` 0xbeeb80); in a dungeon only the colour and the density are used (section 3, "Fog") |
| u8 + 4 x f32 (A) | optional: the height fog, c22 = (A0, A1, 1/A2, A3) (READ `vslot_015` 0xbeec30, four floats; A3 <= 0 uploads nothing); centre height, half the fog-free band, the falloff distance, the strength |
| u8 + 7 x f32 (B) | optional: a mode byte, vec3 -> +0x110, vec3 -> +0x120, a u32 period in ms -> +0x11c (2500/3000 MEASURED); mode 2 negates a working vector every period (`FUN_00c67870`); its getter 0xc669e0 has no caller -- consumer OPEN, not light or fog |
| str label, u32 room, u32 floor | indices into P4's lists (-1 none) |
| u32 n + n x u32, twice | the blocks whose linked (0x08) outline edges meet this one's (navmesh +0x108); a superset (+0x118, INFERRED the visible set) |
| u32 objects, u32 obstacles | then per object: str name, str `.bsr`, vec3 position (dungeon space), vec3 Euler rotation, vec3 scale, u32 flags (bit 2: an obstacle cylinder for the navmesh, bit 4: one more u32 follows), u32, f32 radius |
| u32 lights | then per light: str name, 15 x f32 = a D3DLIGHT9 POINT, Range 99999 (READ `RTDunBlock::FUN_00c68640`): position, diffuse, ambient, specular (rgb each), attenuation 0, 1, 2. They light game objects only (section 3) |

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

### Fog (round 774, READ)

`Map::FUN_00a26f60` for a bit-15 region (0xa27722): FOGVERTEXMODE 3, FOGTABLEMODE 0 (no table fog),
and the object renderer's EXP flag (`vslot_030` 0xc41000, +0xec = 1). So D3D takes the vertex
shader's `oFog`, from `Shader\vss0.c` / `vss2.c` (Data.pk2, assembly text): the EXP variant, and
EXP+HEIGHT when the block's A has A3 > 0 (`FUN_00bf05e0`). The shader's `exp` is base 2:

    z    = the vertex's view-space depth (r5 = v0 x c4, World x View; range fog off)
    kept = 2^-((z x density)^2)
    kept = min(kept, 1 - A3 x (|y_world - A0| - A1) / A2)      (with A)
    out  = clamp(kept, 0, 1) x colour + (1 - kept) x fogColour

Start and end are never used in a dungeon, and nothing is scaled. Each room and block object is
fogged with its own block's record (`CRTDunBlock::vslot_007` / `vslot_008` queue a marker object
before the room and before the objects); the characters after a last marker with no A
(0xa25861). The frame is cleared to the current block's fog colour (`CGFXVideo3d::vslot_028` /
`vslot_025` from `Map::FUN_00a255c0`). MEASURED: tomb B1 density 0.00014, A (1000, 830, 135, 0.21)
-- kept 0.987 at depth 1000, 0.712 at 5000, 0.257 at 10000; the cave 0.001-0.0023, no A.

OpenSRO (`WorldFog`, dungeon mode, `set_dungeon_globals`): the same formula in the full-screen
pass, per pixel with the current block's record (OURS: the original evaluates per vertex and
per block; the difference across one triangle is small, the formula being near-linear over a
triangle's span), and the pass paints the empty pixels with the fog colour (the clear).

### Light (round 774, READ)

- **Rooms and block objects.** `Map::FUN_00a255c0` (0xa25637) sets a directional light with
  diffuse 0 and ambient = the block colour /255, so the vertex colour is
  `oD0 = saturate(0.6 x blockColour)` (0.6: `CCompoundObj`'s colour, ObjectLight; its setter's two
  callers are neither rooms nor block objects). A non-light-mapped mesh: `saturate(2 x tex x oD0)`.
- **Light maps.** A `.bms` with flag 0x400 (BMS_FORMAT.md) has 52-byte vertices whose 0x20..0x27 are
  the light map's coordinates, and names its light map after the vertex array
  (`prim\lightmap\...\<mesh>lightingmap.ddj`, DXT1 256 or 128 square, no mips, MEASURED).
  `FUN_00bd2cd0` sends such meshes to `FUN_00bf1250`: stage 0 MODULATE (the 2X flag 0x1000 cleared,
  0xbf14a1), stage 1 MODULATE2X (the object's +0x260 = 5) of the light map, so
  `pixel = saturate(2 x saturate(tex x oD0) x lightmap)`; no material texture: stage 0 is oD0,
  stage 1 MODULATE. This is by the mesh's flag, not the region: 1,133 field building meshes carry
  light maps too (Jangan, Donwhang, Hotan, ...; MEASURED), and they are light-mapped in the field.
  The rooms' warm spots are baked here.
- **Block lights** (the 15-float records): only game objects get one -- each character the nearest
  light of its block, no range test (`vslot_009` 0xc6ac70) -- through the point-light shader term
  `c13 + max(0, N.L) / (a0 + a1 d + a2 d^2) x c14`, c13 = Ambient / 1.67. Not drawn here (OPEN):
  the tomb's attenuations (8-10, 0.008-0.01, 1.5) leave only the ambient tint.
- **Effects.** Every room and object `.bsr` plays its `ambient` particle set (teleport_effects.md):
  the portals (`system\system_dungeonpotal.efp` on the rooms the walk-ins stand in), flames,
  lanterns, crystals, the cave's sunbeams. MEASURED: every one of the served dungeons' objects is
  such a host; the cave's `lamp.bsr` and `404_sunbeams.bsr` have empty mesh and material lists
  (BsrReader reads them since round 774). OURS: the 400 nearest the camera run (the tomb's B2 has
  4,216 effects and lists no visible blocks), stepped as one native batch.

Not drawn: the block lights on characters, the visible-set culling.

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

## 6. The world map (round 775)

The full reading is in [WORLDMAP_FORMAT.md](WORLDMAP_FORMAT.md), "Dungeons on the world map". In
short (READ, sro_client.exe's NIFWorldMap.cpp):
- the field world map draws `worldmap_localinfo.txt`'s signs; two are the dungeon icons
  (`xy_dungeon.ddj`), linking to Dungeonmap rows 2001 (the cave's 1F) and 2005 (the tomb's B1); a
  press and release on one opens that floor (0x623220 -> 0x6217e0);
- a floor is the `Dungeonmap` row's tiles, a floor spinner over the rows sharing its Name column
  (0x6143b0), its caption the zone code's text plus the player's room (0x6145e0), and a world
  button back;
- in a dungeon, M shows the row whose zone code is the region id and whose floor label (`1F`,
  `B2`) is the text of the player's block's floor name (0x614280 -- the P4 floor names above);
  the arrow sits at `(x / 10 + (count_x / 2) * 192 - (maxX - minX)) / upp_x + draw_x`,
  `draw_y - ((0x80 - 92) * 192 + z / 10 - minY) / upp_y` of the `.dof`-space position (0x60f660),
  drawn only on the player's own floor; on a field map it sits at the dungeon's field point from
  `worldmap_instanceinfo.txt` (0x60fa90).
- OpenSRO: `HudWorldmap.update_player_dungeon(region id, DungeonWorld.to_dungeon(position),
  facing, floor key, room key)`, called from World3D's dungeon minimap step.
