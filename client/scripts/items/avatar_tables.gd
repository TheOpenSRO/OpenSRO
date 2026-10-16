extends RefCounted
class_name AvatarTables

## The textdata tables avatars read beside itemdata and magicoption (round
## 789, lane AC), from the player's own Media.pk2 at runtime:
##
## - `magicoptionassign.txt` -- Service, Race, TypeID3, TypeID4, then the
##   MATTR_ names an item of that kind may be granted, up to "xxx" (MEASURED,
##   AVATAR_ALCHEMY_RESEARCH.md 5). The client fills an item's grantable list
##   from the (TypeID3, TypeID4) row (READ c:0x8be3a0 -> FUN_00926cd0; the race
##   is not looked at, INFERRED: every avatar row is race 3, MEASURED).
## - `refabilitybyitemoptleveldata.txt` -- Service, AbilityID, RefItemID,
##   OptLevel: a devil's spirit's ability at a plus (MEASURED 266 rows).
## - `refmagicoptbyitemoptleveldata.txt` -- AbilityID, magicoption id, value,
##   group, text key ('xxx' for none): the ability's option lines (MEASURED
##   505 rows, groups 0 and 1, every text 'xxx').
##
## The ability of (RefItemID, plus) falls back to the highest lower plus that
## has one (READ FUN_008bf680, the skill strip's and the tooltip's lookup).

const ASSIGN_PATH := "server_dep\\silkroad\\textdata\\magicoptionassign.txt"
const ABILITY_PATH := "server_dep\\silkroad\\textdata\\refabilitybyitemoptleveldata.txt"
const ABILITY_OPT_PATH := "server_dep\\silkroad\\textdata\\refmagicoptbyitemoptleveldata.txt"

## "t3/t4" -> PackedStringArray of MATTR names (the first Service-1 row).
var assign := {}
## RefItemID -> {OptLevel: AbilityID}.
var abilities := {}
## AbilityID -> [{"option": id, "value": int, "group": int, "text": key or ""}].
var ability_options := {}

## The tables HudPanels loads once from the archive; null before.
static var shared: AvatarTables = null

static func from_archive(media: Pk2Reader) -> AvatarTables:
	var t := AvatarTables.new()
	if media == null:
		return t
	for spec in [[ASSIGN_PATH, "parse_assign"], [ABILITY_PATH, "parse_abilities"], [ABILITY_OPT_PATH, "parse_ability_options"]]:
		var entry := ObjectLoader.find_file(media, spec[0])
		if entry != null:
			t.call(spec[1], media.read_file(entry))
	return t

static func _text(data) -> String:
	if data is String:
		return data
	var raw: PackedByteArray = data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		return TextDecode.utf16(raw.slice(2))
	return raw.get_string_from_utf8()

static func _rows(data) -> Array:
	var out: Array = []
	for line in _text(data).replace("\r", "").split("\n"):
		if line.strip_edges() == "" or line.strip_edges().begins_with("//"):
			continue
		var cols := line.split("\t")
		for i in cols.size():
			cols[i] = cols[i].strip_edges()
		out.append(cols)
	return out

static func _int(s: String) -> int:
	return int(s) if s.is_valid_int() else 0

func parse_assign(data) -> void:
	for cols in _rows(data):
		if cols.size() < 5 or _int(cols[0]) != 1:
			continue
		var key := "%d/%d" % [_int(cols[2]), _int(cols[3])]
		if assign.has(key):
			continue
		var names := PackedStringArray()
		for i in range(4, cols.size()):
			var n: String = cols[i]
			if n == "" or n.to_lower() == "xxx":
				break
			names.append(n)
		assign[key] = names

func parse_abilities(data) -> void:
	for cols in _rows(data):
		if cols.size() < 4 or _int(cols[0]) != 1:
			continue
		var ref := _int(cols[2])
		if not abilities.has(ref):
			abilities[ref] = {}
		(abilities[ref] as Dictionary)[_int(cols[3])] = _int(cols[1])

func parse_ability_options(data) -> void:
	for cols in _rows(data):
		if cols.size() < 4 or not (cols[0] as String).is_valid_int():
			continue
		var id := _int(cols[0])
		if not ability_options.has(id):
			ability_options[id] = []
		var text: String = cols[4] if cols.size() > 4 else ""
		(ability_options[id] as Array).append({"option": _int(cols[1]), "value": _int(cols[2]), "group": _int(cols[3]),
			"text": "" if text == "" or text.to_lower() == "xxx" else text})

## The MATTR names an item of TypeID3/TypeID4 may be granted, in the row's
## order (READ c:0x8be3a0 pushes them in that order).
func assign_names(t3: int, t4: int) -> PackedStringArray:
	return assign.get("%d/%d" % [t3, t4], PackedStringArray())

## The AbilityID of (RefItemID, plus), falling back to the highest lower plus
## that has one (READ FUN_008bf680); -1 when none.
func ability_of(ref_id: int, plus: int) -> int:
	var by_plus: Dictionary = abilities.get(ref_id, {})
	var best := -1
	var best_plus := -1
	for p in by_plus:
		if int(p) <= plus and int(p) > best_plus:
			best_plus = int(p)
			best = int(by_plus[p])
	return best

## The ability's option entries of `group`, in file order.
func ability_entries(ability_id: int, group: int) -> Array:
	var out: Array = []
	for e in ability_options.get(ability_id, []):
		if int(e["group"]) == group:
			out.append(e)
	return out
