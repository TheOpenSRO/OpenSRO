extends Pk2Reader
class_name Pk3Reader

## Read-only reader for a `.pk3` asset pack (round 789). Everything about
## packs is OURS: retail has only `.pk2`. A `.pk3` is a plain zip archive
## (`.zip` is accepted too) whose paths are the pk2's own paths, matched
## case-insensitively with `/` and `\` alike (docs/TODO.md, "Asset packs").
## The zip layout is PKWARE's public APPNOTE.TXT.
##
## It is a Pk2Reader to every caller -- find_entry, read_dir, read_dir_at,
## read_file -- so a converted Data.pk3 drops in for Data.pk2 and a pack sits
## in an AssetArchives view as one more layer. An Entry's `_offset` is an id
## here, not a file offset: a file's index in the central directory, or a
## folder's (the root's is 0).
##
## The native half (SrNativePk3, native/src/core/pk3.rs) does the work when
## the library is loaded; this GDScript reader is the fallback and the
## reference the native one is held to (pk3_reader_test.gd compares them).
## Both parse the central directory once (zip64 included), read a stored
## entry straight from the file, inflate a deflated one into a buffer of
## exactly its declared size and check its CRC-32. Here the inflate is
## Godot's own zlib: the raw deflate data is wrapped as a gzip member whose
## trailer is the central directory's CRC-32 and size, so
## PackedByteArray.decompress(size, COMPRESSION_GZIP) inflates AND checks it.
##
## Safety (OURS): an entry is refused -- left out of the index, counted and
## named in `refused` -- when its name could escape the archive (`..` or `.`
## segments, an absolute path, a drive letter or any `:`, a NUL, an empty
## segment), when it is encrypted or neither stored nor deflated, when it is
## a symbolic link (a Unix-made entry's mode), when it declares more than
## MAX_ENTRY_BYTES, when it declares more than MAX_RATIO times its packed size
## (over 64 bytes), or when its data would lie past the end of the file. A
## pack whose entries together declare more than MAX_RATIO times the file's
## size is not opened at all (many records over one stream: the "better zip
## bomb"). Of two entries with one name (case ignored) the first is kept, as
## the pk2 index keeps the first; a file whose name is also a folder's is
## refused. These are docs/protocol/asset_packs.md's rules ("Safety"), which
## the Go reader (server/internal/assetfs) and core::pk3 follow too.

## The largest entry a pack may hold, uncompressed (OURS): 256 MiB, twelve
## times the largest file in the retail archives (MEASURED 2026-10-16:
## Data.pk2's navmesh\ainavdata_32773.dat, 21,352,219 bytes).
const MAX_ENTRY_BYTES := 256 << 20
## The ratio cap, unpacked to packed, per entry (over RATIO_MIN_SIZE bytes)
## and per pack (every entry against the file's size): 1100:1
## (asset_packs.md). Deflate cannot beat about 1032:1, and retail itself
## reaches 974.6:1 (MEASURED by lane G).
const MAX_RATIO := 1100
const RATIO_MIN_SIZE := 64
## Bounds on the central directory (OURS); the largest retail archive holds
## 73,139 files (Data.pk2, MEASURED).
const MAX_ENTRIES := 4000000
const MAX_CD_BYTES := 1 << 30
const REFUSED_KEPT := 64

const SIG_LOCAL := 0x04034b50
const SIG_CENTRAL := 0x02014b50
const SIG_EOCD := 0x06054b50
const SIG_EOCD64 := 0x06064b50
const SIG_LOCATOR64 := 0x07064b50
const EOCD_LEN := 22
const CENTRAL_LEN := 46
const LOCAL_LEN := 30
const FLAG_ENCRYPTED := 0x0001
const FLAG_UTF8 := 0x0800
const METHOD_STORED := 0
const METHOD_DEFLATE := 8

## True when the archive needed its zip64 records.
var zip64 := false
## "name: why" for the first REFUSED_KEPT refusals, in directory order.
var refused := PackedStringArray()
var refused_count := 0

