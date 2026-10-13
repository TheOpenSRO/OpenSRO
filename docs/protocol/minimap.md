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
3,754 resinfo controls carry Style bit `0x40` (43 of them in ginterface.txt). `UiBuilder` hides
every one of them at creation since the round 630 review (`STYLE_HIDDEN_AT_CREATION`); a window
that shows one later (the player info's orbs and race mark) sets it visible itself.

## The map

READ, from `0x661ce0` and the draw vslot_013 (`0x662bd0`). `0x661ce0` has two callers only: vslot_012
(`0x6625f4`), which reaches it only while the zoom is walking (`0x662510` returns early once the drawn
size is the target), and `0x777a70` (`0x777ac7`), which CICPlayer::vslot_015(3) sends when the
player's heading changes (`0x9d49db`, `0x9d5a5f`; the review's reading). The draw reads the stored
position every frame. OURS: `World3D._refresh_minimap` refreshes every physics frame instead.

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
- A region with no minimap file: `0x661ce0` stores the loader's null and the tile's quad is drawn
  with no texture, which Direct3D 9 samples as black (the review's reading). Drawn black here.
- OURS: `HudMinimap.tile_rect` floors each tile edge, so neighbouring tiles share an edge at the
  fractional sizes (the client's float quads share their vertices; snapping each Godot rect on its
  own left 1-pixel gaps). The tiles are kept in a bounded set of 25, missing names remembered.
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
  (the class checks at `0x663787..0x66380f`). The party's signs and arrows (round 717,
  `party_gui.md` section 9) and the tracked quest's NPC signs and arrows (round 785; a 32x32
  quad, +-16, `0xda0ef8` / `0xe1b8e0`, drawn instead of the sign when the distance vslot_013
  computes for it is 47.0 (`0xda0ef0`) or more; its unit was not traced) are drawn in `MapMarks`.
