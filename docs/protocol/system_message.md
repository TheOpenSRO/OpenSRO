# The system message window, and the quick-slot bar's save

Recovered in round 639 from `sro_client.exe` (the dump in `/var/tmp/decomp_client`,
`/var/tmp/sro_client.asm`) and the Media archive's `resinfo` layouts. Labels: **READ** (the code
or data says it), **MEASURED** (taken from a picture or a run), **INFERRED** (a reasoned reading
the code does not state), **OURS** (srrevamp's choice), **OPEN** (not known).

## The window (READ)

Interface child **0x44** (68) is ginterface.txt's `GDR_SYSTEM_MESSAGE_VIEW`, a `CIFSystemMessage`,
rect `0,552,350,126`, no SubSection. Its Create (`0x7bc150`) loads `resinfo\ifsystemmessage.txt`
(the string at `0xdc845c`) and fetches, by ID:

| Member | ID | Layout name (the file's own spelling) | Class | Rect | Art |
|---|---|---|---|---|---|
| +0x378 | 13 | GDR_SYETEM_MESSAGE_CHATOPTION_BTN | CIFButton | 337,0 | `chattingwnd\chat_filter_button.ddj` |
| +0x37c | 15 | GDR_SYETEM_MESSAGE_SIZE_BTN | CIFButton | 337,265 | `chattingwnd\chat_zoom.ddj` |
| +0x380 | 50 | GDR_SYETEM_MESSAGE_OPTBOARD | CIFChatOptionBoard | 207,-155,144,156, Style 0x40 | `ifcommon\window_all.ddj` (UV) |
| +0x388 | 24 | GDR_SYETEM_MESSAGE_VSCROLL | CIFVerticalScroll | 337,37,16,195 | the chat's arrows and bar |
| +0x384 | 19 | GDR_SYETEM_MESSAGE_TEXTBOX | CIFTextBox | 10,15,316,252 | -- |
| -- | 7, 6, 5 | GDR_SYETEM_MESSAGE_BG_DOWN / _MID / _UP | CIFStatic | 0,281,335,4 / 0,4,335,277 / 0,0,335,4 | `chattingwnd\chat_window.ddj` in thirds |

The text box (`0x7bc216..0x7bc2c9`): its owner pointer +0x1ec is the window; pitch 14
(`0x638c20(0xe)`); 100 lines (`+0x3a0 = 0x64`); `+0x3a4` rows = mode * 3; `0x638b50(1)` (lines
stacked from the bottom, as the chat); `0x64e380(1)` (the wrap with the hanging indent);
`0x638d40(1)` (+0x385, not identified -- OPEN); the scroll bar bound through the box's +0x36c
object; the bar's range set by `0x65a390(0xc3, 0, 0, 1)` and scrolled to 999. The chat's Create
also sets a hover colour (`0x638cf0`); this one does not, and srrevamp draws no hover bar here
(INFERRED that none shows without it). The two buttons get tooltips UIIT_STT_MESSAGE_FILTERING
(`0xdc8424`) and UIIT_STT_TOGGLE_CHATING_WINDOW_SETING (`0xdbbbb0`).

**Size modes (`0x7b87a0`, called from Create and on a resolution change, `0x79f030`).** The
constructor `0x7b8450` sets mode m = 2 (+0x370) and 6 rows (+0x374). The size button (ID 15; the
message map at `0xebf330` runs `0x7b89c0`) adds one and wraps 7 to 1, so the modes are 1..6.
With the screen W x H:

- the window at x = W - 0x165 (357), y = H - 0x177 (375) + (6 - m) * 42, height (H - 0x5a) - y --
  its bottom at H - 90 in every mode, 285 - (6 - m) * 42 tall (117 in mode 2);
- the scroll bar's length and height m * 42 - 57 (`0x65a500`, vslot 0x54), scrolled to 999; with the
  frame shown (+0x36c) it is hidden in mode 1 (`0x7b888e`);
- the text box 316 x m * 42, m * 3 rows;
- BG_MID (ID 6) m * 42 + 25 tall, BG_DOWN (ID 7) moved right under it, the size button
  bottom-aligned to BG_DOWN.

Mode 6 is the layout's own geometry (285 = 4 + 277 + 4; 195 = 6 * 42 - 57). MEASURED on the box
(1280x720): the window at (923, 513) 350x117 in mode 2, and the size button stepping 2 -> 3 -> 4
-> 5 -> 6 by real clicks.

**The frame's visibility (`0x7b84e0`).** It shows or hides children 5, 6, 7 and the two buttons
and keeps the state at +0x36c. Create calls it with `settings+7 == 0` (`0x4f9d00`); with that
option set, CGInterface's update (`0x77b385..0x77b3db`) shows the frame only while the mouse is
over the window (`0x7b85a0`). Which option +7 is, and its default, are OPEN; srrevamp always shows
the frame, as the user's screenshot does.

**The filter board.** The filter button's handler `0x7b8680` shows the board when it is hidden and
hides it otherwise. `CIFChatOptionBoard::Create` (`0x7a95f0`) loads `resinfo\ifchatoptionboard.txt`:
five checkboxes kept at +0x36c..+0x37c, IDs 10..14 -- GAIN (UIIT_STT_CHATTING_GAIN_MSG), FIGHT
(UIIT_STT_CHATTING_BATTLE_MSG), STATUS (UIIT_STT_CHATTING_STATE_MSG), PARTY
(UIIT_STT_CHATTING_PARTY_MSG), GAME (UIIT_STT_CHATTING_GAME_SYS_MSG) -- and reads five bytes from
`%s\Setting\chop.dat` (`0xdbb6a0`, mode "rb+") into them. A checkbox starts checked (the
constructor `0x656c70` sets +0x36c = 1); with no file only FIGHT is unchecked (`0x7a9779`). The
board is **not built** here (OPEN: its checkbox art is set in code, not read); the filter button
only logs, and the filters stay at the no-file defaults.

## Adding a line (READ)

`0x7781b0(type, text)` fetches child 0x44, asks `0x7b85f0(type)` and, when it passes, calls the
window's `0x7b89e0(0xff, colour, text, 0, 1)`, which adds the line to the text box
(`0x64f8a0(text, 0, colour, colour, colour, 0, 1)`). `0x778210(iface, type, format, ...)` is the
same after a `vswprintf` into 0x400 wide characters. `0x778190(category, code, colour, filter,
flag)` is the error-code path: `0x7b8b40`'s 643-case switch turns a server code into its message
(docs/protocol/error_codes.md) and hands it to `0x7b89e0` -- 222 of its 223 callers pass
`0xffdbc99b`. `0x778280` takes a caller's colour; its 17 callers are GM and debug lines.

| type | passes when | colour |
|---|---|---|
| 0 | always | `0xffdbc99b` |
| 1 | GAIN checked | `0xffdbc99b` |
| 2 | FIGHT checked (not by default) | `0xffdbc99b` |
| 3 | STATUS checked | `0xffdbc99b` |
| 4 | PARTY checked | `0xffdbc99b` |
| 5, 7 | GAME checked | `0xffdbc99b` |
| 6 | always | `0xffbacff2` |
| anything else | never (the switch's default) | -- |

The colour is `0x7781b0`'s: `if (type == 2 || (c = 0xffbacff2, type != 6)) c = 0xffdbc99b`.
MEASURED against the user's JPEG: the "[Guide]" lines read bluish (about 195, 205, 212), the kill
and appearance lines tan-white (about 200, 200, 176) -- consistent with the two colours over the
translucent frame, not a measurement of them.

**Who writes what (a census of every direct call: 457 of `0x7781b0`, 50 of `0x778210`, 17 of
`0x778280`, and the 223 of `0x778190`; `/var/tmp/syslog/census2.tsv` on the box. The type is an
immediate at 428 of the 507 typed sites; the other 79 pass it in a register, not resolved).**

- Type 1: `Client_ApplyExpAndLevelUp` (`0x8a97c0`) -- UIIT_MSG_STATE_GAIN_EXP "[%I64d]Experience
  Points gained." when the EXP is above 0 (`0x8a9a45..0x8a9a76`), UIIT_MSG_STATE_LOSE_EXP for a loss
  (`0x8a9b76..0x8a9baa`), UIIT_MSG_STATE_GET_SKILL_EXP "[%u]skill experience point gained." when
  the skill EXP is above 0 (`0x8a9cd1..0x8a9cfa`); the ground-item handler `0x87ba20` --
  UIIT_MSG_STATE_GAIN_GOLD "[%d]gold gained." for the gold kind 0xfe (`0x87bef4..0x87bf20`) and
  UIIT_MSG_STATE_GET_ITEM_(NON)EXPENDABLE for items; the job EXP lines (`0x884dd0`); the COS
  pet's EXP (`0x8aa340`).
- The level-up line is **not** a system line: UIIT_MSG_STRGERR_LEVEL is `swprintf`'d (`0x8a9bd3`,
  0x80 characters, so "level [40]." keeps its brackets) and handed to `0x77b580`, which shows it on
  interface child 0x23, `GDR_WARNING_WND`, a CIFNotify (`0x7b3eb0`), like GDR_NOTICE.
- Type 3: UI_STATE's curse release (`0x7836d0`).
- Type 4: UI_PARTY `0x886b10` (UIIT_MSG_PARTY_JOIN "[%s]joined the party.", _LOGOUT, _SECEDE,
  _BOOTED, _BROKEN, _HOST_ROLE_DELEGATED); the chat's own refusals (`0x7ad400`: party, guild and
  academy share the one `push 0x4` at `0x7ad866`); party matching and the academy's.
- Type 5: equip refusals (UIIT_MSG_STRGERR_EQUIPITEM), the drop warnings, socket and deal lines,
  job guild joins.
- Type 6: one caller, CGInterface's vslot 5 (`0x789e53`), a text from `[+0x774]` -> `0x814120`
  gated by the option byte `0x4f9d00[0]` -- INFERRED to be the "[Guide]" tips of the screenshot.
- Type 8: `0x89dbf0`'s server-event line, which the switch never passes.
- Type 0: most refusals and notices, the chat's server refusals (`0x877340`, one `push 0x0` at
  `0x877798` for every 0xB025 code), the "Chat to all" refusals (`0x7ef550`), the camera-view
  line (`0x780420`), the unique monsters' death and appearance lines (`0x874ea0`,
  UIIT_MSG_DEAD_UNIC / UIIT_MSG_ANYONE_DEAD_UNIC; the register type not resolved), and a great
  many debug and GM lines.
