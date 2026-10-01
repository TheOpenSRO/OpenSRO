extends SceneTree

## Holds the native .bms, .ban and .bsk readers (round 669; native/src/core/
## bms.rs, ban.rs, bsk.rs) to the GDScript ones on the REAL archives: EVERY
## .bms, EVERY .ban and EVERY .bsk in each archive, parsed both ways and compared bit for bit
## (ModelCompare) -- every field, every vertex, index, weight, keyframe,
## bone record and string -- and every .bms's to_arrays surface both ways (the native one
## taken before the mesh builds its vertices). Run on the render box; its
## output is never committed:
##
##   client/tools/remote_godot.sh script res://tools/native_parity_models.gd -- --pk2-dir=/opt/sro-files/client
##
## Also counts the files the native reader leaves to GDScript (it returns
## {error} where GDScript returns null, and for input that depends on Godot's
## negative indexing): `deferred` lines say how many, and how many of those
## GDScript then parsed. Prints `PARITY <archive> ...` counts, the first
## FAIL lines, and `PARITY PASS` or `PARITY FAIL <n>`; exits 1 on a FAIL or
## without a usable library. `--only=Data.pk2` limits it to one archive.

const ARCHIVES := ["Data.pk2", "Map.pk2", "Media.pk2", "Particles.pk2"]
## The first FAIL lines printed for each kind (bms, ban, bsk, other).
const MAX_FAIL_LINES := 4

var _fails := 0
var _fails_by_kind := {}

func _fail(msg: String, kind: String = "other") -> void:
	_fails += 1
	_fails_by_kind[kind] = int(_fails_by_kind.get(kind, 0)) + 1
	if _fails_by_kind[kind] <= MAX_FAIL_LINES:
		print("FAIL " + msg)

func _init() -> void:
	var pk2_dir := "/opt/sro-files/client"
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pk2-dir="):
			pk2_dir = a.substr(10)
		elif a.begins_with("--only="):
			only = a.substr(7)
	if not NativeAssets.library_usable():
		print("PARITY FAIL: no usable native library (%s) -- nothing to compare" % NativeAssets.api_verdict(NativeAssets.library_api()))
		quit(1)
		return
	NativeAssets.available()
	if NativeAssets.models() == null:
		print("PARITY FAIL: the library has no %s class" % NativeAssets.MODELS_CLASS)
		quit(1)
		return
	var t0 := Time.get_ticks_msec()
	var total := {"bms": 0, "ban": 0, "bsk": 0}
	for name in ARCHIVES:
		if only != "" and name != only:
			continue
		var counts := _compare_archive(pk2_dir.path_join(name), name)
		total["bms"] += counts[0]
		total["ban"] += counts[1]
		total["bsk"] += counts[2]
	print("PARITY total: %d .bms, %d .ban, %d .bsk compared (%d s)" % [total["bms"], total["ban"], total["bsk"], (Time.get_ticks_msec() - t0) / 1000])
	if _fails == 0:
		print("PARITY PASS")
		quit(0)
	else:
		print("PARITY FAIL %d (by kind: %s)" % [_fails, _fails_by_kind])
		quit(1)

## Every file of the archive whose name ends in `ext`, as [path, Entry].
func _files(archive: Pk2Reader) -> Array:
	var out: Array = []
	var queue: Array = [["", archive._root_offset]]
	var seen := {}
	while not queue.is_empty():
		var item: Array = queue.pop_back()
		var off: int = item[1]
		if seen.has(off):
			continue
		seen[off] = true
		for e in archive._read_block_chain(off):
			var p: String = e.name if item[0] == "" else item[0] + "\\" + e.name
			if e.is_dir:
				if e.name != "." and e.name != "..":
					queue.append([p, e._offset])
			else:
				out.append([p, e])
	return out

