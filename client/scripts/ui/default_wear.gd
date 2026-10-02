extends RefCounted
class_name DefaultWear

## What a character wears where it wears nothing (round 685's review): retail's
## default wear. Everything READ from sro_client.exe unless marked; the rows
## are the player's own Media.pk2 `textdata\charactervisualchange.txt`.
##
## **When** (`FUN_00a5e010`, run after every armour change through 0xa61c60 ->
## `CObjCharacter::FUN_00a611e0`): when `CGame+0x129` is set, both default
## wears are taken off and nothing else happens. Otherwise, for default wear 0
## (mask 0x2, the mail) and 1 (mask 0x10, the pants): if no worn visual's
## record has that bit in its Slot mask (`FUN_004ec9b0(visual) + 4`), it calls
## `SetDefaultWear(0, 1)` / `SetDefaultWear(1, 4)` -- the chest's and the
## legs' visual slots; else it takes that default off. Nothing for the feet,
## the hands, the shoulders or the head.
##
## **What** (`CObjCharacter::SetDefaultWear` 0xa5cca0 and
## `BuildDefaultWearTypeID` 0xa5c760): a packed TypeID, 0x2c, with the armour
## family by the character's race byte (the character data's +0x9c; INFERRED
## the Country, 0 China, 1 Europe) and `WornArmorClass()` (0xa5c670: the first
## visual slot 0..8 holding armour -- 1 for TypeID3 1/9, 2 for 2/10, 3 for
## 3/11 -- else 0): China 0/1 -> TypeID3 1, 2/3 -> 2; Europe 0/1 -> 9, 2/3 ->
## 10 (the jump tables at 0xa5c82c and 0xa5c81c); then TypeID4 3 for wear 0
## (`& 0x7ff | 0x1800`) and 4 for wear 1 (`| 0x2000`). It is looked up
## (FUN_004ec320 -> FUN_004ec9b0) to a visual record whose BsrName(M) (+0x18)
## a man wears and BsrName(F) (+0x34) a woman (`+0x1c4`, the sex).
##
## **The rows** (MEASURED, vSRO): ConditionID 6, Pram1 the packed TypeID --
## 6316 / 8364 China `clothes_00_ba` / `_la`, 6444 / 8492 China `light_00_*`,
## 7340 / 9388 Europe `clothes_01_*`, 7468 / 9516 Europe `light_01_*`, each a
## man's and a woman's .bsr. The packing is TypeID1 << 2 | TypeID2 << 5 |
## TypeID3 << 7 | TypeID4 << 11 (MEASURED: it gives every ConditionID 1 row's
## Pram1 for the armour it names, and the default rows above).
##
## **A worn item's mask:** the ConditionID 1 row whose Pram1 is the item's
## packed TypeID (INFERRED that this is the visual record an equipped item
## gets; the rows are named for armour pieces -- "ROBE-MAIL" 6316 mask 0x2,
## "ROBE-PANTS" 8364 mask 0x10). An avatar's record (ConditionID 2, chosen by
## further conditions) is not modelled: OPEN, as the avatar arbitration is.

const PATH := "server_dep\\silkroad\\textdata\\charactervisualchange.txt"

const COL_SERVICE := 0
const COL_CONDITION := 3
const COL_PRAM1 := 5
const COL_SLOT := 13
const COL_BSR_MAN := 19
const COL_BSR_WOMAN := 20

const CONDITION_ITEM := 1
const CONDITION_DEFAULT := 6

const MASK_MAIL := 0x2
const MASK_PANTS := 0x10
## [default wear number, its mask, the visual slot it fills] (READ 0xa5e010).
const WEARS := [[0, MASK_MAIL, CharacterAppearance.SLOT_CHEST], [1, MASK_PANTS, CharacterAppearance.SLOT_LEGS]]

## packed TypeID -> Slot mask, from the ConditionID 1 rows.
var item_masks: Dictionary = {}
## packed TypeID -> [man .bsr, woman .bsr], from the ConditionID 6 rows.
var defaults: Dictionary = {}

