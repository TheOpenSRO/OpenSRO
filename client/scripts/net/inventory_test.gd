extends SceneTree

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _build_list_result(error: String, slots: Array) -> PackedByteArray:
	var out := PackedByteArray()
	var error_bytes := error.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, error_bytes.size())
	out.append_array(len_buf)
	out.append_array(error_bytes)

	var count_buf := PackedByteArray()
	count_buf.resize(2)
	count_buf.encode_u16(0, slots.size())
	out.append_array(count_buf)

	for s in slots:
		var buf := PackedByteArray()
		buf.resize(16)
		buf.encode_u32(0, s["slot"])
		buf.encode_s64(4, s["item_id"])
		buf.encode_u32(12, s["quantity"])
		out.append_array(buf)

	return out

func _test_encode_list_request() -> void:
	var encoded := InventoryNet.encode_list_request("Aria")
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.slice(2, 6).get_string_from_utf8() == "Aria", "name bytes follow prefix")

func _test_decode_list_result() -> void:
	var payload := _build_list_result("", [{"slot": 0, "item_id": 100, "quantity": 5}])
	var result := InventoryNet.decode_list_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.slots.size() == 1, "one slot decoded")
	if result.slots.size() == 1:
		_check(result.slots[0].slot_index == 0, "slot index round-trips")
		_check(result.slots[0].item_id == 100, "item id round-trips")
		_check(result.slots[0].quantity == 5, "quantity round-trips")

func _test_decode_list_result_error() -> void:
	var payload := _build_list_result("not authenticated", [])
	var result := InventoryNet.decode_list_result(payload)
	_check(result.error == "not authenticated", "error message round-trips")
	_check(result.slots.size() == 0, "no slots alongside an error")

## The move request is the list request plus two signed 64-bit slot indices
## -- the layout server/internal/session's DecodeInventoryMoveRequest reads.
func _test_encode_move_request() -> void:
	var encoded := InventoryNet.encode_move_request("Aria", 3, 27)
	_check(encoded.size() == 2 + 4 + 16, "name prefix + name + two s64 indices")
	_check(encoded.slice(2, 6).get_string_from_utf8() == "Aria", "name bytes follow prefix")
	_check(encoded.decode_s64(6) == 3, "from slot is the first s64")
	_check(encoded.decode_s64(14) == 27, "to slot is the second s64")
	# A negative index is carried as-is; refusing it is the server's job.
	_check(InventoryNet.encode_move_request("A", -1, 0).decode_s64(3) == -1, "negative index preserved")

func _init() -> void:
	_test_encode_list_request()
	_test_encode_move_request()
	_test_decode_list_result()
	_test_decode_list_result_error()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
