extends SceneTree

## Round 866 (the guardian's crash lane): no client script calls
## `get_meta(key, null)`. Godot's Object.get_meta takes a null default as no
## default, so a missing key logs "The object does not have any 'meta'
## values with the key ..." (at: get_meta, core/object/object.cpp:1053) on
## every call: MEASURED, a player's v0.1.638 log carried 7,397 such lines for
## opensro_fidget / opensro_body_clip, all from `get_meta(K, null)` reads.
## Absent keys go through has_meta.
## Scans res://scripts and res://tools, less the suites.
## NEGATIVE: the detector flags each banned form; with World3D's fidget read
## put back to `skel.get_meta(FIDGET_META, null)`, this fails.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

static var _re: RegEx

static func null_defaults(src: String) -> PackedInt32Array:
	if _re == null:
		_re = RegEx.create_from_string("get_meta\\([^()]*(\\([^()]*\\)[^()]*)*,\\s*null\\s*\\)")
	var out := PackedInt32Array()
	var lines := src.split("\n")
	for i in range(lines.size()):
		var code: String = lines[i]
		var h := code.find("#")
		if h >= 0:
			code = code.substr(0, h)
		if _re.search(code) != null:
			out.append(i + 1)
	return out

func _scripts(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		_scripts(dir.path_join(sub), out)
	for f in d.get_files():
		if f.ends_with(".gd") and not f.ends_with("_test.gd"):
			out.append(dir.path_join(f))

func _initialize() -> void:
	for b in ["\tvar src = skel.get_meta(FIDGET_META, null)", "\tif (s as Node).get_meta(K, null) != a:",
			"\tvar r = c.get_meta(name_of(x), null)", "\tvar t = a.get_meta(&\"k\",  null )"]:
		_check(null_defaults(b).size() == 1, "detector flags: %s" % b.strip_edges())
	for a in ["\tvar src = (skel.get_meta(K) if skel.has_meta(K) else null)", "\tvar v = n.get_meta(K, 0)",
			"## get_meta(K, null) in a comment", "\tvar v = n.get_meta(K, [])"]:
		_check(null_defaults(a).is_empty(), "detector allows: %s" % a.strip_edges())
	# The engine's behaviour the rule rests on: a null default is no default.
	var o := Node.new()
	_check(o.get_meta(&"k", 7) == 7, "a non-null default is returned for a missing key")
	o.set_meta(&"k", 3)
	_check(o.get_meta(&"k", null) == 3, "a present key reads with any default")
	o.free()
	var files: Array = []
	_scripts("res://scripts", files)
	_scripts("res://tools", files)
	var bad := 0
	for path in files:
		for ln in null_defaults(FileAccess.get_file_as_string(path)):
			print("  get_meta with a null default: %s:%d" % [path, ln])
			bad += 1
	_check(files.size() > 300, "scanned %d scripts" % files.size())
	_check(bad == 0, "no get_meta(key, null) (%d found)" % bad)
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit()
