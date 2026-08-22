extends SceneTree

## Exercises Packet's wire encoding, run headless:
## `godot4 --headless --path client --script res://scripts/net/packet_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_header_shape() -> void:
	var p := Packet.new(0x1234, "hi".to_utf8_buffer())
	var encoded := p.encode()
	_check(encoded.size() == Packet.HEADER_SIZE + 2, "encode: total size includes header + payload")
	_check(encoded.decode_u16(0) == 2, "encode: size field is payload length")
	_check(encoded.decode_u16(2) == 0x1234, "encode: opcode field round-trips")
	_check(encoded[4] == 0, "encode: rolling byte is 0")
	_check(encoded[5] == 0, "encode: checksum byte is 0")
	_check(encoded.slice(Packet.HEADER_SIZE, Packet.HEADER_SIZE + 2).get_string_from_utf8() == "hi", "encode: payload bytes follow header")

func _test_encode_empty_payload() -> void:
	var p := Packet.new(0x0001)
	var encoded := p.encode()
	_check(encoded.size() == Packet.HEADER_SIZE, "encode: empty payload produces header-only frame")
	_check(encoded.decode_u16(0) == 0, "encode: size field is 0 for empty payload")

func _init() -> void:
	_test_encode_header_shape()
	_test_encode_empty_payload()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
