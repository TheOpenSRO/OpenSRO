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
## KeepingFee (round 728): the warehouse fee a unit. The column is READ on the
## server (RefObjCommon_ExtractData gs:0x6a3090 -> ref +0xac; round 728
## review); the client's deposit box reads its reference's +0xcc (0x6b1002),
## not separately mapped.
const COL_KEEPING_FEE := 30
## MaxStack (column 57): 1 for equipment, the real per-item cap for stackables
## (a potion 5000, arrows 2500) -- so the shop can offer buying a stack.
const COL_MAX_STACK := 57
const COL_TYPE_ID1 := 9
## CashItem and Bionic: bits 0 and 1 of the type word the TypeIDs pack into
## (docs/protocol/characterdata.md, cols 7-12 -> +0x00).
const COL_CASH_ITEM := 7
const COL_BIONIC := 8
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
## Range: a weapon's reach in world units (tenths of a metre) -- the item
## ref's u16 at +0x224, which Char_PublishCombatStats publishes as param 33
## and the attack tick adds to the two BCRadius values
## (CGCharAutoCommandActor::Tick_Attack 0x004ad8e0; round 247). Retail rows
## read sword/blade 6, spear/glaive 18, bow/crossbow 180, dagger 3. The same
## column the server's exporter reads (export-refdata fRange = 94).
const COL_RANGE := 94
## Param1, itemdata column 118 (the export's fParam1).
const COL_PARAM1 := 118
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
	## KeepingFee (column 30, READ): the warehouse deposit fee a unit.
	var keeping_fee: int = 0
	## Archive path of the inventory icon, ICON_PREFIX already applied.
	var icon_path: String
	## The `.bsr` the item is worn as, as the table writes it (no `res\`
	## prefix). Empty for an item with no worn model -- consumables, and a
	## few equipment rows that write `xxx`.
	var model_path: String
	## Every model the column lists, in file order. Almost every row names
	## one; 88 Degree-11 SET_A/SET_B rows name two, comma-separated
	## (`heavy_11_set_b_ba.bsr,heavy_11_set_b_ba_fullset.bsr`). READ in the
	## client (round 626): the row parser (GlobalDataManager::FUN_00972910)
	## splits the column on "," into a list and makes element [0] the drawn
	## model; FUN_00a60c60 switches a worn item to element [1] only while the
	## whole set (refsetitemgroup) is worn, and back to [0] when any piece
	## comes off. model_path is element [0]; the full-set switch is OPEN here.
	var model_paths: PackedStringArray = PackedStringArray()
	## The `.bsr` drawn when the item lies on the ground.
	var drop_model_path: String
	## TypeID1..4 -- the game's own classification, four levels deep.
	var type_ids: PackedInt32Array = PackedInt32Array()
	## CashItem (column 7) and Bionic (column 8), the type word's bits 0 and 1.
	var cash_item: int = 0
	var bionic: int = 0
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
	## The weapon's reach (COL_RANGE), world units; 0 for a non-weapon or a
	## row too short to carry the column.
	var attack_range: int = 0
	## Param1 (column 118; round 632 review): a composite item's (the Energy
	## of life scroll's) duration in seconds, which retail's item-grant
	## gauge reads as its total (ref+0x2b4 x 1000). 0 when the row is short.
	var param1: int = 0
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
	## Otherwise "" -- never an id. A name the table resolves is shown as the
	## client shows it, even when the key's first row carries no English: the
	## client then draws that row's language column as it stands, typically
	## the "0" filler (UiTextTable.parse; the box archive's Rebecca Event Hats
	## read "0").
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
	## equippable shows durability, requirement, race and gender. The attack
	## distance is parsed (attack_range, which the approach walk uses) but no
	## line here prints it yet.
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
	var _pp := ParseProfile.t0()
	if _parse_native(data, into):
		ParseProfile.add("text.items", _pp)
		return into
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
		item.keeping_fee = _int_at(cols, COL_KEEPING_FEE)
		var icon := _find_icon_path(cols)
		if icon != "":
			item.icon_path = ICON_PREFIX + icon
		item.model_paths = _models_at(cols, COL_MODEL)
		item.model_path = item.model_paths[0] if not item.model_paths.is_empty() else ""
		item.drop_model_path = _model_at(cols, COL_DROP_MODEL)
		for col in range(COL_TYPE_ID1, COL_TYPE_ID4 + 1):
			item.type_ids.append(_int_at(cols, col))
		item.cash_item = _int_at(cols, COL_CASH_ITEM)
		item.bionic = _int_at(cols, COL_BIONIC)
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
		item.attack_range = _int_at(cols, COL_RANGE)
		item.param1 = _int_at(cols, COL_PARAM1)
		item.phys_def = Vector2(_float_at(cols, COL_PHYS_DEF_MIN), _float_at(cols, COL_PHYS_DEF_MAX))
		item.mag_def = Vector2(_float_at(cols, COL_MAG_DEF_MIN), _float_at(cols, COL_MAG_DEF_MAX))
		item.block = Vector2(_float_at(cols, COL_BLOCK_MIN), _float_at(cols, COL_BLOCK_MAX))
		# A row with neither a name nor an icon tells the player nothing.
		if item.item_name == "" and item.icon_path == "":
			continue
		into[item.id] = item
	ParseProfile.add("text.items", _pp)
	return into

