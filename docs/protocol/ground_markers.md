# The ring on the ground: click marker and selection circle (round 698)

READ from the decompiled client (`/var/tmp/decomp_client`, `/var/tmp/sro_client.asm` and
`objdump` of `sro_client.exe` on the render box; constants read out of the exe's data) and
from the asset bytes (Media.pk2, Data.pk2, Particles.pk2). Labels: READ, MEASURED, INFERRED,
OURS, OPEN. OpenSRO builds it in `client/scripts/world/ground_markers.gd`.

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
| Ground click | `UI_SILKMALL::FUN_0078f8d0` -> `FUN_009ec570` (0x9ec638..0x9ec64e) | Moves to the click point, slot 0. Past the NPC test (next row), after the click filter `FUN_009ec240` with **no branch on its result**: a click the filter does not send (under 5 units with no order, or a snapped heading) still moves it. Only a new press moves it again: holding the button repeats nothing (round 701, the next section; round 698's line here that "a held button repeats the click (timer 7)" was wrong -- timer 7 re-plots a sky click's heading run). |
| Ground click within 20 units of an NPC | `FUN_009ec570` 0x9ec5a0..0x9ec5eb: walks the object list `0xec4d98` (nodes at object+0x78c); for a CICNPC (0xef1ac4: NPCs and guards) whose 3-D squared distance to the click (`FUN_009ed1e0`) is under 400.0 (double 0xd878a8) and whose +0xc4 is not 0.0, returns | Nothing: no destination, no click filter, no move, the ring stays where it was. +0xc4 is the object's model scale: its writer `FUN_009c4510(scale)` (0x9c451d) stores it and resizes the model's box; the spawns pass it (CICNPC::vslot_025 0x9d487d, CICMonster's rarity x ref scale 0x9d3a53); the CIObject constructor sets 1.0 (0x9c4909). So: an NPC drawn at a non-zero scale. Found by round 698's review. |
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

## Holding the left button (round 701, READ)

A press is one click; holding the button, moving the mouse with it held and letting it go do
nothing more. From `CGInterface::vslot_017` (0x77c260, the world's mouse handler) and the input
object's button bytes:

| Message | Code | What it does |
|---|---|---|
| WM_LBUTTONDOWN (0x201) | 0x77c4a7 `call 0x793570` | SetFocus, then the whole pick: the object under the cursor (`FUN_0078ee20`) to the object click `FUN_00792f00`, else the ground click `FUN_0078f8d0` -> `FUN_009ec570` (the NPC test, the destination, the click filter, the ring) or a sky run `FUN_009ebec0`. This is the only place a left click walks. |
| WM_MOUSEMOVE (0x200) | vslot_017's first branch | Turns the camera when the RIGHT byte is down and the swap flag +0x4f9 is clear, or the MIDDLE byte with the flag set (`FUN_00ba6240(2)` / `(1)`). Never reads the left byte. Then stores the cursor. |
| WM_LBUTTONUP (0x202) | `FUN_0078e5d0` | Only when process mode +0x50c is 0xae or 0xaf: ends that mode (`FUN_00592b70`). No walk, no pick. |
| WM_LBUTTONDBLCLK (0x203) | `FUN_00792190` | A double click on a character: an action request through `SendMagicStateMsg_074_791d40` (0x7074) for the classes it tests; no ground pick. The first press was already a click. |
| Timer 7 | set by `FUN_00777b90` (500 ms) after a sky click's `FUN_009ebec0`, by the arrow-key walks `FUN_0077b070` and `FUN_00780610` (heading runs too) and by the per-frame `FUN_009ec380`; killed by `FUN_00777ba0` on a ground click | `CGInterface::vslot_005` case 6 -> `FUN_009eb8e0`: re-plots the heading run (mover state +0x6e8 == 2) from the player's own position and heading; it reads no mouse. Killed when it returns 0. |

The button bytes (`gfxmainframe::FUN_00ba7240`): +0x258 left (0x201 sets, 0x202 clears), +0x259
middle (0x207 / 0x208), +0x25a right (0x204 / 0x205); `FUN_00ba6240(i)` reads +0x258 + i. Its
callers: vslot_017's WM_MOUSEMOVE (indices 1 and 2) and the hover code `CGInterface::vslot_005`
case 0 (index 0: cursor 0x9a instead of 0x99 over a ground item, class 0xef1c28, while the left
button is down -- a cursor, not a walk), plus two UI controls (`CNIFEdit::vslot_017`, `FUN_00637290`, index 1). No
reader of the left byte issues a move. So retail: the press places the ring and sends one move;
the character walks to the ring; a drag moves neither; a new press does. The 0xB021 heading echo
(kind 0, `NetProcessInNavAndSkill::FUN_008a5750`) hides the ring and kills or re-arms timer 7 --
heading moves only.

OpenSRO before round 701 clicked on the RELEASE and, after a drag past 6 pixels, re-picked the
destination under the cursor every physics frame ("the circle will fluidly move around with your
cursor", playtest 2026-10-03). Round 701 clicks on the press (`World3D._unhandled_input` ->
`_dispatch_left_click`) and reads nothing while the button is held; the right button's orbit is
unchanged.

## Clicking an NPC, a gate or a monster (round 701, READ)

The world's left press runs 0x793570 (above). For an object under the cursor it first calls the
object click `FUN_00792f00`, then branches on the class. The distance it reads is the object's
+0x24c: the 3-D distance from the local player, which `CICPlayer::vslot_005` writes for every
object each frame (0x9d6f19..0x9d6f7e: the two world positions +0x90..+0x98, `sqrt`).

| Class | In reach | Out of reach |
|---|---|---|
| CICNPC (0xef1ac4; guards too) | distance <= 240.0 (double 0xdb9888): `FUN_00778650` (the ring follows it, texture 1) and the select request 0x7045 (`FUN_0078f5f0`) | > 240.0: the same `FUN_00778650`, then the approach below with range 240.0 (float 0xdb9884) |
| CITeleportGate (0xef1dac) | <= 800.0 (double 0xd83080): the select 0x7045 | > 800.0: the approach with range 640.0 (float 0xdb9890). No `FUN_00778650`: a gate gets no follow ring |
| CICUser with a stall open (+0x471 == 4) | <= 100.0 (double 0xe1b7d8): `FUN_0081e170` (the stall) | the approach with range 80.0 (float 0xd8524c), arrival flag 2 (`FUN_0081e170`). Not built |
| CICMonster, CICCos | `FUN_00778650` (texture 3) and the select 0x7045 -- no walk, no attack | the same: there is no distance test |

**The approach** (`FUN_0078f8d0(msg, 1, 0)` -> `FUN_009ec6b0(id, 20.0, range, flag)`; the 20.0 is
float 0xd88108, the object fields +0x634 / +0x638 / +0x63c that 0x793570 fills): when the squared
distance is at least range squared, `d = rand() / 32767.0 * (range - 20) + 20` (double 0xde4808),
the destination `object + d * unit(player - object)` (`FUN_009ed1e0` returns its second position
less its first, here the player less the object), the ring moved there with the ground texture
(`FUN_00a631e0`), the walk sent through the click filter `FUN_009ec240`, and the object's id kept
at destination+0x20 with the flag at +0x24. So the ring lands between 20 and 240 short of an NPC
(a gate: 640) on the line to the player: not at the click, and not always at the farthest spot.

**The arrival** (`FUN_009ec380`, every frame): with an id pending it waits for the mover to start
(+0x714 != 0, then +0x28 = 1) and then to stop (+0x714 == 0 and +0x6ec == 0), and calls
`FUN_0078ff60(flag, id)`: flag 0 -> `FUN_0078f5f0(id)`, the select. The select's reply
(`NetProcessInInterface::FUN_0088b200`) opens the talk window for an NPC or a gate
(`IF_NPCWindow::FUN_00703ff0`, the server's option list read into `FUN_006fcd00`) and, for a
CICharactor, `FUN_00778650` again: the ring goes back under the NPC. A ground click clears the
pending id (`FUN_009ec570` writes +0x20 = 0).

**The server** (SR_GameServer, the select handler 0x50faf0, reply 0xB045): it measures with
`GObjPC::IsWithinInteractionRange` (0x4a8e10; docs/protocol/teleport_network.md has its limits:
300 for an NPC, 800 for a structure, 500 for a monster, 3-D) and replies an error beyond it; the
client's reply handler shows a message only for 0x6007. The shop handler (0x510250) and the
teleport handler (0x513590) measure the same way.

**The monster's attack**: `FUN_00792f00` runs before the selection and sends the action 0x7074
for a CICMonster only when Ctrl is down (`GetKeyState(0x11)`) or the monster already is the
selection (+0x628) with the target window up (`FUN_00778120`). So the first click selects and the
next click attacks; a double click (WM_LBUTTONDBLCLK -> `FUN_00792190`) attacks outright. The
client has no walk on that path: the server walks the attacker into reach (READ: SR_GameServer's
attack tick 0x4ad8e0 calls `GObjPC::MoveTowardObject(target, round(stop))` while the target is out
of reach, docs/protocol/auto_command.md, rounds 247 / 256).

**OpenSRO (round 701).** `World3D._start_talk_approach` / `_step_talk_approach`: an NPC beyond 240
or a gate beyond 800 is walked to a point `talk_approach_point` drawn in 20..240 (640) on the line
to the player, the ring placed there; the walk's end opens the talk window if the player is within
the server's limit (`talk_out_of_range`: 300 / 800, 3-D) -- this client has no select request, so
it applies the server's test itself -- and logs a refusal otherwise. Any new click, death, a zone
change or the target going ends the approach (OURS in part: retail is not read to drop it on a
monster's select). A monster click selects (ring, target window) and attacks only on the next
click while the target window shows that monster, with Ctrl, or on a double click (routed as
retail's WM_LBUTTONDBLCLK: `_dispatch_double_click` attacks a monster and ignores the ground, an
NPC and a gate). An NPC click moves the selection off a monster (`_select_for_talk`); a typing
lock pauses an approach rather than ending it (OURS). The walk into reach stays this client's
(OURS: OpenSRO's server does not chase). The server needs no change for talking: OpenSRO has no
select or talk request, the teleport request has applied the range since round 642, and the shop
and storage requests carry no NPC to measure (TODO).

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

## What OpenSRO builds (round 698)

`GroundMarkers` (one node, `World3D._markers()`): `place_at` on every ground pick that hits
(`_move_by_pick_ray`, before the click filter), `attach` from the monster clicks (`_ring_on_monster`, not `_show_target`, which a cast at the selection also calls -- retail's casts do not reselect),
`_select_character` (players) and `_try_talk_to_npc` (NPCs; a gate gets none),
`heading_move` from `_start_heading_run`, `hide_marker` on a zone change, `step` once a physics
frame (follow or hide). The drape is the 3 x 3 cells of the region's own heights, the
projected UV, `select_0N.ddj` through DdjReader, unshaded alpha blend, clamp.

A ground click within 20 units of an NPC returns from `_move_by_pick_ray` before the ring and
the walk (`GroundMarkers.npc_blocking`, the holders tagged `npc_name`, not gates; logged as
`CLICK: ground at ... ignored -- d from NPC <name>`). The mesh is built for the 3 x 3 cell window
only; inside it the art follows the point through a shader uniform (`RING_SHADER`, UV = (local
xz - origin) / 12, the projection itself), so a followed body costs 13 us a tick instead of 117
(MEASURED, `client/tools/measure_ground_ring.gd`). The height cache holds plain height arrays and
drops a region the grid prunes.

OURS, each said in the code: the drape is lifted 0.05 (different transforms could z-fight on
equal heights); it splits cells the way OUR terrain mesh does (always (r, c)-(r+1, c+1)), not
retail's alternating fans, so it lies on what is drawn; the heading-move hide happens when the
run starts (this client streams positions and gets no 0xB021 echo); culling off; the still-water
quad spans the 3 x 3 window with the projected UV (with clamp and the art's transparent border it
draws the same 12 x 12 square round the point, and need not be rebuilt as the point moves).

## On a placed floor (round 701, OURS: the user's decision)

The user checked a live retail server on 2026-10-03: no ring on Jangan's central plaza deck, the
terrain-only drape above at work ("That seems like a bug we should fix"). So OpenSRO departs from
retail here, and only here: where the point stands on a placed object's walkable surface the ring
is draped on that surface; where it stands on the terrain the drape is retail's, unchanged. Every
number is OURS, named in `GroundMarkers`:

- **Floor or terrain** (`floor_choice`): the point more than 1.0 above the drawn terrain there
  (`TerrainCollision.mesh_height_at` of the region's heights) AND a short vertical ray (0.5 above
  to 1.0 below, the pick layers 0b1001) meeting a body without the terrain-only bit 0b1000.
  Placed objects collide on layer 1 alone, the terrain on layers 1 and 4.
- **Samples**: vertical rays on a 2-unit grid of the region's frame, from 2.0 above the point to
  2.0 below it, so a roof or awning over the point is never met.
- **Edges**: a triangle with a corner that missed or lies outside that span, or whose corners
  differ by more than 1.0, is left out -- nothing stretches down a deck's side or up a wall; a
  lower level within reach is drawn on its own.
- **Look**: the same shader, texture and region-frame origin uniform as the terrain ring, lifted
  0.05 above the hits; no still-water quad on a floor.
- **Cost**: the test and the mesh run only when the point enters another 6 x 6 cell or moves 0.25
  in height; one build covers the art for anywhere in its cell (the 10 x 10 grid points from 6
  before the cell to 6 after it), and samples are kept per region and reference height (up to
  2048), so a body walking a deck fires about one new column of 10 rays per 2 units.
  MEASURED (`client/tools/measure_ground_ring.gd`, headless on the box, a body at 50 units/s,
  1,200 ticks, three runs): 11.7 us a tick on the terrain (13.0-13.3 before the round, the same
  runs interleaved), 35.0-35.4 us on a deck with 166 rebuilds and 5,120 rays.