var _nat3: Object = null
var _len := 0
# The GDScript index (empty when native): per file, per folder.
var _f_name := PackedStringArray()
var _f_path := PackedStringArray()
var _f_method := PackedInt32Array()
var _f_crc := PackedInt64Array()
var _f_csize := PackedInt64Array()
var _f_size := PackedInt64Array()
var _f_local := PackedInt64Array()
var _d_name := PackedStringArray()
## Per folder, its children as codes: id * 2, plus 1 for a folder.
var _d_children: Array = []
## Lower-cased `/` path ("" the root) -> code.
var _index := {}

## A pack by its name: `.pk3` or `.zip`, case ignored.
static func is_zip_name(path: String) -> bool:
	var ext := path.get_extension().to_lower()
	return ext == "pk3" or ext == "zip"

## A zip's first four bytes: a local header, or the end record of an empty one.
static func has_zip_magic(head: PackedByteArray) -> bool:
	if head.size() < 4 or head[0] != 0x50 or head[1] != 0x4b:
		return false
	return (head[2] == 3 and head[3] == 4) or (head[2] == 5 and head[3] == 6)

## Opens path. Returns null (and pushes an error) when it is not a usable zip.
static func open_zip(path: String) -> Pk3Reader:
	var r := Pk3Reader.new()
	r.source_path = path
	var nat: Object = NativeAssets.new_pk3()
	if nat != null:
		if nat.call("open", ProjectSettings.globalize_path(path)):
			r._nat3 = nat
			r.zip64 = bool(nat.call("is_zip64"))
			r.refused = nat.call("refused")
			r.refused_count = int(nat.call("refused_count"))
			return r
		printerr("pk3: native open of %s failed (%s) -- reading it in GDScript" % [path, nat.call("last_error")])
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("pk3: could not open %s: %s" % [path, FileAccess.get_open_error()])
		return null
	r._file = f
	r._len = f.get_length()
	var err := r._parse()
	if err != "":
		push_error("pk3: %s: %s" % [path, err])
		f.close()
		return null
	return r

func is_native() -> bool:
	return _nat3 != null

func close() -> void:
	_nat3 = null
	_lock.lock()
	if _file != null:
		_file.close()
	_lock.unlock()

## Files in the pack (refused ones not counted).
func file_count() -> int:
	return int(_nat3.call("file_count")) if _nat3 != null else _f_path.size()

func find_entry(path: String) -> Pk2Reader.Entry:
	if _nat3 != null:
		var d: Dictionary = _nat3.call("find", path)
		if d.is_empty():
			return null
		return _make(d["name"], int(d["kind"]) == ENTRY_TYPE_FOLDER, int(d["offset"]), int(d["size"]))
	var key := Pk2Reader.clean_path(path).to_lower()
	if key == "":
		return null
	var code: int = _index.get(key, -1)
	if code < 0:
		return null
	return _entry_of(code)

func find_native(path: String) -> Pk2Reader.Entry:
	return find_entry(path)

func walk_find(path: String) -> Pk2Reader.Entry:
	return find_entry(path)

func read_dir() -> Array[Pk2Reader.Entry]:
	return _list(0)

func read_dir_at(dir: Pk2Reader.Entry) -> Array[Pk2Reader.Entry]:
	if not dir.is_dir:
		push_error("pk3: %s is not a folder" % dir.name)
		return []
	return _list(dir._offset)

## Every file's path with `/`, as written, in directory order.
func file_paths() -> PackedStringArray:
	if _nat3 != null:
		return _nat3.call("paths")
	return _f_path

func read_file(file: Pk2Reader.Entry) -> PackedByteArray:
	if file.is_dir:
		push_error("pk3: %s is a folder, not a file" % file.name)
		return PackedByteArray()
	var pp := ParseProfile.t0()
	var bytes := PackedByteArray()
	if _nat3 != null:
		var d: Dictionary = _nat3.call("read", file._offset)
		if d.has("error"):
			push_error(str(d["error"]))
		else:
			bytes = d["bytes"]
	else:
		var r: Variant = _read_gd(file._offset)
		if r is String:
			push_error(r)
		else:
			bytes = r
	ParseProfile.add("pk3.read_file", pp, bytes.size())
	return bytes

