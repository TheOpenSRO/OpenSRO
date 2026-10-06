extends RefCounted
class_name CharCatalog

## The creatable catalogue: which bodies (Figures), weapons and armour sets the
## character-create screens offer, derived at runtime from the player's own
## Media.pk2. Nothing is shipped; no id below is a constant of this file.
##
## **The rule** (docs/protocol/charselect.md section 6, "The creatable
## catalogue"; the server's twin is server/internal/refdata/chargen.go, round
## 682, which applies the same rule to the same columns):
## - a **body** is a characterdata row with Service 1 and TypeID1/TypeID2 = 1/1
##   (a player character -- the test ShardManager's create makes on the model,
##   READ FUN_0048d8d0);
## - an **item** is an itemdata row with Service 1, TypeID1/TypeID2 = 3/1
##   (equipment) and a code name ending `_A_DEF`;
## - the **last** definition of an id wins (the China bodies 1908-1932 appear
##   in two characterdata parts, MEASURED), and the rule is applied to that
##   last definition.
## On the vSRO archive this is 52 bodies and 52 items, the 104 of
## charselect.md section 4 (MEASURED 2026-10-02). Where the retail client's
## own id list (0xeedf08) comes from is OPEN (INFERRED `_RefCharGen`).
##
## **How the screen sorts them** (READ, `CCustomInfoManager`'s loader
## 0x80b980): a character to slot 0; an armour piece (TypeID3 1/2/3/9/10/11)
## by TypeID4 3/4/6 to chest/legs/feet; TypeID3 6 to the weapon; TypeID3 4
## with TypeID4 1/2 to the shield. Each goes to the man's or the woman's list
## (or both) by its sex: a body's characterdata column 58 (MEASURED: 1 on all
## 26 `_MAN_` rows, 0 on all 26 `_WOMAN_`), an item's ReqGender (column 58:
## 0 woman, 1 man, 2 either; READ refobj +0x1c4). Within a list the order is
## the id list's own, INFERRED to be id order: it is the order the tooltips
## name (READ, charselect.md section 4) for every slot but Europe women
## 12/13, whose retail order is OPEN.

const RACE_CHINA := 0
const RACE_EUROPE := 1
## Characterdata column 58 / itemdata ReqGender. 2 is an item for either sex.
const SEX_WOMAN := 0
const SEX_MAN := 1
const SEX_EITHER := 2

## 0-based columns of a tab-split textdata row (column 0 is Service). The same
## indices ItemTableReader, NpcTableReader and refdata/chargen.go use.
const COL_SERVICE := 0
const COL_ID := 1
const COL_CODE := 2
const COL_TYPE_ID1 := 9
const COL_COUNTRY := 14
const COL_MODEL := 52
const COL_SEX := 58
## itemdata only: TwoHanded (MEASURED: 0 on the one-handed sword, blade, Long
## Sword, Warlock Rod and Cleric Rod, 1 on every other catalogue weapon).
const COL_TWO_HANDED := 93

## The create packet's pieces (charselect.md section 4: slots 1..5 of
## `CCustomInfoManager`; 0 is the model).
enum Piece { NONE, CHEST, LEGS, FEET, WEAPON, SHIELD }

## Armour families by TypeID3 (MEASURED on the catalogue's code names:
## `_CLOTHES_` / `_LIGHT_` / `_HEAVY_`).
const ARMOUR_CLASS_NAMES := {
	1: "clothes", 2: "light", 3: "heavy",  # China
	9: "robe", 10: "light", 11: "heavy",   # Europe
}

