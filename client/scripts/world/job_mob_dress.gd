extends RefCounted
class_name JobMobDress

## Round 805: the NPC thieves and hunters (characterdata TypeID 1/2/1/2 and
## 1/2/1/3, the caravan waves' MOB_[EU_]THIEF_NPC_* / MOB_[EU_]HUNTER_NPC_*
## rows) have no model of their own -- every row's model is `xxx` (MEASURED).
## The original draws each as a creatable character body, dressed (READ in
## sro_client.exe):
##
##   - CICMonster::vslot_025 (c:0x9d3850) reads one more byte after the class
##     byte for these two kinds and hands it to ICMonster::FUN_009d3470
##     (c:0x9d3470). The server rolls it, rand() & 0xff, when the monster is
##     made (CGObjMob::vslot_000 s:0x4c1030) -- CombatNet.MonsterSnapshot.body.
##   - The race is the row's Country (+0x9d): 0 or 3 China, 1 Europe. Every
##     thief and hunter row is 3 (MEASURED), so all of them are Chinese.
##   - The body is entry `byte % n` of the race's body list (0xeedf08+0x294
##     China, +0x2bc Europe). What fills the list is OPEN; INFERRED: the
##     race's creatable bodies, here in id order (bodies()).
##   - The outfit, icscriptobj::FUN_009e3c40 (race, sex, level, armour class,
##     weapon type, rare 0): the weapon ITEM_<race>_<WORD>_<deg>_A for the
##     weapon type of the row's DefaultSkill_1 (its ReqCast_Weapon1, the
##     skill's +0xd8; 2 when the row has no skill), the degree stepping down
##     until an item loads; a hunter's six armour pieces
##     ITEM_<race>_<M|W>_<CLOTHES|LIGHT|HEAVY>_<deg>_<piece>_A by the weapon
##     type (a thief wears none: FUN_009d3470 passes -1); a shield for weapon
##     types 2, 3, 7 and 15.
##   - Over it the job suit ITEM_<race>_<M|F>_TRADE_<THIEF|HUNTER>_<NN>: NN 02
##     or 03 by the viewer's own rand() % 2 for China; 01 / 03 / 05 / 07 by
##     the level (< 40, < 60, < 80, else) for Europe.
##   - The model's scale is the class scale x the row's Scale / 100 (asm
##     0x9d3a22..0x9d3a53).

## The characterdata columns read (MEASURED on the real parts, round 805).
const COL_CODE := 2
const COL_TYPE3 := 11
const COL_TYPE4 := 12
const COL_COUNTRY := 14
const COL_SCALE := 48
const COL_LEVEL := 57
const COL_SKILL := 83

## skilldata's id and ReqCast_Weapon1 (SkillDataReader.S_UNIQUE_ID,
## S_REQ_WEAPON_1).
const SKILL_COL_ID := 1
const SKILL_COL_WEAPON := 50

const TYPE4_THIEF := 2
const TYPE4_HUNTER := 3

## One thief or hunter row.
class Row:
	var code := ""
	var type4 := 0
	var country := 0
	var scale := 100
	var level := 1
	var skill := 0

## Whether TypeIDs 1/2/1/x are a thief's or a hunter's (the client's own test,
## c:0x9d38ed..0x9d3922).
static func is_job_type(type3: int, type4: int) -> bool:
	return type3 == 1 and (type4 == TYPE4_THIEF or type4 == TYPE4_HUNTER)

## Whether a code name can be a thief's or hunter's row (the cheap test
## before the tables are asked; the rows' own TypeIDs decide).
static func maybe_job_code(code: String) -> bool:
	return code.contains("_THIEF_NPC_") or code.contains("_HUNTER_NPC_")

