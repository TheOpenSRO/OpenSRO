extends SceneTree

## Mirrors server/internal/session/gm_test.go's wire cases: the client
## decoder must read exactly what the server's GMCommandResult.Encode writes,
## and the request encoder must produce what DecodeGMCommandRequest reads.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## Builds a GMCommandResult payload exactly as gm.go's Encode does, so the
## decoder is tested against the real byte layout, not against itself.
func _build_result(is_gm: bool, refused: bool, text: String, has_pos: bool, x: float, z: float, zone: String, new_level: int, stat_points: int, refresh: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.append(1 if is_gm else 0)
	out.append(1 if refused else 0)
	out.append_array(_str(text))
	out.append(1 if has_pos else 0)
	var f := PackedByteArray()
	f.resize(8)
	f.encode_float(0, x)
	f.encode_float(4, z)
	out.append_array(f)
	out.append_array(_str(zone))
	var ints := PackedByteArray()
	ints.resize(9)
	ints.encode_s32(0, new_level)
	ints.encode_s32(4, stat_points)
	ints.encode_u8(8, refresh)
	out.append_array(ints)
	return out

func _str(s: String) -> PackedByteArray:
	var bytes := s.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, bytes.size())
	out.append_array(bytes)
	return out

func _test_encode_command() -> void:
	var encoded := GmNet.encode_command("Aria", "/tp -300 -880", 42)
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.slice(2, 6).get_string_from_utf8() == "Aria", "name bytes follow prefix")
	var line_off := 6
	var line_len := encoded.decode_u16(line_off)
	_check(encoded.slice(line_off + 2, line_off + 2 + line_len).get_string_from_utf8() == "/tp -300 -880", "line round-trips")
	_check(encoded.decode_s64(line_off + 2 + line_len) == 42, "selected monster is the trailing s64")

func _test_decode_refusal() -> void:
	var payload := _build_result(false, true, "GM commands are not enabled for your account.", false, 0, 0, "", 0, 0, 0)
	var r := GmNet.decode_result(payload)
	_check(r != null, "refusal decodes")
	if r != null:
		_check(not r.is_gm and r.refused, "refusal: not gm, refused")
		_check(r.text == "GM commands are not enabled for your account.", "refusal text")
		_check(not r.has_pos and r.zone == "" and r.refresh == 0, "refusal carries no structure")

func _test_decode_teleport() -> void:
	var payload := _build_result(true, false, "teleporting to -300.0, -880.0", true, -300.0, -880.0, "", 0, 0, 0)
	var r := GmNet.decode_result(payload)
	_check(r != null, "teleport decodes")
	if r != null:
		_check(r.is_gm and not r.refused, "teleport: gm, not refused")
		_check(r.has_pos, "teleport has_pos")
		_check(absf(r.x - (-300.0)) < 0.01 and absf(r.z - (-880.0)) < 0.01, "teleport x/z round-trip")
		_check(r.zone == "", "teleport is in the current zone (no zone change)")

func _test_decode_zone_travel() -> void:
	var payload := _build_result(true, false, "travelling to donwhang", false, 0, 0, "donwhang", 0, 0, GmNet.REFRESH_MONSTERS)
	var r := GmNet.decode_result(payload)
	_check(r != null and r.zone == "donwhang" and not r.has_pos, "zone travel: zone set, no pos")

func _test_decode_level_up() -> void:
	var payload := _build_result(true, false, "level 1 -> 5", false, 0, 0, "", 5, 15, GmNet.REFRESH_STATS)
	var r := GmNet.decode_result(payload)
	_check(r != null, "level-up decodes")
	if r != null:
		_check(r.new_level == 5 and r.stat_points == 15, "level-up level/points round-trip")
		_check(r.refresh & GmNet.REFRESH_STATS != 0, "level-up asks for a stats refresh")

func _test_decode_truncated() -> void:
	_check(GmNet.decode_result(PackedByteArray()) == null, "empty payload -> null")
	_check(GmNet.decode_result(PackedByteArray([1])) == null, "one byte -> null")
	# Flags + a length prefix that lies about its length.
	var bad := PackedByteArray([1, 0, 200, 0])
	_check(GmNet.decode_result(bad) == null, "over-long string prefix -> null")

func _init() -> void:
	_test_encode_command()
	_test_decode_refusal()
	_test_decode_teleport()
	_test_decode_zone_travel()
	_test_decode_level_up()
	_test_decode_truncated()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
