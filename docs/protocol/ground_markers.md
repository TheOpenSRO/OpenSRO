# The ring on the ground: click marker and selection circle (round 698)

READ from the decompiled client (`/var/tmp/decomp_client`, `/var/tmp/sro_client.asm` and
`objdump` of `sro_client.exe` on the render box; constants read out of the exe's data) and
from the asset bytes (Media.pk2, Data.pk2, Particles.pk2). Labels: READ, MEASURED, INFERRED,
OURS, OPEN. srrevamp builds it in `client/scripts/world/ground_markers.gd`.

**The click-to-move marker and the selection circle are the same object.** The game process
owns one `CIODecal`; a ground click moves it to the clicked point with the ground texture, a
selection moves it under the selected character with that character's texture. There is only
ever one ring.

## The object (READ)

| What | Where | Detail |
|---|---|---|
| Creation | `switchD_0084c129::FUN_00786f30`, asm 0x7872d7..0x78733c | `FUN_00ba36d0(0x110aab8, 0)` with ecx = the entity manager `[0x110f7d8]`; 0x110aab8 is the class link registered at 0xd77980: name `CIODecal` (0xde610c), CreateObject 0xa63230, size 0x13c. Stored at process+0x640 (`[0x110f80c]+0x640`). |
| Size | +0x104 | Set to **12.0** (float 0xd8ace0) right after creation; the constructor's default is 10.0 (0xd81a88). No other write to the decal's +0x104 exists (every load of process+0x640 in the asm, 54 sites, was read). One size for everything: not scaled by the target's model or rarity. |
| Textures | `FUN_00a633a0(slot, name)`, slots 0..3 | `effect\select_01.ddj`, `select_02`, `select_03`, `select_04` (strings 0xdb90a4 / 0xdb908c / 0xdb9074 / 0xdb905c). Names at +0x10c+4i, texture handles at +0xdc+4i. Loaded once, never changed. |
| State | +0x108 shown, +0x134 slot drawn, +0x138 followed object id, +0x7c region, +0x80 local position, +0x90 world position | |
| Point setter | `FUN_00a631e0(region, pos)` | +0x138 = 0, position = pos, **+0x134 = 0**, +0x108 = 1. |
| Follow setter | `FUN_00a631c0(id)` | +0x138 = id, +0x108 = 1. |
| Per frame | `CIODecal::vslot_009` (0xa630e0) | When following: find the object; if it is gone, or is a CICharactor whose vslot 0x50 returns 0, clear +0x138 and +0x108 (hidden); otherwise copy its region and position. |
| Draw | `CIODecal::vslot_010` (0xa63160) | Only when +0x108 and the slot's texture: `SWorld::vslot_022(texture, &+0x90, size, +0x8c, 0xffffffff, 1, 0)`. |

CICharactor vslot 0x50 (`GlobalDataManager::FUN_009d11c0`, the same for CICMonster) returns 0
when byte +0xbc is 0, or the stealth mode +0x2c2 is 4 (docs/protocol/appear_fade.md: alpha
0x50), or `FUN_009c7580` (bit 2 of +0xd4, or byte +0x758) says hidden, or the same for the
object's rider, or (global 0xeef5f4 set and `FUN_009d0560` returns 0). What +0xbc, 0xeef5f4 and
`FUN_009d0560` mean is not read.

## Which texture (READ)

`FUN_00778650(obj)` (the selection; `0x7786b7`..`0x778718`), `FUN_00b94b90` being IsKindOf
(it walks the class links' +0xc parent chain, `0xb94b40`):

| Selected | Test | Slot | Texture | Alpha-weighted mean colour (MEASURED) |
|---|---|---|---|---|
| a ground click | `FUN_00a631e0` | 0 | `select_01.ddj` | (148, 169, 169): pale grey-cyan |
| CICMonster (0xef1a84) **or** CICCos (0xeef6f0: pets, horses, transports, COS guards) | first two tests | 3 | `select_04.ddj` | (215, 122, 72): orange-red |
| else CICUser (0xef1bc0: other players, any job, any PK state) | third test | 2 | `select_03.ddj` | (101, 136, 203): blue |
| else (NPCs CICNPC, CICGuard, CICATStruct, ...) | | 1 | `select_02.ddj` | (151, 161, 87): yellow-green |

The class tree, from the registration calls at 0xd763fb..0xd767eb (name, parent link):
CICharactor; CICNonuser : CICharactor; CICMonster, CICCos, CICNPC : CICNonuser;
CICGuard : CICNPC; CICUser : CICharactor; CICPlayer : CICUser; CIItem : CIGIDObject.

**There is no hostility test and no rarity test.** The +0x134 writers in the whole asm are five:
the three above (0x7786ed = 2, 0x7786ff = 1, 0x778711 = 3), and the pick mode's two (0x62a0ef = 1,
0x62a104 = 3, below); `FUN_00a631e0` writes 0. So a murderer, a PK, a free-PvP or an
opposite-job player gets the blue ring; a guard (CICGuard) the yellow-green one whether it is
hostile or not; a unique the same orange-red ring as any monster. Hostility drives the
attack cursor (the hover code, `CGInterface::vslot_005`), not this ring.

The four textures (MEASURED, 65,684 bytes each): 20-byte JMXVDDJ header + a DDS of 128 x 128
A8R8G8B8, no mips. A ring band between radius ~28 and ~52 px of the 64 px half-width, a
4-pixel fully transparent cross through the centre (rows and columns 62..65 alpha 0), alpha 0
beyond ~56 px and on every edge texel.

## When it shows and goes (READ)

| Event | Code | Ring |
|---|---|---|
| Ground click | `UI_SILKMALL::FUN_0078f8d0` -> `FUN_009ec570` (0x9ec638..0x9ec64e) | Moves to the click point, slot 0. After the click filter `FUN_009ec240` with **no branch on its result**: a click the filter does not send (under 5 units with no order, or a snapped heading) still moves it. A held button repeats the click (timer 7, 500 ms, `FUN_00777b90`). |
| Sky click (heading run) | `FUN_0078f8d0` -> `FUN_009ebec0` | Not touched there. |
| Arrow-key walk | `FUN_009ebf40` (from `FUN_0077b070`, `FUN_00780610`) -> `FUN_009ebec0` | Not touched there. |
| The local player's 0xB021 with a heading (kind 0) | `NetProcessInNavAndSkill::FUN_008a5750`, 0x8a5971..0x8a59c5 | **Hidden** (+0x108 = +0x138 = 0), and timer 7 killed or set. So arrow walking and sky runs hide the ring one round trip after they start. |
| Arrival at the destination | the mover tick `FUN_009e0e60` | Not touched: the ring stays under the player. |
| Selecting a character | `FUN_00778650` from the object click `FUN_00792f00` (four branches, at once: CICMonster 0x79326d, CICATStruct 0x793305, CICGuard 0x7934be, any CICharactor 0x7938a6) and from the 0xB045 select reply `FUN_0088b200` (0x88b2d0: any CICharactor but yourself) | Follows it, slot by class. |
| Selecting yourself | `FUN_00780ee0` (the portrait, Shift+click) | Writes the selected id +0x628 only: **no ring**. |
| Deselecting | `FUN_00778650(0)` | Clears +0x628 only: **the ring stays** where it is. |
| The followed object despawns | its destructor `GlobalDataManager::FUN_009c2460` deselects; next frame `CIODecal::vslot_009` finds no object | Hidden. |
| The followed object turns stealthy or hidden | `vslot_009`'s vslot 0x50 test | Hidden. The target window's own test (`CIFTargetWindow::vslot_012`, vslot 0x54) deselects then. |
| The followed object dies | | Nothing in the code above: the ring stays on the body until it despawns (INFERRED from the absence of a death test in vslot 0x50 / vslot_009). |
| Leaving a pick mode | `FUN_00779260(0)` and its callers (0x62a55a, 0x62a8bc, 0x797587, 0x79762c, 0x798a4a, `FUN_0078ae00`) | Hidden. |
| GM free camera (process+0x3ce) | `UI_SILKMALL::FUN_0078e0e0` | Hidden every frame. |

## Where and how it is drawn (READ)

`SWorld::vslot_022` (0x9f42d0; the arguments from the caller's pushes at 0xa63181..0xa631b9 and
the prologue's 0x204 bytes):

- **View**: `D3DXMatrixLookAtLH` (0xaa4bad) from (x, y - 1000.0, z) (double 0xd83268) to the
  point, the up vector (0, 0, 1) turned by the rotation argument (`FUN_0043cda0`, the row-vector
  Y rotation); `D3DXMatrixOrthoLH` (0xaa5134) size x size, near 1.0, far 10000.0 (0xd82efc). So
  the texture is projected straight down over a size x size square centred on the point, whatever
  the point's height.
- **Geometry**: `Map::FUN_009f3c10` gathers the TERRAIN height-map cells round the point: the
  cell under it and `trunc(size / 20.0 + 1.0)` cells each way (0xe1b830 = 20.0, 0xe1b7f0 = 1.0)
  -- 3 x 3 cells for size 12 -- each a 4-vertex fan of the cell's own height-map vertices (the
  block's 17 x 17 grid, stride 7 from +6), UV = (projected * 0.5 + 0.5) (0xe1b7d0). The fan's
  first vertex alternates with the cell's parity (`(x & 1) == (z & 1)`): diagonal (x, z)-(x+1,
  z+1) on even cells, (x+1, z)-(x, z+1) on odd. Placed objects get nothing: on a bridge or a
  floor the ring is on the ground under it. With no height-map block at the point
  (`FUN_009ef640` fails -- INFERRED: a dungeon) nothing is drawn.
- **Still water**: when the block under the point has PlaneType (+0x7ed) 1 and a non-zero WaveID
  (+0x7ee) -- the still surface `MapmWater` draws -- a flat size x size quad is also drawn at the
  point's height, translated up 0.1 (float 0xe1b7fc, `D3DXMatrixTranslation`, 0xaa42c8), UV 0..1.
- **States**: TEXTUREFACTOR = 0xffffffff; stage 0 colour and alpha MODULATE(TEXTURE, TFACTOR):
  the texture as authored, unlit; ALPHABLENDENABLE, SRCBLEND SRCALPHA, DESTBLEND INVSRCALPHA;
  FVF 0x142 (XYZ | DIFFUSE | TEX1); sampler ADDRESSU / ADDRESSV CLAMP (3); afterwards ZFUNC
  LESSEQUAL and blending off. Fog and depth writes are not touched (whatever the world set).
- **Rotation**: the decal's own heading +0x8c, which no decal path writes (INFERRED 0): the
  cross lies along the region axes. Nothing animates the ring.

## The pick mode's use of the same decal (READ, not built)

`UI_SILKMALL::FUN_00629fa0`, for process modes (+0x7ec) 1 and 4: the decal goes to the picked
point (`FUN_00a631e0`), then +0x134 = 1 (`select_02`) when the squared distance is within
(R - 5)^2 and 3 (`select_04`) beyond, R = `[FUN_008ba440()+0x254]`; hidden when the pick fails or
the distance is under 0.25 (0xd9a2b8). What modes 1 and 4 are, and R, are not read (OPEN): the
natural reading is a ground-target skill's or item's cursor, which round 617 drew with the
system cross (`World3D._begin_ground_pick_cursor`).

## The unique's arrow (probed twice, not found)

The user remembered "a purple circle and a red arrow that points down" on uniques.

- **Code**: the ring's texture is chosen by class only (above). The monster spawn reader
  `CICMonster::vslot_025` (0x9d3850) uses the rarity's low nibble (+0x7ac) only to scale the
  model: rarity 1 x1.5 (0xd819ec), 4 x3.0 (0xd8adc4), 6 x1.7 (0xde2818), the rest x1.0, times
  the ref's Scale / 100. The one marker it attaches is `SYSTEM_QUEST_MARK` (id 0x8000001f,
  0x9d3a70), when the ref's (`CCharacterData::FUN_00971210`) +0x28c is non-zero. INFERRED to be
  characterdata column 102: CCharacterData's parser `FUN_00971450` reads 47 columns after the
  common part, +0x1c8 first and the last ten into +0x26c..+0x290, and 57 + 47 = 104 is the
  rows' column count before the trailing empty one (the column order itself is READ; the
  57-column common part is counted, not read). MEASURED: column 102 is 0 on all 17,868 rows of
  the box's characterdata. No runtime writer of a CCharacterData's +0x28c was found (the asm's
  other +0x28c writes sit in other classes' code); not proven absent. That effect is `res\etc\system_questmonster_mark.bsr` ->
  `system\system_questmonster_mark.efp`: a billboard of `quest_monster_paper_q_1.ddj`, a parchment
  "Q" -- not an arrow.
- **Assets**: Media.pk2's `effect\` holds four select textures and nothing purple. Every .efp,
  .bsr and .txt in Particles.pk2 scanned for `point-arrow`, `arrow_glow`, `arrow_waypoint`,
  `quest_monster`, `select_0`, `unique`: the arrow meshes are used only by skill hits
  (`skill_hunting_point_a.efp`, the cold bolt, ...) and the tutorial's `tuto_arrow_waypoint.efp`.
- What uniques do get: the minimap's `mm_sign_unique.ddj`, the target window's
  `tw_icon_unique.ddj`, and the spawn notice.

So in this client a unique has the same orange-red ring as any monster, and no arrow. A
private server's patched client may differ; that would be a different binary.

## What srrevamp builds (round 698)

`GroundMarkers` (one node, `World3D._markers()`): `place_at` on every ground pick that hits
(`_move_by_pick_ray`, before the click filter), `attach` from the monster clicks (`_ring_on_monster`, not `_show_target`, which a cast at the selection also calls -- retail's casts do not reselect),
`_select_character` (players) and `_try_talk_to_npc` (NPCs; a gate gets none),
`heading_move` from `_start_heading_run`, `hide_marker` on a zone change, `step` once a physics
frame (follow or hide). The drape is the 3 x 3 cells of the region's own heights, the
projected UV, `select_0N.ddj` through DdjReader, unshaded alpha blend, clamp.

OURS, each said in the code: the drape is lifted 0.05 (different transforms could z-fight on
equal heights); it splits cells the way OUR terrain mesh does (always (r, c)-(r+1, c+1)), not
retail's alternating fans, so it lies on what is drawn; the heading-move hide happens when the
run starts (this client streams positions and gets no 0xB021 echo); culling off.
