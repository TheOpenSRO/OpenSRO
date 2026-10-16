extends SceneTree

## Exercises Pk3Reader (round 789) against synthetic zips written here, in
## user:// (never real game data), run headless:
## `godot --headless --path client --script res://scripts/pk2/pk3_reader_test.gd`
## Every case runs on the GDScript reader; with the native library loaded it
## runs again on SrNativePk3, and the two are compared answer for answer
## (the parity check).

const Z := preload("res://scripts/pk2/pk3_test_archives.gd")
const DIR := "user://pk3_reader_test"

var _failures := 0
var _mode := ""

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  [%s] %s" % [_mode, msg])
	else:
		print("FAIL [%s] %s" % [_mode, msg])
		_failures += 1

func _filler(n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	var src := "OpenSRO pack test ".to_ascii_buffer()
	for i in range(n):
		b[i] = src[i % src.size()]
	return b

func _sample() -> Array:
	return [
		Z.item("Prim/Mtrl/Foo.DDJ", _filler(5000)),
		Z.item("prim\\mtrl\\bar.txt", _filler(7000), true),
		Z.item("textdata/", PackedByteArray()),
		Z.item("textdata/a.txt", PackedByteArray(), true),
		Z.item("readme.txt", Z.text("hello")),
	]

func _open(path: String) -> Pk3Reader:
	var r := Pk2Reader.open(path)
	return r as Pk3Reader

func _names(list: Array) -> Array:
	var out := []
	for e in list:
		out.append(e.name)
	return out

func _test_reads(zip64: bool) -> void:
	var path := DIR + "/sample%s.pk3" % ("64" if zip64 else "")
	Z.write_zip(path, _sample(), zip64)
	var r := _open(path)
	_check(r != null, "opens (zip64 %s)" % zip64)
	if r == null:
		return
	_check(r.zip64 == zip64, "zip64 flag is %s" % zip64)
	_check(r.refused_count == 0, "nothing refused (%s)" % ", ".join(r.refused))
	_check(r.is_native() == (_mode == "native"), "the reader is the %s one" % _mode)
	var foo := ObjectLoader.find_file(r, "prim\\MTRL\\foo.ddj")
	_check(foo != null and foo.name == "Foo.DDJ" and not foo.is_dir and foo.size == 5000, "case and \\ ignored, the name as written")
	_check(foo != null and r.read_file(foo) == _filler(5000), "a stored entry reads back")
	var bar := ObjectLoader.find_file(r, "PRIM/mtrl/BAR.TXT")
	_check(bar != null and r.read_file(bar) == _filler(7000), "a deflated entry inflates back")
	var empty := ObjectLoader.find_file(r, "textdata\\a.txt")
	_check(empty != null and r.read_file(empty).is_empty(), "an empty deflated entry reads empty")
	var mtrl := ObjectLoader.find_file(r, "prim/mtrl")
	_check(mtrl != null and mtrl.is_dir, "a folder is found")
	_check(mtrl != null and _names(r.read_dir_at(mtrl)) == ["Foo.DDJ", "bar.txt"], "a folder lists its files in directory order")
	_check(_names(r.read_dir()) == ["Prim", "textdata", "readme.txt"], "the root lists folders first named, in order")
	_check(ObjectLoader.find_file(r, "") == null, "the empty path is nothing")
	var dbl := ObjectLoader.find_file(r, "/prim//mtrl\\")
	_check(dbl != null and dbl.is_dir, "empty segments are skipped (asset_packs.md rule 4)")
	_check(ObjectLoader.find_file(r, "prim/../readme.txt") == null and ObjectLoader.find_file(r, "prim/./mtrl") == null
		and ObjectLoader.find_file(r, "c:readme.txt") == null, "an unsafe lookup finds nothing")
	_check(ObjectLoader.find_file(r, "missing.txt") == null, "a missing path is null")
	_check(Array(r.file_paths()) == ["Prim/Mtrl/Foo.DDJ", "prim/mtrl/bar.txt", "textdata/a.txt", "readme.txt"], "file_paths in order, as written")
	_check(AssetSource.read_bytes("readme.txt", r) == Z.text("hello"), "AssetSource.read_bytes reads through it")

func _test_unsafe() -> void:
	var items := []
	for n in ["../evil.txt", "a/../../b.txt", "/etc/passwd", "\\abs.txt", "C:/win.ini", "c:evil", "a//b.txt", "./x.txt", "ok/fine.txt"]:
		items.append(Z.item(n, Z.text("x")))
	var nul := Z.item("x", Z.text("x"))
	nul["name"] = PackedByteArray([0x6e, 0x75, 0x6c, 0x00, 0x2e, 0x74])
	items.append(nul)
	Z.write_zip(DIR + "/unsafe.zip", items)
	var r := _open(DIR + "/unsafe.zip")
	_check(r != null and r.refused_count == 9, "nine names that escape are refused (%s)" % (", ".join(r.refused) if r else "no reader"))
	_check(r != null and Array(r.file_paths()) == ["ok/fine.txt"], "only the plain name is kept")
	_check(r != null and ObjectLoader.find_file(r, "../evil.txt") == null, "a refused name is not found")

func _test_bombs() -> void:
	var zeros := PackedByteArray()
	zeros.resize(1 << 20)
	var lie := Z.item("lie.bin", zeros, true)
	lie["declared_size"] = 1024
	var huge := Z.item("huge.bin", Z.text("x"))
	huge["declared_size"] = Pk3Reader.MAX_ENTRY_BYTES + 1
	var ratio := Z.item("ratio.bin", Z.text("abc"), true)
	ratio["declared_size"] = 200 << 20
	var crc := Z.item("crc.bin", _filler(100), true)
	crc["crc"] = 1
	var enc := Z.item("enc.bin", Z.text("x"))
	enc["flags"] = Pk3Reader.FLAG_ENCRYPTED
	var bz := Z.item("bzip2.bin", Z.text("x"))
	bz["method"] = 12
	var ok := Z.item("zeros.bin", zeros, true)
	var link := Z.item("link.txt", Z.text("/etc/passwd"))
	link["unix_mode"] = 0xA1FF # 0o120777, a symlink
	var unix := Z.item("unix.txt", Z.text("a plain file"))
	unix["unix_mode"] = 0x81A4 # 0o100644, a plain file
	# A stored filler keeps the whole pack under its 1100:1 (the bombs above
	# declare 456 MiB between them).
	var filler := Z.item("filler.bin", _filler(512 << 10))
	Z.write_zip(DIR + "/bombs.pk3", [lie, huge, ratio, crc, enc, bz, ok, link, unix, filler])
	var r := _open(DIR + "/bombs.pk3")
	_check(r != null and r.refused_count == 5, "the cap, the ratio, encryption, the method and a symlink refuse five (%s)" % (", ".join(r.refused) if r else "no reader"))
	if r == null:
		return
	_check(ObjectLoader.find_file(r, "link.txt") == null and ObjectLoader.find_file(r, "unix.txt") != null, "a symlink entry is refused, a Unix-made file is not")
	var z := ObjectLoader.find_file(r, "zeros.bin")
	_check(z != null and r.read_file(z) == zeros, "a real 1000:1 file still reads")
	var l := ObjectLoader.find_file(r, "lie.bin")
	_check(l != null and r.read_file(l).is_empty(), "an entry inflating past its declared size gives nothing")
	var c := ObjectLoader.find_file(r, "crc.bin")
	_check(c != null and r.read_file(c).is_empty(), "a CRC-32 mismatch gives nothing")
	for gone in ["huge.bin", "ratio.bin", "enc.bin", "bzip2.bin"]:
		_check(ObjectLoader.find_file(r, gone) == null, "%s is refused" % gone)

## The overlapping "better zip bomb": 1,200 records over one 1 MiB stream --
## every entry under 1100:1, the pack far over it: not opened at all.
func _test_whole_ratio() -> void:
	var zeros := PackedByteArray()
	zeros.resize(1 << 20)
	var many := Z.item("zeros.bin", zeros, true)
	many["copies"] = 1199
	Z.write_zip(DIR + "/overlap.pk3", [many])
	_check(Pk2Reader.open(DIR + "/overlap.pk3") == null, "a pack over 1100:1 in all is not opened")
	var noise := PackedByteArray()
	var x := 12345
	for i in range(65536):
		x = (x * 1103515245 + 12345) & 0xFFFFFFFF
		noise.append((x >> 16) & 0xFF)
	var few := Z.item("noise.bin", noise, true)
	few["copies"] = 3
	Z.write_zip(DIR + "/shared.pk3", [few])
	var r := _open(DIR + "/shared.pk3")
	_check(r != null and r.file_count() == 4 and r.read_file(ObjectLoader.find_file(r, "noise.bin.3")) == noise, "records sharing one stream are not refused by themselves")

func _test_conflicts() -> void:
	Z.write_zip(DIR + "/dups.pk3", [
		Z.item("a/b.txt", Z.text("one")),
		Z.item("A/B.TXT", Z.text("two")),
		Z.item("a", Z.text("file named like a folder")),
		Z.item("a/b.txt/c", Z.text("under a file")),
	])
	var r := _open(DIR + "/dups.pk3")
	_check(r != null and r.refused_count == 3, "a duplicate, a file over a folder and a folder under a file are refused")
	if r != null:
		_check(r.read_file(ObjectLoader.find_file(r, "a/b.txt")) == Z.text("one"), "the first of two spellings is kept")
		_check(ObjectLoader.find_file(r, "a").is_dir, "the folder stands")

func _test_not_zips() -> void:
	Z.write(DIR + "/zeros.pk3", PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
	_check(Pk2Reader.open(DIR + "/zeros.pk3") == null, "a file that is no zip does not open")
	Z.write_zip(DIR + "/empty.zip", [])
	var e := _open(DIR + "/empty.zip")
	_check(e != null and e.read_dir().is_empty(), "an empty zip opens and lists nothing")
	# A zip named .pk2 opens by its magic.
	Z.write_zip(DIR + "/zipped.pk2", [Z.item("x.txt", Z.text("zip under a pk2 name"))])
	var z := Pk2Reader.open(DIR + "/zipped.pk2")
	_check(z is Pk3Reader and z.read_file(ObjectLoader.find_file(z, "x.txt")) == Z.text("zip under a pk2 name"), "a zip's magic opens it as a pack whatever its name")

## A zip written by Godot's own ZIPPacker (minizip): another writer's output.
func _test_zippacker() -> void:
	var path := DIR + "/packer.zip"
	var zp := ZIPPacker.new()
	if zp.open(path) != OK:
		_check(false, "ZIPPacker opens")
		return
	zp.start_file("Sound/Hit.WAV")
	zp.write_file(_filler(3000))
	zp.close_file()
	zp.start_file("readme.txt")
	zp.write_file(Z.text("packed by godot"))
	zp.close_file()
	zp.close()
	var r := _open(path)
	_check(r != null and r.refused_count == 0, "a ZIPPacker zip opens")
	if r != null:
		_check(r.read_file(ObjectLoader.find_file(r, "sound\\hit.wav")) == _filler(3000), "its deflated entry reads")
		_check(r.read_file(ObjectLoader.find_file(r, "README.TXT")) == Z.text("packed by godot"), "and its second entry")

func _read_many(r: Pk3Reader, n: int, tally: Array, lock: Mutex) -> void:
	var bad := 0
	for k in range(200):
		var i := (n * 7 + k) % 40
		var e := ObjectLoader.find_file(r, "D\\F%d.BIN" % i)
		if e == null or r.read_file(e) != _filler(1000 + i * 37):
			bad += 1
	lock.lock()
	tally[0] += bad
	lock.unlock()

func _test_threads() -> void:
	var items := []
	for i in range(40):
		items.append(Z.item("d/f%d.bin" % i, _filler(1000 + i * 37), i % 2 == 0))
	Z.write_zip(DIR + "/threads.pk3", items, true)
	var r := _open(DIR + "/threads.pk3")
	if r == null:
		_check(false, "threads zip opens")
		return
	var tally := [0]
	var lock := Mutex.new()
	var tasks := []
	for n in range(8):
		tasks.append(WorkerThreadPool.add_task(_read_many.bind(r, n, tally, lock)))
	for t in tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	_check(tally[0] == 0, "eight tasks reading one pack at once read every byte right (%d bad)" % tally[0])

## Everything a reader answers about one zip, for the parity check.
func _answers(path: String) -> Dictionary:
	var r := _open(path)
	if r == null:
		return {"open": false}
	var out := {"open": true, "zip64": r.zip64, "refused": r.refused_count, "paths": Array(r.file_paths())}
	var listing := []
	var queue := [r.read_dir()]
	while not queue.is_empty():
		var list: Array = queue.pop_front()
		for e in list:
			listing.append([e.name, e.is_dir, e.size])
			if e.is_dir:
				queue.append(r.read_dir_at(e))
			else:
				listing.append(r.read_file(e).hex_encode().sha256_text() if e.size > 0 else "")
	out["listing"] = listing
	var finds := []
	for q in ["prim\\mtrl\\FOO.ddj", "prim/mtrl", "PRIM", "", "x//y", "//prim//", "prim/../x", "a:b", "link.txt", "readme.txt", "zeros.bin", "lie.bin", "a/b.txt", "a", "missing"]:
		var e := ObjectLoader.find_file(r, q)
		finds.append([] if e == null else [e.name, e.is_dir, e.size])
	out["finds"] = finds
	return out

func _parity() -> void:
	for f in ["sample.pk3", "sample64.pk3", "unsafe.zip", "bombs.pk3", "shared.pk3", "dups.pk3", "empty.zip", "packer.zip", "threads.pk3"]:
		NativeAssets.force_gdscript = true
		var g := _answers(DIR + "/" + f)
		NativeAssets.force_gdscript = false
		var n := _answers(DIR + "/" + f)
		_check(g == n, "parity: %s answers alike in GDScript and natively" % f)
		if g != n:
			print("  GDScript: %s\n  native:   %s" % [str(g).left(600), str(n).left(600)])

func _all() -> void:
	_test_reads(false)
	_test_reads(true)
	_test_unsafe()
	_test_bombs()
	_test_whole_ratio()
	_test_conflicts()
	_test_not_zips()
	_test_zippacker()
	_test_threads()

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	_mode = "gdscript"
	NativeAssets.force_gdscript = true
	_all()
	NativeAssets.force_gdscript = false
	if NativeAssets.available():
		_mode = "native"
		_all()
		_mode = "parity"
		_parity()
	else:
		print("native library not available (%s) -- GDScript only" % NativeAssets.status)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURE(S)" % _failures)
		quit(1)
