extends SceneTree

## Exercises ShopReader against synthetic shop tables shaped like the real ones
## (never real game data): the six-table chain from an NPC to the item codenames
## its shop sells.
##   godot4 --headless --path client --script res://scripts/npc/shop_reader_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A tab-separated row from {column index: value}, padded so the highest index
## exists. Encoded UTF-16LE like the real textdata.
func _row(fields: Dictionary) -> String:
	var maxc := 0
	for k in fields:
		maxc = maxi(maxc, int(k))
	var cols := PackedStringArray()
	cols.resize(maxc + 1)
	cols.fill("0")
	for k in fields:
		cols[int(k)] = str(fields[k])
	return "\t".join(cols)

func _bytes(rows: Array) -> PackedByteArray:
	return ("\n".join(PackedStringArray(rows))).to_utf16_buffer()

func _init() -> void:
	# The smith chain: two tabs (weapon, shield); weapon sells two blades whose
	# goods rows are deliberately out of slot order to test the sort.
	var tables := {
		ShopReader.T_SHOPGROUP: _bytes([
			"// a comment line is skipped",
			_row({3: "GROUP_STORE_CH_SMITH", 4: "NPC_CH_SMITH"}),
		]),
		ShopReader.T_MAPGROUP: _bytes([
			_row({2: "GROUP_STORE_CH_SMITH", 3: "STORE_CH_SMITH"}),
		]),
		ShopReader.T_MAPTAB: _bytes([
			_row({2: "STORE_CH_SMITH", 3: "STORE_CH_SMITH_GROUP1"}),
		]),
		ShopReader.T_TAB: _bytes([
			_row({3: "STORE_CH_SMITH_TAB1", 4: "STORE_CH_SMITH_GROUP1", 5: "SN_TAB_WEAPON"}),
			_row({3: "STORE_CH_SMITH_TAB2", 4: "STORE_CH_SMITH_GROUP1", 5: "SN_TAB_SHIELD"}),
		]),
		ShopReader.T_GOODS: _bytes([
			# slot 1 then slot 0 -- out of order on purpose.
			_row({2: "STORE_CH_SMITH_TAB1", 3: "PACKAGE_ITEM_CH_BLADE_02_A", 4: "1"}),
			_row({2: "STORE_CH_SMITH_TAB1", 3: "PACKAGE_ITEM_CH_BLADE_01_A", 4: "0"}),
			_row({2: "STORE_CH_SMITH_TAB2", 3: "PACKAGE_ITEM_CH_SHIELD_01_A", 4: "0"}),
		]),
		ShopReader.T_SCRAP: _bytes([
			_row({2: "PACKAGE_ITEM_CH_BLADE_01_A", 3: "ITEM_CH_BLADE_01_A"}),
			_row({2: "PACKAGE_ITEM_CH_BLADE_02_A", 3: "ITEM_CH_BLADE_02_A"}),
			_row({2: "PACKAGE_ITEM_CH_SHIELD_01_A", 3: "ITEM_CH_SHIELD_01_A"}),
		]),
	}

	var reader := ShopReader.new().load(func(p: String) -> PackedByteArray:
		return tables.get(p, PackedByteArray()))

	_check(reader.has_shop("NPC_CH_SMITH"), "the smith runs a shop")
	_check(reader.has_shop("npc_ch_smith"), "has_shop is case-insensitive")
	_check(not reader.has_shop("NPC_CH_POTION"), "an NPC not in the table has no shop")

	var tabs := reader.tabs_for("NPC_CH_SMITH")
	_check(tabs.size() == 2, "the smith has two tabs (got %d)" % tabs.size())
	if tabs.size() == 2:
		_check(tabs[0].name_strid == "SN_TAB_WEAPON", "first tab is the weapon tab (got %s)" % tabs[0].name_strid)
		_check(tabs[1].name_strid == "SN_TAB_SHIELD", "second tab is the shield tab (got %s)" % tabs[1].name_strid)
		var weapon: PackedStringArray = tabs[0].item_codes
		_check(weapon.size() == 2, "the weapon tab has two goods (got %d)" % weapon.size())
		# Sorted by slot: blade 01 (slot 0) before blade 02 (slot 1).
		_check(weapon.size() == 2 and weapon[0] == "ITEM_CH_BLADE_01_A", "goods are in slot order, package resolved to item (got %s)" % (weapon[0] if weapon.size() > 0 else "-"))
		_check(weapon.size() == 2 and weapon[1] == "ITEM_CH_BLADE_02_A", "second good resolves too (got %s)" % (weapon[1] if weapon.size() > 1 else "-"))
		_check(tabs[1].item_codes.size() == 1 and tabs[1].item_codes[0] == "ITEM_CH_SHIELD_01_A", "the shield tab resolves its one good")

	_check(reader.tabs_for("NPC_CH_POTION").is_empty(), "an NPC with no shop has no tabs")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILURE(S)" % _failures)
	quit(_failures)