## Europe's weapon -> Protector rule (READ, `CPSCharacterCreateEurope`
## 0x8531e0, with the slider ranges of 0x853400): keyed by the weapon's
## TypeID4 (the handler's `TID >> 11`), the list positions (1-based, in the
## sex's armour list) that Protector values 1, 2, .. select. Protector 0 is no
## armour. With the list in id order (INFERRED) position 1 is the heavy set,
## 2 light, 3 robe, which is the table charselect.md section 4 gives:
## - 7 1H sword, 8 2H sword, 9 dual axe: heavy, light;
## - 12 crossbow, 13 dagger: light;
## - 10 warlock rod, 11 staff, 14 harp: robe;
## - 15 cleric rod: light, robe.
static var EUROPE_PROTECTOR_POSITIONS := {
	7: [1, 2], 8: [1, 2], 9: [1, 2],
	12: [2], 13: [2],
	10: [3], 11: [3], 14: [3],
	15: [2, 3],
}

## The scale byte a new character starts with: Height and Volume both at 2
## (READ, charselect.md section 4; the sliders run 0..4 and start at 2).
const DEFAULT_SCALE := 0x22

## One catalogue row.
class Entry:
	var id: int
	var code: String
	## RACE_CHINA / RACE_EUROPE (the row's Country; 3 would be either race).
	var race: int
	## A body: SEX_MAN / SEX_WOMAN. An item: its ReqGender, SEX_EITHER for both.
	var sex: int
	var type_ids: PackedInt32Array = PackedInt32Array()
	## The row's worn model (`.bsr`, column 52, first of a comma list).
	var model_path: String = ""
	var two_handed: bool = false
	var is_body: bool = false

	func type_id(level: int) -> int:
		return type_ids[level - 1] if level >= 1 and level <= type_ids.size() else 0

	## The create packet's piece, by the create screen's own loader (READ
	## 0x80b980): an armour piece needs TypeID3 1/2/3/9/10/11 and the shield
	## TypeID4 1 or 2 (also `IsShieldItem` 0x56fab0). refdata/chargen.go's
	## Piece() is looser (TypeID3 4 is a shield whatever its TypeID4, and
	## TypeID4 3/4/6 is a piece whatever its TypeID3). The two agree on all 52
	## catalogue items of the vSRO archive (MEASURED by appearance_probe.gd's
	## set, weapon and shield counts).
	func piece() -> int:
		if is_body:
			return Piece.NONE
		var t3 := type_id(3)
		var t4 := type_id(4)
		if t3 == 6:
			return Piece.WEAPON
		if t3 == 4 and (t4 == 1 or t4 == 2):
			return Piece.SHIELD
		if t3 in [1, 2, 3, 9, 10, 11]:
			match t4:
				3: return Piece.CHEST
				4: return Piece.LEGS
				6: return Piece.FEET
		return Piece.NONE

	## The armour family (TypeID3) of a chest/legs/feet piece, 0 otherwise.
	func armour_class() -> int:
		return type_id(3) if piece() in [Piece.CHEST, Piece.LEGS, Piece.FEET] else 0

	## Whether an item is offered to a body of `body_sex`.
	func fits_sex(body_sex: int) -> bool:
		return sex == SEX_EITHER or sex == body_sex

## A Protector choice: the chest, legs and feet that one slider value sets.
class ArmourSet:
	var armour_class: int
	var name: String
	var chest: Entry
	var legs: Entry
	var feet: Entry

	func ids() -> Array[int]:
		var out: Array[int] = []
		for e in [chest, legs, feet]:
			out.append((e as Entry).id if e != null else 0)
		return out

## Every catalogue row, by id.
var entries: Dictionary = {}

# --- building ------------------------------------------------------------------

## The textdata directory both index files and their parts live in.
const TEXTDATA_DIR := "server_dep\\silkroad\\textdata\\"
## The index files: one part name per line, in the order the client loads them
## (MEASURED: characterdata.txt lists CharacterData_1000.txt ..
## CharacterData_63000.txt and itemdata.txt ItemData_1000.txt ..
## ItemData_63000.txt; the archive also holds parts no index names, such as
## itemdata_55500.txt, which are not read).
const CHAR_INDEX := "characterdata.txt"
const ITEM_INDEX := "itemdata.txt"

## The catalogue from the player's own Media.pk2, or an empty one when it has
## no tables.
static func from_archive(media_pk2: Pk2Reader) -> CharCatalog:
	return from_tables(index_parts(media_pk2, CHAR_INDEX), index_parts(media_pk2, ITEM_INDEX))

