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

func _append_string(out: PackedByteArray, s: String) -> void:
	var b := s.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, b.size())
	out.append_array(len_buf)
	out.append_array(b)

func _append_u16(out: PackedByteArray, v: int) -> void:
	var buf := PackedByteArray()
	buf.resize(2)
	buf.encode_u16(0, v)
	out.append_array(buf)

## Hand-builds an OpCharacterListResult payload matching
## server/internal/session's encoding: a length-prefixed Error, a uint16
## count, then per character name and gender (length-prefixed) and three
## uint16s (level, hp, max hp). `chars` is an Array of Dictionaries.
func _build_list_result_payload(error: String, chars: Array) -> PackedByteArray:
	var out := PackedByteArray()
	_append_string(out, error)
	_append_u16(out, chars.size())
	for c in chars:
		_append_string(out, c["name"])
		_append_string(out, c.get("gender", "china_man"))
		_append_u16(out, c.get("level", 1))
		_append_u16(out, c.get("hp", 100))
		_append_u16(out, c.get("max_hp", 100))
	return out

func _test_decode_list_result_empty() -> void:
	var payload := _build_list_result_payload("", [])
	var result := CharacterNet.decode_list_result(payload)
	_check(result.error == "", "no error for well-formed empty list")
	_check(result.characters.size() == 0, "empty list decodes to zero characters")

func _test_decode_list_result_with_names() -> void:
	var payload := _build_list_result_payload("", [
		{"name": "Aria", "gender": "china_woman", "level": 7, "hp": 55, "max_hp": 100},
		{"name": "Bram", "gender": "china_man", "level": 1, "hp": 100, "max_hp": 100},
	])
	var result := CharacterNet.decode_list_result(payload)
	_check(result.error == "", "no error for well-formed list")
	_check(result.characters.size() == 2, "decoded 2 characters (got %d)" % result.characters.size())
	if result.characters.size() == 2:
		_check(result.characters[0].char_name == "Aria", "first name round-trips")
		_check(result.characters[0].gender == "china_woman", "first gender round-trips")
		_check(result.characters[0].level == 7, "first level round-trips (got %d)" % result.characters[0].level)
		_check(result.characters[0].hp == 55, "first hp round-trips (got %d)" % result.characters[0].hp)
		_check(result.characters[0].max_hp == 100, "first max hp round-trips")
		_check(result.characters[1].char_name == "Bram", "second name round-trips")

func _test_decode_list_result_error() -> void:
	var payload := _build_list_result_payload("not authenticated", [])
	var result := CharacterNet.decode_list_result(payload)
	_check(result.error == "not authenticated", "error message round-trips")
	_check(result.characters.size() == 0, "no characters alongside an error")

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
