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

## The characterdata parts the world read until round 746: the index file
## itself and _5000 .. _30000, 7 of the 63 parts the index names. Now only the
## fallback for an archive with no index; model_table_paths (CharTables) reads
## the index, as the client does.
static var LEGACY_MODEL_TABLE_PATHS := [
	"server_dep\\silkroad\\textdata\\characterdata.txt",
	"server_dep\\silkroad\\textdata\\characterdata_5000.txt",
	"server_dep\\silkroad\\textdata\\characterdata_10000.txt",
	"server_dep\\silkroad\\textdata\\characterdata_15000.txt",
	"server_dep\\silkroad\\textdata\\characterdata_20000.txt",
	"server_dep\\silkroad\\textdata\\characterdata_25000.txt",
	"server_dep\\silkroad\\textdata\\characterdata_30000.txt",
]
## Every characterdata part `media` holds, in its index's order (round 746,
## CharTables.table_paths).
static func model_table_paths(media: Pk2Reader) -> PackedStringArray:
	return CharTables.table_paths(media)

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
## A character's walk and run speeds, in WORLD UNITS PER SECOND -- read from
## the server (round 231): its common-record deserializer stores text columns
## 46 and 47 as the words at record +0xe4/+0xe6 (RefObjCommon_ExtractData,
## fields 47/48), CGObjMobile::vslot_215 loads them into the walk/run slots
## (+0x16c/+0x170), GObjPC::FUN_0048b810 picks one into the live speed (+0x174)
## by move mode, and CGObjMoverByDest::FUN_0048bff0 advances the position by
## dir * |speed * dt| with dt the main loop's seconds delta (capped at 160 per
## step). GObjPC_InitStats publishes them as params 23 and 24. Every playable
## row in the table reads 16 / 50.
const COL_SPEED_WALK := 46
const COL_SPEED_RUN := 47
## A character's collision radius, BCRadius, in world units: the common
## record's word at +0xee, which the server's IGObj slot 344 returns and its
## attack tick adds to the attacker's to make the base of the reach band
## (CGCharAutoCommandActor::Tick_Attack 0x004ad8e0 phase 0; round 247 in
## docs/WORLD_ISSUES.md re-read the parser to put +0xee at column 50).
## Retail rows read: every playable body 4, Mangyang 6, Gyo 10, Yeoha 11 --
## the values server/cmd/server's roster carries (monsterSpec.BCRadius).
const COL_BC_RADIUS := 50
## DecayTime, milliseconds: field 14 of the common record, text column 13
## (round 227, docs/protocol/refobj_binary_format.md; the server keeps it in
## seconds at ref+0x84). An item's is how long it lies on the ground; a
## monster's is how long its corpse lies: `CGObj::Update` (0x484d10) removes
## a character in life state 2 once its dead time reaches it (round 677).
## Retail rows read (the box's characterdata parts, round 677): 5000 for
## most monsters (MOB_CH_MANGNYANG), 10000 for others (MOB_CH_TIGERWOMAN),
## 1000000000 for the player bodies.
const COL_DECAY_TIME := 13

class Spawn:
	var npc_id: int
	var region_x: int
	var region_y: int
	## Region-local position, the same space terrain and navmesh use.
	var local_position: Vector3

## Parses npcpos.txt. Rows that don't have five numeric columns are skipped
## rather than failing the file -- these tables carry comment lines.
static func parse_positions(data: PackedByteArray) -> Array[Spawn]:
	var _pp := ParseProfile.t0()
	var _out: Array[Spawn] = _pp_parse_positions(data)
	ParseProfile.add("text.npc_positions", _pp)
	return _out

## The body of parse_positions, timed by its wrapper above (ParseProfile, round 667).
static func _pp_parse_positions(data: PackedByteArray) -> Array[Spawn]:
	var out: Array[Spawn] = []
	# The native port of the loop below (round 671, native/src/core/tables.rs):
	# the same rows, the same int()/float() values, in file order.
	var rows := NativeAssets.table_rows("npc_positions", [data])
	if not rows.is_empty():
		var ids: PackedInt64Array = rows["npc_ids"]
		var regions: PackedInt64Array = rows["regions"]
		var xs: PackedFloat64Array = rows["x"]
		var ys: PackedFloat64Array = rows["y"]
		var zs: PackedFloat64Array = rows["z"]
		for i in ids.size():
			var region: int = regions[i]
			var spawn := Spawn.new()
			spawn.npc_id = ids[i]
			spawn.region_x = (region >> 8) & 0xFF
			spawn.region_y = region & 0xFF
			spawn.local_position = Vector3(xs[i], ys[i], zs[i])
			out.append(spawn)
		return out
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
	var _pp := ParseProfile.t0()
	var _out: Dictionary = _pp_parse_codes(data, into)
	ParseProfile.add("text.npc_codes", _pp)
	return _out

