extends SceneTree

## Exercises MasteryReader against synthetic rows shaped like the real
## skillmasterydata.txt (never real game data):
##   godot4 --headless --path client --script res://scripts/npc/mastery_reader_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A row with the fields at the columns MasteryReader reads.
func _row(id: String, name_code: String, tab: String, w1: String, w2: String, icon: String) -> String:
	var cols := PackedStringArray()
	cols.resize(13)
	cols.fill("0")
	cols[MasteryReader.COL_ID] = id
	cols[MasteryReader.COL_NAME_CODE] = name_code
	cols[MasteryReader.COL_TAB] = tab
	cols[MasteryReader.COL_WEAPON_TYPE_1] = w1
	cols[MasteryReader.COL_WEAPON_TYPE_1 + 1] = w2
	cols[MasteryReader.COL_ICON] = icon
	return "\t".join(cols)

func _init() -> void:
	var rows := PackedStringArray([
		"// a comment row the real file carries",
		_row("257", "UIIT_STT_MASTERY_VI", "0", "2", "3", "icon\\skillmastery\\china\\mastery_sword.ddj"),
		_row("258", "UIIT_STT_MASTERY_HEUK", "0", "4", "5", "icon\\skillmastery\\china\\mastery_spear.ddj"),
		_row("259", "UIIT_STT_MASTERY_PA", "0", "6", "0", "icon\\skillmastery\\china\\mastery_bow.ddj"),
		_row("273", "UIIT_STT_MASTERY_HAN", "1", "0", "0", "icon\\skillmastery\\china\\mastery_cold.ddj"),
		# Europe -- a china-only parse must drop it.
		_row("513", "UIIT_STT_WARRIOR", "0", "7", "8", "icon\\skillmastery\\europe\\eu_warrior.ddj"),
	])
	var masteries := MasteryReader.parse_china(("\n".join(rows) + "\n").to_utf16_buffer())
	_check(masteries.size() == 4, "four China masteries parsed, the comment and Europe dropped (got %d)" % masteries.size())
	if masteries.size() == 4:
		# Weapon tab first, in file order, then the force mastery.
		_check(masteries[0].id == 257 and masteries[3].id == 273,
			"weapon masteries come before force ones (got %d..%d)" % [masteries[0].id, masteries[3].id])
		_check(masteries[0].icon_path == "icon\\skillmastery\\china\\mastery_sword.ddj",
			"the icon path is the table's own full path (got %s)" % masteries[0].icon_path)
		_check(masteries[0].weapon_types == PackedInt32Array([2, 3]),
			"the trained weapon types are read (got %s)" % str(masteries[0].weapon_types))
		# With no text table, the name falls back to the weapons trained.
		_check(masteries[0].display_name(null) == "Sword / Blade Mastery",
			"a mastery with no resolvable name labels by its weapons (got %s)" % masteries[0].display_name(null))
		# With a text table that resolves the code, that wins.
		var names := UiTextTable.parse("1\tUIIT_STT_MASTERY_VI\t승\t\t\t\t\t\tBicheon\n".to_utf16_buffer())
		_check(masteries[0].display_name(names) == "Bicheon",
			"a resolvable name is used (got %s)" % masteries[0].display_name(names))

	# Round 691: the same table read for a Europe character.
	var eu_rows := PackedStringArray([
		_row("257", "UIIT_STT_MASTERY_VI", "0", "2", "3", "icon\\skillmastery\\china\\mastery_sword.ddj"),
		_row("513", "UIIT_STT_WARRIOR", "0", "7", "8", "icon\\skillmastery\\europe\\eu_warrior.ddj"),
		_row("515", "UIIT_STT_ROG", "0", "11", "12", "icon\\skillmastery\\europe\\eu_rog.ddj"),
		_row("514", "UIIT_STT_WIZARD", "1", "11", "0", "icon\\skillmastery\\europe\\eu_wizard.ddj"),
		_row("518", "UIIT_STT_CLERIC", "2", "10", "0", "icon\\skillmastery\\europe\\eu_cleric.ddj"),
	])
	var eu := MasteryReader.parse_race(("\n".join(eu_rows) + "\n").to_utf16_buffer(), MasteryReader.RACE_EUROPE)
	var eu_ids: Array = []
	for m in eu:
		eu_ids.append((m as MasteryReader.Mastery).id)
	_check(eu_ids == [513, 515, 514, 518], "a Europe parse keeps Europe's masteries by tab then id, no China (got %s)" % str(eu_ids))
	if eu.size() == 4:
		# Europe's names live in textdata_equip&skill.txt: the second table.
		var ui := UiTextTable.parse("1\tUIIT_STT_MASTERY_VI\t승\t\t\t\t\t\tBicheon\n".to_utf16_buffer())
		var sk := UiTextTable.parse("1\tUIIT_STT_WARRIOR\t워\t\t\t\t\t\tWarrior\n".to_utf16_buffer())
		_check(eu[0].display_name(ui, sk) == "Warrior", "a Europe name resolves through the second table (got %s)" % eu[0].display_name(ui, sk))
		_check(eu[3].display_name(null) == "Dark Staff Mastery", "with no table it labels by its weapons (got %s)" % eu[3].display_name(null))

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
