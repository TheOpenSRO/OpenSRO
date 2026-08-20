extends SceneTree

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_request() -> void:
	var encoded := FriendNet.encode_request("Aria", "Bram")
	_check(encoded.decode_u16(0) == 4, "character name length prefix is 4")
	_check(encoded.decode_u16(6) == 4, "target name length prefix is 4")

func _test_encode_accept() -> void:
	var encoded := FriendNet.encode_accept("Bram", 1)
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.decode_s64(6) == 1, "requester id round-trips")

func _test_encode_remove() -> void:
	var encoded := FriendNet.encode_remove("Aria", 2)
	_check(encoded.decode_s64(6) == 2, "friend id round-trips")

func _build_named(name: String) -> PackedByteArray:
	var bytes := name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, bytes.size())
	out.append_array(bytes)
	return out

func _test_decode_request_received() -> void:
	var r := FriendNet.decode_request_received(_build_named("Aria"))
	_check(r != null, "decodes successfully")
	if r != null:
		_check(r.requester_name == "Aria", "requester name round-trips")

func _test_decode_accepted() -> void:
	var a := FriendNet.decode_accepted(_build_named("Bram"))
	_check(a != null, "decodes successfully")
	if a != null:
		_check(a.accepter_name == "Bram", "accepter name round-trips")

func _build_friend_entry(id: int, name: String, online: bool) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(8)
	out.encode_s64(0, id)
	var name_bytes := name.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, name_bytes.size())
	out.append_array(len_buf)
	out.append_array(name_bytes)
	out.append(1 if online else 0)
	return out

func _build_list_result(error: String, entries: Array) -> PackedByteArray:
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
	count_buf.encode_u16(0, entries.size())
	out.append_array(count_buf)
	for e in entries:
		out.append_array(_build_friend_entry(e["id"], e["name"], e["online"]))
	return out

func _test_decode_list_result() -> void:
	var payload := _build_list_result("", [{"id": 2, "name": "Bram", "online": true}])
	var result := FriendNet.decode_list_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.friends.size() == 1, "one friend decoded")
	if result.friends.size() == 1:
		_check(result.friends[0].character_id == 2, "character id round-trips")
		_check(result.friends[0].friend_name == "Bram", "friend name round-trips")
		_check(result.friends[0].online, "online round-trips")

func _test_decode_list_result_error() -> void:
	var payload := _build_list_result("failed to load friends", [])
	var result := FriendNet.decode_list_result(payload)
	_check(result.error == "failed to load friends", "error round-trips")
	_check(result.friends.size() == 0, "no friends alongside an error")

func _build_pending_request(id: int, name: String) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(8)
	out.encode_s64(0, id)
	var name_bytes := name.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, name_bytes.size())
	out.append_array(len_buf)
	out.append_array(name_bytes)
	return out

func _build_pending_list_result(error: String, requests: Array) -> PackedByteArray:
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
	count_buf.encode_u16(0, requests.size())
	out.append_array(count_buf)
	for r in requests:
		out.append_array(_build_pending_request(r["id"], r["name"]))
	return out

func _test_decode_pending_list_result() -> void:
	var payload := _build_pending_list_result("", [{"id": 1, "name": "Aria"}])
	var result := FriendNet.decode_pending_list_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.requests.size() == 1, "one request decoded")
	if result.requests.size() == 1:
		_check(result.requests[0].requester_id == 1, "requester id round-trips")
		_check(result.requests[0].requester_name == "Aria", "requester name round-trips")

func _init() -> void:
	_test_encode_request()
	_test_encode_accept()
	_test_encode_remove()
	_test_decode_request_received()
	_test_decode_accepted()
	_test_decode_list_result()
	_test_decode_list_result_error()
	_test_decode_pending_list_result()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
