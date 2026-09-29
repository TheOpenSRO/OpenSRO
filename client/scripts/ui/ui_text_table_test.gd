extends SceneTree

const UiTextTable = preload("res://scripts/ui/ui_text_table.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	# Test with synthetic UTF-16LE data
	var s1 := "1\tUIIT_STT_GOLD\t금\t\t\t\t\t\tGold\n1\tUIIS_CTL_EXIT\t종료\t\t\t\t\t\tExit\n"
	var bytes := s1.to_utf16_buffer()

	var table := UiTextTable.parse(bytes)
	_check(table.count() == 2, "parsed 2 tokens")
	_check(table.has("UIIT_STT_GOLD"), "has UIIT_STT_GOLD")
	_check(table.get_text("UIIT_STT_GOLD") == "Gold", "UIIT_STT_GOLD resolves to Gold (got %s)" % table.get_text("UIIT_STT_GOLD"))
	_check(table.get_text("UIIS_CTL_EXIT") == "Exit", "UIIS_CTL_EXIT resolves to Exit (got %s)" % table.get_text("UIIS_CTL_EXIT"))
	_check(table.get_text("NON_EXISTENT") == "NON_EXISTENT", "fallback to token itself")
	_check(table.get_text("NON_EXISTENT", "Default") == "Default", "fallback to custom default")

	# The real file's shape, which the fixed-column reader got wrong. Two
	# rows for the same token, of different widths, where the conventional
	# English column holds the "0" filler in the wider one -- taken
	# verbatim from a real textuisystem.txt.
	var varying := PackedStringArray([
		"1\tUIIT_STT_PHYSICAL_ATTACK\t\u1355\t0\t0\t0\t0\t0\tPhy. Atk:\tPhy. Atk:\t0\t0\t0\t0\t0\t0",
		"1\tUIIT_STT_PHYSICAL_ATTACK\t\u1355\t0\t0\t0\t0\t0\t0\tPhy. atk\t0\t0\t0\t0\t0\t0\t0\t0\t0",
		"1\tUIIT_STT_HIT_RATIO\t\u1355\t0\t0\t0\t0\t0\t0\tHit rate\t0\t0\t0\t0\t0\t0\t0\t0\t0",
	])
	var varying_table := UiTextTable.parse(("\n".join(varying)).to_utf16_buffer())
	# The FIRST row for a key wins, as the client's loader keeps it (round
	# 634's review: 0x8ca120's insert returns the existing entry).
	_check(varying_table.get_text("UIIT_STT_PHYSICAL_ATTACK") == "Phy. Atk:",
		"the first row of a duplicated key wins (got %s)" % varying_table.get_text("UIIT_STT_PHYSICAL_ATTACK"))
	var script: Script = load("res://scripts/ui/ui_text_table.gd")
	var parse_args := 0
	for m in script.get_script_method_list():
		if m["name"] == "parse":
			parse_args = (m["args"] as Array).size()
	if parse_args >= 3:
		var last_table = script.call("parse", ("\n".join(varying)).to_utf16_buffer(), 8, false)
		_check(last_table.get_text("UIIT_STT_PHYSICAL_ATTACK") == "Phy. atk",
			"picks the English column even when it moves; keep_first false keeps the last row (got %s)" % last_table.get_text("UIIT_STT_PHYSICAL_ATTACK"))
	else:
		_check(false, "parse takes keep_first (the old last-row rule as an option)")
	var dup := PackedStringArray([
		"1\tUIIT_CTL_CHATMENU_TRAININGCAMP\t&???\t0\t0\t0\t0\t0\t&Team\t&Team\t0",
		"1\tUIIT_CTL_CHATMENU_TRAININGCAMP\t&x\t0\t0\t0\t0\t0\t0\t&Academy\t0",
	])
	var dup_table := UiTextTable.parse(("\n".join(dup)).to_utf16_buffer())
	_check(dup_table.get_text("UIIT_CTL_CHATMENU_TRAININGCAMP") == "&Team",
		"the private archive's first row is what the table holds (got %s)" % dup_table.get_text("UIIT_CTL_CHATMENU_TRAININGCAMP"))
	_check(varying_table.get_text("UIIT_STT_HIT_RATIO") == "Hit rate",
		"a row whose column 8 is the \"0\" filler still resolves (got %s)" % varying_table.get_text("UIIT_STT_HIT_RATIO"))

	# A multi-language archive: English in column 8 with Spanish and Arabic
	# to its right, a row whose column 8 is the filler and whose English
	# sits at 9 ahead of a Vietnamese column, and a name whose Arabic column
	# also carries the Latin name. Each must come out English -- the old
	# rightmost-first rule labelled every NPC in Jangan in Arabic or Spanish
	# on such an archive.
	var multi := PackedStringArray([
		"1\tSN_NPC_ARENA\tፕ\t0\t0\t0\t0\t0\tArena Manager\t0\tAdministrador de Arena\tمدير\t0",
		"1\tSN_ITEM_BOX\tፕ\t0\t0\t0\t0\t0\t0\tJewel Box\t0\tHép b¸u vËt\t0",
		"1\tSN_NPC_DANGSAM\tፕ\t0\t0\t0\t0\t0\tSoldier Dangsam\t0\t0\tDangsam الجندي\t0",
	])
	var multi_table := UiTextTable.parse(("\n".join(multi)).to_utf16_buffer())
	_check(multi_table.get_text("SN_NPC_ARENA") == "Arena Manager",
		"column 8 wins over a Spanish column to its right (got %s)" % multi_table.get_text("SN_NPC_ARENA"))
	_check(multi_table.get_text("SN_ITEM_BOX") == "Jewel Box",
		"the first Latin field after a filler column 8 wins over a later Vietnamese one (got %s)" % multi_table.get_text("SN_ITEM_BOX"))
	_check(multi_table.get_text("SN_NPC_DANGSAM") == "Soldier Dangsam",
		"an Arabic column carrying the Latin name does not beat column 8 (got %s)" % multi_table.get_text("SN_NPC_DANGSAM"))

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)
