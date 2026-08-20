extends SceneTree

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_challenge() -> void:
	var encoded := DuelNet.encode_challenge("Aria", "Bram")
	_check(encoded.decode_u16(0) == 4, "character name length prefix is 4")
	_check(encoded.decode_u16(6) == 4, "target name length prefix is 4")

func _test_encode_respond() -> void:
	var encoded := DuelNet.encode_respond("Bram", "Aria", true)
	_check(encoded.decode_u16(0) == 4, "character name length prefix is 4")
	var challenger_offset := 2 + 4
	_check(encoded.decode_u16(challenger_offset) == 4, "challenger name length prefix is 4")
	_check(encoded[encoded.size() - 1] == 1, "accept flag is 1")

func _test_encode_attack() -> void:
	var encoded := DuelNet.encode_attack("Aria")
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.size() == 6, "no extra payload beyond the name")

func _build_named(name: String) -> PackedByteArray:
	var bytes := name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, bytes.size())
	out.append_array(bytes)
	return out

func _test_decode_invite() -> void:
	var i := DuelNet.decode_invite(_build_named("Aria"))
	_check(i != null, "decodes successfully")
	if i != null:
		_check(i.challenger_name == "Aria", "challenger name round-trips")

func _test_decode_started() -> void:
	var s := DuelNet.decode_started(_build_named("Bram"))
	_check(s != null, "decodes successfully")
	if s != null:
		_check(s.opponent_name == "Bram", "opponent name round-trips")

func _test_decode_declined() -> void:
	var d := DuelNet.decode_declined(_build_named("Aria"))
	_check(d != null, "decodes successfully")
	if d != null:
		_check(d.target_name == "Aria", "target name round-trips")

func _test_decode_ended() -> void:
	var e := DuelNet.decode_ended(_build_named("Aria"))
	_check(e != null, "decodes successfully")
	if e != null:
		_check(e.winner_name == "Aria", "winner name round-trips")

func _build_attack_result(error: String, damage: int, opponent_hp: int, opponent_died: bool) -> PackedByteArray:
	var out := PackedByteArray()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	var error_bytes := error.to_utf8_buffer()
	len_buf.encode_u16(0, error_bytes.size())
	out.append_array(len_buf)
	out.append_array(error_bytes)
	if error != "":
		return out

	var u32_buf := PackedByteArray()
	u32_buf.resize(4)
	u32_buf.encode_u32(0, damage)
	out.append_array(u32_buf)
	u32_buf.encode_u32(0, opponent_hp)
	out.append_array(u32_buf)
	out.append(1 if opponent_died else 0)
	return out

func _test_decode_attack_result() -> void:
	var payload := _build_attack_result("", 30, 70, false)
	var r := DuelNet.decode_attack_result(payload)
	_check(r.error == "", "no decode error")
	_check(r.damage == 30, "damage round-trips")
	_check(r.opponent_hp == 70, "opponent hp round-trips")
	_check(not r.opponent_died, "opponent died round-trips (false)")

func _test_decode_attack_result_death() -> void:
	var payload := _build_attack_result("", 30, 0, true)
	var r := DuelNet.decode_attack_result(payload)
	_check(r.opponent_hp == 0, "opponent hp is 0")
	_check(r.opponent_died, "opponent died round-trips (true)")

func _test_decode_attack_result_error() -> void:
	var payload := _build_attack_result("not in a duel", 0, 0, false)
	var r := DuelNet.decode_attack_result(payload)
	_check(r.error == "not in a duel", "error round-trips")

func _test_decode_opponent_damaged() -> void:
	var buf := PackedByteArray()
	buf.resize(8)
	buf.encode_u32(0, 30)
	buf.encode_u32(4, 70)
	var d := DuelNet.decode_opponent_damaged(buf)
	_check(d != null, "decodes successfully")
	if d != null:
		_check(d.damage == 30, "damage round-trips")
		_check(d.remaining_hp == 70, "remaining hp round-trips")

func _init() -> void:
	_test_encode_challenge()
	_test_encode_respond()
	_test_encode_attack()
	_test_decode_invite()
	_test_decode_started()
	_test_decode_declined()
	_test_decode_ended()
	_test_decode_attack_result()
	_test_decode_attack_result_death()
	_test_decode_attack_result_error()
	_test_decode_opponent_damaged()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
