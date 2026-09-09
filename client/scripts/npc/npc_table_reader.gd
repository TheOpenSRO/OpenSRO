extends RefCounted
class_name NpcTableReader

## Reads the two tables that place NPCs in the world, both of which live in
## the player's own Media.pk2 -- so nothing has to be shipped and no server
## has to supply them.
##
## `server_dep\silkroad\textdata\npcpos.txt` is where every NPC stands:
## UTF-16LE, tab separated, five columns of
## **npc id, region id, X, Y, Z**. A real archive holds 12,367 rows.
##
## `server_dep\silkroad\textdata\characterdata*.txt` maps an npc id to its
## model. Those files are ~104 columns wide and split across several
## numbered parts; the `.bsr` path is the one field that looks like a model
## path, which is how it is found here rather than by a column index that
## would differ between parts.
##
## The region id is the same `(x << 8) | y` key used for navmesh filenames
## and teleport destinations -- `25257` is region 98/169, `25001` is 97/169.

## The characterdata table is split across these; the unnumbered file is
## the small header table. Missing parts are skipped, so a partial archive
## still yields whatever it does have.
const MODEL_TABLE_PATHS := [
	"server_dep\\silkroad\\textdata\\characterdata.txt",
	"server_dep\\silkroad\\textdata\\characterdata_5000.txt",
	"server_dep\\silkroad\\textdata\\characterdata_10000.txt",
	"server_dep\\silkroad\\textdata\\characterdata_15000.txt",
	"server_dep\\silkroad\\textdata\\characterdata_20000.txt",
	"server_dep\\silkroad\\textdata\\characterdata_25000.txt",
	"server_dep\\silkroad\\textdata\\characterdata_30000.txt",
]
const POSITION_TABLE_PATH := "server_dep\\silkroad\\textdata\\npcpos.txt"

const COL_POS_NPC_ID := 0
const COL_POS_REGION := 1
const COL_POS_X := 2
const COL_POS_Y := 3
const COL_POS_Z := 4

## Column 1 is the id in every characterdata part checked.
const COL_MODEL_ID := 1

class Spawn:
	var npc_id: int
	var region_x: int
	var region_y: int
	## Region-local position, the same space terrain and navmesh use.
	var local_position: Vector3

## Parses npcpos.txt. Rows that don't have five numeric columns are skipped
## rather than failing the file -- these tables carry comment lines.
static func parse_positions(data: PackedByteArray) -> Array[Spawn]:
	var out: Array[Spawn] = []
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.size() <= COL_POS_Z:
			continue
		var id_text := cols[COL_POS_NPC_ID].strip_edges()
		var region_text := cols[COL_POS_REGION].strip_edges()
		if not (id_text.is_valid_int() and region_text.is_valid_int()):
			continue
		var region := int(region_text)
		var spawn := Spawn.new()
		spawn.npc_id = int(id_text)
		spawn.region_x = (region >> 8) & 0xFF
		spawn.region_y = region & 0xFF
		spawn.local_position = Vector3(
			float(cols[COL_POS_X].strip_edges()),
			float(cols[COL_POS_Y].strip_edges()),
			float(cols[COL_POS_Z].strip_edges()))
		out.append(spawn)
	return out

## Parses one characterdata part into {npc id -> .bsr path}, merging into
## `into` so several parts can be accumulated.
static func parse_models(data: PackedByteArray, into: Dictionary = {}) -> Dictionary:
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.size() <= COL_MODEL_ID:
			continue
		var id_text := cols[COL_MODEL_ID].strip_edges()
		if not id_text.is_valid_int():
			continue
		var model := _find_model_path(cols)
		if model != "":
			into[int(id_text)] = model
	return into

## The `.bsr` field in a characterdata row. Found by looking rather than by
## index: the parts are ~104 columns wide and there is no guarantee the
## path sits at the same place in each.
static func _find_model_path(cols: PackedStringArray) -> String:
	for col in cols:
		var trimmed := col.strip_edges()
		if trimmed.to_lower().ends_with(".bsr"):
			return trimmed
	return ""

static func _lines(data: PackedByteArray) -> PackedStringArray:
	if data.is_empty():
		return PackedStringArray()
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var text := raw.get_string_from_utf16()
	if text.is_empty():
		text = raw.get_string_from_utf8()
	return text.replace("\r", "").split("\n")
