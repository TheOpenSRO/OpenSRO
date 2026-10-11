extends SceneTree

## Round 774: navmesh\objectstring.ifo (ObjectStringReader). Synthetic lines
## only. Run headless:
## `godot4 --headless --path client --script res://scripts/world/object_string_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

static func _bits(f: float) -> String:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, f)
	return "0x%08x" % b.decode_u32(0)

func _line(rx: int, rz: int, p: Vector3, yaw: float, name: String) -> String:
	return "0xffff0001 0x00000000 %d %d %s %s %s %s \"%s\"" % [rx, rz, _bits(p.x), _bits(p.y), _bits(p.z), _bits(yaw), name]

func _init() -> void:
	var text := "JMXVOBJI1000\r\n2\r\n%s\r\n%s\r\n" % [
		_line(147, 106, Vector3(1615.25, 474.5, 48.5), -1.5, "GATE_SYNTH_IN"),
		_line(1, 128, Vector3(-20.0, 0.0, -864.0), 0.0, "GATE_SYNTH_OUT")]
	var got := ObjectStringReader.parse(text.to_ascii_buffer())
	_check(got.size() == 2, "two lines, two entries (got %d)" % got.size())
	if got.size() == 2:
		var a: ObjectStringReader.Entry = got[0]
		_check(a.name == "GATE_SYNTH_IN", "the quoted name")
		_check(a.region == 0x6A93 and a.region_xy() == Vector2i(106, 147) and not a.is_dungeon(),
			"region id (rz << 8) | rx, the client's region (high, low) = (106, 147)")
		_check(a.position.is_equal_approx(Vector3(1615.25, 474.5, 48.5)) and is_equal_approx(a.yaw, -1.5),
			"the floats from their bit patterns")
		var b: ObjectStringReader.Entry = got[1]
		_check(b.region == 0x8001 and b.is_dungeon() and b.position.z == -864.0, "a dungeon row: rz 128, 0x8001")
	var short := "JMXVOBJI1000\n3\n%s\n" % _line(1, 2, Vector3.ZERO, 0.0, "X")
	_check(ObjectStringReader.parse(short.to_ascii_buffer()).is_empty(), "a count the lines do not meet refuses the file")
	var bad := "JMXVOBJI1000\n1\n0xffff0001 0x0 1 2 0x0 0x0 \"X\"\n"
	_check(ObjectStringReader.parse(bad.to_ascii_buffer()).is_empty(), "a line short of fields refuses the file")
	_check(ObjectStringReader.parse("JMXVOBJX1000\n0\n".to_ascii_buffer()).is_empty(), "another magic is not one")
	print("object_string_reader_test: %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)