## One characterdata part's thief and hunter rows into `into` (code -> Row).
## Only lines naming such a row are split: a cheap substring test first.
static func parse_rows(data: PackedByteArray, into: Dictionary = {}) -> Dictionary:
	var text := _text(data)
	if text == "":
		return into
	for needle in ["_THIEF_NPC_", "_HUNTER_NPC_"]:
		var at := text.find(needle)
		while at >= 0:
			var start := text.rfind("\n", at) + 1
			var end := text.find("\n", at)
			if end < 0:
				end = text.length()
			var cols := text.substr(start, end - start).strip_edges(false, true).split("\t")
			at = text.find(needle, end)
			if cols.size() <= COL_SKILL:
				continue
			var code := cols[COL_CODE].strip_edges()
			if code.find(needle) < 0 or into.has(code):
				continue
			var r := Row.new()
			r.code = code
			r.type4 = int(cols[COL_TYPE4])
			if not is_job_type(int(cols[COL_TYPE3]), r.type4):
				continue
			r.country = int(cols[COL_COUNTRY])
			r.scale = int(cols[COL_SCALE])
			r.level = int(cols[COL_LEVEL])
			r.skill = int(cols[COL_SKILL])
			into[code] = r
	return into

## One skilldata part's ReqCast_Weapon1 for the skill ids in `wanted` into
## `into` (id -> weapon type). The NPC skills are TSKILL_ / HSKILL_ rows.
static func parse_skill_weapons(data: PackedByteArray, wanted: Dictionary, into: Dictionary = {}) -> Dictionary:
	var text := _text(data)
	if text == "":
		return into
	for needle in ["\tTSKILL_", "\tHSKILL_"]:
		var at := text.find(needle)
		while at >= 0:
			var start := text.rfind("\n", at) + 1
			var end := text.find("\n", at)
			if end < 0:
				end = text.length()
			at = text.find(needle, end)
			var cols := text.substr(start, end - start).split("\t")
			if cols.size() <= SKILL_COL_WEAPON:
				continue
			var id := int(cols[SKILL_COL_ID])
			if wanted.has(id) and not into.has(id):
				into[id] = int(cols[SKILL_COL_WEAPON])
	return into

## Every thief and hunter row of `media`'s characterdata parts, and the
## weapon types of their skills from its skilldata parts: [rows, weapons]
## (thread-safe: plain data; World3D reads it on a worker).
static func read_tables(media: Pk2Reader) -> Array:
	var rows := {}
	for bytes in CharTables._parts(media):
		parse_rows(bytes, rows)
	var wanted := {}
	for code in rows:
		wanted[(rows[code] as Row).skill] = true
	var weapons := {}
	for path in SkillDataReader.index_tables(media):
		var e := ObjectLoader.find_file(media, path)
		if e != null:
			parse_skill_weapons(media.read_file(e), wanted, weapons)
	return [rows, weapons]

static func _text(data: PackedByteArray) -> String:
	if data.is_empty():
		return ""
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var text := TextDecode.utf16(raw)
	if text.is_empty():
		text = raw.get_string_from_utf8()
	return text

## FUN_009e2260 (READ): the item degree for a level -- 1 below 8, then a step
## at each of 8, 16, 24, 32, 42, 52, 64, 76, 90, 104, 120, 141, 164 (14).
const DEGREE_STEPS := [8, 16, 24, 32, 42, 52, 64, 76, 90, 104, 120, 141, 164]

static func degree(level: int) -> int:
	var d := 1
	for step in DEGREE_STEPS:
		if level < int(step):
			return d
		d += 1
	return d

## The race word FUN_009e3c40 / FUN_009d3470 print (Country 0 or 3 "CH", 1
## "EU"); "" for any other (the original asserts).
static func race_word(country: int) -> String:
	match country:
		0, 3:
			return "CH"
		1:
			return "EU"
	return ""

## The weapon's word by weapon type (FUN_009e3c40's switch on type - 2).
const WEAPON_WORDS := {2: "SWORD", 3: "BLADE", 4: "SPEAR", 5: "TBLADE", 6: "BOW", 7: "SWORD", 8: "TSWORD",
	9: "AXE", 10: "DARKSTAFF", 11: "TSTAFF", 12: "CROSSBOW", 13: "DAGGER", 14: "HARP", 15: "STAFF"}

