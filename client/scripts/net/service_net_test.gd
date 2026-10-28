extends SceneTree

## Round 838: ServiceNet, the service scrolls' OURS messages -- the bytes the
## server's servicescroll.go writes (its Go tests read the same layouts).
##   godot4 --headless --path client --script res://scripts/net/service_net_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _hex(s: String) -> PackedByteArray:
	var out := PackedByteArray()
	for t in s.split(" ", false):
		out.append(t.hex_to_int())
	return out

func _initialize() -> void:
	# 0x0139 {str "Aria", str "Arion"}.
	var want := _hex("04 00") + "Aria".to_utf8_buffer() + _hex("05 00") + "Arion".to_utf8_buffer()
	_check(ServiceNet.encode_rename("Aria", "Arion") == want, "0x0139's bytes (got %s)" % ServiceNet.encode_rename("Aria", "Arion").hex_encode())
	# 0x013A: {1, 0, "Arion"} and {2, 0x410, ""}.
	var ok := ServiceNet.decode_rename_result(_hex("01 00 00 05 00") + "Arion".to_utf8_buffer())
	_check(bool(ok["ok"]) and int(ok["code"]) == 0 and String(ok["name"]) == "Arion", "0x013A done (got %s)" % str(ok))
	var no := ServiceNet.decode_rename_result(_hex("02 10 04 00 00"))
	_check(not bool(no["ok"]) and int(no["code"]) == 0x410, "0x013A refused 0x410 (got %s)" % str(no))
	# 0x013B {uid 7, name 0xFFFF2020, title 0}.
	var c := ServiceNet.decode_plate_colours(_hex("07 00 00 00  20 20 ff ff  00 00 00 00"))
	_check(int(c["uid"]) == 7 and int(c["name"]) == 0xFFFF2020 and int(c["title"]) == 0, "0x013B (got %s)" % str(c))
	_check(ServiceNet.decode_plate_colours(_hex("07 00 00")).is_empty(), "a short 0x013B")
	# The colours: ARGB to a Color, 0 the plate's default.
	var white := Color(1, 1, 1)
	_check(ServiceNet.argb_colour(0, white) == white, "0 keeps the default")
	_check(ServiceNet.argb_colour(0xFF000000, white) == Color(0, 0, 0, 1), "black is a colour, not the default")
	_check(ServiceNet.argb_colour(0xFF87CEEB, white) == Color8(0x87, 0xce, 0xeb), "sky blue")
	# The dictionary: a colour, then the reset back to the defaults.
	var s := ServiceNet.new()
	var seen: Array = []
	s.plate_colours_changed.connect(func(uid: int) -> void: seen.append(uid))
	var handlers := {}
	var host := _Host.new(handlers)
	s.register_with(host)
	(handlers[ServiceNet.OP_PLATE_COLOURS] as Callable).call(_hex("07 00 00 00  20 20 ff ff  eb ce 87 ff"))
	_check(s.name_colour(7, white) == Color8(0xff, 0x20, 0x20) and s.title_colour(7, Color(1, 0.9, 0.36)) == Color8(0x87, 0xce, 0xeb),
		"uid 7 red name, sky title")
	_check(s.name_colour(8, white) == white, "another uid keeps the default")
	(handlers[ServiceNet.OP_PLATE_COLOURS] as Callable).call(_hex("07 00 00 00  00 00 00 00  00 00 00 00"))
	_check(not s.plate_colours.has(7) and seen == [7, 7], "the reset forgets uid 7 (seen %s)" % str(seen))
	var lines: Array = []
	s.line.connect(func(t: String) -> void: lines.append(t))
	(handlers[ServiceNet.OP_LINE] as Callable).call(_hex("05 00") + "hello".to_utf8_buffer())
	_check(lines == ["hello"], "0x0138's line (got %s)" % str(lines))
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

## Stands in for NetClient's register_handler.
class _Host:
	extends Node
	var _h: Dictionary
	func _init(h: Dictionary) -> void:
		_h = h
	func register_handler(op: int, f: Callable) -> void:
		_h[op] = f
