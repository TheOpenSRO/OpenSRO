extends RefCounted
class_name ItemTableReader

## Reads the item tables in the player's own Media.pk2: an item's name and
## inventory icon, **the model it is worn as**, and who may wear it.
##
## `server_dep\silkroad\textdata\itemdata*.txt` is UTF-16LE, tab separated,
## ~160 columns wide and split across numbered parts. The icon is found by
## content (the one `.ddj` in a row); everything else is by column, and
## the columns are the game's own `_RefObjCommon`/`_RefObjItem` layout,
## checked against real rows -- see docs/protocol/ITEM_FORMAT.md:
##
##   1 id   2 code name   3 display name   9-12 type ids
##   14 country   32/33 required level type and level (+ three more pairs)
##   52 worn model `.bsr`   53 drop model `.bsr`   54 icon `.ddj`
##   58 required gender
##
## The worn model is the whole reason this project can dress a character
## from the id the server sends: `4842 Cotton Suit` reads
## `item\china\man_item\clothes_01_ba.bsr`, and that file names the mesh,
## the material and -- for a weapon or a shoulder piece -- its own skeleton
## and the body bone it hangs from. The models live under `res\` in
## Data.pk2, the prefix the tables omit (see SkinnedBsrAssembler._read).
##
## The icon path is stored relative to `icon\`: a row reads
## `item\china\man_item\clothes_01_ba.ddj` and the file lives at
## `icon\item\china\man_item\clothes_01_ba.ddj`. A real archive holds 5,370
## of them.

const TABLE_PATHS := [
	"server_dep\\silkroad\\textdata\\itemdata.txt",
	"server_dep\\silkroad\\textdata\\itemdata_5000.txt",
	"server_dep\\silkroad\\textdata\\itemdata_10000.txt",
	"server_dep\\silkroad\\textdata\\itemdata_15000.txt",
	"server_dep\\silkroad\\textdata\\itemdata_20000.txt",
	"server_dep\\silkroad\\textdata\\itemdata_25000.txt",
	"server_dep\\silkroad\\textdata\\itemdata_30000.txt",
]

## Icon paths in the table are relative to this directory in Media.pk2.
const ICON_PREFIX := "icon\\"

## Column 1 is the id, column 3 the display name, in every part checked.
const COL_ID := 1
const COL_CODE_NAME := 2
const COL_NAME := 3
const COL_TYPE_ID1 := 9
const COL_TYPE_ID4 := 12
## `Country`: 0 for the China race's items, 1 for Europe's.
const COL_COUNTRY := 14
## Four (type, level) requirement pairs. Type 1 with level 1 is what every
## starter item carries; what the other type values ask for is
## characterised in ITEM_FORMAT.md rather than assumed here.
const COL_REQ_LEVEL_TYPE1 := 32
const COL_REQ_LEVEL1 := 33
const COL_MODEL := 52
const COL_DROP_MODEL := 53
## `ReqGender`: 1 for a man's item, 0 for a woman's, 2 for either.
const COL_REQ_GENDER := 58

const REQ_LEVEL_PAIRS := 4

class Item:
	var id: int
	var code_name: String
	var item_name: String
	## Archive path of the inventory icon, ICON_PREFIX already applied.
	var icon_path: String
	## The `.bsr` the item is worn as, as the table writes it (no `res\`
	## prefix). Empty for an item with no worn model -- consumables, and a
	## few equipment rows that write `xxx`.
	var model_path: String
	## The `.bsr` drawn when the item lies on the ground.
	var drop_model_path: String
	## TypeID1..4 -- the game's own classification, four levels deep.
	var type_ids: PackedInt32Array = PackedInt32Array()
	var country: int = 0
	var req_gender: int = 0
	## Requirement (type, level) pairs, in table order. A pair whose type
	## is -1 or 0 is unused; type 1 is the character's own level.
	var req_level_types: PackedInt32Array = PackedInt32Array()
	var req_levels: PackedInt32Array = PackedInt32Array()

	func is_equipment() -> bool:
		return model_path != ""

	## The character level the item asks for, or 0 when it asks by
	## something other than character level (or nothing at all).
	func required_character_level() -> int:
		for i in range(req_level_types.size()):
			if req_level_types[i] == REQ_TYPE_CHARACTER_LEVEL:
				return req_levels[i]
		return 0

## The value in a requirement pair's type column that means "the
## character's own level" -- what every starter item and every plain
## armour row checked carries in its first pair.
const REQ_TYPE_CHARACTER_LEVEL := 1
const REQ_GENDER_WOMAN := 0
const REQ_GENDER_MAN := 1
const REQ_GENDER_ANY := 2

## Parses one itemdata part into {id -> Item}, merging into `into` so the
## parts can be accumulated.
static func parse(data: PackedByteArray, into: Dictionary = {}) -> Dictionary:
	for line in _lines(data):
		var cols := line.split("\t")
		if cols.size() <= COL_NAME:
			continue
		var id_text := cols[COL_ID].strip_edges()
		if not id_text.is_valid_int():
			continue
		var item := Item.new()
		item.id = int(id_text)
		item.code_name = cols[COL_CODE_NAME].strip_edges()
		item.item_name = cols[COL_NAME].strip_edges()
		var icon := _find_icon_path(cols)
		if icon != "":
			item.icon_path = ICON_PREFIX + icon
		item.model_path = _model_at(cols, COL_MODEL)
		item.drop_model_path = _model_at(cols, COL_DROP_MODEL)
		for col in range(COL_TYPE_ID1, COL_TYPE_ID4 + 1):
			item.type_ids.append(_int_at(cols, col))
		item.country = _int_at(cols, COL_COUNTRY)
		item.req_gender = _int_at(cols, COL_REQ_GENDER)
		for pair in range(REQ_LEVEL_PAIRS):
			item.req_level_types.append(_int_at(cols, COL_REQ_LEVEL_TYPE1 + pair * 2))
			item.req_levels.append(_int_at(cols, COL_REQ_LEVEL1 + pair * 2))
		# A row with neither a name nor an icon tells the player nothing.
		if item.item_name == "" and item.icon_path == "":
			continue
		into[item.id] = item
	return into

## A `.bsr` path in the column the layout puts it in, or "" for the `xxx`
## the table writes where a row has no model -- checked by extension so a
## part with a shifted layout yields nothing rather than a wrong path.
static func _model_at(cols: PackedStringArray, col: int) -> String:
	if col >= cols.size():
		return ""
	var value := cols[col].strip_edges()
	return value.replace("/", "\\") if value.to_lower().ends_with(".bsr") else ""

static func _int_at(cols: PackedStringArray, col: int) -> int:
	if col >= cols.size():
		return 0
	var text := cols[col].strip_edges()
	return int(text) if text.is_valid_int() else 0

## The `.ddj` field in an item row. A row also carries two `.bsr` model
## paths, so matching on the extension is what picks the icon out.
static func _find_icon_path(cols: PackedStringArray) -> String:
	for col in cols:
		var trimmed := col.strip_edges()
		if trimmed.to_lower().ends_with(".ddj"):
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
