extends RefCounted
class_name TileIndexReader

## Read-only parser for tile2d.ifo (JMXV2DTI) -- the real answer to what a
## .m region file's real per-vertex TextureInfo.ID actually resolves to.
## See docs/protocol/TILE2D_FORMAT.md for the full derivation (found via
## the same public documentation source that solved .m/.t, then confirmed
## real and present in a real Data.pk2 at both `tile2d.ifo` and
## `navmesh\tile2d.ifo`).
##
## Like .ifo object-index tables (ObjidxReader), this is not a binary
## container: after the magic line and a count line, it's a plain ASCII
## text table, one real tile type per line.
##
## **Corrected (2026-08-23), see docs/protocol/DDJ_FORMAT.md/
## TILE2D_FORMAT.md**: an earlier version of this comment claimed the real
## ground-texture .ddj files (Category+Filename) referenced here "don't
## actually exist anywhere" -- that search only ever checked Data.pk2/
## Media.pk2/Particles.pk2. They really do exist, in a real Map.pk2\Tile2D\
## folder this project hadn't checked yet at the time. World3D.gd's
## _prepare_ground_textures (round 565; _load_real_ground_textures before)
## resolves them from there and, live-verified
## multiple times this session (including a full-catalog audit,
## 2026-08-25), gets a 100% real resolution rate.

const MAGIC := "JMXV2DTI1001"

## Real, confirmed enum values from the public documentation -- not every
## value has been seen in a real file, but every value seen in the one
## real sample checked (0, 1, 3, 6, 7, 9, 10, 11, 12) matches this
## naming exactly.
enum TileType {
	DIRT = 0,
	SAND = 1,
	ASHFIELD = 2,
	STONE = 3,
	METAL = 4,
	WOOD = 5,
	MUD = 6,
	WATER = 7,
	DEEP_WATER = 8,
	SNOW = 9,
	GRASS = 10,
	LONG_GRASS = 11,
	FOREST = 12,
	CLOUD = 13,
}

class Entry:
	var id: int
	var type: TileType
	var category: String
	var filename: String

## Parsed tile2d.ifo table. entries is indexed by id directly (confirmed
## real: the one real file checked has entries in strict sequential order
## starting at 0) -- lookup() still bounds-checks rather than assuming
## that holds for every possible real file.
class Table:
	var entries: Array[Entry] = []

	## Returns the real entry for id (as found in a real .m vertex's
	## TextureInfo.ID field), or null if id is out of range for this
	## table.
	func lookup(id: int) -> Entry:
		if id < 0 or id >= entries.size():
			return null
		var e := entries[id]
		if e.id != id:
			return null
		return e

## Parses a real tile2d.ifo file's raw bytes. Returns null (and pushes an
## error) if the magic line, declared count, or any record line doesn't
## match the real, confirmed format:
## "JMXV2DTI1001\n<count>\n" followed by exactly <count> lines shaped
## "%05d 0x%08x \"<category>\" \"<filename>\"", each optionally followed
## by a real trailing "{a,b}" grass-placement field this reader doesn't
## need and skips.
static func parse(data: PackedByteArray) -> Table:
	var _pp := ParseProfile.t0()
	var _out: Table = _pp_parse(data)
	ParseProfile.add("tile2d.parse", _pp)
	return _out

## The body of parse, timed by its wrapper above (ParseProfile, round 667).
static func _pp_parse(data: PackedByteArray) -> Table:
	var text := data.get_string_from_ascii()
	var lines := text.split("\n")
	if lines.size() < 2:
		push_error("tile2d: file too short to contain a header")
		return null
	if lines[0].strip_edges() != MAGIC:
		push_error("tile2d: bad magic %s, want %s" % [lines[0], MAGIC])
		return null

	if not lines[1].strip_edges().is_valid_int():
		push_error("tile2d: bad count line %s" % lines[1])
		return null
	var count := lines[1].strip_edges().to_int()
	if count < 0:
		push_error("tile2d: bad count line %s" % lines[1])
		return null
	if lines.size() < 2 + count:
		push_error("tile2d: declared %d records but file only has %d body lines" % [count, lines.size() - 2])
		return null

	var table := Table.new()
	for i in range(count):
		var e := _parse_line(lines[2 + i])
		if e == null:
			push_error("tile2d: record %d: malformed line %s" % [i, lines[2 + i]])
			return null
		table.entries.append(e)

	return table

static func _parse_line(line: String) -> Entry:
	# Real shape: "%05d 0x%08X \"<category>\" \"<filename>\"" (+ an
	# optional trailing "{a,b}" this reader skips) -- space-separated
	# fields, the 3rd and 4th quoted.
	var first_space := line.find(" ")
	if first_space < 0:
		return null
	var id_field := line.substr(0, first_space)
	if not id_field.is_valid_int():
		return null

	var rest := line.substr(first_space + 1)
	var second_space := rest.find(" ")
	if second_space < 0:
		return null
	var type_field := rest.substr(0, second_space)
	if not type_field.begins_with("0x"):
		return null
	var type_hex := type_field.substr(2)
	if not type_hex.is_valid_hex_number():
		return null

	rest = rest.substr(second_space + 1).strip_edges()
	if rest.length() < 1 or rest[0] != "\"":
		return null
	var category_end := rest.find("\"", 1)
	if category_end < 0:
		return null
	var category := rest.substr(1, category_end - 1)

	rest = rest.substr(category_end + 1).strip_edges()
	if rest.length() < 1 or rest[0] != "\"":
		return null
	var filename_end := rest.find("\"", 1)
	if filename_end < 0:
		return null
	var filename := rest.substr(1, filename_end - 1)

	var e := Entry.new()
	e.id = id_field.to_int()
	e.type = type_hex.hex_to_int() as TileType
	e.category = category
	e.filename = filename
	return e
