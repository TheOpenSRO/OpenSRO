extends SceneTree

## Exercises BsrReader against a synthetic object (never real game data), run
## headless: `godot4 --headless --path client --script res://scripts/bsr/bsr_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _put_u32(b: PackedByteArray, off: int, v: int) -> void:
	b[off] = v & 0xFF
	b[off + 1] = (v >> 8) & 0xFF
	b[off + 2] = (v >> 16) & 0xFF
	b[off + 3] = (v >> 24) & 0xFF

func _put_f32(b: PackedByteArray, off: int, v: float) -> void:
	var enc := PackedByteArray()
	enc.resize(4)
	enc.encode_float(0, v)
	for i in range(4):
		b[off + i] = enc[i]

func _append_len_prefixed(buf: PackedByteArray, s: String) -> PackedByteArray:
	var sb := s.to_ascii_buffer()
	var out := buf.duplicate()
	var lp := PackedByteArray()
	lp.resize(4 + sb.size())
	for i in range(sb.size()):
		lp[4 + i] = sb[i]
	_put_u32(lp, 0, sb.size())
	out.append_array(lp)
	return out

func _build_synthetic_object(obj_name: String, mesh_path: String, material_path: String, sub_paths: Array) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(BsrReader.PREAMBLE_END)
	var magic := BsrReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]

	buf = _append_len_prefixed(buf, obj_name)

	var pad := PackedByteArray()
	pad.resize(48) # 2 unconfirmed u32 fields + 40 zero padding bytes
	_put_u32(pad, 0, 10)
	_put_u32(pad, 4, 2)
	buf.append_array(pad)

	buf = _append_len_prefixed(buf, mesh_path)

	var bbox := PackedByteArray()
	bbox.resize(60) # 6-float bbox + sentinel/flag tail observed in real files
	var mins := [-5.0, 0.0, -5.0]
	var maxs := [5.0, 10.0, 5.0]
	for i in range(3):
		_put_f32(bbox, i * 4, mins[i])
		_put_f32(bbox, 12 + i * 4, maxs[i])
	buf.append_array(bbox)

	buf = _append_len_prefixed(buf, material_path)

	var count_bytes := PackedByteArray()
	count_bytes.resize(4)
	_put_u32(count_bytes, 0, sub_paths.size())
	buf.append_array(count_bytes)
	for p in sub_paths:
		buf = _append_len_prefixed(buf, p)

	return buf

func _init() -> void:
	var data := _build_synthetic_object(
		"TestObj01",
		"prim\\mesh\\bldg\\testobj01.bms",
		"prim\\mtrl\\bldg\\testobj01.bmt",
		["prim\\mesh\\bldg\\testobj01_part2.bms", "prim\\mesh\\bldg\\testobj01_part3.bms"])

	var obj := BsrReader.parse(data)
	_check(obj != null, "parses synthetic object")
	if obj != null:
		_check(obj.object_name == "TestObj01", "name matches (got %s)" % obj.object_name)
		_check(obj.mesh_path == "prim\\mesh\\bldg\\testobj01.bms", "mesh path matches (got %s)" % obj.mesh_path)
		_check(obj.material_path == "prim\\mtrl\\bldg\\testobj01.bmt", "material path matches (got %s)" % obj.material_path)
		_check(obj.has_bounds, "bounds located")
		_check(obj.bounds_min == Vector3(-5, 0, -5) and obj.bounds_max == Vector3(5, 10, 5), "bounds match (got min=%s max=%s)" % [obj.bounds_min, obj.bounds_max])
		_check(obj.sub_mesh_paths.size() == 2, "2 sub-mesh paths (got %d)" % obj.sub_mesh_paths.size())
		if obj.sub_mesh_paths.size() == 2:
			_check(obj.sub_mesh_paths[0] == "prim\\mesh\\bldg\\testobj01_part2.bms", "sub-mesh path[0] matches (got %s)" % obj.sub_mesh_paths[0])

	var simple := _build_synthetic_object("Simple01", "prim\\mesh\\simple01.bms", "prim\\mtrl\\simple01.bmt", [])
	var simple_obj := BsrReader.parse(simple)
	_check(simple_obj != null and simple_obj.sub_mesh_paths.size() == 0, "object with no sub-meshes parses cleanly")

	var bad_magic := PackedByteArray()
	bad_magic.resize(BsrReader.PREAMBLE_END)
	_check(BsrReader.parse(bad_magic) == null, "rejects bad magic")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
