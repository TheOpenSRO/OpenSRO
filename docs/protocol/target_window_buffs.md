# The target window's buffs and race emblem: `CIFBuffViewer` and the kindred mark

Round 638 records here how retail shows a selected target's buffs, at the top middle of the screen
under the target's name bar, and the race emblem at the left of a player's bar. srrevamp's
versions are `client/scripts/ui/hud/hud_target_buffs.gd` (the viewer and the per-owner buff book)
and `client/scripts/ui/hud/hud_target.gd` (where the viewer sits, the emblem).

Every address is in `sro_client.exe`: the dump is `/var/tmp/decomp_client` and the disassembly is
`/var/tmp/sro_client.asm` on the RE box. The decompiler loses most of these functions' bodies, so
the rows below were read from the disassembly.

The labels are:
- **READ**: read out of the binary.
- **MEASURED**: measured in the box's archives or in a live run.
- **INFERRED**: a conclusion from something read or measured.
- **OURS**: a choice of this project.
- **OPEN**: not established.

## The window

| What | Value | Label |
|---|---|---|
| Layout | `GDR_TW_BUFF:CIFBuffViewer`, ID 100, `Rect=0,37,0,0`, in `resinfo\iftargetwindow.txt` (the container `CIFTargetWindow::Create` 0x699080 loads) | MEASURED |
| Handle | `CIFTargetWindow::Create` fetches ID 0x64 into the window's `+0x388` (0x699104..0x69911b) and hides it | READ |
| Class | `CIFBuffViewer : CIFWnd` (RTTI). Its vtable 0xdcf59c has 49 slots and overrides only 0, 1, 2 and 10; every mouse slot is CIFWnd's empty stub (0x46fd00..0x46fd70). So a click on it does nothing, and nothing is cancelled from it | READ |
| Constructor | 0x7fb820: two lists (`+0x38c` main, `+0x398` second, node size 0x38), caps `+0x36c`/`+0x370` = 0 (none), per row `+0x374` = 8, pitch `+0x378`/`+0x37c` = 21/21, icon `+0x380`/`+0x384` = 20/20. The target window overwrites the pitch (below) | READ |

## Which targets show it (the select function 0x699540)

- A byte (`[esp+0x1b]`) is cleared at 0x6996a7, before the class tests.
- It is set to 1 in the **CICMonster** branch (0x6999ec, after every rarity, the no-piece rarities
  included), the **CICCos** branch (0x699b62: pets, horses, transport) and the **CICUser** branch
  (0x699ee2: players; this player's own object is a CICUser too).
- The **CICNPC** and **CICATStruct** branches jump to the join point (0x69a161) without setting it.
- At the join (0x69a182): with the byte set, the viewer is shown (vslot 0x5c(1) if hidden) and
  moved; then the target's buffs are collected and filled in (0x699480) and **timer 1 is armed at
  1000 ms** (0x69a215: `push 0x3e8; push 1; call 0xb93320`). With it clear, timer 1 is killed
  (0x69a269, `0xb93170(1)`); the viewer was hidden with every piece at the top of the function.

## Where it sits (0x69a1ab..0x69a1cb)

The viewer is moved (vslot 0x98, an absolute move) to `(window x, piece y + piece height + 1)`,
where the piece's rect is the one the branch read with 0xb8f420 into `[esp+0x1c..0x28]` and the
window x is the centring formula's result stored back into `[esp+0x1c]`. So it sits directly
under the shown piece, at the window's left edge. The layout's own `Rect=0,37` is not used.

| Piece | Height | Viewer at |
|---|---|---|
| Player (`GDR_TW_PLAYERWND`) | 35 | (0, 36) |
| Job player | 58 | (0, 59) |
| Common enemy | 51 | (0, 52) |
| Special mob | 78 | (0, 79) |

A rarity-2 (or > 8) monster shows no piece and nothing writes the rect, so its viewer position is
not defined by anything read (OPEN). No monster in the archive has rarity 2 (MEASURED, round 589).
srrevamp hides the viewer then (OURS).

MEASURED against the retail screenshot (`scratchpad/ui3/target_buffs.png`, a player target
"DragonDive"): the name bar is 35 tall from y 8 and the first icon row starts at y 44, 36 below it;
the icons repeat every 23 px across and the second row sits about 24-25 px under the first.

## What it shows

**The source (READ, 0x9d25e0, called with the target at 0x69a1f9 and 0x699420).**
- It walks the object's `+0x284` list: a std::list. `+0x288` is the head, and 0x9cd050 inserts a
  new node before it, so the list is in arrival order.
- A node's value is a skill object. It is kept only when it IsKindOf `CIDecoSkill` (descriptor
  0x110a808) and its skill id `+0x5c` is > 0.