- The live quick-slot bar (CNIFUnderMenuBar, `0x60a000..0x60efff`) writes no line when a slot is
  filled: none of the four adds is called there.

## What srrevamp writes where (round 639)

`World3D._log_system(text, type)` writes to the window; the chat's All list no longer gets system
lines. With retail's own message and type:

| Line | Type | Source |
|---|---|---|
| "[N]Experience Points gained.", "[N]skill experience point gained." | 1 | the kill's OpAttackResult tail (below); READ strings and conditions |
| "[N]gold gained." | 1 | the pickup result (READ string; until now "Picked up N gold.", ours) |
| "item [..]gained." | 1 | the pickup and loot results (READ strings, round 614) |
| "[name]joined the party." | 4 | the party join push (READ string) |
| "A party member left (character #N)." | 4 | ours: the push carries no name for UIIT_MSG_PARTY_SECEDE |
| the chat's party/guild/academy refusals | 4 | HudChat.system_sink (READ) |
| the chat's server refusals, the global chat's refusals | 0 | READ |
| the camera-view line (F9) | 0 | READ |
| the server's refusals (attack, skill, use item, composite, teleport, pickup) | 0 | retail's path is `0x778190` with a code; srrevamp's server sends English text (OURS wording) |
| "You have advanced to level [N]." | -- | GDR_WARNING_WND (HudNotice, top centre), READ; the class's y is round 634's reading for GDR_NOTICE, no writer for this instance looked for (OPEN) |

