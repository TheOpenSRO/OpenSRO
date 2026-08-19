extends SceneTree

## Exercises Auth's credential/result encoding, run headless:
## `godot4 --headless --path client --script res://scripts/net/auth_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_credentials_shape() -> void:
	var encoded := Auth.encode_credentials("alice", "hunter2")
	_check(encoded.decode_u16(0) == 5, "username length prefix is 5")
	_check(encoded.slice(2, 7).get_string_from_utf8() == "alice", "username bytes follow its length prefix")
	_check(encoded.decode_u16(7) == 7, "password length prefix is 7")
	_check(encoded.slice(9, 16).get_string_from_utf8() == "hunter2", "password bytes follow its length prefix")
	_check(encoded.size() == 16, "total encoded size matches both fields (got %d)" % encoded.size())

func _test_decode_result_ok() -> void:
	# Hand-build a wire payload matching server/internal/session's encoding:
	# 1 OK byte, then a length-prefixed reason (empty here).
	var payload := PackedByteArray([1, 0, 0])
	var result := Auth.decode_result(payload)
	_check(result.error == "", "no decode error for well-formed OK payload")
	_check(result.ok, "ok is true")
	_check(result.reason == "", "reason is empty")

func _test_decode_result_failure_with_reason() -> void:
	var reason := "account blocked"
	var reason_bytes := reason.to_utf8_buffer()
	var payload := PackedByteArray([0])
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, reason_bytes.size())
	payload.append_array(len_buf)
	payload.append_array(reason_bytes)

	var result := Auth.decode_result(payload)
	_check(result.error == "", "no decode error for well-formed failure payload")
	_check(not result.ok, "ok is false")
	_check(result.reason == reason, "reason round-trips (got %s)" % result.reason)

func _test_decode_result_truncated() -> void:
	var result := Auth.decode_result(PackedByteArray())
	_check(result.error != "", "empty payload reported as a decode error, not a crash")

func _init() -> void:
	_test_encode_credentials_shape()
	_test_decode_result_ok()
	_test_decode_result_failure_with_reason()
	_test_decode_result_truncated()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
