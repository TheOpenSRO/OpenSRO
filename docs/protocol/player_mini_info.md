# The player block (CIFPlayerMiniInfo)

The top-left block: `GDR_PLAYER_MINI_INFO` in `resinfo\ginterface.txt`, its 53 children in
`resinfo\ifplayerminiinfo.txt`, and the class `CIFPlayerMiniInfo` in the client
(`IFPlayerMiniInfo.cpp`, asserted at 0x007b4b20). Read in round 629 from the decompile
(`/var/tmp/decomp_client`) and the disassembly (`/var/tmp/sro_client.asm`); constants read from
`sro_client.exe`'s own sections. Labels: **READ** (from the code or data), **MEASURED** (counted
or checked against real data), **INFERRED** (a conclusion from READ facts), **OURS** (a choice of
this project), **OPEN** (not recovered).

## Where each control lands (READ, `CIFPlayerMiniInfo::Create`, 0x007b5600)

`FUN_008b51f0(id, 1)` fetches a child by the layout's `ID`. The ones kept:

| member | id | control | notes |
|---|---|---|---|
| +0x3c8 | 12 | GDR_PMI_PICTURE | picture control; given `interface\playerminiinfo\pmi_face.ddj` (+0x380) and a 128x128 render buffer (`BufRender::FUN_009edae0(0x80, 0x80)`) |
| +0x394 / +0x398 | 0 / 1 | GDR_PMI_GAUGE_HP / _MP | art set through slot +0x34: `pmi_hp.ddj` / `pmi_mp.ddj` (124x12) |
| +0x3a0..+0x3b0 | 7..11 | GDR_PMI_CIRCLE0..4 | the five berserk orbs (`pmi_jahwan.ddj`, 8x8) |
| +0x3b4 | 13 | GDR_PMI_BTN_JAHWAN | the ready circle (`pmi_jahwan_button.ddj`, 20x20, at 16,-5) |
| +0x3b8/+0x3bc/+0x3c0/+0x3c4 | 3/4/5/6 | TXT_ID, TXT_LEVEL, TXT_HP, TXT_MP | |
| +0x390 | 34 | GDR_PMI_BTN_STATUP | `com_plus_button.ddj`, 150,3 |
| +0x39c | 14 | GDR_PMI_PARTY_LEADER | |
| +0x380 | 200 | GDR_PMI_SELECT | |
| +0x3cc | 20 | GDR_PMI_BTN_CINFO | the stat panel's button (`pmi_button.ddj`, 41,56); tooltip `UIIT_STT_CHARACTER_ABILITY_VIEW_OFF` |
| +0x3d0..+0x420 | 21, 35, 36, 22..27, 52, 53, 37, 38, 28..33, 54, 55 | GDR_PMI_STA_CINFOBG and the twenty stat labels/values | all hidden at create |
| +0x424 / +0x428 | 45 / 46 | GDR_PMI_HWAN_EFF_FACE / _GLOW | berserk overlays |
| +0x43c..+0x44c | 40..44 | GDR_PMI_DECO_HWAN_SLOT0..4 | flames: `pmi_jahwan_burn.ddj`, 16x28 frames (`FUN_00633b90(16,28)`), 12 frames (`FUN_00633970(12)`) |
| +0x468 / +0x46c | 77 / 78 | GDR_PMI_EFFECT_HP / _MP | low-HP/MP caution |

`GDR_PMI_RACE_MARK` (id 15) is taken by the one-time fill 0x007b6fd0, not by Create.

## Clicks: the message map (READ)

Initialised at 0x00d71d40; entries are 0x28 bytes from 0x00ebf1e8 (`msg, 0, id_lo, id_hi, sig, 0,
pfn`), read out of the exe's `.data`:

| msg | ids | handler | does |
|---|---|---|---|
| 0x801 | - | 0x007b4b20 | releases the portrait's render buffer (device lost) |
| 0x802 | - | 0x007b4b80 | recreates it |
| 1 | 34 | 0x007b4c10 | shows the main popup and selects its character page (`FUN_006a1f70(0x4b)`) |
| 1 | 20 | 0x007b4c60 | toggles the stat panel: the background's visibility flips, every row takes the new state |
| 1 | 13 | 0x007b4f00 -> 0x00778ac0 | `if (player+0x886 >= 5) FUN_0081e690(1)`: the berserk request, silently nothing below five |