## The bytes of every part `index_name` names, in the index's order. A name the
## archive lacks is skipped; an empty or missing index gives no parts.
static func index_parts(media_pk2: Pk2Reader, index_name: String) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	for name in index_part_names(media_pk2, index_name):
		var entry := ObjectLoader.find_file(media_pk2, TEXTDATA_DIR + name)
		if entry != null:
			out.append(media_pk2.read_file(entry))
	return out

## The part names an index file lists, in order.
static func index_part_names(media_pk2: Pk2Reader, index_name: String) -> PackedStringArray:
	var names := PackedStringArray()
	if media_pk2 == null:
		return names
	var entry := ObjectLoader.find_file(media_pk2, TEXTDATA_DIR + index_name)
	if entry == null:
		return names
	return parse_index(media_pk2.read_file(entry))

## An index file's part names, in order (blank and `//` lines skipped).
static func parse_index(data) -> PackedStringArray:
	var names := PackedStringArray()
	for line in _text_lines(data):
		var n := line.strip_edges()
		if n != "" and not n.begins_with("//"):
			names.append(n)
	return names

## The catalogue from raw characterdata and itemdata parts (UTF-16LE as the
## archive stores them, or UTF-8), in the index files' order.
static func from_tables(char_parts: Array, item_parts: Array) -> CharCatalog:
	var catalog := CharCatalog.new()
	var last_chars := {}
	for part in char_parts:
		_collect_last(_text_lines(part), last_chars, false)
	var last_items := {}
	for part in item_parts:
		_collect_last(_text_lines(part), last_items, true)
	for id in last_chars:
		var cols: PackedStringArray = String(last_chars[id]).split("\t")
		if _is_body(cols):
			catalog.entries[id] = _entry(cols, true)
	for id in last_items:
		var cols: PackedStringArray = String(last_items[id]).split("\t")
		if _is_item(cols):
			catalog.entries[id] = _entry(cols, false)
	return catalog

## Keeps, per id, the last line that defines it -- but only for ids that are
## ever a candidate, so the 30,000 item rows are not all kept. A later
## definition of a candidate id replaces it whatever it says, which is what
## "the last definition wins" needs. As refdata/chargen.go does: a `//` line
## and a row whose column 1 is not an integer are skipped, and a row too short
## to hold the rule's columns (58 for a body, 93 for an item) defines nothing,
## so it does not replace an earlier one.
static func _collect_last(lines: PackedStringArray, last: Dictionary, items: bool) -> void:
	var need := (COL_TWO_HANDED if items else COL_SEX) + 1
	for line in lines:
		if line.is_empty() or line.begins_with("//"):
			continue
		var id_text := line.get_slice("\t", COL_ID).strip_edges()
		if not id_text.is_valid_int():
			continue
		var id := int(id_text)
		# The cheap tests first: most rows are neither a candidate nor an id
		# already kept, and a full tab count of every row cost ~1 s (MEASURED).
		if not (last.has(id) or _maybe_candidate(line, items)):
			continue
		if line.count("\t") + 1 < need:
			continue
		last[id] = line.trim_suffix("\r")

## A cheap pre-test the full rule then confirms: an item's code must end
## `_A_DEF`, so its line holds `_A_DEF\t`; a body's TypeID1/2 must read 1/1.
static func _maybe_candidate(line: String, items: bool) -> bool:
	if items:
		return line.contains("_A_DEF\t")
	return line.get_slice("\t", COL_TYPE_ID1).strip_edges() == "1" \
		and line.get_slice("\t", COL_TYPE_ID1 + 1).strip_edges() == "1"

static func _is_body(cols: PackedStringArray) -> bool:
	return cols.size() > COL_SEX and _int(cols, COL_SERVICE) == 1 \
		and _int(cols, COL_TYPE_ID1) == 1 and _int(cols, COL_TYPE_ID1 + 1) == 1

