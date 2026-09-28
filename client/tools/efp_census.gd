extends SceneTree

## The GDScript twin of `server/cmd/efpcensus`: decodes every .efp in the
## player's Particles.pk2 through EfpReader.decode and prints the same
## headline counts, so the two readers can be checked against each other.
## Reads the archive at runtime and prints only counts and paths.
##
##   godot4 --headless --path client --script res://tools/efp_census.gd -- --pk2=/path/Particles.pk2
##
## (or set SRREVAMP_PARTICLES_PK2). Exits 0 when every file whose header
## parses also decodes, 1 otherwise.
##
## `-- --pk2=... --build` (round 620) also builds every decoded file into an
## EfpEffect with its real meshes and textures and runs 40 frames (2 s) of
## its simulation, and reports how many build, how many draw every node they
## mean to draw, and the reasons nodes were skipped (render modes not drawn,
## assets missing, commands no rule covers).
##
## `--assets` (round 621, with --build) lists every texture and mesh that did
## not load, one line each, with the number of files naming it and why it
## failed: absent from Particles.pk2 (and whether Media.pk2 or Data.pk2 beside
## it, another extension, or another folder of Particles.pk2 has it), or
## present but refused by DdjReader / BmsReader (with the DDS FourCC or the
## JMXVBMS version).

var _files := 0
var _header_ok := 0
var _exact := 0
var _trailing := 0
var _failed := {}
var _examples := {}
var _nodes := 0
var _typed_values := 0
var _build := false
var _pk2: Pk2Reader
var _built := 0
var _built_full := 0
var _built_drawing := 0
var _build_failed := 0
var _skips := {}
var _skip_files := {}
var _spawned := 0
var _assets := false
var _link_files := 0 # files with a drawn Link node
var _link_drawing := 0 # ... whose strips drew a triangle at some sampled frame
var _link_peaks := PackedInt32Array() # per such file: its largest one-frame triangle count
var _bad_assets := {} # "texture|path" or "mesh|path" -> files naming it
var _pk2_dir := ""

