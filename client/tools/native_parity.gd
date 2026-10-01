extends SceneTree

## Holds the native (Rust) readers to the GDScript ones on REAL archives,
## byte for byte and value for value (round 667; native/README.md, "Parity").
## Run on the render box, never committed output:
##
##   client/tools/remote_godot.sh script res://tools/native_parity.gd -- --pk2-dir=/opt/sro-files/client
##
## For each archive (Data, Map, Media, Particles): every directory of the
## whole tree read both ways (names, kinds, offsets, sizes); a path lookup
## (ObjectLoader.find_file) both ways for every file in a folder of at most
## FIND_ALL_UNDER entries and every FIND_STRIDE-th one in larger folders,
## plus an upper-cased, a slash-separated and a missing variant of a share
## of them; every READ_STRIDE-th file's bytes both ways; and every .ddj whose
## decode loops over pixels in GDScript (uncompressed, or 'q') decoded both
## ways, RGBA compared byte for byte.
##
## Prints `PARITY <archive> ...` counts, the first FAIL lines of any
## mismatch, and `PARITY PASS` or `PARITY FAIL <n>`. Exits 1 on a FAIL or when
## the library did not load (nothing would have been compared).

const ARCHIVES := ["Data.pk2", "Map.pk2", "Media.pk2", "Particles.pk2"]
const FIND_ALL_UNDER := 300
const FIND_STRIDE := 25
const READ_STRIDE := 7
const READ_MAX_BYTES := 8 * 1024 * 1024
const MAX_FAIL_LINES := 12

var _fails := 0

func _fail(msg: String) -> void:
	_fails += 1
	if _fails <= MAX_FAIL_LINES:
		print("FAIL " + msg)

func _init() -> void:
	var pk2_dir := "/opt/sro-files/client"
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pk2-dir="):
			pk2_dir = a.substr(10)
		elif a.begins_with("--only="):
			only = a.substr(7)
	if not NativeAssets.library_loaded():
		print("PARITY FAIL: the native library did not load -- nothing to compare (is client/native_bin shipped?)")
		quit(1)
		return
	NativeAssets.available()
	var t0 := Time.get_ticks_msec()
	for name in ARCHIVES:
		if only != "" and name != only:
			continue
		_compare_archive(pk2_dir.path_join(name), name)
	print("PARITY took %d s" % ((Time.get_ticks_msec() - t0) / 1000))
	if _fails == 0:
		print("PARITY PASS")
		quit(0)
	else:
		print("PARITY FAIL %d" % _fails)
		quit(1)