A left press anywhere else on the block is `vslot_030` (0x007b4be0), selecting the player (round
622).

## The berserk (Hwan) gauge

- **The count** is `player+0x886`, `_CHAR.RemainHwanCount` (0..5), which the server sends in
  0x304E type 4 (READ, round 629's review). The setter `FUN_00778ae0(count, flag)` stores it; with
  the flag it runs the activation `FUN_007b4f40(1)`, else with a count that is not 0 the refresh
  `FUN_007b4f40(0)`, and with `(0, 0)` it refreshes NOTHING (READ). The berserk request's gate,
  0x00778ac0, tests the count only (`>= 5`), not whether a display is running.
- **The refresh**, `FUN_007b4f40(0)` (READ): the five flames hide; the ready circle shows exactly
  when the count is 5; the loop starts at +0x3b0 (CIRCLE4, the bottom orb at 31,60) and walks up to
  +0x3a0 (CIRCLE0, the top one at 7,13), SHOWING one orb per charge and HIDING the rest. So the
  orbs fill bottom-up, and an empty socket is the frame's own dark socket.
- **Activation**, `FUN_007b4f40(1)` (READ): the ready circle hides; timer 1 is set to 50 ms
  (`FUN_00b93320(1, 0x32)`) and timer 2 to `round((60 + player+0x20f8 + socket bonus) * 1000 / 5)`
  ms (60.0 is the double at 0x00d880d8, 1000.0 at 0x00d83268, 5.0 at 0x00d81950; the socket bonus
  is `FUN_006ac0a0`, which looks for `SKILL_ITEM_ETC_SOCKET_STONE_HWAN_E_01..03`). `player+0x20f8`
  is the Energy of life scroll's bonus (READ): `FUN_0089a0d0` stores the value of a timed job with
  FourCC `0x706874` there (`FUN_009d4e00`) while the job has time left, and `FUN_0089a1a0` clears
  it at that job's end. srrevamp feeds it from the composite state's bonus
  (`HudPlayerInfo.set_hwan_time_bonus`; round 629-632 integration); the socket bonus is OPEN (0:
  no socket stones). Each flame starts
  on frame `rand() % 12`, shows, and fades 0 -> 255 over 1.0 s (`FUN_006526e0(0, 0xff, 1.0f)`);
  the face and glow show and fade in over 3.0 s (the float at 0x00d8adc4).
- **While on** (`vslot_005`, READ): case 1 advances every flame one frame (`FUN_00634300`, wraps
  at 12) and re-arms 50 ms; case 2 -- CLIENT timer 2, every duration/5, 12 s at the 60 s base --
  fades orb `k` and flame `k` 255 -> 0 over 1.0 s, `k` counting
  up from 0 (the top first); at the fifth it hides all ten, fades the face and glow out over 3.0 s,
  and kills both timers.
- **The refresh**, `FUN_007b4f40(0)`, touches neither timer nor the face and the glow (above): a
  count arriving during the display leaves the drain running.
- **The reset**, `FUN_007b5300` (READ): only while timer 2 runs -- each SHOWN orb and its flame
  fade 255 -> 0 over 1.0 s (from 255), the face and the glow over 3.0 s only when their alpha is
  exactly 255 (`+0x12d == -1`) -- then it kills timer 2 (not timer 1). It is NOT the
  server's end: it runs on the player's DEATH (0x30BF kind 0 value 2 -> `FUN_0077b000`, the call
  at 0x0077b02c) and on a ZONE RESET (`FUN_00787860`, the call at 0x00787930).
- **The body mode**, 0x30BF kind 4 (READ; server `CGObjChar::SetBodyMode` 0x4a9fc0 ->
  `GObjPC::BroadcastStateChange` 0x4a8340, client handler 0x8a80a0): value 1 = berserk on, with
  one more byte that the client reads only for value 1 -- chardata+5, which `SetBodyMode` sets to
  its fifth argument just before broadcasting (the flag granting param 189's 0.3), and the berserk
  activation passes 0 there (`push 0x0` at 0x515cc6; READ, round 629-632 integration) -- and for
  its own player `FUN_00778ae0(0, 1)` -- the display starts; value 0 = off, which ends the body mode
  and leaves the display to timer 2. srrevamp's server sends both (round 629's review): on at
  activation, off when the tracker's activation runs out (`scheduleBerserkEnd`), and off when a
  revive or a zone change ends the berserk (`endBerserk`: the engine's revive and world entry set
  body mode 2, broadcast as value 2; srrevamp has no body mode 2 and sends 0, OURS).
- **Hwan level art**, `FUN_007b5f40` (READ): when the byte at `player+0x764` is not 0 the orbs,
  flames, button, face and glow swap to `pmi_jahwan_02*.ddj` (blue). INFERRED: that byte is
  `_CHAR.HwanLevel` -- its setter 0x009ca930 builds the Hwan title through `hwanleveldata`.
- The server's berserk lasts 60 s (`internal/berserk.Duration`, recovered from the server
  binary); the client's 60 s display base agrees with it.

