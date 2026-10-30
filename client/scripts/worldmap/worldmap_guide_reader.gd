extends RefCounted
class_name WorldmapGuideReader

## Reads `server_dep\silkroad\textdata\worldmapguidedata.txt` -- what the
## world map's guide has to say about *where things are*: which towns and
## areas exist, which monsters live in which tile, and where each quest
## sends you.
##
## Four `#section`s, each with its own column layout and its own header row
## naming every column:
##
##   MAP_MANAGER  18 rows  항목 | 시작 리전 | 끝 리전 | 그림 한장의 사이즈 |
##                         한 리전크기 | 맵ID
##   AREA         39 rows  이름 | 코드네임 | 스트링네임 | 지역 | 분류 | …
##   MONSTER     339 rows  이름 | 코드네임 | 지역 | 분류 | 순서… |
##                         x | y | 리전x | 리전y | pos_x | pos_y | 색상값
##   QUEST       492 rows  퀘스트 이름 | 코드네임 | 구분 | 지역 |
##                         x | y | 리전x | 리전y | pos_x | pos_y | 몬스터 코드네임
##
## MAP_MANAGER joins to worldmap_mapinfo.txt by 맵ID, and says the same
## things about the world map: start region `46x113`, one picture 128x128,
## one region size `4x4`. A second table, authored separately, stating the
## same grid.
##
## **Do not read the `x`/`y` columns.** They are world-map pixels and they
## are stale: for the 173 field monsters on the world map's grid the pitch
## is exactly 128 on both axes and the row index is exact for every one,
## but the *column* index is five tiles out for the 142 `MOB_CH_*` rows and
## exact for the 31 newer western ones. The map was re-cut westward at some
## point and the Chinese entries were never re-based. (The 89 field quests
## are exact on both axes, so it is specific to those monster rows.) The
## region and `pos_` columns are consistent throughout, so `pixel_in()`
## derives the pixel rather than reading it.
##
## See docs/protocol/WORLDMAP_FORMAT.md.

const TABLE_PATH := "server_dep\\silkroad\\textdata\\worldmapguidedata.txt"

const SECTION_MAPS := "MAP_MANAGER"
const SECTION_AREAS := "AREA"
const SECTION_MONSTERS := "MONSTER"
const SECTION_QUESTS := "QUEST"

## MAP_MANAGER. Column indices are the header's own order.
const MCOL_SERVICE := 0
const MCOL_NAME := 1
const MCOL_START_REGION := 2
## Column 3 is headed 끝 리전, "end region", and is not one: it reads
## `17x26` for twelve of the eighteen rows and then counts up 27, 28, 29,
## 30, 31, 32 through the last six, and matches no map's dimensions. Read
## and kept as text rather than interpreted.
const MCOL_END_REGION := 3
const MCOL_TEXTURE_SIZE := 4
const MCOL_ONE_REGION := 5
const MCOL_MAP_ID := 6

## AREA.
const ACOL_NAME := 1
const ACOL_CODE := 2
const ACOL_STRING_KEY := 3
const ACOL_AREA := 4
const ACOL_KIND := 5

## MONSTER and QUEST carry the same six geometry columns at different
## indices, which is the whole reason the reader tracks the section.
const MON_CODE := 2
const MON_AREA := 3
const MON_GEOMETRY := 8
const MON_COLOUR := 14

const QST_CODE := 2
const QST_KIND := 3
const QST_AREA := 4
const QST_GEOMETRY := 5
const QST_MONSTER_CODE := 11


## One MAP_MANAGER row: a map the guide can put marks on.
class GuideMap:
	## The name the point rows join to, in their 지역 column: "field",
	## "dunhuang1", "jupiter_field" and so on.
	var name: String
	## The first tile's name, as `<A>x<B>` -- A is region y and B region x,
	## the same convention as the tile files. The world map's is 46x113,
	## which is `left x top` from worldmap_mapinfo.txt.
	var start_region: Vector2i
	var texture_size: Vector2i
	var regions_per_tile: Vector2i
	## Joins to a WorldmapInfoReader map, or to a dungeon floor.
	var map_id: int
	var end_region_text: String
	## The 서비스 column (round 845; the client loads a row only when it is
	## not 0).
	var service: int = 1

	## Where a region and an in-tile offset land on this map, in pixels
	## from its top-left. A ascends from the start and B descends from it,
	## the same as the tile grid.
	func pixel(region: Vector2i, pos: Vector2i) -> Vector2i:
		var step := Vector2i(maxi(1, regions_per_tile.x), maxi(1, regions_per_tile.y))
		return Vector2i(
			(region.x - start_region.x) / step.x * texture_size.x + pos.x,
			(start_region.y - region.y) / step.y * texture_size.y + pos.y)


