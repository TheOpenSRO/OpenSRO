extends SceneTree

## Exercises LevelDataReader against SYNTHETIC rows shaped like the real
## leveldata.txt (level in column 0, the mastery cost in column 2, a trailing
## `//` copyright line) -- never real game data -- and the skill window's
## LEVEL UP gate that consumes it:
##   godot4 --headless --path client --script res://scripts/npc/level_data_reader_test.gd
##
## The costs are made up, except that level 20 costs 53 to mirror the value
## docs/RE_COMPLETION.md records for the real column; level 1 costs 7 so a
## pass cannot come from a real-looking default.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A ten-column row with the level and the mastery cost where the reader
## looks; every other column is filler.
func _row(level: String, cost: String) -> String:
	var cols := PackedStringArray()
	cols.resize(10)
	cols.fill("0")
	cols[LevelDataReader.COL_LEVEL] = level
	cols[LevelDataReader.COL_MASTERY_SP] = cost
	return "\t".join(cols)

func _init() -> void:
	var rows := PackedStringArray([
		"Level\tExp\tMasterySP\tx\tx\tExpUnit\tJ1\tJ2\tJ3\tx",   # a header row
		_row("1", "7"),
		_row("20", "53"),
		_row("21", "abc"),   # column 2 not an integer
		_row("121", "99"),   # past the cost loop's bound
		"",
		"//Copyright line, as the real file ends",
	])
	# UTF-16LE with its BOM, the way the archive stores the table.
	var data := PackedByteArray([0xFF, 0xFE]) + ("\r\n".join(rows) + "\r\n").to_utf16_buffer()
	var costs := LevelDataReader.parse_mastery_costs(data)

	_check(LevelDataReader.mastery_up_cost(costs, 20) == 53,
		"raising from level 20 costs column 2 of row 20 (got %d)" % LevelDataReader.mastery_up_cost(costs, 20))
	_check(LevelDataReader.mastery_up_cost(costs, 1) == 7,
		"raising from level 1 costs column 2 of row 1 (got %d)" % LevelDataReader.mastery_up_cost(costs, 1))
	# The first point is free: 0x59c628 skips the loop for a level-0 mastery.
	_check(LevelDataReader.mastery_up_cost(costs, 0) == 0,
		"a mastery's first point costs 0 (got %d)" % LevelDataReader.mastery_up_cost(costs, 0))
	_check(LevelDataReader.mastery_up_cost(costs, 21) == 0,
		"a non-integer column 2 gives 0, not a guess (got %d)" % LevelDataReader.mastery_up_cost(costs, 21))
	# No L + 1 fallback for a level the table lacks.
	_check(LevelDataReader.mastery_up_cost(costs, 5) == 0,
		"a missing row gives 0, not L + 1 (got %d)" % LevelDataReader.mastery_up_cost(costs, 5))
	_check(LevelDataReader.mastery_up_cost({}, 20) == 0, "an empty table gives 0")
	# Past 0x78 the loop breaks before summing, whatever the row says.
	_check(costs.get(121, 0) == 99, "row 121's column 2 is parsed (got %s)" % str(costs.get(121)))
	_check(LevelDataReader.mastery_up_cost(costs, 121) == 0,
		"raising from above 120 costs 0 even with a row present (got %d)" % LevelDataReader.mastery_up_cost(costs, 121))
	_check(LevelDataReader.MASTERY_COST_LAST_LEVEL == 120, "the cost loop's bound is 0x78 = 120")
	# Only the three integer rows make keys: no header, blank or comment key.
	var keys := costs.keys()
	keys.sort()
	_check(keys == [1, 20, 121], "only integer rows are keyed (got %s)" % str(keys))
	_check(LevelDataReader.parse_mastery_costs(PackedByteArray()).is_empty(), "no data gives no costs")

	# The gate and its wiring are in _initialize, below, which also reports.

