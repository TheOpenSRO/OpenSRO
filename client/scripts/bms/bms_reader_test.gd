extends SceneTree

## Exercises BmsReader against a synthetic mesh (never real game data), run
## headless: `godot4 --headless --path client --script res://scripts/bms/bms_reader_test.gd`

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

func _build_synthetic_mesh(rec_size: int = 44, skinned: bool = false) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(BmsReader.PREAMBLE_END)
	var magic := BmsReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]

	buf = _append_len_prefixed(buf, "Tri01")
	buf = _append_len_prefixed(buf, "Mat01")

	var count_bytes := PackedByteArray()
	count_bytes.resize(8)
	_put_u32(count_bytes, 0, 1) # unconfirmed constant
	_put_u32(count_bytes, 4, 3) # vertex count
	buf.append_array(count_bytes)

	var positions := [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)]
	var normal := Vector3(0, 1, 0)
	var uvs := [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)]
	for i in range(3):
		var rec := PackedByteArray()
		rec.resize(rec_size)
		_put_f32(rec, 0x00, positions[i].x)
		_put_f32(rec, 0x04, positions[i].y)
		_put_f32(rec, 0x08, positions[i].z)
		_put_f32(rec, 0x0c, normal.x)
		_put_f32(rec, 0x10, normal.y)
		_put_f32(rec, 0x14, normal.z)
		_put_f32(rec, 0x18, uvs[i].x)
		_put_f32(rec, 0x1c, uvs[i].y)
		if rec_size > 0x24 + 4:
			_put_u32(rec, 0x24, 0xFFFFFFFF)
		buf.append_array(rec)

	# Optional skin section, between the vertices and the indices, exactly
	# where a real character mesh puts it: header word 0 points at a bone
	# palette, then one 6-byte weight record per vertex, ending precisely
	# where header word 1 (the index section) begins.
	if skinned:
		var skin_off := buf.size()
		_put_u32(buf, BmsReader.HEADER_PTRS_BASE + 0 * 4, skin_off)
		var palette := PackedByteArray()
		palette.resize(4)
		_put_u32(palette, 0, 2) # two bones
		buf.append_array(palette)
		buf = _append_len_prefixed(buf, "Bip01 Spine")
		buf = _append_len_prefixed(buf, "Bip01 L Hand")
		var skin := PackedByteArray()
		skin.resize(3 * BmsReader.SKIN_REC_SIZE)
		# v0: entirely on bone 0.
		skin[0] = 0
		skin[1] = 0xFF
		skin[2] = 0xFF
		skin[3] = BmsReader.NO_BONE
		skin[4] = 0
		skin[5] = 0
		# v1: an even split between bone 0 and bone 1, as a real 50/50
		# vertex is written -- 32765 twice, which is not quite full scale.
		skin[6] = 0
		skin[7] = 253
		skin[8] = 127
		skin[9] = 1
		skin[10] = 253
		skin[11] = 127
		# v2: entirely on bone 1.
		skin[12] = 1
		skin[13] = 0xFF
		skin[14] = 0xFF
		skin[15] = BmsReader.NO_BONE
		skin[16] = 0
		skin[17] = 0
		buf.append_array(skin)

	var index_off := buf.size()
	_put_u32(buf, BmsReader.HEADER_PTRS_BASE + 1 * 4, index_off)
	var idx := PackedByteArray()
	idx.resize(4 + 6)
	_put_u32(idx, 0, 1) # triangle count
	idx[4] = 0
	idx[5] = 0
	idx[6] = 1
	idx[7] = 0
	idx[8] = 2
	idx[9] = 0
	buf.append_array(idx)

	var bbox_off := buf.size()
	_put_u32(buf, BmsReader.HEADER_PTRS_BASE + 4 * 4, bbox_off)
	var bbox := PackedByteArray()
	bbox.resize(24)
	var mins := [0.0, 0.0, 0.0]
	var maxs := [1.0, 0.0, 1.0]
	for i in range(3):
		_put_f32(bbox, i * 4, mins[i])
		_put_f32(bbox, 12 + i * 4, maxs[i])
	buf.append_array(bbox)

	return buf

