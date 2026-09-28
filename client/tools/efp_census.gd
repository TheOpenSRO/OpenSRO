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

var _files := 0
var _header_ok := 0
var _exact := 0
var _trailing := 0
var _failed := {}
var _examples := {}
var _nodes := 0
var _typed_values := 0

func _init() -> void:
	var path := OS.get_environment("SRREVAMP_PARTICLES_PK2")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pk2="):
			path = a.substr(6)
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

func _count(n: EfpReader.EfpNode) -> void:
	_nodes += 1
	_typed_values += n.vars.size()
	for l in [n.emit, n.update, n.commands]:
		for c in l:
			if c.value != null:
				_typed_values += 1