## The body of parse_codes, timed by its wrapper above (ParseProfile, round 667).
static func _pp_parse_codes(data: PackedByteArray, into: Dictionary = {}) -> Dictionary:
	if _merge_native(into, "char_codes", [data]):
		return into
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
	var _pp := ParseProfile.t0()
	var _out: Dictionary = _pp_parse_models(data, into)
	ParseProfile.add("text.npc_models", _pp)
	return _out

## The body of parse_models, timed by its wrapper above (ParseProfile, round 667).
static func _pp_parse_models(data: PackedByteArray, into: Dictionary = {}) -> Dictionary:
	if _merge_native(into, "char_models", [data]):
		return into
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
	var _pp := ParseProfile.t0()
	if names == null:
		ParseProfile.add("text.models_by_name", _pp)
		return into
	# Native: each row's (model, SN_ key); the lookup and the lower-casing
	# stay here (Godot's to_lower is the key's definition).
	var rows := NativeAssets.table_rows("char_models_name_keys", [data])
	if not rows.is_empty():
		var models: PackedStringArray = rows["keys"]
		var keys: PackedStringArray = rows["values"]
		for i in models.size():
			var display := names.get_text(keys[i])
			if display == "" or display == keys[i]:
				continue
			into[display.to_lower()] = models[i]
		ParseProfile.add("text.models_by_name", _pp)
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
	ParseProfile.add("text.models_by_name", _pp)
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
	var _pp := ParseProfile.t0()
	if _merge_native(into, "char_models_by_code", [data, prefix]):
		ParseProfile.add("text.models_by_code", _pp)
		return into
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
	ParseProfile.add("text.models_by_code", _pp)
	return into

## OrgObjCodeName, the row a `_CLON` (and 34 other rows) takes its model from
## when its own is `xxx` (round 655; see parse_org_codes).
const COL_ORG_CODE_NAME := 4

## Parses one characterdata part into {code name -> OrgObjCodeName} for rows
## whose column 4 names another row, merging into `into`. `xxx` and "" name
## none: the client's text reader stores `xxx` as an empty string (READ,
## FUN_0097f860 / FUN_0097f920: lstrcmp against "xxx", then assign "").
##
## What the client does with it (READ, round 655, docs/protocol/
## characterdata.md "The model of a row with none"): when a character is
## created, its model is its own row's first col-52 file (+0x124) unless that
## is empty, and then the Org row's (`if (*(rec+0x138) == 0 && org != 0) path
## = org + 0x124`, CICMonster::vslot_025 0x9d3850 and three twins). One
## level: the Org row's own Org is never consulted.
static func parse_org_codes(data: PackedByteArray, into: Dictionary = {}) -> Dictionary:
	var _pp := ParseProfile.t0()
	if _merge_native(into, "char_org_codes", [data]):
		ParseProfile.add("text.org_codes", _pp)
		return into
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.size() <= COL_ORG_CODE_NAME:
			continue
		var code := cols[COL_CODE_NAME].strip_edges()
		var org := cols[COL_ORG_CODE_NAME].strip_edges()
		if code == "" or org == "" or org.to_lower() == "xxx":
			continue
		into[code] = org
	ParseProfile.add("text.org_codes", _pp)
	return into

## The model a row is drawn with: its own when it has one, else its Org row's
## (one level; READ, parse_org_codes). "" when neither has one -- the client
## would then load `res\mob\china\mangnyang.bsr` (FUN_009c4ec0, 0xde1f90),
## but in the real table every row that reaches this path with a code whose
## Org has no model is a thief, hunter or guild soldier, which the client
## draws through its own model list instead (ICMonster::FUN_009d3470), so the
## fallback is not taken here.
static func model_with_org(code: String, models_by_code: Dictionary, org_by_code: Dictionary) -> String:
	var own: String = models_by_code.get(code, "")
	if own != "":
		return own
	var org: String = org_by_code.get(code, "")
	if org == "":
		return ""
	return models_by_code.get(org, "")