## A hunter's armour class by weapon type (FUN_009d3470's switch): 1 clothes
## (2, 4, 10, 11, 14, 15), 3 heavy (3, 5..9), 2 light (12, 13), -1 none.
static func armour_class(weapon_type: int) -> int:
	match weapon_type:
		2, 4, 10, 11, 14, 15:
			return 1
		3, 5, 6, 7, 8, 9:
			return 3
		12, 13:
			return 2
	return -1

const ARMOUR_WORDS := {1: "CLOTHES", 2: "LIGHT", 3: "HEAVY"}
## The six pieces (the static strings at 0xef1c4c, from 0xd858fc..0xd858d4).
## The first becomes "HA" for good the first time rand() is odd at a
## dressing (c:0x9e42c2: "HA" assigned over the string at 0xef1c48).
const PIECES := ["CA", "SA", "BA", "LA", "AA", "FA"]

## Whether a weapon type carries a shield (FUN_009e3c40: 2, 3, 7, 15).
static func has_shield(weapon_type: int) -> bool:
	return weapon_type == 2 or weapon_type == 3 or weapon_type == 7 or weapon_type == 15

## The suit's NN (FUN_009d3470): China 02 + coin (rand() % 2); Europe by the
## level, 01 below 40, 03 below 60, 05 below 80, 07 from 80.
static func suit_number(race: String, level: int, coin: int) -> int:
	if race == "CH":
		return 2 + (coin & 1)
	if level < 40:
		return 1
	if level < 60:
		return 3
	return 7 if level >= 80 else 5

## The outfit as candidate code lists, each tried in order until one loads
## (the original's degree step-down): {"weapon": [...], "shield": [...],
## "armour": [[...] per piece], "suit": code}. `man` is the body's sex,
## `suit_coin` and `ha` the viewer's own rand() draws.
static func outfit(row: Row, weapon_type: int, man: bool, suit_coin: int, ha: bool) -> Dictionary:
	var out := {"weapon": [], "shield": [], "armour": [], "suit": ""}
	var race := race_word(row.country)
	if race == "":
		return out
	var deg := degree(row.level)
	var word := String(WEAPON_WORDS.get(weapon_type, ""))
	if word != "":
		for d in range(deg, 0, -1):
			(out["weapon"] as Array).append("ITEM_%s_%s_%02d_A" % [race, word, d])
	if row.type4 == TYPE4_HUNTER:
		var cls := armour_class(weapon_type)
		if cls > 0:
			for i in PIECES.size():
				var piece: String = "HA" if i == 0 and ha else String(PIECES[i])
				var tries: Array = []
				for d in range(deg, 0, -1):
					tries.append("ITEM_%s_%s_%s_%02d_%s_A" % [race, "M" if man else "W", ARMOUR_WORDS[cls], d, piece])
				(out["armour"] as Array).append(tries)
	if has_shield(weapon_type):
		for d in range(deg, 0, -1):
			(out["shield"] as Array).append("ITEM_%s_SHIELD_%02d_A" % [race, d])
	out["suit"] = "ITEM_%s_%s_TRADE_%s_%02d" % [race, "M" if man else "F",
		"THIEF" if row.type4 == TYPE4_THIEF else "HUNTER", suit_number(race, row.level, suit_coin)]
	return out

## The race's body list (INFERRED: its creatable bodies, in id order):
## [ref id, man] pairs from the catalogue.
static func bodies(catalog: CharCatalog, country: int) -> Array:
	var race := CharCatalog.RACE_EUROPE if country == 1 else CharCatalog.RACE_CHINA
	var ids: Array = []
	if catalog == null:
		return ids
	for id in catalog.entries:
		var e: CharCatalog.Entry = catalog.entries[id]
		if e.is_body and e.race == race:
			ids.append(int(id))
	ids.sort()
	var out: Array = []
	for id in ids:
		out.append([id, (catalog.entries[id] as CharCatalog.Entry).sex == CharCatalog.SEX_MAN])
	return out

## The body the byte picks: `byte % n` (FUN_009d3470).
static func pick_body(list: Array, body_byte: int) -> Array:
	if list.is_empty() or body_byte < 0:
		return []
	return list[body_byte % list.size()]
