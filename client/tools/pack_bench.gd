extends SceneTree

## Load benchmark for the asset packs (round 789; docs/TODO.md's "measure
## loading against .pk2"). Times the same lookups and reads three ways, each
## on freshly opened handles, interleaved, several rounds:
##   plain    Pk2Reader.open(Data) -- every reader before round 789;
##   empty    an AssetArchives set over Data with an EMPTY pack folder (the
##            default for a player without packs: must be no slower);
##   packs    the same set with --packs=<dir> over it (a pack overriding a
##            few files: the overlay index, the layered lookup).
## The paths: the first --count files of Data's tree (breadth first), each
## found and read once a round. Data comes from OPENSRO_PK2_PATH (Pk2Config).
##
##   OPENSRO_PK2_PATH=/opt/sro-files/client/Data.pk2 godot --headless --path client \
##     --script res://tools/pack_bench.gd -- --packs=/var/tmp/k789/packs --count=20000 --rounds=5
## OPENSRO_NATIVE=0 measures the GDScript readers. Prints a BENCH line per
## scenario and round and a MEDIAN line per scenario: open (the set and the
## handle), view (the view, with its override census), find, read (ms).

func _arg(flag: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return def

func _collect(r: Pk2Reader, count: int) -> PackedStringArray:
	var out := PackedStringArray()
	var queue: Array = [["", r.read_dir()]]
	while not queue.is_empty() and out.size() < count:
		var item: Array = queue.pop_front()
		for e in item[1]:
			var p: String = item[0] + e.name
			if e.is_dir:
				queue.append([p + "\\", r.read_dir_at(e)])
			else:
				out.append(p)
				if out.size() >= count:
					break
	return out

func _run(kind: String, data_path: String, packs: String, empty_dir: String, paths: PackedStringArray) -> Array:
	var t0 := Time.get_ticks_usec()
	var a: Pk2Reader
	var s: AssetArchives = null
	if kind == "plain":
		a = Pk2Reader.open(data_path)
	else:
		s = AssetArchives.open_set({"mode": "mixed", "base_paths": {"Data": data_path},
			"pack_dir": packs if kind == "packs" else empty_dir, "custom_dir": ""})
	var t1 := Time.get_ticks_usec()
	if s != null:
		a = s.view("Data")
	var t2 := Time.get_ticks_usec()
	var found: Array = []
	for p in paths:
		found.append(ObjectLoader.find_file(a, p))
	var t3 := Time.get_ticks_usec()
	var bytes := 0
	for e in found:
		if e != null:
			bytes += a.read_file(e).size()
	var t4 := Time.get_ticks_usec()
	return [(t1 - t0) / 1000.0, (t2 - t1) / 1000.0, (t3 - t2) / 1000.0, (t4 - t3) / 1000.0, bytes]

func _init() -> void:
	var data_path := Pk2Config.data_path()
	if data_path == "":
		printerr("pack_bench: no Data archive (OPENSRO_PK2_PATH)")
		quit(2)
		return
	var packs := _arg("--packs", "")
	var count := int(_arg("--count", "20000"))
	var rounds := int(_arg("--rounds", "5"))
	var empty_dir := ProjectSettings.globalize_path("user://pack_bench_empty")
	DirAccess.make_dir_recursive_absolute(empty_dir)
	var paths := _collect(Pk2Reader.open(data_path), count)
	print("pack_bench: %d paths of %s; packs %s; %s" % [paths.size(), data_path, packs if packs != "" else "(none)", NativeAssets.status])
	var kinds := ["plain", "empty"]
	if packs != "":
		kinds.append("packs")
	var results := {}
	for k in kinds:
		results[k] = []
	for r in range(rounds + 1):
		for k in kinds:
			var v := _run(k, data_path, packs, empty_dir, paths)
			if r == 0:
				continue # the first round warms the page cache
			results[k].append(v)
			print("BENCH %s round %d: open %.1f view %.1f find %.1f read %.1f ms (%.1f MB)" % [k, r, v[0], v[1], v[2], v[3], v[4] / 1048576.0])
	for k in kinds:
		var cols := []
		for c in range(4):
			var xs := []
			for v in results[k]:
				xs.append(v[c])
			xs.sort()
			cols.append(xs[xs.size() / 2])
		print("MEDIAN %s: open %.1f view %.1f find %.1f read %.1f ms, total %.1f" % [k, cols[0], cols[1], cols[2], cols[3], cols[0] + cols[1] + cols[2] + cols[3]])
	quit(0)