## Parses one characterdata part into {code name -> [walk, run]} (world units
## per second, COL_SPEED_WALK/COL_SPEED_RUN) for rows whose code starts with
## `prefix`, merging into `into`. A row missing either column is skipped.
static func parse_speeds_by_code(data: PackedByteArray, into: Dictionary = {}, prefix: String = "CHAR_") -> Dictionary:
	var _pp := ParseProfile.t0()
	var rows := NativeAssets.table_rows("char_speeds_by_code", [data, prefix])
	if not rows.is_empty():
		var codes: PackedStringArray = rows["keys"]
		var walks: PackedFloat64Array = rows["walk"]
		var runs: PackedFloat64Array = rows["run"]
		for i in codes.size():
			into[codes[i]] = [walks[i], runs[i]]
		ParseProfile.add("text.speeds_by_code", _pp)
		return into
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.size() <= COL_SPEED_RUN:
			continue
		var code := cols[COL_CODE_NAME].strip_edges()
		if code == "" or not code.begins_with(prefix):
			continue
		var walk := cols[COL_SPEED_WALK].strip_edges()
		var run := cols[COL_SPEED_RUN].strip_edges()
		if not walk.is_valid_float() or not run.is_valid_float():
			continue
		into[code] = [float(walk), float(run)]
	ParseProfile.add("text.speeds_by_code", _pp)
	return into

## _RefObjCommon.Country: 0 for the China race, 1 for Europe (characterdata
## and itemdata share the common head; ItemTableReader.COL_COUNTRY is the
## same column). MEASURED on the real parts (round 629): the 26 CHAR_CH_*
## rows read 0, the 26 CHAR_EU_* rows 1.
const COL_COUNTRY := 14

## Parses one characterdata part into {code name -> Country} for rows whose
## code starts with `prefix`, merging into `into`. A row whose column is not a
## number is skipped rather than read as China.
static func parse_country_by_code(data: PackedByteArray, into: Dictionary = {}, prefix: String = "CHAR_") -> Dictionary:
	var _pp := ParseProfile.t0()
	if _merge_native(into, "char_country_by_code", [data, prefix]):
		ParseProfile.add("text.country_by_code", _pp)
		return into
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.size() <= COL_COUNTRY:
			continue
		var code := cols[COL_CODE_NAME].strip_edges()
		if code == "" or not code.begins_with(prefix):
			continue
		var country := cols[COL_COUNTRY].strip_edges()
		if not country.is_valid_int():
			continue
		into[code] = int(country)
	ParseProfile.add("text.country_by_code", _pp)
	return into

## Parses one characterdata part into {code name -> DecayTime (ms,
## COL_DECAY_TIME)} for rows whose code starts with `prefix` (the monsters,
## by default), merging into `into` -- how long a dead monster's corpse lies
## (World3D._monster_corpse_seconds, round 677). A row too short to have the
## column, or whose column is not a number, is skipped. The fallback reads
## the two columns it needs with get_slice rather than splitting the whole
## ~100-column row.
static func parse_decay_by_code(data: PackedByteArray, into: Dictionary = {}, prefix: String = "MOB_") -> Dictionary:
	var _pp := ParseProfile.t0()
	if _merge_native(into, "char_decay_by_code", [data, prefix]):
		ParseProfile.add("text.decay_by_code", _pp)
		return into
	for line in _lines(data):
		if line.get_slice_count("\t") <= COL_DECAY_TIME:
			continue
		var code := line.get_slice("\t", COL_CODE_NAME).strip_edges()
		if code == "" or not code.begins_with(prefix):
			continue
		var decay := line.get_slice("\t", COL_DECAY_TIME).strip_edges()
		if not decay.is_valid_int():
			continue
		into[code] = int(decay)
	ParseProfile.add("text.decay_by_code", _pp)
	return into