## The loop above, its row work done by the native port (round 671; native/
## src/core/tables.rs `items`): every kept row's fields come back as columns,
## and each Item is built from them here, field for field as above, merged into
## `into` in file order (a later duplicate id replaces an earlier one, as
## above). False when there is no library or the port handed the table back.
static func _parse_native(data: PackedByteArray, into: Dictionary) -> bool:
	var rows := NativeAssets.table_rows("items", [data])
	if rows.is_empty():
		return false
	var ids: PackedInt64Array = rows["ids"]
	var code_names: PackedStringArray = rows["code_names"]
	var item_names: PackedStringArray = rows["item_names"]
	var name_strids: PackedStringArray = rows["name_strids"]
	var icon_paths: PackedStringArray = rows["icon_paths"]
	var drop_models: PackedStringArray = rows["drop_models"]
	var models: PackedStringArray = rows["models"]
	var model_counts: PackedInt64Array = rows["model_counts"]
	var max_stacks: PackedInt64Array = rows["max_stacks"]
	var sell_prices: PackedInt64Array = rows["sell_prices"]
	# Round 728: a library from before this column has none (fee 0).
	var keeping_fees: PackedInt64Array = rows.get("keeping_fees", PackedInt64Array())
	var countries: PackedInt64Array = rows["countries"]
	var req_genders: PackedInt64Array = rows["req_genders"]
	var durabilities: PackedInt64Array = rows["durabilities"]
	var attack_rates: PackedInt64Array = rows["attack_rates"]
	var criticals: PackedInt64Array = rows["criticals"]
	var ranges: PackedInt64Array = rows["ranges"]
	var param1s: PackedInt64Array = rows["param1s"]
	var type_ids: PackedInt64Array = rows["type_ids"]
	# Round 726: a library from before these two columns has neither; such a
	# library's rows read as 0 (no cash item, not bionic).
	var cash_items: PackedInt64Array = rows.get("cash_items", PackedInt64Array())
	var bionics: PackedInt64Array = rows.get("bionics", PackedInt64Array())
	var req_types: PackedInt64Array = rows["req_types"]
	var req_levels: PackedInt64Array = rows["req_levels"]
	var attacks: PackedInt64Array = rows["attacks"]
	var defences: PackedFloat64Array = rows["defences"]
	var m := 0
	for i in ids.size():
		var item := Item.new()
		item.id = ids[i]
		item.code_name = code_names[i]
		item.item_name = item_names[i]
		item.name_strid = name_strids[i]
		item.max_stack = max_stacks[i]
		item.sell_price = sell_prices[i]
		if i < keeping_fees.size():
			item.keeping_fee = keeping_fees[i]
		item.icon_path = icon_paths[i]
		var count: int = model_counts[i]
		item.model_paths = models.slice(m, m + count)
		m += count
		item.model_path = item.model_paths[0] if not item.model_paths.is_empty() else ""
		item.drop_model_path = drop_models[i]
		for k in range(4):
			item.type_ids.append(type_ids[i * 4 + k])
		if i < cash_items.size():
			item.cash_item = cash_items[i]
		if i < bionics.size():
			item.bionic = bionics[i]
		item.country = countries[i]
		item.req_gender = req_genders[i]
		for pair in range(REQ_LEVEL_PAIRS):
			item.req_level_types.append(req_types[i * REQ_LEVEL_PAIRS + pair])
			item.req_levels.append(req_levels[i * REQ_LEVEL_PAIRS + pair])
		item.durability = durabilities[i]
		var a := i * 8
		item.phys_atk = Vector2i(attacks[a], attacks[a + 1])
		item.mag_atk = Vector2i(attacks[a + 2], attacks[a + 3])
		item.phys_reinforce = Vector2i(attacks[a + 4], attacks[a + 5])
		item.mag_reinforce = Vector2i(attacks[a + 6], attacks[a + 7])
		item.attack_rate = attack_rates[i]
		item.critical = criticals[i]
		item.attack_range = ranges[i]
		item.param1 = param1s[i]
		var d := i * 6
		item.phys_def = Vector2(defences[d], defences[d + 1])
		item.mag_def = Vector2(defences[d + 2], defences[d + 3])
		item.block = Vector2(defences[d + 4], defences[d + 5])
		into[item.id] = item
	return true

## A `.bsr` path in the column the layout puts it in, or "" for the `xxx`
## the table writes where a row has no model -- checked by extension so a
## part with a shifted layout yields nothing rather than a wrong path.
static func _model_at(cols: PackedStringArray, col: int) -> String:
	if col >= cols.size():
		return ""
	var value := cols[col].strip_edges()
	return value.replace("/", "\\") if value.to_lower().ends_with(".bsr") else ""

## The column's `.bsr` paths, comma-separated as the client splits it
## (round 626, see Item.model_paths): each token passes _model_at's own
## test, so `xxx` or a stray token yields nothing. Until round 626 the whole
## "a.bsr,b.bsr" string was taken as one path, which is no file, so a set
## chest drew nothing.
static func _models_at(cols: PackedStringArray, col: int) -> PackedStringArray:
	var out := PackedStringArray()
	if col >= cols.size():
		return out
	for token in cols[col].split(",", false):
		var one := _model_at(PackedStringArray([token]), 0)
		if one != "":
			out.append(one)
	return out

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
	var _pp := ParseProfile.t0()
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var text := raw.get_string_from_utf16()
	if text.is_empty():
		text = raw.get_string_from_utf8()
	var _out := text.replace("\r", "").split("\n")
	ParseProfile.add("text.decode_split", _pp, data.size())
	return _out
