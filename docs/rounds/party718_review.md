# Round 718 review: the party-matching report (`dev..ea35a7a0`)

An independent adversarial review of `docs/rounds/party718.md`. Labels: READ (from the client's
asm or decompile), MEASURED (pixels or the log of a run), INFERRED. No code was changed.

**Verdict.** The stale-listing fix is correct for kinds 1, 2 and 3. The rotation of the six-piece
top and bottom edges is correct, and I confirmed it on the right class. The lane cited
CNIFStretchWnd, but resinfo builds CIFStretchWnd, a sibling class with its own copy of the
code. That copy has the same mode 3 and the same result. Two findings change behaviour:
**kind 9 is handled wrongly** (F1), and **CIFEdit's HAlign is now READ and is not applied** (F2).
Both are in the window the user reported. Everything else is labels, or latent and minor.

## Findings, most severe first

### F1. DEPARTURE: a leader change does not update the registration's name

- **Where:** `client/scripts/net/party_match_state.gd:250-266` (`on_party_event` has no
  `EVENT_LEADER` branch). The test `client/scripts/net/party_match_test.gd:244-247` ("A leader
  change leaves the registration alone"). `docs/rounds/party718.md` §1 table, row "kind 9, new
  leader | untouched".
- **Evidence (READ),** `UI_PARTY::FUN_00886b10`, kind 9 (`0x8871d0`..`0x8872a2`):
  - `0x9958a0(jid)` makes the member the leader.
  - `0x9921e0(jid)` returns that member's record, and `ebp` keeps it (`0x887200`). The record
    begins with the member's name as a wstring: `[ebp+0x18]` is the capacity and `[ebp+4]` the
    buffer (`0x887207`..`0x887211`).
  - The system line is written, then:
    `0x97b950` -> `esi`; `0x799680` (the window) -> `edi`; `cmp [esi],0` (a registration);
    `push -1; push 0; push ebp; lea ecx,[esi+0x10]; call 0x46ed50`, a wstring assign;
    then `push [esi]; call 0x73a980` (redraw that row).
  - The registration's `+0x10` is its Name column (party_gui.md, the `CPartyRegData` table:
    "Name | +0x10 wstring").
  - So the original **copies the new leader's name into the registration and redraws its row**.
    OpenSRO keeps the old leader's name on the pinned row until a later page replaces it. The
    server already moves the entry to the new leader (`server/internal/party/match.go:11`).
- **Fix:**
  1. Add an `EVENT_LEADER` branch: if `registration != null`, set `registration.leader_name` to
     the new leader's member name, then `changed.emit()`.
  2. `PartyMatchWindow._on_party_event` has to pass that name, or the jid and a lookup.
  3. Correct the party718.md row and the test, and add the kind 9 line to party_gui.md's
     "registration follows the party" paragraph.

### F2. DEPARTURE: CIFEdit's HAlign is applied in the original and not here

- **Where:** `client/scripts/ui/ui_builder.gd:892-904` (`_build_edit` sets no alignment). Its
  comment says "HAlign is left as it was: how CIFEdit applies it is not read". party718.md §3 and
  "OURS / not read" say the same.
- **Evidence (READ).**
  - CIFEdit's vtable is `0xd9ae3c` (slot 10 = `CIFEdit::vslot_010` 0x637a60). Its draw is slot
    13, `0x637b70`.
  - The draw takes the text rect from `0x652800` (the rect less ClientRect) and the text extent
    from `0x8b2f20`.
  - It then switches on `[esi+0x88]` (HAlign) at `0x637c7f`:
    - 0: `right = left + w`.
    - 1: centred (`0x637cc3`..`0x637cf3`).
    - 2: `left = right - w - 2.0` (`0x637cad`..`0x637cbb`). The constant is the double at
      `0xe1b898`, which reads 2.0.
  - The resinfo HAlign values:
    - `GDR_PARTYMATCH_SEARCH_NAME_EDIT` is **HAlign 2**.
    - `ifpartymatchregister.txt`'s `GDR_PARTYMATCH_REGISTER_LEVEL_MIN_EDIT` and `_MAX_EDIT` are
      **HAlign 2**.
    - The level search edits are HAlign 0.
  - So in the original, a name typed into the Name box sits at its right, 2 px in.
