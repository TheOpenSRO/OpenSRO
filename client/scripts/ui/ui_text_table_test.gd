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
	_check(varying_table.get_text("UIIT_STT_PHYSICAL_ATTACK") == "Phy. atk",
		"picks the English column even when it moves (got %s)" % varying_table.get_text("UIIT_STT_PHYSICAL_ATTACK"))
	_check(varying_table.get_text("UIIT_STT_HIT_RATIO") == "Hit rate",
		"a row whose column 8 is the \"0\" filler still resolves (got %s)" % varying_table.get_text("UIIT_STT_HIT_RATIO"))

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)
