# Chat: the window, the channels, globals and notices

Recovered in round 634 from `sro_client.exe` (the dump in `/var/tmp/decomp_client`,
`/var/tmp/sro_client.asm`) and the Media archive's `resinfo` layouts. Labels: **READ** (the code
or data says it), **MEASURED** (taken from a picture or a texture's pixels), **INFERRED** (a
reasoned reading the code does not state), **OURS** (srrevamp's choice), **OPEN** (not known).

## The packets (retail)

| Opcode | Direction | Fields | Where |
|---|---|---|---|
| `0x7025` | C->S | type u8, index u8, [receiver string if type 2], text string | sent by CIFChatViewer's input handler `0x7ad400` (`push 0x7025` at `0x7adadd`; fields from `0x7adb20`) |
| `0x3026` | S->C | type u8; types 1, 3, 0xd: unique id u32 + text; type 7: text; others: name + text | `Chat_OnChatUpdate` `0x877810` |
| `0xB025` | S->C | 1 = ok: type, index (the client shows its own kept line); 2 = error: code u16, type, index | `0x877340` |
| `0x704c` | C->S | slot u8 (bag slot + 13), type word u16, text | the global chatting item's use, `0x7901c0` |

`client_senders.tsv` lists only CIFConsole's four senders for `0x7025`; `0x7ad400` is a fifth,
CIFChatViewer's (READ, round 634).

srrevamp keeps its own framing (`server/internal/session/chat.go`, `client/scripts/net/chat.gd`,
OURS): `0x00A5` send (type, index, target, text), `0x00A6` update (type, sender name, text --
a name even where retail sends a unique id), `0x00A7` result (ok, type, index, code u16, target),
`0x00A8` global (slot as int64, text).

## Chat types (READ)

From `0x7ad400`'s prefix switch, `0x877810`'s reader and `0x876810`'s two switches:

| Type | Channel | Typed as | Line shown (`0x876810`) | Colour (ARGB) |
|---|---|---|---|---|
| 1 | all | no mark | `name:text` | white |
| 2 | whisper | `$name text` | `name(FROM):text`; the sender's echo `target(TO):text` | `0xff9ffffe` |
| 3 | all, GM | no mark, when `0x9d4c40` (GM) | `name:text`; a text starting `;` loses it and shows as type 1, white | `0xffffaec3` |
| 4 | party | `#text` | `name(Party):text` (UIIT_CTL_PARTY) | `0xff9affd0` |
| 5 | guild | `@text` | `name(Guild):text` (UIIT_CTL_GUILD) | `0xffffb541` |
| 6 | global | the global chatting item | `name:text` | `0xffffff00` |
| 7 | notice | -- | `(Notice):text` (UIIT_MSG_NOTIFY), filed as type 3; also GDR_NOTICE | `0xffffaec3` |
| 9 | stall | -- | its own path (`0x778a10`) | white |
| 0x0a | "(ASK)" | -- | `name(ASK):text` | `0xff9ffffe` |
| 0x0b | union | `%text` | `name(Union` + text; the sender's client puts `-<guild>): ` before the text (`0x7ada5a`, `L"-%s): "`) | `0xffc2f573` |
| 0x0d | NPC | -- | `name:text` | `0xffdbadf8` |
| 0x10 | academy | `&text` | `name(Academy):text` (UIIT_CTL_TC_TRAININGCAMP) | `0xff64c7ff` |

`/` makes type `0xfe`, a command (`0x7adf70`, the client's own slash commands such as `/w`).
Before sending, `0x7ad400` refuses a party line without a party (UIIT_MSG_PARTYERR_CANT_FIND_PARTY,
`0x987070`), a guild line without a guild (UIIT_MSG_GUILD_NON_EXISTING, `0x9870e0`) and an academy
line outside one (UIIT_MSG_TC_ERROR_NOT_POSITION, `0x987140`). A lone mark (length 1) ends the
input without sending (`0x7ad7dc`). The flood block: four lines inside 4000 ms or six inside 9999 ms
end in `0x7a9bb0` (not built, OPEN). Whether the mark itself is sent is INFERRED: `0x7ad904` copies
the raw line when the split left the message empty; srrevamp's client strips it (OURS).

After a line goes out (`0x7add04..0x7ade70`): types 1 and 6 empty the box; type 3 leaves `;` if the
line began with one; a whisper leaves `$name `; party/guild/union/academy leave their mark; and on
any tab but All the box then gets that tab's mark.

R's reply (`0x7ab470`): `"$" + name + " "` (`0xdbb848`, `0xe19330`), set through vslot `0xb4`.

`0xB025` codes (`0x877340`): 3 UIIT_CHATERR_CANT_FIND_TARGET "Cannot find [%s].", 0x2006
UIIT_CHATERR_YOU_ARE_SQUELCHED, 0x2008 UIIT_CHATERR_INVALID_COMMAND, 0x200a
UIIT_CHATERR_NOT_A_PARTY_MEMBER, 0x200b/0x200c UIIT_CHATERR_ALLIANCE_PERMISSION_DENIED, 0x200d
UIIT_STT_CANT_CHATTING (formatted with 10), 0x200e UIIT_MSG_GUILD_UNION_CHAT_LIMIT. srrevamp adds
0xf001 (no guild), 0xf002 (no academy), 0xf003 (no global item), 0xf004 (empty) (OURS; the first two
show the strings the retail client shows for its own refusals).

## The window (CIFChatViewer)

Layout `resinfo\ifchatviewer.txt`, read with `UI_UPDATE_2009_FIRST` (round 585); registry
`GDR_CHAT_BOARD` 399x398.

**Tabs (READ, `CIFChatViewer::Create` `0x7ab920`).** Built in code, not in the layout: five
CIFSelectableAreas, IDs 100..104, rect `(45 + 70 i, 0, 71, 20)` (`0x7ab9bd`: `i * 0x46 + 0x2d`,
`0x47`, `0x14`), texture `interface\chattingwnd\chat_long_tab.ddj` (100x20, stretched; MEASURED),
captions UIIT_CTL_CHAT_ALL, UIIT_CTL_CHATMENU_PARTY, _GUILD, _ALLY, _TRAININGCAMP. The selected tab
gets `0x64cc30(1)`, font style 2 (`0x8b2cc0` maps flag 2 to style 2, the bold variant; drawn here
with Godot's embolden, OURS) and text state 0, white; every other tab `0x64cc30(0)` and
`0x8b4750(3)` at `0x7aa79d`, text state 3, the grey `0xffb4b4b4` the CIFStatic constructor sets for
it (`0x64d64f`, also `0x8b5759`) (READ, round 634's review). Caption centring is MEASURED from the
retail screenshot.

**The Academy caption.** The client's text loader keeps the FIRST row of a duplicated key (see
"The text table" below). The box's archive -- a private server's -- has
UIIT_CTL_CHATMENU_TRAININGCAMP "&Team" first and "&Academy" after it; the vanilla archive has only
"&Academy" (round 634's review), and the user asked for Academy. HudChat therefore keeps the
table's first row everywhere and shows the vanilla "&Academy" when that caption resolves to a known
private-server row ("&Team", "Job/Team"; `PRIVATE_SERVER_CAPTIONS`, OURS and labelled).

**Lamps (READ).** The layout's five lamps are moved to `(48 + 70 i, 6)` (vslot `0x98` at
`0x7ac098..0x7ac0f5`); the tab switch (`0x7aa690`) hides all five and shows the selected tab's.

**Tab switch (READ, `0x7aa690`).** Hides the five lists and lamps, shows the selected ones, binds
the scroll bar to the list and scrolls it to 999 (the bottom). If the input box is empty or holds
one of `# $ % & / @ ^ ~` alone (the jump table at `0x7aa9dc`), it gets the tab's mark: "", "#", "@",
"%", "&".

**What each tab files (READ, `0x7aca30`).** All: types 1, 2, 3, 4, 5, 6, 8, 0xa, 0xb, 0xd, 0x10,
0xff. #Party: 4; @Guild: 5; %Union: 0xb; &Academy: 0x10; and 2, 3, 0xa, 0xff go to all four
channel tabs too. Types it does not list (7, 9, ...) add nothing -- a notice arrives as type 3.

**Lists (READ).** 100 lines each (`+0x3a0 = 100`, `0x7abed8`; `0x64f8a0` drops the oldest). Word
wrap with a hanging indent: `0x64e930`, enabled by `+0x3cc` (`0x64e380(1)`), prefixes each
continuation line with `floor(20 / space advance)` spaces (at least one) and narrows it by as much.
That the break falls between words is MEASURED from the screenshot. The pitch is `+0x39c = 14`
(`0x638c20(0xe)` at `0x7abeb8`; the draw `0x639ab0` adds it per line), which the screenshot's 14 px
agrees with. A list shows `+0x3a4` rows, the mode's m * 4. **Lines stack from the bottom:** with
fewer lines than rows, `0x639ab0` starts pitch * (rows - count) down (`0x639d20..0x639d52`, under
`+0x3a8`, which Create sets with `0x638b50(1)` at `0x7abeee`). **The hover bar:** `+0x3c8 =
0x66ffffff` (`0x638cf0`) is a 40%-white bar under the row the mouse is over -- the mouse-move slot
17 (`0x63ad10`, enabled by `+0x3aa`) picks the row, the draw (`0x639ab0` -> `0x63b0e0`, enabled by
`+0x386`) fills it; its height is the line's text height (`+0x384` unset). Text has a one-pixel
black shadow at (+1, +1) (MEASURED: every glyph pixel's lower-right neighbour is black).

**Scroll bar (READ).** `GDR_CHAT_VSCROLL` (CIFVerticalScroll, `0,36,16,308`); its layout
`ifverticalscroll.txt`: up arrow `chat_arrow_up.ddj` at (0,-16), down arrow `chat_arrow_down.ddj`,
thumb `com_scroll_button.ddj` 16x16; its bar art `com_scroll_bar.ddj` (`0x65a9c0`). Create sets its
length to 308 (`0x7abf60` into `0x65a390`): the thumb travels `(pos - min) * 308 / (max - min)`
below the bar's top (`0x659150`), the down arrow sits at the top + 308 + 16 (`0x65a40f`), the arrows
step 1. The bar art covering the thumb's whole travel is MEASURED from the screenshot. The wheel
step (1 line) and a click on the bar (jumps the thumb, starts a drag) are OURS.

**Size modes (READ, `0x7aac20`).** The constructor starts the window at mode m = 2 (`+0x428 = 2`
at `0x7ad385`). `GDR_BTN_CHAT_SIZE` (ID 15; the event map at `0xebebf0` -> `0x7ac2a0`) steps m
through 0..6 and back to 0. For m > 0: lists m * 56 + 7 tall showing m * 4 rows, scroll length
m * 56 - 28, middle band m * 56 + 12, the bottom band at m * 56 + 37, the input row (size button,
mode button, input line) at m * 56 + 42, and the window at y = H - 0x1d3 + (6 - m) * 56 with its
bottom on the bar (height 399 - (6 - m) * 56). Mode 0 is the input row alone, 0x15 tall at
H - 0x59, the tabs hidden (`0x7a9a80(1)`), the lists, bands, scroll bar and the two left buttons
hidden. Mode 6 is the layout's geometry (the registry's 398 against the formula's 399 is a pixel
the client's own code gives). The user's retail screenshot is mode 5 (its down arrow at 304 =
36 + 252 + 16).

**Refusals before sending (READ, `0x7ad400`).** A party, guild or academy line with no such group
is refused by the client: UIIT_MSG_PARTYERR_CANT_FIND_PARTY "Cannot find the corresponding
party.", UIIT_MSG_GUILD_NON_EXISTING "Cannot carry this function out because you do not belong to
the guild.", UIIT_MSG_TC_ERROR_NOT_POSITION "You do not belong to an Academy.", and the box is
emptied (SetText "" at `0x7ad875`). srrevamp's client knows the party and guild from their info
answers; the server still refuses with its own codes.

**Not built (OPEN):** the whisper list (`GDR_WHISPERLIST`, `0x7acfd0` adds to it), the chat-mode
button and viewer (IDs 41/42), the hide button, speech balloons
(`0x9c77c0` for types 1, 3, 6, 0xd), the system message window (interface child 0x44, `0x7781b0`,
colours `0xffdbc99b` / `0xffbacff2`) -- srrevamp writes its system lines and refusals into the All
list (OURS).

## Globals (READ)

The inventory slot's use handler (IFSlotWithHelp `0x676570`) sends an item whose type word gives
TypeID4 5 under 3/3/3 to GInterfaceWndRelation `0x79b8a0`, which builds "WholeChat" (interface child
0x38, `GDR_WHOLE_CHAT`: `msgbox2_window_`, 433x239), keeps the slot (`0x7ef3e0`) and shows the
stack count as "Remaining turns" (`0x7ef400`). Layout `resinfo\ifwholechat.txt`, title
UIIT_STT_WHOLECHAT "Chat to all". Its Use (`0x7ef550`): nothing without turns; empty text ->
UIIT_STT_WHOLECHAT_INPUTMSG; filtered text (`0x8c4020`, not built, OPEN) ->
UIIT_MSG_WHOLECHATERR_NOTINUSEMSG; else `0x704c` (`0x7901c0`: sent only when the slot's type word
has `(w & 0x1c) == 0xc`, `(w & 0x60) == 0x60`, `(w & 0x780) == 0x180`, `(w & 0xf800) == 0x2800`, i.e.
TypeID 3/3/3/5); the edit box is emptied on every path. The archive's item with that TypeID is id
3851 in the box's items.csv (and eight more). The global line is type 6, yellow, All tab only.

Server side (OURS, retail's accounting of `0x704c` for this kind was not read): one item per line,
the line to every character including the sender.

## Notices (READ)

Type 7 in `0x876810`: the chat line `(Notice):text`, filed as type 3 (every tab), colour
`0xffffaec3`; and `0x777bf0` -> interface child 0x14, `GDR_NOTICE` (a CIFNotify, `ifnotify.txt`),
`0x7b3eb0`: life 7000 ms, the text measured and the window sized to it, placed at
`x = screen width / 2 - text width / 2`, `y = +0x7d4`, which the constructor `0x7b3c40` sets to 0
(no other writer found for this class): the top centre. The update `0x7b3e20` fades the alpha to
`remaining * 255 / 2000` over the last 2000 ms. Frame textures `com_notice_edge.ddj`,
`com_notice_edge2.ddj`, `com_notice_corner.ddj` (READ); all translucent maroon (128, 45, 67)
(MEASURED); their arrangement as a stretch frame over the window -- which is the text's extent --
is INFERRED; no fill of ours.

srrevamp's `/notice <text>` GM command (OURS) sends type 7 to everyone.

## The retail screenshot's colours

The colours are READ (`0x876810`). The user's screenshot, a private server's client, confirms the
byte order: its global lines are (255, 255, 0), `0xffffff00` read as ARGB. Its notice / warning
lines are (0, 174, 195):
exactly `0xffffaec3`'s green and blue bytes with the red byte zeroed, and they carry no "(Notice):"
prefix. The binary on the box says pink `0xffffaec3` and the prefix; srrevamp draws what the binary
says. Where the private client's cyan comes from (its `vsroplus_lib.dll` is the likely suspect) is
OPEN.

## The text table (READ, round 634's review)

TextStringManager `0x8cac30` loads textdataname.txt's list, textuisystem, textzonename, textquest,
texthelp and textevent into one hash map; its insert (`0x8ca120`) returns the existing entry for a
key it already holds, and the caller at `0x8cb266` ignores that -- **the first row of a duplicated
key wins**. UiTextTable now does the same (`keep_first`, default true). On the box's archive this
changes 566 of 6,937 keys in textuisystem.txt, 55 of 11,119 in textdata_object.txt and 2 of 8,005
in textdata_equip&skill.txt (`/var/tmp/chat` tool text_dupes.gd). Visible examples:
UIIT_STT_PHYSICAL_ATTACK "Phy. Atk:" (was "Phy. atk"), UIIT_STT_MAGICAL_ATTACK "Mag. Atk:",
UIIT_STT_PHYSICAL_DEFENCE "Phy. Def:", UIIT_STT_PHYSICAL_BALANCE "Phy. Balance:" (the stat panel);
UIC_STT_FONTNAME "Arial" (was "Tahoma", which was never installed -- both ended on an Arial file);
UIIT_CTL_CHATMENU_TRAININGCAMP "&Team"; login and install messages worded "SRO" instead of
"Silkroad-Online"; twelve 2013 avatar item names ("Grey Warlord Hat (M)" for "Grey Dragon Soul
Helm (M)"); about 40 rows whose first copy is Korean mangled to "?", and 24 whose first copy keeps
CSV quote marks (`"""<sml2>...`).

The rest of the loader (READ, rounds 633-635 integration review), which UiTextTable follows:

- **The service column.** A row is loaded only when column 0 reads 1 (`0xb9cc80(0, 1)`, then
  `cmp eax,1; jne` at `0x8cb110..0x8cb118`). The continuation lines of a value that spans lines
  fail it and never become keys.
- **One column, as it stands.** The value is the field at column `0x8c5370(language)` -- 2 for
  language 0, 8 by default, 9 for language 5, and so on. `0x8c6a90` compares a first-choice
  column's field with L"0" (`DAT_00e1804c`) and falls back to the second column when it is empty
  or "0"; but the CGame loads (`0x849215..0x8493ad`) pass -1 as the first choice and `0x8cace6`
  sets that slot to -1, so only the second is ever read, and its field is kept whatever it holds.
  A key whose first row has no English therefore shows that column's "0" filler (or nothing):
  the box's Rebecca Event Hats read "0". UiTextTable still picks the English column by content
  (column 8, else the first Latin field after it), which gives the client's column on every
  displayed key checked; for a row with no Latin text it keeps column 8's field, not the Korean
  column 2 or the token.
- **No quote handling.** Fields split on tab, CR and NUL only (`0xb9d580`), so a CSV-quoted field
  reaches the client with its quotes, as it reaches ours.
