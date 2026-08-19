extends SceneTree

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_attack() -> void:
	var encoded := CombatNet.encode_attack("Aria", 7)
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.decode_s64(6) == 7, "target monster id round-trips")

func _build_attack_result(error: String, monster_damage: int, monster_hp: int, monster_died: bool,
		player_damage: int, player_hp: int, player_died: bool) -> PackedByteArray:
	var out := PackedByteArray()
	var error_bytes := error.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, error_bytes.size())
	out.append_array(len_buf)
	out.append_array(error_bytes)

	var buf := PackedByteArray()
	buf.resize(18)
	buf.encode_u32(0, monster_damage)
	buf.encode_u32(4, monster_hp)
	buf[8] = 1 if monster_died else 0
	buf.encode_u32(9, player_damage)
	buf.encode_u32(13, player_hp)
	buf[17] = 1 if player_died else 0
	out.append_array(buf)
	return out

func _test_decode_attack_result() -> void:
	var payload := _build_attack_result("", 20, 20, false, 15, 85, false)
	var result := CombatNet.decode_attack_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.monster_damage == 20, "monster_damage round-trips")
	_check(result.monster_remaining_hp == 20, "monster_remaining_hp round-trips")
	_check(not result.monster_died, "monster_died is false")
	_check(result.player_damage_taken == 15, "player_damage_taken round-trips")
	_check(result.player_hp == 85, "player_hp round-trips")
	_check(not result.player_died, "player_died is false")

func _test_decode_attack_result_deaths() -> void:
	var payload := _build_attack_result("", 20, 0, true, 0, 100, false)
	var result := CombatNet.decode_attack_result(payload)
	_check(result.monster_died, "monster_died is true")
	_check(result.player_damage_taken == 0, "no counterattack when monster died")

func _test_decode_monster_damaged() -> void:
	var buf := PackedByteArray()
	buf.resize(16)
	buf.encode_s64(0, 1)
	buf.encode_u32(8, 20)
	buf.encode_u32(12, 80)
	var m := CombatNet.decode_monster_damaged(buf)
	_check(m != null, "decodes successfully")
	if m != null:
		_check(m.monster_id == 1, "monster_id round-trips")
		_check(m.damage == 20, "damage round-trips")
		_check(m.remaining_hp == 80, "remaining_hp round-trips")

func _test_decode_monster_died() -> void:
	var buf := PackedByteArray()
	buf.resize(8)
	buf.encode_s64(0, 42)
	_check(CombatNet.decode_monster_died(buf) == 42, "monster id round-trips")

func _init() -> void:
	_test_encode_attack()
	_test_decode_attack_result()
	_test_decode_attack_result_deaths()
	_test_decode_monster_damaged()
	_test_decode_monster_died()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