- **MEASURED:** in my real-input run, "Bram" typed into the Name edit drew at x 352..380, from
  the left of the edit rect (351..432).
- **Fix:** set `LineEdit.alignment` from `def.halign` (the existing `_map_halign`). For HAlign 2,
  also give a 2 px right content margin on the three empty styleboxes. Then relabel the comment
  and the notes READ.

### F3. WRONG-LABEL: the rotation is cited on the wrong class; the result is right

- **Where:** `client/scripts/ui/ui_builder.gd:742-757`, `:797-807` and `:834-836`. The comment
  in `client/scripts/ui/ui_builder_test.gd` `_check_six_piece_edges_rotated`. party718.md §2.
  party_gui.md's new "edit boxes and the black frames" bullet.
- **Evidence (READ).** The resinfo frames are **CIFStretchWnd**. RTTI gives `CIFStretchWnd :
  CIFWnd : CGWnd ...`, not CNIFStretchWnd, and the class has its own vtable `0xdd2174`.
  Its path:
  - The resinfo loader checks IsKindOf on `0xeecb94` (CIFStretchWnd) at `0x8b57ce`. It then
    calls `0x819c00`, the six-piece loader: four corners, then `right_side`, `right_side`,
    `left_side`, `left_side` into the edge slots left/top/right/bottom.
  - It then calls vtable slot 47 (`+0xbc`) with the control's **StretchType** (`[esi+0xf0]`,
    `0x8b5824`). The `+0xf0` is StretchType's offset: the resinfo parser `0x82c1d0` stores
    StretchType there.
  - Slot 47 is `0x819110` -> `0x8190f0`. When StretchType is 0, it calls the corner UVs
    `0x818a50(2)` and the edge UVs `0x818d30(3)`. Otherwise the constructor's modes stay:
    corner from eax, edge 1 (`0x819276`..`0x819280`).
- **Mode 3 is the same in this copy.** I simulated the x87 stack of `0x818d4f`..:
  - Left and right are upright.
  - Top and bottom are TL (0,1), TR (0,0), BR (1,0), BL (1,1).
  - The size copies are `[0x7a4]=[0x7a0]`, `[0x7a8]=[0x79c]`, `[0x7b4]=[0x7b0]`,
    `[0x7b8]=[0x7ac]`.
  - These are CNIF's offsets plus 0x1c.
- **StretchType:** every six-piece CIFStretchWnd in the 229 resinfo files has StretchType 0:
  100 `com_blacksquare_`, 14 `com_lattice_outline_`, 1 `com_square_`, plus the
  GuildGrantPower and MultiLetter subclasses (my census).
- **The CNIF citation still holds for the 2dt windows.** The 2dt loader `0x489b80` calls slot 49
  with 0 at `0x48a408`..`0x48a415` before `0x49b040`. So `TwoDtBuilder._frame` is right to rotate
  as well.
- **Fix:** cite the CIF path for resinfo and the CNIF path for 2dt. Also, the comment's "how
  that inner rect maps onto a control's rect is not read" is now READ, in CIF slot 41
  `0x8186a0`:
  - Every piece is laid **inside** the control's rect.
  - Top: x from LT.w to W−RT.w, at y..y+`[0x7a8]` (left_side.w).
  - Bottom: x from LB.w to W−RB.w, at H−`[0x7b8]` (right_side.w)..H.
  - Left: x..x+left_side.w, from LT.h to H−LB.h.
  - Right: from RT.h to H−RB.h.
  - The builder matches this for every 4x4 set.

### F4. MINOR: the edges are stretched in the original and tiled here

- **Where:** `client/scripts/ui/ui_builder.gd:819-830` (`_add_slice(..., true)`).
- **Evidence (READ).**
  - Mode 3's UVs are 0 and 1, and the layout (`0x8186a0`) writes positions only.
  - The draw `0x819d80` copies the quads unchanged and samples with point filtering
    (`SetSamplerState(0, 5/6, 1)` at `0x819e3c`/`0x819e5f`).
  - So each edge piece is **stretched** across its span.
