extends RefCounted
class_name SkillEffectReader

## Reads skilleffect.txt (the client's own `server_dep\silkroad\textdata\`
## table) into a map from a skill's Basic_Code to the hit effect it plays -- so
## each skill can play its OWN recovered .efp rather than one hardcoded set.
## Recovered 2026-09-12 (see the skill-animations note). China focus for now.
##
## The file opens with a `#section characterInfo` block (rows keyed by a
## CHAR_/MOB_ code) and then the skill rows, each a tab-separated line whose
## col 2 is the skill's Basic_Code (no level suffix, e.g. SKILL_CH_SWORD_SMASH_A)
## and whose col 14 is the on-hit effect `hiteffect\*.efp`. Only rows whose col 2
## is a SKILL_ code are kept; a row without a real .efp there is skipped.

const TABLE := "server_dep\\silkroad\\textdata\\skilleffect.txt"

const E_CODE := 2
const E_HIT_EFP := 14

## Parses the table into Basic_Code (upper-cased) -> hit `.efp` path.
static func parse(data: PackedByteArray) -> Dictionary:
	return parse_all(data)["hit"]

## Both readings of the table in ONE pass over one decode (the 616-618
## integration review: the 4.5 MB file was decoded twice, on the first cast):
## {"hit": parse's map, "aniset": parse_aniset's}. Pure data -- World3D runs
## it on a WorkerThreadPool task at world entry.
static func parse_all(data: PackedByteArray) -> Dictionary:
	var _pp := ParseProfile.t0()
	var hit: Dictionary = {}
	var sets: Dictionary = {}
	if _parse_all_native(data, hit, sets):
		ParseProfile.add("text.skill_effects", _pp)
		return {"hit": hit, "aniset": sets}
	var section := ""
	for line in _lines(data):
		if line.begins_with("#section"):
			var parts := line.split("\t", false)
			section = parts[1].strip_edges() if parts.size() > 1 else ""
			continue
		if not line.contains("SKILL_") and not line.contains("SYSTEM_"):
			continue
		var cols := line.split("\t")
		_hit_row(cols, hit)
		if section in ANIM_SECTIONS and not line.strip_edges().begins_with("//"):
			_aniset_row(cols, section, sets)
	ParseProfile.add("text.skill_effects", _pp)
	return {"hit": hit, "aniset": sets}

## parse_all's loop with its row work done by the native port (round 671;
## native/src/core/tables.rs `skill_effects`): the hit rows and the aniset rows
## come back in file order, and the case folding, the ANI_TYPES lookups and the
## merge of a repeated SkillID run here exactly as in _hit_row/_aniset_row.
## False when there is no library or the port handed the table back.
static func _parse_all_native(data: PackedByteArray, hit: Dictionary, sets: Dictionary) -> bool:
	var rows := NativeAssets.table_rows("skill_effects", [data])
	if rows.is_empty():
		return false
	var hit_codes: PackedStringArray = rows["hit_codes"]
	var hit_efps: PackedStringArray = rows["hit_efps"]
	for i in hit_codes.size():
		hit[hit_codes[i].to_upper()] = hit_efps[i]
	var codes: PackedStringArray = rows["set_codes"]
	var groups: PackedStringArray = rows["set_groups"]
	var priorities: PackedInt64Array = rows["set_priorities"]
	var defenses: PackedStringArray = rows["set_defenses"]
	var names: PackedStringArray = rows["set_names"]
	var counts: PackedInt64Array = rows["set_name_counts"]
	var n := 0
	for i in codes.size():
		var code := codes[i].to_upper()
		var lists := [[], [], []]
		for k in range(3):
			for j in range(n, n + counts[i * 3 + k]):
				var ani := names[j].to_upper()
				if ANI_TYPES.has(ani):
					lists[k].append(int(ANI_TYPES[ani]))
			n += counts[i * 3 + k]
		if not code.begins_with("SKILL_") and not code.begins_with("SYSTEM_"):
			continue
		var row: Dictionary = sets.get(code, {"group": "", "ready": [], "wait": [], "shot": []})
		row["group"] = groups[i].to_lower()
		row["priority"] = priorities[i]
		if defenses[i] != "":
			row["defense"] = defenses[i]
		(row["ready"] as Array).append_array(lists[0])
		(row["wait"] as Array).append_array(lists[1])
		(row["shot"] as Array).append_array(lists[2])
		sets[code] = row
	return true

