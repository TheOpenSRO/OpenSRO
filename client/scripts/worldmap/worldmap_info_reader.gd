extends RefCounted
class_name WorldmapInfoReader

## Reads `server_dep\silkroad\textdata\worldmap_mapinfo.txt` -- the table
## that says where every world-map, local-map and dungeon-map image goes,
## which regions it covers, and what world-space box it draws.
##
## The file has two `#section`s and they do **not** share a column layout.
## Both are decoded, and the column indices below are not read off the
## header row: they are the order the client's own two row parsers consume
## the line, `CWorldMap_MapInfo` and `CWorldMap_DungeonMapInfo`. Where the
## client stops reading, this reader records that it stops.
##
## See docs/protocol/WORLDMAP_FORMAT.md for the recovery.

const TABLE_PATH := "server_dep\\silkroad\\textdata\\worldmap_mapinfo.txt"

const TYPE_WORLD := 0
const TYPE_LOCAL := 1

## The client's own region-to-world transform, from `NIFWorldMap.cpp`:
## `(region_y - 135) * 192` horizontally and `(region_x - 92) * 192`
## vertically. The same three constants as the project's position readout,
## established independently and long before.
const REGION_Y_ORIGIN := 135
const REGION_X_ORIGIN := 92
const REGION_SPAN := 192

## Section `WLocalmap`. Column indices are the order `CWorldMap_MapInfo`
## reads the row.
const COL_ID := 0
const COL_TYPE := 1
# 2 is `//Name(Skip)` -- the client reads it and throws it away, as the
# header's own "Skip" says to.
const COL_ADDR := 3
const COL_TEXTURE_W := 4
const COL_TEXTURE_H := 5
const COL_PIC_AREA_W := 6
const COL_PIC_AREA_H := 7
const COL_DRAW_W := 8
const COL_DRAW_H := 9
const COL_REGION_LEFT := 10
const COL_REGION_TOP := 11
const COL_REGION_RIGHT := 12
const COL_REGION_BOTTOM := 13
const COL_LT_X := 14
const COL_LT_Y := 15
const COL_RB_X := 16
const COL_RB_Y := 17
const COL_FORTRESS_WORLD_ID := 18
const COL_NAME_KEY := 19
## Columns 20 (`전체맵버튼타입`) and 21 (`한 리젼 크기`) are authored but the
## client's row parser never reads them -- it stops after column 19. The
## tile step it uses is a literal 4 in both the loader and the destructor.
const COL_WHOLE_MAP_BUTTON := 20
const COL_ONE_REGION := 21

## Section `Dungeonmap`. Column indices are the order
## `CWorldMap_DungeonMapInfo` reads the row.
const DCOL_ID := 0
# 1 is `Name` and 2 is `layer`; both are read and thrown away.
const DCOL_LAYERS := 3
const DCOL_TOTAL_LAYERS := 4
const DCOL_ZONE_CODE := 5
const DCOL_TEXTURE_COUNT_X := 6
const DCOL_TEXTURE_COUNT_Y := 7
const DCOL_DRAW_W := 8
const DCOL_DRAW_H := 9
const DCOL_REGION_LEFT := 10
const DCOL_REGION_TOP := 11
const DCOL_REGION_RIGHT := 12
const DCOL_REGION_BOTTOM := 13
const DCOL_SCALE := 14
const DCOL_ADDR := 15
const DCOL_REGION_ID := 16
## Columns 17 (`층수 스트링`), 18 (`전체맵버튼타입`) and 19-22
## (`Left/Top/Right/Bottom`) are authored and the row parser stops before
## them.

