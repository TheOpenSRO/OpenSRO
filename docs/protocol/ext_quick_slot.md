# The Additional Quick Slot (round 788)

Retail's "Additional Quick Slot" bar (`CIFExtQuickSlot`, `GDR_EXT_QUICK_SLOT`, window 133 / 0x85,
`ginterface.txt` section `ExtQuickSlot`) and its option window (`CIFExtQuickSlotOption`), read in
`sro_client.exe` (md5 `2a5794b72c90908d945be8b3f3f2edd4`; decompile `/var/tmp/decomp_client`, asm
`/var/tmp/sro_client.asm` on the RE box), and OpenSRO's own extra bars built on it. Labels as
everywhere: **READ** (the binary), **MEASURED** (the archive, the user's screenshots, a run),
**INFERRED**, **OURS**, **OPEN**.

Code: `client/scripts/ui/hud/hud_ext_quick_slot.gd` (one bar and its option window),
`hud_ext_quick_slots.gd` (the bars), `ext_quick_slot_layout.gd` (the arithmetic),
`ext_quick_slot_settings.gd` (what is kept), `hud_underbar.gd` (`lend_slot`), `hotbar_store.gd`
(the slots' contents). Tests: `hud_ext_quick_slot_test.gd` (synthetic layouts from
`ext_quick_slot_fixture.gd`), `hotbar_store_test.gd`, `keymap_test.gd`, `ui_layout_parser_test.gd`.

## 1. What it is (READ)

- **Retail has ONE bar.** `CIFExtQuickSlot : CIFWnd`, vtable `0xda0464`, ctor `0x65e870`, Create
  (vslot 10) `0x65f720`: loads `resinfo\ifextquickslot.txt`, keeps the bottom bar (`0x7994e0` ->
  window 0xaf, `CNIFUnderMenuBar`) at +0x374, loads the options file (`0x65f580`). Message map
  `0xeb73e8`: 11 OPT -> `0x65eea0`, 12 HORI -> `0x65f700`, 13 VERT -> `0x65f710`, 14 ONOFF ->
  `0x65eed0`.
- **Always present.** The in-game set-up `0x786f30` calls `0x79c600(1)` unconditionally
  (`0x7871d2`); the teardown `0x787860` calls `0x79c600(0)` (`0x787946`). Those are the only
  callers: no menu item and no key shows or hides it; it can only be collapsed.
- **Its slots are the bottom bar's quick slots 41..50** -- the ones no page shows (F1..F4 are
  1..40). `CIFExtQuickSlotSlot : CIFWnd` (vtable `0xda07ec`, ctor `0x65fa50`) is a PROXY: +0x36c
  holds the target slot's id (bound by `0x65fc70`, the binding loop in `0x65ef70` reading the
  bottom bar's +0x478..+0x49c, its slots 41..50: OnCreate `0x60df30`). Draw (vslot 13 `0x65fb00`)
  calls the target's draw at the proxy's place: the icon, the count and the re-use display are
  the target's own. Events (vslot 19 `0x65fb90`) go to the target; a drop (vslot 28 `0x65fb50`) to
  the target's drop, with no lock test; the right button's release on the same slot uses it
  (vslot 33 `0x65fc20` -> `0x682040`). Teardown clears the ten targets (`0x65eef0`).
- **The hover help (READ, this round; the research note said "no tooltips").** `0x65fb90` forwards
  the hover message 0x4009 to the target, whose `CIFSlotWithHelp::vslot_019` (`0x667820`) shows
  its help (vslot 48, `0x686db0`), and then re-places the help window (interface +0x730,
  `0x798db0`) beside the PROXY's own rect: `0x776c00(rect, 0)` puts it at x = rect right + 8 (or
  rect left - its width - 8 when right + 0x14 + width passes the screen), y = rect top + 8 (kept
  0xf above the bottom). So a skill on the bar shows its tooltip beside the bar's slot.
- **No key-number labels** (none in the layout).