## The stat panel (READ, `vslot_012` 0x007b7c60, every frame)

| row | value | source |
|---|---|---|
| Str / Int | `%d` | `player+0x87c` / `+0x87e` (u16) |
| Phy. atk | `%d ~ %d` | the stats block (`FUN_00987090` on 0x00eeebd8) +0 / +4 |
| Phy. def. | `%d` | +0x10 |
| Mag. atk | `%d ~ %d` | +8 / +0xc |
| Mag. def. | `%d` | +0x12 |
| Hit rate / Parry ratio | `%d` | +0x14 / +0x16: the u16s the server sends in 0x303D (client `FUN_00880f80`), built by `CGObjPC::vslot_334` (0x4ebe30) from params 11 and 9 |
| Phy. balance | `%d %%` | computed, below |
| Mag. balance | `%d %%` | computed, below |

The balances (READ, 0x007b802c..0x007b81d0; the character window's CIFPlayerInfo computes the
same at 0x006b8ee3..0x006b90fc):

    L   = the byte at player+0x20d8 (FUN_009d4d70): the server-sent MaxLevel (READ, round 629's
          review); FUN_009d4d50 keeps it max(itself, +0x868 level)
    phy = ftol( (Str + 2L + 14) * 100.0 / float32( ((L - 1) * 7.0 + 56.0) * 0.8571428656578064 ) )
    mag = ftol(  Int * 100.0 / ( (L + 7) * 5 * 0.8 ) )
    each capped: >= 120 shows 120

`ftol` is `FUN_00b42d10`, the CRT's truncating conversion. MEASURED against a retail screenshot:
Str 21, Int 21, level 2 gives 72 % and 58 %, as shown. The one-time fill 0x007b6fd0 uses the
current level and a cap of 100; the per-frame rewrite above replaces it at once.

