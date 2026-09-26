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
| 0 | Map ID | int | `+0x04`, the key |
| 1, 2 | Name, layer | string | discarded |
| 3, 4 | layers, total layers | byte | `+0x40`, `+0x41` |
| 5 | code | int | `+0x44` — a `TextZoneName.txt` zone code; dungeons have the high bit set (`32769` = `0x8001`) |
| 6, 7 | texture num x/y | int | `+0x48`, `+0x4c` |
| 8, 9 | draw x/y | int | `+0x50`, `+0x54` |
| 10–13 | start region left(X), top(Y), right(X), bottom(Y) | int | `+0x58` … `+0x64` |
| 14 | 척도(비율) — "1.0 = 256" | **float** | `+0x68` |
| 15 | map path | string | `+0x6c` |
| 16 | 리전아이디 | int | `+0x88` |
| 17–22 | 층수 스트링, 전체맵버튼타입, Left, Top, Right, Bottom | — | **the parser stops before these** |

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
- **The window is built** — `client/scripts/ui/hud/hud_worldmap.gd`, the client's
  `CNIFWorldMap` from `res_ui\worldmapguide.2dt` since round 599 (`docs/RE_COMPLETION.md`).
  The caption's name comes from the client's map record, +0x94 (`0x612fd0`); which column fills
  it was not traced. What is left on the window is in `docs/UI_TODO.md`.