func _compare_archive(path: String, label: String) -> Array:
	var archive := Pk2Reader.open(path)
	if archive == null:
		_fail("%s: could not open" % label)
		return [0, 0, 0]
	var models: Object = NativeAssets.models()
	var t := Time.get_ticks_msec()
	var files := _files(archive)
	var bms := {"files": 0, "parsed": 0, "null": 0, "deferred": 0, "deferred_parsed": 0, "vertices": 0, "triangles": 0,
		"skinned": 0, "partial_skin": 0, "rec52": 0, "motion": 0, "links": 0, "g_us": 0, "n_us": 0}
	var ban := {"files": 0, "parsed": 0, "null": 0, "deferred": 0, "deferred_parsed": 0, "bones": 0, "keys": 0, "g_us": 0, "n_us": 0}
	var bsk := {"files": 0, "parsed": 0, "null": 0, "deferred": 0, "deferred_parsed": 0, "bones": 0, "type_a": 0, "g_us": 0, "n_us": 0}
	for f in files:
		var p: String = f[0]
		var lower := p.to_lower()
		var ext := lower.get_extension()
		if not ext in ["bms", "ban", "bsk"]:
			continue
		var is_bms := ext == "bms"
		var data := archive.read_file(f[1])
		var raw: Dictionary = models.call(ext + "_parse", data)
		var s: Dictionary = {"bms": bms, "ban": ban, "bsk": bsk}[ext]
		s["files"] += 1
		NativeAssets.force_gdscript = true
		var tg := Time.get_ticks_usec()
		var g = _parse(ext, data)
		s["g_us"] += Time.get_ticks_usec() - tg
		NativeAssets.force_gdscript = false
		var tn := Time.get_ticks_usec()
		var n = _parse(ext, data)
		s["n_us"] += Time.get_ticks_usec() - tn
		if raw.has("error"):
			s["deferred"] += 1
			if g != null:
				s["deferred_parsed"] += 1
		if g == null:
			s["null"] += 1
		else:
			s["parsed"] += 1
		if raw.has("error") == false and g == null:
			_fail("%s: '%s': native parsed it, GDScript returned null" % [label, p], ext)
			continue
		if is_bms:
			var diff := ""
			if g != null and n != null:
				var natively: bool = not n._native.is_empty()
				var ga := BmsReader.to_arrays(g)
				var na := BmsReader.to_arrays(n)
				diff = ModelCompare.arrays_diff(ga, na)
				if diff != "":
					diff = "to_arrays: " + diff
				if natively != (not raw.has("error")):
					diff = "parsed natively %s, native answered %s" % [natively, "error" if raw.has("error") else "a mesh"]
				bms["vertices"] += g.vertex_count()
				bms["triangles"] += g.indices.size() / 3
				if g.is_skinned():
					bms["skinned"] += 1
				elif raw.has("bone0"):
					bms["partial_skin"] += 1
				if int(raw.get("extra_size", 0)) == 52 - 0x20:
					bms["rec52"] += 1
				if not g.vertex_motion.is_empty():
					bms["motion"] += 1
				if not g.vertex_links.is_empty():
					bms["links"] += 1
			if diff == "":
				diff = ModelCompare.bms_diff(g, n)
			if diff != "":
				_fail("%s: bms '%s': %s" % [label, p, diff], "bms")
		elif ext == "bsk":
			if g != null:
				bsk["bones"] += g.bones.size()
				for b in g.bones:
					if (b as BskReader.Bone).parent_name == "":
						bsk["type_a"] += 1
			var diff := ModelCompare.bsk_diff(g, n)
			if diff != "":
				_fail("%s: bsk '%s': %s" % [label, p, diff], "bsk")
		else:
			if g != null:
				ban["bones"] += g.bones.size()
				for b in g.bones:
					ban["keys"] += (b as BanReader.Bone).keyframes.size()
			var diff := ModelCompare.ban_diff(g, n)
			if diff != "":
				_fail("%s: ban '%s': %s" % [label, p, diff], "ban")
	archive.close()
	print("PARITY %s: bms -- %d files: %d parsed, %d null both ways; %d left to GDScript by the native reader (%d of them parsed there); %d vertices, %d triangles; %d skinned, %d with a skin refused part-way, %d at 52 bytes a vertex, %d with motion, %d with links; parse %d ms GDScript, %d ms native" % [
		label, bms["files"], bms["parsed"], bms["null"], bms["deferred"], bms["deferred_parsed"], bms["vertices"], bms["triangles"],
		bms["skinned"], bms["partial_skin"], bms["rec52"], bms["motion"], bms["links"], bms["g_us"] / 1000, bms["n_us"] / 1000])
	print("PARITY %s: ban -- %d files: %d parsed, %d null both ways; %d left to GDScript by the native reader (%d of them parsed there); %d bones, %d keyframes; parse %d ms GDScript, %d ms native (%d ms total)" % [
		label, ban["files"], ban["parsed"], ban["null"], ban["deferred"], ban["deferred_parsed"], ban["bones"], ban["keys"],
		ban["g_us"] / 1000, ban["n_us"] / 1000, Time.get_ticks_msec() - t])
	print("PARITY %s: bsk -- %d files: %d parsed, %d null both ways; %d left to GDScript by the native reader (%d of them parsed there); %d bones, %d of them parent-less records; parse %d ms GDScript, %d ms native" % [
		label, bsk["files"], bsk["parsed"], bsk["null"], bsk["deferred"], bsk["deferred_parsed"], bsk["bones"], bsk["type_a"],
		bsk["g_us"] / 1000, bsk["n_us"] / 1000])
	return [bms["files"], ban["files"], bsk["files"]]

func _parse(ext: String, data: PackedByteArray) -> Variant:
	match ext:
		"bms":
			return BmsReader.parse(data)
		"ban":
			return BanReader.parse(data)
	return BskReader.parse(data)