- Type `+0x54` == 2 gives an entry with "type 3" byte 0; type 3 gives the byte 1 and a name (the
  object's `+0x74` string). Any other type is skipped.
- Type 2 objects are made by 0xa54020 (0xa53850 writes `+0x54 = 2`). The **0xB0BD** buff-start
  handler (0x8a59e0) calls it at 0x8a5d49 for the owner it finds by id (0x9c31a0), whoever that is,
  and attaches the object with 0x9cd050. So every buff the zone is told about is on its owner.
- Type 3 objects are made by 0xa53fc0 (`+0x54 = 3`, the name copied to `+0x74`), called only from
  the **0xB0BE** handler (0x8a5da0, at 0x8a5e7d). What 0xB0BE carries in retail is OPEN; srrevamp
  sends nothing like it.
- Then the abnormal-state mask at `+0x2c4`: each set bit of the 32 goes in through 0x7fd2e0, which
  appends to the **second** list (0x7fd433..0x7fd463). srrevamp sends no one's abnormal states to
  the client, so none is shown (OPEN).

**Item states are not shown (READ).** The only adds are 0x7fd020 (a skill entry) and 0x7fd2e0 (an
abnormal bit): every call of either is from 0x699480, 0x7fd640, the party window (0x6d90xx) or
0x7b47xx. The buff bar's item-time kinds (3/4/5: "premium" and the item grants, round 632) come
from other packets into CIFMagicStateBoard only. So a target's premium or item grant never
appears here. A mall item that works by starting a **skill** buff (the `SN_SKILL_MALL_*` rows in
the name-only list below) does come through 0xB0BD and does appear.

## The grid (0x699480 sets it, 0x7fbea0 lays it out)

- 0x699480 clears the viewer (0x7fbcf0), then sets 8 per row (0x7fabb0(8)), a 23 x 23 pitch
  (0x7fabc0(0x17, 0x17)) and 20 x 20 icons (0x7fabe0(0x14, 0x14)).
- Each entry is added with 0x7fd020(entry, 0), each abnormal bit with 0x7fd2e0, and the grid is
  laid out once (0x7fbea0).
- **Which list (0x7fd020).** The skill row (0x93f250) `+0x184` is `bbuf`. An entry whose "type 3"
  byte is 0 and whose skill has `bbuf` goes to the second list; any other goes to the main list.
  The same `+0x184` test sends a `bbuf` buff to the buff bar's second list (0x804989).
- **Main list:** icon i at `((i % 8) * 23, (i / 8) * 23)`.
- **Second list:** icon j at `((j % 8) * 23, (j / 8 + rows1) * 23 + 2)`.
- `rows1` is **0 when the main list is empty** (0x7fbff1: `cmp eax,edi; je` skips the division).
  Otherwise it is `(n - 1) / 8 + 1`. This differs from the buff bar's board (0x7ffc10), which counts
  an empty list as one row.
- The viewer's size: `(23 * 8, (rows1 + max(n2 - 1, 0) / 8 + 1) * 23)` (0x7fc137..0x7fc176). The
  second list always counts one row.
- Entries are appended (inserted before the head sentinel). No cap.

## A slot

- 0x7fd020 creates a `CIFStateSlot` child (runtime class 0xeec948, the same class the buff bar
  uses) with rect `{0, 0, 20, 20}` (0xba20b0), then calls 0x8065b0(20, 20) and
  **0x806d50(0, 0, lnks, type3, 1)**.
- 0x806d50's first argument is the "make a time gauge" flag (0x806d8c). The buff bar passes 1
  (0x803d94). The viewer passes **0**, so **no gauge is made** and the slot is sized to the bare
  icon, 20 x 20 (0x807177..0x80719a: the gauge height is added only when `+0x388` is set).
- **So a target's buffs show no expiry bar.**
- The third argument is the skill's `lnks` (0x7fd123: row `+0x194`). It draws the frame cut from
  `window_all.ddj`. The fourth picks which UV constants that frame uses. The frame is the buff
  bar's OPEN item and is not drawn here either.
- The fifth argument (1) loads the admittance sprites. They are drawn while the slot's `+0x36c` is
  set.
- **What sets `+0x36c` (new, READ):** 0x806630 writes it from the entry's byte `+5`. 0x9d25e0 fills
  that byte from a comparison of two 32-entry arrays (0x9c7830 on the skill object's `+0x154` row
  `+0x244`, against 0x9cdf00 on the target). What the two arrays are is OPEN, so neither the
  sprites nor the tooltip's red line is drawn.
- The icon is kind 1's: the skill row's `+0x108` path (0x7ff240), the same 32 x 32 skill-window
  file the buff bar draws. srrevamp point-samples it to 20 x 20 the same way
  (`HudBuffBoard.retail_icon_image`, round 624). That the same sampler state holds for this window
  is INFERRED: its draw order was not audited as the board's was.

## Live: timer 1 and the diff (0x6993a0, 0x7fd640)

- `CIFTargetWindow::vslot_005` (0x6993a0) is its OnTimer. For timer id 1 it finds the target
  again (0x9c3220).
  - If the target is gone or is not a `CICharactor` (0xef1a5c), the viewer is cleared (0x7fbcf0).
  - Otherwise, if the viewer is shown (0xb8f530), the list is collected again (0x9d25e0) and
    0x7fd640 diffs it in.
- That the timer repeats is INFERRED: CIFStateSlot's own 100 ms timer (0x8065d0) is armed once
  with the same call and receives nine ticks.
- **The diff (0x7fd640):**
  - For each main-list node, the collected entries are searched for its skill id. A match
    refreshes the node's `+0x36c` byte (0x806630) and is removed from the collection. A node
    without one is erased at once (its window destroyed through 0xba1190), with no burst and no
    sound.
  - The second list is treated the same way for skill nodes. An abnormal node is kept while its
    bit is still set.
  - What is left of the collection is appended (0x7fd020) in order, then the abnormal bits.
  - The grid is then laid out again.
- **So an icon appears or goes within a second of its buff's start or end.** A buff that stays
  keeps its place.

## The tooltip (0x7fc260; shown by CIFStateSlot::vslot_048 0x806640)

- 0x7fd020 calls 0x7fc260(entry) for every slot. That builds the text and stores it on the slot
  (0x653dc0, the slot's `+0x210`).
- CIFStateSlot's vslot_048 (0x806640) tests whether the slot's parent is a CIFMagicStateBoard
  (0xeec928). If it is, the board's own tooltip runs (vslot 0xc4). If not, as here, the generic
  tooltip window (0x798db0) opens, 200 wide, with the slot's stored text.
- The text for a skill entry (kind 1), in order:
  1. `"%s Lv %d\n\n"`: the name (the row's `+0x124` code, resolved) and the level (the row's `+0x60`
     byte). The "Lv" is a **literal** in the format string at 0xdcf7d0, not `UIIT_STT_LEVEL_LV` as
     in the buff bar's tooltip. Twelve name codes print `"%s\n\n"`, the name alone (0x7fc412..0x7fc594,
     each compared at full length): `SN_SKILL_ASSAULTING_SOILDER`, `SN_SKILL_ELITE_ASSAULTING_SOILDER`,
     `SN_SKILL_CENTURION`, `SN_SKILL_ASSAULTING_LEADER`, `SN_SKILL_ELITE_IMPERIAL_GUARD`,
     `SN_SKILL_COMBAT_COMMANDER`, `SN_SKILL_MALL_PET_SKILL_COLD`, `SN_SKILL_MALL_PET_SKILL_FIRE`,
     `SN_SKILL_MALL_PET_SKILL_LIGHTNING`, `SN_SKILL_MALL_PET_WATCH_CHULHYEN`,
     `SN_SKILL_MALL_PET_WATCH_AGOL` and `SN_SKILL_MALL_PET_GROWTH_POTION`. This is the buff bar's
     list without `SN_SKILL_MALL_PRE_APRU_4W`.
  2. The description (the row's `+0x15c` code, resolved) plus `"\n\n"`, when it is not empty.
  3. The skill's parameter text from 0x96e480(7, ...) (the damage, range and similar lines the
     skill window's tooltip builds). **Not built by srrevamp (OPEN).**
  4. A remaining-time line only when the entry's `+0x28` is non-zero. 0x7fb0f0 zeroes it and
     0x7fd020 never writes it, so **a target's buff has no time line**.
  5. `"%s : %s"`, `UIIT_STT_TARGETTING` and the entry's name, when the name is not empty. Only
     type 3 entries have one.
- The skill id `0xc0000000` has its own branch: `"%s \n\n"`, then `"(%s)"` with
  `UIIT_TOOLTIP_OPERATION_STOP`, then the row's `+0x140` text.
- OURS: srrevamp trims the trailing blank lines, so Godot's tooltip does not draw empty rows.

## The race emblem (the kindred mark)

- `resinfo\iftw_player.txt` has `GDR_TW_KINDRED_MARK` (CIFStatic, ID 10, `Rect=3,0,24,24`, no
  DDJ) and `GDR_TWP_TEXT_NAME` (ID 1) (MEASURED). `iftw_jobplayer_trijob2.txt` has
  `GDR_TWJP_KINDRED_MARK` (ID 20) at the same rect.
- The player piece's setter 0x69b0d0 (called from the CICUser branch at 0x699e39) sets the name
  (ID 1, `"%s"` of the object's `+0x114`).
- It then sets ID 10's texture to **`FUN_0098caa0(ref +0x9c, 0)`**, where `ref` is the object's
  reference data (`+0x220`) and `+0x9c` is `_RefObjCommon.Country` (round 629).
- 0x98caa0 returns these paths:
  - Country 0 → `interface\ifcommon\com_kindred_china.ddj`
  - Country 1 → `interface\ifcommon\com_kindred_europe.ddj`
  - any other value → an empty path, so nothing is drawn
- The `…16.ddj` twins are for a non-zero second argument. The target window passes 0.
- The monster pieces have no kindred control. A monster shows its level gem instead (round 589).
- **Race for another player.** Retail reads it from the object's reference object, which the spawn
  names; it is not a packet field. srrevamp's `Gender` is its stand-in for the reference object
  (`server/internal/character/schema.go`: "RefObjID: … what srrevamp's Gender stands in for").
  The entity snapshot already carries it. The client maps it to the body code (`GENDER_BODY_CODE`)
  and that body's characterdata Country (column 14). Every playable body here is `CHAR_CH_*`,
  Country 0 (MEASURED, round 629). So no server change was needed.

## Where srrevamp's data comes from

- The server broadcasts `OpBuffStart` / `OpBuffEnd` to the owner's whole zone, and replays active
  buffs on zone entry in both directions (rounds 616 and 622, `sendBuffsInView`).
- `World3D` keeps every owner's buffs in a `HudTargetBuffs.Book`, keyed like the auras
  (`character:<id>`, `monster:<id>`) and in start order.
- An owner's entries are dropped when it leaves view or dies, and all of them on world entry.
- **Monsters:** srrevamp's server starts no buff on a monster (`OwnerKind` is always
  `OwnerCharacter` in `session/buffs.go`). So a monster's row is empty, which is what retail shows
  for a monster with no buffs. Monster buffs themselves are OPEN (a server feature).
