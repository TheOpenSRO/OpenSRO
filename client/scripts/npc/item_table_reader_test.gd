extends SceneTree

## Exercises ItemTableReader against synthetic rows shaped like the real
## tables (never real game data):
##   godot4 --headless --path client --script res://scripts/npc/item_table_reader_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A real itemdata row is ~160 columns and carries three resource paths --
## two `.bsr` models and one `.ddj` icon -- which is why the icon is found
## by extension rather than by index.
func _row(id: String, item_name: String, icon: String, icon_col: int,
		model := "item\\china\\man_item\\clothes_01_ba.bsr") -> String:
	var cols := PackedStringArray()
	cols.resize(160)
	cols.fill("0")
	cols[0] = "1"
	cols[ItemTableReader.COL_ID] = id
	cols[ItemTableReader.COL_CODE_NAME] = "ITEM_CH_M_CLOTHES_01_BA_A_RARE"
	cols[ItemTableReader.COL_NAME] = item_name
	# The classification and requirement columns as a real Cotton Suit
	# row carries them: type ids 3/1/1/3, China, man, character level 1.
	cols[9] = "3"
	cols[10] = "1"
	cols[11] = "1"
	cols[12] = "3"
	cols[ItemTableReader.COL_COUNTRY] = "0"
	cols[ItemTableReader.COL_REQ_LEVEL_TYPE1] = "1"
	cols[ItemTableReader.COL_REQ_LEVEL1] = "1"
	cols[34] = "-1"
	cols[36] = "-1"
	cols[38] = "-1"
	cols[52] = model
	cols[53] = "item\\etc\\drop_ch_equip_rare.bsr"
	cols[ItemTableReader.COL_REQ_GENDER] = "1"
	if icon != "":
		cols[icon_col] = icon
	return "\t".join(cols)

