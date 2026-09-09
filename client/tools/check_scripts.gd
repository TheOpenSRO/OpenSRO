extends SceneTree

## CI guard: loads every script and scene in the project and fails if any of
## them cannot be compiled or instantiated.
##
## This exists because `--import --quit` cannot answer the question. It exits
## 0 either way, and its *output* is unusable in both directions: on a cold
## cache it prints hundreds of spurious "Could not find type" parse errors
## while class_name symbols are still being registered (283 of them on a
## clean checkout of this project), and on a warm cache it prints nothing at
## all even when a script is genuinely broken, because the cached version is
## served instead of being re-parsed.
##
## That gap shipped a release. v0.1.71 contained
## `Control.PRESET_BOTTOM_CENTER`, an enum that does not exist in Godot 4,
## so `World3D.gd` failed to parse and the world scene could not load --
## and the release built and published green. See AGENTS.md's "a clean
## --import is not proof scripts compile".
##
## Loading a resource really does compile it, so this catches what the
## import step cannot.
##
## Usage:
##   godot4 --headless --path client --script res://tools/check_scripts.gd

## Directories that hold resources this check should not try to load.
const SKIP_DIRS := [".godot", ".import", "build", "dist"]

var _failures: Array[String] = []
var _scripts := 0
var _scenes := 0

func _collect(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path.path_join(entry) if dir_path != "res://" else "res://" + entry
		if dir.current_is_dir():
			if not (entry.begins_with(".") or entry in SKIP_DIRS):
				_collect(full, out)
		elif entry.ends_with(".gd") or entry.ends_with(".tscn"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()

func _initialize() -> void:
	var paths: Array[String] = []
	_collect("res://", paths)
	paths.sort()

	for path in paths:
		var res := load(path)
		if res == null:
			_failures.append("%s (did not load)" % path)
			continue
		# load() alone is not enough: Godot hands back a GDScript object for
		# a script that failed to parse, having only printed the error. Ask
		# the script to re-parse itself and check the returned error code --
		# that is a value this tool can act on rather than a log line.
		if res is GDScript:
			var err: int = (res as GDScript).reload()
			# Only a real compile failure counts. A script that is already
			# live in this process -- an autoload, or this tool itself --
			# answers ERR_ALREADY_IN_USE (22) because it cannot be swapped
			# out from under its own running instance, which says nothing
			# about whether it parses.
			if err == ERR_PARSE_ERROR or err == ERR_COMPILATION_FAILED:
				_failures.append("%s (%s)" % [path, "parse error" if err == ERR_PARSE_ERROR else "compilation failed"])
				continue
			_scripts += 1
		elif res is PackedScene:
			if not (res as PackedScene).can_instantiate():
				_failures.append("%s (cannot instantiate)" % path)
				continue
			_scenes += 1

	print("checked %d scripts and %d scenes" % [_scripts, _scenes])
	if _failures.is_empty():
		print("ALL LOAD")
		quit(0)
		return
	printerr("%d resource(s) failed to load:" % _failures.size())
	for path in _failures:
		printerr("  ", path)
	quit(1)