static func _is_item(cols: PackedStringArray) -> bool:
	return cols.size() > COL_SEX and _int(cols, COL_SERVICE) == 1 \
		and _int(cols, COL_TYPE_ID1) == 3 and _int(cols, COL_TYPE_ID1 + 1) == 1 \
		and cols[COL_CODE].strip_edges().ends_with("_A_DEF")

static func _entry(cols: PackedStringArray, is_body: bool) -> Entry:
	var e := Entry.new()
	e.id = _int(cols, COL_ID)
	e.code = cols[COL_CODE].strip_edges()
	e.race = _int(cols, COL_COUNTRY)
	e.sex = _int(cols, COL_SEX)
	for i in range(4):
		e.type_ids.append(_int(cols, COL_TYPE_ID1 + i))
	if cols.size() > COL_MODEL:
		e.model_path = cols[COL_MODEL].strip_edges().split(",")[0].strip_edges().replace("/", "\\")
		if not e.model_path.to_lower().ends_with(".bsr"):
			e.model_path = ""
	e.two_handed = not is_body and _int(cols, COL_TWO_HANDED) != 0
	e.is_body = is_body
	return e

static func _int(cols: PackedStringArray, i: int) -> int:
	if i >= cols.size():
		return 0
	var t := cols[i].strip_edges()
	return int(t) if t.is_valid_int() else 0

static func _text_lines(data) -> PackedStringArray:
	if data is String:
		return (data as String).replace("\r", "").split("\n")
	var raw: PackedByteArray = data
	if raw.is_empty():
		return PackedStringArray()
	var text := ""
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		text = raw.slice(2).get_string_from_utf16()
	else:
		text = raw.get_string_from_utf8()
	# Lines keep a trailing "\r"; every reader strips its fields, and a kept
	# row is trimmed, so the whole text is not copied once more to drop them.
	return text.split("\n")

# --- queries -------------------------------------------------------------------

func size() -> int:
	return entries.size()

func has(id: int) -> bool:
	return entries.has(id)

func get_entry(id: int) -> Entry:
	return entries.get(id)

## Every id in the catalogue, ascending.
func all_ids() -> Array[int]:
	var out: Array[int] = []
	for id in entries:
		out.append(int(id))
	out.sort()
	return out

## The Figures for a race and sex, in id order: the Figure slider's 1..n.
func figures(race: int, sex: int) -> Array[Entry]:
	return _sorted(func(e: Entry) -> bool: return e.is_body and e.race == race and e.sex == sex)

## The weapons for a race, in id order: the Weapon slider's 1..n (0 is none).
func weapons(race: int, sex: int = SEX_EITHER) -> Array[Entry]:
	return _sorted(func(e: Entry) -> bool:
		return e.piece() == Piece.WEAPON and e.race == race and (sex == SEX_EITHER or e.fits_sex(sex)))

## The race's shield (the server adds it beside a one-handed weapon,
## charselect.md section 5), or null.
func shield(race: int) -> Entry:
	var found := _sorted(func(e: Entry) -> bool: return e.piece() == Piece.SHIELD and e.race == race)
	return found[0] if not found.is_empty() else null

## Every armour set for a race and sex, in list order (INFERRED id order):
## the Protector slider's list positions 1..n.
func all_armour_sets(race: int, sex: int) -> Array[ArmourSet]:
	var by_class := {}
	var order: Array[int] = []
	for e in _sorted(func(x: Entry) -> bool:
			return x.armour_class() != 0 and x.race == race and x.fits_sex(sex)):
		var cls: int = e.armour_class()
		if not by_class.has(cls):
			var s := ArmourSet.new()
			s.armour_class = cls
			s.name = ARMOUR_CLASS_NAMES.get(cls, str(cls))
			by_class[cls] = s
			order.append(cls)
		var set_: ArmourSet = by_class[cls]
		match e.piece():
			Piece.CHEST:
				if set_.chest == null: set_.chest = e
			Piece.LEGS:
				if set_.legs == null: set_.legs = e
			Piece.FEET:
				if set_.feet == null: set_.feet = e
	# Ordered by the set's chest id, the list's position (the chest list is
	# what the Protector index walks first, READ 0x84de90 / 0x8531e0).
	var sets: Array[ArmourSet] = []
	for cls in order:
		sets.append(by_class[cls])
	sets.sort_custom(func(a: ArmourSet, b: ArmourSet) -> bool:
		return CharCatalog._first_id(a) < CharCatalog._first_id(b))
	return sets

