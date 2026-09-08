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

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)