func _init() -> void:
	var data := _build_synthetic_mesh()
	var mesh := BmsReader.parse(data)
	_check(mesh != null, "parses synthetic mesh")
	if mesh != null:
		_check(mesh.mesh_name == "Tri01" and mesh.material_name == "Mat01", "names match (got %s / %s)" % [mesh.mesh_name, mesh.material_name])
		_check(mesh.vertices.size() == 3, "3 vertices (got %d)" % mesh.vertices.size())
		_check(mesh.indices.size() == 3, "3 indices (got %d)" % mesh.indices.size())
		if mesh.vertices.size() == 3:
			_check(mesh.vertices[1].position == Vector3(1, 0, 0), "v1 position (got %s)" % mesh.vertices[1].position)
			_check(mesh.vertices[1].normal == Vector3(0, 1, 0), "v1 normal (got %s)" % mesh.vertices[1].normal)
			_check(mesh.vertices[1].uv == Vector2(1, 0), "v1 uv (got %s)" % mesh.vertices[1].uv)
		_check(mesh.bounds_min == Vector3(0, 0, 0) and mesh.bounds_max == Vector3(1, 0, 1), "bounds match (got min=%s max=%s)" % [mesh.bounds_min, mesh.bounds_max])

		var array_mesh := BmsReader.to_array_mesh(mesh)
		_check(array_mesh != null, "builds a Godot ArrayMesh")
		_check(array_mesh.get_surface_count() == 1, "ArrayMesh has 1 surface")

		# Real winding reversal (see to_array_mesh's own doc comment): the
		# real .bms index buffer winds each triangle opposite to Godot's
		# front-face convention, so feeding it through unchanged renders
		# every real object inside-out. Each triangle must come back with
		# its 2nd and 3rd indices swapped, and nothing else changed --
		# proved against real data, so it's worth pinning here.
		if array_mesh != null and array_mesh.get_surface_count() == 1:
			var out_idx: PackedInt32Array = array_mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
			_check(out_idx.size() == mesh.indices.size(), "winding reversal keeps the real triangle count (got %d, want %d)" % [out_idx.size(), mesh.indices.size()])
			var reversed_ok := out_idx.size() == mesh.indices.size()
			for t in range(0, mesh.indices.size() - 2, 3):
				if out_idx[t] != mesh.indices[t] or out_idx[t + 1] != mesh.indices[t + 2] or out_idx[t + 2] != mesh.indices[t + 1]:
					reversed_ok = false
					break
			_check(reversed_ok, "each real triangle's 2nd/3rd indices are swapped (parsed=%s built=%s)" % [mesh.indices, out_idx])

	var bad_magic := PackedByteArray()
	bad_magic.resize(BmsReader.PREAMBLE_END)
	_check(BmsReader.parse(bad_magic) == null, "rejects bad magic")

	# Real self-validating stride detection (2026-08-23) -- see
	# VERTEX_REC_SIZE_CANDIDATES's doc comment: some real, larger building
	# meshes use a real 52-byte vertex record instead of the documented
	# 44-byte one, with no reliable per-file flag distinguishing the two.
	var data52 := _build_synthetic_mesh(52)
	var mesh52 := BmsReader.parse(data52)
	_check(mesh52 != null, "parses a synthetic mesh with real 52-byte vertex records")
	if mesh52 != null:
		_check(mesh52.vertices.size() == 3, "52-byte: 3 vertices (got %d)" % mesh52.vertices.size())
		if mesh52.vertices.size() == 3:
			_check(mesh52.vertices[1].position == Vector3(1, 0, 0), "52-byte: v1 position (got %s)" % mesh52.vertices[1].position)
			_check(mesh52.vertices[0].extra.size() == 20, "52-byte: 20 real trailing Extra bytes (got %d)" % mesh52.vertices[0].extra.size())

	# Skinning. This project recorded that ".bms carries no per-vertex
	# skinning data", from accounting for the 44-byte vertex record and
	# finding no room in it. That is true and beside the point: the weights
	# live in their own section, pointed at by header word 0.
	var skinned_mesh := BmsReader.parse(_build_synthetic_mesh(44, true))
	_check(skinned_mesh != null, "a mesh with a skin section parses")
	if skinned_mesh != null:
		_check(skinned_mesh.is_skinned(), "the mesh reports itself skinned")
		_check(skinned_mesh.bone_names.size() == 2,
			"both palette bones read (got %d)" % skinned_mesh.bone_names.size())
		_check(skinned_mesh.bone_names[0] == "Bip01 Spine",
			"palette names round-trip (got %s)" % skinned_mesh.bone_names[0])
		var v0: BmsReader.Vertex = skinned_mesh.vertices[0]
		_check(v0.bone0 == 0 and v0.bone1 == -1,
			"a single-influence vertex has no second bone (got %d/%d)" % [v0.bone0, v0.bone1])
		_check(is_equal_approx(v0.weight0, 1.0),
			"a single-influence vertex weighs 1.0 (got %f)" % v0.weight0)
		var v1: BmsReader.Vertex = skinned_mesh.vertices[1]
		_check(v1.bone0 == 0 and v1.bone1 == 1,
			"a two-influence vertex names both bones (got %d/%d)" % [v1.bone0, v1.bone1])
		# 32765 + 32765 is 65530, not 65535, so the weights are normalised
		# rather than trusted -- an unnormalised weight stretches its vertex.
		_check(is_equal_approx(v1.weight0, 0.5) and is_equal_approx(v1.weight1, 0.5),
			"a 50/50 vertex normalises to 0.5/0.5 (got %f/%f)" % [v1.weight0, v1.weight1])
		_check(is_equal_approx(v1.weight0 + v1.weight1, 1.0), "weights sum to 1")

		var skinned_arrays := BmsReader.to_array_mesh(skinned_mesh).surface_get_arrays(0)
		_check(skinned_arrays[Mesh.ARRAY_BONES] != null and skinned_arrays[Mesh.ARRAY_WEIGHTS] != null,
			"the ArrayMesh carries bone and weight arrays")

	# And a mesh with no skin section stays unskinned rather than inventing
	# one -- scenery is the common case.
	var plain := BmsReader.parse(_build_synthetic_mesh(44, false))
	_check(plain != null and not plain.is_skinned(), "a mesh with no skin section is not skinned")
	if plain != null:
		var plain_arrays := BmsReader.to_array_mesh(plain).surface_get_arrays(0)
		_check(plain_arrays[Mesh.ARRAY_BONES] == null,
			"an unskinned mesh gets no bone array")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
