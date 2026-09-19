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

## Column 1 is the id, column 2 the code name, column 3 an internal object
## name and column 5 the name **string id** (`SN_ITEM_*`). Column 3 is written
## in mixed languages -- English for weapons ("Copper Sword"), Korean for many
## consumables -- so the display name comes from column 5 resolved through
## textdata_object.txt (English), with column 3 the fallback. Confirmed against
## real rows: HP_POTION_05's col3 is Korean while col5 is SN_ITEM_ETC_HP_POTION_05,
## which textdata_object gives as "HP Recovery Potion (X-Large)".
const COL_ID := 1
const COL_CODE_NAME := 2
const COL_NAME := 3
const COL_NAME_STRID := 5
## SellPrice (column 31): what the NPC pays to buy an item back -- real, and
## under the buy price on every row (Copper Sword 890 buy / 427 sell). Shown as
## the estimate in the sell confirm; the server's result carries the true gold.
const COL_SELL_PRICE := 31
## MaxStack (column 57): 1 for equipment, the real per-item cap for stackables
## (a potion 5000, arrows 2500) -- so the shop can offer buying a stack.
const COL_MAX_STACK := 57
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

## Weapon stat columns, each read as a group of four where the item's own
## value is [0] and its upper bound [2] -- the display is `[0] ~ [2]`.
## Anchored against a real Copper Sword (+5) tooltip: its physical attack
## base is 15~16 (columns below) and grows 2.4 a plus, so +5 shows 27~28;
## its magical attack base 25~28 grows 4.1, so +5 shows 45~48; and the
## reinforce, rate and critical columns read 306/342 (30.6~34.2%),
## 519/591 (51.9~59.1%), 24 and 3 -- every figure the tooltip showed, in
## these columns, with no fudge. See ITEM_FORMAT.md and WORLD_ISSUES.md.
## Durability is common to every equippable item; the rest are weapons.
const COL_DURABILITY := 63
const COL_PHYS_ATK_MIN := 95
const COL_PHYS_ATK_MAX := 97
const COL_MAG_ATK_MIN := 100
const COL_MAG_ATK_MAX := 102
const COL_PHYS_REINFORCE_MIN := 105
const COL_PHYS_REINFORCE_MAX := 107
const COL_MAG_REINFORCE_MIN := 109
const COL_MAG_REINFORCE_MAX := 111
const COL_ATTACK_RATE := 113
const COL_CRITICAL := 116

## Armour defence columns, a separate block from the weapon attack columns
## above (weapons leave these 0; armour leaves the attack columns 0). Grounded
## from the real DB _RefObjItem column order documented in
## docs/protocol/refdata_schema.md -- PD (physical defence), ER, PAR, BR (block,
## shields), MD (magical defence) -- which lines up with these positions in the
## data, and is confirmed by the cloth-vs-heavy relationship (cloth armour has
## more magical defence, heavy armour more physical). Each defence is a min/max
## pair (the +0 range, like the weapon block); the values are floats (2 ~ 2.5).
const COL_PHYS_DEF_MIN := 65
const COL_PHYS_DEF_MAX := 66
const COL_BLOCK_MIN := 74
const COL_BLOCK_MAX := 75
const COL_MAG_DEF_MIN := 76
const COL_MAG_DEF_MAX := 77

## TypeID3 (the item family) values, index 2 of type_ids.
const FAMILY_WEAPON := 6
const CHINA_ARMOUR_FAMILIES := [1, 2, 3]
const EUROPE_ARMOUR_FAMILIES := [9, 10, 11]
## Weapon TypeID4 -> the "Sort of item" name the original prints, for the
## China kinds (the only bodies this project draws). ITEM_FORMAT.md's
## switch has the rest.
const WEAPON_SORT := {
	2: "Sword", 3: "Blade", 4: "Spear", 5: "Glaive", 6: "Bow",
	7: "Sword", 8: "Two-handed Sword", 9: "Axe", 10: "Dark Staff",
	11: "Two-handed Staff", 12: "Crossbow", 13: "Dagger", 14: "Harp", 15: "Staff",
}