## One row of `WLocalmap`: the whole world map, or one city's own map.
class MapInfo:
	var id: int
	var type: int
	## Either a whole `.ddj` path (one image) or a tile-name prefix ending
	## in an underscore (the world map, a grid).
	var addr: String
	## The size of one tile, or of the single image.
	var texture_size: Vector2i
	## How much of that image is the map. Equal to `texture_size` for the
	## world map's tiles; smaller for the single images, which are stored
	## square and drawn as a rectangle.
	var pic_area: Vector2i
	## The size the whole map draws at.
	var draw_size: Vector2i
	## Region bounds. `left`/`right` are region **y** and `top`/`bottom`
	## are region **x** -- see `world_min()`.
	var region_left: int
	var region_top: int
	var region_right: int
	var region_bottom: int
	## Region-local offsets, in world units, of the covered box: `lt` goes
	## with `left`/`top` and `rb` with `right`/`bottom`.
	var coord_lt: Vector2i
	var coord_rb: Vector2i
	## Columns the client reads and discards, kept because they are useful:
	## the fortress world id and the `UIIT_` key for the map's name.
	var fortress_world_id: String
	var name_key: String
	## Column 21, "한 리젼 크기" -- how many regions one tile covers. **The
	## client does not read this column**; its loader steps by a literal 4.
	## Kept because it is authored data and it agrees; `tiles_across()`
	## derives the count from the draw size instead, and the reader's test
	## asserts the two produce the same grid.
	var regions_per_tile: Vector2i = Vector2i.ONE

	## Whether this row describes a grid of tiles rather than one image.
	func is_tiled() -> bool:
		return addr.ends_with("_")

	func tiles_across() -> int:
		return draw_size.x / texture_size.x if texture_size.x > 0 else 0

	func tiles_down() -> int:
		return draw_size.y / texture_size.y if texture_size.y > 0 else 0

	func covers_region(region_x: int, region_y: int) -> bool:
		return region_y >= region_left and region_y <= region_right \
			and region_x <= region_top and region_x >= region_bottom

	## The archive path of the tile covering a region, or "" when the
	## region is outside this map or the map is a single image.
	func tile_for_region(region_x: int, region_y: int) -> String:
		if not is_tiled() or not covers_region(region_x, region_y):
			return ""
		var step_y: int = maxi(1, regions_per_tile.x)
		var step_x: int = maxi(1, regions_per_tile.y)
		# Tiles are named by their own first region, so a region resolves
		# to the tile it falls inside rather than to the nearest name.
		var a := region_left + ((region_y - region_left) / step_y) * step_y
		var b := region_top - ((region_top - region_x) / step_x) * step_x
		return "%s%dx%d.ddj" % [addr, a, b]

	## Every tile name this map is made of, in the order the client loads
	## them: the first component ascending from `left`, the second
	## descending from `top`.
	func tiles() -> PackedStringArray:
		var out := PackedStringArray()
		if not is_tiled():
			return out
		var step_y: int = maxi(1, regions_per_tile.x)
		var step_x: int = maxi(1, regions_per_tile.y)
		var a := region_left
		while a <= region_right:
			var b := region_top
			while b >= region_bottom:
				out.append("%s%dx%d.ddj" % [addr, a, b])
				b -= step_x
			a += step_y
		return out

	## The corner of the covered box at the smallest world coordinates, in
	## the same units as the project's position readout. Read from
	## `NIFWorldMap.cpp`, which pairs `left`/`right` with the region-**y**
	## constant and `top`/`bottom` with the region-**x** one -- which is
	## what settles which authored bound is which axis.
	func world_min() -> Vector2i:
		return Vector2i(
			(region_left - REGION_Y_ORIGIN) * REGION_SPAN + coord_lt.x,
			(region_bottom - REGION_X_ORIGIN) * REGION_SPAN + coord_rb.y)

	## The opposite corner: `right` horizontally, `top` vertically.
	func world_max() -> Vector2i:
		return Vector2i(
			(region_right - REGION_Y_ORIGIN) * REGION_SPAN + coord_rb.x,
			(region_top - REGION_X_ORIGIN) * REGION_SPAN + coord_lt.y)

	## World units per drawn pixel, each axis. The client takes the
	## absolute span over the draw size, exactly this.
	func units_per_pixel() -> Vector2:
		var span := world_max() - world_min()
		if draw_size.x <= 0 or draw_size.y <= 0:
			return Vector2.ZERO
		return Vector2(absf(span.x) / draw_size.x, absf(span.y) / draw_size.y)

	## Where a world position falls on the drawn map, in pixels from its
	## top-left. The horizontal half is the client's own scale; the
	## vertical **flip** is not read from the client -- it follows from the
	## table's own naming, `좌표 LT_y` being the offset that goes with
	## `top`, the larger region x and so the larger world Y.
	func pixel_for_world(world: Vector2) -> Vector2:
		var upp := units_per_pixel()
		if upp.x <= 0.0 or upp.y <= 0.0:
			return Vector2.ZERO
		var lo := world_min()
		var hi := world_max()
		return Vector2((world.x - lo.x) / upp.x, (hi.y - world.y) / upp.y)