## One MONSTER or QUEST row: something with a place on a map.
class GuidePoint:
	var code: String
	## The Korean display name, or the quest's planning name.
	var name: String
	## The MAP_MANAGER 항목 this point belongs to.
	var area: String
	## `<A>x<B>` -- the tile, named by its own first region.
	var region: Vector2i
	## Pixels within that tile.
	var pos: Vector2i
	## The `x`/`y` columns, kept but **not to be used as the position** --
	## see the note at the top of this file, and
	## `client/tools/check_worldmap_guide.gd`, which measures how far out
	## they are. `pixel_in()` derives the position instead.
	var stated_pixel: Vector2i
	## MONSTER only: the 색상값 column, `0x80000005` and friends.
	var colour_text: String
	## QUEST only: the monster the quest is about, if it names one.
	var monster_code: String
	## The 서비스 column: the client loads a MONSTER or QUEST row only when
	## it is not 0 (Client_LoadRefDataFile case 0x59, round 845, READ).
	var service: int = 1
	## QUEST only: the 구분 column (+0xf0, GlobalDataManager 0x970110): 0
	## the monster codes' areas, 1 a quest icon at the row's own place
	## (NIFWorldMap 0x6256e0, round 845).
	var kind: int = 0

	## QUEST: the last column split at `,` (0x970110's loop over 0x4ee310):
	## monster codes for kind 0, the icon's tooltip keys for kind 1.
	func codes() -> PackedStringArray:
		var out := PackedStringArray()
		for c in monster_code.split(",", false):
			var t := c.strip_edges()
			if t != "":
				out.append(t)
		return out

	## MONSTER: the 색상값 column's colours, `0x80000005[,0x...]` -- the
	## values the monster's area texels carry in its mask tiles
	## (interface\worldmap\monster\<area>_<x>x<y>.ddj; MEASURED:
	## field_166x101's texels are 0x80000004, MOB_CH_WATERGHOST's colour).
	func colours() -> PackedInt64Array:
		var out := PackedInt64Array()
		for c in colour_text.split(",", false):
			var t := c.strip_edges().to_lower()
			if t.begins_with("0x"):
				t = t.substr(2)
			if t != "" and t.is_valid_hex_number():
				out.append(t.hex_to_int())
		return out

	func pixel_in(map: GuideMap) -> Vector2i:
		return map.pixel(region, pos) if map != null else Vector2i.ZERO


class ParsedGuide:
	var maps: Array[GuideMap] = []
	var areas: Array[GuidePoint] = []
	var monsters: Array[GuidePoint] = []
	var quests: Array[GuidePoint] = []
	## Rows in a section this reader does not know, counted rather than
	## read with the wrong columns.
	var skipped_other_sections: int = 0

	func map_named(name: String) -> GuideMap:
		for m in maps:
			if m.name == name:
				return m
		return null

	## Every monster the guide places in one tile of one map.
	func monsters_in(area: String, region: Vector2i) -> Array[GuidePoint]:
		var out: Array[GuidePoint] = []
		for m in monsters:
			if m.area == area and m.region == region:
				out.append(m)
		return out


static func parse(data: PackedByteArray) -> ParsedGuide:
	var guide := ParsedGuide.new()
	var section := ""
	for line in _lines(data):
		var cols := line.split("\t")
		if line.begins_with("#section"):
			section = cols[1].strip_edges() if cols.size() > 1 else ""
			continue
		# Every data row's first column is the 서비스 flag, 1 or 0; the
		# header rows and the `//실제 데이터 영역` separators start with
		# `//`, and the section lines were taken above.
		var flag := cols[0].strip_edges() if cols.size() > 0 else ""
		if not flag.is_valid_int():
			continue
		match section:
			SECTION_MAPS:
				if cols.size() > MCOL_MAP_ID:
					guide.maps.append(_parse_map(cols))
			SECTION_AREAS:
				if cols.size() > ACOL_KIND:
					guide.areas.append(_parse_area(cols))
			SECTION_MONSTERS:
				if cols.size() > MON_COLOUR:
					guide.monsters.append(_parse_point(
						cols, MON_CODE, MON_AREA, MON_GEOMETRY, MON_COLOUR, -1))
			SECTION_QUESTS:
				if cols.size() > QST_MONSTER_CODE:
					var q := _parse_point(cols, QST_CODE, QST_AREA, QST_GEOMETRY, -1, QST_MONSTER_CODE)
					q.kind = _int_at(cols, QST_KIND)
					guide.quests.append(q)
			_:
				guide.skipped_other_sections += 1
	return guide