static func _hit_row(cols: PackedStringArray, out: Dictionary) -> void:
	if cols.size() <= E_CODE:
		return
	var code := cols[E_CODE].strip_edges()
	if not code.begins_with("SKILL_"):
		return
	var efp := ""
	if cols.size() > E_HIT_EFP:
		efp = cols[E_HIT_EFP].strip_edges()
	# Guard the fixed column: if it isn't a .efp, scan the row for one.
	if not efp.to_lower().ends_with(".efp"):
		efp = ""
		for c in cols:
			var cl := c.strip_edges()
			if cl.to_lower().ends_with(".efp"):
				efp = cl
				break
	if efp != "" and efp.to_lower() != "none":
		out[code.to_upper()] = efp

## The hit `.efp` for a Basic_Code, tolerating the level suffix (the table keys
## without it, e.g. SKILL_CH_SWORD_SMASH_A for ..._SMASH_A_01). "" if unknown.
static func hit_efp_for(effects: Dictionary, basic_code: String) -> String:
	var code := basic_code.to_upper()
	if effects.has(code):
		return effects[code]
	var us := code.rfind("_")
	if us > 0 and code.substr(us + 1).is_valid_int():
		code = code.substr(0, us)
	return effects.get(code, "")

# --- skillaniset2: what a skill's body plays (round 616-618 integration) ---
#
# READ (sro_client.exe). The loader FUN_00a9eb60 routes `#section skillaniset`
# and `#section skillaniset2` rows to FUN_00a9c470, keyed by the SkillID
# column (col 2, the Basic_Code without its level). After Priority (col 3),
# AniTRUE (4), Hide Weapon (5) and AniGroup (6) it reads SIX lists (cols 7..12:
# AniReady, AniWait, AniShot, Ani play Timing, Act W, Act S), each up to nine
# comma-separated names, every name looked up in the ANI_ name map
# (FUN_00a94f50; a name the map lacks -- "none" -- is not stored). The record
# keeps the counts at +8/+9/+10 and the lists at +0xe/+0x20/+0x32.
#
# The skill's deco start FUN_00a54f00 reads the three: READY (+0xe) and SHOT
# (+0x32) are kept for later phases, WAIT (+0x20) is played on the body at once
# as vslot 0xb4(group, type, 200), where the group is the ROW's AniGroup
# (record +4, interned by FUN_00a9a6f0, copied to the deco's +0x130 by FUN_00a54f00),
# not the held weapon's -- and when all three are EMPTY (and the id is not a
# system one, bit 31 clear) it ends the deco (vslot 8, 1) and returns: the body
# plays NOTHING. That is Grass Walk (SKILL_CH_LIGHTNING_GYEONGGONG_A) and the
# lightning imbue (..._GIGONGTA_*): every list "none".
#
# ANI_TYPES is the ANI_ name map's registrations in FUN_009e5240, READ: the
# name -> the body .bsr's animation action type. From ANI_SKILL_1 on each is
# `local_1058 = <type>` then the name; the 26 before it (ANI_POSE ..
# ANI_REVOLUTION) are the name then `local_100c`/`local_102c = <type>`. The
# early ones agree with the action types BsrReader already reads off real
# bodies (STAND1 0, WALK 1, ATTACK1 2, ATTREADY 6, RUN 7, SIT_DOWN 13, SIT 14,
# STAND_UP 15, WALK_BACK 23). Names the map lacks -- ANI_SHOT (47 list cells)
# and DOWN_UP (2), MEASURED over the box's 1,044 skillaniset2 skill rows --
# resolve to nothing, as the loader's -1 does.

