# Notice banners and the area banner (round 703)

The centre-screen banners of the original client: the two CIFNotify instances (the pink-red GM
notice and the blue warning that carries the level-up line, the unique notices and some seventy
other lines) and the CIFRegionView area banner shown on walking into a named area. Built in
`client/scripts/ui/hud/hud_notice.gd` and `client/scripts/ui/hud/hud_region_view.gd`; checked by
`client/scripts/ui/hud/hud_notice_test.gd`.

Labels: READ = read from `sro_client.exe` or the data; MEASURED = counted from real files or from
reference pixels; INFERRED = follows from what was read but was not read itself; OURS = srrevamp's
choice. Addresses are `sro_client.exe` virtual addresses.

## The kinds

| Kind | Instance (ginterface.txt) | Fill / art | Frame | y | Text | Life |
|---|---|---|---|---|---|---|
| GM notice (chat type 7, `0x876810`), guild created (`0x8852c0`), `0x887330`, arena (`0x89f860`) | GDR_NOTICE, child 0x14, via `0x777bf0` | (128, 45, 67), the pink-red banner | `com_notice_edge/edge2/corner.ddj` | 100 | 12 px, weight 600, white, no shadow, centred | 7000 ms, the last 2000 fading |
| Level-up (`0x8a97c0`), unique appeared/killed (`0x874ea0`, 15 sites), recall point, siege, training camp, the error dispatcher `0x7b8b40`, ~70 sites | GDR_WARNING_WND, child 0x23, via `0x77b580` | (0, 52, 92), the blue banner | `com_warning_*.ddj` | 130 | the same | the same |
| Area entered (`0x783610`, `0x786f30`) | GDR_REGION_INFO_VIEW, child 0x53, `#ifdef EUROPE_SYSTEM` | `interface\game\area_deco.ddj`, (0, 37, 73) | none | 95 (window) | title 20 px x1.5, weight 600, cyan (61, 253, 255), shadow; line 2 15 px white, shadow; line 3 11 px (255, 255, 92), shadow | fade in 0.5 s, held to 3 s, fade out 0.5 s |

All READ except the colour names. The fills and y values are CGInterface's set-up (round 657:
`0x78cbbe`, `0x78cbed`, `0x78cbd2..0x78cbe8`, `0x78cd00..0x78cd12`, frame names
`0x78cc0d..0x78ccfb`). There is no other colour: the user remembered a "pinkish red" kind, and it
is GDR_NOTICE's fill. The layout's `Color=` lines (GDR_WARNING_WND "255,119,119,251", GDR_NOTICE
"255,236,174,252") are not read by the resinfo parser (`0x82c1d0`).

## CIFNotify (READ)

- **Show** `0x7b3eb0`: life `+0x7c8` = 7000; the text set on GDR_NOTIFY_TXT and measured
  (`0x8b2f20`); window and static sized to the extent; x = W/2 - w/2 by two truncating halvings
  (`cdq; sub; sar` at `0x7b3f0b..0x7b3f24`), y = `+0x7d4`; `0x8185e0(w, h)` and
  `0x8182e0(x, y, 1.0)` lay the frame out; alpha 255. A second show replaces the first: no queue.
  The two instances are separate windows, so a GM notice and a warning are up together, 30 px
  apart (bands at y 92..122 and 122..152 for 14 px text).
- **Update** `0x7b3e20`: the life counts down by the frame time; at 2000 ms or less (`< 0x7d1`) the
  alpha is remaining * 255 / 2000; at 0 the window and the text hide. A child's alpha is its own
  times its parent's / 255 (`0x652670`), so the text fades with the band.
- **Render** `0x7b3cb0` (vslot 13): while shown (`+0x7cc`), a quad over the window's rect in the
  fill colour with alpha byte `-0x80 - (0xff - a) / 2` (128 at full; untextured, texture-factor
  colour, `0x654d10`), then the stretch frame (`0x81a450` -> `0x819d80`).
- **Create** `0x7b3fe0` (vslot 10): `resinfo\ifnotify.txt` (GDR_NOTIFY_TXT: FontColor
  255,255,255,255, FontIndex 0, HAlign 1); frame `0x819690("edge2", "edge", "edge2", "edge")` --
  the strings built at `0x7b4069..0x7b40e2`, last argument first -- and corner `0x8199e0("corner")`;
  UV modes `0x818d30(0)`, `0x818a50(0)`; text flags `0x8b44b0(5, 2)`.