func _make(name: String, is_dir: bool, id: int, size: int) -> Pk2Reader.Entry:
	var e := Pk2Reader.Entry.new()
	e.name = name
	e.is_dir = is_dir
	e._offset = id
	e.size = size
	e._layer = layer_id
	return e

func _entry_of(code: int) -> Pk2Reader.Entry:
	var id := code >> 1
	if code & 1:
		return _make(_d_name[id], true, id, 0)
	return _make(_f_name[id], false, id, _f_size[id])

## A folder's entries, made once and cached as Pk2Reader caches a directory.
func _list(id: int) -> Array[Pk2Reader.Entry]:
	_lock.lock()
	if _dir_cache.has(id):
		var hit: Array[Pk2Reader.Entry] = _dir_cache[id]
		_lock.unlock()
		return hit
	_lock.unlock()
	var out: Array[Pk2Reader.Entry] = []
	if _nat3 != null:
		var d: Dictionary = _nat3.call("list_dir", id)
		var names: PackedStringArray = d.get("names", PackedStringArray())
		var kinds: PackedInt64Array = d.get("kinds", PackedInt64Array())
		var ids: PackedInt64Array = d.get("offsets", PackedInt64Array())
		var sizes: PackedInt64Array = d.get("sizes", PackedInt64Array())
		for i in range(names.size()):
			out.append(_make(names[i], kinds[i] == ENTRY_TYPE_FOLDER, ids[i], sizes[i]))
	elif id >= 0 and id < _d_children.size():
		for code in _d_children[id]:
			out.append(_entry_of(code))
	_lock.lock()
	if not _dir_cache.has(id):
		_dir_cache[id] = out
	out = _dir_cache[id]
	_lock.unlock()
	return out

## A pack path made plain: [path with `/`, is_folder], or [why] when the
## name could escape the archive (core::pk3::safe_path, rule for rule).
static func safe_path(name: String) -> Array:
	if name == "":
		return ["empty name"]
	var p := name.replace("\\", "/")
	if p.begins_with("/"):
		return ["absolute path"]
	if p.contains(":"):
		return ["drive letter or ':' in the name"]
	var is_dir := p.ends_with("/")
	var body := p.substr(0, p.length() - 1) if is_dir else p
	if body == "":
		return ["empty name"]
	for seg in body.split("/"):
		if seg == "":
			return ["empty path segment"]
		if seg == "." or seg == "..":
			return ["'.' or '..' segment"]
	return [body, is_dir]

func _refuse(name: String, why: String) -> void:
	refused_count += 1
	if refused.size() < REFUSED_KEPT:
		refused.append("%s: %s" % [name, why])

