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

func _build_loot_dropped(monster_id: int, drops: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(8)
	out.encode_s64(0, monster_id)
	var count_buf := PackedByteArray()
	count_buf.resize(2)
	count_buf.encode_u16(0, drops.size())
	out.append_array(count_buf)
	for d in drops:
		var buf := PackedByteArray()
		buf.resize(12)
		buf.encode_s64(0, d["item_id"])
		buf.encode_u32(8, d["quantity"])
		out.append_array(buf)
	return out

func _test_decode_loot_dropped() -> void:
	var payload := _build_loot_dropped(1, [{"item_id": 500, "quantity": 1}, {"item_id": 600, "quantity": 3}])
	var result := CombatNet.decode_loot_dropped(payload)
	_check(result != null, "decodes successfully")
	if result != null:
		_check(result.monster_id == 1, "monster id round-trips")
		_check(result.drops.size() == 2, "two drops decoded")
		if result.drops.size() == 2:
			_check(result.drops[0].item_id == 500, "first drop item id round-trips")
			_check(result.drops[0].quantity == 1, "first drop quantity round-trips")
			_check(result.drops[1].item_id == 600, "second drop item id round-trips")
			_check(result.drops[1].quantity == 3, "second drop quantity round-trips")

func _test_decode_loot_dropped_empty() -> void:
	var payload := _build_loot_dropped(1, [])
	var result := CombatNet.decode_loot_dropped(payload)
	_check(result != null, "decodes successfully with no drops")
	if result != null:
		_check(result.drops.size() == 0, "no drops")

func _build_monster_snapshot(id: int, name: String, max_hp: int, hp: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(8)
	out.encode_s64(0, id)
	var name_bytes := name.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, name_bytes.size())
	out.append_array(len_buf)
	out.append_array(name_bytes)
	var hp_buf := PackedByteArray()
	hp_buf.resize(8)
	hp_buf.encode_u32(0, max_hp)
	hp_buf.encode_u32(4, hp)
	out.append_array(hp_buf)
	return out

func _build_monster_list_result(error: String, monsters: Array) -> PackedByteArray:
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
	count_buf.encode_u16(0, monsters.size())
	out.append_array(count_buf)
	for m in monsters:
		out.append_array(_build_monster_snapshot(m["id"], m["name"], m["max_hp"], m["hp"]))
	return out

func _test_decode_monster_list_result() -> void:
	var payload := _build_monster_list_result("", [{"id": 1, "name": "Stone Golem", "max_hp": 200, "hp": 150}])
	var result := CombatNet.decode_monster_list_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.monsters.size() == 1, "one monster decoded")
	if result.monsters.size() == 1:
		_check(result.monsters[0].monster_id == 1, "monster id round-trips")
		_check(result.monsters[0].monster_name == "Stone Golem", "monster name round-trips")
		_check(result.monsters[0].max_hp == 200, "max hp round-trips")
		_check(result.monsters[0].hp == 150, "hp round-trips")

func _test_decode_monster_list_result_error() -> void:
	var payload := _build_monster_list_result("not in the world", [])
	var result := CombatNet.decode_monster_list_result(payload)
	_check(result.error == "not in the world", "error round-trips")
	_check(result.monsters.size() == 0, "no monsters alongside an error")

func _init() -> void:
	_test_encode_attack()
	_test_decode_attack_result()
	_test_decode_attack_result_deaths()
	_test_decode_monster_damaged()
	_test_decode_monster_died()
	_test_decode_loot_dropped()
	_test_decode_loot_dropped_empty()
	_test_decode_monster_list_result()
	_test_decode_monster_list_result_error()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
