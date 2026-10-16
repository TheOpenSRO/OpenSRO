extends SceneTree

## Real-data check for the asset pack reader (round 789): every file of a
## `.pk2` against the same path in its converted `.pk3` (lane G's pk2topk3),
## read by the GDScript Pk3Reader and, when the library is loaded, by the
## native one -- the bytes must be identical, and the two readers must agree
## on every lookup and folder listing. Nothing is written; no game data
## leaves the box.
##
##   godot --headless --path client --script res://tools/pk3_parity.gd -- \
##     --pk2=/opt/sro-files/client/Media.pk2 --pk3=/var/tmp/g789/pk3/Media.pk3 [--every=1]
##
## --every=N checks every Nth file (1: all). Prints timings (open, read) and
## `PK3 PARITY OK <n> files` or `PARITY FAIL ...` lines (remote_godot.sh
## exits 1 on the latter).

func _arg(flag: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return def

func _collect(r: Pk2Reader, out: Array, prefix: String, list: Array) -> void:
	for e in list:
		var p: String = prefix + e.name
		if e.is_dir:
			_collect(r, out, p + "\\", r.read_dir_at(e))
		else:
			out.append([p, e])

func _init() -> void:
	var pk2_path := _arg("--pk2", "")
	var pk3_path := _arg("--pk3", "")
	var every := maxi(1, int(_arg("--every", "1")))
	var pk2 := Pk2Reader.open(pk2_path)
	if pk2 == null or pk3_path == "":
		printerr("usage: --pk2=<archive.pk2> --pk3=<archive.pk3> [--every=N]")
		quit(2)
		return
	var t0 := Time.get_ticks_usec()
	NativeAssets.force_gdscript = true
	var g := Pk2Reader.open(pk3_path) as Pk3Reader
	NativeAssets.force_gdscript = false
	var t1 := Time.get_ticks_usec()
	var n: Pk3Reader = null
	if NativeAssets.available():
		n = Pk2Reader.open(pk3_path) as Pk3Reader
	var t2 := Time.get_ticks_usec()
	if g == null:
		print("PARITY FAIL %s did not open" % pk3_path)
		quit(1)
		return
	print("pk3_parity: open %s: GDScript %d ms (%d files, %d refused, zip64 %s), native %s" % [pk3_path, (t1 - t0) / 1000,
		g.file_count(), g.refused_count, g.zip64, ("%d ms" % ((t2 - t1) / 1000)) if n != null else "not loaded"])
	var files: Array = []
	_collect(pk2, files, "", pk2.read_dir())
	var checked := 0
	var bad := 0
	var bytes := 0
	var t_g := 0
	var t_n := 0
	for i in range(0, files.size(), every):
		var path: String = files[i][0]
		var want := pk2.read_file(files[i][1])
		var a := t0
		a = Time.get_ticks_usec()
		var ge := ObjectLoader.find_file(g, path)
		var gb := g.read_file(ge) if ge != null else PackedByteArray()
		t_g += Time.get_ticks_usec() - a
		checked += 1
		bytes += want.size()
		if ge == null or gb != want:
			bad += 1
			if bad <= 10:
				print("PARITY FAIL GDScript %s: %s" % [path, "missing" if ge == null else "%d bytes, want %d" % [gb.size(), want.size()]])
		if n != null:
			a = Time.get_ticks_usec()
			var ne := ObjectLoader.find_file(n, path)
			var nb := n.read_file(ne) if ne != null else PackedByteArray()
			t_n += Time.get_ticks_usec() - a
			if ne == null or nb != want or ne.name != ge.name or ne.size != ge.size or ne._offset != ge._offset:
				bad += 1
				if bad <= 10:
					print("PARITY FAIL native %s" % path)
	# The two readers' folder listings, every folder.
	if n != null:
		var queue: Array = [[g.read_dir(), n.read_dir(), ""]]
		var dirs := 0
		while not queue.is_empty():
			var item: Array = queue.pop_front()
			var ga: Array = item[0]
			var na: Array = item[1]
			dirs += 1
			if ga.size() != na.size():
				bad += 1
				print("PARITY FAIL listing of %s: %d against %d entries" % [item[2], ga.size(), na.size()])
				continue
			for k in range(ga.size()):
				var x: Pk2Reader.Entry = ga[k]
				var y: Pk2Reader.Entry = na[k]
				if x.name != y.name or x.is_dir != y.is_dir or x.size != y.size or x._offset != y._offset:
					bad += 1
					if bad <= 10:
						print("PARITY FAIL listing %s%s" % [item[2], x.name])
				elif x.is_dir:
					queue.append([g.read_dir_at(x), n.read_dir_at(y), item[2] + x.name + "\\"])
		print("pk3_parity: %d folders listed alike" % dirs)
	print("pk3_parity: %d of %d files (%.1f MB): GDScript find+read %d ms, native %s" % [checked, files.size(), bytes / 1048576.0,
		t_g / 1000, ("%d ms" % (t_n / 1000)) if n != null else "-"])
	if bad == 0:
		print("PK3 PARITY OK %d files" % checked)
	else:
		print("PARITY FAIL %d difference(s)" % bad)
	quit(0 if bad == 0 else 1)