## One row of `Dungeonmap`: one floor of one dungeon.
class DungeonMapInfo:
	var id: int
	var layers: int
	var total_layers: int
	## The zone code this floor sits in; the header points at
	## `TextZoneName.txt` for the name. Dungeon zone codes have the high
	## bit set (`32769` = `0x8001`).
	var zone_code: int
	## How many tiles the floor is made of, each axis. The client loops on
	## these counts directly rather than on the region bounds.
	var texture_count: Vector2i
	var draw_size: Vector2i
	var region_left: int
	var region_top: int
	var region_right: int
	var region_bottom: int
	## The header spells out what this means: "1.0 = 256", so a scale of
	## 1.0 draws a region 256 pixels wide.
	var scale: float
	## A tile-name prefix; every dungeon row is a grid.
	var addr: String
	var region_id: int

	## Every tile name, in the client's own order: the first component
	## ascending from `left`, the second descending from `top`, one region
	## at a time, `texture_count.x` by `texture_count.y` of them.
	func tiles() -> PackedStringArray:
		var out := PackedStringArray()
		for a in texture_count.x:
			for b in texture_count.y:
				out.append("%s%dx%d.ddj" % [addr, region_left + a, region_top - b])
		return out

	## Pixels per region, from the scale column. The draw size divided by
	## the tile count should agree with it.
	func pixels_per_region() -> float:
		return scale * 256.0


class ParsedTable:
	var maps: Array[MapInfo] = []
	var dungeons: Array[DungeonMapInfo] = []
	## How many rows were passed over because they belong to a section
	## this reader does not know. Reported rather than dropped silently --
	## a new section appearing is a thing to hear about.
	var skipped_other_sections: int = 0

	func by_id(id: int) -> MapInfo:
		for m in maps:
			if m.id == id:
				return m
		return null

	## The whole-world map. **Not** simply the row whose type is
	## TYPE_WORLD: the table has three of those -- the main world and the
	## two Jupiter worlds, which are separate places you switch to rather
	## than overlays on the main map. The main one is the only one drawn
	## from a grid of tiles.
	func world() -> MapInfo:
		for m in maps:
			if m.type == TYPE_WORLD and m.is_tiled():
				return m
		return null

	## Every map that stands alone as a world of its own, main one first.
	func worlds() -> Array[MapInfo]:
		var out: Array[MapInfo] = []
		for m in maps:
			if m.type == TYPE_WORLD:
				out.append(m)
		return out

	## The local map covering a region, if the table has one. Several can
	## overlap -- Jangan's town map and its fortress map share regions --
	## so the first match wins, in file order.
	func local_for_region(region_x: int, region_y: int) -> MapInfo:
		for m in maps:
			if m.type == TYPE_LOCAL and m.covers_region(region_x, region_y):
				return m
		return null


const SECTION_WORLD_AND_LOCAL := "WLocalmap"
const SECTION_DUNGEON := "Dungeonmap"

## Parses the table. Rows whose id is not a number are skipped: the file
## carries comment rows (`//Map File Info`), the column-name header of each
## section, a Korean gloss row under it, and rows commented out by putting
## `//` in the id column -- the Loksan map is one, and it has no region
## bounds at all.
static func parse(data: PackedByteArray) -> ParsedTable:
	var table := ParsedTable.new()
	var section := SECTION_WORLD_AND_LOCAL
	for line in _lines(data):
		var cols := line.split("\t")
		if line.begins_with("#section"):
			section = cols[1].strip_edges() if cols.size() > 1 else ""
			continue
		var id_text := cols[COL_ID].strip_edges() if cols.size() > 0 else ""
		if not id_text.is_valid_int():
			continue
		match section:
			SECTION_WORLD_AND_LOCAL:
				if cols.size() > COL_NAME_KEY:
					table.maps.append(_parse_map(cols))
			SECTION_DUNGEON:
				if cols.size() > DCOL_REGION_ID:
					table.dungeons.append(_parse_dungeon(cols))
			_:
				table.skipped_other_sections += 1
	return table

