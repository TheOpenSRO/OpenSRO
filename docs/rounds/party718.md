# Round 718: the user's party-matching report -- the stale listing, the ticked borders, the low digits, the Purpose value

The user's report (2026-10-04), with a screenshot of OpenSRO's Party Matching window
(`/root/opensro-handoff/party_refs/bug2_tcT9woa.png`) against their screenshots of the original
(`02_BQfjkpc.png`, `06_ZQRvaFg.png`, `07_YbXSuv5.png`):

> the name input field, the bottom border appears inaccurate. It shows vertical lines when it
> should be horizontal. The same goes for the bottom of the window for the party listings and
> level input fields. Also the numbers should be centered in the black boxes but they're too
> low. Also in the purpose tab the original game has the text aligned to the right and then
> hides the left of the text that would overflow ... let's replicate it for now. I also found a
> bug ... if I character add a party to listing while viewing the party matching then have a
> player leave and join (the party is supposed to be removed from matching and it was) and that
> new player creates a party in party matching so you see two parties. You can delete the first
> because it says it doesn't exist anymore and even hitting refresh or reopening the window does
> fix it.

Read as: the stale first entry **cannot** be deleted ("doesn't exist", `0x2c1c`), and Refresh or
reopening does **not** clear it. Labels: READ, MEASURED, INFERRED, OURS.

## 1. The stale listing: the client never let go of its own registration

**Cause (READ).** OpenSRO's `PartyMatchState` keeps the player's own registration pinned to the
top of the list (`0x97b950`) and cleared it only on a `0xb06b` for its own number or an empty
page. Nothing cleared it when the party went away. A leader whose party dissolved -- which the
server answers by dropping the entry, as the user saw -- kept the old row pinned; a page whose
row 0 is someone else's leaves the pin (`0x8841f0`), so Refresh and reopening kept it; and
Delete entry sent the old number, which the server refuses `0x2c1c` ("doesn't exist").

**What the original does (READ, `UI_PARTY::FUN_00886b10`, the `0x3864` handler).** Every clear is
`0x97c960(0)` -> `0x97c3b0`; the argument is 0 because `ebp` is zeroed at `0x886b64` and pushed
unchanged at `0x886ea4` and `0x88719f` (and `push 0` at `0x886f6f`):

| `0x3864` | the registration |
|---|---|
| kind 1, dissolved | cleared (`0x8871a7`); its number leaves the window's list and the window redraws (`0x73a700`, `0x73a770`) |
| kind 3, the player left | cleared (`0x886eaa`) |
| kind 3, someone else left, the player out of a party | cleared and dropped from the list (`0x886f76`, `0x73a700`, `0x73a770`) |
| kind 3, someone else left, still in a party | its member count becomes the party's (`+9` <- `0x986f50()+0x10`, the source the echo `0x97c530` fills the count from), and its row redraws (`0x73a980`) |
| kind 2, joined | the same count update |
| kind 9, new leader | untouched |

The list steps are gated on `0x799680` (= `0x8b51f0(0x82, 1)`, the matching window as a child of
the interface), which the original builds once with the interface, so they always run there.
None of these paths calls the Set lock `0x6d5ab0` (its four callers are `0x79c252`, `0x79c2fd`,
`0x880268`, `0x884040`), so Set stays as it was.

**Fix.** `PartyState` signals each applied event (`party_event(kind, jid)`, not for kind 6);
`PartyMatchWindow` passes it to `PartyMatchState.on_party_event`, which applies the table above.
Disconnected in `dispose()` with the window's other hooks (round 714's B6).

## 2. The ticked bottom borders: a six-piece frame's top and bottom are its sides turned on their side

**Cause (READ + MEASURED).** The black boxes are `com_blacksquare_` CIFStretchWnds: the three
search boxes (99,75,90,20; 394,75,36,20; 443,75,36,20) and the list (25,119,735,305). That set
has six pieces -- no `mid_up`/`mid_down` -- and the builder reused `left_side` for the top and
`right_side` for the bottom, tiled **upright**. `right_side` is 4x4 with a grey column 3
(`#7B797B`; MEASURED from the archive's DDS) and black elsewhere, so tiled along the bottom it
put a grey dot every 4 px: the "vertical lines". (`left_side`'s column 0 is near-black,
`#080808`, so the top's ticks were invisible.)

**What the original does (READ).** CNIFStretchWnd's two UV slots (`0x49b1e0`, `0x49b200`; no
direct callers, so virtual) both call the corner UVs `0x49a140` with mode 2 and the edge UVs
`0x49a410` with mode 3. `0x49a410` is a jump table at `0x49a7b8` (cases `0x49a417`, `0x49a4f8`,
`0x49a5f1`, `0x49a6b0`); the quad layout `0x499e10` puts quads 0-3 at the corners (LT, RT, RB,
LB) and 4-7 on the edges (left, top, right, bottom), each vertex 6 floats with u, v at +0x10 and
+0x14. Decoded by simulating the x87 stack over the asm:

| mode 3 (`0x49a6b0`) | TL | TR | BR | BL |
|---|---|---|---|---|
| left | (0,0) | (1,0) | (1,1) | (0,1) |
| top | (0,1) | (0,0) | (1,0) | (1,1) |
| right | (0,0) | (1,0) | (1,1) | (0,1) |
| bottom | (0,1) | (0,0) | (1,0) | (1,1) |

The top and bottom are the texture turned 90 degrees clockwise (a texture column becomes a
screen row), and the sizes are copied across swapped (`[0x788]=[0x784]`, `[0x78c]=[0x780]`,
`[0x798]=[0x794]`, `[0x79c]=[0x790]`): the top's thickness is `left_side`'s width, the bottom's
`right_side`'s. Mode 2's corners are each drawn upright with their own texture. So the bottom
strip's last row is `right_side`'s grey column: a line.

**Fix.** `UiBuilder._build_frame` turns a reused side piece 90 degrees clockwise
(`rotated_cw`, cached per texture) for a six-piece set's top and bottom, at that side's width.
Every six-piece base in the archive's layouts is a CIFStretchWnd (MEASURED over all 248
`resinfo` files: `com_blacksquare_` 105 CIFStretchWnd + one CIFGuildGrantPower + one
CIFMultiLetter; `com_lattice_outline_` 14; `com_square_` 1). `com_lattice_outline_` -- the
border around the inventory's, storage's, exchange's and store's item grids -- had the same
fault: its sides are vertical stripes (`#100C10 #393839 #101410 #000000` by column; MEASURED), so
its top and bottom were drawn as fine ticks, and are now horizontal bands, matching its own
`left_up` corner, whose row 1 is the band (`#313431`).

