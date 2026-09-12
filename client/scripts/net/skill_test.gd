extends SceneTree

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_learn() -> void:
	var encoded := SkillNet.encode_learn("Aria", 1)
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.decode_s64(6) == 1, "skill id round-trips")

func _test_encode_use() -> void:
	var encoded := SkillNet.encode_use("Aria", 1, 7)
	_check(encoded.decode_s64(6) == 1, "skill id round-trips")
	_check(encoded.decode_s64(14) == 7, "target monster id round-trips")

func _test_decode_learn_result_ok() -> void:
	var payload := PackedByteArray([1, 0, 0])
	var result := SkillNet.decode_learn_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.ok, "ok is true")

func _test_decode_learn_result_failure() -> void:
	var reason := "already known"
	var reason_bytes := reason.to_utf8_buffer()
	var payload := PackedByteArray([0])
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, reason_bytes.size())
	payload.append_array(len_buf)
	payload.append_array(reason_bytes)

	var result := SkillNet.decode_learn_result(payload)
	_check(not result.ok, "ok is false")
	_check(result.reason == reason, "reason round-trips")

func _test_encode_list() -> void:
	var encoded := SkillNet.encode_list("Aria")
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")

func _build_skill_snapshot(id: int, name: String, damage_bonus: int, cooldown_seconds: int, known: bool, ready_seconds: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(8)
	out.encode_s64(0, id)
	var name_bytes := name.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, name_bytes.size())
	out.append_array(len_buf)
	out.append_array(name_bytes)
	var fields := PackedByteArray()
	fields.resize(13)
	fields.encode_u32(0, damage_bonus)
	fields.encode_u32(4, cooldown_seconds)
	fields[8] = 1 if known else 0
	fields.encode_u32(9, ready_seconds)
	out.append_array(fields)
	return out

func _build_skill_list_result(error: String, skills: Array) -> PackedByteArray:
	var out := PackedByteArray()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	var error_bytes := error.to_utf8_buffer()
	len_buf.encode_u16(0, error_bytes.size())
	out.append_array(len_buf)
	out.append_array(error_bytes)
	if error != "":
		return out
	var count_buf := PackedByteArray()
	count_buf.resize(2)
	count_buf.encode_u16(0, skills.size())
	out.append_array(count_buf)
	for s in skills:
		out.append_array(_build_skill_snapshot(s["id"], s["name"], s["damage_bonus"], s["cooldown_seconds"], s["known"], s["ready_seconds"]))
	return out

func _test_decode_list_result() -> void:
	var payload := _build_skill_list_result("", [
		{"id": 1, "name": "Power Strike", "damage_bonus": 15, "cooldown_seconds": 5, "known": true, "ready_seconds": 3},
	])
	var result := SkillNet.decode_list_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.skills.size() == 1, "one skill decoded")
	if result.skills.size() == 1:
		var s := result.skills[0]
		_check(s.skill_id == 1, "skill id round-trips")
		_check(s.skill_name == "Power Strike", "skill name round-trips")
		_check(s.damage_bonus == 15, "damage bonus round-trips")
		_check(s.cooldown_seconds == 5, "cooldown round-trips")
		_check(s.known, "known round-trips")
		_check(s.ready_seconds == 3, "ready seconds round-trips")

func _test_decode_list_result_error() -> void:
	var payload := _build_skill_list_result("not in the world", [])
	var result := SkillNet.decode_list_result(payload)
	_check(result.error == "not in the world", "error round-trips")
	_check(result.skills.is_empty(), "no skills alongside an error")

func _test_encode_raise_mastery() -> void:
	var encoded := SkillNet.encode_raise_mastery("Aria", 257)
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.decode_s64(6) == 257, "mastery id round-trips")

func _build_state_result(error: String, level: int, sp: int, masteries: Array, known: Array = []) -> PackedByteArray:
	var out := PackedByteArray()
	var eb := error.to_utf8_buffer()
	var lp := PackedByteArray()
	lp.resize(2)
	lp.encode_u16(0, eb.size())
	out.append_array(lp)
	out.append_array(eb)
	if error != "":
		return out
	var hdr := PackedByteArray()
	hdr.resize(10)
	hdr.encode_u32(0, level)
	hdr.encode_u32(4, sp)
	hdr.encode_u16(8, masteries.size())
	out.append_array(hdr)
	for m in masteries:
		var mb := PackedByteArray()
		mb.resize(12)
		mb.encode_s64(0, m.id)
		mb.encode_u32(8, m.level)
		out.append_array(mb)
	var kb := PackedByteArray()
	kb.resize(2)
	kb.encode_u16(0, known.size())
	out.append_array(kb)
	for id in known:
		var ib := PackedByteArray()
		ib.resize(8)
		ib.encode_s64(0, id)
		out.append_array(ib)
	return out

func _test_decode_state_result() -> void:
	var payload := _build_state_result("", 40, 123, [{"id": 257, "level": 20}, {"id": 258, "level": 5}], [17401, 17402])
	var s := SkillNet.decode_state_result(payload)
	_check(s.error == "", "no decode error")
	_check(s.level == 40, "level round-trips")
	_check(s.skill_points == 123, "skill points round-trip")
	_check(s.mastery_levels.get(257, -1) == 20, "mastery 257 level round-trips")
	_check(s.mastery_levels.get(258, -1) == 5, "mastery 258 level round-trips")
	_check(s.known_skills.has(17401) and s.known_skills.has(17402), "known skills decode into the set")

func _build_raise_result(error: String, mid: int, new_level: int, sp: int) -> PackedByteArray:
	var out := PackedByteArray()
	var eb := error.to_utf8_buffer()
	var lp := PackedByteArray()
	lp.resize(2)
	lp.encode_u16(0, eb.size())
	out.append_array(lp)
	out.append_array(eb)
	var tb := PackedByteArray()
	tb.resize(16)
	tb.encode_s64(0, mid)
	tb.encode_u32(8, new_level)
	tb.encode_u32(12, sp)
	out.append_array(tb)
	return out

func _test_decode_raise_result() -> void:
	var ok := SkillNet.decode_raise_mastery_result(_build_raise_result("", 257, 3, 90))
	_check(ok.error == "", "no decode error")
	_check(ok.mastery_id == 257, "mastery id round-trips")
	_check(ok.new_level == 3, "new level round-trips")
	_check(ok.skill_points == 90, "skill points round-trip")
	var fail := SkillNet.decode_raise_mastery_result(_build_raise_result("not enough skill points", 0, 0, 0))
	_check(fail.error == "not enough skill points", "error round-trips")

func _init() -> void:
	_test_encode_learn()
	_test_encode_use()
	_test_decode_learn_result_ok()
	_test_decode_learn_result_failure()
	_test_encode_list()
	_test_decode_list_result()
	_test_decode_list_result_error()
	_test_encode_raise_mastery()
	_test_decode_state_result()
	_test_decode_raise_result()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
