extends SceneTree

## UseItemNet.decode_result: the 28-byte body, and round 632's berserk tail.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _reply(tail: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, 0)
	var body := PackedByteArray()
	body.resize(28)
	body.encode_s32(24, 2)
	out.append_array(body)
	out.append_array(tail)
	return out

func _init() -> void:
	var old := UseItemNet.decode_result(_reply(PackedByteArray()))
	_check(old.error == "" and old.remaining == 2, "a 28-byte reply decodes")
	_check(not old.has_berserk, "a reply without the tail carries no berserk state")
	var tail := PackedByteArray()
	tail.resize(6)
	tail[0] = 1
	tail.encode_s32(1, 100)
	tail[5] = 0
	var zerk := UseItemNet.decode_result(_reply(tail))
	_check(zerk.has_berserk, "the berserk tail is read")
	_check(zerk.berserk_gauge == 100, "the gauge round-trips (got %d)" % zerk.berserk_gauge)
	_check(not zerk.berserk_active, "active round-trips")
	_check(zerk.remaining == 2, "the body is unchanged by the tail")
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		quit(1)