- **Where it shows (MEASURED, run 1).** It differs only for pieces that change along their
  length:
  - `com_blacksquare_`'s `left_side` column 0 is `#080808 #080C08 #000400 #080808` by row.
  - Our top rows (165, 209) repeat that every 4 px. The original would show four long bands.
  - The difference is ≤ 8 levels and invisible.
  - `com_square_` (4x64 sides, one control, `GDR_SKLPB_SQUARE`, not built) would differ more.
- **Fix (optional):** use `STRETCH_SCALE` for a CIFStretchWnd's edges.

### F5. MINOR / WRONG-LABEL: a tall edit is centred, not at its top

- **Where:** `client/scripts/ui/ui_builder.gd:876-890` (comment). party718.md §3 says "the text
  starts at the rect's top -- the layouts' VAlign 0".
- **Evidence.**
  - CIFEdit's VAlign 0 keeps the text at the text rect's top (`0x637d58`..`0x637d64`, bottom =
    top + h). There is **no inset** (READ).
  - Godot's LineEdit always centres its line vertically: `y_ofs = (y_area − text_height) / 2`
    in Godot 4.2's `line_edit.cpp`. That is from the engine source, not measured here.
  - The claim therefore holds only while the rect is shorter than the line, as party matching's
    11-15 px edits are.
  - `GDR_WHOLE_CHAT_EDITBOX_INPUT` is 298x36 with VAlign 0, and it still centres. That predates
    this round.
- **Fix:** say so in the comment. If the whole-chat edit should match, give it a bottom content
  margin of (36 − line).

### F6. MINOR: `_build_edit` ignores ClientRect

- **Evidence (READ).** CIFEdit lays its text in `0x652800`, the rect less ClientRect. Nine
  CIFEdits carry `7,5,7,5`: `ifmessagebox.txt`'s `GDR_MBS_EDIT_AMOUNT`, `_MBDC_..._AMOUNT_EDIT`,
  the coupon edits and `_ITEM_COUNT_EDIT`.
- With Godot's padded box gone, such an edit would draw at its rect's corner. **None is built
  through `_build_edit` today.** The client's gold and quantity boxes are its own LineEdits
  (`hud_panels.gd:1380`, `:2711`), and the chat line is `hud_chat.gd:553`. So it is latent.
- **Fix:** turn `def.client_rect` into the empty styleboxes' content margins.

### F7. MINOR: a kind-3 self-leave also drops the number from the list

- **Where:** `client/scripts/net/party_match_state.gd:268-276`. `_clear_registration` always
  emits `removed(number)`.
- **Evidence (READ).** On the self-leave path the original clears at `0x886eaa`. The following
  `*piVar5 == 0` test then skips `0x73a700`/`0x73a770`. Only kind 1 (`0x8871bf`) and kind 3 out
  of a party (`0x886f76`) drop the number.
- **Effect:** `_on_removed` touches only `_filtered` (the search result) and redraws. The own row
  is never in `rows`, so the effect is invisible except possibly in a search result. The notes'
  table is right, and the code is broader than the table.
- **Fix:** have `_clear_registration(emit_removed)` skip the signal on the self-leave branch.

### Also noted (not findings)

- **The Purpose alignment is READ, not only the user's description.**
  - The matching window's create gets combo id 0x2d and calls `0x6321a0(5)`, the five-row list
    (`0x73b04c`..`0x73b05d`).
  - It then calls the combo's text-board slot 5 (`+0x14`) with **2** (`0x73b062`..`0x73b073`).
  - CIFComboBox's override `0x6321e0` stores it and forwards it to child 3, then relays it
    (`+0xa8`, `0x64d9b0`, case 2: x = right − w).
  - Child 3 is a CIFStatic that `CIFComboBox::vslot_010` (`0x632937`..`0x63294f`) makes at
    `{5, 0, W−30, H}`.
  - A code-made static's defaults are HAlign 1 and VAlign 1 (`CTextBoard` ctor
    `0x655c28`..`0x655c3b`), so the vertical centring is READ as well.
  - MEASURED on the original (`02_BQfjkpc.png`, halved): the combo's box spans x 248..301
    (54 = W−20). "All" spans 285..295.5, against the text rect's right edge at 297.
  - **The left clip is still unread**, since CIFStatic's draw clipping was not read. The
    window's comment and party_gui.md can say the alignment is READ.
  - No other combo changed: the change is in `party_match_window.gd` only.
  - Other combos that need it: four `ifguildwarrequest` combos and one `ifspecialtydeal` combo
    carry HAlign 2 in their layouts. None is built.