const ANIM_SECTIONS := ["skillaniset", "skillaniset2"]
## Priority (col 3) and DefenseEfp (col 13), round 640. The retail client
## plays, on a body hit while any skill deco is attached to it, the
## highest-Priority attached deco's efp at anim-set +0x80 in place of the
## attacker's hit effect (IDecoSkill::FUN_009cd480 from FUN_00a4f720, READ).
## +0x80 IS this column (READ in the review: the aniset loader FUN_00a9c470
## files column 13, whose header the table names "DefenseEfp", at +0x80, and
## column 14, DamageEfp, at +0x84). The walls' rows name one
## (SKILL_CH_FIRE_HWABYEOK_A: skill\china\fire_ganggi_damage_a.efp,
## SKILL_CH_COLD_BINGBYEOK_A: hiteffect\hit_2_ice.efp -- MEASURED).
const A_PRIORITY := 3
const A_DEFENSE_EFP := 13
const A_GROUP := 6
const A_READY := 7
const A_WAIT := 8
const A_SHOT := 9

const ANI_TYPES := {
	"ANI_POSE": 60, "ANI_STAND1": 0, "ANI_STAND2": 122, "ANI_STAND3": 61, "ANI_STAND4": 81,
	"ANI_ATTREADY": 6, "ANI_TURN_L": 24, "ANI_TURN_R": 25, "ANI_SIT_DOWN": 13, "ANI_SIT": 14,
	"ANI_STAND_UP": 15, "ANI_DEFENCE": 22, "ANI_WALK": 1, "ANI_WALK_BACK": 23, "ANI_RUN": 7,
	"ANI_ATTACK1": 2, "ANI_ATTACK2": 5, "ANI_ATTACK3": 16, "ANI_ATTACK4": 17, "ANI_ATTACK5": 183,
	"ANI_ATTACK6": 184, "ANI_ATTACK7": 185, "ANI_ATTACK8": 186, "ANI_ATTACK9": 190,
	"ANI_REVOLUTION": 39,
	"ANI_SKILL_1": 26, "ANI_SKILL_2": 27, "ANI_SKILL_3": 28, "ANI_SKILL_4": 29, "ANI_SKILL_5": 30,
	"ANI_SKILL_6": 31, "ANI_SKILL_7": 32, "ANI_SKILL_8": 33, "ANI_SKILL_9": 34, "ANI_SKILL_10": 35,
	"ANI_SKILL_11": 68, "ANI_SKILL_12": 69, "ANI_SKILL_13": 70, "ANI_SKILL_14": 71,
	"ANI_SKILL_15": 72, "ANI_SKILL_16": 73, "ANI_SKILL_17": 74, "ANI_SKILL_18": 75,
	"ANI_SKILL_19": 76, "ANI_SKILL_20": 77, "ANI_SKILL_21": 101, "ANI_SKILL_22": 102,
	"ANI_SKILL_23": 103, "ANI_SKILL_24": 104, "ANI_SKILL_25": 105, "ANI_SKILL_26": 106,
	"ANI_SKILL_27": 107, "ANI_SKILL_28": 108, "ANI_SKILL_29": 109, "ANI_SKILL_30": 110,
	"ANI_SKILL_31": 111, "ANI_SKILL_32": 112, "ANI_SKILL_33": 113, "ANI_SKILL_34": 114,
	"ANI_SKILL_35": 115, "ANI_SKILL_36": 116, "ANI_SKILL_37": 117, "ANI_SKILL_38": 118,
	"ANI_SKILL_39": 119, "ANI_SKILL_40": 120, "ANI_SKILL_41": 123, "ANI_SKILL_42": 124,
	"ANI_SKILL_43": 125, "ANI_SKILL_44": 126, "ANI_SKILL_45": 127, "ANI_SKILL_46": 128,
	"ANI_SKILL_47": 129, "ANI_SKILL_48": 130, "ANI_SKILL_49": 131, "ANI_SKILL_50": 132,
	"ANI_SKILL_51": 133, "ANI_SKILL_52": 134, "ANI_SKILL_53": 135, "ANI_SKILL_54": 136,
	"ANI_SKILL_55": 137, "ANI_SKILL_56": 138, "ANI_SKILL_57": 139, "ANI_SKILL_58": 140,
	"ANI_SKILL_59": 141, "ANI_SKILL_60": 142, "ANI_SKILL_61": 143, "ANI_SKILL_62": 144,
	"ANI_SKILL_63": 145, "ANI_SKILL_64": 146, "ANI_SKILL_65": 147, "ANI_SKILL_66": 148,
	"ANI_SKILL_67": 149, "ANI_SKILL_68": 150, "ANI_SKILL_69": 151, "ANI_SKILL_70": 152,
	"ANI_SKILL_71": 153, "ANI_SKILL_72": 154, "ANI_SKILL_73": 155, "ANI_SKILL_74": 156,
	"ANI_SKILL_75": 157, "ANI_SKILL_76": 158, "ANI_SKILL_77": 159, "ANI_SKILL_78": 160,
	"ANI_SKILL_79": 161, "ANI_SKILL_80": 162, "ANI_SKILL_81": 163, "ANI_SKILL_82": 164,
	"ANI_SKILL_83": 165, "ANI_SKILL_84": 166, "ANI_SKILL_85": 167, "ANI_SKILL_86": 168,
	"ANI_SKILL_87": 169, "ANI_SKILL_88": 170, "ANI_SKILL_89": 171, "ANI_SKILL_90": 172,
	"ANI_SKILL_91": 173, "ANI_SKILL_92": 174, "ANI_SKILL_93": 175, "ANI_SKILL_94": 176,
	"ANI_SKILL_95": 177, "ANI_SKILL_96": 178, "ANI_SKILL_97": 179, "ANI_SKILL_98": 180,
	"ANI_SKILL_99": 181, "ANI_SKILL_100": 182, "ANI_READY01": 40, "ANI_READY02": 41,
	"ANI_READY03": 42, "ANI_READY04": 43, "ANI_READY05": 44, "ANI_WAIT01": 91, "ANI_WAIT02": 92,
	"ANI_WAIT03": 93, "ANI_WAIT04": 94, "ANI_WAIT05": 95, "ANI_HAMMER": 187, "ANI_HANDLOOF": 188,
	"ANI_TROW": 189, "ANI_MG_SSELF": 19, "ANI_MG_SOTHER": 20, "ANI_DAMAGE1": 3, "ANI_DAMAGE2": 9,
	"ANI_HELP": 67, "ANI_FIND": 78, "ANI_STUN": 79, "ANI_DIE1": 4, "ANI_DIE1_RM": 36, "ANI_DIE2": 18,
	"ANI_DIE2_RM": 37, "ANI_REVIVAL": 121, "ANI_DOWN": 62, "ANI_DOWN_RM": 63, "ANI_DOWN_DAMAGE": 64,
	"ANI_DOWN_UP": 65, "ANI_DOWN_DIE": 66, "ANI_PICK": 38, "ANI_CLICK": 10, "ANI_CB_YEONHWAN": 11,
	"ANI_CB_2": 12, "ANI_ET_BYE": 21, "ANI_EMOTION01": 50, "ANI_EMOTION02": 51, "ANI_EMOTION03": 52,
	"ANI_EMOTION04": 53, "ANI_EMOTION05": 54, "ANI_EMOTION06": 55, "ANI_EMOTION07": 56,
	"ANI_EMOTION08": 57, "ANI_EMOTION09": 58, "ANI_EMOTION10": 59, "ANI_VENDOR01": 80
}