- READ, the sign art (`CIFMinimap::Create`, `0x660f70`; each path built by `0x425ae0` and
  loaded by `0x5008f0`, then stored):

  | Slot | File (`interface\minimap\`) | String | Store | MEASURED size |
  |---|---|---|---|---|
  | `+0x3ac` | `mm_sign_monster.ddj` | `0xda0e48` | `0x661082` | 8x8 |
  | `+0x3b0` | `mm_sign_unique.ddj` | `0xda0e20` | `0x6610d7` | 12x12 |
  | `+0x3b4` | `mm_sign_npc.ddj` | `0xda0dfc` | `0x66112c` | 8x8 |
  | `+0x3b8` | `mm_sign_otherplayer.ddj` | `0xda0dd0` | `0x661181` | 8x8 |
  | `+0x3c8` | `mm_sign_animal.ddj` | `0xda0ccc` | `0x66137f` | 8x8 |

  MEASURED (round 786, `Pk2Reader` and `DdjReader` over the box's Media.pk2): all five are in
  `interface\minimap\`; the unique's opaque pixels average (130, 37, 178), a purple, against the
  monster sign's red (176, 19, 19). All are drawn on the same +-4 quad: every class branch
  sets its texture and joins at `0x66382f`, which builds the quad from `0xe1b860`.
- READ, the class checks (`0x663780..0x66381c`), in this order, each `IsKindOf` (`0xb94b90`):
  CICMonster (`0xef1a84`): `+0x7ac` 3 or 8 -> `+0x3b0`, otherwise `+0x3ac`; else CICCos
  (`0xeef6f0`) -> `+0x3c8`; else CICNPC (`0xef1ac4`) -> `+0x3b4`; else CICUser (`0xef1bc0`) ->
  `+0x3b8`; else no sign. The loop (`0x6636d2..0x6639af`) walks one entity list (head
  `0xec4cec`, next at `+0xc`) and draws each entity's sign as it reaches it.
- READ, `+0x7ac`: CICMonster's spawn reader `CICMonster::vslot_025` (`0x9d3850`) reads one byte
  (`0x9d38c4`, `MsgStreamBuffer::Read`, 1), stores its low nibble at `+0x7ac` (`0x9d38de`
  `and cl,0xf`, `0x9d38e1`) and its high nibble at `+0x7ad` (`0x9d38e7`, the party flag, round
  660). The same function uses the low nibble to scale the model (rarity 1, 4, 6; round 660).
  INFERRED that the byte the server sends is characterdata's Rarity (`_RefObjCommon` column 15),
  which is what this project's server sends (`MonsterSnapshot.Rarity`, the species' column 15,
  `server/internal/nest/hatch.go`) and the client reads (`CombatNet.MonsterSnapshot.rarity`, the
  party bit 8 stripped). The byte's server-side source in retail was not read. MEASURED over the
  box's characterdata (13,297 rows), the 6,850 monster rows (TypeID 1/2/1) have Rarity 0 (6,123),
  1 (10), 3 (605), 4 (1), 6 (2), 7 (91) and 8 (18); the rarity-3 rows are the uniques
  (`MOB_TK_BONELORD`, "Lord Yarkan"; `MOB_CH_TIGERWOMAN`, `MOB_OA_URUCHI`, `MOB_KK_ISYUTARU`), the
  rarity-8 rows bosses of `TQ` and `RM` (`MOB_TQ_TOMBGENERAL`, `MOB_TQ_SNAKEGENERAL`,
  `MOB_TQ_BLACKSNAKE`, `MOB_RM_SPIRITS`, `MOB_RM_DEVILSAYTAN`, `MOB_RM_TAHOMET_ROC`,
  `MOB_RM_WINGTRIBEKNIGHT`, and their `_CLON` / `_L2` / `_L3` rows).
- Round 786: `HudMinimap.monster_sign_kind` is that rule (`"unique"` for rarity 3 or 8), and
  `World3D._build_monster_body` decides it once a body (`_minimap_unique_bodies`); the frame's
  `_minimap_fill_monsters` hands a unique to the `unique` kind of `MinimapSigns` and not to the
  monster list. OURS: `MinimapSigns` draws a kind at a time, the unique kind last, so a unique's
  sign is always over the rest; retail stacks signs by the entity list's order.
- OPEN: the animal sign (`+0x3c8`) is drawn for a CICCos, a pet, horse or transport (the class
  `CIFTargetWindow` also tells apart, `hud_target.gd`); this client builds no such body, so it has
  nothing to draw it for.
- READ: the arrow is a 16x16 quad (+-8, `0xd99a70` / `0xd89240`) about the aperture's centre,
  turned by `-(+0x3ec)` (`0x665366`: `fmul` by -1.0, `0xe1b8e8`) through `0x8b5c50`, which computes
  `(x cos - y sin, x sin + y cos)` with `0xb44a10` the cos (`fcos`) and `0xb44b40` the sin (`fsin`):
  clockwise on the y-down screen. `+0x3ec = player+0x8c - pi / 2` (`0x661dc5`, `0xe1b8f0`).
- MEASURED: `mm_sign_character.ddj` points right: its tip is column 15, row 7 of 16.
- READ (round 630 review): `0x9ed130` / `0x9c4260` store the heading `h` at `player+0x8c` in
  `[0, 2 pi)`, and `0x9ec850` turns it into the facing `(sin h, 0, -cos h)` (`0xb44b40` the sin,
  `0xb44a10` the cos): `h` counts from south (-z) toward east. So the client's `-(h - pi/2)` is the
  angle of the facing's `(x, -z)` on the screen, which is what `HudMinimap.arrow_rotation` computes.
- READ: the world map's marker is the same art turned the same way: `CNIFWorldMap` keeps
  `player+0x8c - pi / 2` at `+0x97c8` (`0x60f6a5`, `0x610a05`) and turns a +-8 quad by
  `-(+0x97c8)` (`0x6200de..0x620236`).

## How a CIFStatic lays out its text

READ: CIFStatic's layout `0x64d9b0` takes the rect `0x652800` fills and
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
The rect is the control's, inset by its ClientRect: `0x652800` adds `+0x18c` / `+0x190` to the left
and top and takes `+0x18c + +0x194` / `+0x190 + +0x198` off the width and height
(`0x65280e..0x65283b`), and `0x6527d0` copies those four from the parsed ClientRect
(`0x8b566e..0x8b5674`, the def's `+0x58..+0x64`) in the file's order: left, top, right, bottom. 60
CIFStatics and 238 CIFButtons carry a non-zero one. CIFButton draws its text the same way: its
vtable's slot 13 (`0x655f30`) jumps to CIFStatic's `0x64d940`, its slot 42 is `0x64d9b0`, and the
builder sets every control's HAlign and VAlign (`0x8b5696..0x8b56b8`, no type test).
`UiBuilder.place_label` lays a CIFStatic's or CIFButton's text by that rule, in its ClientRect
(round 630 and its review); the draw truncates the screen coordinate, which for a window at whole
pixels is flooring the offset in it;
`TwoDtBuilder.set_text` already did the same for `.2dt` windows (round 598).

MEASURED (the render box, where Tahoma is not installed and the archive's Arial fallback draws):
the minimap's X text has its cap top 2 px below its rect's top, where the retail screenshot's is 3
(measured on the report's 2x crop, frame matched at scale 2.00). Arial's ascent at 12 px (about
10.9) is a pixel short of Tahoma's (about 12.0), which accounts for it; the user's machine has
Tahoma. INFERRED, not measured with Tahoma.