## CIFStretchWnd, the frame (READ)

`0x8182e0(x, y, z)` with the window's w x h (`+0x7bc`, `+0x7c0`) writes eight quads, every one
**outside** the window's rect, each piece its own texture's size (`GetLevelDesc` via
`0x819690`/`0x8193d0` -> `0x818120..0x818180`, `0x818200..0x818260`):

| Quad | Rect | Texture | UV (mode 0) |
|---|---|---|---|
| TL corner | (x - cw, y - ch) .. (x, y) | corner `+0x37c` | as authored |
| TR corner | (x + w, y - ch) .. (x + w + cw, y) | corner `+0x380` | mirrored in u |
| BR corner | (x + w, y + h) .. (x + w + cw, y + h + ch) | corner `+0x384` | mirrored in u and v |
| BL corner | (x - cw, y + h) .. (x, y + h + ch) | corner `+0x388` | mirrored in v |
| left | (x - lw, y) .. (x, y + h) | edge2 `+0x38c` | as authored |
| top | (x, y - th) .. (x + w, y) | edge `+0x390` | as authored |
| right | (x + w, y) .. (x + w + rw, y + h) | edge2 `+0x394` | mirrored in u |
| bottom | (x, y + h) .. (x + w, y + h + bh) | edge `+0x398` | mirrored in v |

Every vertex is then moved by -0.5 (`0xe1b7d0`), D3D9's pixel-centre alignment. `0x819d80` draws
them point-sampled (sampler states 5 and 6 set to 1) with alpha = texel alpha x window alpha
(texture factor `a << 24`, alpha op modulate).

MEASURED (Media.pk2): all six frame textures are A8R8G8B8 of one colour each -- com_notice_*
(128, 45, 67), com_warning_* (0, 52, 92). corner and edge2 40 x 8, edge 4 x 8. edge2's alpha runs
0 -> 127 across its 40 columns (the same in all 8 rows); edge's rows are 51, 89, 128, 128, ...;
corner is both (rows 0 and 1 reach 53 and 89, rows 2-7 reach 127). So the band is the text's rect
plus a 40-pixel horizontal fade each side and an 8-pixel lip above and below whose outer two rows
fade: (w + 80) x (h + 16), at alpha 128 inside.

## Text flags (READ)

The text object at a static's `+0x90` keeps flags per state at `+0x50..+0x5c` and the current set at
`+0x60` (`0x8b4400` sets, `0x8b44b0` ORs; state 5 = all). `0x8b39e0` picks the glyph face:
flag 2 -> face variant 2, else flag 0x40 -> variant 1, else 0. The variants are created in
`0x00baa110` from the same face name: 1 italic, 2 lfWeight 600, 3 underlined. Flag 1 is the drop
shadow: `0x8b48b0` passes `flags & 1` to `0x8b2290`, which draws the glyph first at (+1, +1) in
black at the text's alpha, then the glyph in its colour. `0x8b2290` samples point at scale 1
(`|scale - 1| <= eps`) and linear otherwise.

| Static | Flags | Means |
|---|---|---|
| GDR_NOTIFY_TXT | 2 (`0x8b44b0(5, 2)`) | weight 600, no shadow |
| GDR_STA_REGIONNAME | 3 (`0x8b4400(5, 3)`) | weight 600 and shadow |
| GDR_STA_REGIONEXPLAIN, GDR_STA_LVEXPLAIN | 1 (`0x8b4400(5, 1)`) | shadow |

## CIFRegionView, the area banner (READ)