## The skillaniset rows: Basic_Code (upper-cased, no level) -> {"group": the
## AniGroup column lower-cased, "ready", "wait", "shot": Array of action
## types}. Rows in other sections are ignored.
static func parse_aniset(data: PackedByteArray) -> Dictionary:
	return parse_all(data)["aniset"]

## One aniset row into `sets`, as FUN_00a9c470 files it (READ):
## - in `skillaniset2` the loader's flag (+0x10 of the manager, set to 1 for
##   that section and 0 for `skillaniset` by FUN_00a9eb60) makes it read a
##   leading int first, and a 0 there skips the row (FUN_00a997e0); a plain
##   `skillaniset` row has no such column, so its fields sit one column left;
## - a SkillID seen before is the SAME record: the scalars (AniGroup here)
##   are overwritten and each list's names are APPENDED after the ones it
##   already holds (the per-list count is not reset).
static func _aniset_row(cols: PackedStringArray, section: String, sets: Dictionary) -> void:
	var shift := 0 if section == "skillaniset2" else -1
	if cols.size() <= A_SHOT + shift:
		return
	if shift == 0:
		var service := cols[0].strip_edges()
		if not service.is_valid_int() or int(service) == 0:
			return
	var code := cols[E_CODE + shift].strip_edges().to_upper()
	if not code.begins_with("SKILL_") and not code.begins_with("SYSTEM_"):
		return
	var row: Dictionary = sets.get(code, {"group": "", "ready": [], "wait": [], "shot": []})
	row["group"] = cols[A_GROUP + shift].strip_edges().to_lower()
	var prio := cols[A_PRIORITY + shift].strip_edges()
	row["priority"] = int(prio) if prio.is_valid_int() else 0
	if cols.size() > A_DEFENSE_EFP + shift:
		var defense := cols[A_DEFENSE_EFP + shift].strip_edges()
		if defense.to_lower().ends_with(".efp"):
			row["defense"] = defense
	(row["ready"] as Array).append_array(_ani_list(cols[A_READY + shift]))
	(row["wait"] as Array).append_array(_ani_list(cols[A_WAIT + shift]))
	(row["shot"] as Array).append_array(_ani_list(cols[A_SHOT + shift]))
	sets[code] = row