`GDR_PMI_BTN_STATUP` shows while the u16 at `player+0x884` is not 0 -- the unspent stat points,
which the server sends in 0x304E type 3 (READ, round 629's review) -- and blinks (`FUN_00655ec0(1)`, OPEN here).

## The race emblem (READ, 0x007b6fd0 -> `FUN_0098caa0`)

`GDR_PMI_RACE_MARK` (53,41, 24x24) is shown with `FUN_0098caa0(race, 0)`: race 0 ->
`interface\ifcommon\com_kindred_china.ddj`, 1 -> `com_kindred_europe.ddj`, anything else -> no
path. The race is the byte at the character's reference object +0x9c, `_RefObjCommon.Country`
(RE_COMPLETION 2026-09-16). MEASURED: characterdata column 14 reads 0 on all 26 `CHAR_CH_*` rows
and 1 on all 26 `CHAR_EU_*` rows.

## The portrait (READ; drawn since round 635)

`UI_SILKMALL::FUN_007b7740` renders the portrait. srrevamp's version is
`client/scripts/ui/hud/player_portrait.gd`.

**The model (READ).** `IFMainPopup::FUN_006a1d50` returns the popup's +0x7c0, the CIFEquipment
page. Its CCObjAnimation at +0x36c (the object at +0x370) is the equipment window's own dressed
avatar. When `vt+0x98` says the avatar is not ready, the dirty byte stays set and the render
tries again next frame.

**The render, step by step (READ):**
1. Play animation 0x3c (`vt+0xc(0x3c, 0, 0, 0, 1.0, 1.0)`). 0x3c = 60 = ANI_POSE, per
   `FUN_009e5240`'s name map.
2. Step it once: `FUN_00a5ac80(1, 0.0)` calls the object's `vt+0x38` with the frame time.
3. Find `Bip01 Head` (`vt+0x44`, the string at 0x00da95fc) and take its matrix's translation
   (+0x30..+0x38).
4. Build the camera and set the avatar's yaw to 0.1 (`FUN_00a5a8c0`, the float at 0x00e1b7fc).
5. Begin the buffer (`BufRender::FUN_009edb60`). This sets the target and depth and clears both
   to 0xff000000 / 1.0.
6. Set the camera (`vt+0x5c` of the manager at 0x0110f7ec) and the view/projection
   (`FUN_00bbdbd0`).
7. Queue the avatar on the object renderer (slot 10), draw (slots 3, 5 and 6), then end the
   buffer (`FUN_009edc90`).
8. Restore the yaw from CIFEquipment +0x578 (its rotate buttons' angle,
   `FUN_006ab920`/`FUN_006ab960`), stop 0x3c and play animation 0.

MEASURED: every player body lists ANI_POSE in its `default` group. CHAR_CH_MAN_FIGHTER and
CHAR_EU_MAN_WARRIOR use `prim\ani\char\china\man\man_pose.ban`; CHAR_CH_WOMAN_FIGHTER and
CHAR_EU_WOMAN_KNIGHT use `...\woman\woman_pose.ban`. The EU bodies share the China skeletons and
clips. Measured with `client/tools/probe_portrait.gd` and `portrait_shot.gd`.

**The camera (READ: 0x007b7875..0x007b790a, `CGFXVideo3d::FUN_00bae810`, `FUN_00bae580`).** The
render starts from a copy of the game camera (copy constructor `FUN_006d8000`) and sets:

| field | value | meaning |
|---|---|---|
| +0x10 | head + (0, 1.0, 0) (the double at 0x00e1b7f0) | the look-at target |
| +0x34 | 0 | rotation about X |
| +0x38 | 0.2 (0x00da95f8) | rotation about Y: a yaw around the head |
| +0x3c | 0 | rotation about Z |
| +0x40 | 6.5 (0x00da95f4) | the distance |
| +0x50 | 30.0 (0x00d82ef0) | the vertical field of view in degrees |

- `FUN_00bae580` builds `R = RotZ(+0x3c) * RotX(+0x34) * RotY(+0x38)`.
- It sets the up vector to `(0,1,0) * R` and the eye to `target - (0, 0, +0x40) * R`.
- When the byte at +0x44 is 0, the distance is 10000.0 instead (0x00d82efc).
- A switch on the camera mode (+0x0) picks a preset rotation, but the multiply overwrites it
  (the product's output is the same matrix).
- The projection is `FUN_00aa4ef0(+0x50 * pi/180, aspect, +0x48, +0x4c)`, a `PerspectiveFovLH`
  (0x00e1b8d8 = pi/180; `cot(fov * 0.5)`). Byte +0x44 set selects it; when it is clear,
  `FUN_00aa5134` uses +0x3c as a width.
- The aspect is the viewport's (INFERRED 1.0: `SetRenderTarget` resets the viewport to the
  128x128 surface before `FUN_00bae810(1)` reads it).
- Near and far (+0x48/+0x4c) are the game camera's (OPEN).
- INFERRED: that 0x00ec7798 / 779c / 77a0 are D3DX RotationX / Y / Z. They are D3DX's
  declaration order, and the mode presets (RotX ±pi/2 up/down, RotY pi/2, 3pi/2, pi) only make
  sense that way.

**The avatar's yaw (READ).** `FUN_00a5a8c0(f)` calls `vt+0x30(f)` on the object. For the
CCompoundObj family (`CCompChar::FUN_00c26e70`, vtable slot 12) that setter builds the rotation
`[[cos,0,sin],[0,1,0],[-sin,0,cos]]` (cos 0x00b44a10, sin 0x00b44b40). INFERRED: the avatar
object is of that family.

**The light (READ, 0x007b796d..0x007b7a64).** The D3DLIGHT9 at `esp+0x2c`:

| part | value | address |
|---|---|---|
| Type | 3 (directional) | |
| Diffuse | 0.7, 0.7, 0.7 (alpha 0) | 0x00d82f04 |
| Specular | 0.58 x3 | 0x00da95f0 |
| Ambient | 0.3 x3 | 0x00d82f00 |
| Direction | (0, 0, 1) | |
| Range | 1000.0 | 0x00da95ec |

The render then:
- sets `SetLight(0)` and `LightEnable(0, 1)`;
- sets render states 0x24/0x25 (fog start/end) to 1000.0, and the renderer's fog slot
  (`CObjRendererVS::vslot_014`, vertex constant c16) to (1000, 1000, 0);
- sets 0x89 LIGHTING = 1, 0x1b ALPHABLENDENABLE = 0 and 7 ZENABLE = 1;
- sets stage 0 to MODULATE(TEXTURE, CURRENT) and disables stage 1.

**How the object renderer uses it.**
- The skinned-object vertex shader (`vertexshader2.c`) lights with
  `oD0 = c10 + max(0, N.c9) * c11`.
- `CObjRendererVS::vslot_025` (0x00beecc0) is the renderer's light setter. It stores
  Direction x -1.0 (0x00e1b8e8) at renderer+0x130 for c9, and Diffuse and Ambient in globals
  (0x01112e18, 0x01112e28).
- `vslot_038` multiplies the material colour by those for c10 (0x00bf59e1). It uploads c9 in
  object space and sets stage 0 to D3DTOP_MODULATE2X (0x00bf5e1e).
- MEASURED: player body materials are ambient = diffuse = 0.588, so a lit face is
  `2 x 0.588 x texel`.
- INFERRED / OPEN: the portrait calls the device's SetLight, not `vslot_025`. The world's
  environment code calls both (`Map::FUN_00a19160`). On a vertex-shader device, retail may
  therefore light the portrait with the zone's current light. srrevamp uses the portrait's own
  READ light.
- The specular term is not drawn: the shader writes no oD1 from it.

**The picture control (READ).**
- Create (0x007b5600) gives GDR_PMI_PICTURE (a `CIFStaticWithPictureClip`) the texture
  `pmi_face.ddj` at +0x380, and the buffer's texture through `+0x84 -> vt+0x3c` into +0x15c.
- `CIFStaticWithPictureClip::vslot_013` (0x0064de80) draws one XYZRHW|TEX2 quad (FVF 0x204) over
  the control's rect with both UV pairs 0..1:
  - stage 0: colour SELECTARG1(TEXTURE) (the render), alpha SELECTARG1(CURRENT) = 1.0;
  - stage 1: colour SELECTARG1(CURRENT), alpha SELECTARG1(TEXTURE) (the mask);
  - alpha blending on.
- MEASURED: `pmi_face.ddj` is 48x48 ARGB8888, all texels black. Alpha is 255 on 1804 texels (a
  disc) and 0 on 500. It is the mask, not an image.

**When it renders (READ).**
- The byte +0x38c is tested by `vslot_012` (0x007b83ef) and cleared by the render.
- It is set by:
  - the constructor (0x007b4a48);
  - the device-reset handler (message 0x802, 0x007b4b80);
  - the render itself when the avatar is not ready;
  - `CIFPlayerMiniInfo::FUN_007b4c00`, called by the item-move reply `FUN_0087ba20` (five sites,
    each after the avatar's refresh `FUN_006ab690`) and by the avatar's reset `FUN_006abc50`
    (called from `FUN_00786f30`; INFERRED world entry).
- Nothing in the berserk code writes it.

**Other portraits.** The party slots (`IFQuickPartyWnd::FUN_006d8bf0`, buffers in
`CIFQuickPartySlot::Create`) and the academy slots (`IFApprenticeShip::FUN_006ea0c0`,
`CIFApprenticeShipSlot::FUN_006eb740`) use the same camera and light constants. No target-window
code creates a BufRender (INFERRED from the xref list of `BufRender::FUN_009edae0`).

**srrevamp** (round 635), in `client/scripts/ui/hud/player_portrait.gd`:
- it copies the player's dressed body and hangs it under a z -> -z node;
- it poses ANI_POSE at the first key (INFERRED: within one frame of retail's step);
- it applies the READ camera, yaw and light;
- its own shader does the lighting and MODULATE2X in gamma space. MEASURED: the SubViewport
  neither decodes nor encodes sRGB (a 0.5-grey calibration quad came out at the expected 150);
- it renders with `UPDATE_ONCE` on every dress;
- the camera's near and far are OURS (0.5 / 1000).
