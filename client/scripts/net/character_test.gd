extends SceneTree

## Exercises CharacterNet's encoding, run headless:
## `godot4 --headless --path client --script res://scripts/net/character_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_name() -> void:
	var encoded := CharacterNet.encode_name("Aria")
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.slice(2, 6).get_string_from_utf8() == "Aria", "name bytes follow the length prefix")
	_check(encoded.size() == 6, "total encoded size matches (got %d)" % encoded.size())

func _test_encode_create() -> void:
	var encoded := CharacterNet.encode_create("Mei", CharacterNet.GENDER_CHINA_WOMAN)
	_check(encoded.decode_u16(0) == 3, "name length prefix is 3")
	_check(encoded.slice(2, 5).get_string_from_utf8() == "Mei", "name bytes follow the name length prefix")
	var gender_len := encoded.decode_u16(5)
	_check(gender_len == 11, "gender length prefix is 11 (got %d)" % gender_len)
	_check(encoded.slice(7, 7 + gender_len).get_string_from_utf8() == "china_woman", "gender bytes follow the gender length prefix")
	_check(encoded.size() == 7 + gender_len, "total encoded size matches (got %d)" % encoded.size())

func _test_encode_create_default_gender() -> void:
	var encoded := CharacterNet.encode_create("Bram")
	var gender_len := encoded.decode_u16(2 + 4)
	_check(gender_len == 0, "omitted gender encodes as an empty string (got len %d)" % gender_len)

## Hand-builds an OpCharacterListResult payload matching
## server/internal/session's encoding: empty Error, count=2, two names.
func _build_list_result_payload(error: String, names: Array) -> PackedByteArray:
	var out := PackedByteArray()
	var error_bytes := error.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, error_bytes.size())
	out.append_array(len_buf)
	out.append_array(error_bytes)

	var count_buf := PackedByteArray()
	count_buf.resize(2)
	count_buf.encode_u16(0, names.size())
	out.append_array(count_buf)

	for name in names:
		var name_bytes: PackedByteArray = name.to_utf8_buffer()
		var nlen_buf := PackedByteArray()
		nlen_buf.resize(2)
		nlen_buf.encode_u16(0, name_bytes.size())
		out.append_array(nlen_buf)
		out.append_array(name_bytes)

	return out

func _test_decode_list_result_empty() -> void:
	var payload := _build_list_result_payload("", [])
	var result := CharacterNet.decode_list_result(payload)
	_check(result.error == "", "no error for well-formed empty list")
	_check(result.names.size() == 0, "empty list decodes to zero names")

func _test_decode_list_result_with_names() -> void:
	var payload := _build_list_result_payload("", ["Aria", "Bram"])
	var result := CharacterNet.decode_list_result(payload)
	_check(result.error == "", "no error for well-formed list")
	_check(result.names.size() == 2, "decoded 2 names (got %d)" % result.names.size())
	if result.names.size() == 2:
		_check(result.names[0] == "Aria", "first name round-trips")
		_check(result.names[1] == "Bram", "second name round-trips")

func _test_decode_list_result_error() -> void:
	var payload := _build_list_result_payload("not authenticated", [])
	var result := CharacterNet.decode_list_result(payload)
	_check(result.error == "not authenticated", "error message round-trips")
	_check(result.names.size() == 0, "no names alongside an error")

func _test_decode_list_result_truncated() -> void:
	var result := CharacterNet.decode_list_result(PackedByteArray([1]))
	_check(result.error != "", "truncated payload reported as an error, not a crash")

func _init() -> void:
	_test_encode_name()
	_test_encode_create()
	_test_encode_create_default_gender()
	_test_decode_list_result_empty()
	_test_decode_list_result_with_names()
	_test_decode_list_result_error()
	_test_decode_list_result_truncated()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