## One list column: its comma-separated names, each through ANI_TYPES; a name
## the map lacks ("none") is dropped, as the loader drops a -1.
static func _ani_list(cell: String) -> Array:
	var types: Array = []
	for name in cell.split(",", false):
		var n := name.strip_edges().to_upper()
		if ANI_TYPES.has(n):
			types.append(int(ANI_TYPES[n]))
	return types

## A skill's aniset row by Basic_Code, tolerating the level suffix; {} when the
## table has none.
static func aniset_for(sets: Dictionary, basic_code: String) -> Dictionary:
	var code := basic_code.to_upper()
	if sets.has(code):
		return sets[code]
	var us := code.rfind("_")
	if us > 0 and code.substr(us + 1).is_valid_int():
		code = code.substr(0, us)
	return sets.get(code, {})

## The DefenseEfp a body holding buffs of `basic_codes` shows when it is hit
## (round 640): the one of the highest Priority among the rows that name one,
## the earliest listed on a tie (retail's pick keeps the first it meets at the
## highest byte, `>`, FUN_009cd480 -- the order it meets its decos in is not
## read, OPEN). "" when none names one.
static func defense_efp_for(sets: Dictionary, basic_codes: Array) -> String:
	var best := ""
	var best_prio := -1
	for code in basic_codes:
		var row := aniset_for(sets, String(code))
		if not row.has("defense"):
			continue
		var p := int(row.get("priority", 0))
		if p > best_prio:
			best_prio = p
			best = String(row["defense"])
	return best

## What the body plays when the skill's deco starts, from its aniset row
## (FUN_00a54f00, READ): {"kind": "none"} when READY, WAIT and SHOT are all
## empty (retail plays nothing); {"kind": "wait", "type": t, "group": g} when
## WAIT names one (played at once in the row's AniGroup g; the entry among
## several is picked by a per-deco byte, OPEN -- the first is taken); {"kind": "unread"} when only READY or SHOT
## name one (their timing was not read) or there is no row.
static func cast_body_anim(row: Dictionary) -> Dictionary:
	if row.is_empty():
		return {"kind": "unread"}
	var ready: Array = row.get("ready", [])
	var wait: Array = row.get("wait", [])
	var shot: Array = row.get("shot", [])
	if ready.is_empty() and wait.is_empty() and shot.is_empty():
		return {"kind": "none"}
	if not wait.is_empty():
		return {"kind": "wait", "type": int(wait[0]), "group": String(row.get("group", ""))}
	return {"kind": "unread"}

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