## The LEVEL UP gate (HudPanels.mastery_levelup_block_reason) and its wiring.
##
## This runs here and not in _init: hud_panels.gd names the NetClient
## autoload, which a --script suite registers only after _init (round 514's
## measurement, recorded in npc_service_reader_test.gd's check (j)). The
## script is loaded by path and reached through has_method/call, so a HudPanels
## without the gate FAILS these checks rather than failing to parse, which
## would hang the suite.
func _initialize() -> void:
	var panels_script := load("res://scripts/ui/hud/hud_panels.gd") as GDScript
	var compiled := panels_script != null and panels_script.can_instantiate()
	_check(compiled, "HudPanels compiles in _initialize, once the NetClient autoload is registered")
	if compiled:
		var panels: Node = panels_script.new()
		var has_gate := panels.has_method("mastery_levelup_block_reason")
		_check(has_gate, "HudPanels has mastery_levelup_block_reason")
		var gate := func(real_level: int, char_level: int, total_now: int, total_cap: int,
				sp: int, cost: int) -> String:
			if not has_gate:
				return "<no gate>"
			return str(panels.call("mastery_levelup_block_reason", real_level, char_level,
				total_now, total_cap, sp, cost))

		# NEGATIVE: 5 SP against a 53-point raise. Before round 516 the button
		# only refused at 0 SP, so this was clickable and the server's 0x3802
		# came back unseen.
		var short: String = gate.call(20, 30, 20, 330, 5, 53)
		_check(short != "" and short.contains("53") and short != "<no gate>",
			"5 SP against a 53 cost is refused, naming the cost (got '%s')" % short)
		# cost == SP goes through: `jbe` at 0x59c69a.
		var exact: String = gate.call(20, 30, 20, 330, 53, 53)
		_check(exact == "", "53 SP against a 53 cost is allowed (got '%s')" % exact)
		# The character-level check comes before the skill points (0x3804 first).
		var capped: String = gate.call(20, 20, 20, 330, 100, 53)
		_check(capped.contains("character-level cap"),
			"a mastery at the character's level gives the level reason (got '%s')" % capped)
		# The total comes before both (0x3805 first).
		var full: String = gate.call(20, 20, 330, 330, 0, 53)
		_check(full.begins_with("Total mastery cap reached"),
			"a full total gives the total reason first (got '%s')" % full)
		# A mastery's first point is free (0x59c628 skips the 0x3802 check),
		# so no skill points is not a reason to grey it.
		var first: String = gate.call(0, 30, 0, 330, 0, 0)
		_check(first == "", "a level-0 mastery with 0 SP can take its first point (got '%s')" % first)
		var first_one: String = gate.call(0, 30, 0, 330, 1, 0)
		_check(first_one == "", "a level-0 mastery with 1 SP can take its first point (got '%s')" % first_one)
		# The existing no-points branch is unchanged for a raise that costs.
		var broke: String = gate.call(1, 30, 1, 330, 0, 0)
		_check(broke == "Not enough skill points.", "a level-1 mastery with 0 SP is refused (got '%s')" % broke)

		# The board reads the cost from the loaded table: LEVEL UP greys
		# with 5 SP at Bicheon 20 and lights with 53.
		panels.set("_level_mastery_costs", {20: 53})
		panels.set("_level_data_loaded", true)
		panels.set("_skill_char_level", 30)
		panels.set("_skill_mastery_levels", {257: 20})
		var mastery := MasteryReader.Mastery.new()
		mastery.id = 257
		for sp in [5, 53]:
			panels.set("_skill_points", sp)
			var board := Control.new()
			panels.call("_build_mastery_board", board, mastery)
			var btn := board.find_child("SkillMasteryLevelUp", true, false) as Button
			_check(btn != null, "the board has its LEVEL UP button (%d SP)" % sp)
			if btn != null:
				if sp == 5:
					_check(btn.disabled and btn.tooltip_text.contains("53") and btn.tooltip_text.contains("(you have 5)"),
						"with 5 SP the button is greyed with the 53 cost (disabled %s, '%s')" % [btn.disabled, btn.tooltip_text])
				else:
					_check(not btn.disabled and btn.tooltip_text.contains("costs 53 skill points"),
						"with 53 SP the button is live and shows its cost (disabled %s, '%s')" % [btn.disabled, btn.tooltip_text])
			board.free()

		# A server refusal reaches chat through system_notice; a success says
		# nothing. No character is signed in, so neither sends a request.
		var notices: Array = []
		var has_notice := panels.has_signal("system_notice")
		_check(has_notice, "HudPanels has the system_notice signal")
		if has_notice:
			panels.connect("system_notice", func(text: String) -> void: notices.append(text))
		var refused := SkillNet.RaiseMasteryResult.new()
		refused.error = "not enough skill points"
		panels.call("_on_raise_mastery_result", refused)
		_check(notices.size() == 1 and str(notices[0]).contains("not enough skill points"),
			"a refused raise is said in chat (got %s)" % str(notices))
		var raised := SkillNet.RaiseMasteryResult.new()
		raised.mastery_id = 257
		raised.new_level = 21
		panels.call("_on_raise_mastery_result", raised)
		_check(notices.size() == 1, "a successful raise adds no notice (got %s)" % str(notices))
		panels.free()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
