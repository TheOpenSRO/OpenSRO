extends RefCounted

## Writes synthetic archives for the round 789 tests (pk3_reader_test.gd,
## asset_archives_test.gd): zips -- stored, deflated, zip64, with any name,
## and with lies about their sizes and checksums -- and small unencrypted
## pk2s. Nothing here is game data (docs/LEGAL.md): every byte is made up at
## test time, in user://.

## One zip entry. `name` as written; `data` the uncompressed bytes.
static func item(name: String, data: PackedByteArray, deflate: bool = false) -> Dictionary:
	return {"name": name.to_utf8_buffer(), "data": data, "deflate": deflate, "flags": 0,
		"declared_size": -1, "crc": -1, "method": -1, "unix_mode": -1, "copies": 0}

static var _crc_table := PackedInt64Array()

static func crc32(data: PackedByteArray) -> int:
	if _crc_table.is_empty():
		_crc_table.resize(256)
		for i in range(256):
			var c := i
			for _k in range(8):
				c = (0xEDB88320 ^ (c >> 1)) if c & 1 else (c >> 1)
			_crc_table[i] = c
	var c := 0xFFFFFFFF
	for b in data:
		c = _crc_table[(c ^ b) & 0xFF] ^ (c >> 8)
	return c ^ 0xFFFFFFFF

## Raw deflate (no zlib wrapper) of data, from Godot's own zlib.
static func raw_deflate(data: PackedByteArray) -> PackedByteArray:
	if data.is_empty():
		return PackedByteArray([0x03, 0x00])
	var z := data.compress(FileAccess.COMPRESSION_DEFLATE)
	return z.slice(2, z.size() - 4)

static func _u16(b: PackedByteArray, v: int) -> void:
	b.append(v & 0xFF)
	b.append((v >> 8) & 0xFF)

static func _u32(b: PackedByteArray, v: int) -> void:
	for i in range(4):
		b.append((v >> (8 * i)) & 0xFF)

static func _u64(b: PackedByteArray, v: int) -> void:
	for i in range(8):
		b.append((v >> (8 * i)) & 0xFF)

## The zip's bytes; with zip64, every size and offset goes through the zip64
## extra field and the zip64 end records (core::pk3::synth::build, the same).
## An item's `unix_mode` marks it made on Unix with that st_mode (0o120777 = 0xA1FF, a
## symlink); `copies` adds that many more central records over its data,
## named "<name>.<i>" (the overlapping "better zip bomb").
static func zip_bytes(items: Array, zip64: bool = false) -> PackedByteArray:
	var out := PackedByteArray()
	var central := PackedByteArray()
	var n := 0
	for it in items:
		var data: PackedByteArray = it["data"]
		var body := raw_deflate(data) if it["deflate"] else data
		var method: int = it["method"] if it["method"] >= 0 else (8 if it["deflate"] else 0)
		var crc: int = it["crc"] if it["crc"] >= 0 else crc32(data)
		var size: int = it["declared_size"] if it["declared_size"] >= 0 else data.size()
		var csize := body.size()
		var local := out.size()
		var name: PackedByteArray = it["name"]
		var x64 := PackedByteArray()
		if zip64:
			_u16(x64, 1)
			_u16(x64, 24)
			_u64(x64, size)
			_u64(x64, csize)
			_u64(x64, local)
		_u32(out, 0x04034b50)
		_u16(out, 45 if zip64 else 20)
		_u16(out, it["flags"])
		_u16(out, method)
		_u32(out, 0)
		_u32(out, crc)
		_u32(out, 0xFFFFFFFF if zip64 else csize)
		_u32(out, 0xFFFFFFFF if zip64 else size)
		_u16(out, name.size())
		_u16(out, 20 if zip64 else 0)
		out.append_array(name)
		if zip64:
			_u16(out, 1)
			_u16(out, 16)
			_u64(out, size)
			_u64(out, csize)
		out.append_array(body)
		for c in range(int(it["copies"]) + 1):
			var cname := name.duplicate()
			if c > 0:
				cname.append_array((".%d" % c).to_utf8_buffer())
			var mode: int = it["unix_mode"]
			_u32(central, 0x02014b50)
			_u16(central, (3 << 8 | 20) if mode >= 0 else (45 if zip64 else 20))
			_u16(central, 45 if zip64 else 20)
			_u16(central, it["flags"])
			_u16(central, method)
			_u32(central, 0)
			_u32(central, crc)
			_u32(central, 0xFFFFFFFF if zip64 else csize)
			_u32(central, 0xFFFFFFFF if zip64 else size)
			_u16(central, cname.size())
			_u16(central, x64.size())
			_u16(central, 0)
			_u16(central, 0)
			_u16(central, 0)
			_u32(central, (mode << 16) if mode >= 0 else 0)
			_u32(central, 0xFFFFFFFF if zip64 else local)
			central.append_array(cname)
			central.append_array(x64)
			n += 1
	var cd_off := out.size()
	var cd_size := central.size()
	out.append_array(central)
	if zip64:
		var rec := out.size()
		_u32(out, 0x06064b50)
		_u64(out, 44)
		_u16(out, 45)
		_u16(out, 45)
		_u32(out, 0)
		_u32(out, 0)
		_u64(out, n)
		_u64(out, n)
		_u64(out, cd_size)
		_u64(out, cd_off)
		_u32(out, 0x07064b50)
		_u32(out, 0)
		_u64(out, rec)
		_u32(out, 1)
	_u32(out, 0x06054b50)
	_u16(out, 0)
	_u16(out, 0)
	_u16(out, 0xFFFF if zip64 else n)
	_u16(out, 0xFFFF if zip64 else n)
	_u32(out, 0xFFFFFFFF if zip64 else cd_size)
	_u32(out, 0xFFFFFFFF if zip64 else cd_off)
	_u16(out, 0)
	return out

