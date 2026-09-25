extends SceneTree

## Exercises ObjectLoader against a synthetic pk2 archive containing a
## synthetic .bsr + .bms (never real game data), run headless:
## `godot4 --headless --path client --script res://scripts/assets/object_loader_test.gd`

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
func _build_uncompressed_bmt(layer_names: Array) -> PackedByteArray:
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
		dec.append_array(unk)
		dec = _append_len_prefixed(dec, "%s.ddj" % name)
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
				# TEST_BMT_HEX's own layer carries flag word 0x0341, i.e.
				# bit 0 set -- a real alpha layer (see
				# ObjectLoader.LAYER_FLAG_ALPHA). The fixture was taken
				# from real data, so it exercises the cutout path, and the
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

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
