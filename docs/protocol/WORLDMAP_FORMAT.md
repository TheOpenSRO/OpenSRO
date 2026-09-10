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
269 are referenced by nothing in the table. They are the ones whose A is odd mod 4, so they
belong to a grid this table does not describe.)

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

## What is left

- **The other 269 `map_world_*` tiles**, on the odd-mod-4 grid. Four functions reference the
  format string; two are the loader and destructor above, and the other two have not been read.
- **Three rows with no artwork**: `map_survival_colosseum`, `_desert` and `_palace` (ids 23–25).
  All three have **every region bound set to 0** — degenerate boxes, zero units per pixel — so
  they are unfinished placeholder rows rather than shipped content this archive is missing.
  Every other one of the 34 `WLocalmap` rows resolves.
- **Three rows are type 0**, not one: the main world plus `map_jupiter_a` and `map_jupiter1_1`,
  which are worlds of their own you switch to. Type alone does not identify the world map; the
  main one is the only type-0 row drawn from a grid.
- **The window itself.** `GDR_WORLDMAP` is a `CIFWorldMap` at `100,100,652,424` on
  `mframe_wnd_`, and `ifworldmap.txt` carries only three buttons, so the map is the control's own
  drawing. Everything it needs to draw is now readable.