static func _parse_map(cols: PackedStringArray) -> MapInfo:
	var info := MapInfo.new()
	info.id = _int_at(cols, COL_ID)
	info.type = _int_at(cols, COL_TYPE)
	info.addr = cols[COL_ADDR].strip_edges().replace("/", "\\")
	info.texture_size = Vector2i(_int_at(cols, COL_TEXTURE_W), _int_at(cols, COL_TEXTURE_H))
	info.pic_area = Vector2i(_int_at(cols, COL_PIC_AREA_W), _int_at(cols, COL_PIC_AREA_H))
	info.draw_size = Vector2i(_int_at(cols, COL_DRAW_W), _int_at(cols, COL_DRAW_H))
	info.region_left = _int_at(cols, COL_REGION_LEFT)
	info.region_top = _int_at(cols, COL_REGION_TOP)
	info.region_right = _int_at(cols, COL_REGION_RIGHT)
	info.region_bottom = _int_at(cols, COL_REGION_BOTTOM)
	info.coord_lt = Vector2i(_int_at(cols, COL_LT_X), _int_at(cols, COL_LT_Y))
	info.coord_rb = Vector2i(_int_at(cols, COL_RB_X), _int_at(cols, COL_RB_Y))
	info.fortress_world_id = cols[COL_FORTRESS_WORLD_ID].strip_edges()
	info.name_key = cols[COL_NAME_KEY].strip_edges()
	if cols.size() > COL_ONE_REGION:
		info.regions_per_tile = _region_size(cols[COL_ONE_REGION].strip_edges())
	return info

static func _parse_dungeon(cols: PackedStringArray) -> DungeonMapInfo:
	var info := DungeonMapInfo.new()
	info.id = _int_at(cols, DCOL_ID)
	info.layers = _int_at(cols, DCOL_LAYERS)
	info.total_layers = _int_at(cols, DCOL_TOTAL_LAYERS)
	info.zone_code = _int_at(cols, DCOL_ZONE_CODE)
	info.texture_count = Vector2i(
		_int_at(cols, DCOL_TEXTURE_COUNT_X), _int_at(cols, DCOL_TEXTURE_COUNT_Y))
	info.draw_size = Vector2i(_int_at(cols, DCOL_DRAW_W), _int_at(cols, DCOL_DRAW_H))
	info.region_left = _int_at(cols, DCOL_REGION_LEFT)
	info.region_top = _int_at(cols, DCOL_REGION_TOP)
	info.region_right = _int_at(cols, DCOL_REGION_RIGHT)
	info.region_bottom = _int_at(cols, DCOL_REGION_BOTTOM)
	info.scale = float(cols[DCOL_SCALE].strip_edges()) if cols.size() > DCOL_SCALE else 0.0
	info.addr = cols[DCOL_ADDR].strip_edges().replace("/", "\\")
	info.region_id = _int_at(cols, DCOL_REGION_ID)
	return info

## "4x4" -> (4, 4). Anything else -- the file writes "xxx" for every map
## that is a single image -- is one region per tile.
static func _region_size(text: String) -> Vector2i:
	var parts := text.to_lower().split("x")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ONE
	return Vector2i(int(parts[0]), int(parts[1]))

static func _int_at(cols: PackedStringArray, index: int) -> int:
	if index >= cols.size():
		return 0
	var text := cols[index].strip_edges()
	return int(text) if text.is_valid_int() else 0

static func _lines(data: PackedByteArray) -> PackedStringArray:
	if data.is_empty():
		return PackedStringArray()
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var text := TextDecode.utf16(raw)
	if text.is_empty():
		text = raw.get_string_from_utf8()
	return text.replace("\r", "").split("\n")
