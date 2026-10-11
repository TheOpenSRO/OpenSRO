# The world map

How the client turns `interface\worldmap\`'s images into a map, which regions each one covers,
and where a world position lands on it. Recovered 2026-09-10; the reader is
`client/scripts/worldmap/worldmap_info_reader.gd` and the check against a real archive is
`client/tools/check_worldmap_tiles.gd`.

No game data is committed here — only the structure.

## The table

`Media.pk2\server_dep\silkroad\textdata\worldmap_mapinfo.txt`, UTF-16LE, tab separated, 23
columns, with `#section` lines dividing it into **`WLocalmap`** and **`Dungeonmap`**. The two
sections do **not** share a column layout.

Every column index below is the order the client's own row parser consumes the line, not a count
off the header row. There is one parser per section — the RTTI names them `CWorldMap_MapInfo` and
`CWorldMap_DungeonMapInfo` — and each is a straight run of "read next token as int / as float /
as string" calls into fixed member offsets, so the mapping is exact. Where a parser stops before
the end of the row, that is recorded too.

### Section `WLocalmap` — the world map, cities, fortresses, instances

| # | Header | Read as | Member |
|---|---|---|---|
| 0 | Map ID | int | `+0x04`, and returned as the map's key |
| 1 | Type 0:Wmap, 1:Local | byte | `+0x08` |
| 2 | //Name(Skip) | string | discarded — the header's own "Skip" |
| 3 | Addr | string | `+0x28` |
| 4, 5 | Texture Size_x/_y | int | `+0x44`, `+0x48` |
| 6, 7 | Pic Area_x/_y | int | `+0x4c`, `+0x50` |
| 8, 9 | Draw x/y | int | `+0x54`, `+0x58` |
| 10–13 | 리젼 left, top, right, bottom | int | `+0x5c` … `+0x68` |
| 14–17 | 좌표 LT_x, LT_y, RB_x, RB_y | int | `+0x6c` … `+0x78` |
| 18 | 요새월드ID | string | discarded |
| 19 | 로컬 이름 스트링 코드 | string | discarded |
| 20 | 전체맵버튼타입 | — | **the parser stops before this** |
| 21 | 한 리젼 크기 | — | **not read** |

Two things fall out of that last pair. Column 19 is the `UIIT_`/`SN_` key for the map's name and
the client reads it only to throw it away, so the window's title comes from somewhere else.
And column 21, "one region size", reads `4x4` for the world map — but **the client never looks at
it**: both the loader and the destructor step by a literal `4`. Our reader uses the column
because it is authored data and it agrees; the test asserts the grid it produces is the size the
draw size implies, which is what would catch it drifting.

### Section `Dungeonmap` — one row per dungeon floor

| # | Header | Read as | Member |
|---|---|---|---|
| 0 | Map ID | int | `+0x04`, the key (2001 up) |
| 1 | Name | wide string | `+0x08` (0x62c1eb) -- the dungeon's name, the same on all its floors |
| 2 | layer | wide string | `+0x24` (0x62c20b) -- `F` (1F, 2F ...) or `B` (B1, B2 ...) |
| 3, 4 | layers, total layers | byte | `+0x40` (this floor, 1-based), `+0x41` |
| 5 | code | int | `+0x44` — a `TextZoneName.txt` zone code; dungeons have the high bit set (`32769` = `0x8001`) |
| 6, 7 | texture num x/y | int | `+0x48`, `+0x4c` |
| 8, 9 | draw x/y | int | `+0x50`, `+0x54` |
| 10–13 | start region left(X), top(Y), right(X), bottom(Y) | int | `+0x58` … `+0x64` |
| 14 | 척도(비율) — "1.0 = 256" | **float** | `+0x68` |
| 15 | map path | string | `+0x6c` |
| 16 | 리전아이디 | int | `+0x88` |
| 17–22 | 층수 스트링, 전체맵버튼타입, Left, Top, Right, Bottom | — | **the parser stops before these** |