**Built here:** the bottom bar lends the slot's own node (`HudUnderbar.lend_slot(41..50)`), which
the bar re-parents to its slot rects. Every call by quick-slot index -- icons, counts, the re-use
display, seals, drops (`slot_index_at`), the right-click use, the left-click pick-up -- reaches it
unchanged; the bottom bar's page changes skip lent slots. The bottom bar never shows a fifth page
(`0x60a730` wraps 0..3), so nothing there needed hiding. The tooltip is the slot's own bubble
(`HudPanels.set_bubble_tip`, placed beside the node's rect: our placement rule, not `0x776c00`'s).

## 2. The layouts (MEASURED, `resinfo\ifextquickslot.txt`, read at run time)

`type = vertical * 2 + twoLines` picks sections Type1..Type4 (`0x65ef70`, stored at +0x372). Rects
are relative to the bar; size 0 means the art's own size; children are listed front to back
(built reversed). The window's own size is the WND control's (`0x65f12e`): the slots hang outside
the window's rect. Art under `interface\quick_slot\`, every button with `_focus` and `_press`.

| ctrl (id) | Type1 horiz 1-line | Type2 horiz 2-line | Type3 vert 1-line | Type4 vert 2-line |
|---|---|---|---|---|
| WND `CIFDragableArea` (10) | 0,0,44,40 `qsl_hriz01_windo` | 0,0,32,76 `qsl_hriz02_windo` | 0,0,44,44 `qsl_vrtl01_windo` | 0,0,80,32 `qsl_vrtl02_windo` |
| OPT (11) `qsl_opt_button` 16x16 | 14,1 | 14,37 | 2,14 | 38,14 |
| HORI (12) `qsl_hriz_button` 16x16 | 14,13 | 14,49 | 14,14 | 50,14 |
| VERT (13) `qsl_vrtl_button` 16x16 | 14,25 | 14,61 | 26,14 | 62,14 |
| ONOFF (14) | 26,1 `qsl_hopen_button` 16x40 | 14,1 (same) | 2,26 `qsl_vopen_button` 40x14 | 2,14 (same) |
| END (20) | 401,0 `qsl_hriz01_end` 4x40 | 209,0 `qsl_hriz02_end` 4x76 | 0,41 `qsl_vrtl01_end` 44x4 | 0,29 `qsl_vrtl02_end` 80x4 |
| BOARD 30.. | 10, x = 41+36i, 36x40 | 5, x = 29+36i, 36x76 | 10, y = 41+36i, 44x36 | 5, y = 29+36i, 80x36 |
| SLOT 100..109, 32x32 | (43+36i, 4) | i<5 (31+36i, 4); else (31+36(i-5), 40) | (5, 43+36i) | i<5 (5, 31+36i); else (41, 31+36(i-5)) |
| every control's extent | 405x41 | 213x77 | 44x401 | 80x209 |