static func write(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()

static func write_zip(path: String, items: Array, zip64: bool = false) -> void:
	write(path, zip_bytes(items, zip64))

## An unencrypted pk2 holding `files` ({"a/b/c.txt": bytes}): one 20-slot
## block per folder (a "." entry and at most 19 children -- enough here),
## files' bytes after the blocks. The layout is docs/protocol/PK2_FORMAT.md's.
static func pk2_bytes(files: Dictionary) -> PackedByteArray:
	# The tree: folder path -> [[name, is_dir, child path or file path]].
	var tree := {"": []}
	for p in files:
		var segs: PackedStringArray = str(p).split("/")
		var parent := ""
		for i in range(segs.size()):
			var child := segs[i] if parent == "" else parent + "/" + segs[i]
			var is_dir := i < segs.size() - 1
			var listed := false
			for e in tree[parent]:
				if e[0] == segs[i]:
					listed = true
			if not listed:
				tree[parent].append([segs[i], is_dir, child])
			if is_dir and not tree.has(child):
				tree[child] = []
			parent = child
	var dirs: Array = tree.keys()
	var block_at := {}
	for i in range(dirs.size()):
		block_at[dirs[i]] = Pk2Reader.HEADER_SIZE + i * Pk2Reader.BLOCK_SIZE
	var data_at := Pk2Reader.HEADER_SIZE + dirs.size() * Pk2Reader.BLOCK_SIZE
	var file_at := {}
	var payload := PackedByteArray()
	for p in files:
		file_at[p] = data_at + payload.size()
		payload.append_array(files[p])
	var out := PackedByteArray()
	out.resize(Pk2Reader.HEADER_SIZE)
	var magic := "JoyMax File Manager!".to_ascii_buffer()
	for i in range(magic.size()):
		out[i] = magic[i]
	for d in dirs:
		var block := PackedByteArray()
		block.resize(Pk2Reader.BLOCK_SIZE)
		_pk2_entry(block, 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", block_at[d], 0)
		var slot := 1
		for e in tree[d]:
			if e[1]:
				_pk2_entry(block, slot, Pk2Reader.ENTRY_TYPE_FOLDER, e[0], block_at[e[2]], 0)
			else:
				_pk2_entry(block, slot, Pk2Reader.ENTRY_TYPE_FILE, e[0], file_at[e[2]], (files[e[2]] as PackedByteArray).size())
			slot += 1
		out.append_array(block)
	out.append_array(payload)
	return out

static func _pk2_entry(block: PackedByteArray, i: int, kind: int, name: String, offset: int, size: int) -> void:
	var base := i * Pk2Reader.ENTRY_SIZE
	block[base] = kind
	var nb := name.to_ascii_buffer()
	for j in range(nb.size()):
		block[base + Pk2Reader.ENTRY_OFF_NAME + j] = nb[j]
	block.encode_u32(base + Pk2Reader.ENTRY_OFF_POSITION, offset)
	block.encode_u32(base + Pk2Reader.ENTRY_OFF_SIZE, size)

static func write_pk2(path: String, files: Dictionary) -> void:
	write(path, pk2_bytes(files))

static func text(s: String) -> PackedByteArray:
	return s.to_utf8_buffer()
