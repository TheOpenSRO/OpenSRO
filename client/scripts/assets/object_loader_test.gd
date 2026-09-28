extends SceneTree

## Exercises ObjectLoader against a synthetic pk2 archive containing a
## synthetic .bsr + .bms (never real game data), run headless:
## `godot4 --headless --path client --script res://scripts/assets/object_loader_test.gd`

var _failures := 0

## A constant of ObjectLoader looked up at run time, so this suite still
## compiles against a loader that lacks it -- which is how round 625's
## negative runs it against BASE and gets FAIL lines, not a parse error.
func _ol_const(name: String) -> Variant:
	return (load("res://scripts/assets/object_loader.gd") as GDScript).get_script_constant_map().get(name)

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

func _build_bms(mesh_name: String, material_name: String) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(BmsReader.PREAMBLE_END)
	var magic := BmsReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	buf = _append_len_prefixed(buf, mesh_name)
	buf = _append_len_prefixed(buf, material_name)

	var counts := PackedByteArray()
	counts.resize(8)
	_put_u32(counts, 0, 1)
	_put_u32(counts, 4, 3)
	buf.append_array(counts)

	var positions := [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)]
	for i in range(3):
		var rec := PackedByteArray()
		rec.resize(44)
		_put_f32(rec, 0x00, positions[i].x)
		_put_f32(rec, 0x04, positions[i].y)
		_put_f32(rec, 0x08, positions[i].z)
		_put_f32(rec, 0x10, 1.0) # normal.y
		buf.append_array(rec)

	var index_off := buf.size()
	_put_u32(buf, BmsReader.HEADER_PTRS_BASE + 1 * 4, index_off)
	var idx := PackedByteArray()
	idx.resize(4 + 6)
	_put_u32(idx, 0, 1)
	idx[4] = 0
	idx[6] = 1
	idx[8] = 2
	buf.append_array(idx)

	return buf

func _build_bsr(obj_name: String, mesh_path: String, material_path: String, sub_paths: Array) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(BsrReader.PREAMBLE_END)
	var magic := BsrReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	buf = _append_len_prefixed(buf, obj_name)

	var pad := PackedByteArray()
	pad.resize(48)
	buf.append_array(pad)

	buf = _append_len_prefixed(buf, mesh_path)
	buf.append_array(_zeros(60))
	buf = _append_len_prefixed(buf, material_path)

	var count_bytes := PackedByteArray()
	count_bytes.resize(4)
	_put_u32(count_bytes, 0, sub_paths.size())
	buf.append_array(count_bytes)
	for p in sub_paths:
		buf = _append_len_prefixed(buf, p)

	return buf

func _zeros(n: int) -> PackedByteArray:
	var z := PackedByteArray()
	z.resize(n)
	return z

## A single-layer .bmt ("layer0", diffuse white, texture "walltex.ddj"),
## zlib-compressed with Python's zlib -- see bmt/bmt_reader_test.gd for why
## an independent encoder is used rather than Godot's own.
const TEST_BMT_HEX := "71000000789cf3f28d0873f20d5130303430626460606003e29cc4cad42203ed76317b18666068c0c0696969700c11430610be2333030337902e4fccc92949add04b49c90200325616b1"

## Builds a synthetic uncompressed .bmt (the real live-client layout, no
## zlib wrapper -- see bmt/bmt_reader_test.gd) with one layer per entry in
## layer_names, each with a distinct texture path "<name>.ddj". Used to
## exercise ObjectLoader's real name-based layer matching (see this file's
## top comment) with layers in a deliberately shuffled order relative to
## how the meshes referencing them are built, the same real
## don't-assume-positional-order shape confirmed against a real 27-piece/
## 28-layer building (bagh_city_palace.bsr/.bmt).
func _build_uncompressed_bmt(layer_names: Array, flags: Dictionary = {}) -> PackedByteArray:
	var dec := PackedByteArray()
	dec.append_array("JMXVBMT 0102".to_ascii_buffer())
	var count := PackedByteArray()
	count.resize(4)
	_put_u32(count, 0, layer_names.size())
	dec.append_array(count)
	for name in layer_names:
		dec = _append_len_prefixed(dec, name)
		for i in range(4): dec = _append_f32_arr(dec, 1.0) # ambient
		for i in range(4): dec = _append_f32_arr(dec, 1.0) # diffuse
		for i in range(4): dec = _append_f32_arr(dec, 1.0) # specular
		for i in range(4): dec = _append_f32_arr(dec, 0.0) # emissive
		dec = _append_f32_arr(dec, 0.0) # power
		var unk := PackedByteArray()
		unk.resize(4)
		_put_u32(unk, 0, int(flags.get(name, 0)))
		dec.append_array(unk)
		dec = _append_len_prefixed(dec, "%s.ddj" % name)
		# The seven trailer bytes every real layer carries (round 625, READ
		# from CPrimMtrl FUN_00bf91b0): a uint32 and three bytes.
		dec.append_array(_zeros(7)) # BmtReader.LAYER_TRAILER_BYTES
	return dec

func _append_f32_arr(buf: PackedByteArray, v: float) -> PackedByteArray:
	var enc := PackedByteArray()
	enc.resize(4)
	enc.encode_float(0, v)
	var out := buf.duplicate()
	out.append_array(enc)
	return out

func _build_ddj(width: int, height: int) -> PackedByteArray:
	var dds_size := 4 + DdjReader.DDS_HEADER_SIZE + width * height * 4
	var dds := PackedByteArray()
	dds.resize(dds_size)
	var magic_bytes := "DDS ".to_ascii_buffer()
	for i in range(4):
		dds[i] = magic_bytes[i]
	_put_u32(dds, 4, DdjReader.DDS_HEADER_SIZE)
	_put_u32(dds, 4 + 8, height)
	_put_u32(dds, 4 + 12, width)
	_put_u32(dds, 4 + 24, 1)
	var pf_off := 4 + 72
	_put_u32(dds, pf_off, 32)
	_put_u32(dds, pf_off + 4, DdjReader.DDPF_RGB | DdjReader.DDPF_ALPHAPIXELS)
	_put_u32(dds, pf_off + 12, 32)

	var buf := PackedByteArray()
	buf.resize(DdjReader.WRAPPER_SIZE + dds.size())
	var magic := DdjReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	_put_u32(buf, 0x0c, buf.size() - DdjReader.MAGIC_LEN)
	_put_u32(buf, 0x10, 3)
	for i in range(dds.size()):
		buf[DdjReader.WRAPPER_SIZE + i] = dds[i]
	return buf

