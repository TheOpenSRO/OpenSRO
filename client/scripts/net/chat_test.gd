extends SceneTree

## ChatNet's framing against server/internal/session/chat.go (round 634).
## Loaded by path and driven through call(), so against a client that lacks
## the typed chat it reports FAIL lines instead of failing to compile.

const CHAT_NET_PATH := "res://scripts/net/chat.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _str(s: String) -> PackedByteArray:
	var b := s.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, b.size())
	out.append_array(b)
	return out

func _initialize() -> void:
	var net: Script = load(CHAT_NET_PATH)
	var has := func(m: String) -> bool:
		for d in net.get_script_method_list():
			if d["name"] == m:
				return true
		return false
	var consts: Dictionary = net.get_script_constant_map()
	_check(consts.get("OP_SEND") == 0x00A5 and consts.get("OP_UPDATE") == 0x00A6
		and consts.get("OP_RESULT") == 0x00A7 and consts.get("OP_GLOBAL") == 0x00A8,
		"the opcodes are the server's 0x00A5..0x00A8 (got %s)" % [consts])

	if has.call("encode_send"):
		var e: PackedByteArray = net.call("encode_send", 2, 7, "Bram", "psst")
		var want := PackedByteArray([2, 7])
		want.append_array(_str("Bram"))
		want.append_array(_str("psst"))
		_check(e == want, "encode_send is type, index, target, text (got %s)" % [e])
	else:
		_check(false, "ChatNet has encode_send")

	if has.call("encode_global"):
		var g: PackedByteArray = net.call("encode_global", 21, "hi all")
		_check(g.size() == 8 + 2 + 6 and g.decode_s64(0) == 21, "encode_global is the slot as int64, then the text")
	else:
		_check(false, "ChatNet has encode_global")

	if has.call("decode_update"):
		var p := PackedByteArray([6])
		p.append_array(_str("Aria"))
		p.append_array(_str("WTS blade"))
		var u = net.call("decode_update", p)
		_check(u != null and u.type == 6 and u.sender_name == "Aria" and u.message_text == "WTS blade",
			"decode_update reads type, sender, text")
		_check(net.call("decode_update", PackedByteArray([6, 9, 0])) == null, "a truncated update decodes to null")
	else:
		_check(false, "ChatNet has decode_update")

	if has.call("decode_result"):
		var r := PackedByteArray([0, 2, 9, 3, 0])
		r.append_array(_str("Ghost"))
		var res = net.call("decode_result", r)
		_check(res != null and not res.ok and res.type == 2 and res.index == 9 and res.code == 3 and res.target == "Ghost",
			"decode_result reads ok, type, index, the u16 code and the target")
	else:
		_check(false, "ChatNet has decode_result")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
