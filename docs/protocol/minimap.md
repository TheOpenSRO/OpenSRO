# The minimap (CIFMinimap), and how a CIFStatic lays out its text

Read from the client's decompile and disassembly on the RE box (round 630). Every value below is
labelled READ (from the binary or the archive's own data), MEASURED (counted in real data or a
render), INFERRED, OURS or OPEN. `HudMinimap` (`client/scripts/ui/hud/hud_minimap.gd`) implements
it; `World3D.place_minimap` places it.

## The window

- READ: `resinfo\ginterface.txt` registers `GDR_MINIMAP` (`CIFMinimap`, id 10) at `892,6` and
  `140x184`, artwork `interface\minimap\mm_window.ddj`. MEASURED: that DDJ is 140x184 (round 630's
  `dump_ddj_sizes.gd`), opaque over columns 0..128 and rows 0..171 only.
- READ: the interface's HUD placement `0x79f030` (called from `0x78cf13`) fetches child 10 and calls
  its SetPos (vslot `0x98`) with `(screen width - 0x81, 0)` (`0x79f059..0x79f095`). So the art's
  129 opaque columns end at the screen's right edge and its top is the screen's top; the 11
  transparent columns hang off the edge. The ginterface rect's `892,6` is not where it is drawn.
- READ: `CIFMinimap::Create` (`0x660f70`) loads the sign textures, builds `resinfo\ifminimap.txt`'s
  `Create` section, keeps child 1's (`GDR_MINIMAP_ALPHA`) texture at `+0x370` and hides child 1
  (`0x66145e`: vslot `0x5c` with 0), and keeps children 8, 2, 3, 4, 5, 6 at `+0x414`, `+0x418`,
  `+0x41c`, `+0x420`, `+0x40c`, `+0x410` (map button, area name, X, Y, zoom-in, zoom-out).

| Child (ifminimap.txt) | id | Rect | Art | What the client does with it |
|---|---|---|---|---|
| `GDR_MINIMAP_DUNGEON_FLOOR_INFO` | 10 | 1,42 32x32 | mm_dungeonfloor.ddj | Style 64: hidden at creation; shown only in a dungeon region (below) |
| `GDR_MINIMAP_BTN_TOG_MAP` | 8 | 99,47 24x24 | mm_map_button.ddj | message map `0xeb77d0`: id 8 -> `0x6606a0` -> `0x79abe0` (world map) |
| `GDR_MINIMAP_TEXT_POS_Y` | 4 | 67,32 56x11 | | `Y:%3d` |
| `GDR_MINIMAP_TEXT_POS_X` | 3 | 8,32 56x11 | | `X:%3d` |
| `GDR_MINIMAP_TEXT_AREANAME` | 2 | 12,9 104x12 | | the area's name |
| `GDR_MINIMAP_ZOOMOUT` | 6 | 90,152 20x20 | mm_zoomout.ddj | `0xeb77a8`: id 6 -> `0x660660` |
| `GDR_MINIMAP_ZOOMIN` | 5 | 107,136 20x20 | mm_zoomin.ddj | `0xeb7780`: id 5 -> `0x660620` |
| `GDR_MINIMAP_ALPHA` | 1 | 14,57 105x105 | mm_alpha.ddj (104x104) | hidden; its texture is the map's mask, its rect the aperture |

