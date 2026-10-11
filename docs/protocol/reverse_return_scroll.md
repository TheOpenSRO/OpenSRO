# The reverse return scroll (and the return scroll it depends on)

Round 778. Everything here was read from `sro_client.exe` (the client Ghidra project
`sro_client_re`, the dump `/var/tmp/decomp_client`, the disassembly `/var/tmp/sro_client.asm`) and
`SR_GameServer.exe` (`/var/tmp/decomp_server`, `/var/tmp/srv.asm`) on the render box, and from
the Media.pk2 tables there. Each fact is labelled: **READ** (the binary or the archive says so),
**MEASURED** (a run on the box), **INFERRED** (the evidence points there, nothing states it),
**OURS** (this project's choice), **OPEN** (not settled).

OpenSRO's implementation: `server/internal/session/scroll.go` (the use, the cast, the move),
`server/internal/character/returnpoints.go` (the two stored points),
`server/internal/teleport/optional.go` (the map points), `client/scripts/ui/hud/reverse_return_box.gd`
(the box), `client/scripts/ui/hud/hud_worldmap.gd` (the map's selection mode),
`client/scripts/worldmap/optional_teleport_reader.gd` (the table).

## 1. The items (READ, `itemdata_*.txt`)

| ID | CodeName128 | TypeID | Param1 | Param2 |
|---|---|---|---|---|
| 3795 | `ITEM_MALL_REVERSE_RETURN_SCROLL` | 3/3/3/3 | 1000 | 1 |
| 24449 | `ITEM_EVENT_REVERSE_RETURN_SCROLL` | 3/3/3/3 | 1000 | 1 |
| 36772 | `ITEM_EVENT_RENT_REVERSE_RETURN_SCROLL` | 3/3/3/3 | 1000 | 1 |
| 62530 | `ITEM_MALL_REVERSE_RETURN_SCROLL_SPECIAL` | 3/3/3/3 | 1000 | 1 |

The ordinary return scrolls are 3/3/3/1 (`ITEM_ETC_SCROLL_RETURN_01` Param1 30000, `_02` 15000,
`ITEM_MALL_RETURN_SCROLL_HIGH_SPEED` 1000, the two `_THIEFDEN_` rows).

- The client's own test for the kind is `FUN_0078e870`: `(tid & 2) == 0`, `(tid & 0x1c) == 0xc`,
  `(tid & 0x60) == 0x60`, `(tid & 0x780) == 0x180`, `(tid & 0xf800) == 0x1800` -- 3/3/3/3 (READ).
- The SPECIAL row's tooltip promises five choices ("Move to a party member", "Move to a previously
  saved location"); those and the `VPLUS_UI_REVERSE_*` texts in this archive's textuisystem.txt
  belong to a private-server add-on, not to this client binary, which builds the same three-choice
  box for every 3/3/3/3 item (READ: no other path tests the kind).

## 2. The client: the box (message box kind 0x21)

**Opening (READ).** A bag item's use goes through `IFSlotWithHelp::FUN_00676570`; for TypeID3 3 it
switches on `tid >> 0xb` at 0x676a8e: case 3 (the reverse scroll) opens message box kind **0x21**
(`push 0x21 ... call 0x6ec5d0` at 0x676abe) instead of sending the use; case 5 is the global chat
item (round 634). Kind **0x24** is the same box opened from two other places (0x7ae963, 0x7b00c3).

**The box (READ, `UI_SILKMALL::FUN_00644c90` case 0x21/0x24, asm 0x647dff..0x648114).** A
CIFMessageBox (`resinfo\ifmessagebox.txt`, frame `interface\messagebox\msgbox2_window_`):

| What | Where | Text key (English column) |
|---|---|---|
| size | 300 x 204 (`push 0xcc; push 0x12c`, vslot 0x54) | |
| title | the box's own SetText | `UIIT_STT_CONFIRM_BOX` ("Confirmation window") |
| message (+0x840) | (0x1b, 0x30), 246 x 20 | `UIIT_MSG_QUESTION_SILKMALL_ITEM_USE_REVERSE_PORTAL` ("Select the location used by the reverse return scroll.") |
| +0x800, control 200 | (0x19, 0x4c), 252 x 24 | `UIIT_MSG_ITEM_USE_REVERSE_PORTAL_RETRUN_TO_LAST_RETURN` ("Move to the last recall point.") |
| +0x808, control 202 | (0x19, 0x6b) | `UIIT_MSG_ITEM_USE_REVERSE_PORTAL_RETRUN_TO_LAST_DEATH` ("Move to the place where you died.") |
| +0x80c, control 203, created here (class 0xee9828, font colour 0xfffefbd8) | (0x19, 0x8a) | `UIIT_CLT_REVERSE_RETRUN_SCROLL_TO_APPOINT_CHANGE` ("Move to certain location at the map.") |
| +0x804, control 201 | (0x19, 0xa9) | `UIO_COMMON_CTL_CANCEL` |

All four buttons get `interface\ifcommon\com_return_button.ddj` (with its `_focus`, `_press`,
`_disable`). 200, 201 and 202 are MsgBoxINIF's `GDR_MBIN_BTN_OK`, `_CANCEL` and `_CERTIFY`
(ClientRect 0,6,0,0, FontColor 254,251,216, HAlign 1).

**The buttons (READ).** The box's message map (.data 0xeb5e70.., read with objdump: entries of 0x28
bytes, ids at +8/+0xc, handler at +0x18 filled by 0xd6a820) sends 200 to 0x63b6e0 (result 1), 201
to 0x63b8b0 (result 0), 202 to 0x641eb0 (result 2), 203 to 0x63b9a0 (result 3). `FUN_00777dd0`
hands the result to `FUN_00797d90`, whose case 0x21 (0x798862..0x7988d8) sends the use
(`SendItem_HandleUseItem` 0x796660) with option **2** for result 1, **3** for result 2 and **7** for
result 3, and nothing for 0; then the box is destroyed (`FUN_006ec860`).

**Result 3 (READ, 0x63b9a0).** The box records result 3, hides itself, shows the world map (window
0x1c, `FUN_00799920`) and calls `CNIFWorldMap::0x622dd0(1, box kind)`: the selection mode below.

INFERRED: control 203's text alignment (the created button's defaults were not read; the layout's
centred alignment is used) and that MsgBoxINIF's MESSAGE1 static is +0x840 (its look is used).
OURS: the box is centred on the screen.

