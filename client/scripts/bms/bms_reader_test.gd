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

func _read_u32(b: PackedByteArray, off: int) -> int:
	return b.decode_u32(off)

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

func _build_synthetic_mesh(rec_size: int = 44, skinned: bool = false, motion: bool = false, empty_first_slot: bool = false, both_empty: bool = false) -> PackedByteArray:
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
		if empty_first_slot:
			# v2 the way Degree-11 armour writes a few of its vertices
			# (round 626): the FIRST slot empty, the second at full weight.
			skin[12] = BmsReader.NO_BONE
			skin[13] = 0
			skin[14] = 0
			skin[15] = 1
			skin[16] = 0xFF
			skin[17] = 0xFF
		if both_empty:
			# v2 with NEITHER slot used, as heavy_15_ba writes 14 vertices.
			skin[12] = BmsReader.NO_BONE
			skin[13] = 0
			skin[14] = 0
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

	# Optional per-vertex motion section (header word 2): a count that must
	# equal the vertex count, then a float32 + uint32 for each. See
	# docs/protocol/BMS_FORMAT.md.
	if motion:
		var motion_off := buf.size()
		_put_u32(buf, BmsReader.HEADER_PTRS_BASE + 2 * 4, motion_off)
		var section := PackedByteArray()
		section.resize(4 + 3 * BmsReader.VERTEX_MOTION_REC_SIZE)
		_put_u32(section, 0, 3)
		# Two pinned vertices (amount 0, flag 1) and one free one, which is
		# how every real file is shaped: the flag is 1 exactly where the
		# amount is zero.
		var amounts := [0.0, 0.15, 0.0]
		var flags := [1, 0, 1]
		for i in range(3):
			_put_f32(section, 4 + i * 8, amounts[i])
			_put_u32(section, 4 + i * 8 + 4, flags[i])
		buf.append_array(section)

	# Optional link section (header word 3): a count, then two vertex
	# indices and a distance for each. A real file follows the records with
	# a trailer this reader does not decode, so one is included here to
	# prove the reader does not depend on the section ending at the records.
	if motion:
		var link_off := buf.size()
		_put_u32(buf, BmsReader.HEADER_PTRS_BASE + 3 * 4, link_off)
		# Shaped like a real section: a count, the 12-byte records, one
		# index word per link, then 36 bytes this reader does not decode.
		var links := PackedByteArray()
		links.resize(4 + 2 * BmsReader.VERTEX_LINK_REC_SIZE + 2 * 4 + 36)
		_put_u32(links, 0, 2)
		_put_u32(links, 4, 0)
		_put_u32(links, 8, 1)
		_put_f32(links, 12, 1.5)
		_put_u32(links, 16, 1)
		_put_u32(links, 20, 2)
		_put_f32(links, 24, 0.75)
		_put_u32(links, 28, 1) # order: link 1 first
		_put_u32(links, 32, 0) # then link 0
		# Round 794: the parameter block (flag, wind, gravity, its gain, the
		# gust's gain, retention, divisor).
		_put_u32(links, 36, 1)
		_put_f32(links, 40, 0.0)
		_put_f32(links, 44, 0.0)
		_put_f32(links, 48, 1.0)
		_put_f32(links, 52, 9.8)
		_put_f32(links, 56, 1.0)
		_put_f32(links, 60, 0.0)
		_put_f32(links, 64, 0.95)
		_put_u32(links, 68, 2)
		buf.append_array(links)

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

