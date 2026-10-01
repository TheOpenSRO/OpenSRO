extends SceneTree

## The native (Rust) readers against the GDScript ones on SYNTHETIC input
## (round 667; never real game data): an encrypted pk2 whose folder spans
## chained blocks, with a case-variant duplicate name, read both ways --
## directories, lookups, file bytes, and concurrent reads from worker
## threads -- and uncompressed and half-float .ddj textures decoded both
## ways. Without the library it checks the fallback instead: nothing native
## is used and the GDScript readers still answer.
##
##   godot4 --headless --path client --script res://scripts/pk2/native_assets_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _put_u32(b: PackedByteArray, at: int, v: int) -> void:
	b.encode_u32(at, v)

func _entry(block: PackedByteArray, i: int, kind: int, name: String, pos: int, size: int, next_block: int = 0) -> void:
	var base := i * Pk2Reader.ENTRY_SIZE
	block[base] = kind
	var nb := name.to_ascii_buffer()
	for j in range(nb.size()):
		block[base + Pk2Reader.ENTRY_OFF_NAME + j] = nb[j]
	_put_u32(block, base + Pk2Reader.ENTRY_OFF_POSITION, pos)
	_put_u32(block, base + Pk2Reader.ENTRY_OFF_SIZE, size)
	_put_u32(block, base + Pk2Reader.ENTRY_OFF_NEXT_BLOCK, next_block)

## The format's directory obfuscation, the other way (Blowfish encrypt with
## each 4-byte half little-endian): what a real archive's blocks hold.
func _encrypt(block: PackedByteArray) -> void:
	var bf := Blowfish.new(Pk2Reader._effective_key(Pk2Reader.DEFAULT_KEY.to_ascii_buffer()))
	var off := 0
	while off + 8 <= block.size():
		var lr := [block.decode_u32(off), block.decode_u32(off + 4)]
		bf._encrypt_block(lr)
		block.encode_u32(off, lr[0])
		block.encode_u32(off + 4, lr[1])
		off += 8

