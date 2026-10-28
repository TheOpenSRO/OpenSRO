extends SceneTree

## Round 781: the action window's dispatch table (ActionCommands), against
## what the retail dispatcher 0x793b00 does for each id, and actionwnddata's
## reader (ActionWndData) on synthetic rows shaped like the archive's (no
## archive text: the names here are made up).
##
##   godot4 --headless --path client --script res://scripts/world/action_commands_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_test_plan()
	_test_emotes()
	_test_walk_run()
	_test_nearest()
	_test_reader()
	_test_net()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _test_plan() -> void:
	for pair in [[1000, "sit"], [1001, "walk_run"], [1002, "auto_attack"], [1005, "auto_select"],
			[1006, "exchange"], [1007, "party"], [1008, "auto_get"], [1003, "trace"], [1009, "stall"]]:
		_check(String(ActionCommands.plan(pair[0])["kind"]) == pair[1], "action %d is %s" % pair)
	for pair in [[1010, "alchemy"], [1012, "autopotion"], [1014, "academy"], [1016, "partymatch"]]:
		var p := ActionCommands.plan(pair[0])
		_check(String(p["kind"]) == "panel" and String(p["panel"]) == pair[1], "action %d opens %s" % pair)
	for id in [1004, 1011, 1015, 1017, 5000]:
		var p := ActionCommands.plan(id)
		_check(String(p["kind"]) == "unsupported" and String(p.get("line", "")) != "",
			"action %d says why it does nothing (OURS)" % id)
	_check(String(ActionCommands.plan(1013)["kind"]) == "unknown" and String(ActionCommands.plan(4007)["kind"]) == "unknown",
		"ids no row carries are unknown (1013 is commented out in the archive)")

func _test_emotes() -> void:
	# READ, 0x793b00: 4000 [00], 4001 [06], 4002 [01], 4003 [05], 4004 [02], 4005 [03], 4006 [04].
	var want := {4000: 0, 4001: 6, 4002: 1, 4003: 5, 4004: 2, 4005: 3, 4006: 4}
	for id in want:
		var p := ActionCommands.plan(id)
		_check(String(p["kind"]) == "emote" and int(p["emote"]) == int(want[id]), "emote %d sends 0x3091 [%02x]" % [id, want[id]])
	_check(ActionCommands.emote_animation(0) == 50 and ActionCommands.emote_animation(6) == 56,
		"an emote plays action type 0x32 + its byte (ANI_EMOTION01.., 0xa59bc0)")

func _test_walk_run() -> void:
	_check(ActionCommands.walk_run_request(true) == 2 and ActionCommands.walk_run_request(false) == 3,
		"Walk/Run sends [02] while running and [03] while walking (0x9d4a00)")

func _test_nearest() -> void:
	var from := Vector3.ZERO
	var c := {7: Vector3(30, 0, 0), 8: Vector3(0, 0, 10), 9: Vector3(0, 69.9, 0)}
	_check(ActionCommands.nearest_within(from, c) == 8, "Auto Select picks the nearest")
	_check(ActionCommands.nearest_within(from, {1: Vector3(70, 0, 0)}) == -1,
		"... strictly within 70.0 (.rdata 0xd990a8): one at exactly 70 is not taken")
	_check(ActionCommands.nearest_within(from, {1: Vector3(0, 60, 40)}) == -1, "... measured in 3-D (72.1 away, 40 on the ground)")
	_check(ActionCommands.nearest_within(from, {}) == -1, "... and nothing when nothing is near")

func _row(cols: Array) -> String:
	var parts := PackedStringArray()
	for c in cols:
		parts.append(str(c))
	return "\t".join(parts)

func _test_reader() -> void:
	var lines := PackedStringArray()
	lines.append(_row([1000, 1, "a", "KEY_A", "icon\\action\\a.ddj", 1, 0]))
	lines.append(_row([1001, 1, "b", "KEY_B", "icon\\action\\b.ddj", 1, 1]))
	lines.append("//" + _row([1013, 1, "c", "KEY_C", "icon\\action\\c.ddj", 1, 12]))
	lines.append(_row([1099, 0, "d", "KEY_D", "icon\\action\\d.ddj", 1, 5]))
	lines.append(_row([4001, 1, "e", "KEY_E", "icon\\action\\e.ddj", 4, 1]))
	lines.append(_row([5000, 1, "f", "KEY_F", "icon\\action\\f.ddj", 4, 7]))
	lines.append("broken\trow")
	var text := "﻿" + "\r\n".join(lines) + "\r\n"
	var bytes := PackedByteArray([0xff, 0xfe]) + text.substr(1).to_utf16_buffer()
	var rows := ActionWndData.parse(bytes)
	var ids: Array = []
	for r in rows:
		ids.append((r as ActionWndData.Entry).id)
	_check(ids == [1000, 1001, 4001, 5000], "rows in file order; the // row, a service-0 row and a short row skipped (got %s)" % [ids])
	var e := ActionWndData.find(rows, 4001)
	_check(e != null and e.text_key == "KEY_E" and e.icon == "icon\\action\\e.ddj" and e.section == 4 and e.slot == 1,
		"columns: id, service, name, text key, icon, section, slot (0x976e60)")
	_check(e != null and e.control_id() == 401, "section 4 slot 1 is ifaction's control 401 (0x190 + i, 0x6a4a22)")
	_check(ActionWndData.find(rows, 1001).control_id() == 101, "section 1 slot 1 is control 101 (0x64 + i)")
	var bad := ActionWndData.Entry.new()
	bad.section = 2
	bad.slot = 8
	_check(bad.control_id() == -1, "a slot past its section's 8 has no control")

func _test_net() -> void:
	var req := WorldNet.encode_emote(6)
	_check(req == PackedByteArray([6]), "0x3091's request is the one byte")
	var bc := PackedByteArray([0x04, 0x03, 0x02, 0x01, 0x05])
	var d := WorldNet.decode_emote(bc)
	_check(d.size() == 2 and int(d[0]) == 0x01020304 and int(d[1]) == 5, "0x3091's broadcast is {u32 id, u8 emote}")
	_check(WorldNet.decode_emote(bc.slice(0, 4)).is_empty(), "a short broadcast is dropped")
	_check(WorldNet.OP_EMOTE == 0x3091 and WorldNet.MOTION_WALK == 2 and WorldNet.MOTION_RUN == 3, "the retail codes")
