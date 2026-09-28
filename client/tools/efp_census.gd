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

func _init() -> void:
	var path := OS.get_environment("SRREVAMP_PARTICLES_PK2")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pk2="):
			path = a.substr(6)
		if a == "--build":
			_build = true
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
	_walk(pk2, pk2.read_dir(), "")
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
	for _i in range(40):
		fx.sim.step()
	_spawned += fx.sim.spawned
	var kinds := {}
	for r in fx.skipped:
		var k := String(r)
		if k.begins_with("texture "):
			k = "texture did not load"
		elif k.begins_with("mesh "):
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