- **Not read:** `ifcaschatview.txt`'s `GDR_CAS_CHATVIEW_BLACKSQUARE_2` is a CIFStretchWnd on the
  eight-piece `frame_msg_`. Its loader `0x819c00` takes the sides for the top and bottom even
  so; the builder would use `mid_up`. That window is not built. I also did not check whether
  any 2dt CNIFFrame (not CNIFStretchWnd) names a six-piece base, which `TwoDtBuilder._frame`
  would now rotate.

## Verified

### The stale listing (READ)

`FUN_00886b10` (decompile and asm) agrees with the notes for kinds 1, 2 and 3:

| Kind | What the original does |
|---|---|
| 1 | Takes the number before clearing (`iVar4 = *piVar5`), clears (`0x97c960`), then drops the number and redraws when the window exists and the number was non-zero. |
| 2 | Calls `0x7387c0`, then sets the count `+9 <- 0x986f50()+0x10` and redraws the row. |
| 3, the player | Clears at `0x886eaa`. |
| 3, another member, player out of a party | Clears, drops and redraws. |
| 3, another member, still in a party | Updates the count. |

`clear_party()` does not zero `own_jid`, so `self_left` is detected after `_apply_event`. Kind 9
is F1.

### The edge rotation (READ)

- I read `0x49a410` myself. It is a jump table at `0x49a7b8` -> 0x49a417 / 0x49a4f8 / 0x49a5f1
  / 0x49a6b0. Simulating the x87 stack gives mode 3 = left/right upright and top/bottom
  TL(0,1) TR(0,0) BR(1,0) BL(1,1).
- `0x499e10`'s vertices are TL, TR, BR, BL, with quads 4-7 = left, top, right, bottom.
- That is 90° **clockwise**: a screen row is a texture column, and the outer column 0 of
  `left_side` becomes the top's outer row.
- The width is the side's width (`[0x78c]=[0x780]`, `[0x79c]=[0x790]`).
- The CIF copy is identical (F3).

### Pixels (MEASURED)

Run 1: Forward+ on Vulkan (RX 7600), stock `qa_shot.sh`, the shared lock, `QA_SHOT_REAP=0`,
1920x1080, panels inventory, action and partymatch. Frame `/var/tmp/r718rev/f1_299.png`. The
matching window is at (646.67, 90) and the action pane at (1452, 90).

**Party matching, the list frame** (x 672..1406, y 209..513):

| Row | Colour |
|---|---|
| 510 | `#313431`, the last slot's own line over the strip |
| 511-512 | black |
| 513 | `#7B797B` from 676 to 1405, one run |

The corners meet it: the bottom-left corner's `#6A6562` at 673-675 and the bottom-right's
`#737573` at 1403/1406. The left edge's columns 672-675 are `#080808`, black, black, `#313431`.
The top row 209 is `left_side` column 0 (near-black), as the original's.

**The Name box** (x 746..835, y 165..184):

| Part | Colour |
|---|---|
| Rows 166-183 | black |
| Row 184 | corner `#6A6562` 747-749, strip `#7B797B` 750-831, corner `#737573` 832/835 |
| Column 835 | grey from 166 to 184 |

There is no tick anywhere. Against the original's Min box (2x, column 790): black 140-177 and a
grey line at 178-179, a 1 px line in 1x.

**The Purpose box:** the field frame spans 900..953, with a grey bottom 901..953 and a right
edge at 953. "All" spans 936..947, against the text rect's right edge at 948.67.

