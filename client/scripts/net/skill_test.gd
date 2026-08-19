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

func _init() -> void:
	_test_encode_learn()
	_test_encode_use()
	_test_decode_learn_result_ok()
	_test_decode_learn_result_failure()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
