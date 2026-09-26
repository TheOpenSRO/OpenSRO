# `res_ui\*.2dt` — the client's newer window files

The retail client builds its newer windows (`CNIF*` classes: guild and community, quest list,
enchant, world-map guide, option, menu bar, open market, stall network and more) from binary
`.2dt` files, not from the `resinfo\if*.txt` layouts the older `CIF*` windows use. This project
reads them with `client/scripts/ui/twodt_reader.gd` and builds them with
`client/scripts/ui/twodt_builder.gd`. No game data is in this document or the repository.

Binary: `sro_client.exe`, md5 `2a5794b72c90908d945be8b3f3f2edd4`. Addresses are its VAs. Every
fact is labelled:

- **read**: read out of the binary (asm or decompile at the cited address);
- **measured**: counted in the retail files by a script or by `client/tools/check_2dt_files.gd`;
- **inferred**: a conclusion from read or measured facts, with its basis. Not a reading.

## Where they are

42 files, all in `Media.pk2` under `res_ui\` (measured: none in Data, Map, Music or Particles).
Every one is loaded through `0x469140(path, parent, 0)` on the loader singleton `0x115dd40`
(read), by the class or game-state code that pushes its name. `nifsimplemsgbox.2dt` is never
loaded: its name is not in the exe as ASCII or UTF-16 (measured, two probes).

## Container (read, measured)

```
u32    count                   ReadFile(h, &count, 4)          0x48f983..0x48f990
record[count], 0x3d0 each      ReadFile(h, buf, 0x3d0)         0x48f9b5..0x48f9c7
```

There is no other header and no trailer. **A file that is not exactly `4 + count * 976` bytes is
refused** by the reader. Measured with `check_2dt_files.gd`: 42 of 42 files are exact, 2312
records in all.

## Record (976 bytes)

Offsets are relative to the record buffer (`[esp+0xac]` at the top of the loader's loop
`0x48f9a4..0x48fc7e`); the per-record factory is `0x489b80`.

| off | type | field | meaning | label | where |
|---|---|---|---|---|---|
| 0x000 | char[64] | name | runtime class name for types 0, 1, 4, 8, 15, 18, looked up in the class registry `0xb9b6a0`; a miss keeps the type's default class. Non-empty also queues the window for message `0x8065` (its OnCreate) once the whole file is loaded | read | `0x48a295..0x48a2c2`; queue `0x48fbaf..0x48fc2b`; sent at `0x48fca9` |
| 0x040 | char[256] | base | frame / tile art of types 0, 1, 2, 3, 9; empty = the type's default | read | `0x48a2e8` (`add eax,0x40`, type 1), the same in cases 0, 2, 3, 9 |
| 0x140 | char[256] | texture | art of types 4, 5, 8, 10, 11, 15, 16, 18, 19 | read | e.g. `0x48ab65` (type 16) |
| 0x240 | char[128] | text id | a text-table key, converted to wide, looked up in `0xeede90` (`0x8c9bb0`) and set with SetText (vslot `0xbc`) | read | `0x48af85..0x48afc6` |
| 0x2c0 | char[64] | comment | designer's comment (cp949). Only the loose-file branch copies it; the pk2 branch never reads it | read | `0x48f6a1..0x48f6f2` |
| 0x300 | char[64] | sample text | shown only in editor mode (`singleton(0x115e9c8)+0x40`) when the text id is empty. **Never drawn by this client** (see Text) | read; "not shown in retail" inferred | `0x48b058..0x48b090`, `0x48b151..0x48b224` |
| 0x340 | u32 | type | 0..20, the switch at `0x489d64` (`jmp [eax*4+0x48b398]`) | read | `0x48fa13` |
| 0x344 | u32 | id | control id; 0 = assigned by the loader | read | `0x489bfb..0x489c03` |
| 0x348 | u32 | parent | the parent's id; the root's is replaced by the load parent's | read | `0x48fb51` |
| 0x34c | u32 | grandparent | the parent's parent's id; 0 = the load parent | read | `0x48fb5a..0x48fb6d` |
| 0x350 | u32 x2 | — | 0 in all 2312 records; read by neither branch | measured / read (absent) | — |
| 0x358 | u32 ARGB | colour | stored into the control's text object | destination read; "text colour" inferred | `0x48af4b..0x48af69` |
| 0x35c | i32 x4 | rect | x, y, width, height in the designer's screen space | read | `0x48f9c9..0x48f9f6` |
| 0x36c | f32 x8 | uv | passed to `0x46d110`, stored at wnd+0x21c..0x238 | read | `0x48faa2..0x48fae4` |
| 0x38c | u32 | tab group | CNIFTabButton only (the `IsKindOf(0x115dfc8)` test) -> wnd+0x368 | read | `0x48fae9..0x48fb09` |
| 0x390 | u32 | tab pane | CNIFTabButton only -> wnd+0x36c: the id of the sibling the tab shows; `0xffffffff` = none | read | `0x48fb0f`, used at `0x47a20e` |
| 0x394 | u32 | root flag | 1 on the root; pushes the window on the returned root list | read; measured (42 of 42 files: exactly one, record 0) | `0x48fb15` |
| 0x398..0x39a | u8 x3 | style | text-object style bits (`0x4774f0` / `0x477690`, +0x68) | read; 0 everywhere (measured) | `0x48aeb1..0x48af34` |
| 0x39b | u8 | font | index into the font table `0x115e1f4` | read; 0 everywhere (measured) | `0x48aea5..0x48aeef` |
| 0x39c | u32 | — | -> text object +0x98 and +0x18 | read; 0 everywhere | `0x48af71..0x48af82` |
| 0x3a0 | u32 | — | CNIFTextBox only -> wnd+0x374 (0 means 23) | read | `0x48b0b7..0x48b0d3` |
| 0x3cd | u8 | halign | -> text object slot 5 | destination read; meaning inferred | `0x48ae6a..0x48ae81` |
| 0x3ce | u8 | valign | -> text object slot 6 | destination read; meaning inferred | `0x48ae86..0x48ae9d` |

Strings are C strings (read with `strlen`). The four the reader decodes (name, base, texture,
text id) are plain ASCII in all 42 files (measured); the comment and sample text are kept as
bytes and never decoded.

## Types (read, the switch at `0x489d64`)

| type | class | default art (the string its case pushes) | art field |
|---|---|---|---|
| 0 | CNIFMainFrame (by name) | `interface\frame\mframe_wnd_` | base |
| 1 | CNIFFrame (by name) | `interface\inventory\int_window_` | base |
| 2 | CNIFNormalTile | `interface\ifcommon\bg_tile\com_bg_tile_b.ddj` | base |
| 3 | CNIFStretchWnd | `interface\ifcommon\com_blacksquare_` | base |
| 4 | CNIFButton (by name) | `interface\ifcommon\com_button.ddj` | texture |
| 5 | CNIFStatic | — | texture |
| 6 | CNIFEdit | — | — |
| 7 | CNIFTextBox | — | — |
| 8 | CNIFSlot (by name) | — | texture |
| 9 | CNIFLattice | `interface\ifcommon\lattice_window\com_lattice_` | base |
| 10 | CNIFGauge | `interface\playerminiinfo\pmi_hp.ddj` | texture |
| 11 | CNIFCheckBox | `interface\ifcommon\com_checkbutton02_on.ddj` | texture |
| 12 | CNIFComboBox | — | — |
| 13 | CNIFVerticalScroll | (its class draws its own) | — |
| 14 | CNIFPageManager | (its class draws its own) | — |
| 15 | CNIFBarWnd (by name) | — | texture |
| 16 | CNIFTabButton | — | texture |
| 17 | CNIFBothSidesGauge | — | — |
| 18 | CNIFWnd (by name) | — | texture |
| 19 | CNIFSliderCtrl | `interface\recovery\re_selectbar.ddj` | texture |
| 20 | CNIFSpinButtonCtrl | — | — |

Counts over the 2312 records (measured): `0:25 1:60 2:89 3:61 4:223 5:1116 6:12 7:4 8:165 9:1
10:16 11:88 12:22 13:27 14:4 15:219 16:29 17:2 18:146 19:3`, and no type 20.

## How the loader builds a window

**Coordinates (read).** Record 0 is created under the load parent at its authored rect
(`0x48f9e0..0x48fa1f`); every other record is created under record 0 at `(x - x0, y - y0, w, h)`
(`0x48fa40..0x48fa93`, x0/y0 saved at `0x48fa36`). The window factory `0xba20b0` stores the rect
and adds the parent's absolute position (`0xba223e..0xba2247`). So a record's position relative
to the file's root is its authored rect less record 0's.

**Parents (read, `0x48cb00`).** Ids are not unique within a file (41, 52, 72, 341 and others
repeat), so each record is linked by the pair (parent 0x348, grandparent 0x34c): the loader walks
the windows it has created (the list at loader+4, appended at creation by `0x48d7f0`) for one with
`id == parent` whose own parent's id is the grandparent (`0x48cba3..0x48cbbc`), restricted to the
same file's windows (+0x1f8 is the file's root window, set at `0x48fa9c` and compared at
`0x48cbce`). A grandparent of 0 is the load parent. A pair that matches nothing leaves the window
under the root, where it was created: `0x48cb00` returns 0 without moving it. **Guard:** once the
parent is found, `0x48cb00` asks it for a direct child with the record's own id (GetChild,
`0x48cbe6..0x48cbf7`) and does not re-link when it already has one; the record stays under the
root. **Parent 0:** the id is first compared with loader+0x3c (`0x48cb0f`), which is 0 (stored at
`0x48999a`; its setter `0x48cd60` has no direct caller), so a parent id of 0 takes that first
branch, finds loader+0x38 empty and returns at `0x48cc27` without a move. Linking moves a
window between child lists (AddChild, vslot `0x1c`, a push_back) and does not move it on screen.
Measured with the reader's rule (earlier records only, with the guard): **2310 of 2312 records
link, none ambiguously, none needs a later record, and the guard leaves none behind**; the other
2 have parent 0 (`cumunity_note` #111, id 58, and `nifstallnetworkmsgbox` #17, id 26) and stay
under the root.

**Order (measured, not read).** Records are created and appended in file order. The data says
file order is **back to front**: in 690 of 694 overlapping sibling pairs of a NormalTile and a
content control (anything but a frame or stretch border), the tile comes first
(`check_2dt_files.gd`'s ORDER line). That is the opposite of the `.txt` layouts, whose frame is
the last entry. The render loop was not read.

**Visibility at creation (read, with one inference).** The window base constructor `0xb9e270`
(vtable `0xe08f0c`) sets the visible byte +0x61 to 1 (`0xb9e284`); `0xb8f530` is the visibility
test that reads it. That this constructor runs for every CNIF window is inferred from their RTTI
chains (`CNIFWnd : CGWnd : ...`). Windows start visible; OnCreate handlers hide what they hide.

**OnCreate (read) -- in reverse file order.** After the whole file is loaded, every record with a
non-empty name gets message `0x8065` (`0x48fca9`), which runs its class's handler from its message
map. The queue is filled with a **push_front**: `0x48fc09..0x48fc2b` takes the list's first node
(`edi = [head]`) and inserts a node before it (`0x46bf60` builds `{next = arg1, prev = arg2,
value = *arg3}` with next = that first node, prev = its prev, the head), where the root list at
`0x48fb1f` is a push_back (next = head, prev = head's prev). The send loop `0x48fc84..0x48fcbd`
walks from the front. So **the last named record gets 0x8065 first and record 0 last**: a
window's own handler runs after all of its named children's. A handler can load further files
(the guild window loads four), which queue and send their own the same way when each load ends.
Two consequences the guild window shows: a list class that its rows join in their OnCreates
(each pushing itself to the front of the list, e.g. `0x5a92b0`) ends up with the rows in file
order, and a window's OnCreate can rely on its children's (FriendWnd's +0x798, set in its own
OnCreate at `0x5a9a28`, is read by the refresh a later SetCheck triggers). An earlier version of
this document said "in file order"; that was wrong.

## Art per type

All read, from the factory's cases and the classes' texture setters:

- **0, 1 (frames):** the base expands to eight pieces, `left_up`, `mid_up`, `right_up`,
  `left_side`, `right_side`, `left_down`, `mid_down`, `right_down` + `.ddj` (`0x4745a0`), set with
  vslot `0xc8`. Each piece is drawn at its own size (round 584, `0x474d00` / `0x4736a0`).
- **3 (stretch):** six pieces, `left_up`, `left_side`, `left_down`, `right_up`, `right_side`,
  `right_down` (`0x49b040`). No `mid_up` / `mid_down`, and the archive has none for these bases.
- **2 (tile):** one texture.
- **9 (lattice):** four cell pieces, `left_up`, `right_up`, `left_down`, `right_down` (`0x49d030`).
- **15 (bar):** a texture ending in `.ddj` is cut after its last `_` (`0x4733a0` rfind `'_'`,
  `0x472b05`) and `left`, `mid`, `right` + `.ddj` appended (`0x472a40`).
- **16 (tab):** the texture cut after its last `_` plus `on.ddj`, `off.ddj`, `disable.ddj`
  (`0x47a4e0`, strings `0xe17ec0` / `0xe17ec8` / `0xe17ed0`), loaded into +0x370, +0x374, +0x378.
  **`on` is the checked piece**: a click puts +0x370 up on the tab it checks (`0x47a387`) and
  +0x374 on the ones it unchecks (`0x47a2f7`).
- **4 (button):** the texture, and `_focus`, `_press`, `_disable` variants from it (`0x4717b0`,
  strings `0xe17504`, `0xe174f4`, `0xe1750c`). Missing variants are common.
- **11 (check box):** the texture cut after its last `_`, plus `off.ddj` as the box (set with
  `0x470ce0` at `0x482ef2`) and `on.ddj` for the mark (a child window, `0x482bd0` at `0x482f2c`)
  (`0x482dc0`).
- **5, 8, 10, 18, 19:** the texture as it is, through the text object's vslot `0x34`. Case 5
  sets it only when the field is non-empty.
- **6, 7, 12, 13, 14, 17, 20:** no art from the record.

Measured by `check_2dt_files.gd` over all 42 files: **2555 of 2555 required pieces exist** in the
archive (frames, stretch sets, tiles, lattices, buttons, bars, tabs' on / off, check boxes'
on / off, plain textures). Optional pieces (buttons' `_focus` / `_press` / `_disable`, tabs'
`disable`): 604 of 698. 80 of the 283 textured statics, slots and plain windows are authored at a
rect other than their texture's size; how the client draws those (stretched, tiled or at size) is
**not read**, and this project stretches them.

## Text

The text id (0x240), if non-empty, goes through the text table and SetText. The sample text
(0x300) is used only when `singleton(0x115e9c8)+0x40` is set (`0x48b058`, `0x48b151`), and that is
the same byte as the loose-file flag the loader branches on (`0x469350` stores its third argument
to both, `0x46938a` / `0x4693f3`). The retail install has no loose `res_ui` directory (measured),
so the pk2 branch is the live one and **the sample text is never shown** (inferred from those two
reads and the measurement). Designer strings such as a Korean placeholder in the friend rows must
not be drawn, and this project never draws them.

The colour (0x358) goes to the text object (read), so it is used as the text colour (inferred:
white on 2146 records, gold `ffefdaa4` on 52 labels, cream `fffff7ca` on 27 button captions).
It also sits on tiles that draw no text, so it is **never a tint**.

The alignment bytes go to the text object's slots 5 and 6 (read), the same text-board slots the
`.txt` layout builder feeds HAlign and VAlign into (round 586). The values are taken as 0 =
left / top, 1 = centre, 2 = right / bottom, the mapping the `.txt` path uses; that is
**inferred** (gold `label :` statics use 2,0 and end just left of their value field). The code
that consumes +4 / +8 of the text object was not traced.

## Tabs (read)

- **SetCheck** `0x47a200`: the checked look (`0x47a950`), then
  `parent->GetChild(pane)->ShowWindow(checked)`. `GetChild` (`0x46e060`) searches direct
  children only, so a tab's pane is its sibling.
- **Click** (`0x47a240`, message `0x202`, the button's release): the siblings with the same group
  (`0x46e0d0`) are unchecked (their look, unless locked, +0x3d1) and their panes hidden; then the
  tab is checked and its pane shown (`0x47a3bb..0x47a3dd`); then the parent is notified
  (`0xb8f150`), whose message map sees message 1 with the tab's id.

## The MainFrame chrome (read, `0x479a50`)

A type-0 window gets three children, at rects relative to it (`W` its width, read with
`0xb8f420`):

| part | class | id | rect | art |
|---|---|---|---|---|
| caption | CNIFStatic (`0x115e090`) | 0xffff | (10, 12, W-21, 12) | the window's SetText (vslot `0xbc`, forwarded to it); font 0; text-object slots 5 = 1, 6 = 0 (`0x479bf6`, `0x479c0b`) |
| drag area | CNIFDragableArea (`0x115e0b0`) | 0xfffe | (10, 0, W-21, 34) | — |
| close | CNIFButton (`0x115dec0`) | 0xfffd | (W-26, 10, 16, 16) | `interface\ifcommon\com_windowclose.ddj` (`0xe17d70`) |

These are the same numbers as CIFMainFrame's (`0x816f80`, round 586). The caption's colour is not
set here and is not read.

## Not established

- The sibling draw order (the data's back-to-front is measured; the loop is not read). The four
  exceptions are statics before an overlapping tile in `nifstallnetworkmsgbox`,
  `open_market_main`, `silkrecievelist` and `silksearch`.
- What the alignment values mean, beyond where they are stored.
- How a textured static, slot or plain window is drawn when its rect is not its texture's size.
- The style bytes 0x398..0x39a, 0x39c, 0x350 and 0x3a4..0x3cc (zero in all data).
- What the first branch of `0x48cb00` does when loader+0x38 is set (it re-links a pending list to
  it). Nothing sets loader+0x3c or +0x38 through a direct call, and parent-0 records return at
  `0x48cc27`.
- The classes' own art for types 6, 7, 12, 13, 14, 17 and 20 (the vertical scroll's
  `com_scroll_bar` / `chat_arrow_up` / `chat_arrow_down`, the page manager's
  `mall_page_next` / `mall_page_prev`) is not built.
