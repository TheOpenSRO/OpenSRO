extends SceneTree

## Round 778: the window title, "[<character>] <server>" in the world.
##   godot4 --headless --path client --script res://scripts/ui/window_title_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_check(WindowTitle.in_world("deadass3", "OldSRO") == "[deadass3] OldSRO", "the user's example")
	_check(WindowTitle.in_world("deadass3", "") == "[deadass3] OpenSRO", "no server entry: the project's name")
	_check(WindowTitle.in_world("", "OldSRO") == "OldSRO", "no character: the server alone")
	_check(WindowTitle.in_world(" deadass3 ", " OldSRO ") == "[deadass3] OldSRO", "spaces trimmed")
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