**Action window, `com_lattice_outline_` "Character Control":**

| Strip | Rows | Colours |
|---|---|---|
| Top | 161-164 | `#100C10 #393839 #101410 #000000`, each one run from 1488 to 1805 |
| Bottom | 231-234 | `#000000 #6A696A #292829 #5A5D5A`, each one run from 1488 to 1805 |

The top rows equal the left side's columns 1484-1487, and the bottom rows equal the right side's
columns 1806-1809, column k to row k. The 4-px corners at 1484-1487 and 1806-1809 meet both
strips. There is no 1 px shift: each strip is 4 thick, spanning exactly between the corners.

### Real X input (MEASURED)

Run 2: Compatibility, vglrun on Xvfb :718, xdotool, the shared lock, an in-memory server.
Script `/var/tmp/r718rev/live2.sh` + `drive2.py`; log `/var/tmp/r718rev/live2/client.log`.

| Step | Result |
|---|---|
| Click into the Name edit | Log: `KEY typing: keys go to GDR_PARTYMATCH_SEARCH_NAME_EDIT<LineEdit>`. The caret is visible: `#F2F2F2` at x 351, rows 196-213. |
| `xdotool type Bram` | Text in rows 201-209 of the box (black 195-213, line 214): 6 above, 4 below. No key fired a hotkey, and no `KEYMAP` line. |
| `ctrl+a` | The selection highlight is `#808080` over x 351..379, rows 199-212. |
| Click the Min level edit, BackSpace, `7` | "7" drawn at x 647, caret at 651. |
| Return, `hello718 bam`, Return in the chat line | `CHAT SEND: type 1 index 1 to '': hello718 bam`, then `CHAT RESULT ... ok true`. The b, a and m keys went into the line. |

**Focus look:** there is none (empty focus style). The original draws none either.

### The vertical text offset

The lane's measurement holds. On the original (`orig02.png`, the Min box, halved) the box is
black 70..88 with its line at 89, and "1" is in rows 76..84: 6 above, 4 below. Ours is 5 above
and 5 below for the level digits, and 6 / 4 for the Name edit (rect y 79 against 78).

CIFEdit's draw adds **no** vertical inset for VAlign 0 (READ, F5's addresses), so the 1 px is
the glyph's position in its cell: GDI cell against Godot's ascent. That is INFERRED, and the
lane's label for it is honest.

### Which windows the builder change reaches

`_build_edit` is reached by party matching (3 edits), the register dialog (3 edits) and the
whole chat (1 edit). The login screen, character create and select, the chat line and the gold
and quantity boxes build their own LineEdits, so the edit change does not reach them.

`_build_frame`'s rotation reaches these six-piece frames:

| Source | Windows |
|---|---|
| resinfo | ifaction 4, ifexchange 4, ifguild 2, ifinventory 1, ifmessagebox 10, ifpartymatch 4, ifpartymatchregister 2, ifpartymatchreqjoin 3, ifstorageroom 1, ifstore 1, ifwholechat 1 |
| 2dt, through `TwoDtBuilder._frame` | guild, community, enchant (alchemy), and others. Their loader also sets mode 3 (F3). |

No six-piece set is in the skill window or the chat window.

## Tests

`RENDER_DIR=/opt/opensro-client-r718rev`, `GODOT_LOCK=/var/tmp/r718rev/lock`, at `ea35a7a0`:

| Command | Result |
|---|---|
| `remote_godot.sh check` | ALL LOAD (605 scripts, 9 scenes) |
| `remote_godot.sh tests` | 231 suites, 0 failing |

No perf gate, as for the lane: only UI construction and message handling changed.

Kept on the box:
- `/var/tmp/r718rev/f1_299.png` (run 1's frame).
- `/var/tmp/r718rev/live2/{b_name_focus,c_name_typed,d_name_selected,e_min_typed}.png`.
- `client.log` and the two scripts.

The rest of run 1's frames and the reviewer's client copy were deleted, and nothing was left
running.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Y12ecfRLgyrW8rPt8BVTF9
