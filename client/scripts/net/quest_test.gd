extends SceneTree

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_list_request() -> void:
	var encoded := QuestNet.encode_list_request("Aria")
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")

func _test_encode_accept() -> void:
	var encoded := QuestNet.encode_accept("Aria", 1)
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.decode_s64(6) == 1, "quest id round-trips")

func _build_entry(quest_id: int, name: String, monster_name: String, target: int, gold: int, kills: int, accepted: bool, completed: bool) -> PackedByteArray:
	var out := PackedByteArray()
	var id_buf := PackedByteArray()
	id_buf.resize(8)
	id_buf.encode_s64(0, quest_id)
	out.append_array(id_buf)

	var len_buf := PackedByteArray()
	len_buf.resize(2)
	var name_bytes := name.to_utf8_buffer()
	len_buf.encode_u16(0, name_bytes.size())
	out.append_array(len_buf)
	out.append_array(name_bytes)

	var monster_bytes := monster_name.to_utf8_buffer()
	len_buf.encode_u16(0, monster_bytes.size())
	out.append_array(len_buf)
	out.append_array(monster_bytes)

	var u32_buf := PackedByteArray()
	u32_buf.resize(4)
	u32_buf.encode_u32(0, target)
	out.append_array(u32_buf)

	id_buf.encode_s64(0, gold)
	out.append_array(id_buf)

	u32_buf.encode_u32(0, kills)
	out.append_array(u32_buf)

	var flags := 0
	if accepted:
		flags |= 1
	if completed:
		flags |= 2
	out.append(flags)

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
		out.append_array(_build_entry(e["id"], e["name"], e["monster"], e["target"], e["gold"], e["kills"], e["accepted"], e["completed"]))
	return out

func _test_decode_list_result() -> void:
	var payload := _build_list_result("", [
		{"id": 1, "name": "Golem Cull", "monster": "Stone Golem", "target": 3, "gold": 200, "kills": 1, "accepted": true, "completed": false},
	])
	var result := QuestNet.decode_list_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.entries.size() == 1, "one entry decoded")
	if result.entries.size() == 1:
		var e := result.entries[0]
		_check(e.quest_id == 1, "quest id round-trips")
		_check(e.quest_name == "Golem Cull", "quest name round-trips")
		_check(e.monster_name == "Stone Golem", "monster name round-trips")
		_check(e.target_kills == 3, "target kills round-trips")
		_check(e.gold_reward == 200, "gold reward round-trips")
		_check(e.kills == 1, "kills round-trips")
		_check(e.accepted, "accepted round-trips")
		_check(not e.completed, "completed round-trips")

func _test_decode_list_result_error() -> void:
	var payload := _build_list_result("failed to load quest progress", [])
	var result := QuestNet.decode_list_result(payload)
	_check(result.error == "failed to load quest progress", "error round-trips")
	_check(result.entries.size() == 0, "no entries alongside an error")

func _test_decode_completed() -> void:
	var buf := PackedByteArray()
	buf.resize(16)
	buf.encode_s64(0, 1)
	buf.encode_s64(8, 200)
	var c := QuestNet.decode_completed(buf)
	_check(c != null, "decodes successfully")
	if c != null:
		_check(c.quest_id == 1, "quest id round-trips")
		_check(c.gold_reward == 200, "gold reward round-trips")

func _init() -> void:
	_test_encode_list_request()
	_test_encode_accept()
	_test_decode_list_result()
	_test_decode_list_result_error()
	_test_decode_completed()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
