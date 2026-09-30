extends SceneTree

## Round 651's review: NetClient keeps every character's berserk body mode
## (0x30BF kind 4) as it dispatches it, so a body built AFTER a remote "1"
## arrived -- a relog beside a berserk player, an arrival list laid out after
## the server's in-view replay -- still takes the look (World3D._berserk_resync
## reads NetClient.body_modes). Driven through NetClient's own dispatch with
## synthetic packets. Run headless:
## `godot4 --headless --path client --script res://scripts/net/body_mode_book_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _state(id: int, kind: int, value: int, extra: bool) -> Packet:
	var d := PackedByteArray()
	d.resize(7 if extra else 6)
	d.encode_u32(0, id)
	d.encode_u8(4, kind)
	d.encode_u8(5, value)
	return Packet.new(WorldNet.OP_STATE_CHANGE, d)

func _left(id: int) -> Packet:
	var d := PackedByteArray()
	d.resize(8)
	d.encode_s64(0, id)
	return Packet.new(WorldNet.OP_ENTITY_LEFT, d)

func _initialize() -> void:
	var net: Node = (load("res://scripts/net/net_client.gd") as GDScript).new()
	var heard: Array = []
	net.state_changed.connect(func(c) -> void: heard.append(c))
	net.call("_dispatch", _state(7, WorldNet.STATE_KIND_BODY_MODE, 1, true))
	var book = net.get("body_modes")
	_check(book is Dictionary and int((book as Dictionary).get(7, 0)) == 1,
		"a remote berserk (kind 4 value 1) is kept for a body built later (book %s)" % [book])
	_check(heard.size() == 1, "and still reaches state_changed")
	net.call("_dispatch", _state(8, WorldNet.STATE_KIND_BODY_MODE, 1, true))
	net.call("_dispatch", _state(8, WorldNet.STATE_KIND_MOTION, 4, false))
	book = net.get("body_modes")
	_check(book is Dictionary and (book as Dictionary).has(8), "a motion change leaves it")
	net.call("_dispatch", _state(8, WorldNet.STATE_KIND_BODY_MODE, 0, false))
	book = net.get("body_modes")
	_check(book is Dictionary and not (book as Dictionary).has(8) and (book as Dictionary).has(7),
		"its end (value 0) clears only that character (book %s)" % [book])
	net.call("_dispatch", _left(7))
	book = net.get("body_modes")
	_check(book is Dictionary and (book as Dictionary).is_empty(), "who leaves takes their body mode along (book %s)" % [book])
	net.free()
	print("ALL PASS" if _failures == 0 else "%d FAILED" % _failures)
	quit(0 if _failures == 0 else 1)
