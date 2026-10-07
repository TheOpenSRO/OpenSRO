extends SceneTree

## Round 760 (blocker 4): no client script decodes UTF-16 with a bare
## `get_string_from_utf16()`; each goes through TextDecode.utf16, which keeps
## Godot's uninitialised character (and the 4.7.2 heap overflow that follows
## it) out of the text (TextDecode's header). A bare call is allowed only on a
## line that says why: `# text-decode: <reason>` (TextDecode itself, the
## probe's negative). Scans res://scripts and res://tools, less the suites.
## NEGATIVE: the detector flags each banned form of a snippet; with
## NpcTableReader._lines put back to `raw.get_string_from_utf16()`, this fails.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

static func bare_decodes(src: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	var lines := src.split("\n")
	for i in range(lines.size()):
		var line: String = lines[i]
		var code := line
		var note := ""
		var h := line.find("#")
		if h >= 0:
			code = line.substr(0, h)
			note = line.substr(h)
		if code.find("get_string_from_utf16(") >= 0 and note.find("text-decode:") < 0:
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
	for b in ["\tvar t := raw.get_string_from_utf16()", "\treturn bytes.slice(2).get_string_from_utf16() # decode",
			"\tx = (d as PackedByteArray).get_string_from_utf16()"]:
		_check(bare_decodes(b).size() == 1, "detector flags: %s" % b.strip_edges())
	for a in ["\tvar t := TextDecode.utf16(raw)", "## get_string_from_utf16() in a comment",
			"\treturn d.get_string_from_utf16() # text-decode: the safe bytes"]:
		_check(bare_decodes(a).is_empty(), "detector allows: %s" % a.strip_edges())
	var files: Array = []
	_scripts("res://scripts", files)
	_scripts("res://tools", files)
	var bad := 0
	for path in files:
		for ln in bare_decodes(FileAccess.get_file_as_string(path)):
			print("  bare UTF-16 decode: %s:%d" % [path, ln])
			bad += 1
	_check(files.size() > 300, "scanned %d scripts" % files.size())
	_check(bad == 0, "no bare get_string_from_utf16 (%d found)" % bad)
	_check(FileAccess.get_file_as_string("res://scripts/npc/npc_table_reader.gd").find("TextDecode.utf16(raw)") >= 0,
		"NpcTableReader._lines decodes through TextDecode")
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit()
