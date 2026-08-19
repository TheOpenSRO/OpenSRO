extends SceneTree

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_say() -> void:
	var encoded := ChatNet.encode_say("hello, jangan")
	_check(encoded.decode_u16(0) == 13, "message length prefix is 13")

func _test_encode_whisper() -> void:
	var encoded := ChatNet.encode_whisper("Bram", "psst")
	_check(encoded.decode_u16(0) == 4, "target name length prefix is 4")
	var msg_offset := 2 + 4
	_check(encoded.decode_u16(msg_offset) == 4, "message length prefix is 4")

func _build_message(sender: String, msg: String) -> PackedByteArray:
	var out := PackedByteArray()
	var len_buf := PackedByteArray()
	len_buf.resize(2)

	var sender_bytes := sender.to_utf8_buffer()
	len_buf.encode_u16(0, sender_bytes.size())
	out.append_array(len_buf)
	out.append_array(sender_bytes)

	var msg_bytes := msg.to_utf8_buffer()
	len_buf.encode_u16(0, msg_bytes.size())
	out.append_array(len_buf)
	out.append_array(msg_bytes)

	return out

func _test_decode_message() -> void:
	var payload := _build_message("Aria", "hello, jangan")
	var m := ChatNet.decode_message(payload)
	_check(m != null, "decodes successfully")
	if m != null:
		_check(m.sender_name == "Aria", "sender name round-trips")
		_check(m.message_text == "hello, jangan", "message text round-trips")

func _test_decode_whisper_result() -> void:
	var payload := PackedByteArray([1, 0, 0])
	var result := ChatNet.decode_whisper_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.ok, "ok is true")

func _test_decode_whisper_result_failure() -> void:
	var reason := "player not found"
	var reason_bytes := reason.to_utf8_buffer()
	var out := PackedByteArray([0])
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, reason_bytes.size())
	out.append_array(len_buf)
	out.append_array(reason_bytes)
	var result := ChatNet.decode_whisper_result(out)
	_check(result.error == "", "no decode error")
	_check(not result.ok, "ok is false")
	_check(result.reason == reason, "reason round-trips")

func _init() -> void:
	_test_encode_say()
	_test_encode_whisper()
	_test_decode_message()
	_test_decode_whisper_result()
	_test_decode_whisper_result_failure()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