The extents are MEASURED from the built nodes (the suite and the live run's `QA EXTRECTS` lines):
Type1's collapse button (26,1, 40 tall) hangs one pixel below its 40-tall strip, Type2's VERT
(14,61) one below 76. END in the vertical types sits at the top of the slot area, behind board 1.
The WND art is opaque over 77 of its 80 columns (Type4), which is why the bar looks 77 wide.

## 3. Behaviour (READ unless marked)

- **State** (ctor `0x65e870`): +0x36c open, +0x36d vertical, +0x36e two lines, +0x36f
  transparent, +0x370 lock slots, +0x371 lock toolbar, +0x372 the current type (0xff at start, so
  the first apply builds).
- **apply()** `0x65f390`, in this order: (1) the layout rebuilt only if the type changed
  (`0x65ef70`: old Type section destroyed, the new one built, the window sized from WND, the
  proxies bound, the open state applied again); (2) alpha = 0x6e (110) if Transparent else 0xff,
  given to WND and the four buttons, and -- only while open -- to END, the ten slots and the
  boards (`0x655460` stores it per control at +0xa9, `0x6526b1` multiplies it by the parent's);
  (3) each slot's pick-up flag (+0x64, `0xb9daf0`) = !lock slots; (4) WND's input (+0x62,
  `0xb8f540`, gated at `0xb91440`) = !lock toolbar.
  - **The quirk, reproduced:** Transparent changed while collapsed reaches only the header; END,
    the boards and the slots keep their old alpha until the next apply while open (collapse does
    not apply, see below).
  - **The slots' alpha is kept but does not fade the icons** (INFERRED): the proxy draws the
    target with the target's own draw and alpha, and the user's screenshots show full-colour icons
    on a transparent bar. OPEN until the draw path is traced.
  - The art is near-black (average RGB ~10); the tan look in screenshots is the ground through 43 %
    opacity.
- **Collapse** (ONOFF `0x65eed0` -> `0x65ecd0`): open toggles; the ONOFF art becomes
  `qsl_hclose_button` / `qsl_vclose_button` while open and `qsl_hopen_button` /
  `qsl_vopen_button` while collapsed; the slots and boards (ten each, or ten and five) and then END
  are shown or hidden. Only the header stays. Nothing else is re-applied.
- **HORI / VERT** (`0x65f700` / `0x65f710`): vertical = 0 / 1, then apply().
- **Moving:** dragging the WND strip (the header art; the buttons sit on it). Position = mouse -
  grab offset (`0x6a1a30` -> `0xb90cf0`), **no screen clamp while dragging**. Lock Toolbar turns
  WND's input off entirely (no drag); the buttons still work. The option window, a child of the
  bar, moves with it (INFERRED from `0xb90cf0` moving children).
- **Lock Slots** stops the left-button-up pick-up (`0x6525b1` tests +0x64; no Ctrl/Shift/Alt
  held). A drop still lands on a locked slot (`0x65fb50` has no lock test; INFERRED from the
  absence).
- **The place.** Default `(screen_w - window_w - 26, 181)` (`0x79c600`, `0x79c697..0x79c6c3`;
  `push 0xb5`), window_w being WND's width. A kept place is restored on show (`0x79a8d0`), clamped
  on the right and bottom only (x = screen_w - w when it overflows; y likewise).
- **Keys:** Space held + 1..9, 0 uses quick slots 41..50 (`GetKeyState(VK_SPACE)` at `0x780c11`
  -> 40 + k into `0x60bb80`); Ctrl + digit wins (party select, `0x780c21`). F1..F4 select the
  bottom bar's pages 0..3 and wrap; the raw-key table `0x780da8` has no F5; the bar does not touch
  the page selector. Right-click uses a slot (`0x682040`, kind 0x0c); left-click picks the icon up.

## 4. The option window (READ)

- `CIFExtQuickSlotOption : CIFMainFrame` (vtable `0xda069c`), the Option section's child 5:
  `GDR_EXT_QUICKSLOT_OPTION`, 290x223 on the 8-slice `interface\messagebox\msgbox2_window_`,
  caption `UIIT_STT_ADD_QUICKSLOT_ADD`. Its Create (`0x65f9d0`) loads section Create of
  `resinfo\ifextquickslotoption.txt`: BG1 `com_bg_tile_b` 48,82,195,65; BG2 `com_bg_tile_b`
  16,175,258,32; FRAME1 `inventory\int_window_` 14,40,262,135; FRAME2 `option\opt_inner_box_`
  28,54,235,105; header `UIIT_CTL_OPTION` 90,59,111,16 centred; statics 62 / 68 wide, white:
  TRANS 46,92, LOCK 46,127, FIX 160,92, DOUBLELINE 160,127; check boxes (`com_checkbutton_off` /
  `_on`, 16x16) 25 TRANS 111,91, 26 LOCK 111,126, 27 FIX 231,91, 28 DOUBLELINE 231,126; buttons
  `com_button` 76x24, text 255,247,202 centred, ClientRect y 6: 35 Confirm 63,185 (its rect has
  only three numbers, "63,185,0" -- the archive's only such rect; this round's parser keeps x and y),
  36 Apply 149,185. The chrome is CIFMainFrame's (`0x816f80`): caption (10,12,269,12), drag strip
  (10,0,269,34), close at (264,10).
- Opened only by OPT; `0x65eea0` builds it if child 5 is absent, else destroys it (OPT pressed
  again closes WITHOUT applying). On open the boxes are set from the state (`0x65f800`).
- **Placement** (`0x65eb10`, asm `0x65ebba..0x65ec78`), from the bar's own rect (its header): a
  vertical bar -> (x + w, y) if x < screen_w >> 1, else (x - opt_w, y); a horizontal bar ->
  (x, y + h) if y < screen_h >> 1, else (x, y - opt_h). No clamp: a horizontal bar near the right
  edge opens it partly off the screen (MEASURED in the live run at the default place, as retail
  would).
- **Apply** (`0x65f870`): 25 -> transparent, 26 -> lock slots, 27 -> lock toolbar, 28 -> two
  lines, then apply(); the window stays. **Confirm** (`0x65f9b0`): Apply, then close (vslot 43,
  `0x65f7e0`). **The close X** closes without applying (INFERRED: the X -> vslot 43). Neither
  writes the options file.

## 5. Persistence (READ)

- Options: `%s\Setting\SRExtQSOption.dat` (`%s` = `DAT_0110f7d0+0x134`, presumably the install
  directory, INFERRED): u32 version 1, then six bytes: open, vertical, two lines, transparent, lock
  slots, lock toolbar. Written only when the bar is destroyed (dtor `0x65ead0` -> `0x65e9b0`), i.e.
  at teardown; read at Create (`0x65f580`). No file -> open, vertical, two lines, transparent,
  both locks off (Type4). Version != 1 leaves the ctor's values (open, the rest 0).
- Position: not on disk. `0x79c600(0)` stores it in CGInterface's in-memory map +0x710 keyed by
  window id (`0x79a840`), built and freed only with CGInterface (`0x78d27e`, `0x78c564`): the next
  launch starts at the default place.
- Slot contents: quick slots 41..50 in the bottom bar's own save (0x7158 types 0/1, slot 0..50,
  MAX 0x33) and the character data (`0x8a7c50`); `0x60b260` re-applies the bar after the load.

## 6. Text (MEASURED, the English column)

`UIIT_STT_ADD_QUICKSLOT_ADD` "Additional Quick Slot", `_INVISIBLE` "Transparent", `_LOCK` "Lock
Slots", `_FIXING_POSITION` "Lock Toolbar", `_TWO_LINE` "Two Lines", `UIIT_CTL_OPTION` "Option",
`UIIS_CTL_CONFIRM` "Confirm", `UIIT_CTL_APPLY` "Apply". Unused: `UIIT_STT_ADD_QUICKSLOT_EXSLOT2`
"Extended Slot 2" (no reference in the exe or the layouts).

## 7. OpenSRO's additions (OURS)

The user's reference screenshots (a private server's client) show a SECOND bar with a page footer
(◄ "F5" ► under a vertical bar, ▲ "F5" ▼ right of a horizontal one); its page F5 is empty while the
retail bar (41..50) holds items, so that server's pager is a separate slot range. The user asked
for retail's bar exactly, a second bar of ours with a footer, and room to add more.