## The armour sets the Protector slider offers with `weapon_id` in hand,
## Protector value 1 first. China has no restriction; Europe's is READ
## (EUROPE_PROTECTOR_POSITIONS). With no weapon Europe offers none (the slider
## is dimmed, READ 0x8531e0 case 0).
func armour_sets(race: int, sex: int, weapon_id: int = 0) -> Array[ArmourSet]:
	var all := all_armour_sets(race, sex)
	if race != RACE_EUROPE:
		return all
	var weapon := get_entry(weapon_id)
	var out: Array[ArmourSet] = []
	if weapon == null or weapon.piece() != Piece.WEAPON:
		return out
	for pos in EUROPE_PROTECTOR_POSITIONS.get(weapon.type_id(4), []):
		if int(pos) >= 1 and int(pos) <= all.size():
			out.append(all[int(pos) - 1])
	return out

## What the create screen starts with (READ: sex man, 0x8504b4 passes 1;
## Figure 1, 0x84f350 clamps the slider to its minimum; Height and Volume 2;
## Weapon 0). Protector starts at its minimum, which is 0 or 1 by a per-server
## flag whose meaning is OPEN (charselect.md section 4): pass
## `protector_required` for 1. A weapon of 0 is refused by Confirm, so these
## are the screen's starting values, not a creatable kit.
func defaults(race: int, sex: int = SEX_MAN, protector_required: bool = false) -> Dictionary:
	var figs := figures(race, sex)
	var out := {
		"race": race,
		"sex": sex,
		"model": figs[0].id if not figs.is_empty() else 0,
		"scale": DEFAULT_SCALE,
		"weapon": 0,
		"chest": 0, "legs": 0, "feet": 0,
	}
	if protector_required and race != RACE_EUROPE:
		var sets := all_armour_sets(race, sex)
		if not sets.is_empty():
			var ids := sets[0].ids()
			out["chest"] = ids[0]
			out["legs"] = ids[1]
			out["feet"] = ids[2]
	return out

## A creatable kit for previews and lineups (OURS: the first weapon and the
## first armour set it allows, plus the race's shield beside a one-handed
## weapon as the server adds it, READ section 5). Items as
## CharacterAppearance.build takes them.
func sample_kit(race: int, sex: int, weapon_index: int = 0, set_index: int = 0) -> Array:
	var ws := weapons(race, sex)
	if ws.is_empty():
		return []
	var weapon: Entry = ws[clampi(weapon_index, 0, ws.size() - 1)]
	var sets := armour_sets(race, sex, weapon.id)
	var kit: Array = []
	if not sets.is_empty():
		for id in sets[clampi(set_index, 0, sets.size() - 1)].ids():
			if id != 0:
				kit.append({"id": id, "plus": 0})
	kit.append({"id": weapon.id, "plus": 0})
	var sh := shield(race)
	if sh != null and not weapon.two_handed and weapon.type_id(4) != 6 and weapon.type_id(4) != 12:
		kit.append({"id": sh.id, "plus": 0})
	return kit

static func _first_id(s: ArmourSet) -> int:
	for e in [s.chest, s.legs, s.feet]:
		if e != null:
			return (e as Entry).id
	return 0

func _sorted(pred: Callable) -> Array[Entry]:
	var out: Array[Entry] = []
	for id in entries:
		var e: Entry = entries[id]
		if pred.call(e):
			out.append(e)
	out.sort_custom(func(a: Entry, b: Entry) -> bool: return a.id < b.id)
	return out