## Builds a synthetic pk2 archive (unencrypted) on disk containing:
## /prim/mesh/bldg/wall01.bms
## /prim/mesh/bldg/wall02.bms
## /prim/bsr/testobj.bsr  (references the two .bms above)
## /prim/mtrl/testobj.bmt (references walltex.ddj)
## /prim/mtrl/walltex.ddj
func _build_archive(path: String) -> void:
	var header := PackedByteArray()
	header.resize(Pk2Reader.HEADER_SIZE)
	var magic := "JoyMax File Manager!".to_ascii_buffer()
	for i in range(magic.size()):
		header[i] = magic[i]

	var write_entry := func(block: PackedByteArray, i: int, entry_type: int, name: String, offset: int, size: int) -> void:
		var base := i * Pk2Reader.ENTRY_SIZE
		block[base] = entry_type
		var nb := name.to_ascii_buffer()
		for j in range(nb.size()):
			block[base + 0x01 + j] = nb[j]
		var pos_base := base + Pk2Reader.ENTRY_OFF_POSITION
		block[pos_base] = offset & 0xFF
		block[pos_base + 1] = (offset >> 8) & 0xFF
		block[pos_base + 2] = (offset >> 16) & 0xFF
		block[pos_base + 3] = (offset >> 24) & 0xFF
		var size_base := base + Pk2Reader.ENTRY_OFF_SIZE
		size_base = base + Pk2Reader.ENTRY_OFF_SIZE
		block[size_base] = size & 0xFF
		block[size_base + 1] = (size >> 8) & 0xFF
		block[size_base + 2] = (size >> 16) & 0xFF
		block[size_base + 3] = (size >> 24) & 0xFF

	# Layout: root block, prim/ block, prim/mesh/ block, prim/mesh/bldg/
	# block (2 .bms files), prim/mtrl/ block (.bmt + .ddj), file data.
	var block_size := Pk2Reader.BLOCK_SIZE
	var root_off := Pk2Reader.HEADER_SIZE
	var prim_off := root_off + block_size
	var mesh_off := prim_off + block_size
	var bldg_off := mesh_off + block_size
	var mtrl_off := bldg_off + block_size
	var files_off := mtrl_off + block_size

	var wall01 := _build_bms("wall01", "mat01")
	var wall02 := _build_bms("wall02", "mat01")
	var bmt_data := TEST_BMT_HEX.hex_decode()
	var ddj_data := _build_ddj(4, 4)
	var wall01_off := files_off
	var wall02_off := wall01_off + wall01.size()
	var bmt_off := wall02_off + wall02.size()
	var ddj_off := bmt_off + bmt_data.size()
	var bsr_data := _build_bsr("TestObj", "prim\\mesh\\bldg\\wall01.bms", "prim\\mtrl\\testobj.bmt", ["prim\\mesh\\bldg\\wall02.bms"])
	var bsr_off := ddj_off + ddj_data.size()

	var root_block := PackedByteArray()
	root_block.resize(block_size)
	write_entry.call(root_block, 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", root_off, 0)
	write_entry.call(root_block, 1, Pk2Reader.ENTRY_TYPE_FOLDER, "prim", prim_off, 0)

	var prim_block := PackedByteArray()
	prim_block.resize(block_size)
	write_entry.call(prim_block, 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", prim_off, 0)
	write_entry.call(prim_block, 1, Pk2Reader.ENTRY_TYPE_FOLDER, "..", root_off, 0)
	write_entry.call(prim_block, 2, Pk2Reader.ENTRY_TYPE_FOLDER, "mesh", mesh_off, 0)
	write_entry.call(prim_block, 3, Pk2Reader.ENTRY_TYPE_FOLDER, "mtrl", mtrl_off, 0)
	write_entry.call(prim_block, 4, Pk2Reader.ENTRY_TYPE_FILE, "testobj.bsr", bsr_off, bsr_data.size())

	var mesh_block := PackedByteArray()
	mesh_block.resize(block_size)
	write_entry.call(mesh_block, 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", mesh_off, 0)
	write_entry.call(mesh_block, 1, Pk2Reader.ENTRY_TYPE_FOLDER, "..", prim_off, 0)
	write_entry.call(mesh_block, 2, Pk2Reader.ENTRY_TYPE_FOLDER, "bldg", bldg_off, 0)

	var bldg_block := PackedByteArray()
	bldg_block.resize(block_size)
	write_entry.call(bldg_block, 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", bldg_off, 0)
	write_entry.call(bldg_block, 1, Pk2Reader.ENTRY_TYPE_FOLDER, "..", mesh_off, 0)
	write_entry.call(bldg_block, 2, Pk2Reader.ENTRY_TYPE_FILE, "wall01.bms", wall01_off, wall01.size())
	write_entry.call(bldg_block, 3, Pk2Reader.ENTRY_TYPE_FILE, "wall02.bms", wall02_off, wall02.size())

	var mtrl_block := PackedByteArray()
	mtrl_block.resize(block_size)
	write_entry.call(mtrl_block, 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", mtrl_off, 0)
	write_entry.call(mtrl_block, 1, Pk2Reader.ENTRY_TYPE_FOLDER, "..", prim_off, 0)
	write_entry.call(mtrl_block, 2, Pk2Reader.ENTRY_TYPE_FILE, "testobj.bmt", bmt_off, bmt_data.size())
	write_entry.call(mtrl_block, 3, Pk2Reader.ENTRY_TYPE_FILE, "walltex.ddj", ddj_off, ddj_data.size())

	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(header)
	f.store_buffer(root_block)
	f.store_buffer(prim_block)
	f.store_buffer(mesh_block)
	f.store_buffer(bldg_block)
	f.store_buffer(mtrl_block)
	f.store_buffer(wall01)
	f.store_buffer(wall02)
	f.store_buffer(bmt_data)
	f.store_buffer(ddj_data)
	f.store_buffer(bsr_data)
	f.close()

## A flat single-directory archive (root-level files only, no nested
## folders needed) exercising ObjectLoader's real name-based layer
## matching: two mesh pieces with distinct material_names, referenced by
## the .bsr in one order, but with the .bmt listing their matching layers
## in the *opposite* order -- the same real shuffled-order shape confirmed
## against bagh_city_palace.bsr/.bmt. Index-based pairing would assign
## each piece the wrong layer; name-based matching gets both right.
func _build_name_match_archive(path: String) -> void:
	var header := PackedByteArray()
	header.resize(Pk2Reader.HEADER_SIZE)
	var magic := "JoyMax File Manager!".to_ascii_buffer()
	for i in range(magic.size()):
		header[i] = magic[i]

	var write_entry := func(block: PackedByteArray, i: int, entry_type: int, name: String, offset: int, size: int) -> void:
		var base := i * Pk2Reader.ENTRY_SIZE
		block[base] = entry_type
		var nb := name.to_ascii_buffer()
		for j in range(nb.size()):
			block[base + 0x01 + j] = nb[j]
		var pos_base := base + Pk2Reader.ENTRY_OFF_POSITION
		block[pos_base] = offset & 0xFF
		block[pos_base + 1] = (offset >> 8) & 0xFF
		block[pos_base + 2] = (offset >> 16) & 0xFF
		block[pos_base + 3] = (offset >> 24) & 0xFF
		var size_base := base + Pk2Reader.ENTRY_OFF_SIZE
		block[size_base] = size & 0xFF
		block[size_base + 1] = (size >> 8) & 0xFF
		block[size_base + 2] = (size >> 16) & 0xFF
		block[size_base + 3] = (size >> 24) & 0xFF

	var block_size := Pk2Reader.BLOCK_SIZE
	var root_off := Pk2Reader.HEADER_SIZE
	var files_off := root_off + block_size

	var piece_a := _build_bms("pieceA", "piece_a")
	var piece_b := _build_bms("pieceB", "piece_b")
	# Layers in the opposite order from how the pieces are referenced below
	# (piece_a is the primary mesh, piece_b the sub-mesh) -- deliberately
	# shuffled, same real convention confirmed against bagh_city_palace.
	var bmt_data := _build_uncompressed_bmt(["piece_b", "piece_a"])
	var piece_a_off := files_off
	var piece_b_off := piece_a_off + piece_a.size()
	var bmt_off := piece_b_off + piece_b.size()
	var bsr_data := _build_bsr("NameMatchObj", "pieceA.bms", "test.bmt", ["pieceB.bms"])
	var bsr_off := bmt_off + bmt_data.size()

	var root_block := PackedByteArray()
	root_block.resize(block_size)
	write_entry.call(root_block, 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", root_off, 0)
	write_entry.call(root_block, 1, Pk2Reader.ENTRY_TYPE_FILE, "pieceA.bms", piece_a_off, piece_a.size())
	write_entry.call(root_block, 2, Pk2Reader.ENTRY_TYPE_FILE, "pieceB.bms", piece_b_off, piece_b.size())
	write_entry.call(root_block, 3, Pk2Reader.ENTRY_TYPE_FILE, "test.bmt", bmt_off, bmt_data.size())
	write_entry.call(root_block, 4, Pk2Reader.ENTRY_TYPE_FILE, "nameMatchObj.bsr", bsr_off, bsr_data.size())

	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(header)
	f.store_buffer(root_block)
	f.store_buffer(piece_a)
	f.store_buffer(piece_b)
	f.store_buffer(bmt_data)
	f.store_buffer(bsr_data)
	f.close()

## Builds a real-shaped DXT3-compressed .ddj (4x4, 1 real 16-byte DXT3
## block) -- see build_godot_material's own doc comment for why DXT3
## specifically matters (a real per-pixel alpha channel Godot's decoder
## actually preserves, unlike DXT1).
func _build_dxt3_ddj() -> PackedByteArray:
	var payload_len := 16 # one 4x4 DXT3 block
	var dds := PackedByteArray()
	dds.resize(4 + DdjReader.DDS_HEADER_SIZE + payload_len)
	var magic_bytes := "DDS ".to_ascii_buffer()
	for i in range(4):
		dds[i] = magic_bytes[i]
	_put_u32(dds, 4, DdjReader.DDS_HEADER_SIZE)
	_put_u32(dds, 4 + 8, 4) # height
	_put_u32(dds, 4 + 12, 4) # width
	_put_u32(dds, 4 + 24, 1) # mip map count
	var pf_off := 4 + 72
	_put_u32(dds, pf_off, 32)
	_put_u32(dds, pf_off + 4, DdjReader.DDPF_FOURCC)
	var cc_bytes := "DXT3".to_ascii_buffer()
	for i in range(4):
		dds[pf_off + 8 + i] = cc_bytes[i]

	var buf := PackedByteArray()
	buf.resize(DdjReader.WRAPPER_SIZE + dds.size())
	var magic := DdjReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	_put_u32(buf, 0x0c, buf.size() - DdjReader.MAGIC_LEN)
	_put_u32(buf, 0x10, 1)
	for i in range(dds.size()):
		buf[DdjReader.WRAPPER_SIZE + i] = dds[i]
	return buf

## A minimal, flat, root-level-only archive with a single real
## DXT3-compressed texture -- just enough to exercise
## ObjectLoader.build_godot_material's real alpha-cutout detection without
## needing a full .bsr/.bms object around it.
func _build_alpha_archive(path: String) -> void:
	var header := PackedByteArray()
	header.resize(Pk2Reader.HEADER_SIZE)
	var magic := "JoyMax File Manager!".to_ascii_buffer()
	for i in range(magic.size()):
		header[i] = magic[i]

	var write_entry := func(block: PackedByteArray, i: int, entry_type: int, name: String, offset: int, size: int) -> void:
		var base := i * Pk2Reader.ENTRY_SIZE
		block[base] = entry_type
		var nb := name.to_ascii_buffer()
		for j in range(nb.size()):
			block[base + 0x01 + j] = nb[j]
		var pos_base := base + Pk2Reader.ENTRY_OFF_POSITION
		block[pos_base] = offset & 0xFF
		block[pos_base + 1] = (offset >> 8) & 0xFF
		block[pos_base + 2] = (offset >> 16) & 0xFF
		block[pos_base + 3] = (offset >> 24) & 0xFF
		var size_base := base + Pk2Reader.ENTRY_OFF_SIZE
		block[size_base] = size & 0xFF
		block[size_base + 1] = (size >> 8) & 0xFF
		block[size_base + 2] = (size >> 16) & 0xFF
		block[size_base + 3] = (size >> 24) & 0xFF

	var block_size := Pk2Reader.BLOCK_SIZE
	var root_off := Pk2Reader.HEADER_SIZE
	var sub_off := root_off + block_size
	var files_off := sub_off + block_size
	var ddj_data := _build_dxt3_ddj()
	var ddj_off := files_off
	var ddj2_data := _build_dxt3_ddj()
	var ddj2_off := ddj_off + ddj_data.size()

	var root_block := PackedByteArray()
	root_block.resize(block_size)
	write_entry.call(root_block, 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", root_off, 0)
	write_entry.call(root_block, 1, Pk2Reader.ENTRY_TYPE_FILE, "leaf.ddj", ddj_off, ddj_data.size())
	write_entry.call(root_block, 2, Pk2Reader.ENTRY_TYPE_FOLDER, "sub", sub_off, 0)

	var sub_block := PackedByteArray()
	sub_block.resize(block_size)
	write_entry.call(sub_block, 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", sub_off, 0)
	write_entry.call(sub_block, 1, Pk2Reader.ENTRY_TYPE_FOLDER, "..", root_off, 0)
	write_entry.call(sub_block, 2, Pk2Reader.ENTRY_TYPE_FILE, "leaf2.ddj", ddj2_off, ddj2_data.size())

	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(header)
	f.store_buffer(root_block)
	f.store_buffer(sub_block)
	f.store_buffer(ddj_data)
	f.store_buffer(ddj2_data)
	f.close()

## Builds a minimal real-shaped .cpd (magic + name, no trailing real
## sub-count field this reader doesn't rely on -- see CpdReader's own doc
## comment) referencing one real .bsr sub-object by a bare root-relative
## path.
func _build_cpd(name: String, bsr_path: String) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(CpdReader.HEADER_LEN)
	var magic := CpdReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	buf = _append_len_prefixed(buf, name)
	buf = _append_len_prefixed(buf, bsr_path)
	return buf

## A minimal, flat, root-level-only archive with a real synthetic
## .bms/.bsr pair plus a real .cpd referencing that .bsr -- exercises
## ObjectLoader's real .cpd dispatch (load_object -> _load_compound_object
## -> load_object again for the real sub-.bsr).
func _build_cpd_archive(path: String) -> void:
	var header := PackedByteArray()
	header.resize(Pk2Reader.HEADER_SIZE)
	var magic := "JoyMax File Manager!".to_ascii_buffer()
	for i in range(magic.size()):
		header[i] = magic[i]

	var write_entry := func(block: PackedByteArray, i: int, entry_type: int, name: String, offset: int, size: int) -> void:
		var base := i * Pk2Reader.ENTRY_SIZE
		block[base] = entry_type
		var nb := name.to_ascii_buffer()
		for j in range(nb.size()):
			block[base + 0x01 + j] = nb[j]
		var pos_base := base + Pk2Reader.ENTRY_OFF_POSITION
		block[pos_base] = offset & 0xFF
		block[pos_base + 1] = (offset >> 8) & 0xFF
		block[pos_base + 2] = (offset >> 16) & 0xFF
		block[pos_base + 3] = (offset >> 24) & 0xFF
		var size_base := base + Pk2Reader.ENTRY_OFF_SIZE
		block[size_base] = size & 0xFF
		block[size_base + 1] = (size >> 8) & 0xFF
		block[size_base + 2] = (size >> 16) & 0xFF
		block[size_base + 3] = (size >> 24) & 0xFF

	var block_size := Pk2Reader.BLOCK_SIZE
	var root_off := Pk2Reader.HEADER_SIZE
	var files_off := root_off + block_size

	var bms_data := _build_bms("simple", "")
	var bsr_data := _build_bsr("TestCompoundPiece", "simple.bms", "testpiece.bmt", [])
	var cpd_data := _build_cpd("TestCompound", "testpiece.bsr")

	var bms_off := files_off
	var bsr_off := bms_off + bms_data.size()
	var cpd_off := bsr_off + bsr_data.size()

	var root_block := PackedByteArray()
	root_block.resize(block_size)
	write_entry.call(root_block, 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", root_off, 0)
	write_entry.call(root_block, 1, Pk2Reader.ENTRY_TYPE_FILE, "simple.bms", bms_off, bms_data.size())
	write_entry.call(root_block, 2, Pk2Reader.ENTRY_TYPE_FILE, "testpiece.bsr", bsr_off, bsr_data.size())
	write_entry.call(root_block, 3, Pk2Reader.ENTRY_TYPE_FILE, "testcompound.cpd", cpd_off, cpd_data.size())

	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(header)
	f.store_buffer(root_block)
	f.store_buffer(bms_data)
	f.store_buffer(bsr_data)
	f.store_buffer(cpd_data)
	f.close()

## How many distinct Texture2D objects the mesh pieces of these objects draw
## with, through either material kind ObjectLoader builds.
func _distinct_albedo_textures(objects: Array) -> int:
	var seen := {}
	for obj in objects:
		for child in obj.get_children():
			var mat: Material = (child as MeshInstance3D).material_override
			var tex: Texture2D = null
			if mat is ShaderMaterial:
				tex = (mat as ShaderMaterial).get_shader_parameter("albedo_texture")
			elif mat is StandardMaterial3D:
				tex = (mat as StandardMaterial3D).albedo_texture
			if tex != null:
				seen[tex.get_instance_id()] = true
	return seen.size()

## --- Round 566: the prepare/commit split and the alpha probes on the Image --
##
## ObjectLoader.load_object is `commit_object(prepare_object(...))` since
## round 566: the prepare (plain data, safe on a WorkerThreadPool task) and
## the commit (the ArrayMesh, textures, materials, shape and nodes, main
## thread). The new API is reached through load() and call(), so on a tree
## without the split this suite FAILS rather than failing to parse, and its
## load_object checks still run: they are what the old one-piece loader --
## whose alpha probes read the uploaded texture back -- was measured
## against. Held to account:
## - the node tree, surface counts, collision faces and materials of every
##   synthetic object, through load_object and through commit(prepare) --
##   both against fingerprints MEASURED on the pre-split loader (BASE
##   f8704c4, 2026-09-25, this suite's own `fingerprint` lines);
## - the prepare on a task holds no Node and no Resource but Image;
## - each piece's prepared faces are the uploaded mesh's
##   `create_trimesh_shape().get_faces()`, element for element, with
##   off-grid corners (the 0.0001 snap) and a degenerate triangle (kept);
## - THE ALPHA RULE ON THE IMAGE (the NEGATIVE): layers whose flag word
##   leaves the decision to the pixels (no bit 6, LAYER_FLAG_MASK) -- an
##   uncompressed texture with binary alpha is a cutout and one with graded
##   alpha is not, a DXT1 texture all punched out is a cutout and an opaque
##   one is not. The readback path met these; an implementation that skips
##   the Image fails them;
## - the texture cache carries the measured statistics, so a texture the
##   world holds is neither decoded nor measured again, and one whose
##   statistic is missing is decoded for it; SRREVAMP_QA_ALPHA_LOG says
##   which.

## The pre-split loader's fingerprints (BASE f8704c4's load_object on the
## render box, 2026-09-25), with round 625's material rule applied: the
## scissor is 128/255 (0.5020), the shader says which cull it is (`two` /
## `one`), and dxt1solid's 0x141 layer is the two-sided shader untested.
## Everything else in them is the pre-split loader's, unchanged.
const EXPECTED_FINGERPRINTS := {
	"testobj": "0:Node3D:TestObj | 1:MeshInstance3D:wall01 surfaces=1 [v=3 i=3 isum=3 psum=1.0000,0.0000,1.0000] mat=Shader(layer0,shader=two,tex=4x4,scissor=0.5020,albedo=(0.588, 0.588, 0.588, 1)) | 2:StaticBody3D:@ | 3:CollisionShape3D:@ shape=ConcavePolygonShape3D faces=3 fsum=1.0000,0.0000,1.0000 backface=false | 1:MeshInstance3D:wall02 surfaces=1 [v=3 i=3 isum=3 psum=1.0000,0.0000,1.0000] mat=Shader(layer0,shader=two,tex=4x4,scissor=0.5020,albedo=(0.588, 0.588, 0.588, 1)) | 2:StaticBody3D:@ | 3:CollisionShape3D:@ shape=ConcavePolygonShape3D faces=3 fsum=1.0000,0.0000,1.0000 backface=false",
	"namematch": "0:Node3D:NameMatchObj | 1:MeshInstance3D:pieceA surfaces=1 [v=3 i=3 isum=3 psum=1.0000,0.0000,1.0000] mat=Standard(piece_a,tex=null,albedo=(1, 1, 1, 1),transparency=0,cull=0) | 2:StaticBody3D:@ | 3:CollisionShape3D:@ shape=ConcavePolygonShape3D faces=3 fsum=1.0000,0.0000,1.0000 backface=false | 1:MeshInstance3D:pieceB surfaces=1 [v=3 i=3 isum=3 psum=1.0000,0.0000,1.0000] mat=Standard(piece_b,tex=null,albedo=(1, 1, 1, 1),transparency=0,cull=0) | 2:StaticBody3D:@ | 3:CollisionShape3D:@ shape=ConcavePolygonShape3D faces=3 fsum=1.0000,0.0000,1.0000 backface=false",
	"compound": "0:Node3D:TestCompound | 1:Node3D:TestCompoundPiece | 2:MeshInstance3D:simple surfaces=1 [v=3 i=3 isum=3 psum=1.0000,0.0000,1.0000] mat=null | 3:StaticBody3D:@ | 4:CollisionShape3D:@ shape=ConcavePolygonShape3D faces=3 fsum=1.0000,0.0000,1.0000 backface=false",
	"alphaobj": "0:Node3D:AlphaObj | 1:MeshInstance3D:bin surfaces=1 [v=3 i=6 isum=4 psum=0.5468,5.4445,1.2655] mat=Shader(bin,shader=two,tex=4x4,scissor=0.5020,albedo=(1, 1, 1, 1)) | 2:StaticBody3D:@ | 3:CollisionShape3D:@ shape=ConcavePolygonShape3D faces=6 fsum=3.9354,7.4444,5.0309 backface=false | 1:MeshInstance3D:graded surfaces=1 [v=3 i=3 isum=3 psum=0.5468,5.4445,1.2655] mat=Standard(graded,tex=4x4,albedo=(1, 1, 1, 1),transparency=0,cull=0) | 2:StaticBody3D:@ | 3:CollisionShape3D:@ shape=ConcavePolygonShape3D faces=3 fsum=0.5468,5.4444,1.2655 backface=false | 1:MeshInstance3D:dxt1cut surfaces=1 [v=3 i=3 isum=3 psum=0.5468,5.4445,1.2655] mat=Shader(dxt1cut,shader=one,tex=4x4,scissor=0.5020,albedo=(1, 1, 1, 1)) | 2:StaticBody3D:@ | 3:CollisionShape3D:@ shape=ConcavePolygonShape3D faces=3 fsum=0.5468,5.4444,1.2655 backface=false | 1:MeshInstance3D:dxt1solid surfaces=1 [v=3 i=3 isum=3 psum=0.5468,5.4445,1.2655] mat=Shader(dxt1solid,shader=two,tex=4x4,scissor=0.0000,albedo=(1, 1, 1, 1)) | 2:StaticBody3D:@ | 3:CollisionShape3D:@ shape=ConcavePolygonShape3D faces=3 fsum=0.5468,5.4444,1.2655 backface=false",
}

## The four alpha layers of the r566 archive, by piece: whether the rule
## makes it a cutout. Since round 625 the LAYER's flag word decides, as the
## client does (ObjectLoader.layer_draw_rule), and the textures only carry
## alpha a pixel rule would have read the other way for two of them:
## `graded` (all 128) is untested, `dxt1solid` (opaque) is two-sided.
const LAYER_FLAGS := {"bin": 0x341, "graded": 0x140, "dxt1cut": 0x340, "dxt1solid": 0x141}
const ALPHA_EXPECTED := {"bin": true, "graded": false, "dxt1cut": true, "dxt1solid": false}
const TWO_SIDED_EXPECTED := {"bin": true, "graded": false, "dxt1cut": false, "dxt1solid": true}

## Round 625: THE MATERIAL RULE, READ from the client (ObjectLoader's
## comment above layer_draw_rule): flag 0x200 is the alpha test at
## ALPHAREF 0x80 / GREATEREQUAL, flag 0x1 is cull none, and the two are
## independent; an ENVMAP mod replaces the test with its own (ref 1, or
## none) -- for every material of the object (round 626, READ). The texture is the same DXT3
## leaf with real transparency in every case -- only the flag word differs.
## NEGATIVE: before this round bit 0 was the "alpha" bit, so a 0x340 needle
## card (alpha test, one-sided) drew as a solid StandardMaterial3D.
func _test_round_625() -> void:
	var path := "user://srrevamp_objloader_r625.pk2"
	_build_alpha_archive(path)
	var archive := Pk2Reader.open(path)
	_check(archive != null, "r625: opens the alpha archive")
	if archive == null:
		return
	var layer_for := func(flags: int) -> BmtReader.Layer:
		var l := BmtReader.Layer.new()
		l.layer_name = "leaf_%x" % flags
		l.ambient = Color.WHITE
		l.texture_path = "leaf.ddj"
		l.unknown = flags
		return l
	# The needle card first, with the three-argument call BASE also has.
	var needle: Material = ObjectLoader.build_godot_material(archive, "", layer_for.call(0x340))
	var sm := needle as ShaderMaterial
	_check(sm != null and sm.shader == _ol_const("FOLIAGE_SHADER_ONE_SIDED")
			and is_equal_approx(float(sm.get_shader_parameter("alpha_scissor")), 128.0 / 255.0),
		"r625: a 0x340 layer is alpha-tested at 128/255 and ONE-sided (got %s)" % needle)
	var OL = load("res://scripts/assets/object_loader.gd")
	var names := {}
	for m in (OL as GDScript).get_script_method_list():
		names[m["name"]] = true
	if not names.has("layer_draw_rule"):
		_check(false, "r625: ObjectLoader.layer_draw_rule exists")
		archive.close()
		DirAccess.remove_absolute(path)
		return
	# The item column is gone (round 626): an item is drawn by the same rule
	# as anything else; what spares armour is its ENVMAP mod (the env column).
	var cases := [
		# flags, env map, expected alpha ref, expected two-sided
		[0x341, -1, 128, true],
		[0x340, -1, 128, false],
		[0x141, -1, 0, true],
		[0x140, -1, 0, false],
		[0x040, -1, 0, false],
		[0x2345, -1, 128, true],
		[0x341, 0x1, 0, true],
		[0x340, 0x3, 1, false],
	]
	for c in cases:
		var rule: Dictionary = OL.layer_draw_rule(c[0], c[1])
		_check(rule == {"alpha_ref": c[2], "two_sided": c[3]},
			"r625: flags 0x%x env %d -> ref %d two-sided %s (got %s)" % [c[0], c[1], c[2], c[3], rule])
		var mat: Material = OL.build_godot_material(archive, "", layer_for.call(c[0]), {}, c[1])
		if c[2] > 0 or c[3]:
			var shader := mat as ShaderMaterial
			_check(shader != null
					and shader.shader == (ObjectLoader.FOLIAGE_SHADER if c[3] else _ol_const("FOLIAGE_SHADER_ONE_SIDED"))
					and is_equal_approx(float(shader.get_shader_parameter("alpha_scissor")), float(c[2]) / 255.0),
				"r625: flags 0x%x env %d builds the %s foliage shader at %d/255 (got %s)" % [c[0], c[1],
					"two-sided" if c[3] else "one-sided", c[2], mat])
		else:
			_check(mat is StandardMaterial3D and (mat as StandardMaterial3D).cull_mode == BaseMaterial3D.CULL_BACK
					and (mat as StandardMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_DISABLED,
				"r625: flags 0x%x env %d is solid and one-sided whatever the texture's alpha (got %s)" % [
					c[0], c[1], mat])
	archive.close()
	DirAccess.remove_absolute(path)

func _test_round_566() -> void:
	var OL = load("res://scripts/assets/object_loader.gd")
	var names := {}
	for m in (OL as GDScript).get_script_method_list():
		names[m["name"]] = true
	var split_present := true
	for needed in ["prepare_object", "commit_object", "snapshot_textures", "commit_textures"]:
		if not names.has(needed):
			split_present = false
		_check(names.has(needed), "ObjectLoader has %s (absent before round 566)" % needed)

	var archives := {
		"main": ["user://srrevamp_r566_objloader_main.pk2", "_build_archive", "prim/testobj.bsr", "testobj"],
		"namematch": ["user://srrevamp_r566_objloader_nm.pk2", "_build_name_match_archive", "nameMatchObj.bsr", "namematch"],
		"cpd": ["user://srrevamp_r566_objloader_cpd.pk2", "_build_cpd_archive", "testcompound.cpd", "compound"],
		"alpha": ["user://srrevamp_r566_objloader_alpha.pk2", "_build_r566_archive", "alphaobj.bsr", "alphaobj"],
	}
	for which in archives:
		var spec: Array = archives[which]
		call(spec[1], spec[0])
		var archive := Pk2Reader.open(spec[0])
		_check(archive != null, "r566: opens the %s archive" % which)
		if archive == null:
			continue
		var fp_name: String = spec[3]
		var loaded := ObjectLoader.load_object(archive, spec[2])
		var fp_loaded := _fingerprint(loaded) if loaded != null else "null"
		print("fingerprint %s: %s" % [fp_name, fp_loaded])
		var expected: String = EXPECTED_FINGERPRINTS[fp_name]
		_check(fp_loaded == expected, "load_object builds %s exactly as the pre-split loader did" % fp_name)
		if split_present:
			var prepared: Dictionary = OL.prepare_object(archive, spec[2])
			var committed: Node3D = OL.commit_object(prepared)
			var fp_split := _fingerprint(committed) if committed != null else "null"
			_check(fp_split == expected, "commit_object(prepare_object()) builds %s exactly as the pre-split loader did" % fp_name)
			if fp_split != expected:
				print("  got  %s" % fp_split)
			_check_faces(prepared, fp_name)
			if committed != null:
				committed.free()
		if loaded != null:
			if which == "alpha":
				_check_alpha_classes(loaded, "load_object")
			loaded.free()
		if which == "alpha" and split_present:
			_test_alpha_on_the_image(OL, archive)
			_test_prepare_on_a_task(OL, archive, spec[2])
		archive.close()
		DirAccess.remove_absolute(spec[0])

## The four alpha pieces' materials: a cutout is the foliage ShaderMaterial,
## anything else a StandardMaterial3D -- each textured.
func _check_alpha_classes(root: Node, via: String) -> void:
	for piece in ALPHA_EXPECTED:
		var mi := root.get_node_or_null(piece) as MeshInstance3D
		_check(mi != null, "%s: the %s piece is there" % [via, piece])
		if mi == null:
			continue
		var cutout: bool = ALPHA_EXPECTED[piece]
		var two: bool = TWO_SIDED_EXPECTED[piece]
		var mat := mi.material_override
		if cutout or two:
			var sm := mat as ShaderMaterial
			_check(sm != null and sm.get_shader_parameter("albedo_texture") != null
					and is_equal_approx(float(sm.get_shader_parameter("alpha_scissor")), 128.0 / 255.0 if cutout else 0.0)
					and sm.shader == (ObjectLoader.FOLIAGE_SHADER if two else _ol_const("FOLIAGE_SHADER_ONE_SIDED")),
				"%s: flags 0x%x make %s %s, %s (got %s)" % [via, LAYER_FLAGS[piece], piece,
					"alpha-tested at 128" if cutout else "untested", "two-sided" if two else "one-sided", mat])
		else:
			_check(mat is StandardMaterial3D and (mat as StandardMaterial3D).albedo_texture != null
					and (mat as StandardMaterial3D).cull_mode == BaseMaterial3D.CULL_BACK,
				"%s: flags 0x%x leave %s solid and one-sided (got %s)" % [via, LAYER_FLAGS[piece], piece, mat])

## Each prepared piece's faces against the trimesh the engine builds from
## the same arrays once uploaded -- the readback they replace.
func _check_faces(prepared: Dictionary, what: String) -> void:
	var pieces: Array = []
	_collect_pieces(prepared.get("root"), pieces)
	var compared := 0
	for piece in pieces:
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, piece["arrays"])
		var shape := mesh.create_trimesh_shape()
		var engine_faces: PackedVector3Array = shape.get_faces() if shape != null else PackedVector3Array()
		var ours: PackedVector3Array = piece["faces"] if piece["faces"] != null else PackedVector3Array()
		_check(piece["faces"] != null and ours == engine_faces,
			"%s piece %s: the prepared faces are create_trimesh_shape()'s, element for element (%d vs %d corners)" % [
				what, piece["name"], ours.size(), engine_faces.size()])
		compared += 1
	_check(compared > 0, "%s: %d piece(s) compared" % [what, compared])

func _collect_pieces(node, out: Array) -> void:
	if node == null:
		return
	if node["kind"] == "cpd":
		for child in node["children"]:
			_collect_pieces(child, out)
	else:
		out.append_array(node["pieces"])

## The rule, on the prepare's own data: the plan's classification per
## piece, the statistic measured on the decoded Image, the cache carrying
## it, and the QA line saying where each came from.
func _test_alpha_on_the_image(OL, archive: Pk2Reader) -> void:
	OS.set_environment("SRREVAMP_QA_ALPHA_LOG", "1")
	var prepared: Dictionary = OL.prepare_object(archive, "alphaobj.bsr")
	var plans := {}
	var pieces: Array = []
	_collect_pieces(prepared["root"], pieces)
	for piece in pieces:
		plans[piece["name"]] = piece["material"]
	for piece in ALPHA_EXPECTED:
		var plan = plans.get(piece)
		_check(plan != null and plan["cutout"] == ALPHA_EXPECTED[piece] and plan["two_sided"] == TWO_SIDED_EXPECTED[piece]
				and plan["texture_key"] == piece + ".ddj",
			"prepare: %s's plan is cutout=%s two_sided=%s on %s.ddj (got %s)" % [piece, ALPHA_EXPECTED[piece],
				TWO_SIDED_EXPECTED[piece], piece, plan])
	var textures: Dictionary = prepared["textures"]
	_check(textures.size() == 4, "prepare: the four textures decoded once each (got %d)" % textures.size())
	for key in textures:
		_check(textures[key]["image"] is Image, "prepare: %s decoded to an Image" % key)
		# Round 625: the rule reads the flag word, never the pixels.
		_check((textures[key]["alpha"] as Dictionary).is_empty(),
			"prepare: no pixel statistic measured on %s (got %s)" % [key, textures[key]["alpha"]])
	var log_text := "\n".join(PackedStringArray(prepared["log"]))
	_check(not log_text.contains("QA ALPHA"), "SRREVAMP_QA_ALPHA_LOG: nothing consulted the pixels (log: %s)" % log_text)

	# Committed into a cache, the textures travel; a second prepare over the
	# snapshot decodes nothing and classifies the same.
	var cache := {}
	var first: Node3D = OL.commit_object(prepared, cache)
	_check(first != null and cache.size() == 4 and cache["bin.ddj"]["texture"] is ImageTexture,
		"the cache holds each texture")
	if first != null:
		_check_alpha_classes(first, "commit_object")
		first.free()
	var snapshot: Dictionary = OL.snapshot_textures(cache)
	_check(_forbidden(snapshot).is_empty() and snapshot["bin.ddj"] == {"four_cc": "", "alpha": {}},
		"the snapshot names each texture by fourCC and statistics, never the texture (got %s)" % str(snapshot.get("bin.ddj")))
	var again: Dictionary = OL.prepare_object(archive, "alphaobj.bsr", snapshot)
	var decoded_again := 0
	for key in again["textures"]:
		if again["textures"][key]["image"] != null:
			decoded_again += 1
	_check(decoded_again == 0, "a texture the cache holds is not decoded again (%d were)" % decoded_again)
	var second: Node3D = OL.commit_object(again, cache)
	if second != null:
		_check_alpha_classes(second, "commit over the snapshot")
		second.free()

	# SRREVAMP_QA_MATS still measures -- the one statistic left, `fraction`,
	# on an untested layer -- and a cached texture lacking it is decoded
	# from the file for it, never read back from the cached texture.
	OS.set_environment("SRREVAMP_QA_MATS", "1")
	var third: Dictionary = OL.prepare_object(archive, "alphaobj.bsr", OL.snapshot_textures(cache))
	OS.set_environment("SRREVAMP_QA_MATS", "")
	var third_log := "\n".join(PackedStringArray(third["log"]))
	_check(third["textures"]["graded.ddj"]["image"] is Image
			and is_equal_approx(float(third["textures"]["graded.ddj"]["alpha"].get("fraction", -1.0)), 1.0)
			and third_log.contains("QA MAT: graded (graded.ddj, ) is 100.0% non-opaque, flags 0x0140, no alpha test"),
		"QA_MATS: an untested layer's texture is decoded and measured, and reported (got %s / %s)" % [
			third["textures"]["graded.ddj"]["alpha"], third_log])
	OS.set_environment("SRREVAMP_QA_ALPHA_LOG", "")

	# build_godot_material (SkinnedBsrAssembler's path) takes the same rule.
	var bmt_entry := ObjectLoader.find_file(archive, "alpha.bmt")
	var material := BmtReader.parse(archive.read_file(bmt_entry)) if bmt_entry != null else null
	_check(material != null and material.layers.size() == 4, "the r566 material parses, four layers")
	if material != null:
		for layer in material.layers:
			var mat: Material = ObjectLoader.build_godot_material(archive, "alpha.bmt", layer)
			var shader_expected: bool = ALPHA_EXPECTED[layer.layer_name] or TWO_SIDED_EXPECTED[layer.layer_name]
			_check((mat is ShaderMaterial) == shader_expected,
				"build_godot_material: %s is %s (got %s)" % [layer.layer_name,
					"the foliage material" if shader_expected else "solid", mat])

## The prepare on a WorkerThreadPool task, the way World3D's cell task runs
## it: it finishes, holds no Node and no Resource but Image, and commits to
## the same tree as the main thread's.
func _test_prepare_on_a_task(OL, archive: Pk2Reader, path: String) -> void:
	var out := {}
	var task := WorkerThreadPool.add_task(func(): out["prepared"] = OL.prepare_object(archive, path, {}, {}), true, "r566 object prepare test")
	WorkerThreadPool.wait_for_task_completion(task)
	_check(out.has("prepared") and out["prepared"]["root"] != null, "the prepare ran to the end on a task")
	if not out.has("prepared"):
		return
	var bad := _forbidden(out["prepared"])
	_check(bad.is_empty(), "the task's result holds no Node and no Resource but Image (found %s)" % str(bad))
	var committed: Node3D = OL.commit_object(out["prepared"])
	_check(committed != null and _fingerprint(committed) == EXPECTED_FINGERPRINTS["alphaobj"],
		"the task-prepared object commits to the pre-split loader's tree")
	_test_the_walk_sees_what_it_forbids(out["prepared"], committed)
	if committed != null:
		committed.free()

## The walk's positive control (round 566's second review: every call above
## expects it to find nothing, so it must be shown to find something). A
## deep copy of the task's prepared object with forbidden things planted
## where a prepare could leave them -- a texture inside a piece, the
## committed Node, a mesh behind a RefCounted's script variable (the path the
## walk takes into the readers' structs) -- must be reported, each by its
## path, and an Image planted beside them must not.
func _test_the_walk_sees_what_it_forbids(prepared: Dictionary, committed: Node3D) -> void:
	var planted: Dictionary = prepared.duplicate(true)
	var pieces: Array = (planted["root"] as Dictionary).get("pieces", [])
	if pieces.is_empty() or committed == null:
		_check(false, "the walk's control has a prepared piece and a committed node to plant")
		return
	(pieces[0] as Dictionary)["planted"] = ImageTexture.new()
	planted["node"] = committed
	var holder_script := GDScript.new()
	holder_script.source_code = "extends RefCounted\nvar held\n"
	holder_script.reload()
	var holder = holder_script.new()
	holder.held = ArrayMesh.new()
	planted["holder"] = holder
	planted["image"] = Image.create(1, 1, false, Image.FORMAT_RGBA8)
	var found := _forbidden(planted)
	found.sort()
	_check(found == ["prepared.holder.held: ArrayMesh", "prepared.node: Node3D", "prepared.root.pieces[0].planted: ImageTexture"],
		"the walk finds a texture in a piece, the committed Node and a mesh behind a script variable -- and passes the Image (got %s)" % str(found))

## A test-local object tree fingerprint: per node its depth, class and name
## (an engine-generated `@Class@n` name as `@`), per mesh its surfaces'
## vertex/index counts and sums, per material its kind, name, texture size,
## albedo and cutout settings, per shape its class and faces' count and sum.
func _fingerprint(node: Node) -> String:
	var parts := PackedStringArray()
	_fp(node, 0, parts)
	return " | ".join(parts)

func _fp(node: Node, depth: int, parts: PackedStringArray) -> void:
	var node_name := String(node.name)
	var s := "%d:%s:%s" % [depth, node.get_class(), "@" if node_name.begins_with("@") else node_name]
	if node is MeshInstance3D:
		var mesh := (node as MeshInstance3D).mesh
		s += " surfaces=%d" % (mesh.get_surface_count() if mesh != null else -1)
		if mesh != null:
			for i in range(mesh.get_surface_count()):
				var arrays := mesh.surface_get_arrays(i)
				var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				var psum := Vector3.ZERO
				for p in positions:
					psum += p
				var isum := 0
				for k in indices:
					isum += k
				s += " [v=%d i=%d isum=%d psum=%.4f,%.4f,%.4f]" % [positions.size(), indices.size(), isum, psum.x, psum.y, psum.z]
		s += " mat=" + _mat_fp((node as MeshInstance3D).material_override)
	elif node is CollisionShape3D:
		var shape := (node as CollisionShape3D).shape
		if shape == null:
			s += " shape=null"
		elif shape is ConcavePolygonShape3D:
			var faces := (shape as ConcavePolygonShape3D).get_faces()
			var fsum := Vector3.ZERO
			for f in faces:
				fsum += f
			s += " shape=ConcavePolygonShape3D faces=%d fsum=%.4f,%.4f,%.4f backface=%s" % [
				faces.size(), fsum.x, fsum.y, fsum.z, (shape as ConcavePolygonShape3D).backface_collision]
		else:
			s += " shape=" + shape.get_class()
	parts.append(s)
	for child in node.get_children():
		_fp(child, depth + 1, parts)

func _mat_fp(mat: Material) -> String:
	if mat == null:
		return "null"
	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		var tex: Texture2D = sm.get_shader_parameter("albedo_texture")
		return "Shader(%s,shader=%s,tex=%s,scissor=%.4f,albedo=%s)" % [sm.resource_name,
			"two" if sm.shader == ObjectLoader.FOLIAGE_SHADER else ("one" if sm.shader == _ol_const("FOLIAGE_SHADER_ONE_SIDED") else "other"),
			"%dx%d" % [tex.get_width(), tex.get_height()] if tex != null else "null",
			sm.get_shader_parameter("alpha_scissor"), sm.get_shader_parameter("albedo")]
	if mat is StandardMaterial3D:
		var std := mat as StandardMaterial3D
		var tex := std.albedo_texture
		return "Standard(%s,tex=%s,albedo=%s,transparency=%d,cull=%d)" % [std.resource_name,
			"%dx%d" % [tex.get_width(), tex.get_height()] if tex != null else "null",
			std.albedo_color, std.transparency, std.cull_mode]
	return mat.get_class()

## Every Object reachable from `v` that is a Node, or a Resource other than
## an Image -- what the prepare-thread rule forbids (terrain_prepare_test's
## walk, same rules).
func _forbidden(v: Variant) -> Array:
	var out: Array = []
	_walk(v, {}, "prepared", out)
	return out

func _walk(v: Variant, seen: Dictionary, path: String, out: Array) -> void:
	match typeof(v):
		TYPE_ARRAY:
			var a: Array = v
			for i in range(a.size()):
				_walk(a[i], seen, "%s[%d]" % [path, i], out)
		TYPE_DICTIONARY:
			var d: Dictionary = v
			for k in d:
				_walk(k, seen, "%s{key}" % path, out)
				_walk(d[k], seen, "%s.%s" % [path, str(k)], out)
		TYPE_OBJECT:
			if v == null or not is_instance_valid(v):
				return
			var o: Object = v
			if seen.has(o.get_instance_id()):
				return
			seen[o.get_instance_id()] = true
			if o is Node or (o is Resource and not o is Image):
				out.append("%s: %s" % [path, o.get_class()])
				return
			for prop in o.get_property_list():
				if int(prop["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
					_walk(o.get(prop["name"]), seen, "%s.%s" % [path, prop["name"]], out)

## The r566 archive, root-level only: `alphaobj.bsr` with four pieces whose
## material names are the four layers of an uncompressed `alpha.bmt` with a
## zero flag word (so the pixels decide, LAYER_FLAG_MASK), each layer's
## texture `<name>.ddj`: `bin` uncompressed 32-bit BGRA with half its texels
## at alpha 0 and half at 255, `graded` all at 128, `dxt1cut` one DXT1 block
## in the three-colour mode with every index 3 (transparent), `dxt1solid`
## one opaque four-colour block. The pieces' corners are off the 0.0001 grid
## and `bin` carries a degenerate triangle. Synthetic, never game data.
func _build_r566_archive(path: String) -> void:
	var corners := [Vector3(0.123456, 1.000049, 2.5), Vector3(3.141593, 0.0, -1.23456), Vector3(-2.71828, 4.44444, 0.00005)]
	var files := {}
	files["alphaobj.bsr"] = _build_bsr("AlphaObj", "bin.bms", "alpha.bmt", ["graded.bms", "dxt1cut.bms", "dxt1solid.bms"])
	files["bin.bms"] = _build_bms_tris("bin", "bin", corners, [[0, 1, 2], [0, 0, 1]])
	files["graded.bms"] = _build_bms_tris("graded", "graded", corners, [[0, 2, 1]])
	files["dxt1cut.bms"] = _build_bms_tris("dxt1cut", "dxt1cut", corners, [[1, 2, 0]])
	files["dxt1solid.bms"] = _build_bms_tris("dxt1solid", "dxt1solid", corners, [[2, 1, 0]])
	files["alpha.bmt"] = _build_uncompressed_bmt(["bin", "graded", "dxt1cut", "dxt1solid"], LAYER_FLAGS)
	var binary := PackedByteArray()
	var graded := PackedByteArray()
	for i in range(16):
		binary.append(0 if i % 2 == 0 else 255)
		graded.append(128)
	files["bin.ddj"] = _build_bgra_ddj(4, 4, binary)
	files["graded.ddj"] = _build_bgra_ddj(4, 4, graded)
	files["dxt1cut.ddj"] = _build_dxt1_ddj(PackedByteArray([0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]))
	files["dxt1solid.ddj"] = _build_dxt1_ddj(PackedByteArray([0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
	_write_flat_pk2(path, files)

## A `.bms` with the given corners and triangles (index triples), the
## layout _build_bms writes.
func _build_bms_tris(mesh_name: String, material_name: String, corners: Array, tris: Array) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(BmsReader.PREAMBLE_END)
	var magic := BmsReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	buf = _append_len_prefixed(buf, mesh_name)
	buf = _append_len_prefixed(buf, material_name)
	var counts := PackedByteArray()
	counts.resize(8)
	_put_u32(counts, 0, 1)
	_put_u32(counts, 4, corners.size())
	buf.append_array(counts)
	for corner in corners:
		var rec := PackedByteArray()
		rec.resize(44)
		_put_f32(rec, 0x00, corner.x)
		_put_f32(rec, 0x04, corner.y)
		_put_f32(rec, 0x08, corner.z)
		_put_f32(rec, 0x10, 1.0) # normal.y
		buf.append_array(rec)
	var index_off := buf.size()
	_put_u32(buf, BmsReader.HEADER_PTRS_BASE + 1 * 4, index_off)
	var idx := PackedByteArray()
	idx.resize(4 + tris.size() * 6)
	_put_u32(idx, 0, tris.size())
	for t in range(tris.size()):
		for c in range(3):
			idx[4 + t * 6 + c * 2] = tris[t][c]
	buf.append_array(idx)
	return buf

## An uncompressed 32-bit `.ddj` with the standard BGRA masks declared
## (DDJ_FORMAT.md; DdjReader decodes by the masks), colour fixed, alpha per
## texel from `alphas`.
func _build_bgra_ddj(width: int, height: int, alphas: PackedByteArray) -> PackedByteArray:
	var dds := PackedByteArray()
	dds.resize(4 + DdjReader.DDS_HEADER_SIZE + width * height * 4)
	var magic_bytes := "DDS ".to_ascii_buffer()
	for i in range(4):
		dds[i] = magic_bytes[i]
	_put_u32(dds, 4, DdjReader.DDS_HEADER_SIZE)
	_put_u32(dds, 4 + 8, height)
	_put_u32(dds, 4 + 12, width)
	_put_u32(dds, 4 + 24, 1)
	var pf_off := 4 + 72
	_put_u32(dds, pf_off, 32)
	_put_u32(dds, pf_off + 4, DdjReader.DDPF_RGB | DdjReader.DDPF_ALPHAPIXELS)
	_put_u32(dds, pf_off + 12, 32)
	_put_u32(dds, pf_off + 16, 0x00ff0000)
	_put_u32(dds, pf_off + 20, 0x0000ff00)
	_put_u32(dds, pf_off + 24, 0x000000ff)
	_put_u32(dds, pf_off + 28, 0xff000000)
	var px := 4 + DdjReader.DDS_HEADER_SIZE
	for i in range(width * height):
		dds[px + i * 4] = 0x40
		dds[px + i * 4 + 1] = 0x80
		dds[px + i * 4 + 2] = 0xc0
		dds[px + i * 4 + 3] = alphas[i]
	return _wrap_ddj(dds, 3)

## A 4x4 DXT1 `.ddj` holding the one 8-byte block given.
func _build_dxt1_ddj(block: PackedByteArray) -> PackedByteArray:
	var dds := PackedByteArray()
	dds.resize(4 + DdjReader.DDS_HEADER_SIZE)
	var magic_bytes := "DDS ".to_ascii_buffer()
	for i in range(4):
		dds[i] = magic_bytes[i]
	_put_u32(dds, 4, DdjReader.DDS_HEADER_SIZE)
	_put_u32(dds, 4 + 8, 4)
	_put_u32(dds, 4 + 12, 4)
	_put_u32(dds, 4 + 24, 1)
	var pf_off := 4 + 72
	_put_u32(dds, pf_off, 32)
	_put_u32(dds, pf_off + 4, DdjReader.DDPF_FOURCC)
	var cc := "DXT1".to_ascii_buffer()
	for i in range(4):
		dds[pf_off + 8 + i] = cc[i]
	dds.append_array(block)
	return _wrap_ddj(dds, 1)

func _wrap_ddj(dds: PackedByteArray, kind: int) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(DdjReader.WRAPPER_SIZE + dds.size())
	var magic := DdjReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	_put_u32(buf, 0x0c, buf.size() - DdjReader.MAGIC_LEN)
	_put_u32(buf, 0x10, kind)
	for i in range(dds.size()):
		buf[DdjReader.WRAPPER_SIZE + i] = dds[i]
	return buf

## A root-level-only synthetic pk2 (at most 19 files, one block).
func _write_flat_pk2(path: String, files: Dictionary) -> void:
	var header := PackedByteArray()
	header.resize(Pk2Reader.HEADER_SIZE)
	var magic := "JoyMax File Manager!".to_ascii_buffer()
	for i in range(magic.size()):
		header[i] = magic[i]
	var root_off := Pk2Reader.HEADER_SIZE
	var data_off := root_off + Pk2Reader.BLOCK_SIZE
	var block := PackedByteArray()
	block.resize(Pk2Reader.BLOCK_SIZE)
	_write_block_entry(block, 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", root_off, 0)
	var data := PackedByteArray()
	var slot := 1
	for name in files:
		var bytes: PackedByteArray = files[name]
		_write_block_entry(block, slot, Pk2Reader.ENTRY_TYPE_FILE, name, data_off + data.size(), bytes.size())
		data.append_array(bytes)
		slot += 1
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(header)
	f.store_buffer(block)
	f.store_buffer(data)
	f.close()

func _write_block_entry(block: PackedByteArray, i: int, entry_type: int, name: String, offset: int, size: int) -> void:
	var base := i * Pk2Reader.ENTRY_SIZE
	block[base] = entry_type
	var nb := name.to_ascii_buffer()
	for j in range(nb.size()):
		block[base + Pk2Reader.ENTRY_OFF_NAME + j] = nb[j]
	_put_u32(block, base + Pk2Reader.ENTRY_OFF_POSITION, offset)
	_put_u32(block, base + Pk2Reader.ENTRY_OFF_SIZE, size)

func _init() -> void:
	var path := "user://srrevamp_objloader_test.pk2"
	_build_archive(path)

	var archive := Pk2Reader.open(path)
	_check(archive != null, "opens synthetic archive")

	if archive != null:
		var obj := ObjectLoader.load_object(archive, "prim\\wall01.bsr")
		_check(obj == null, "nonexistent .bsr correctly fails to load")

		var missing_dir := ObjectLoader.load_object(archive, "nope\\testobj.bsr")
		_check(missing_dir == null, "nonexistent directory correctly fails to load")

		var real := ObjectLoader.load_object(archive, "prim/testobj.bsr")
		_check(real != null, "loads a real synthetic .bsr end-to-end")
		if real != null:
			_check(real.name == "TestObj", "root node named after object (got %s)" % real.name)
			_check(real.get_child_count() == 2, "2 mesh pieces loaded (got %d)" % real.get_child_count())
			for child in real.get_children():
				_check(child is MeshInstance3D, "child %s is a MeshInstance3D" % child.name)
				var mi := child as MeshInstance3D
				_check(mi.mesh != null, "child %s has a mesh assigned" % child.name)
				# TEST_BMT_HEX's own layer carries flag word 0x0341: 0x200,
				# the alpha test, and 0x1, two-sided (round 625,
				# ObjectLoader.layer_draw_rule). The fixture was taken from
				# real data, so it exercises the cutout path, and the
				# material it yields is the foliage ShaderMaterial rather
				# than a StandardMaterial3D.
				_check(mi.material_override != null, "child %s has a material applied" % child.name)
				_check(mi.material_override is ShaderMaterial,
					"child %s takes the cutout path its layer's alpha flag asks for (got %s)" % [
						child.name, mi.material_override])
				if mi.material_override is StandardMaterial3D:
					var mat := mi.material_override as StandardMaterial3D
					_check(mat.albedo_texture is ImageTexture, "child %s's material has a texture (got %s)" % [child.name, mat.albedo_texture])
					if mat.albedo_texture != null:
						_check(mat.albedo_texture.get_width() == 4 and mat.albedo_texture.get_height() == 4, "child %s's texture is 4x4 (got %dx%d)" % [child.name, mat.albedo_texture.get_width(), mat.albedo_texture.get_height()])
			real.free()

		# The texture cache (round 559): every material built through one
		# dictionary that names the same .ddj shares ONE Texture2D -- here
		# two pieces per load and two loads, four materials, one texture.
		# Without a cache each call gets its own dictionary: the two pieces
		# of one load share, the two loads do not -- two textures, which is
		# also the check that the omitted argument is a fresh dictionary per
		# call (a shared default would give one texture: a process-wide
		# cache, exactly the cross-instance state round 558 measured
		# against; the old per-piece decode gave four).
		var texture_cache := {}
		var first := ObjectLoader.load_object(archive, "prim/testobj.bsr", texture_cache)
		var second := ObjectLoader.load_object(archive, "prim/testobj.bsr", texture_cache)
		var plain_a := ObjectLoader.load_object(archive, "prim/testobj.bsr")
		var plain_b := ObjectLoader.load_object(archive, "prim/testobj.bsr")
		_check(first != null and second != null and plain_a != null and plain_b != null, "texture cache: all four loads succeed")
		if first != null and second != null and plain_a != null and plain_b != null:
			var shared := _distinct_albedo_textures([first, second])
			_check(shared == 1, "four pieces over two loads through one cache share one texture (got %d distinct)" % shared)
			_check(texture_cache.size() == 1 and texture_cache.keys()[0] == "prim/mtrl/walltex.ddj",
				"the cache holds the one .ddj under its resolved lower-cased path (got %s)" % [texture_cache.keys()])
			var separate := _distinct_albedo_textures([plain_a, plain_b])
			_check(separate == 2, "without a cache each call decodes its own texture and the calls do not share (got %d distinct; 1 would be a shared default)" % separate)
		for loaded in [first, second, plain_a, plain_b]:
			if loaded != null:
				loaded.free()

		archive.close()
	DirAccess.remove_absolute(path)

	var name_match_path := "user://srrevamp_objloader_namematch_test.pk2"
	_build_name_match_archive(name_match_path)
	var nm_archive := Pk2Reader.open(name_match_path)
	_check(nm_archive != null, "opens name-match synthetic archive")
	if nm_archive != null:
		var obj := ObjectLoader.load_object(nm_archive, "nameMatchObj.bsr")
		_check(obj != null, "loads the name-match object")
		if obj != null:
			var by_name := {}
			for child in obj.get_children():
				by_name[child.name] = child
			_check(by_name.has("pieceA") and by_name.has("pieceB"), "both real pieces loaded (got %s)" % [by_name.keys()])
			if by_name.has("pieceA") and by_name.has("pieceB"):
				var mat_a: StandardMaterial3D = by_name["pieceA"].material_override
				var mat_b: StandardMaterial3D = by_name["pieceB"].material_override
				_check(mat_a != null and mat_a.resource_name == "piece_a", "pieceA gets its real name-matched layer, not the positionally-first one (got %s)" % (mat_a.resource_name if mat_a != null else "null"))
				_check(mat_b != null and mat_b.resource_name == "piece_b", "pieceB gets its real name-matched layer, not the positionally-second one (got %s)" % (mat_b.resource_name if mat_b != null else "null"))
			obj.free()
		nm_archive.close()
	DirAccess.remove_absolute(name_match_path)

	var alpha_path := "user://srrevamp_objloader_alpha_test.pk2"
	_build_alpha_archive(alpha_path)
	var alpha_archive := Pk2Reader.open(alpha_path)
	_check(alpha_archive != null, "opens alpha synthetic archive")
	if alpha_archive != null:
		var layer := BmtReader.Layer.new()
		layer.layer_name = "leaf"
		layer.diffuse = Color.WHITE
		layer.texture_path = "leaf.ddj"
		layer.unknown = 0x341
		# Round 625: the same DXT3 texture under a layer whose flag word asks
		# for no alpha test draws solid -- the client never looks at the
		# pixels (ObjectLoader.layer_draw_rule).
		var untested := BmtReader.Layer.new()
		untested.layer_name = "leaf_untested"
		untested.texture_path = "leaf.ddj"
		untested.unknown = 0x140
		var solid := ObjectLoader.build_godot_material(alpha_archive, "", untested)
		_check(solid is StandardMaterial3D, "a 0x140 layer over an alpha texture is solid (got %s)" % solid.get_class())
		var mat := ObjectLoader.build_godot_material(alpha_archive, "", layer)
		# A real texture carrying real alpha now yields the real cutout
		# foliage material, not a StandardMaterial3D -- see
		# foliage.gdshader for why a real double-sided card cannot be one.
		_check(mat is ShaderMaterial, "real DXT3 alpha yields the real cutout foliage material (got %s)" % mat.get_class())
		if mat is ShaderMaterial:
			var foliage := mat as ShaderMaterial
			_check(foliage.shader == ObjectLoader.FOLIAGE_SHADER, "uses the real foliage shader")
			_check(foliage.get_shader_parameter("albedo_texture") != null, "real DXT3 texture loads")
			_check(foliage.get_shader_parameter("alpha_scissor") == ObjectLoader.FOLIAGE_ALPHA_SCISSOR, "real alpha cutout threshold is set")

		# Real failure mode found live-testing real Jangan palace materials
		# (2026-08-23): a layer's texture_path is sometimes a real *full
		# path* (pointing at a completely different real directory) rather
		# than a bare filename. bmt_path here ("other\\place.bmt") is
		# deliberately unrelated to "sub\\leaf2.ddj"'s real directory --
		# prefixing it would produce a nonexistent nonsense path.
		var full_path_layer := BmtReader.Layer.new()
		full_path_layer.layer_name = "leaf2"
		full_path_layer.diffuse = Color.WHITE
		full_path_layer.texture_path = "sub\\leaf2.ddj"
		var mat2 := ObjectLoader.build_godot_material(alpha_archive, "other\\place.bmt", full_path_layer)
		var mat2_tex: Texture2D = null
		if mat2 is ShaderMaterial:
			mat2_tex = (mat2 as ShaderMaterial).get_shader_parameter("albedo_texture")
		elif mat2 is StandardMaterial3D:
			mat2_tex = (mat2 as StandardMaterial3D).albedo_texture
		_check(mat2_tex != null, "a real full texture_path resolves correctly, ignoring bmt_path's own directory")

		alpha_archive.close()
	DirAccess.remove_absolute(alpha_path)

	# Real .cpd dispatch (2026-08-23, found live-testing real Jangan palace
	# scenery) -- load_object() must recurse through a real compound
	# object's real sub-.bsr reference(s), not fail outright on the real,
	# different magic.
	var cpd_path := "user://srrevamp_objloader_cpd_test.pk2"
	_build_cpd_archive(cpd_path)
	var cpd_archive := Pk2Reader.open(cpd_path)
	_check(cpd_archive != null, "opens cpd synthetic archive")
	if cpd_archive != null:
		var compound_obj := ObjectLoader.load_object(cpd_archive, "testcompound.cpd")
		_check(compound_obj != null, "loads a real .cpd end-to-end")
		if compound_obj != null:
			_check(compound_obj.name == "TestCompound", "root node named after the real compound (got %s)" % compound_obj.name)
			_check(compound_obj.get_child_count() == 1, "1 real sub-object loaded (got %d)" % compound_obj.get_child_count())
			if compound_obj.get_child_count() == 1:
				var piece: Node3D = compound_obj.get_child(0)
				_check(piece.name == "TestCompoundPiece", "sub-object named after its own real .bsr (got %s)" % piece.name)
				_check(piece.get_child_count() == 1, "sub-object has its 1 real mesh piece (got %d)" % piece.get_child_count())
			compound_obj.free()
		cpd_archive.close()
	DirAccess.remove_absolute(cpd_path)

	_test_round_566()
	_test_round_625()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