Columns 1 and 2 were recorded as discarded until round 775: the two string reads go through
`0x46ed50` into the record's wide strings at `+0x08` and `+0x24` (READ, asm 0x62c1db..0x62c20b),
and the world map's dungeon branch uses both (below).

The path is column **15**, not 3, and the grid comes from the *texture counts* (columns 6 and 7)
rather than from the region bounds. Reading these rows with the `WLocalmap` columns produced maps
whose artwork was the string `"1"` and whose tiles were 1 × 32,797 pixels, which is how the
difference was first noticed; the reader tracks the section, and counts rather than reads
anything in a section it does not know.

Column 14 is the only float in either section, and the header states its unit outright:
**a scale of 1.0 draws a region 256 pixels wide**. Every dungeon row in the archive checks out
against that — floor 1 of 돈황석굴 is 3 × 3 tiles at scale 1.0 drawn 768 × 768, i.e. 256 a tile.

## Tile names

Both sections name tiles `<prefix><A>x<B>.ddj`, with **A ascending from `left`** and
**B descending from `top`** — the world map in steps of 4, a dungeon floor in steps of 1.

The world map's own row reads:

```
id 0, type 0, interface\worldmap\map\map_world_
texture 128x128,  pic area 128x128,  draw 4224x1408
region left 46, top 113, right 177, bottom 70
LT (0, 192)   RB (192, 0)
```

So A runs 46, 50 … 174 (33 values) and B runs 113, 109 … 73 (11 values). **33 × 11 = 363 tiles**,
and 33 × 128 by 11 × 128 is **4224 × 1408** — the declared draw size, to the pixel.

That loop is in the client twice, once acquiring the textures and once releasing them, and both
write it out longhand with the same four constants:

```
A = 46;  do { B = 113;  do { load(A, B);  B -= 4; } while (B > 69);  A += 4; } while (A < 178);
```