## root: Data (folder), readme.txt. Data: f00..f24 over two chained blocks,
## a later "F03" (the first of a name wins), and Sub (folder) with x.bin.
func _build(path: String) -> PackedByteArray:
	var root := Pk2Reader.HEADER_SIZE
	var b1 := root + Pk2Reader.BLOCK_SIZE
	var b2 := b1 + Pk2Reader.BLOCK_SIZE
	var sub := b2 + Pk2Reader.BLOCK_SIZE
	var payload_at := sub + Pk2Reader.BLOCK_SIZE
	var blocks: Array[PackedByteArray] = []
	for _i in range(4):
		var b := PackedByteArray()
		b.resize(Pk2Reader.BLOCK_SIZE)
		blocks.append(b)
	_entry(blocks[0], 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", root, 0)
	_entry(blocks[0], 1, Pk2Reader.ENTRY_TYPE_FOLDER, "Data", b1, 0)
	_entry(blocks[0], 2, Pk2Reader.ENTRY_TYPE_FILE, "readme.txt", payload_at, 5)
	for i in range(19):
		_entry(blocks[1], i, Pk2Reader.ENTRY_TYPE_FILE, "f%02d" % i, payload_at + i, 1)
	_entry(blocks[1], 19, Pk2Reader.ENTRY_TYPE_FILE, "f19", payload_at + 19, 1, b2)
	for i in range(5):
		_entry(blocks[2], i, Pk2Reader.ENTRY_TYPE_FILE, "f%02d" % (20 + i), payload_at + 20 + i, 1)
	_entry(blocks[2], 5, Pk2Reader.ENTRY_TYPE_FILE, "F03", payload_at + 2, 3)
	_entry(blocks[2], 6, Pk2Reader.ENTRY_TYPE_FOLDER, "Sub", sub, 0)
	_entry(blocks[3], 0, Pk2Reader.ENTRY_TYPE_FILE, "x.bin", payload_at, 25)
	var header := PackedByteArray()
	header.resize(Pk2Reader.HEADER_SIZE)
	var magic := "JoyMax File Manager!".to_ascii_buffer()
	for i in range(magic.size()):
		header[i] = magic[i]
	header[0x22] = 1
	var body := PackedByteArray()
	for i in range(25):
		body.append(0x61 + i)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(header)
	for b in blocks:
		_encrypt(b)
		f.store_buffer(b)
	f.store_buffer(body)
	f.close()
	return body

func _same(a: Pk2Reader.Entry, b: Pk2Reader.Entry) -> bool:
	if a == null or b == null:
		return a == b
	return a.name == b.name and a.is_dir == b.is_dir and a._offset == b._offset and a.size == b.size

func _ddj(four_cc: String, bpp: int, masks: Array, w: int, h: int, pixels: PackedByteArray) -> DdjReader.ParsedTexture:
	var t := DdjReader.ParsedTexture.new()
	t.width = w
	t.height = h
	t.mip_map_count = 1
	t.four_cc = four_cc
	t.rgb_bit_count = bpp
	t.r_mask = masks[0]
	t.g_mask = masks[1]
	t.b_mask = masks[2]
	t.a_mask = masks[3]
	var dds := PackedByteArray()
	dds.resize(4 + DdjReader.DDS_HEADER_SIZE)
	dds.append_array(pixels)
	t.dds = dds
	return t

func _init() -> void:
	# The interface check (round 667's review, M2): a stale library -- API 0,
	# built before the number existed, or any other number -- is refused.
	_check(NativeAssets.api_verdict(NativeAssets.NATIVE_API) == "", "a library speaking API %d is accepted" % NativeAssets.NATIVE_API)
	_check(NativeAssets.api_verdict(0).contains("stale"), "a library without api() (API 0) is refused as stale")
	_check(NativeAssets.api_verdict(NativeAssets.NATIVE_API + 1) != "", "a library from newer sources is refused too")
	_check(NativeAssets.api_verdict(-1) == "not loaded", "no library is 'not loaded'")
	# The native comparisons need the readers ON: the library usable AND not
	# switched off by SRREVAMP_NATIVE=0 (round 671's review: under that switch
	# the suite expected a native handle and failed).
	var loaded := NativeAssets.library_usable() and NativeAssets.available()
	print("native library loaded: %s, API %d (client %d)" % [NativeAssets.library_loaded(), NativeAssets.library_api(), NativeAssets.NATIVE_API])
	if NativeAssets.library_loaded() and not loaded:
		_check(not NativeAssets.available(), "a refused library is not used")
	var path := "user://srrevamp_native_test.pk2"
	var body := _build(path)

	NativeAssets.force_gdscript = true
	var g := Pk2Reader.open(path)
	NativeAssets.force_gdscript = false
	var n := Pk2Reader.open(path)
	_check(g != null and n != null, "the synthetic encrypted archive opens both ways")
	_check(not g.is_native(), "force_gdscript gives a GDScript handle")
	if not loaded:
		_check(not n.is_native() and not NativeAssets.available(), "without the library nothing is native")
		var e := ObjectLoader.find_file(n, "data\\sub\\X.BIN")
		_check(e != null and n.read_file(e) == body, "without the library the GDScript reader still answers")
		print("SKIP native comparisons: the native readers are off (no usable library, or SRREVAMP_NATIVE=0)")
	else:
		_check(n.is_native(), "with the library the handle is native")
		var gd_root := g.read_dir()
		var nt_root := n.read_dir()
		_check(gd_root.size() == 2 and nt_root.size() == 2, "the root lists 2 entries both ways ('.' skipped)")
		var data_g := ObjectLoader.find_file(g, "Data")
		var data_n := ObjectLoader.find_file(n, "Data")
		_check(_same(data_g, data_n), "Data resolves the same both ways")
		var dg := g.read_dir_at(data_g)
		var dn := n.read_dir_at(data_n)
		var same := dg.size() == dn.size() and dg.size() == 27
		for i in range(mini(dg.size(), dn.size())):
			same = same and _same(dg[i], dn[i])
		_check(same, "Data's 27 entries over two chained blocks agree entry for entry (%d / %d)" % [dg.size(), dn.size()])
		for q in ["DATA\\f03", "data/F03", "Data\\Sub\\x.bin", "data\\sub\\X.BIN", "Data\\missing", "readme.txt\\x", "Data\\\\f03", ""]:
			var a := ObjectLoader._find_file(g, q)
			var b := ObjectLoader.find_file(n, q)
			_check(_same(a, b), "find '%s' agrees (%s)" % [q, "found " + a.name if a != null else "null"])
		var x := ObjectLoader.find_file(n, "Data\\Sub\\x.bin")
		_check(x != null and n.read_file(x) == body and g.read_file(x) == body, "x.bin's bytes agree both ways")
		# Concurrent reads and lookups from worker threads through one native handle.
		var tally := {"wrong": 0, "runs": 0}
		var lock := Mutex.new()
		var tasks: Array[int] = []
		for _t in range(8):
			tasks.append(WorkerThreadPool.add_task(func():
				for _k in range(200):
					var e := ObjectLoader.find_file(n, "data\\SUB\\x.bin")
					var ok := e != null and n.read_file(e) == body
					lock.lock()
					tally["runs"] += 1
					if not ok:
						tally["wrong"] += 1
					lock.unlock(), true, "native concurrent"))
		for id in tasks:
			WorkerThreadPool.wait_for_task_completion(id)
		_check(int(tally["runs"]) == 1600 and int(tally["wrong"]) == 0,
			"1600 concurrent native lookups+reads from 8 tasks all return the bytes (%d wrong)" % int(tally["wrong"]))

		# Textures: each per-pixel branch, both ways.
		var bgra := PackedByteArray([0x10, 0x20, 0x30, 0x40, 0xff, 0x00, 0x80, 0x01, 1, 2, 3, 4, 250, 251, 252, 253])
		var argb1555 := PackedByteArray([0xff, 0xff, 0x00, 0x7c, 0x21, 0x04, 0x10, 0x80])
		var halfs := PackedByteArray()
		for hv in [0x0000, 0x3c00, 0x3800, 0xc000, 0x7bff, 0x7e00, 0x7c00, 0x3400]:
			halfs.append(hv & 0xff)
			halfs.append(hv >> 8)
		var cases := [
			["32-bit BGRA", _ddj("", 32, [0x00FF0000, 0x0000FF00, 0xFF, 0xFF000000], 2, 2, bgra)],
			["16-bit ARGB1555", _ddj("", 16, [0x7C00, 0x03E0, 0x001F, 0x8000], 2, 2, argb1555)],
			["24-bit, no masks recorded", _ddj("", 0, [0, 0, 0, 0], 1, 1, PackedByteArray([1, 2, 3]))],
			["A16B16G16R16F", _ddj("q", 0, [0, 0, 0, 0], 2, 1, halfs)],
		]
		for c in cases:
			var tex: DdjReader.ParsedTexture = c[1]
			NativeAssets.force_gdscript = true
			var ig := DdjReader.to_image(tex)
			NativeAssets.force_gdscript = false
			var inn := DdjReader.to_image(tex)
			_check(ig != null and inn != null and ig.get_data() == inn.get_data() and ig.get_format() == inn.get_format(),
				"%s decodes to the same RGBA both ways (%s / %s)" % [c[0],
					str(ig.get_data()) if ig != null else "null", str(inn.get_data()) if inn != null else "null"])
		var short := _ddj("", 32, [0x00FF0000, 0x0000FF00, 0xFF, 0xFF000000], 4, 4, bgra)
		_check(DdjReader.to_image(short) == null, "a short payload is refused on the native path too (the GDScript error reports it)")
	g.close()
	n.close()
	DirAccess.remove_absolute(path)

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