## `server_dep\silkroad\textdata\worldmapguidedata_region.txt` (round
## 845): `<monster code>\t<A>x<B>[,<A>x<B>...]`, the tiles of a monster's
## mask. The client appends each row's tiles to the monster's record
## (Client_LoadRefDataFile case 0x5d: 0x9417f0 by the code, then every
## pair), so a code's rows add up, in file order. Code -> Array of Vector2i.
const REGION_TABLE_PATH := "server_dep\\silkroad\\textdata\\worldmapguidedata_region.txt"

static func parse_region_tiles(data: PackedByteArray) -> Dictionary:
	var out := {}
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.size() < 2:
			continue
		var code := cols[0].strip_edges()
		if code == "" or code.begins_with("//"):
			continue
		var tiles: Array = out.get(code, [])
		for part in cols[1].split(",", false):
			var t := _pair(part)
			if t != Vector2i.ZERO:
				tiles.append(t)
		out[code] = tiles
	return out

static func _parse_map(cols: PackedStringArray) -> GuideMap:
	var m := GuideMap.new()
	m.service = int(cols[0].strip_edges())
	m.name = cols[MCOL_NAME].strip_edges()
	m.start_region = _pair(cols[MCOL_START_REGION])
	m.end_region_text = cols[MCOL_END_REGION].strip_edges()
	m.texture_size = _pair(cols[MCOL_TEXTURE_SIZE])
	m.regions_per_tile = _pair(cols[MCOL_ONE_REGION])
	m.map_id = _int_at(cols, MCOL_MAP_ID)
	return m

static func _parse_area(cols: PackedStringArray) -> GuidePoint:
	var p := GuidePoint.new()
	p.name = cols[ACOL_NAME].strip_edges()
	p.code = cols[ACOL_CODE].strip_edges()
	# An area has no coordinates of its own; the string key is what it
	# carries that a caller wants.
	p.monster_code = cols[ACOL_STRING_KEY].strip_edges()
	p.area = cols[ACOL_AREA].strip_edges()
	p.colour_text = cols[ACOL_KIND].strip_edges()
	return p

## MONSTER and QUEST differ only in where their six geometry columns start
## and what trails them, so one function reads both.
static func _parse_point(cols: PackedStringArray, code_col: int, area_col: int,
		geometry_col: int, colour_col: int, monster_col: int) -> GuidePoint:
	var p := GuidePoint.new()
	p.service = int(cols[0].strip_edges())
	p.name = cols[1].strip_edges()
	p.code = cols[code_col].strip_edges()
	p.area = cols[area_col].strip_edges()
	# geometry is x, y, 리전x, 리전y, pos_x, pos_y. The first pair is the
	# stale one; see the note at the top of this file.
	p.stated_pixel = Vector2i(_int_at(cols, geometry_col), _int_at(cols, geometry_col + 1))
	p.region = Vector2i(_int_at(cols, geometry_col + 2), _int_at(cols, geometry_col + 3))
	p.pos = Vector2i(_int_at(cols, geometry_col + 4), _int_at(cols, geometry_col + 5))
	if colour_col >= 0:
		p.colour_text = cols[colour_col].strip_edges()
	if monster_col >= 0 and monster_col < cols.size():
		p.monster_code = cols[monster_col].strip_edges()
	return p

## "46x113" -> (46, 113). The file writes "xxx" where a row has none.
static func _pair(text: String) -> Vector2i:
	var parts := text.strip_edges().to_lower().split("x")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))

static func _int_at(cols: PackedStringArray, index: int) -> int:
	if index < 0 or index >= cols.size():
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