**All 363 are present in a real Media.pk2**, as are all 25 dungeon floors' tiles — several
thousand files, no misses. (The `map\` directory holds 632 `map_world_*` tiles in all; the other
269 are on three further lattices that nothing asks for — see the last section.)

## Where a position lands on the map

`NIFWorldMap.cpp` turns the region bounds into a world-space box and divides by the draw size:

```
minX = (left   - 135) * 192 + LT_x        maxX = (right  - 135) * 192 + RB_x
maxY = (top    -  92) * 192 + LT_y        minY = (bottom -  92) * 192 + RB_y

units per pixel = |maxX - minX| / draw_x  ,  |maxY - minY| / draw_y
```

`135`, `92` and `192` are **the same three constants as this project's position readout** —
`X = (region_y - 135) * 192 + local_x / 10`, `Y = (region_x - 92) * 192 + local_z / 10` —
established independently and long before. It multiplies `left`/`right` by the *y* constant and
`top`/`bottom` by the *x* one, and that is what fixes which authored bound is which axis:
**`left`/`right` are region y, `top`/`bottom` are region x.**

Three separate things then agree, which is why this is a finding and not a reading:

- The world map's box is −17088…8256 by −4224…4224, which over 4224 × 1408 pixels is
  **exactly 6.0 world units per pixel on both axes** — and 6.0 is 192 ÷ 32, i.e. 32 pixels a
  region, i.e. 128 pixels per 4-region tile. The tile grid and the scale are the same statement.
- Jangan's own local map row gives region left 166, top 99, right 170, bottom 96. Jangan is
  region **x = 97, y = 168**: y falls inside 166…170 and x inside 96…99. The data alone puts the
  axes the same way round as the binary does.
- Jangan's box is 6048…6816 by 864…1440 over 1024 × 768 pixels — **0.75 on both axes**. The town
  square, region 97/168 local (1002, 917) → world (6436.2, 1051.7), lands at pixel
  (517.6, 517.7): inside its own map, near the middle.

Swapping the axes makes none of those come out.

The **vertical flip** — image y growing as world Y shrinks — is *not* read from the client, which
takes an absolute value and so says nothing either way. It follows from the table's own naming:
`좌표 LT_y` is the offset paired with `top`, and `top` is the larger region x and so the larger
world Y, which puts the image's top edge at the high end of Y.

## Worked example

Jangan, region x = 97, y = 168. `left` 46 step 4 → the tile beginning at y = 166; `top` 113 step 4
→ x = 97 exactly. So Jangan is in

```
interface\worldmap\map\map_world_166x97.ddj
```

which exists.

## A second table says the same things: `worldmapguidedata.txt`

`server_dep\silkroad\textdata\worldmapguidedata.txt` is the world map guide's own data, and it
was authored separately. Four `#section`s, each with its own columns and its own header row:

| Section | Rows | What |
|---|---|---|
| `MAP_MANAGER` | 18 | 항목 (name) \| 시작 리전 \| 끝 리전 \| 그림 한장의 사이즈 \| 한 리전크기 \| 맵ID |
| `AREA` | 39 | town and area names, their `SN_ZONE_*`/`UIIT_` string keys, and a link id |
| `MONSTER` | 339 | 코드네임 \| 지역 \| … \| x \| y \| 리전x \| 리전y \| pos_x \| pos_y \| 색상값 |
| `QUEST` | 492 | quest code \| 지역 \| x \| y \| 리전x \| 리전y \| pos_x \| pos_y \| 몬스터 코드네임 |

MONSTER and QUEST carry the **same six geometry columns at different indices** — MONSTER's `x` is
column 8 and QUEST's is column 5 — so a reader has to track the section here too.

`MAP_MANAGER` joins to `worldmap_mapinfo.txt` by 맵ID, and `client/tools/check_worldmap_guide.gd`
runs the join. Against a real archive **nothing disagrees**. The world map's row reads start
region `46x113`, one picture `128x128`, one region size `4x4`, map id `0` — the same grid the
other table gives, from a table with no code path in common.

It also names two maps `worldmap_mapinfo.txt` has as single images:

- **`jupiter_field`, map id 17, start `199x103`, 128 × 128, four regions a tile.** That is exactly
  the archive's spare 5 × 5 lattice (A 199…215, B 87…103) — so the tiles nothing asks for are the
  tiled form of the Jupiter field, and this table is what names them.
- **`jupiter1_1`, map id 16, start `235x126`, 256 × 256, one region a tile**, which is the
  `map_jupiter_a_<A>x<B>.ddj` set (`map_jupiter_a_237x126.ddj` is 32,916 bytes = 256 × 256 DXT1).

### Do not read its `x`/`y` columns

They are world-map pixels, and they are **stale**. Measured over every MONSTER and QUEST row on
the world map's own grid:

| | rows | stated − derived |
|---|---|---|
| MONSTER | 142 | **5 tiles out horizontally**, 0 vertically — every one a `MOB_CH_*` |
| MONSTER | 31 | exact — the newer `MOB_TK_*` / `MOB_SD_*` western rows |
| QUEST | 89 | exact |

The pitch is a whole 128 on both axes for **all 262**, and the **row** index is exact for all 262
— which is a third independent confirmation that `top` is 113, the step is 4, and B descends. The
column index is the only thing out, by exactly five tiles (twenty regions), and only on the older
Chinese monsters: the map was re-cut westward at some point and those rows were never re-based.

So the region and `pos_` columns are the ones to use. `WorldmapGuideReader` keeps `x`/`y` as
`stated_pixel` and derives the real position with `pixel_in()`.

## Loose ends, and one that is closed

- **The other 269 `map_world_*` tiles** are asked for by **nothing**. All four functions that
  reference the format string — two loaders and two destructors, belonging to two classes — write
  out the identical bounds, 46 to 177 and 113 down to 69 by 4. So there is no second loop and no
  second zoom level; the archive simply carries tiles this build never requests.

  They are not junk, though. Every one is 8,340 bytes (128 × 128 DXT1, the same as the tiles in
  use) and they fall into exactly **three more step-4 lattices**, each at its own origin:

  | Lattice | Tiles | Covers |
  |---|---|---|
  | A 65…177, B 85…113 | 224 of 232 — the bottom row from A 149 is absent | a sub-box of the main map, on a lattice offset three regions from it |
  | A 199…215, B 87…103 | 25, a full 5 × 5 | 640 × 640 pixels |
  | A 200…216, B 72…84 | 20, a full 5 × 4 | 640 × 512 pixels |

  The middle one is **the Jupiter field, tiled**, and two separate things say so.
  `worldmapguidedata.txt` names a map `jupiter_field` at start region **`199x103`**, 128 × 128,
  four regions a tile — the lattice exactly. And the geometry agrees: `map_jupiter1_1`'s row
  covers world X 12288…16128 by Y −1728…2112 drawn at 640 × 640, which is 6.0 units a pixel — the
  world map's own scale — and 5 × 5 tiles of 128 is exactly 640 × 640 over the same box.
  `worldmap_mapinfo.txt` gives that map as a single image instead, which is why its loader never
  asks for the tiles. **The 5 × 4 lattice at A 200…216, B 72…84 still matches nothing** in either
  table.
- **Three rows with no artwork**: `map_survival_colosseum`, `_desert` and `_palace` (ids 23–25).
  All three have **every region bound set to 0** — degenerate boxes, zero units per pixel — so
  they are unfinished placeholder rows rather than shipped content this archive is missing.
  Every other one of the 34 `WLocalmap` rows resolves.
- **Three rows are type 0**, not one: the main world plus `map_jupiter_a` and `map_jupiter1_1`,
  which are worlds of their own you switch to. Type alone does not identify the world map; the
  main one is the only type-0 row drawn from a grid.
- **The dungeon branches are built** (round 775) -- the section above.
- **The window is built** — `client/scripts/ui/hud/hud_worldmap.gd`, the client's
  `CNIFWorldMap` from `res_ui\worldmapguide.2dt` since round 599 (`docs/RE_COMPLETION.md`).
  The caption's name comes from the client's map record, +0x94 (`0x612fd0`); which column fills
  it was not traced. What is left on the window is in `docs/UI_TODO.md`.

## Dungeons on the world map (round 775)

Every fact READ from `sro_client.exe` unless marked; MEASURED facts are from the retail archive on
the render box (structure and counts only). The window's code is `HudWorldmap`
(`client/scripts/ui/hud/hud_worldmap.gd`), the readers `WorldmapInfoReader`,
`WorldmapLocalInfoReader` and `WorldmapInstanceInfoReader`. CNIFWorldMap reads a Dungeonmap record
through `0x62c030` (record + 4), a map record through `0x96f4e0` and a sign through `0x96f0b0`
(both + 4), so the window's offsets are the parsers' less 4; the offsets here are the parsers'.

### The modes

`+0x97d0` is 0 the world map, 1 a local map, 2 a dungeon floor; `+0x7ac` the map id; `+0x99a0` the
floor's record. `0x622b60(mode, id)` shows a world or local map (and hides the spinner at its end),
`0x6217e0(id)` a floor (mode 2; "Illigal Dungeon Map Index" asserted for an id with no row).
`0x623060` (ShowWindow and the render's auto-move step) and `0x616a20` (the caption refresh) pick
between them by id: 0 the world, 1..2000 a local map, above 2000 a floor.

### How a dungeon appears on the field map: `worldmap_localinfo.txt`

`server_dep\silkroad\textdata\worldmap_localinfo.txt`, UTF-16LE, tab separated, no sections. The
loader (Client_LoadRefDataFile's type 4, 0x9534c4..0x9534e0) reads column 0 as a number and skips
the row when it is 0 -- the `service` column, which also skips `//` rows. RefParse_worldmap_localinfo
(0x96f280) then reads, in order:

| # | Read as | Member | Use |
|---|---|---|---|
| 1 | int | `+0x04` | id |
| 2 | byte | `+0x08` | type: 1 text, 2 picture |
| 3 | wide string | `+0x0c` | a text key (type 1) or a `.ddj` path (type 2) |
| 4, 5, 6 | wide string | `+0x28`, `+0x44`, `+0x60` | glosses; the window does not read them |
| 7 | int | `+0x7c` | link: the map a picture opens; on a text, 1 puts `<-` before it, 2 `->` after |
| 8 | int | `+0x80` | parent: the map the sign is drawn on (0 the world map) |
| 9, 10 | int | `+0x84`, `+0x88` | regions (paired with the world map's `left` and `top`) |
| 11, 12 | int | `+0x8c`, `+0x90` | x, y |
| 13, 14 | int | `+0x94`, `+0x98` | w, h (a text's font index is 14) |
| 15..17 | int x3 | `+0x9c` | colour `0xff000000 \| r << 16 \| g << 8 \| b` |
| 18..20 | byte x3 | `+0xa0..+0xa2` | text style bytes (Shadow, Bold, Blur by the header): Bold is text flag 2, Blur flag 1 (the shadow), Shadow nothing -- see "The text signs" |
| 21 | wide string | `+0xc4` | a picture's hover key (`SN_NPC_*` or `xxx`) |

`+0xa4` is set to 1.0 (the quads' UV extent). `0x6210b0(id)` (called by both `0x622b60` and
`0x6217e0`) lists every sign whose parent is the map shown and places it: parent 0 at
`x + (region9 - world.left) * 32`, `y + (world.top - region10) * 32` (32 pixels a region, the
world map's own scale), any other parent at `x, y` on that map's image. A picture is its texture on
a `w` x `h` quad with that top-left (0x6196d0 / 0x61b510 re-lay it as the map scrolls); a text is
centred on `x` (`x - width / 2`) with its top at `y`, in the font of index column 14 and the
colour, and drawn over every picture (below). Which side `<-` and `->` go is INFERRED from the two
concatenations' argument order.

**The click (vslot_017 0x623220).** On the world map (mode 0) only:
- WM_LBUTTONDOWN (0x6232e4): `+0x9800 = 0`, then the first type-2 sign whose quad strictly holds
  the mouse gives its link to `+0x9800` (when nonzero). The press also starts the map drag and
  turns auto-move off with the stale flag, as any press on the map.
- WM_LBUTTONUP (0x623819..0x62393b): the first type-2 sign under the mouse decides -- no link, or a
  link other than `+0x9800`, and nothing opens; a pressed fortress (1001..1999, 0x6238e2) passes
  on to the next sign under the mouse; otherwise a link up to 2000 opens `0x622b60(1, link)`, above
  2000 `0x6217e0(link)`, and both centre (0x61cc30).
- WM_MOUSEMOVE (0x623220's 0x200 case): on the world map a fortress sign shows its tooltip
  (0x613260); on a local map or a floor a picture sign of that map shows its column-21 text
  (0x614950). OpenSRO draws neither (OPEN).

MEASURED: 863 type-2 rows; on the world map (parent 0) the city icons (`city_*.ddj`, links 1..5,
12, 18), the fortress icons (links 1001..1003; 1004's rows have service 0), the ferries, the shaman's house, and the two
dungeon icons `interface\worldmap\map\xy_dungeon.ddj`: link **2001** (the Donwhang cave's 1F) at
region (147, 106) + (20, 19), and link **2005** (the Qin-Shi tomb's B1) at (172, 102) + (7, 0),
both 32 x 32; two more world-map signs (36 x 36, in the far west) link 2017, the Egyptian
temple's floor. Each dungeon's `worldmap_instanceinfo.txt` field point lands inside its icon
(the cave's at pixel (3259, 255) in the icon at (3252, 243); the tomb's at (4048, 359) in
(4039, 352)). MEASURED on the archive, all 25 rows: the walk from 2001 has no gap, every row's
floor label is the textzonename text of its `.dof` floor key (`DH_A01_FLOOR01` "1F" ...
`QT_A01_FLOOR06` "B6"), and the cave's 2001..2004 share one Name, the tomb's 2005..2010 another.
The cave's floor 2001 carries a text sign `STORE_DH_GATE_OUT` (the way out), the
tomb's 2006 and 2009 room names; their texts are in `textdata_object.txt`.

OpenSRO draws the signs of every map shown and, with the table present, no longer draws the
round-599 name plates on the world map (they were OURS, standing in for these icons); an archive
without the table keeps the plates. The text signs are drawn as the next section says (round 776).

### The text signs (round 776)

READ unless marked; the code is `HudWorldmap._sign_label` and its `SignText`.

- **Set-up (0x6210b0, asm 0x6211d4..0x621444).** The sign object (0x160 bytes, 0x6125e0) holds a
  text object at +0x34. In order: the font `0xba5460(+0x94)` -- column 14, the same index table as a
  `.2dt` record's FontIndex (INFERRED from the shared getter; MEASURED every world-map text row has
  0, the 12 px face) -- through 0x8b2b50; the colour (columns 15..17) through 0x8b2b70; then the text
  flags: `+0xa0 ? 0x8b44b0(5, 1) : 0x8b4560(5, 1)`, `+0xa1 ? ...(5, 2)`, `+0xa2 ? ...(5, 1)` --
  0x8b44b0 ORs the bits into every state, 0x8b4560 clears them. **Column 20 (Blur) sets or clears
  flag 1 after column 18 (Shadow) did, so Blur decides the shadow and Shadow has no effect;**
  column 19 (Bold) is flag 2. Flag 2 picks the face's weight-600 variant (0x8b39e0 -> glyph mode
  2, made in 0xbaa110), flag 1 is the drop shadow (0x8b48b0 passes `flags & 1` to 0x8b2290, which
  draws the glyph at `x + 1, y + 1` in black at the text's alpha, then at `x, y` in its colour --
  glyph by glyph). Then the text (the key through 0x8c9bb0, with the link's `<-` / `->`) is set
  (0x8b3b60 -> 0x8b39e0), which lays the glyphs out in the flags' face and measures it (0x8b3910:
  width = the sum of the glyphs' advances, height = line spacing + the font's height).
- **Place.** `+0xac = origin.x - width / 2 + anchor.x` (an int division: `cdq; sub; sar 1`),
  `+0xb0 = origin.y + anchor.y`; 0x6196d0 and 0x61c5a0 keep it as the map moves. 0x8b48b0 draws the
  glyph cells from that point, the cell's top at `y`.
- **Draw order (vslot_013 0x624380 -> 0x61c360).** One walk of the sign list draws every picture
  sign with a texture (`*sign == 2 && +0x9c != 0`, a DrawPrimitiveUP of its quad), a second walk
  every text sign with text (`*sign == 1 && +0x7c != 0`, `0x8b48b0(+0xac, +0xb0, 0xff)`). **Every
  text is over every picture**, whatever the file order. A town's name is a text row of its own
  that falls on the plate painted into its icon: Jangan's is `SN_ZONE_22001` ("Jangan", region
  (168, 97) + (15, 10), bold, (255, 247, 182)), listed before `city_jangan.ddj` (region (167, 98)
  + (16, 2), 64 x 64) -- drawn in file order, the icon covers it. Signs are not clipped by
  themselves; the map area's viewport (0x46d920 with +0x97d8) clips them with the map.
- **MEASURED (the archive):** the world map has 136 text rows (service != 0, parent 0). Shadow /
  Bold / Blur: 98 are 0/0/1 (the white 21xxx and 25xxx places: plain, shadowed), 34 are 0/1/1 (the
  22xxx towns in (255, 247, 182), 23xxx tombs in (196, 231, 255), 24xxx mountains and rivers in
  (217, 240, 152): bold, shadowed), 2 are 1/0/1 (the far-west 27000 names: shadowed -- by Blur), and
  2 are 0/1/0 (22004 and 22005: bold, and by the rule above **without** a shadow). All 136 have font
  index 0.
- **MEASURED (the user's picture of the original at Jangan, 2x, fitted to the map's own tiles to
  the pixel):** the ink of Water Ghost Marshland, Exorcist's Home, China East Ferry, Huang He and
  Jangan is centred on its anchor's x to half a pixel, its capitals start 3 px below the anchor's
  y, every one has a one-pixel black shadow right and down, and the five coloured ones are bold.
- OURS: without a weight-600 file of the face on the system the bold is GDI's simulation (each
  glyph at x and x + 1, its advance one wider; HudNotice.draw_bold, round 703). Without an archive
  face (tests) the text is Godot's fallback font.

### A floor: `0x6217e0`

- **Tiles**: column `a` of `count_x`, row `b` of `count_y`, file `"%s%dx%d.ddj"` of the path,
  `left + a`, `top - b`; quads `scale * 256.0` a side (0x6196d0, the double at 0xd99a58) at
  `(a, b) * side`, UVs 0..1. MEASURED: count x side is the draw size on all 25 rows.
- **Box and scale**: min X `(left - 135) * 192`, max X `((right - 135) * 3 + 3) * 64`, min Y
  `(bottom - 92) * 192`, max Y `((top - 92) * 3 + 3) * 64` -- the field's transform, the far
  bounds one region further so the box holds the last tile; units a pixel `|max - min| / draw`.
- **The floor spinner** (record 4, `+0x999c`): top `+0x354 = total - 1`, value `+0x35c = 0`, letter
  `+0x360` = the layer column's first character, spelling `+0x364` = 2 for `F`, else 1; then one
  step up (0x60f080), one down (0x60efc0) and up until the value is `layers - 1`. Shown when
  `total > 1`.
- `0x6196d0`, `0x6210b0(id)` (the floor's signs), the caption `0x6145e0`.

**The spinner's steps** (0x60f210 sets it up: label `0x1b` = 27, buttons `0x18` = 24 and
`0x16` = 22; its picture `interface\store\str_slot_02.ddj`; the message map at 0xeb5468 sends 24
to 0x60efc0 and 22 to 0x60f080). A step first turns the world map's auto-move off with the stale
flag when it is on (`+0x229ac = 1`, `+0x7b1 = 0`, through window 28), then -- within 0..top -- moves
the value, redraws the label (0x60edd0: `"%c%d"` for spelling 1, `"%d%c"` for 2) and enables each
button by whether it can step again (0x471dc0). Because `0x6217e0` steps the spinner itself,
**showing any floor turns auto-move off**: the map then stays on that floor until button 20 is
pressed twice (the stale flag takes the first press back, 0x616870).

**The floor change** (0x621ca0, the render's tail at 0x624543): on a floor with auto-move on the
spinner is stepped to the floor shown; with it off, a value other than the floor's shows
`0x621c60` -> `0x6143b0(id, value + 1)`: the walk 2001, 2002, ... (to the first missing id) for
the row with the shown row's Name and that floor number, then `0x6217e0` and the arrow
(`0x610980`). OpenSRO runs this right after the press (OURS: the client's next frame).

**The caption** (0x6145e0): the zone code as `"%d"` looked up in the text tables (0x8c9c30), that
text as `"%s"` looked up again, and the caption is the second lookup followed by the first (a
miss gives "", 0x8c9b20 -> 0xec3b70); then, with the player in a dungeon (bit 15) and auto-move
on or this floor the player's, `" - "` and the text of the player's room name (0x9d7830). The world
button is shown. In the small size the caption is refreshed only for a floor (0x616a20).
MEASURED: textzonename names zone 32769 -- the cave's four floors -- "Job Temple", and 32770..32775
"Underground Level 6..1 of Tomb of Qin-Shi"; the caption shows what the table says.

**The buttons on a floor** (0x616870): auto-move on, the spinner is shown when `total > 1`; manual
in the big size, the world button and (total > 1) the spinner are shown; manual in the small size,
both are hidden. The world button (0x6231e0) goes back to the world map and hides the spinner.

### The player in a dungeon

- **Which floor** (0x623060 -> 0x614280): the walk from 2001 for the row whose zone code equals
  the player's region id and whose floor label (`"%d%c"` / `"%c%d"` of its layers and layer
  letter) is the text of the player's current floor name (0x612920: `lstrcmpW` against the text of
  `0x9d7880`, the region's current floor name; no floor name, no match). None: the world map.
  INFERRED: 0x9d7880 / 0x9d7830 are the `.dof` block's floor and room names (P4's two lists,
  `docs/protocol/dungeon.md`); MEASURED: textzonename gives `DH_A01_FLOOR01` "1F" and
  `QT_A01_FLOOR01` "B1", which are exactly the rows' labels.
- **The arrow on a floor** (0x60f660; x, y, z the player's +0x80 / +0x84 / +0x88, the `.dof`'s
  space; `high` the region id's high byte, 0x80):

  ```
  px = (x / 10 + (count_x / 2) * 192 - (maxX - minX)) / upp_x + draw_x
  py = draw_y - ((high - 92) * 192 + z / 10 - minY) / upp_y
  ```

  `count_x / 2` is an integer halving; MEASURED, on every row it equals `128 - left`, so a dungeon
  x of 0 is the left edge of the column named 128 -- the minimap's own `floor(x / 1920) + 0x80`.
  The facing is the field's (+0x97c8). The arrow is drawn on a floor only when the floor is the
  player's (0x614890(0) -> 0x612920); the view centres on the pixel either way (0x61cc30, mode 2).
- **The arrow on a field map**: with the player's region in `worldmap_instanceinfo.txt` and bit 15
  set, the render draws the arrow at that entry's field point instead (0x60fa90), and the view
  centres there (0x61cc30, `+0x97b4`).

### `worldmap_instanceinfo.txt`

`server_dep\silkroad\textdata\worldmap_instanceinfo.txt` (loaded by Client_LoadAllRefData 0x844cd0
only when vslot 0xb8 of `+0x4c4` returns 0, not traced). Header: `CodeName, Name(Skip),
RegionLeft, RegionTop, RegionRight, RegionBottom, MapRegionX, MapRegionZ, MapPosX, MapPosY,
MapPosZ`. The loader (0x9536a0..0x9537fe) expands each row's box into one entry a region -- z from
RegionTop up to RegionBottom, x from RegionLeft up to RegionRight, ascending (a start past its end
gives nothing), key `x | z << 8` -- holding the field region `(MapRegionZ << 8 | MapRegionX) &
0x7fff` and the position as floats. The point is `(low - 135) * 192 + MapPosX / 10`,
`(high - 92) * 192 + MapPosZ / 10` on the shown map's transform (0x60fa90). Which column feeds which
member is INFERRED from the header (the parser's token order past the box was not traced). Without
the table (`0xeedf08 + 0x1ec` zero) two constants stand in (0x610c5e..0x610cab): region 0x8001 at
(2465, 2693), 0x8002..0x8007 at (7200, 2102). MEASURED: `Worldmap_DONWHANG` (box 1..1 x 128) and
`Worldmap_JINSI` (2..7 x 128) give points within 0.3 of the first constant and 34 off the second.

### Open

- The party's marks on a floor: the render (0x61eec0) draws members with the floor's dungeon id
  (column 16) and, for dungeon 1 (the cave), only those whose height falls in the floor's band
  (0x610ed0: y < 70, 70..210, 210..350, 350 up -- floats at 0xd990a8 / 0xd990a0 / 0xd9909c). OpenSRO
  shows no party marks in a dungeon (World3D sends no dungeon party positions).
- The tooltips of 0x614950 / 0x613260, the spinner label's style (0x4774f0(5, 2) on its text).
  (The text signs' style bytes are read: round 776, above.)

## The player's marker turns (round 630)

READ: the marker is `interface\minimap\mm_sign_character.ddj` (art pointing right, MEASURED), a
16x16 quad (+-8) turned by `-(+0x97c8)` through `0x8b5c50` (`0x6200de..0x620236`), with `+0x97c8 =
player+0x8c - pi / 2` (`0x60f6a5`, `0x610a05`) -- the minimap arrow's rule
([minimap.md](minimap.md)). `HudWorldmap.update_player` takes the facing and turns it; it was drawn
unturned before.
