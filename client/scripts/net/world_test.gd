extends SceneTree

## Exercises WorldNet's encoding, run headless:
## `godot4 --headless --path client --script res://scripts/net/world_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_enter_world() -> void:
	var encoded := WorldNet.encode_enter_world("Aria")
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.slice(2, 6).get_string_from_utf8() == "Aria", "name bytes follow prefix")

func _test_encode_move() -> void:
	var encoded := WorldNet.encode_move(1.5, -2.5, 100.0)
	_check(encoded.size() == 12, "move payload is 12 bytes (got %d)" % encoded.size())
	_check(encoded.decode_float(0) == 1.5, "x round-trips")
	_check(encoded.decode_float(4) == -2.5, "y round-trips")
	_check(encoded.decode_float(8) == 100.0, "z round-trips")

## Hand-builds an OpEnterWorldResult payload matching
## server/internal/session's encoding.
func _build_enter_world_result(ok: bool, reason: String, zone: String, x: float, y: float, z: float, own_gender: String, others: Array) -> PackedByteArray:
	var out := PackedByteArray([1 if ok else 0])
	var reason_bytes := reason.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, reason_bytes.size())
	out.append_array(len_buf)
	out.append_array(reason_bytes)
	if not ok:
		return out

	var zone_bytes := zone.to_utf8_buffer()
	len_buf.encode_u16(0, zone_bytes.size())
	out.append_array(len_buf)
	out.append_array(zone_bytes)

	var pos_buf := PackedByteArray()
	pos_buf.resize(12)
	pos_buf.encode_float(0, x)
	pos_buf.encode_float(4, y)
	pos_buf.encode_float(8, z)
	out.append_array(pos_buf)

	var own_gender_bytes := own_gender.to_utf8_buffer()
	len_buf.encode_u16(0, own_gender_bytes.size())
	out.append_array(len_buf)
	out.append_array(own_gender_bytes)

	var count_buf := PackedByteArray()
	count_buf.resize(2)
	count_buf.encode_u16(0, others.size())
	out.append_array(count_buf)

	for o in others:
		var id_buf := PackedByteArray()
		id_buf.resize(8)
		id_buf.encode_s64(0, o["id"])
		out.append_array(id_buf)
		var oname_bytes: PackedByteArray = o["name"].to_utf8_buffer()
		len_buf.encode_u16(0, oname_bytes.size())
		out.append_array(len_buf)
		out.append_array(oname_bytes)
		var opos_buf := PackedByteArray()
		opos_buf.resize(12)
		opos_buf.encode_float(0, o["x"])
		opos_buf.encode_float(4, o["y"])
		opos_buf.encode_float(8, o["z"])
		out.append_array(opos_buf)
		out.append(int(o.get("armor_slots_mask", 0)) & 0xFF)
		out.append(1 if o.get("has_weapon", false) else 0)
		var ogender_bytes: PackedByteArray = String(o.get("gender", "")).to_utf8_buffer()
		len_buf.encode_u16(0, ogender_bytes.size())
		out.append_array(len_buf)
		out.append_array(ogender_bytes)

	return out

func _test_decode_enter_world_result_success() -> void:
	var payload := _build_enter_world_result(true, "", "jangan", 1.0, 2.0, 3.0, CharacterNet.GENDER_CHINA_MAN, [{"id": 42, "name": "Bram", "x": 4.0, "y": 5.0, "z": 6.0, "armor_slots_mask": 0b10101, "has_weapon": true, "gender": CharacterNet.GENDER_CHINA_WOMAN}])
	var result := WorldNet.decode_enter_world_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.ok, "ok is true")
	_check(result.zone == "jangan", "zone round-trips")
	_check(result.x == 1.0 and result.y == 2.0 and result.z == 3.0, "position round-trips")
	_check(result.gender == CharacterNet.GENDER_CHINA_MAN, "own gender round-trips")
	_check(result.others.size() == 1, "one other entity (got %d)" % result.others.size())
	if result.others.size() == 1:
		_check(result.others[0].character_id == 42, "other's character_id round-trips")
		_check(result.others[0].char_name == "Bram", "other's name round-trips")
		_check(result.others[0].x == 4.0, "other's x round-trips")
		_check(result.others[0].armor_slots_mask == 0b10101, "other's armor_slots_mask round-trips (got %d)" % result.others[0].armor_slots_mask)
		_check(result.others[0].has_weapon, "other's has_weapon round-trips")
		_check(result.others[0].gender == CharacterNet.GENDER_CHINA_WOMAN, "other's gender round-trips")

