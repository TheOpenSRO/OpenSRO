extends SceneTree

## Exercises EfpReader against synthetic effects (never real game data), run
## headless:
## `godot4 --headless --path client --script res://scripts/efp/efp_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _append_u32(buf: PackedByteArray, v: int) -> PackedByteArray:
	var lp := PackedByteArray()
	lp.resize(4)
	lp[0] = v & 0xFF
	lp[1] = (v >> 8) & 0xFF
	lp[2] = (v >> 16) & 0xFF
	lp[3] = (v >> 24) & 0xFF
	var out := buf.duplicate()
	out.append_array(lp)
	return out

func _append_len_prefixed(buf: PackedByteArray, s: String) -> PackedByteArray:
	var sb := s.to_ascii_buffer()
	buf = _append_u32(buf, sb.size())
	var out := buf.duplicate()
	out.append_array(sb)
	return out

func _append_zeros(buf: PackedByteArray, n: int) -> PackedByteArray:
	var pad := PackedByteArray()
	pad.resize(n)
	var out := buf.duplicate()
	out.append_array(pad)
	return out

## magic + version header + root head length + name + one controller, the smallest
## root the flat walk accepts (mirrors header_test.go's headerFor).
func _build_header(version: String, root_name: String) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array((EfpReader.MAGIC + " " + version).to_ascii_buffer())
	if version == "0012":
		buf = _append_u32(buf, 0x3ecccccd) # 0.4
	elif version == "0013":
		buf = _append_u32(buf, 0x3f000000) # 0.5
		buf = _append_zeros(buf, 12)
	buf = _append_u32(buf, 101) # root node id
	buf = _append_len_prefixed(buf, root_name)
	buf = _append_u32(buf, 1)
	buf = _append_len_prefixed(buf, "NormalTimeLife")
	buf = _append_len_prefixed(buf, "StaticEmit")
	buf = _append_zeros(buf, 20)
	return buf

func _build_0011() -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array(EfpReader.MAGIC.to_ascii_buffer())
	buf.append_array(" ".to_ascii_buffer())
	buf.append_array("0011".to_ascii_buffer())
	buf = _append_u32(buf, 0) # unconfirmed u32
	buf = _append_len_prefixed(buf, "myeffect")
	buf = _append_u32(buf, 2) # top-level count

	buf = _append_len_prefixed(buf, "NormalTimeLife")
	buf = _append_zeros(buf, 8)

	buf = _append_len_prefixed(buf, "StaticEmit")
	buf = _append_zeros(buf, 20)

	return buf

func _build_0013() -> PackedByteArray:
	var buf := PackedByteArray()
	buf.append_array(EfpReader.MAGIC.to_ascii_buffer())
	buf.append_array(" ".to_ascii_buffer())
	buf.append_array("0013".to_ascii_buffer())
	buf = _append_u32(buf, 0x3f000000) # unconfirmed float32 (0.5)
	buf = _append_zeros(buf, 12) # reserved bytes, observed zero
	buf = _append_u32(buf, 193) # unconfirmed u32
	buf = _append_len_prefixed(buf, "fireball")
	buf = _append_u32(buf, 1) # top-level count

	buf = _append_len_prefixed(buf, "NormalTimeLife")
	buf = _append_zeros(buf, 4)

	return buf

func _init() -> void:
	var data := _build_0011()
	var e := EfpReader.parse(data)
	_check(e != null, "parses synthetic 0011 effect")
	if e != null:
		_check(e.version == "0011", "version matches (got %s)" % e.version)
		_check(e.effect_name == "myeffect", "name matches (got %s)" % e.effect_name)
		_check(e.count == 2, "count matches (got %d)" % e.count)
		_check(e.entries.size() == 2, "2 entries (got %d)" % e.entries.size())
		if e.entries.size() == 2:
			_check(e.entries[0].entry_name == "NormalTimeLife" and e.entries[0].value.size() == 8, "entry 1 matches")
			_check(e.entries[1].entry_name == "StaticEmit" and e.entries[1].value.size() == 20, "entry 2 matches")

	var data13 := _build_0013()
	var e13 := EfpReader.parse(data13)
	_check(e13 != null, "parses synthetic 0013 effect")
	if e13 != null:
		_check(e13.version == "0013", "0013 version matches (got %s)" % e13.version)
		_check(e13.effect_name == "fireball", "0013 name matches (got %s)" % e13.effect_name)
		_check(e13.entries.size() == 1 and e13.entries[0].entry_name == "NormalTimeLife", "0013 entries match")

	var bad_magic := PackedByteArray()
	bad_magic.resize(30)
	_check(EfpReader.parse(bad_magic) == null, "rejects bad magic")

	var bad_version := PackedByteArray()
	bad_version.append_array(EfpReader.MAGIC.to_ascii_buffer())
	bad_version.append_array(" ".to_ascii_buffer())
	bad_version.append_array("9999".to_ascii_buffer())
	bad_version = _append_zeros(bad_version, 20)
	_check(EfpReader.parse(bad_version) == null, "rejects unrecognized version")

	var truncated := data.slice(0, 20)
	_check(EfpReader.parse(truncated) == null, "rejects truncated buffer")

	# Round 619: the client's header variants (FUN_00cb8d70) -- an f32 after
	# the magic from "0012", three u32 more from "0013" -- then the root node's head length.
	for v in ["0010", "0011", "0012", "0013"]:
		var ev := EfpReader.parse(_build_header(v, "fx"))
		_check(ev != null and ev.version == v and ev.effect_name == "fx" and ev.count == 1,
			"header variant %s parses" % v)
	# The root name is any printable string (retail has "11111", "-...").
	for nm in ["11111", "-fire", "big wave,2"]:
		var en := EfpReader.parse(_build_header("0011", nm))
		_check(en != null and en.effect_name == nm, "relaxed root name %s" % nm)
	# EUC-KR bytes, as system_levelup.efp's root name is (name bytes at 20..25).
	var kr := _build_header("0011", "KKKKKK")
	var kr_bytes := [0xb7, 0xb9, 0xba, 0xa7, 0xbe, 0xf7]
	for i in range(6):
		kr[20 + i] = kr_bytes[i]
	_check(EfpReader.parse(kr) != null, "root name in EUC-KR bytes parses")
	_check(EfpReader.parse(_build_header("0000", "fx")) == null, "rejects version 0000 (not the node format)")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