- **Extra bars.** `HudExtQuickSlots` builds retail's bar (index 0) and `extra_bars` more (index
  1..), each the same window -- same layouts, art, options, collapse, orientation, option window,
  drag and locks -- with its own options and place.
- **Their slots are new quick slots, 51..250.** Bar b (1-based), page p, key k is quick slot
  `51 + ((b - 1) * 5 + (p - 1)) * 10 + k`: room for 4 bars x 5 pages x 10, a fixed stride per bar,
  so raising the bar or page count needs no format change and moves nothing stored
  (`HudUnderbar.EXT_SLOT_BASE / EXT_BARS_MAX / EXT_PAGES_MAX / SLOT_COUNT`). The bottom bar makes
  the nodes on first asking (`lend_slot`) and registers them, so every quick-slot path works on
  them by index. Retail's 0..50 are unchanged.
- **Where they are kept.** OpenSRO's quick-slot bar has lived on the CLIENT since round 639
  (`HotbarStore`, `user://quickslots.cfg`, OURS at the user's request; retail keeps it on the
  server through 0x7158, and OpenSRO's server stores only 0x7158 type 2, the auto potion). Slots
  41..50 were already saved there (the store took 0..50); this round widens it to 0..250. No server
  or protocol change: an old client reading a new file skips the entries past 50 (its own range
  check) and drops them at its next save of that character's bar; a new client reads an old file
  as before.
- **The footer** (MEASURED from the screenshots at 2x: footer 23 px past the slot area, arrows 12x20
  2 px in from each side flush with the slot area's end, label centred between them;
  `ExtQuickSlotLayout.footer_rects`). Vertical: a band under the slots, `qsl_left_arrow` left,
  `qsl_right_arrow` right. Horizontal: a band right of the slots, the same arrows turned a quarter
  clockwise (no up/down art exists under `quick_slot\`), up at the top, down at the bottom; there
  the END cap is not built (the band covers it). The backing is composed from the header art (its
  grip lines 2..12 repeated, closed by its rounded edge lines 0..1 turned outward; the reference
  server's own art is not in the archive). The label is the client's font 0, white, at full alpha
  (as on the reference's transparent bar); the band and arrows take the bar's alpha with the
  boards; the footer collapses with the boards. The one-line types' footers are the same rule,
  not measured (no screenshot shows them).
- **Pages.** Labelled `F5`, `F6`, ... (`F%d` of 4 + page, after the bottom bar's F1..F4, as the
  reference's first page reads F5). The arrows step and wrap, as the bottom bar's pages do. No key
  selects a page (F5..F8 stay unbound, as in retail). An extra bar starts on page 1 each session.
- **Keys.** Alt + 1..9, 0 fires the FIRST extra bar's page slot k (`KeyMap.resolve`,
  `ext_quickslot`). Every other modifier + digit is taken: Space (41..50) and Ctrl (select) by
  retail, Shift by retail's plain digit (`0x780610` tests no Shift). Retail's Alt + digit is unread
  (its message map registers no `WM_SYSKEYDOWN`); before this round OpenSRO treated it as the plain
  digit. Bars 2.. have no keys (clickable only).
- **Options and places persist** in the client's settings file (`ClientSettings`,
  `user://settings.cfg`), section `[ext_quick_slot]`: `options_<n>` (retail's six values, retail's
  order, as 0/1 ints), `position_<n>` (whole pixels), `extra_bars` (0..4, default 1), `pages` (1..5,
  default 4). Written whenever they change (retail writes the options at teardown), the place when
  a drag ends (retail forgets it on exit). Retail's `SRExtQSOption.dat` is not written. The READ
  defaults apply to every bar with nothing kept; a damaged entry reads as none.
- **Default places.** Retail's bar at the READ default; extra bar n at the same y, moved left by
  n x (header width + 4).
- **Adding more.** An extra bar's option window has one more row (OURS; 30 px taller, the button
  band moved down): "Bars" and "Pages", each a value between the `qsl_left_arrow` / `qsl_right_arrow`
  art, taking effect on Apply or Confirm (1..4 bars, 1..5 pages). Retail's bar's window is as
  authored. With 0 extra bars (only by editing the file) the row is not reachable; set
  `extra_bars=1` under `[ext_quick_slot]` in `settings.cfg` to bring one back. Fewer bars hide the
  removed bars' slots but keep their contents, which come back with the bar.

## 8. OPEN

- The private server's real pager semantics (what its second bar binds to, whether a key turns its
  pages, how many pages).
- Whether the slots' icons fade with Transparent (the proxy's draw path, `0x65fb00` -> the
  target's draw, not traced to the alpha multiply).
- The hover help's exact place: `0x776c00`'s rule is read; ours places the bubble with
  `HudPanels`' rule. The `param_1[0x21] + 0x24` call with 0xc4 in it is not identified.
- The option window's close X -> vslot 43 wiring (INFERRED).
- The base directory behind `DAT_0110f7d0+0x134`.
- `0x65f580`'s setter mapping is from the decompile; the per-byte stack offsets were not re-traced
  in the asm.
- Escape and the option window: not read; here Escape does not close it.