## Round 774: a light-mapped mesh (flag 0x400 at 0x40, READ CPrimMesh::
## FUN_00c1bb20): 52-byte records whose bytes 0x20..0x27 are the light map's
## coordinates, and the light map's file right after the vertex array.
func _test_lightmap() -> void:
	var buf := PackedByteArray()
	buf.resize(BmsReader.PREAMBLE_END)
	var magic := BmsReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	_put_u32(buf, BmsReader.FLAG_OFFSET, BmsReader.FLAG_LIGHTMAP)
	buf = _append_len_prefixed(buf, "Deck01")
	buf = _append_len_prefixed(buf, "Mat01")
	var head := PackedByteArray()
	head.resize(8)
	_put_u32(head, 0, 1)
	_put_u32(head, 4, 2)
	buf.append_array(head)
	var verts: Array[BmsReader.Vertex] = []
	for i in 2:
		var rec := PackedByteArray()
		rec.resize(BmsReader.LIGHTMAP_REC_SIZE)
		_put_f32(rec, 0x20, 0.25 + i * 0.5)
		_put_f32(rec, 0x24, 0.75)
		_put_u32(rec, 0x2c, 0xFFFFFFFF)
		buf.append_array(rec)
		var v := BmsReader.Vertex.new()
		v.extra = rec.slice(0x20)
		verts.append(v)
	buf = _append_len_prefixed(buf, "prim\\lightmap\\dun\\deck01lightingmap.ddj")
	_check(BmsReader.lightmap_path(buf) == "prim\\lightmap\\dun\\deck01lightingmap.ddj",
		"r774: the light map's file follows the vertex array (got '%s')" % BmsReader.lightmap_path(buf))
	var plain := buf.duplicate()
	_put_u32(plain, BmsReader.FLAG_OFFSET, 0)
	_check(BmsReader.lightmap_path(plain) == "", "r774: no 0x400, no light map")
	var mesh := BmsReader.ParsedMesh.new()
	mesh.vertices = verts
	var uvs := BmsReader.lightmap_uvs(mesh)
	_check(uvs.size() == 2 and uvs[0] == Vector2(0.25, 0.75) and uvs[1] == Vector2(0.75, 0.75),
		"r774: the record's bytes 0x20..0x27 are the light map coordinates (got %s)" % str(uvs))

## Round 838: the client reads the mesh body in sequence (CPrimMesh::
## FUN_00c1bb20, READ); a file whose hdr[1] points short of where the skin
## section ends (the archive's 3-bone cape, 16 bytes short) is read where the
## sequence puts the triangle count.
func _test_header_index_off() -> void:
	var data := _build_synthetic_mesh(44, true)
	var good := _read_u32(data, BmsReader.HEADER_PTRS_BASE + 4)
	var bad := data.duplicate()
	# hdr[1] pointing where no triangle count fits (the cape's points into
	# its weights, where the "count" reads 0xFFFF).
	_put_u32(bad, BmsReader.HEADER_PTRS_BASE + 4, bad.size() - 2)
	var mesh := BmsReader.parse(bad)
	_check(mesh != null and mesh.indices.size() == 3 and mesh.bone_names.size() == 2,
		"r838: a wrong hdr[1] is read at the skin section's end (%s)" % ("null" if mesh == null else "%d indices, %d bones" % [mesh.indices.size(), mesh.bone_names.size()]))
	_check(BmsReader._skin_section_end(data, _read_u32(data, BmsReader.HEADER_PTRS_BASE), 3) == good,
		"r838: _skin_section_end lands on the index section")
	var whole := BmsReader.parse(data)
	_check(mesh != null and whole != null and mesh.bounds_min == whole.bounds_min and mesh.bounds_max == whole.bounds_max,
		"r838: a header short at hdr[1] alone keeps hdr[4]'s box (the cape)")

## Round 838: a header whose index pointer (and the sections after it) sits
## 9 bytes short of the stream, as the archive's "_parz" meshes write it; the
## client reads the stream (CPrimMesh::FUN_00c1bb20), so the reader takes the
## stream's place. A header that fits is left as it is.
func _test_stream_order() -> void:
	var good := _build_synthetic_mesh(44, true)
	var bad := good.duplicate()
	for k in [1, 4]:
		var at: int = BmsReader.HEADER_PTRS_BASE + k * 4
		_put_u32(bad, at, _read_u32(bad, at) - 9)
	var m := BmsReader.parse(bad)
	_check(m != null, "stream order: a short index pointer still parses")
	if m != null:
		_check(m.indices.size() == 3, "stream order: 3 indices (got %d)" % m.indices.size())
		_check(m.bounds_max == Vector3(1, 0, 1), "stream order: the bounds shift with it (got %s)" % m.bounds_max)
		_check(m.bone_names.size() == 2, "stream order: the skin's palette is read (got %d)" % m.bone_names.size())
	var ok := BmsReader.parse(good)
	_check(ok != null and ok.indices.size() == 3, "stream order: a fitting header is untouched")