## Parses one characterdata part into {code name -> BCRadius} (world units,
## COL_BC_RADIUS) for rows whose code starts with `prefix`, merging into
## `into`. "" takes every row -- the player bodies (CHAR_) and the monsters
## (MOB_) both feed the reach band. A row too short to have the column, or
## whose column is not a number, is skipped rather than read as 0.
##
## Keyed by code name, which is what MonsterSnapshot carries. Measured in round
## 519 on the render box's extracted copies of the six data files among
## LEGACY_MODEL_TABLE_PATHS (the seventh, characterdata.txt, lists part-file names
## -- CharacterData_1000.txt, ... -- not rows): 13,291 rows with a numeric
## column 50 and 13,291 distinct code names, so no row shadows another (a live
## client read the same 13,291 keys out of Media.pk2). The row
## docs/protocol/monster_ai.md ("The roster's real walk and run speeds
## (round 362)") first called a "second MOB_CH_MANGNYANG" is
## MOB_CH_STRONG_MANGNYANG (id 9383), a different code; that paragraph was
## corrected in round 523 and now names it, and says an exact code-name key
## is safe.
static func parse_bc_radius_by_code(data: PackedByteArray, into: Dictionary = {}, prefix: String = "") -> Dictionary:
	var _pp := ParseProfile.t0()
	if _merge_native(into, "char_bc_radius_by_code", [data, prefix]):
		ParseProfile.add("text.bc_radius_by_code", _pp)
		return into
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.size() <= COL_BC_RADIUS:
			continue
		var code := cols[COL_CODE_NAME].strip_edges()
		if code == "" or not code.begins_with(prefix):
			continue
		var radius := cols[COL_BC_RADIUS].strip_edges()
		if not radius.is_valid_int():
			continue
		into[code] = int(radius)
	ParseProfile.add("text.bc_radius_by_code", _pp)
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
	var _pp := ParseProfile.t0()
	if names == null:
		ParseProfile.add("text.npc_names", _pp)
		return into
	# Native: each row's (id, SN_ key); the lookup stays here.
	var rows := NativeAssets.table_rows("char_name_keys", [data])
	if not rows.is_empty():
		var ids: PackedInt64Array = rows["ids"]
		var keys: PackedStringArray = rows["values"]
		for i in ids.size():
			var display := names.get_text(keys[i])
			if display == "" or display == keys[i]:
				continue
			into[ids[i]] = display
		ParseProfile.add("text.npc_names", _pp)
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
	ParseProfile.add("text.npc_names", _pp)
	return into

## Parses one characterdata part into {id -> `SN_` name key}, merging into
## `into` -- the index the unique notices look a RefObjID up in (round 657:
## World3D builds it once, on a WorkerThreadPool task, at load).
static func parse_name_keys(data: PackedByteArray, into: Dictionary = {}) -> Dictionary:
	var _pp := ParseProfile.t0()
	if _merge_native(into, "char_name_keys", [data]):
		ParseProfile.add("text.name_keys", _pp)
		return into
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.size() <= COL_MODEL_ID:
			continue
		var id_text := cols[COL_MODEL_ID].strip_edges()
		if not id_text.is_valid_int():
			continue
		var key := _find_name_key(cols)
		if key != "":
			into[int(id_text)] = key
	ParseProfile.add("text.name_keys", _pp)
	return into

## The `SN_` name key of the characterdata row whose id is `id` in one part,
## or "" -- the key the object's name and the unique notices' choice go by
## (round 657, UniqueNoticeNet.line_for). Scans only as far as the row.
static func find_name_key(data: PackedByteArray, id: int) -> String:
	var want := str(id)
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.size() <= COL_MODEL_ID or cols[COL_MODEL_ID].strip_edges() != want:
			continue
		return _find_name_key(cols)
	return ""

## Merges the native port's rows for `method` (round 671; native/src/core/
## tables.rs: the GDScript loop's kept rows, in file order, as `ids` or `keys`
## beside `values`) into `into` in that order -- so a later duplicate id or
## code overwrites an earlier one, as the loop's own `into[k] = v` does. False
## when there is no library or the port handed the table back; the caller then
## runs its GDScript loop.
static func _merge_native(into: Dictionary, method: String, args: Array) -> bool:
	var rows := NativeAssets.table_rows(method, args)
	if rows.is_empty():
		return false
	var values = rows["values"]
	var keys = rows["ids"] if rows.has("ids") else rows["keys"]
	for i in keys.size():
		into[keys[i]] = values[i]
	return true

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
			# Several files in the one column (`MOB_SD_HAROERIS`, `MOB_SD_SETH`):
			# the client splits it on "," and keeps the first as the model
			# (READ, round 655: RefObjCommon parser FUN_00972910, asm 0x972f1d
			# copies piece 0 to +0x124).
			return trimmed.split(",")[0].strip_edges()
	return ""

static func _lines(data: PackedByteArray) -> PackedStringArray:
	if data.is_empty():
		return PackedStringArray()
	var _pp := ParseProfile.t0()
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var text := TextDecode.utf16(raw)
	if text.is_empty():
		text = raw.get_string_from_utf8()
	var _out := text.replace("\r", "").split("\n")
	ParseProfile.add("text.decode_split", _pp, data.size())
	return _out
