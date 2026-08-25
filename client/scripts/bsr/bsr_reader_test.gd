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

## Builds a synthetic .bsr-shaped buffer (never real game data) matching
## the real "nature"-category field order confirmed against a real
## center_asia_plant01_01.bsr: name, two unconfirmed fields + padding,
## bounding box + sentinel tail, material path, a count field, then the
## mesh path last -- the opposite order from _build_synthetic_object's
## "building"-category layout. See docs/protocol/BSR_FORMAT.md.
func _build_synthetic_nature_object(obj_name: String, material_path: String, mesh_path: String) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(BsrReader.PREAMBLE_END)
	var magic := BsrReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]

	buf = _append_len_prefixed(buf, obj_name)

	var pad := PackedByteArray()
	pad.resize(52) # 2 unconfirmed u32 fields + 44 zero padding bytes
	_put_u32(pad, 0, 11)
	_put_u32(pad, 4, 2)
	buf.append_array(pad)

	var bbox := PackedByteArray()
	bbox.resize(60)
	var mins := [-1.0, 0.0, -1.0]
	var maxs := [1.0, 2.0, 1.0]
	for i in range(3):
		_put_f32(bbox, i * 4, mins[i])
		_put_f32(bbox, 12 + i * 4, maxs[i])
	buf.append_array(bbox)

	buf = _append_len_prefixed(buf, material_path)
	var count_bytes := PackedByteArray()
	count_bytes.resize(4)
	_put_u32(count_bytes, 0, 1) # real files show a "1" field here
	buf.append_array(count_bytes)
	buf = _append_len_prefixed(buf, mesh_path)

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

	# Real failure mode found live-testing real Jangan palace buildings
	# (2026-08-23): a declared sub-mesh count larger than how many further
	# real path strings are actually present. parse() must return the real
	# primary mesh/material data plus whatever real sub-mesh paths did
	# parse, not fail the whole object.
	var overdeclared := _build_synthetic_object(
		"TestObj02",
		"prim\\mesh\\bldg\\testobj02.bms",
		"prim\\mtrl\\bldg\\testobj02.bmt",
		["prim\\mesh\\bldg\\testobj02_part2.bms"])
	# Overwrite the declared sub-mesh count (the uint32 right before the
	# one real sub-mesh path) to claim 3 real paths follow when only 1
	# actually does.
	var sub_count_off := overdeclared.size() - (4 + "prim\\mesh\\bldg\\testobj02_part2.bms".length()) - 4
	_put_u32(overdeclared, sub_count_off, 3)
	var overdeclared_obj := BsrReader.parse(overdeclared)
	_check(overdeclared_obj != null, "an overdeclared sub-mesh count still yields a graceful partial result, not null")
	if overdeclared_obj != null:
		_check(overdeclared_obj.mesh_path == "prim\\mesh\\bldg\\testobj02.bms", "overdeclared: mesh path still matches (got %s)" % overdeclared_obj.mesh_path)
		_check(overdeclared_obj.sub_mesh_paths.size() == 1, "overdeclared: 1 real sub-mesh path survives (got %d)" % overdeclared_obj.sub_mesh_paths.size())

	var bad_magic := PackedByteArray()
	bad_magic.resize(BsrReader.PREAMBLE_END)
	_check(BsrReader.parse(bad_magic) == null, "rejects bad magic")

	# Real, genuine mesh-less variant, not a parse failure: real
	# "*_particle.bsr" files (e.g. wreck_sship_particle.bsr, placed over
	# 1,200 times combined across a real client's map data -- found
	# auditing this project's own full real object catalog, 2026-08-25)
	# carry a real material plus real .efp particle-effect references
	# instead of any .bms mesh at all.
	var particle_buf := PackedByteArray()
	particle_buf.resize(BsrReader.PREAMBLE_END)
	var particle_magic := BsrReader.MAGIC.to_ascii_buffer()
	for i in range(particle_magic.size()):
		particle_buf[i] = particle_magic[i]
	particle_buf = _append_len_prefixed(particle_buf, "wreck_sship_particle")
	var particle_pad := PackedByteArray()
	particle_pad.resize(40)
	particle_buf.append_array(particle_pad)
	particle_buf = _append_len_prefixed(particle_buf, "prim\\mtrl\\dun\\property\\wreck\\wreck_float.bmt")
	var particle_obj := BsrReader.parse(particle_buf)
	_check(particle_obj != null, "parses a real mesh-less particle object instead of erroring")
	if particle_obj != null:
		_check(particle_obj.object_name == "wreck_sship_particle", "particle object name matches (got %s)" % particle_obj.object_name)
		_check(particle_obj.mesh_path == "", "particle object has an empty real mesh path (got %s)" % particle_obj.mesh_path)
		_check(particle_obj.material_path == "prim\\mtrl\\dun\\property\\wreck\\wreck_float.bmt", "particle object material path matches (got %s)" % particle_obj.material_path)

	# Real failure mode found live-testing a real Jangan-adjacent tree
	# (2026-08-23, "tre_bank02.bsr"): a real zero-length sub-mesh path,
	# never a real usable reference -- it means the real sub-mesh list
	# already ended and this read spilled into the file's own trailing
	# boilerplate. parse() must stop there rather than recording a
	# sub-mesh path nothing can ever resolve.
	var with_empty_sub := _build_synthetic_object(
		"TestObj03",
		"prim\\mesh\\bldg\\testobj03.bms",
		"prim\\mtrl\\bldg\\testobj03.bmt",
		["prim\\mesh\\bldg\\testobj03_part2.bms", ""])
	var with_empty_sub_obj := BsrReader.parse(with_empty_sub)
	_check(with_empty_sub_obj != null, "an empty sub-mesh path still yields a parsed object")
	if with_empty_sub_obj != null:
		_check(with_empty_sub_obj.sub_mesh_paths.size() == 1, "empty sub-mesh path dropped, 1 real one survives (got %d)" % with_empty_sub_obj.sub_mesh_paths.size())
		if with_empty_sub_obj.sub_mesh_paths.size() == 1:
			_check(with_empty_sub_obj.sub_mesh_paths[0] == "prim\\mesh\\bldg\\testobj03_part2.bms", "surviving sub-mesh path matches (got %s)" % with_empty_sub_obj.sub_mesh_paths[0])

	# A second real shape of the same real failure mode (2026-08-23,
	# "tre_maple01.bsr"): a real *non-empty* garbage sub-mesh path (a
	# single stray real byte, "6", not a plausible ".bms" path) read from
	# the file's own trailing boilerplate. parse() must stop there rather
	# than recording it, same as the empty-path case.
	var with_garbage_sub := _build_synthetic_object(
		"TestObj04",
		"prim\\mesh\\bldg\\testobj04.bms",
		"prim\\mtrl\\bldg\\testobj04.bmt",
		["prim\\mesh\\bldg\\testobj04_part2.bms", "6"])
	var with_garbage_sub_obj := BsrReader.parse(with_garbage_sub)
	_check(with_garbage_sub_obj != null, "a garbage sub-mesh path still yields a parsed object")
	if with_garbage_sub_obj != null:
		_check(with_garbage_sub_obj.sub_mesh_paths.size() == 1, "garbage sub-mesh path dropped, 1 real one survives (got %d)" % with_garbage_sub_obj.sub_mesh_paths.size())

	var nature_data := _build_synthetic_nature_object(
		"test_plant01",
		"prim\\mtrl\\nature\\test_plant01.bmt",
		"prim\\mesh\\nature\\test_plant01.bms")
	var nature_obj := BsrReader.parse(nature_data)
	_check(nature_obj != null, "parses synthetic nature-category object")
	if nature_obj != null:
		_check(nature_obj.mesh_path == "prim\\mesh\\nature\\test_plant01.bms", "nature: mesh path matches (got %s)" % nature_obj.mesh_path)
		_check(nature_obj.material_path == "prim\\mtrl\\nature\\test_plant01.bmt", "nature: material path matches (got %s)" % nature_obj.material_path)
		_check(not nature_obj.has_bounds, "nature: bounds not claimed (position not confirmed for this order)")
		_check(nature_obj.sub_mesh_paths.size() == 0, "nature: no sub-mesh paths claimed")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