## Round 838's merge: of the two box candidates, an inverted one (min above
## max, a shifted read landing in other data) is rejected without building
## an AABB of negative size, and the other is taken.
func _test_bbox_inverted_candidate() -> void:
	var data := PackedByteArray()
	data.resize(64)
	for i in 3:
		_put_f32(data, 8 + i * 4, 5.0)
		_put_f32(data, 8 + 12 + i * 4, -5.0)
		_put_f32(data, 40 + i * 4, -1.0)
		_put_f32(data, 40 + 12 + i * 4, 2.0)
	var mesh := BmsReader.ParsedMesh.new()
	var v := BmsReader.Vertex.new()
	v.position = Vector3(0.5, 0.5, 0.5)
	mesh.vertices.append(v)
	_check(BmsReader._bbox_offset(data, 40, -32, mesh) == 40,
		"r838 merge: an inverted shifted box is passed over for hdr[4]'s")

func _init() -> void:
	_test_header_index_off()
	_test_bbox_inverted_candidate()
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

	# Round 626: 0xFF in the FIRST slot is "no bone here", not a misread
	# palette -- the client's skinned vertex-buffer builders skip a 0xFF slot
	# and read the next (ResObject::FUN_00be28d0). Refusing it threw away the
	# whole skin of heavy_11_la/ba.bms, and an unweighted armour piece is not
	# drawn: the missing chest and legs of a Degree-11 set.
	var empty_first := BmsReader.parse(_build_synthetic_mesh(44, true, false, true))
	_check(empty_first != null and empty_first.is_skinned(),
		"a skin record with an empty (0xFF) first slot keeps the mesh skinned")
	if empty_first != null and empty_first.is_skinned():
		var ve: BmsReader.Vertex = empty_first.vertices[2]
		_check(ve.bone0 == 1 and ve.bone1 == -1,
			"an empty first slot leaves the second slot's bone as the one influence (got %d/%d)" % [ve.bone0, ve.bone1])
		_check(is_equal_approx(ve.weight0, 1.0),
			"...at full weight (got %f)" % ve.weight0)
		var ea := BmsReader.to_array_mesh(empty_first).surface_get_arrays(0)
		var eb: PackedInt32Array = ea[Mesh.ARRAY_BONES]
		var ew: PackedFloat32Array = ea[Mesh.ARRAY_WEIGHTS]
		_check(eb[8] == 1 and is_equal_approx(ew[8], 1.0) and is_equal_approx(ew[9], 0.0),
			"the ArrayMesh binds that vertex to bone 1 alone (got bone %d weights %f/%f)" % [eb[8], ew[8], ew[9]])

	# Round 626 follow-up: both slots empty is palette entry 0 in the
	# client's builder (ResObject::FUN_00be2f80) -- no bone -- drawn here in
	# the model's own space: to_arrays binds it one past the palette, where
	# Skeleton3DBuilder.build_skin puts a bone that never moves.
	var both := BmsReader.parse(_build_synthetic_mesh(44, true, false, false, true))
	_check(both != null and both.is_skinned(), "a vertex with both slots empty keeps the mesh skinned")
	if both != null and both.is_skinned():
		var vb: BmsReader.Vertex = both.vertices[2]
		_check(vb.bone0 == BmsReader.OBJECT_SPACE and is_equal_approx(vb.weight0, 1.0) and vb.bone1 == -1,
			"both slots empty is the object-space entry at full weight (got %d/%f/%d)" % [vb.bone0, vb.weight0, vb.bone1])
		_check(both.object_space_vertices == 1, "the mesh counts one object-space vertex (got %d)" % both.object_space_vertices)
		var ba := BmsReader.to_array_mesh(both).surface_get_arrays(0)
		var bb: PackedInt32Array = ba[Mesh.ARRAY_BONES]
		_check(bb[8] == both.bone_names.size(), "to_arrays puts it one past the palette (got %d)" % bb[8])
		var sk := Skeleton3D.new()
		sk.add_bone("Bip01 Spine")
		sk.add_bone("Bip01 L Hand")
		var skin := Skeleton3DBuilder.build_skin(sk, both.bone_names, true)
		_check(skin != null and skin.get_bind_count() == 3
				and sk.get_bone_name(skin.get_bind_bone(2)) == Skeleton3DBuilder.OBJECT_SPACE_BONE
				and skin.get_bind_pose(2) == Transform3D.IDENTITY,
			"build_skin binds that index to a still bone with an identity bind")
		sk.free()

	# And a mesh with no skin section stays unskinned rather than inventing
	# one -- scenery is the common case.
	var plain := BmsReader.parse(_build_synthetic_mesh(44, false))
	_check(plain != null and not plain.is_skinned(), "a mesh with no skin section is not skinned")
	if plain != null:
		var plain_arrays := BmsReader.to_array_mesh(plain).surface_get_arrays(0)
		_check(plain_arrays[Mesh.ARRAY_BONES] == null,
			"an unskinned mesh gets no bone array")

	# The hdr[2] per-vertex section. Absent from most meshes, so a reader
	# that carries it must also cope with it not being there.
	var motionless := BmsReader.parse(_build_synthetic_mesh())
	_check(motionless != null and motionless.vertex_motion.is_empty(),
		"a mesh with no hdr[2] section carries no motion data")

	var with_motion := BmsReader.parse(_build_synthetic_mesh(44, false, true))
	_check(with_motion != null, "a mesh with an hdr[2] section still parses")
	if with_motion != null:
		_check(with_motion.vertex_motion.size() == with_motion.vertices.size(),
			"one motion record per vertex (got %d for %d vertices)"
				% [with_motion.vertex_motion.size(), with_motion.vertices.size()])
		_check(is_equal_approx(with_motion.vertex_motion[1], 0.15),
			"the amount decodes as a float (got %f)" % with_motion.vertex_motion[1])
		_check(with_motion.vertex_pinned[0] == 1 and with_motion.vertex_pinned[2] == 1
			and with_motion.vertex_pinned[1] == 0,
			"the flag marks exactly the vertices whose amount is zero")
		# The geometry must be unaffected: the section sits between the
		# indices and the bounding box, and reading it must not disturb
		# either.
		_check(with_motion.indices.size() == 3 and with_motion.bounds_max.x == 1.0,
			"the rest of the mesh reads the same with the section present")

	# The hdr[3] link section.
	_check(motionless != null and motionless.vertex_links.is_empty(),
		"a mesh with no hdr[3] section carries no links")
	if with_motion != null:
		_check(with_motion.vertex_links.size() == 4,
			"two links, flattened into four indices (got %d)" % with_motion.vertex_links.size())
		_check(with_motion.vertex_links[0] == 0 and with_motion.vertex_links[1] == 1
			and with_motion.vertex_links[2] == 1 and with_motion.vertex_links[3] == 2,
			"the pairs decode in order")
		# The trailer after the records must not be read as another link.
		_check(with_motion.vertex_link_lengths.size() == 2,
			"the trailer after the records is not mistaken for a link (got %d)"
				% with_motion.vertex_link_lengths.size())
		_check(is_equal_approx(with_motion.vertex_link_lengths[0], 1.5)
			and is_equal_approx(with_motion.vertex_link_lengths[1], 0.75),
			"each link carries its own distance")
		_check(with_motion.vertex_link_order.size() == 2
			and with_motion.vertex_link_order[0] == 1
			and with_motion.vertex_link_order[1] == 0,
			"the index word after each record decodes as an order over the links")
		var cp := with_motion.cloth_params
		_check(cp.size() == 9 and cp[0] == 1.0 and cp[3] == 1.0 and is_equal_approx(cp[4], 9.8)
			and is_equal_approx(cp[7], 0.95) and cp[8] == 2.0,
			"the 36 bytes after the order are the cloth's parameters (got %s)" % cp)
		_check(with_motion.is_cloth(), "a mesh with both sections whole is cloth")

	# An index outside the mesh means the 12-byte split is wrong, and a
	# half-read link list is worse than none: the reader must leave it empty
	# rather than carry indices that point at nothing.
	var bad := _build_synthetic_mesh(44, false, true)
	var bad_link_off := _read_u32(bad, BmsReader.HEADER_PTRS_BASE + 3 * 4)
	_put_u32(bad, bad_link_off + 4, 99) # a vertex index the mesh does not have
	var bad_mesh := BmsReader.parse(bad)
	_check(bad_mesh != null and bad_mesh.vertex_links.is_empty(),
		"a link pointing outside the mesh leaves the whole list unread")

	_test_lightmap()
	_test_stream_order()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
