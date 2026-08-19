extends SceneTree

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_join() -> void:
	var encoded := PartyNet.encode_join("Bram", 1)
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.decode_s64(6) == 1, "party id round-trips")

func _build_result(error: String, party_id: int, members: Array) -> PackedByteArray:
	var out := PackedByteArray()
	var error_bytes := error.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, error_bytes.size())
	out.append_array(len_buf)
	out.append_array(error_bytes)
	if error != "":
		return out

	var id_buf := PackedByteArray()
	id_buf.resize(8)
	id_buf.encode_s64(0, party_id)
	out.append_array(id_buf)

	var count_buf := PackedByteArray()
	count_buf.resize(2)
	count_buf.encode_u16(0, members.size())
	out.append_array(count_buf)

	for m in members:
		var id_buf2 := PackedByteArray()
		id_buf2.resize(8)
		id_buf2.encode_s64(0, m["id"])
		out.append_array(id_buf2)
		var name_bytes: PackedByteArray = m["name"].to_utf8_buffer()
		len_buf.encode_u16(0, name_bytes.size())
		out.append_array(len_buf)
		out.append_array(name_bytes)

	return out

func _test_decode_result() -> void:
	var payload := _build_result("", 1, [{"id": 100, "name": "Aria"}, {"id": 200, "name": "Bram"}])
	var result := PartyNet.decode_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.party_id == 1, "party id round-trips")
	_check(result.members.size() == 2, "two members decoded")
	if result.members.size() == 2:
		_check(result.members[0].character_id == 100, "first member id round-trips")
		_check(result.members[0].member_name == "Aria", "first member name round-trips")
		_check(result.members[1].member_name == "Bram", "second member name round-trips")

func _test_decode_result_error() -> void:
	var payload := _build_result("party is full", 0, [])
	var result := PartyNet.decode_result(payload)
	_check(result.error == "party is full", "error round-trips")
	_check(result.members.size() == 0, "no members alongside an error")

func _test_decode_leave_result() -> void:
	var payload := PackedByteArray([1, 0, 0])
	var result := PartyNet.decode_leave_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.ok, "ok is true")

func _test_decode_member_joined() -> void:
	var name_bytes := "Bram".to_utf8_buffer()
	var buf := PackedByteArray()
	buf.resize(10)
	buf.encode_s64(0, 200)
	buf.encode_u16(8, name_bytes.size())
	buf.append_array(name_bytes)
	var m := PartyNet.decode_member_joined(buf)
	_check(m != null, "decodes successfully")
	if m != null:
		_check(m.character_id == 200, "character id round-trips")
		_check(m.member_name == "Bram", "name round-trips")

func _test_decode_member_left() -> void:
	var buf := PackedByteArray()
	buf.resize(8)
	buf.encode_s64(0, 200)
	_check(PartyNet.decode_member_left(buf) == 200, "character id round-trips")

func _init() -> void:
	_test_encode_join()
	_test_decode_result()
	_test_decode_result_error()
	_test_decode_leave_result()
	_test_decode_member_joined()
	_test_decode_member_left()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
