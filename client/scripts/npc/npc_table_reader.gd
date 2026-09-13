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
## Maps the `SN_` name key a characterdata row carries to a display name --
## `SN_MOB_CH_MANGNYANG` to "Mangyang". Same shape as the UI string table,
## so UiTextTable parses it.
const OBJECT_NAME_TABLE_PATH := "server_dep\\silkroad\\textdata\\textdata_object.txt"

const COL_POS_NPC_ID := 0
const COL_POS_REGION := 1
const COL_POS_X := 2
const COL_POS_Y := 3
const COL_POS_Z := 4

## Column 1 is the id in every characterdata part checked, and column 2
## the code name (`CHAR_CH_MAN_FIGHTER`, `MOB_CH_MANGNYANG`).
const COL_MODEL_ID := 1
const COL_CODE_NAME := 2

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

## Parses one characterdata part into {npc id -> codename}, merging into `into`.
## The codename (NPC_CH_SMITH) is what the shop/greeting tables key by, so this
## is the join from a placed NPC's id to those tables.
static func parse_codes(data: PackedByteArray, into: Dictionary = {}) -> Dictionary:
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.size() <= COL_CODE_NAME:
			continue
		var id_text := cols[COL_MODEL_ID].strip_edges()
		if not id_text.is_valid_int():
			continue
		var code := cols[COL_CODE_NAME].strip_edges()
		if code != "":
			into[int(id_text)] = code
	return into

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

## Parses one characterdata part into {lowercased display name -> .bsr
## path}, merging into `into`.
##
## This is what lets a caller ask for a model by the name a creature is
## known by rather than by id. A characterdata row carries an `SN_` key
## (`SN_MOB_CH_MANGNYANG`) and a model path; `names` resolves that key to a
## display name ("Mangyang"). Joining the two gives name -> model without
## anything hardcoded per species.
##
## Lowercased on both sides because the tables and the server do not agree
## on capitalisation.
static func parse_models_by_name(
	data: PackedByteArray, names: UiTextTable, into: Dictionary = {}
) -> Dictionary:
	if names == null:
		return into
	for line in _lines(data):
		var cols := line.split("\t")
		var model := _find_model_path(cols)
		if model == "":
			continue
		var key := _find_name_key(cols)
		if key == "":
			continue
		var display := names.get_text(key)
		# get_text falls back to the key itself when it isn't in the table;
		# that is not a name anyone would search for.
		if display == "" or display == key:
			continue
		into[display.to_lower()] = model
	return into

## Parses one characterdata part into {code name -> model path}, merging
## into `into`: `CHAR_CH_MAN_FIGHTER` -> `char\\china\\chinaman_fighter.bsr`,
## `MOB_CH_MANGNYANG` -> `mob\\china\\mangnyang.bsr`. `prefix` narrows it
## to one kind of row; "" takes every row that has a code and a model.
##
## The player's own body is a row in this table like any NPC's -- ids
## 1907-1932 are the 26 playable China classes, 13 to a gender -- and the
## code name is the stable way to name one of them: it is the same string
## in every part and every archive, where an id is only a number and a
## display name is whatever language column the archive happens to carry.
static func parse_models_by_code(data: PackedByteArray, into: Dictionary = {}, prefix: String = "CHAR_") -> Dictionary:
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.size() <= COL_CODE_NAME:
			continue
		var model := _find_model_path(cols)
		if model == "":
			continue
		var code := cols[COL_CODE_NAME].strip_edges()
		if code == "" or not code.begins_with(prefix):
			continue
		into[code] = model
	return into

## Parses one characterdata part into {id -> display name}, merging into
## `into`.
##
## The other half of the same join `parse_models_by_name` does, from the
## other side: a row carries its id, its `SN_` key and its model, so
## resolving the key through `names` gives id -> name as readily as it gives
## name -> model. This is what lets an NPC placed from npcpos.txt (which
## carries an id and nothing else) be labelled with what the game calls it.
static func parse_names(
	data: PackedByteArray, names: UiTextTable, into: Dictionary = {}
) -> Dictionary:
	if names == null:
		return into
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.size() <= COL_MODEL_ID:
			continue
		var id_text := cols[COL_MODEL_ID].strip_edges()
		if not id_text.is_valid_int():
			continue
		var key := _find_name_key(cols)
		if key == "":
			continue
		var display := names.get_text(key)
		# get_text hands back the key when it is not in the table, and
		# "SN_NPC_CH_POTION" over an NPC's head is worse than nothing.
		if display == "" or display == key:
			continue
		into[int(id_text)] = display
	return into

## The `SN_`-prefixed name key in a characterdata row, found by content for
## the same reason the model path is.
static func _find_name_key(cols: PackedStringArray) -> String:
	for col in cols:
		var trimmed := col.strip_edges()
		if trimmed.begins_with("SN_"):
			return trimmed
	return ""

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