OURS, type 0: the help and developer hints at login ("Type /help ...", "Developer tools ...
Ctrl+F1", "Debug panel ... Ctrl+F3", "Stuck in a wall ... /unstuck"), "Developer tools shown/
hidden", the console and GM replies, "Quickslots are full.", "You have not learned that skill
yet.", the dead-input line, the ground-pick hints for self/ground casts, "Select a target first",
"The skill's data is still loading", "X entered/left the zone", "Berserk!" and its refusal, the
death line, "Revived.", "Recovered ...", the quest, trade, friend and guild lines, "Screenshot
saved", the unstuck lines and the debug panel's lines. **Removed**: "Assigned skill to quickslot
N ..." and "Put the item on quickslot N." -- retail writes nothing there; they go to the log file
only.

**The kill's EXP (OURS carrier, READ lines).** Retail's EXP arrives in its own packet
(`0x8a97c0` reads 4 bytes, an s64 EXP, an s64 skill EXP and a flag byte, then optional parts; the
opcode was not looked up). srrevamp appends two s64s to
OpAttackResult after the targetType byte: ExpGained and SkillExpGained, what the server granted
(`session.AttackResult`, `CombatNet.AttackResult.exp_gained / skill_exp_gained`). The skill EXP is
the disclosed M = 1 of `combat.go` (a kill's skill EXP is not recovered). Quest rewards' EXP writes
no line yet (OPEN).

## The quick-slot bar's save (READ; ours is client-side)

Retail keeps the bar **on the server**:

- **Save.** CNIFUnderMenuBar `0x60bea0` (and IFUnderBar's dead copy `0x68cec0`) sends packet
  **0x7158** on every change: a byte, the slot (0..50; `cmp bl,0x33` asserts MAX_QUICKSLOT at
  `0x68ceed`), the slot's kind (`0x666720`) and a u32 -- the skill id (`0x666730`) for a skill,
  the **bag slot** (`0x666800`, bounded by the bag's size `0x6af600`) for an item, a pet slot
  (< 0xd or < 5) for the COS kinds.
- **Load.** The character-data handler `0x8ab0e0` calls `0x8a7c50`, which reads a u8 flag
  (`!= 7` sets 0xef1b64), a u8 count and count x 6 bytes {u8 slot, u8 kind, u32 data} into
  0xef1b68 / 0xef1b6c; CNIFUnderMenuBar `0x60b260` fills the 51 slots from it. `0x8a7bd0` right
  after it reads the auto-potion settings (0xef1b70..0xef1b76).
- **Moved items.** `0x60c430` re-binds a moved item.
- `Setting\SRExtQSOption.dat` / `SRExtQSOption2.dat` exist on the box but are not the slots
  (not read further).

srrevamp (OURS, the user's request): `HotbarStore` writes `user://quickslots.cfg`, one entry per
`server:port/character` (percent-encoded), holding every skill slot (id, Basic_Code) and item slot
(item id, bag slot) on every page and the "m" slot, on every change; World3D restores it once the
bar exists and re-resolves each item against the bag when the inventory arrives -- its saved slot
first, as retail binds it, then the same item anywhere, else the binding is dropped. MEASURED on the
box: 4 skills (slots 1, 3, 5 and page 2's 12) and a potion (slot 7) put on by real mouse drags came
back after the in-client Restart and after a new process, and key 7 used the potion.