## Reads the central directory into the index; "" or why it failed.
func _parse() -> String:
	if _len < EOCD_LEN:
		return "too small to be a zip archive"
	var tail_len := mini(_len, EOCD_LEN + 0xFFFF)
	var tail_off := _len - tail_len
	_file.seek(tail_off)
	var tail := _file.get_buffer(tail_len)
	var e := -1
	var i := tail_len - EOCD_LEN
	while i >= 0:
		if tail.decode_u32(i) == SIG_EOCD and i + EOCD_LEN + tail.decode_u16(i + 20) <= tail_len:
			e = i
			break
		i -= 1
	if e < 0:
		return "not a zip archive (no end of central directory record)"
	var eocd_abs := tail_off + e
	var disk := tail.decode_u16(e + 4)
	var cd_disk := tail.decode_u16(e + 6)
	var total := tail.decode_u16(e + 10)
	var cd_size := tail.decode_u32(e + 12)
	var cd_off := tail.decode_u32(e + 16)
	if eocd_abs >= 20:
		_file.seek(eocd_abs - 20)
		var loc := _file.get_buffer(20)
		if loc.size() == 20 and loc.decode_u32(0) == SIG_LOCATOR64:
			var rec_off := loc.decode_u64(8)
			if rec_off < 0 or rec_off + 56 > eocd_abs:
				return "zip64 end record lies outside the file"
			_file.seek(rec_off)
			var rec := _file.get_buffer(56)
			if rec.size() < 56 or rec.decode_u32(0) != SIG_EOCD64:
				return "zip64 locator points at no zip64 end record"
			zip64 = true
			disk = rec.decode_u32(16)
			cd_disk = rec.decode_u32(20)
			total = rec.decode_u64(32)
			cd_size = rec.decode_u64(40)
			cd_off = rec.decode_u64(48)
	if disk != 0 or cd_disk != 0:
		return "split (multi-disk) archives are not supported"
	if total < 0 or total > MAX_ENTRIES or cd_size < 0 or cd_size > MAX_CD_BYTES:
		return "central directory too large (%d entries, %d bytes)" % [total, cd_size]
	if cd_off < 0 or cd_off + cd_size > eocd_abs:
		return "central directory lies outside the file"
	_file.seek(cd_off)
	var cd := _file.get_buffer(cd_size)
	if cd.size() != cd_size:
		return "central directory is truncated"
	_d_name.append("")
	_d_children.append([])
	_index[""] = 1
	var p := 0
	var records: Array = []
	var declared := 0
	for _n in range(total):
		if p + CENTRAL_LEN > cd.size() or cd.decode_u32(p) != SIG_CENTRAL:
			return "central directory is truncated or corrupt"
		var made_by := cd.decode_u16(p + 4)
		var flags := cd.decode_u16(p + 8)
		var method := cd.decode_u16(p + 10)
		var crc := cd.decode_u32(p + 16)
		var csize := cd.decode_u32(p + 20)
		var size := cd.decode_u32(p + 24)
		var nlen := cd.decode_u16(p + 28)
		var xlen := cd.decode_u16(p + 30)
		var clen := cd.decode_u16(p + 32)
		var ext_attr := cd.decode_u32(p + 38)
		var local := cd.decode_u32(p + 42)
		var rec_end := p + CENTRAL_LEN + nlen + xlen + clen
		if rec_end > cd.size():
			return "central directory is truncated or corrupt"
		var raw_name := cd.slice(p + CENTRAL_LEN, p + CENTRAL_LEN + nlen)
		var x := p + CENTRAL_LEN + nlen
		var x_end := x + xlen
		while x + 4 <= x_end:
			var id := cd.decode_u16(x)
			var sz := cd.decode_u16(x + 2)
			if id == 0x0001:
				var q := x + 4
				var body_end := mini(x + 4 + sz, x_end)
				if size == 0xFFFFFFFF and q + 8 <= body_end:
					size = cd.decode_u64(q)
					q += 8
				if csize == 0xFFFFFFFF and q + 8 <= body_end:
					csize = cd.decode_u64(q)
					q += 8
				if local == 0xFFFFFFFF and q + 8 <= body_end:
					local = cd.decode_u64(q)
					q += 8
			x += 4 + sz
		# A Unix-made entry (version made by's high byte 3) keeps st_mode in the
		# external attributes' high 16 bits; S_IFLNK is 0o120000 (0xA000).
		var symlink := (made_by >> 8) == 3 and ((ext_attr >> 16) & 0xF000) == 0xA000
		declared = declared + size if size >= 0 and declared < (1 << 62) else (1 << 62)
		records.append([raw_name, flags, method, crc, csize, size, local, symlink])
		p = rec_end
	if declared > MAX_RATIO * _len:
		return "its entries unpack to %d bytes from a %d-byte file (over %d:1): a zip bomb" % [declared, _len, MAX_RATIO]
	for r in records:
		var raw_name: PackedByteArray = r[0]
		var flags: int = r[1]
		if raw_name.find(0) >= 0:
			_refuse(raw_name.get_string_from_ascii(), "NUL in the name")
			continue
		# UTF-8 when the entry says so, else one Latin-1 code point a byte: the
		# pk2 reader's own decoding (get_string_from_ascii).
		var name := raw_name.get_string_from_utf8() if flags & FLAG_UTF8 else raw_name.get_string_from_ascii()
		_add(name, flags, r[2], r[3], r[4], r[5], r[6], r[7])
	return ""