## 3. The low digits

**Cause.** Two separate things:
- The edits (Name, the two Level boxes) were Godot LineEdits with Godot's default style, a padded
  box whose minimum height (content margins plus the 17 px line) is taller than the layouts'
  11-15 px edit rects. Godot clamps a control's size to its minimum, so the edit grew and
  centred its text 4-5 px low. The client's edit draws no box of its own (every one sits on art:
  here `com_bg_tile_e` inside the black frame), and the layouts give VAlign 0.
- The page spin's value label is set to its READ rect (16,4) 18x12, but a Godot Label is never
  shorter than its line (17 px), so it grew downward and its centred text sat low.

**Fix.** `UiBuilder._build_edit` gives a CIFEdit no box (StyleBoxEmpty for normal, focus and
read_only, as `TwoDtBuilder._edit` already did) and the layout's FontIndex face, size and
colour, so it settles at its line with the text from the rect's top. The spin's label is laid by
`place_label` on its rect (the client's centred overrun, as every static's text is). How CIFEdit
applies HAlign was not read, so the edits' horizontal alignment is unchanged.

## 4. The Purpose value

The user's description of the original: right-aligned, an overflow hidden on its LEFT. The
combo's drawing code was not read; this follows the description, labelled so. A Godot Button
clips a too-long text on its right, so the OptionButton keeps the clicks and the list and draws
no text, and the value is a Label in a clipping box over the combo's READ text rect
`{5, 0, W-30, H}` (`OptionVideoPage.combo_text_rect`), its right edge on the box's.

## Tests

- `party_match_test.gd`: the stale-listing mechanism (a page of someone else's rows leaves the
  pin), every event branch above, and `PartyState` signalling kind 1. All pass.
- `party_match_window_test.gd`: after a dissolve only the new entry is listed; a CIFEdit's three
  styles are empty and pad nothing; the Purpose value's right edge is the text rect's and a
  too-long value overflows on the left inside the clip. All pass.
- `ui_builder_test.gd`: a synthetic six-piece set whose `right_side` has a grey column 3 draws
  its bottom strip with a grey last ROW (not a column), and `left_side`'s column 0 as the top's
  first row. Passes.

## Live (render box, RX 7600 / Vulkan Forward+, the shared lock, stock `qa_shot.sh --server`)

One scene, run twice against a server built from this branch (`/var/tmp/r718/r718_live.sh`):
`dev`'s client (`f6989ea9`, before) and this branch's (after). Aria (rendered) invites the bot
Bram and lists the party ("Aria party", entry 2); the bot Cara lists a party-less entry (1); Aria
leaves (a party of two dissolves); Aria pages, tries Delete entry, pages again. The window's own
QA dump of its list:

| step | before | after |
|---|---|---|
| listed, in the party | 2 Aria (own), 1 Cara | 2 Aria (own), 1 Cara |
| "The party is dismissed.", page 0 | **2 Aria (own)**, 1 Cara | 1 Cara |
| Delete entry | "Cannot find the corresponding party." (`0x2c1c`) | (nothing to delete) |
| page 0 again | **2 Aria (own)**, 1 Cara | 1 Cara |

The user's bug, reproduced and gone. Logs: `/var/tmp/r718/before/godot.log`,
`/var/tmp/r718/after/godot.log`.

**The window, MEASURED on frame 330 of each run** (1280x720, the window at 248,120; the user's
original `02_BQfjkpc.png` is a 2x screenshot, halved below):

| what | before | after | the original |
|---|---|---|---|
| list frame's bottom strip, rows 541-543 (x 300..700) | each row 300 black + 100 grey: a grey tick every 4 px | 541-542 black, 543 all 400 grey: one line | 2-row (1 px) grey line under the boxes |
| Name box's bottom row, y 214 (x 352..431) | covered by Godot's own grey box | 80 grey: one line | a line |
| Min-level box (black y 195-213, grey line 214): the "1" | not on black (Godot's box over it) | rows 200-208: 5 px black above, 5 below | 6 px above, 4 below |
| Page spin "1", below the arrows' top | 9-17 px (4 px low) | 5-13 px | 5-13 px |
| Purpose "All": gap to the arrow button | -- | 8 px, rows 5-13 of the box | 7.5 px, rows 5-14.5 |

The level digits now sit 1 px higher than the original's. That is the font's own metrics
(Godot's line vs the client's GDI cell); how CIFEdit offsets its text was not read, so no
constant was added to close it.