func _init() -> void:
	var path := OS.get_environment("SRREVAMP_PARTICLES_PK2")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pk2="):
			path = a.substr(6)
		if a == "--build":
			_build = true
		if a == "--assets":
			_assets = true
	if path == "":
		print("usage: efp_census.gd -- --pk2=<Particles.pk2>")
		quit(2)
		return
	var pk2 := Pk2Reader.open(path)
	if pk2 == null:
		print("cannot open %s" % path)
		quit(2)
		return
	var t0 := Time.get_ticks_msec()
	_pk2 = pk2
	_pk2_dir = path.get_base_dir()
	_walk(pk2, pk2.read_dir(), "")
	if _assets:
		_report_assets()
	pk2.close()
	var decoded := _exact + _trailing
	print("efp files:            %d" % _files)
	print("headers parsed:       %d (%.1f%%)" % [_header_ok, 100.0 * _header_ok / maxi(_files, 1)])
	print("tree decoded:         %d (%.1f%%)" % [decoded, 100.0 * decoded / maxi(_files, 1)])
	print("  exact, 0 bytes left: %d" % _exact)
	print("  bytes after root:     %d" % _trailing)
	print("nodes decoded:        %d" % _nodes)
	print("typed values decoded: %d" % _typed_values)
	for k in _failed:
		print("  %6d  %s  e.g. %s" % [_failed[k], k, _examples[k]])
	if _build:
		print("built into an EfpEffect: %d of %d decoded (%.1f%% of all files); %d failed" % [
			_built, decoded, 100.0 * _built / maxi(_files, 1), _build_failed])
		print("  drawing every node they draw: %d (%.1f%% of all files)" % [_built_full, 100.0 * _built_full / maxi(_files, 1)])
		print("  drawing at least one node:    %d (%.1f%% of all files)" % [_built_drawing, 100.0 * _built_drawing / maxi(_files, 1)])
		print("  particles spawned in 40 frames, all files: %d" % _spawned)
		if _link_files > 0:
			var pk := _link_peaks.duplicate()
			pk.sort()
			var nz := pk.size()
			print("  files drawing a Link node: %d; with a Link triangle at some sampled frame: %d" % [_link_files, _link_drawing])
			if nz > 0:
				print("  one effect's peak Link triangles in one frame (frames 1..40 sampled): median %d, 90th pct %d, max %d" % [
					pk[nz / 2], pk[mini(nz - 1, nz * 9 / 10)], pk[nz - 1]])
		print("skipped (files, reason):")
		var keys := _skip_files.keys()
		keys.sort_custom(func(a, b): return int(_skip_files[a]) > int(_skip_files[b]))
		for k in keys.slice(0, 30):
			print("  %6d  %s" % [_skip_files[k], k])
	print("elapsed %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
	quit(0 if decoded == _header_ok else 1)

func _walk(pk2: Pk2Reader, entries: Array, prefix: String) -> void:
	for e in entries:
		if e.name == "." or e.name == "..":
			continue
		var p: String = e.name if prefix == "" else prefix + "\\" + e.name
		if e.is_dir:
			_walk(pk2, pk2.read_dir_at(e), p)
			continue
		if not p.to_lower().ends_with(".efp"):
			continue
		_files += 1
		var data := pk2.read_file(e)
		var header_ok := data.size() >= 12 and data.slice(0, 8).get_string_from_ascii() == "JMXVEFF " \
			and EfpReader.header_size(data.slice(8, 12).get_string_from_ascii()) >= 0
		if header_ok:
			_header_ok += 1
		var f := EfpReader.decode(data)
		if f == null:
			var k := EfpReader.last_error.split(" at offset")[0]
			if not header_ok:
				k = "header: " + k
			_failed[k] = _failed.get(k, 0) + 1
			if not _examples.has(k):
				_examples[k] = p
			continue
		if f.trailing == 0:
			_exact += 1
		else:
			_trailing += 1
		f.root.walk(_count)
		if _build:
			_build_one(p, f)

## Builds one decoded file into an EfpEffect with its real assets and runs
## 40 frames of it. A skip reason is bucketed by kind, not by asset name.
func _build_one(p: String, f: EfpReader.EfpFile) -> void:
	var t := EfpSim.compile(f.root)
	var fx := EfpEffect.from_template(t, func(x: String): return EfpEffect._texture(x, _pk2),
		func(x: String): return EfpEffect._mesh(x, _pk2), 1)
	if fx == null:
		_build_failed += 1
		return
	_built += 1
	# Round 621: the Link strips are built at every frame (headless view),
	# so a script error in the strip code shows up across the archive, and
	# each file's peak one-frame triangle count is kept (review follow-up:
	# frame 40 alone missed effects that are over by then).
	var peak := 0
	for _i in range(40):
		fx.sim.step()
		if not fx._links.is_empty():
			fx.reset_link_budget()
			fx._update_links()
			var tris := 0
			for d in fx._links:
				tris += (d[3] as EfpLinks.Out).expand().size()
			peak = maxi(peak, tris)
	_spawned += fx.sim.spawned
	if not fx._links.is_empty():
		_link_files += 1
		if peak > 0:
			_link_drawing += 1
			_link_peaks.append(peak)
	var kinds := {}
	for r in fx.skipped:
		var k := String(r)
		if k.begins_with("texture "):
			_note_asset("texture|" + k.substr(8))
			k = "texture did not load"
		elif k.begins_with("mesh "):
			_note_asset("mesh|" + k.substr(5))
			k = "mesh did not load"
		elif k.begins_with("BSAnimation"):
			k = "BSAnimation (mesh drawn unanimated)"
		elif k.find(" (") > 0:
			k = k.substr(0, k.find(" ("))
		kinds[k] = true
	var hard := false
	for k in kinds:
		_skip_files[k] = int(_skip_files.get(k, 0)) + 1
		if not String(k).begins_with("BSAnimation"):
			hard = true
	if not hard:
		_built_full += 1
	if fx.draw_count() > 0:
		_built_drawing += 1
	fx.sim.clear()
	fx.free()

func _count(n: EfpReader.EfpNode) -> void:
	_nodes += 1
	_typed_values += n.vars.size()
	for l in [n.emit, n.update, n.commands]:
		for c in l:
			if c.value != null:
				_typed_values += 1

func _note_asset(k: String) -> void:
	_bad_assets[k] = int(_bad_assets.get(k, 0)) + 1

## One line per asset that did not load, with the reason (see the header).
func _report_assets() -> void:
	var others := {}
	for n in ["Media.pk2", "Data.pk2"]:
		var o := Pk2Reader.open(_pk2_dir.path_join(n))
		if o != null:
			others[n] = o
	var by_base := {}
	_index_names(_pk2, _pk2.read_dir(), "", by_base)
	var other_base := {}
	for n in others:
		var ob := {}
		_index_names(others[n], (others[n] as Pk2Reader).read_dir(), "", ob)
		other_base[n] = ob
	var keys := _bad_assets.keys()
	keys.sort()
	var reasons := {}
	print("assets that did not load (kind, files, path, reason):")
	for k in keys:
		var kind: String = String(k).split("|")[0]
		var p: String = String(k).split("|")[1]
		var why := _why(kind, p, others, by_base, other_base)
		var bucket := why.split(":")[0]
		reasons[kind + ": " + bucket] = int(reasons.get(kind + ": " + bucket, 0)) + 1
		print("  %-7s %4d  %s  -- %s" % [kind, _bad_assets[k], p, why])
	print("asset failures by reason (distinct assets):")
	for r in reasons:
		print("  %4d  %s" % [reasons[r], r])
	for n in others:
		(others[n] as Pk2Reader).close()

func _index_names(pk2: Pk2Reader, entries: Array, prefix: String, out: Dictionary) -> void:
	for e in entries:
		if e.name == "." or e.name == "..":
			continue
		var p: String = e.name if prefix == "" else prefix + "\\" + e.name
		if e.is_dir:
			_index_names(pk2, pk2.read_dir_at(e), p, out)
		else:
			var b := String(e.name).to_lower().get_basename()
			if not out.has(b):
				out[b] = []
			(out[b] as Array).append(p)

func _why(kind: String, p: String, others: Dictionary, by_base: Dictionary, other_base: Dictionary) -> String:
	var bytes := AssetSource.read_bytes(p, _pk2)
	if not bytes.is_empty():
		var magic := bytes.slice(0, 12).get_string_from_ascii()
		if kind == "texture":
			var t := DdjReader.parse(bytes)
			if t == null:
				return "refused by DdjReader: magic %s" % magic
			return "refused by DdjReader.to_texture: fourcc '%s' (%s) bpp %d" % [
				t.four_cc, _hex4(bytes, 20 + 4 + 72 + 8), t.rgb_bit_count]
		return "refused by BmsReader: magic %s, %d bytes" % [magic, bytes.size()]
	var alt := []
	for n in others:
		if ObjectLoader.find_file(others[n], p) != null:
			alt.append("in " + n)
	var stem := p.get_basename()
	for ext in ["ddj", "dds", "tga", "bms", "bmt"]:
		if ext != p.get_extension().to_lower() and ObjectLoader.find_file(_pk2, stem + "." + ext) != null:
			alt.append("as ." + ext)
	var b := p.get_file().to_lower().get_basename()
	if b != "" and by_base.has(b):
		alt.append("same name at " + ", ".join(PackedStringArray((by_base[b] as Array).slice(0, 3))))
	for n in other_base:
		if b != "" and (other_base[n] as Dictionary).has(b):
			alt.append("same name in %s at %s" % [n, ", ".join(PackedStringArray((other_base[n][b] as Array).slice(0, 3)))])
	if alt.is_empty():
		return "absent: not in Particles.pk2, Media.pk2 or Data.pk2 under any folder or extension"
	return "absent here, but: " + "; ".join(PackedStringArray(alt))

static func _hex4(b: PackedByteArray, o: int) -> String:
	if b.size() < o + 4:
		return "?"
	return "%02x %02x %02x %02x" % [b[o], b[o + 1], b[o + 2], b[o + 3]]