## The folder for segs, made (with its parents) when missing; -1 when a file
## holds a name on the way.
func _ensure_dir(segs: PackedStringArray) -> int:
	var cur := 0
	var key := ""
	for seg in segs:
		if key != "":
			key += "/"
		key += seg.to_lower()
		var code: int = _index.get(key, -1)
		if code >= 0:
			if code & 1 == 0:
				return -1
			cur = code >> 1
		else:
			var id := _d_name.size()
			_d_name.append(seg)
			_d_children.append([])
			(_d_children[cur] as Array).append(id * 2 + 1)
			_index[key] = id * 2 + 1
			cur = id
	return cur

func _add(name: String, flags: int, method: int, crc: int, csize: int, size: int, local: int, symlink: bool) -> void:
	var sp := safe_path(name)
	if sp.size() == 1:
		_refuse(name, sp[0])
		return
	var path: String = sp[0]
	var segs := path.split("/")
	if sp[1]:
		if _ensure_dir(segs) < 0:
			_refuse(name, "a folder on its path is a file")
		return
	var why := ""
	if flags & FLAG_ENCRYPTED:
		why = "encrypted"
	elif method != METHOD_STORED and method != METHOD_DEFLATE:
		why = "compression method is neither stored nor deflate"
	elif symlink:
		why = "a symbolic link"
	elif size < 0 or size > MAX_ENTRY_BYTES:
		why = "larger than the 256 MiB entry cap"
	elif method == METHOD_STORED and csize != size:
		why = "stored entry whose sizes differ"
	elif size > RATIO_MIN_SIZE and (csize < 0 or size > csize * MAX_RATIO):
		why = "unpacks to more than 1100 times its packed size: a zip bomb"
	elif local < 0 or csize < 0 or local + LOCAL_LEN + csize > _len:
		why = "its data lies past the end of the file"
	if why != "":
		_refuse(name, why)
		return
	var key := path.to_lower()
	var have: int = _index.get(key, -1)
	if have >= 0:
		_refuse(name, "the same name is a folder" if have & 1 else "duplicate name (the first is kept)")
		return
	var parent_segs := segs.slice(0, segs.size() - 1)
	var parent := _ensure_dir(parent_segs)
	if parent < 0:
		_refuse(name, "a folder on its path is a file")
		return
	var id := _f_path.size()
	_f_name.append(segs[segs.size() - 1])
	_f_path.append(path)
	_f_method.append(method)
	_f_crc.append(crc)
	_f_csize.append(csize)
	_f_size.append(size)
	_f_local.append(local)
	(_d_children[parent] as Array).append(id * 2)
	_index[key] = id * 2

## A file's bytes, or why not (a String).
func _read_gd(id: int) -> Variant:
	if id < 0 or id >= _f_path.size():
		return "pk3: no entry %d" % id
	var path := _f_path[id]
	var local := _f_local[id]
	var csize := _f_csize[id]
	var size := _f_size[id]
	_lock.lock()
	_file.seek(local)
	var lh := _file.get_buffer(LOCAL_LEN)
	if lh.size() != LOCAL_LEN or lh.decode_u32(0) != SIG_LOCAL:
		_lock.unlock()
		return "pk3: %s: no local header at %d" % [path, local]
	var data := local + LOCAL_LEN + lh.decode_u16(26) + lh.decode_u16(28)
	if data + csize > _len:
		_lock.unlock()
		return "pk3: %s: data lies past the end of the file" % path
	if size == 0:
		_lock.unlock()
		return PackedByteArray()
	_file.seek(data)
	var comp := _file.get_buffer(csize)
	_lock.unlock()
	if comp.size() != csize:
		return "pk3: %s: truncated" % path
	if _f_method[id] == METHOD_STORED:
		return comp
	# A gzip member around the raw deflate data: a 10-byte header (no name,
	# no time), then the trailer zlib checks -- CRC-32 and size, little-endian.
	var gz := PackedByteArray([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
	gz.append_array(comp)
	var trailer := PackedByteArray()
	trailer.resize(8)
	trailer.encode_u32(0, _f_crc[id])
	trailer.encode_u32(4, size & 0xFFFFFFFF)
	gz.append_array(trailer)
	var out := gz.decompress(size, FileAccess.COMPRESSION_GZIP)
	if out.size() != size:
		return "pk3: %s: inflate failed -- larger than its declared %d bytes, corrupt, or its CRC-32 does not match" % [path, size]
	return out
