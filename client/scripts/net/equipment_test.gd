extends SceneTree

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_equip() -> void:
	var encoded := EquipmentNet.encode_equip("Aria", EquipmentNet.SLOT_WEAPON, 3)
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.slice(2, 6).get_string_from_utf8() == "Aria", "name bytes follow prefix")
	_check(encoded.decode_u32(6) == 0, "slot encodes as 0 (SLOT_WEAPON)")
	_check(encoded.decode_u32(10) == 3, "inventory slot round-trips")

func _test_encode_unequip() -> void:
	var encoded := EquipmentNet.encode_unequip("Aria", EquipmentNet.SLOT_ARMOR)
	_check(encoded.decode_u32(6) == 1, "slot encodes as 1 (SLOT_ARMOR)")

func _build_result(error: String, items: Array) -> PackedByteArray:
	var out := PackedByteArray()
	var error_bytes := error.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, error_bytes.size())
	out.append_array(len_buf)
	out.append_array(error_bytes)

	var count_buf := PackedByteArray()
	count_buf.resize(2)
	count_buf.encode_u16(0, items.size())
	out.append_array(count_buf)

	for it in items:
		var buf := PackedByteArray()
		buf.resize(12)
		buf.encode_u32(0, it["slot"])
		buf.encode_s64(4, it["item_id"])
		out.append_array(buf)

	return out

func _test_decode_result() -> void:
	var payload := _build_result("", [{"slot": 0, "item_id": 100}])
	var result := EquipmentNet.decode_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.items.size() == 1, "one item decoded")
	if result.items.size() == 1:
		_check(result.items[0].slot == 0, "slot round-trips")
		_check(result.items[0].item_id == 100, "item id round-trips")

func _init() -> void:
	_test_encode_equip()
	_test_encode_unequip()
	_test_decode_result()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
