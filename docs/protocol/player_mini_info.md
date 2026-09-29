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

- **The count** is `player+0x886`, `_CHAR.RemainHwanCount` (0..5); the setter 0x00778ae0 stores
  it and refreshes the block (READ).
- **The refresh**, `FUN_007b4f40(0)` (READ): the five flames hide; the ready circle shows exactly
  when the count is 5; the loop starts at +0x3b0 (CIRCLE4, the bottom orb at 31,60) and walks up to
  +0x3a0 (CIRCLE0, the top one at 7,13), SHOWING one orb per charge and HIDING the rest. So the
  orbs fill bottom-up, and an empty socket is the frame's own dark socket.
- **Activation**, `FUN_007b4f40(1)` (READ): the ready circle hides; timer 1 is set to 50 ms
  (`FUN_00b93320(1, 0x32)`) and timer 2 to `round((60 + player+0x20f8 + socket bonus) * 1000 / 5)`
  ms (60.0 is the double at 0x00d880d8, 1000.0 at 0x00d83268, 5.0 at 0x00d81950; the socket bonus
  is `FUN_006ac0a0`, which looks for `SKILL_ITEM_ETC_SOCKET_STONE_HWAN_E_01..03`); each flame starts
  on frame `rand() % 12`, shows, and fades 0 -> 255 over 1.0 s (`FUN_006526e0(0, 0xff, 1.0f)`);
  the face and glow show and fade in over 3.0 s (the float at 0x00d8adc4).
- **While on** (`vslot_005`, READ): case 1 advances every flame one frame (`FUN_00634300`, wraps
  at 12) and re-arms 50 ms; case 2 fades orb `k` and flame `k` 255 -> 0 over 1.0 s, `k` counting
  up from 0 (the top first); at the fifth it hides all ten, fades the face and glow out over 3.0 s,
  and kills both timers.
- **The end from the server**, `FUN_007b5300` (READ; called from 0x0077b02c and 0x00787930):
  fades whatever still shows and kills timer 2.
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
| Hit rate / Parry ratio | `%d` | +0x14 / +0x16 |
| Phy. balance | `%d %%` | computed, below |
| Mag. balance | `%d %%` | computed, below |

The balances (READ, 0x007b802c..0x007b81d0; the character window's CIFPlayerInfo computes the
same at 0x006b8ee3..0x006b90fc):

    L   = the byte at player+0x20d8 (FUN_009d4d70); FUN_009d4d50 keeps it max(itself, +0x868 level)
    phy = ftol( (Str + 2L + 14) * 100.0 / float32( ((L - 1) * 7.0 + 56.0) * 0.8571428656578064 ) )
    mag = ftol(  Int * 100.0 / ( (L + 7) * 5 * 0.8 ) )
    each capped: >= 120 shows 120

`ftol` is `FUN_00b42d10`, the CRT's truncating conversion. MEASURED against a retail screenshot:
Str 21, Int 21, level 2 gives 72 % and 58 %, as shown. The one-time fill 0x007b6fd0 uses the
current level and a cap of 100; the per-frame rewrite above replaces it at once.

`GDR_PMI_BTN_STATUP` shows while the u16 at `player+0x884` is not 0 (INFERRED: the unspent stat
points) and blinks (`FUN_00655ec0(1)`, OPEN here).

## The race emblem (READ, 0x007b6fd0 -> `FUN_0098caa0`)

`GDR_PMI_RACE_MARK` (53,41, 24x24) is shown with `FUN_0098caa0(race, 0)`: race 0 ->
`interface\ifcommon\com_kindred_china.ddj`, 1 -> `com_kindred_europe.ddj`, anything else -> no
path. The race is the byte at the character's reference object +0x9c, `_RefObjCommon.Country`
(RE_COMPLETION 2026-09-16). MEASURED: characterdata column 14 reads 0 on all 26 `CHAR_CH_*` rows
and 1 on all 26 `CHAR_EU_*` rows.

## The portrait (READ; OPEN in srrevamp)

`UI_SILKMALL::FUN_007b7740` renders the player's own model into the 128x128 buffer whenever the
block is marked dirty (+0x38c): it plays animation 0x3c on the model, finds the `Bip01 Head` bone,
builds a camera from the head's position (+1.0 on y, the double at 0x00e1b7f0) with the floats
0.2, 6.5 and 30.0 (0x00da95f8, 0x00da95f4, 0x00d82ef0) and 0.1 (0x00e1b7fc), renders the model
alone, and restores the model's animation. `pmi_face.ddj` (48x48, a black disc) is the picture
behind it. Which of the camera floats is the distance, the height offset and the field of view is
not settled from the decompile alone (OPEN), and srrevamp does not draw this render yet.
