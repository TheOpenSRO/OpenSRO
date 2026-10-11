extends RefCounted
class_name WorldmapInstanceInfoReader

## Reads `server_dep\silkroad\textdata\worldmap_instanceinfo.txt` -- where
## the world map puts a player who is somewhere the field map does not
## cover: a dungeon, a cave, an arena (round 775). Labels: READ
## (sro_client.exe), MEASURED (the retail archive on the render box, nothing
## reproduced), INFERRED, OURS.
##
## **The loader (READ, Client_LoadRefDataFile 0x9536a0..0x9537fe).** Each row
## is expanded into one entry per region of its box: z from `RegionTop` up
## to `RegionBottom`, x from `RegionLeft` up to `RegionRight`, both loops
## ascending (a row whose start is past its end gives nothing), key
## `x | z << 8`. The entry keeps the field point: the region
## `(MapRegionZ << 8 | MapRegionX) & 0x7fff` and the position as three
## floats. Which column is which is INFERRED from the header row: the
## parser's token order was not traced past the box.
##
## **Its use (READ).** With the table loaded (`0xeedf08 + 0x1ec`, 0x8d83e0)
## and the player's region in it (0x9375b0), a field map (world or local)
## draws the player's arrow at the entry's point and centres there
## (0x60fa90, 0x610980, 0x61cc30), as `(low - 135) * 192 + x / 10`,
## `(high - 92) * 192 + z / 10` through the map's own transform -- but only
## when the player's region has bit 15 (the render, 0x61f20c). Without the
## table the client falls back on two constants (0x610c5e..0x610cab): the
## region id 0x8001 at (2465, 2693), 0x8002..0x8007 at (7200, 2102).
##
## MEASURED: the archive's dungeon rows are `Worldmap_DONWHANG` (box 1..1 x
## 128) and `Worldmap_JINSI` (2..7 x 128); the field points they give are
## within 0.3 of the first constant and 34 units off the second.

const TABLE_PATH := "server_dep\\silkroad\\textdata\\worldmap_instanceinfo.txt"

const COL_CODE := 0
# 1 is the Korean name, "(Skip)" in the header.
const COL_LEFT := 2
const COL_TOP := 3
const COL_RIGHT := 4
const COL_BOTTOM := 5
const COL_MAP_REGION_X := 6
const COL_MAP_REGION_Z := 7
const COL_POS_X := 8
const COL_POS_Y := 9
const COL_POS_Z := 10

## The fallbacks for a client without the table (0x610c5e..0x610cab, READ
## as floats at 0xd99098 / 0xd99094 and 0xd99090 / 0xd9908c).
const FALLBACK_DONWHANG := Vector2(2465.0, 2693.0)
const FALLBACK_QIN_SHI := Vector2(7200.0, 2102.0)

class Entry:
	var code: String
	## The field region the point is in, `z << 8 | x`.
	var map_region: int
	var pos: Vector3

	## The point in the world map's units (0x60fa90, READ).
	func world_point() -> Vector2:
		var low := map_region & 0xff
		var high := (map_region >> 8) & 0xff
		return Vector2(
			float((low - WorldmapInfoReader.REGION_Y_ORIGIN) * WorldmapInfoReader.REGION_SPAN) + pos.x / 10.0,
			float((high - WorldmapInfoReader.REGION_X_ORIGIN) * WorldmapInfoReader.REGION_SPAN) + pos.z / 10.0)

class Table:
	## Region id (`x | z << 8`) -> Entry, the loader's expansion. The first
	## row to claim a region keeps it (OURS: the map's insert was not read).
	var by_region := {}

	func find(region_id: int) -> Entry:
		return by_region.get(region_id) as Entry

## The point a player in `region_id` is drawn at on a field map, or null:
## the table's entry; without a table (`table` null), the client's two
## constants for the dungeons it knew (0x610c5e..0x610cab).
static func field_point(table: Table, region_id: int) -> Variant:
	if table != null:
		var e := table.find(region_id)
		return e.world_point() if e != null else null
	if region_id & 0x8000 == 0:
		return null
	var low := region_id & 0x7fff
	if low == 1:
		return FALLBACK_DONWHANG
	if low >= 2 and low <= 7:
		return FALLBACK_QIN_SHI
	return null

static func parse(data: PackedByteArray) -> Table:
	var table := Table.new()
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.size() <= COL_POS_Z:
			continue
		var code := cols[COL_CODE].strip_edges()
		if code == "" or code.begins_with("//"):
			continue
		var e := Entry.new()
		e.code = code
		e.map_region = ((_int_at(cols, COL_MAP_REGION_Z) << 8) | (_int_at(cols, COL_MAP_REGION_X) & 0xff)) & 0x7fff
		e.pos = Vector3(_int_at(cols, COL_POS_X), _int_at(cols, COL_POS_Y), _int_at(cols, COL_POS_Z))
		var left := _int_at(cols, COL_LEFT)
		var right := _int_at(cols, COL_RIGHT)
		var top := _int_at(cols, COL_TOP)
		var bottom := _int_at(cols, COL_BOTTOM)
		for z in range(top, bottom + 1):
			for x in range(left, right + 1):
				var key: int = ((z & 0xff) << 8) | (x & 0xff)
				if not table.by_region.has(key):
					table.by_region[key] = e
	return table

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