const REQ_LEVEL_PAIRS := 4

class Item:
	var id: int
	var code_name: String
	## The internal object name (column 3): English for weapons, but Korean for
	## many consumables. Prefer display_name(), which resolves the string id.
	var item_name: String
	## The name string id (column 5, `SN_ITEM_*`), resolved through
	## textdata_object.txt for the real English display name.
	var name_strid: String
	## MaxStack (column 57): how many fit in one inventory slot. 1 for
	## equipment; a large cap for stackable consumables/materials.
	var max_stack: int = 1
	## SellPrice (column 31): the NPC buy-back price, for the sell estimate.
	var sell_price: int = 0
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
	## Weapon stats, base (+0). Reinforce is in tenths of a percent, as the
	## table stores it (306 = 30.6%). Zero for a non-weapon.
	var durability: int = 0
	var phys_atk := Vector2i.ZERO
	var mag_atk := Vector2i.ZERO
	var phys_reinforce := Vector2i.ZERO
	var mag_reinforce := Vector2i.ZERO
	var attack_rate: int = 0
	var critical: int = 0
	## Armour defence, base (+0), min~max (floats). Zero for a non-defensive
	## item. block is a shield's block ratio.
	var phys_def := Vector2.ZERO
	var mag_def := Vector2.ZERO
	var block := Vector2.ZERO

	func is_equipment() -> bool:
		return model_path != ""

	func family() -> int:
		return type_ids[2] if type_ids.size() > 2 else 0

	func is_weapon() -> bool:
		return family() == FAMILY_WEAPON

	func is_armour() -> bool:
		return CHINA_ARMOUR_FAMILIES.has(family()) or EUROPE_ARMOUR_FAMILIES.has(family())

	## True when the item carries a defence value (armour or a shield) -- what
	## decides whether the tooltip shows a defence block.
	func has_defence() -> bool:
		return phys_def != Vector2.ZERO or mag_def != Vector2.ZERO

	## Formats a defence float without a trailing ".0" (2.0 -> "2", 2.5 -> "2.5").
	static func _fmt(value: float) -> String:
		return ("%.1f" % value).trim_suffix(".0")

	## The real English display name: the name string id (column 5) resolved
	## through textdata_object.txt -- and ONLY that table: the 9,315 `SN_ITEM_`
	## keys live there and nowhere else (textuisystem.txt holds none, measured
	## 2026-09-19), so a caller handing in the UI-string table gets nothing
	## resolved. When no table is given or the id does not resolve, the
	## column-3 object name is used only if it reads as English: it is English
	## for weapons and armour but Korean for many consumables, and in this
	## archive the Korean is already mangled to question marks in the file
	## itself (`ITEM_ETC_HP_POTION_01`'s column 3 is literally "HP ?? ??").
	## Otherwise "" -- a player is shown the client's own name or nothing,
	## never an id and never a row of question marks.
	func display_name(names: UiTextTable = null) -> String:
		if names != null and name_strid != "":
			var resolved := names.get_text(name_strid)
			if resolved != "" and resolved != name_strid:
				return resolved
		if reads_as_english(item_name):
			return item_name
		return ""

	## True when a column-3 object name is usable as an English label:
	## printable ASCII with at least one letter and no '?' (the archive's
	## mark of a lost non-Latin character). A name with a Hangul character,
	## a "?", or nothing but digits and punctuation is not shown.
	static func reads_as_english(text: String) -> bool:
		var trimmed := text.strip_edges()
		if trimmed == "" or trimmed.contains("?"):
			return false
		var has_letter := false
		for ch in trimmed:
			var code := ch.unicode_at(0)
			if code < 0x20 or code > 0x7e:
				return false
			if (code >= 0x41 and code <= 0x5a) or (code >= 0x61 and code <= 0x7a):
				has_letter = true
		return has_letter

	## The lines a hover tooltip shows, top to bottom -- the item's own real
	## figures, none invented. A weapon shows its attack block; every
	## equippable shows durability, requirement, race and gender. Kept to
	## what is measured: attack distance and the armour defence block are
	## not among these columns yet, so they are simply absent rather than
	## guessed at.
	func tooltip_lines(names: UiTextTable = null) -> Array:
		var lines: Array = [display_name(names)]
		var type_id4: int = type_ids[3] if type_ids.size() > 3 else 0
		var sort: String = str(WEAPON_SORT.get(type_id4, "")) if is_weapon() else ""
		if sort != "":
			lines.append("Sort of item: %s" % sort)
		lines.append("")
		if is_weapon():
			lines.append("Phy. atk. pwr. %d ~ %d" % [phys_atk.x, phys_atk.y])
			lines.append("Mag. atk. pwr. %d ~ %d" % [mag_atk.x, mag_atk.y])
		elif has_defence():
			lines.append("Phy. def. pwr. %s ~ %s" % [_fmt(phys_def.x), _fmt(phys_def.y)])
			lines.append("Mag. def. pwr. %s ~ %s" % [_fmt(mag_def.x), _fmt(mag_def.y)])
			if block != Vector2.ZERO:
				lines.append("Block ratio %s ~ %s" % [_fmt(block.x), _fmt(block.y)])
		if durability > 0:
			lines.append("Durability %d / %d" % [durability, durability])
		if is_weapon():
			lines.append("Attack rate %d" % attack_rate)
			lines.append("Critical %d" % critical)
			lines.append("Phy. reinforce %.1f %% ~ %.1f %%" % [phys_reinforce.x / 10.0, phys_reinforce.y / 10.0])
			lines.append("Mag. reinforce %.1f %% ~ %.1f %%" % [mag_reinforce.x / 10.0, mag_reinforce.y / 10.0])
		lines.append("")
		var level := required_character_level()
		if level > 0:
			lines.append("Required level %d" % level)
		lines.append("China" if country == 0 else "Europe")
		if req_gender == REQ_GENDER_MAN:
			lines.append("Man only")
		elif req_gender == REQ_GENDER_WOMAN:
			lines.append("Woman only")
		return lines

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
		if cols.size() > COL_NAME_STRID:
			item.name_strid = cols[COL_NAME_STRID].strip_edges()
		var stack := _int_at(cols, COL_MAX_STACK)
		if stack > 0:
			item.max_stack = stack
		item.sell_price = _int_at(cols, COL_SELL_PRICE)
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
		item.durability = _int_at(cols, COL_DURABILITY)
		item.phys_atk = Vector2i(_int_at(cols, COL_PHYS_ATK_MIN), _int_at(cols, COL_PHYS_ATK_MAX))
		item.mag_atk = Vector2i(_int_at(cols, COL_MAG_ATK_MIN), _int_at(cols, COL_MAG_ATK_MAX))
		item.phys_reinforce = Vector2i(_int_at(cols, COL_PHYS_REINFORCE_MIN), _int_at(cols, COL_PHYS_REINFORCE_MAX))
		item.mag_reinforce = Vector2i(_int_at(cols, COL_MAG_REINFORCE_MIN), _int_at(cols, COL_MAG_REINFORCE_MAX))
		item.attack_rate = _int_at(cols, COL_ATTACK_RATE)
		item.critical = _int_at(cols, COL_CRITICAL)
		item.phys_def = Vector2(_float_at(cols, COL_PHYS_DEF_MIN), _float_at(cols, COL_PHYS_DEF_MAX))
		item.mag_def = Vector2(_float_at(cols, COL_MAG_DEF_MIN), _float_at(cols, COL_MAG_DEF_MAX))
		item.block = Vector2(_float_at(cols, COL_BLOCK_MIN), _float_at(cols, COL_BLOCK_MAX))
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

## A float column (armour defence values are written like "2.5"), or 0.
static func _float_at(cols: PackedStringArray, col: int) -> float:
	if col >= cols.size():
		return 0.0
	var text := cols[col].strip_edges()
	return float(text) if text.is_valid_float() else 0.0

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