func _init() -> void:
	var text := "\t".join(PackedStringArray(["//", "a comment row"])) + "\n" \
		+ _row("4842", "Cotton Suit", "item\\china\\man_item\\clothes_01_ba.ddj", 54) + "\n" \
		+ _row("4734", "Cotton Hat", "item\\china\\man_item\\clothes_01_ha.ddj", 61) + "\n" \
		+ _row("9999", "", "", 54) + "\n"
	var items := ItemTableReader.parse(text.to_utf16_buffer())

	_check(items.size() == 2, "two items parsed, the comment and the empty row skipped (got %d)" % items.size())

	var suit: ItemTableReader.Item = items.get(4842)
	_check(suit != null, "item 4842 present")
	if suit != null:
		_check(suit.item_name == "Cotton Suit", "name round-trips (got %s)" % suit.item_name)
		# The icon path in the table is relative; the file lives under icon\.
		_check(suit.icon_path == "icon\\item\\china\\man_item\\clothes_01_ba.ddj",
			"icon path is prefixed with icon\\ (got %s)" % suit.icon_path)

	# The icon column moves between parts, so it is found by extension. The
	# two .bsr paths in the same row must not be mistaken for it.
	var hat: ItemTableReader.Item = items.get(4734)
	_check(hat != null and hat.icon_path.ends_with("clothes_01_ha.ddj"),
		"an icon in a different column is still found (got %s)" % (hat.icon_path if hat != null else "-"))
	_check(hat != null and not hat.icon_path.ends_with(".bsr"),
		"a model path is not mistaken for the icon")

	# The server's own starting kit ids -- the table's `_A_DEF` rows -- must
	# be resolvable, or a new character's inventory shows unnamed rows.
	var kit_rows := PackedStringArray()
	for pair in [["3643", "Cotton Suit"], ["3644", "Cotton Trousers"], ["3645", "Cotton Shoes"],
			["3632", "Copper Sword"]]:
		kit_rows.append(_row(pair[0], pair[1], "item\\china\\man_item\\x.ddj", 54))
	var kit_items := ItemTableReader.parse(("\n".join(kit_rows) + "\n").to_utf16_buffer())
	_check(kit_items.size() == 4, "the four starting-kit ids all parse (got %d)" % kit_items.size())

	# The worn model and who may wear it, by column -- the game's own
	# _RefObjCommon layout, checked against real rows.
	if suit != null:
		_check(suit.model_path == "item\\china\\man_item\\clothes_01_ba.bsr",
			"column 52 is the model the item is worn as (got %s)" % suit.model_path)
		_check(suit.drop_model_path == "item\\etc\\drop_ch_equip_rare.bsr",
			"column 53 is the model it lies on the ground as (got %s)" % suit.drop_model_path)
		_check(suit.is_equipment(), "an item with a worn model is equipment")
		_check(suit.code_name == "ITEM_CH_M_CLOTHES_01_BA_A_RARE", "the code name is kept (got %s)" % suit.code_name)
		_check(suit.type_ids == PackedInt32Array([3, 1, 1, 3]), "type ids 1-4 are columns 9-12 (got %s)" % str(suit.type_ids))
		_check(suit.country == 0 and suit.req_gender == ItemTableReader.REQ_GENDER_MAN,
			"country and required gender are columns 14 and 58 (got %d, %d)" % [suit.country, suit.req_gender])
		_check(suit.req_level_types == PackedInt32Array([1, -1, -1, -1]) and suit.req_levels == PackedInt32Array([1, 0, 0, 0]),
			"the four requirement pairs are columns 32-39 (got %s / %s)" % [str(suit.req_level_types), str(suit.req_levels)])
		_check(suit.required_character_level() == 1,
			"a type-1 pair is the character's own level (got %d)" % suit.required_character_level())

	# A row that writes `xxx` where its model would be is not equipment --
	# the Cotton Hood does exactly that -- and no `.bsr` is invented for it.
	var hood: ItemTableReader.Item = ItemTableReader.parse(_row("4770", "Cotton Hood", "item\\china\\man_item\\clothes_01_ca.ddj", 54, "xxx").to_utf16_buffer()).get(4770)
	_check(hood != null and hood.model_path == "" and not hood.is_equipment(),
		"a row with xxx for a model has no model (got %s)" % (hood.model_path if hood != null else "-"))

	# A weapon's stat columns, with the real Copper Sword's own values in
	# the verified positions: base physical attack 15~16, magical 25~28,
	# durability 62, attack rate 24, critical 3, phys reinforce 306/342,
	# mag reinforce 519/591. These are the exact figures its real +5
	# tooltip showed (growth backed out), so the tooltip lines must read
	# them out unchanged.
	var w := PackedStringArray()
	w.resize(160)
	w.fill("0")
	w[ItemTableReader.COL_ID] = "3632"
	w[ItemTableReader.COL_CODE_NAME] = "ITEM_CH_SWORD_01_A_DEF"
	w[ItemTableReader.COL_NAME] = "Copper Sword"
	w[ItemTableReader.COL_TYPE_ID1] = "3"
	w[11] = "6" # TypeID3 = weapon family
	w[ItemTableReader.COL_TYPE_ID4] = "2" # sword
	w[ItemTableReader.COL_COUNTRY] = "0"
	w[ItemTableReader.COL_REQ_LEVEL_TYPE1] = "1"
	w[ItemTableReader.COL_REQ_LEVEL1] = "1"
	w[ItemTableReader.COL_REQ_GENDER] = "2"
	w[54] = "item\\china\\weapon\\sword_01.ddj"
	w[ItemTableReader.COL_DURABILITY] = "62"
	w[ItemTableReader.COL_PHYS_ATK_MIN] = "15"
	w[ItemTableReader.COL_PHYS_ATK_MAX] = "16"
	w[ItemTableReader.COL_MAG_ATK_MIN] = "25"
	w[ItemTableReader.COL_MAG_ATK_MAX] = "28"
	w[ItemTableReader.COL_PHYS_REINFORCE_MIN] = "306"
	w[ItemTableReader.COL_PHYS_REINFORCE_MAX] = "342"
	w[ItemTableReader.COL_MAG_REINFORCE_MIN] = "519"
	w[ItemTableReader.COL_MAG_REINFORCE_MAX] = "591"
	w[ItemTableReader.COL_ATTACK_RATE] = "24"
	w[ItemTableReader.COL_CRITICAL] = "3"
	var sword: ItemTableReader.Item = ItemTableReader.parse(("\t".join(w) + "\n").to_utf16_buffer()).get(3632)
	_check(sword != null and sword.is_weapon(), "the sword parses and is a weapon")
	if sword != null:
		_check(sword.phys_atk == Vector2i(15, 16), "physical attack 15~16 (got %s)" % str(sword.phys_atk))
		_check(sword.mag_atk == Vector2i(25, 28), "magical attack 25~28 (got %s)" % str(sword.mag_atk))
		_check(sword.durability == 62 and sword.attack_rate == 24 and sword.critical == 3, "durability, rate, critical")
		_check(sword.phys_reinforce == Vector2i(306, 342), "phys reinforce tenths (got %s)" % str(sword.phys_reinforce))
		var lines := sword.tooltip_lines()
		var joined := "\n".join(PackedStringArray(lines))
		_check(joined.contains("Phy. atk. pwr. 15 ~ 16"), "tooltip shows physical attack (got: %s)" % joined)
		_check(joined.contains("Mag. reinforce 51.9 % ~ 59.1 %"), "tooltip shows mag reinforce as a percent (got: %s)" % joined)
		_check(joined.contains("Sort of item: Sword") and joined.contains("Required level 1"), "tooltip shows sort and required level")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