static func from_archive(media: Pk2Reader) -> DefaultWear:
	var dw := DefaultWear.new()
	if media == null:
		return dw
	var entry := ObjectLoader.find_file(media, PATH)
	if entry != null:
		dw.parse_into(media.read_file(entry))
	return dw

static func from_text(text: String) -> DefaultWear:
	var dw := DefaultWear.new()
	dw.parse_into(text)
	return dw

func parse_into(data) -> void:
	var text := ""
	if data is String:
		text = data
	else:
		var raw: PackedByteArray = data
		if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
			text = raw.slice(2).get_string_from_utf16()
		else:
			text = raw.get_string_from_utf8()
	for line in text.split("\n"):
		line = line.strip_edges(false, true)
		if line == "" or line.begins_with("//"):
			continue
		var cols := line.split("\t")
		if cols.size() <= COL_BSR_WOMAN or _num(cols[COL_SERVICE]) != 1:
			continue
		var cond := _num(cols[COL_CONDITION])
		var tid := _num(cols[COL_PRAM1])
		if cond == CONDITION_ITEM:
			item_masks[tid] = int(item_masks.get(tid, 0)) | _num(cols[COL_SLOT])
		elif cond == CONDITION_DEFAULT:
			defaults[tid] = [_path(cols[COL_BSR_MAN]), _path(cols[COL_BSR_WOMAN])]

static func _num(t: String) -> int:
	t = t.strip_edges()
	if t.begins_with("0x") or t.begins_with("0X"):
		return t.substr(2).hex_to_int()
	return int(t) if t.is_valid_int() else 0

static func _path(t: String) -> String:
	t = t.strip_edges()
	return "" if t == "" or t == "xxx" else t

## The packed TypeID of an item's TypeID1..4 (MEASURED, header).
static func packed_type_id(t: PackedInt32Array) -> int:
	if t.size() < 4:
		return 0
	return (t[0] << 2) | (t[1] << 5) | (t[2] << 7) | (t[3] << 11)

## READ 0xa5c670: the first visual slot 0..8 holding armour decides --
## 1 (TypeID3 1/9), 2 (2/10), 3 (3/11); 0 when none does. `worn` is
## [{slot, type_ids}], any order.
static func worn_armour_class(worn: Array) -> int:
	var sorted := worn.duplicate()
	sorted.sort_custom(func(a, b): return int(a["slot"]) < int(b["slot"]))
	for w in sorted:
		var slot := int(w["slot"])
		if slot < 0 or slot > 8:
			continue
		var t: PackedInt32Array = w["type_ids"]
		if t.size() < 4 or t[0] != 3 or t[1] != 1:
			continue
		match t[2]:
			1, 9: return 1
			2, 10: return 2
			3, 11: return 3
	return 0

## READ 0xa5c760: the default wear's packed TypeID.
static func default_type_id(race: int, wear_num: int, armour_class: int) -> int:
	var v := 0x2c
	if race == CharCatalog.RACE_EUROPE:
		v = (v & 0xfcff) | 0x480 if armour_class <= 1 else (v & 0xfd7f) | 0x500
	else:
		v = (v & 0xf8ff) | 0x80 if armour_class <= 1 else (v & 0xf97f) | 0x100
	if wear_num == 0:
		return (v & 0x7ff) | 0x1800
	return (v & 0x7ff) | 0x2000

## What fills the empty chest and legs (READ 0xa5e010): [{slot, path, wear}]
## for each default the worn visuals leave uncovered. `worn` is [{slot,
## type_ids}]. `server_flag` is CGame+0x129: set, nothing.
func wear_for(race: int, woman: bool, worn: Array, server_flag: bool = false) -> Array:
	var out: Array = []
	if server_flag or defaults.is_empty():
		return out
	var covered := 0
	for w in worn:
		covered |= int(item_masks.get(packed_type_id(w["type_ids"]), 0))
	var cls := worn_armour_class(worn)
	for wear in WEARS:
		if covered & int(wear[1]):
			continue
		var row: Array = defaults.get(default_type_id(race, wear[0], cls), [])
		if row.is_empty():
			continue
		var path: String = row[1] if woman else row[0]
		if path != "":
			out.append({"slot": wear[2], "path": path, "wear": wear[0]})
	return out