## 3. The client: the world map's selection mode

**Entering (READ, `CNIFWorldMap` 0x622dd0(1, kind)).** +0x9990 = 1, +0x9994 = the box's kind;
auto-move off (`0x616b80(0)`); the world map shown (`NIFWorldMap::0x622b60(0, 0)`); a small window
returned to the big size (`0x61ca20` when +0x97cc == 1); the size button 7, the world button 6, the
floor spinner 4 and the auto button 20 hidden (+0x9814 / +0x9818 / +0x999c / +0x981c, the ids
OnCreate 0x620f70 fetches); the view centred (`0x61cc30`); timer 0xd started at 500 ms
(`FUN_00b93320(0xd, 500)`). Leaving (0x622dd0(0)): 20, 7 and 6 shown, the popup hidden, the timer
stopped.

**The icons (READ).** `GlobalDataManager::FUN_00927850` builds the list at +0x985c from every
refoptionalteleport row whose map-point byte (+0x54) is 1. `0x6192f0` loads, for each,
`interface\worldmap\map\xy_returnicon.ddj`, its `_focus` and its `_press`. The render (vslot_013
0x624380) draws them only in this mode (`FUN_0061e270`): a quad of half-side 16.0 (the double at
0xe1b8e0) centred on x = ((rid & 0xff) - 0x87) * 0xc0 + px / 10, y = ((rid >> 8) - 0x5c) * 0xc0 +
pz / 10 (the player marker's transform), less 0.5 (0xe1b7d0). The plain texture is drawn with the UVs
at +0x9864, which timer 0xd (vslot_005 0x6191d0) swaps every tick between u 0..0.5 (+0x98c4) and
u 0.5..1 (+0x9924) -- a two-frame blink of the 64 x 32 atlas; `_focus` (under the mouse, WM_MOUSEMOVE)
and `_press` (picked, +0xc0 = 1) are drawn whole.

**A click (READ, vslot_017 0x623220).** A press hides the popup and clears every pick. A release on
an icon (strictly inside its quad) picks it and fills the popup (+0x9984, a `CIFButtonPopup`,
created hidden by 0x6192f0 with id 30): cleared (0x631bc0), then for a row whose group (+0x50) is -1
one button for the row, else one button per row of that group whose map-point byte is not 1
(`FUN_0094d270` reads the group map, 0x6236e2..0x623761). Each button (0x631d60) is 155 x 22
(`push 0x16; push 0x9b`) at y 1 + 22 * i on `interface\worldmap\map\map_return.ddj`, captioned with
the row's zone key through the text tables (0x8c9c30). The popup is shown with its corner at the
icon's lower-left vertex (+0xa8 / +0xac). A release off every icon hides it. In this mode a release
never opens a sign's map (the release returns at 0x6237fb).

**A popup button (READ, 0x60f5f0).** +0x998c = the row's id; the box of kind +0x9994 is found and
its result 3 run (`FUN_00777dd0`, which sends the use with option 7 and the id: the sender reads the
map's +0x998c through `FUN_0060f650`, 0x7977d6); the map is hidden.

**Hiding the map meanwhile (READ, vslot_023 0x624550).** In this mode a hide destroys the box of
kind +0x9994 (`FUN_006ec860`) -- nothing is sent -- and leaves the mode.

OURS: the popup buttons' caption colour and alignment (white, centred).

## 4. The wire

**Retail (READ).** The use is 0x704C: `u8 slot + 13`, `u16` the item's type word, then for a
reverse return scroll `u8 option` (2, 3 or 7) and, for 7 with a point chosen, `u32` the
refoptionalteleport id (`SendItem_HandleUseItem` 0x796660's `param_3 != -1` branch). The reply
0xB04C: a u8 result; on anything but 1 a u16 code, shown under category **1**
(`Item_OnUseItemResult` 0x87a7b0 -> `FUN_00778190(1, code)`, 0x87b665..0x87b689).

**OpenSRO (OURS, `docs/protocol/PROTOCOL_DECISION.md`'s rule).** The request is OpUseItem 0x008a,
`string name, i64 slot`, followed for a reverse scroll by `u8 option` and, for 7, `u32 LE id` --
retail's tail. The reply OpUseItemResult 0x008b gains `u16 code, u32 cast_ms` after the berserk
tail; an older decoder stops before them.

## 5. The server

**The use (READ, `CGItemExpendable::vslot_307` 0x49b9f0, the DoJob of TypeID3 3).** A user whose
logout byte is not 1 is refused 0x186b first. Case 1 (the return scroll) is `FUN_004a0380(Param1,
Param2, ...)`, case 3 (the reverse scroll) `FUN_004a00c0(Param1, Param2)` with the request stream in
EAX. The item is spent when the use answers 1 (DoJob's `LAB_0049af45`), i.e. before the delay.

**FUN_004a00c0's refusals, in order (READ, asm 0x4a00c0..0x4a0371):**

| Test | Code | Name (category 1, READ through the jump table) |
|---|---|---|
| the user's world allows it (`FUN_005f85a0`, the world record's +0x20 byte) | 0x18f5 | `UIIT_MSG_ITEM_USE_REVERSE_PORTAL_RETRUN_TO_INS` |
| the user's world is not special (`FUN_005f6c90`, world vslot 0x78) | 0x187a | `UIIT_MSG_COSPETERR_CANT_USEITEM` |
| no quest blocks the job (vslot 0x244(0x20000)) | 0x185f | `UIIT_MSG_STRGERR_REQUESTED_JOB_BLOCKED_BY_QUEST` |
| no scroll already working (vslot 0x120, the state 0xb byte) | 0x185d | `UIIT_MSG_STRGERR_PREV_TELESCROLL_ALREADY_WORKING` |
| not a murderer (chardata +0xc == 2) | 0x1875 | `UIIT_MSG_STRGERR_MURDERER_CANT_USE_PORTAL_SCROLL` |
| no trade cart (vslot 0x2ec) | 0x185e | `UIIT_MSG_STRGERR_CANT_TELEPORT_WITH_CART` |
| option 2: a recall point (`FUN_004e0130`, charData +0xcc != 0) | 0x1885 | `UIIT_MSG_STRGERR_CANT_FIND_LAST_TELEPOS` |
| option 3: a death point (`FUN_004e01c0`, +0xdc != 0) | 0x1886 | `UIIT_MSG_STRGERR_CANT_FIND_LAST_DIEDPOS` |
| option 7: the record (`FUN_004a1f00`, the ref manager's +0xa8c) with a region | 2 | (outside category 1's switch: the client shows nothing) |
| option 7: the level (`FUN_004a1ed0`, +0x2e / +0x30) | 0x18fd | `UIIT_MSG_INTERACTION_FAIL_OUT_OF_REQUIRED_LEVEL_FOR_TELEPORT` |
| any other option | 2 | |
| the destination world takes the user (world vslot 0x54 = `CDataDrivenGameWorld::vslot_021`) | 0x18f5 | |
| a fortress world (vslot 0x7c): job mode 4, no siege | 0x18e9 / 0x18f2 | `UIIT_MSG_FORT_PORTALSTONE_FAIL_02` / `UIIT_MSG_FORT_ETC_ERROR_WRONGACTION_FORTWAR` |

Then the scroll state starts (`FUN_004e0b50` at 0x4a0351, `SetCharacterState` kind 0xb): the value
(Param2 == 0) + 1, sub-kind 3, the delay `(float)Param1`, the option, and for 7 the record; the use
answers 1 and logs `GameEventLog(0xb, 4, option)`.

**The move (READ, `AJStateChanger::vslot_002` case 0xb).** When the delay runs out the destination
is resolved *then*: option 0 (the return scroll) `GObjPC::Revive(0)`, the return-point move; 2 and
3 read the stored point again (abandoning on 0); 7 copies the record's region and x/y/z words as
floats and its world (`FUN_004076f0`) -- the point exactly, no scatter; vslot 0x378 warps; the state
returns to 0. A character locked at expiry (chardata +4 == 1) waits another 1.0.

**The recall point (READ).** `CGObjPC::SaveCurPosAsLastTelPosition` (0x4e0250, vtable slot 153)
copies the current region (+0x94), position (+0x98..+0xa0) and world (+0xec) into +0xcc..+0xd8 and
+0xee, when the world allows it (`FUN_005f85a0`). The ordinary return scroll calls it when used
(0x4a055d), as do a siege dungeon's entry and some quests -- so "the last recall point" is where the
last return scroll was read. The reverse scroll does not set it.

**The death point (READ).** `GObjPC::FUN_004e0330` copies the same fields into +0xdc..+0xe8 and
+0xf0, called from CGObjPC vslot_306 (0x529b10) on death when the world's vslot 0x78 is 0.

**The delay's unit: OPEN.** The PC's job manager (pc+0x1d8, `0x4a6990 -> 0x4065d0`) counts a job
down by the elapsed GetTickCount milliseconds divided by 1000.0 (`fdiv` 0x406605) -- seconds, as
berserk's 60.0 and a GM warp's 5.0 (0xb45b28) are. Read literally, Param1 1000 is 1000 seconds; but
the high-speed return scroll's tooltip (also Param1 1000) says it "returns to the town immediately"
and the beginner scroll's (30000) "time consuming". **OURS:** Param1 is milliseconds -- one second
for every reverse return scroll.

## 6. The table (READ, `server_dep\silkroad\textdata\refoptionalteleport.txt`)

19 tab-separated fields, 39 serviced rows in this archive (MEASURED). The client's parser
(`Client_LoadRefDataFile` case 0x4e, 0x956ba0..0x956d56):

| Column | Field | Record |
|---|---|---|
| 0 | Service (a 0 row is not parsed) | |
| 1 | ID | +0 |
| 2 | object name (Korean) | |
| 3 | zone name key (`SN_ZONE_*`; `xxx` on a flag row) | +0x20 |
| 4 | region id (negative: a dungeon) | +0x3c |
| 5..7 | x, y, z (region-local; dungeon space in a dungeon) | +0x40..+0x48 (floats) |
| 8 | world id | +0x4c |
| 9 | region group (-1 alone) | +0x50 |
| 10 | map point (1: an icon) | +0x54 |
| 11, 12 | level min, level max | not read by the client |
| 13..18 | three param / description pairs (-1 / xxx in every row) | not read |

Columns 11/12 as the level range are **INFERRED**: the server's `FUN_004a1ed0` tests two words at
+0x2e / +0x30 only when both are non-zero, and the values are 0 0 on the towns, 50 999 on the
Donwhang cave's floor and 90 999 on the Arabian rows. Which rows are map points, and the groups:

- 38 of the 39 rows are map points (MEASURED). Row 29 (the Donwhang cave's entrance, `xxx`, group 1)
  is a flag; row 30 (`SN_ZONE_23002`, "Donwhang Stone Cave", region -32767 = 0x8001, (1115, 0,
  -935), level 50..999, map point 0) is the one row under it -- the floor a click on the flag lists.
  Row 31 (the Qin-Shi tomb's entrance, group 2) is a flag with **no** row under it in this archive
  (ids 32..38 are absent), so its popup is empty, as the client's would be.
- No row is country-limited in the table (OPEN: whether the server tests a race; this binary's path
  above has no such test. `REVERSE_INVALID_COUNTRY_ERROR` in textuisystem.txt is the add-on's).

OpenSRO exports it as the teleport directory's optional fifth CSV, `optionalteleport.csv`
(`export-refdata -mode teleport ... refoptionalteleport.txt`); the client reads it from the archive.

## 7. What OpenSRO models and what not (OURS)

- One game world, no PK, quest blocks, trade carts or fortresses: those refusals have nothing to
  refuse. A destination OpenSRO cannot place (another world, a dungeon it does not serve) is
  refused with 0x18f5, the world test's own code.
- A cast whose character died, left the world or came back on another session is dropped.
- The return scroll is modelled to the extent the reverse scroll needs: its use records the recall
  point and its cast takes the character to its return point (`returnPointFor`). The thief-den
  scrolls stay refused.
- No 0x30bf broadcast of the scroll state; clients learn of the move from the zone change.

## 8. Verification (MEASURED, round 778)

- Server: `go test ./internal/session -run Round778` drives a logged-in character over the wire:
  the map option to a field point and to the dungeon floor lands on the table's point exactly; a
  return scroll records its use point and option 2 brings the character back there; option 3 lands
  where it fell (field and dungeon); each refusal carries its code and spends nothing; one scroll at
  a time.
- Client: `scripts/ui/hud/reverse_return778_test.gd` (the reader, the box's layout and options, the
  map's icons, blink, hover, pick, popup and cancel, the wire).
- Live, on the render box (`/var/tmp/r778-rrs/rrs_shot.sh`): a level-60 character at Jangan's spawn
  opened the box, pressed the map button, picked the Donwhang cave flag (popup: "Donwhang Stone
  Cave"), chose it; the server logged `scroll cast ... option=7 point=30 delay=1s` and one second
  later `scroll warp ... zone=dungeon/32769 x=1115 y=0 z=935`, and the client built
  `Dunhwang_Cv.dof` and stood the player at local (1115, -935).