- **Trigger.** GlobalDataManager::FUN_00783610 (every position update) and the world's set-up
  `0x786f30` (at `0x787609..0x787660`) take the player's region id (`+0x7c`); if not 0,
  `0x665aa0(id)` looks the code up (CGame::FUN_00842a00, CGame's map at `+0x63c`) and
  - no code -> the remembered code (`+0x36c`) is cleared, no banner;
  - the remembered code -> no banner;
  - another code -> `0x665d00` sets the texts and remembers the code, then
    `0x6526e0(0, 255, 0.5 s, 0, 1)` fades the window in.
- **The codes.** Game::FUN_00844310 loads `textdata\regioncode.txt` (ANSI, tab-separated: service,
  region id, code, Korean note): a row is kept when `atol(service) != 0` and the id column is set,
  unless the code is exactly `xxx` (`0xdae70c`); the first row of an id wins. MEASURED on the box's
  archive: 3,144 rows with service 1, 146 distinct codes, every one with a `_01` text. The ids pack
  regions as `(x << 8) | y` -- 25000 is Jangan's 97/168, as in textzonename.txt.
- **Texts** `0x665d00`: code + `_01` (`0xda10ac`) -> title (child 1), + `_02` -> line 2 (child 0xb),
  + `_03` -> line 3 (child 0xc), through the text manager `0x8c9bb0` (textzonename.txt). Lines 2
  and 3 are blanked when the text is exactly `xxx` (`0xd81d38`, length 3). A fortress town's line 3
  becomes UIIT_MSG_FORTRESS_TOWN_GUILD_NAME with the owner guild (not built: no fortress data).
- **Timing.** The fade `0x6552f0`: alpha = trunc(from * (1 - t) + to * t) over 0.5 s. vslot_012
  `0x6656f0` starts the fade out (255 -> 0, 0.5 s) once more than 3000 ms have passed since the texts
  were set (`+0x388`). The fade's end (`0x652850`) hides the window when its target alpha is 0.
- **Layout** (`0x6657f0`, `0x665740`; W/2 by `shr`; `0xb42d10` truncates):
  - window 744 x 104 (`0x2e8 x 0x68`) at (W/2 - 372, 95);
  - title at x = W/2 - trunc(w x 1.5 x 0.5), y = 119 - trunc(h x 1.5 x 0.25), scale 1.5
    (`+0xcc` = `0xd819ec`);
  - line 2 static at (W/2 - 343, 156), 691 x 13, centred; line 3 at (W/2 - 214, 177), 427 x 11.
- **Layout file** `resinfo\ifregionview.txt` (`0xda1038`): GDR_STA_REGIONNAME FontColor
  (255,61,253,255) FontIndex 4; GDR_STA_REGIONEXPLAIN white FontIndex 3 HAlign 1 VAlign 1;
  GDR_STA_LVEXPLAIN (255,255,255,92) FontIndex 1.
- **Art.** ginterface.txt's GDR_REGION_INFO_VIEW DDJ `interface\game\area_deco.ddj`. MEASURED:
  708 x 104, A8R8G8B8, one colour (0, 37, 73), alpha 4 at both ends rising to 151 over ~300 columns
  with a plateau in the middle, the same in every row. INFERRED: CIFWnd draws it over the window's
  rect, stretched to 744.

## What srrevamp builds

- `HudNotice`: the fill over the text's rect and the eight frame pieces outside it, mirrored
  through the canvas transform; the text in the face's weight-600 variant with no shadow.
  `HudNotice.style_for_kind` is the kind table above.
- `HudRegionView`: the trigger rule, the texts, the fade and the layout above, fed from the
  archive's regioncode.txt and textzonename.txt; called from `World3D._update_zone_label_for_region`
  on every region the player enters and once when the HUD is built.
- OURS: the weight-600 face is the system's own bold file of the UI face when there is one (as
  GDI picks it); otherwise FreeType's embolden at 16 / size, which thickens a 12 px stem from 1 to
  2 px. EUROPE_SYSTEM is treated as defined (the user chose the Europe content on, round 682), so
  the area banner exists. The area banner draws under the two notice banners.

## The broken band before round 703

Round 634's HudNotice drew the fill over the text's rect and the frame pieces **inside** it: the
left and top pieces at 0..40 and 0..8 over the fill, the right and bottom ones through rects of
negative size. Godot 4.2's `canvas_item_add_texture_rect` turns a negative size into a flip but
keeps the rect's position as its left/top edge (READ, servers/rendering/renderer_canvas_cull.cpp),
so `Rect2(w, 0, -40, 8)` lands at w .. w + 40: the right and bottom pieces sat a piece's width out,
each at a different height (top-right corner at 0..8, right edge at 8..h-8, bottom-right corner
below the rect, bottom edge below it from 40 to w - 40). That is the hard rectangle hugging the
text and the broken streaks and gaps to its right, in every renderer. The texture loading was not
at fault: the six frame textures are A8R8G8B8 and decode with their alpha.