func _test_decode_enter_world_result_failure() -> void:
	var payload := _build_enter_world_result(false, "no such character", "", 0, 0, 0, "", [])
	var result := WorldNet.decode_enter_world_result(payload)
	_check(result.error == "", "no decode error")
	_check(not result.ok, "ok is false")
	_check(result.reason == "no such character", "reason round-trips")

func _test_decode_entity_entered() -> void:
	var payload := _build_enter_world_result(true, "", "z", 0, 0, 0, "", [{"id": 7, "name": "Bram", "x": 1.0, "y": 2.0, "z": 3.0, "armor_slots_mask": 0b00010, "has_weapon": false, "gender": CharacterNet.GENDER_CHINA_MAN}])
	# _build_enter_world_result wraps a single EntitySnapshot the same way
	# OpEntityEntered's payload is just one bare EntitySnapshot -- slice off
	# the EnterWorldResult framing in front of it (ok byte + empty reason +
	# zone + position + own-gender + count) to get just that snapshot's
	# bytes.
	var snapshot_start := 1 + 2 + 0 + 2 + 1 + 12 + 2 + 2
	var entered := WorldNet.decode_entity_entered(payload.slice(snapshot_start))
	_check(entered != null, "decodes successfully")
	if entered != null:
		_check(entered.character_id == 7, "character_id round-trips")
		_check(entered.char_name == "Bram", "name round-trips")
		_check(entered.armor_slots_mask == 0b00010, "armor_slots_mask round-trips (got %d)" % entered.armor_slots_mask)
		_check(not entered.has_weapon, "has_weapon round-trips (false)")
		_check(entered.gender == CharacterNet.GENDER_CHINA_MAN, "gender round-trips")

	var unarmored := _build_enter_world_result(true, "", "z", 0, 0, 0, "", [{"id": 8, "name": "Aria", "x": 0.0, "y": 0.0, "z": 0.0, "armor_slots_mask": 0, "has_weapon": true, "gender": CharacterNet.GENDER_CHINA_WOMAN}])
	var entered2 := WorldNet.decode_entity_entered(unarmored.slice(snapshot_start))
	_check(entered2 != null and entered2.armor_slots_mask == 0, "armor_slots_mask round-trips (0)")
	_check(entered2 != null and entered2.has_weapon, "second entity's has_weapon round-trips (true)")
	_check(entered2 != null and entered2.gender == CharacterNet.GENDER_CHINA_WOMAN, "second entity's gender round-trips")

func _test_decode_entity_moved() -> void:
	var buf := PackedByteArray()
	buf.resize(20)
	buf.encode_s64(0, 7)
	buf.encode_float(8, 1.0)
	buf.encode_float(12, 2.0)
	buf.encode_float(16, 3.0)
	var m := WorldNet.decode_entity_moved(buf)
	_check(m != null, "decodes successfully")
	if m != null:
		_check(m.character_id == 7, "character_id round-trips")
		_check(m.x == 1.0 and m.y == 2.0 and m.z == 3.0, "position round-trips")

func _test_decode_entity_left() -> void:
	var buf := PackedByteArray()
	buf.resize(8)
	buf.encode_s64(0, 99)
	_check(WorldNet.decode_entity_left(buf) == 99, "character_id round-trips")

func _init() -> void:
	_test_encode_enter_world()
	_test_encode_move()
	_test_decode_enter_world_result_success()
	_test_decode_enter_world_result_failure()
	_test_decode_entity_entered()
	_test_decode_entity_moved()
	_test_decode_entity_left()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