func _compare_archive(path: String, label: String) -> void:
	NativeAssets.force_gdscript = true
	var g := Pk2Reader.open(path)
	NativeAssets.force_gdscript = false
	var n := Pk2Reader.open(path)
	if g == null or n == null or not n.is_native() or g.is_native():
		_fail("%s: could not open both ways (gdscript %s, native %s)" % [label, g != null, n != null and n.is_native()])
		return
	var t := Time.get_ticks_msec()
	# The tree, both ways, directory by directory.
	var dirs := 0
	var entries := 0
	var files: Array = [] # [path, Entry (GDScript's), folder size]
	var queue: Array = [["", g._root_offset]]
	var seen := {}
	while not queue.is_empty():
		var item: Array = queue.pop_back()
		var prefix: String = item[0]
		var off: int = item[1]
		if seen.has(off):
			continue
		seen[off] = true
		var ge: Array[Pk2Reader.Entry] = g._read_block_chain(off)
		var ne: Array[Pk2Reader.Entry] = n._read_block_chain(off)
		dirs += 1
		entries += ge.size()
		if ge.size() != ne.size():
			_fail("%s: dir '%s' has %d entries in GDScript, %d native" % [label, prefix, ge.size(), ne.size()])
		for i in range(mini(ge.size(), ne.size())):
			var a := ge[i]
			var b := ne[i]
			if a.name != b.name or a.is_dir != b.is_dir or a._offset != b._offset or a.size != b.size:
				_fail("%s: dir '%s' entry %d: GDScript (%s, dir %s, @%d, %d) native (%s, dir %s, @%d, %d)" % [
					label, prefix, i, a.name, a.is_dir, a._offset, a.size, b.name, b.is_dir, b._offset, b.size])
		for e in ge:
			var p := e.name if prefix == "" else prefix + "\\" + e.name
			if e.is_dir:
				queue.append([p, e._offset])
			else:
				files.append([p, e, ge.size()])
	print("PARITY %s: tree -- %d directories, %d entries compared (%d ms)" % [label, dirs, entries, Time.get_ticks_msec() - t])

	# Path lookups, both ways.
	t = Time.get_ticks_msec()
	var finds := 0
	var variants := 0
	var i := 0
	for f in files:
		i += 1
		var folder_size: int = f[2]
		if folder_size > FIND_ALL_UNDER and i % FIND_STRIDE != 0:
			continue
		var p: String = f[0]
		var tries := [p]
		if i % 10 == 0:
			tries.append(p.to_upper())
			tries.append(p.replace("\\", "/"))
			tries.append(p + "_missing")
			variants += 3
		for q in tries:
			finds += 1
			var a: Pk2Reader.Entry = ObjectLoader._find_file(g, q)
			var b: Pk2Reader.Entry = n.find_native(q)
			if (a == null) != (b == null):
				_fail("%s: find '%s': GDScript %s, native %s" % [label, q, "found" if a != null else "null", "found" if b != null else "null"])
			elif a != null and (a.name != b.name or a.is_dir != b.is_dir or a._offset != b._offset or a.size != b.size):
				_fail("%s: find '%s': GDScript (%s, @%d, %d) native (%s, @%d, %d)" % [label, q, a.name, a._offset, a.size, b.name, b._offset, b.size])
	print("PARITY %s: find -- %d lookups compared (%d of them case/slash/missing variants) (%d ms)" % [label, finds, variants, Time.get_ticks_msec() - t])

	# File bytes, both ways; and every .ddj whose decode loops over pixels.
	t = Time.get_ticks_msec()
	var reads := 0
	var read_bytes := 0
	var ddj_seen := 0
	var ddj_compared := 0
	var ddj_formats := {}
	i = 0
	for f in files:
		i += 1
		var e: Pk2Reader.Entry = f[1]
		var p: String = f[0]
		var is_ddj := p.to_lower().ends_with(".ddj")
		if i % READ_STRIDE != 0 and not is_ddj:
			continue
		if e.size > READ_MAX_BYTES and not is_ddj:
			continue
		var a := g.read_file(e)
		var b := n.read_file(e)
		reads += 1
		read_bytes += a.size()
		if a != b:
			_fail("%s: read '%s': %d bytes GDScript, %d native, contents differ" % [label, p, a.size(), b.size()])
			continue
		if not is_ddj:
			continue
		ddj_seen += 1
		var tex := DdjReader.parse(a)
		if tex == null or not (tex.four_cc == "" or tex.four_cc == "q"):
			continue
		var fmt := tex.four_cc if tex.four_cc != "" else "rgb%d" % tex.rgb_bit_count
		ddj_formats[fmt] = int(ddj_formats.get(fmt, 0)) + 1
		NativeAssets.force_gdscript = true
		var img_g := DdjReader.to_image(tex)
		NativeAssets.force_gdscript = false
		var img_n := DdjReader.to_image(tex)
		ddj_compared += 1
		if (img_g == null) != (img_n == null):
			_fail("%s: ddj '%s': GDScript image %s, native %s" % [label, p, img_g != null, img_n != null])
		elif img_g != null and (img_g.get_width() != img_n.get_width() or img_g.get_height() != img_n.get_height()
				or img_g.get_format() != img_n.get_format() or img_g.get_data() != img_n.get_data()):
			_fail("%s: ddj '%s' (%s %dx%d): decoded pixels differ" % [label, p, fmt, tex.width, tex.height])
	print("PARITY %s: read -- %d files, %d bytes compared; ddj -- %d .ddj read, %d per-pixel decodes compared %s (%d ms)" % [
		label, reads, read_bytes, ddj_seen, ddj_compared, str(ddj_formats), Time.get_ticks_msec() - t])
	g.close()
	n.close()