The black ring a player saw left of the globe was child 10. READ: the resinfo layout builder hides
a control whose Style has bit `0x40` at creation (`0x8b5710..0x8b5726`: `0x652da0(0x40)`, then
vslot `0x5c` with 0), and `0x661ce0` shows child 10 only while the region id's top bit is set
(`0x661d65..0x661def` keep `player+0x7c >> 15`; `0x6620db..0x662101` call its vslot `0x5c` with
that bit) -- the same bit that switches the tiles to `minimap_d\`. MEASURED: 92 of the archive's
3,754 resinfo controls carry Style bit `0x40` (43 of them in ginterface.txt). OPEN: `UiBuilder`
does not honour the bit in general; `HudMinimap` hides child 10 itself. The others (for example
ifplayerminiinfo's `GDR_PMI_RACE_MARK`, `GDR_PMI_CIRCLE0..4`, `GDR_PMI_SELECT`) are each window's
own business.

## The map

READ, from `0x661ce0` (run every frame by vslot_012 `0x662510`) and the draw vslot_013 (`0x662bd0`):

- `+0x424` / `+0x428` are the player's region id's low and high bytes (`player+0x7c`); `+0x3e0`,
  `+0x3e4`, `+0x3e8` its region-local x, y, z (`player+0x80..0x88`).
- Nine tiles, `+0x378` onward, filled by the loop at `0x662271..0x6622a3` with
  `"%s%dx%d.ddj"` (`minimap\` outside a dungeon) of `(low byte - 1 + i) x (high byte + 1 - j)`,
  `i` outer and `j` inner, 0..2. So `i` runs west to east and `j` north to south, and the file name
  is `minimap\<region y>x<region x>.ddj` in this project's naming (AGENTS.md).
- `+0x3fc` is the drawn size of one region in pixels, `+0x400` the size it is walking toward. Both
  start at 160.0 (`0x660c42`: `0xda0b6c`). Zoom-in (`0x660620`) adds 19.2 (`0xda0b60`) to the
  target, capped at 256.0 (`0xda0b5c`); zoom-out (`0x660660`) takes 19.2 off, floored at 64.0
  (`0xda0b68`). Eleven levels, five each side of 160. Each frame the drawn size moves toward the
  target by `[0x110f7f8] * 0.05` (`0xda0ee0`) and stops on it (`0x662569..0x6625ec`).
  `0x110f7f8` is the frame timer's `+0x98`, capped at 3000 (`0xba40fb..0xba410d`). INFERRED: it
  counts milliseconds, so the walk is 0.05 px per ms.
- `+0x404 = S * x / 1920` and `+0x408 = S * (1920 - z) / 1920` (1920 is `0xe1b800`); tile `(i, j)`
  is drawn at `((i - 1) * S - +0x404 + w * 0.5, (j - 1) * S - +0x408 + h * 0.5)` in the aperture
  (child 1's rect, `w = h = 105`), clipped to it, with the mask as texture stage 0. So an image's
  rows run north to south and the player's point is always the aperture's centre.
- MEASURED: decoded with this project's DdjReader, tile `168x97`'s bottom row continues `168x96`'s
  top row (mean RGB difference 13.8, against 31.7 the other way round), `169x96` continues
  `168x96` to the east (10.0 against 24.8): the images are upright.
- MEASURED against the terrain: for every navmesh tile of six regions around Jangan (96/168, 97/168,
  96/167, 95/168, 96/169, 98/168) the texel under the tile's point is greener on grass tiles than on
  the rest by 0.022..0.104 (green minus the mean of red and blue) under this rule, and by
  -0.011..0.008 under the old `v = z / 1920`. At the report's spot, 96/168 local (1140, 1230), the
  terrain is `c_dust_fld_06` (dirt) and the READ rule's texel is brown (114,84,32); the old rule read
  the point mirrored about the region's middle, (1140, 690), which is `c_grass_fld_05`.
- OPEN: each tile's colour is modulated by a colour from `0x9edd60`'s object, scaled by 400
  (`0xd878a8`) and capped at 255 (vslot_013's tile loop). Not replicated.
- OURS: the draw's `-0.5` (`0xe1b7d0`) on every vertex is Direct3D 9's texel-centre offset; Godot's
  2D pixel centres already sit at .5, so it is not applied.

## The signs and the arrow

- READ (vslot_013, `0x6636f1..0x663887`): for a monster, NPC, animal or other player the sign's
  centre is `(w * 0.5 + S * dx, h * 0.5 - S * dz)` with `dx`, `dz` the entity's position less the
  player's over 1920 (`+0x90`/`+0x98` less `+0x80`/`+0x88`), and it is drawn only when that point's
  distance from the centre is less than `w * 0.5 - 8.0` (`0x663759..0x66377a`) -- 44.5 here. The
  quad is +-4 (`0xe1b860`) whatever the art's size. Which art: monster `+0x3ac`, or unique `+0x3b0`
  when the monster's `+0x7ac` is 3 or 8; animal `+0x3c8`; NPC `+0x3b4`; other player `+0x3b8`
  (the class checks at `0x663787..0x66380f`). OPEN: unique, animal, party, quest-NPC and the party
  and quest arrows (a 32x32 quad, +-16, `0xda0ef8` / `0xe1b8e0`, drawn instead of the sign when the distance vslot_013 computes for it is 47.0 (`0xda0ef0`) or more; its unit was not traced) are not drawn by
  `HudMinimap`, which has no data for them.
- READ: the arrow is a 16x16 quad (+-8, `0xd99a70` / `0xd89240`) about the aperture's centre,
  turned by `-(+0x3ec)` (`0x665366`: `fmul` by -1.0, `0xe1b8e8`) through `0x8b5c50`, which computes
  `(x cos - y sin, x sin + y cos)` with `0xb44a10` the cos (`fcos`) and `0xb44b40` the sin (`fsin`):
  clockwise on the y-down screen. `+0x3ec = player+0x8c - pi / 2` (`0x661dc5`, `0xe1b8f0`).
- MEASURED: `mm_sign_character.ddj` points right: its tip is column 15, row 7 of 16.
- INFERRED: `player+0x8c` counts from south toward east, which is what makes the READ turn point the
  arrow along the facing. The heading's writer was not traced. `HudMinimap.arrow_rotation` turns the
  art by the angle of the facing's `(x, -z)` on the screen, the same thing for that origin.
- READ: the world map's marker is the same art turned the same way: `CNIFWorldMap` keeps
  `player+0x8c - pi / 2` at `+0x97c8` (`0x60f6a5`, `0x610a05`) and turns a +-8 quad by
  `-(+0x97c8)` (`0x6200de..0x620236`).

## How a CIFStatic lays out its text

READ: CIFStatic's layout `0x64d9b0` takes the rect `0x652800` fills (left, top, width, height) and
the text's extent (`+0xdc` wide, `+0xde` tall) and stores the text's top-left at `+0x370`/`+0x374`:

| | 0 | 1 | 2 |
|---|---|---|---|
| HAlign (`+0x88`) | left | left + (width - text w) * 0.5 | right - text w |
| VAlign (`+0x8c`) | top | top + (height - text h) * 0.5 | bottom - text h |

(`0x64da4d..0x64db39`; 0.5 is `0xe1b7d0`). The draw `0x64d940` truncates the two (`0xb42d10`, the CRT's float-to-int: `cvttsd2si`) and
hands them to `0x8b48b0`, unclipped. `0x8b48b0` walks the glyph runs and draws each with `0x8b2290`,
which puts the glyph's whole cell bitmap at `(x, y)` -- the cell's top at `y` -- and, when the text
board's `+0x60` has bit 1, first draws a black copy at `(x + 1, y + 1)`. So a text larger than its
rect overruns it evenly when centred and toward the top or left when bottom- or right-aligned.
`UiBuilder.place_label` lays a CIFStatic's text label by that rule (round 630);
`TwoDtBuilder.set_text` already did the same for `.2dt` windows (round 598).

MEASURED (the render box, where Tahoma is not installed and the archive's Arial fallback draws):
the minimap's X text has its cap top 2 px below its rect's top, where the retail screenshot's is 3
(measured on the report's 2x crop, frame matched at scale 2.00). Arial's ascent at 12 px (about
10.9) is a pixel short of Tahoma's (about 12.0), which accounts for it; the user's machine has
Tahoma. INFERRED, not measured with Tahoma.
