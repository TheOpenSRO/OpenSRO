extends RefCounted
class_name WorldmapLocalInfoReader

## Reads `server_dep\silkroad\textdata\worldmap_localinfo.txt` -- the signs
## the world map draws over a map: the city, fortress and dungeon icons on
## the world map, the shop icons and names on a town's map, the room names on
## a dungeon floor (round 775). Facts are labelled READ (sro_client.exe,
## md5 2a5794b72c90908d945be8b3f3f2edd4), MEASURED (the retail archive on the
## render box; nothing of it is reproduced here), INFERRED or OURS.
##
## **The loader (READ).** Client_LoadRefDataFile's type-4 case reads the
## row's first token as a string, turns it to a number (0xb43f9b) and skips
## the row when that is 0 (0x9534c4..0x9534e0) -- the `service` column, so
## `0` rows and `//` comment rows are both skipped. The rest goes to
## RefParse_worldmap_localinfo (0x96f280), one token after another into
## fixed members: the column map below is that order. The world map reads a
## record through 0x96f0b0, which hands back the record + 4, so the window's
## offsets are the parser's less 4.
##
## **How the window uses a sign (READ, NIFWorldMap 0x6210b0).** Showing a
## map (0x622b60 for the world and local maps, 0x6217e0 for a dungeon floor)
## lists every sign whose parent column is that map's id. Its place:
## - parent 0 (the world map): `x + (region_a - world.left) * 32`,
##   `y + (world.top - region_b) * 32` -- 32 pixels a region, the world
##   map's own scale;
## - any other map: `x`, `y` as written, pixels on that map's image.
## A type-2 sign is the picture in column 3, `w` x `h` with its top-left
## there (the quad, `+0x31..+0x44`); a type-1 sign is text, centred on `x`
## (`x - width / 2`, 0x6210b0 / 0x6196d0) with its top at `y`.
## On the world map a press and a release on the same type-2 sign with a
## link opens the linked map (vslot_017 0x623220): a local map below 2001
## (0x622b60), a dungeon floor from 2001 (0x6217e0), and never a fortress
## (a press recorded in 1001..1999 opens nothing).

const TABLE_PATH := "server_dep\\silkroad\\textdata\\worldmap_localinfo.txt"

## Type column (byte, +0x08): text, or a picture.
const TYPE_TEXT := 1
const TYPE_PICTURE := 2

## 32 pixels a region on the world map (0x6210b0: `(region - left) * 0x20`).
const WORLD_PIXELS_PER_REGION := 32

## Columns, in the order 0x96f280 reads them (READ; the stores are at the
## parser's offsets given).
const COL_SERVICE := 0      # the loader's skip test
const COL_ID := 1           # +0x04
const COL_TYPE := 2         # +0x08 (byte)
const COL_TEXT := 3         # +0x0c wide string: a text key (type 1) or a .ddj (type 2)
# 4, 5, 6: three more wide strings (+0x28, +0x44, +0x60) -- glosses, unused
# by the window.
const COL_LINK := 7         # +0x7c: the map a type-2 sign opens; 1 / 2 decorate a type-1 text
const COL_PARENT := 8       # +0x80: the map the sign is drawn on (0 the world map)
const COL_REGION_A := 9     # +0x84: with the world map's `left` (region y)
const COL_REGION_B := 10    # +0x88: with the world map's `top` (region x)
const COL_X := 11           # +0x8c
const COL_Y := 12           # +0x90
const COL_W := 13           # +0x94
const COL_H := 14           # +0x98: a type-2 sign's height, a type-1 sign's font
const COL_R := 15           # +0x9c = 0xff000000 | r << 16 | g << 8 | b
const COL_G := 16
const COL_B := 17
const COL_SHADOW := 18      # +0xa0 (byte)
const COL_BOLD := 19        # +0xa1 (byte)
const COL_BLUR := 20        # +0xa2 (byte)
const COL_TIP := 21         # +0xc4 wide string (an `SN_` key or "xxx")

class Sign:
	var id: int
	var type: int
	## A text key (type 1) or a picture path (type 2).
	var text: String
	var link: int
	var parent: int
	var region_a: int
	var region_b: int
	var pos: Vector2i
	var size: Vector2i
	var color := Color.WHITE
	var shadow: int
	var bold: int
	var blur: int
	var tip: String

	## The sign's anchor in pixels on the map it is drawn on (0x6210b0,
	## READ): a world-map sign (parent 0) is placed by its region against the
	## world map's `left` / `top`; any other as written. `world_left` and
	## `world_top` are the world map's region bounds.
	func anchor(world_left: int, world_top: int) -> Vector2i:
		if parent != 0:
			return pos
		return Vector2i(pos.x + (region_a - world_left) * WORLD_PIXELS_PER_REGION,
			pos.y + (world_top - region_b) * WORLD_PIXELS_PER_REGION)

	## A type-2 sign's quad: its anchor is the top-left, its size the `w` and
	## `h` columns (0x6196d0 / 0x61b510 lay `+0x37 = x + w`,
	## `+0x3e = y + h`; READ).
	func rect(world_left: int, world_top: int) -> Rect2:
		return Rect2(Vector2(anchor(world_left, world_top)), Vector2(size))

	## The press / release hit test (0x623220, READ): strictly inside the
	## quad on all four sides.
	func hit(world_left: int, world_top: int, at: Vector2) -> bool:
		var r := rect(world_left, world_top)
		return at.x > r.position.x and at.x < r.end.x and at.y > r.position.y and at.y < r.end.y

class Table:
	var signs: Array[Sign] = []

	## The signs drawn on map `id`, in file order (0x6210b0 walks the table
	## and keeps those whose parent is the map shown).
	func for_map(id: int) -> Array[Sign]:
		var out: Array[Sign] = []
		for s in signs:
			if s.parent == id:
				out.append(s)
		return out

static func parse(data: PackedByteArray) -> Table:
	var table := Table.new()
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.is_empty():
			continue
		var service := cols[COL_SERVICE].strip_edges()
		# _wtoi: a leading number, 0 for anything else ("//", blank).
		if not service.is_valid_int() or int(service) == 0:
			continue
		var s := Sign.new()
		s.id = _int_at(cols, COL_ID)
		s.type = _int_at(cols, COL_TYPE)
		s.text = _str_at(cols, COL_TEXT)
		s.link = _int_at(cols, COL_LINK)
		s.parent = _int_at(cols, COL_PARENT)
		s.region_a = _int_at(cols, COL_REGION_A)
		s.region_b = _int_at(cols, COL_REGION_B)
		s.pos = Vector2i(_int_at(cols, COL_X), _int_at(cols, COL_Y))
		s.size = Vector2i(_int_at(cols, COL_W), _int_at(cols, COL_H))
		s.color = Color8(_int_at(cols, COL_R) & 0xff, _int_at(cols, COL_G) & 0xff, _int_at(cols, COL_B) & 0xff)
		s.shadow = _int_at(cols, COL_SHADOW)
		s.bold = _int_at(cols, COL_BOLD)
		s.blur = _int_at(cols, COL_BLUR)
		s.tip = _str_at(cols, COL_TIP)
		table.signs.append(s)
	return table

static func _int_at(cols: PackedStringArray, index: int) -> int:
	if index >= cols.size():
		return 0
	var text := cols[index].strip_edges()
	return int(text) if text.is_valid_int() else 0

static func _str_at(cols: PackedStringArray, index: int) -> String:
	return cols[index].strip_edges() if index < cols.size() else ""

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
