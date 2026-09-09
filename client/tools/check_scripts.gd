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
## **Run the import first.** `can_instantiate()` is only meaningful once
## the `class_name` registry is populated, and on a cold cache it is false
## for every script that references another by its global name -- 117 of
## this project's 162. That is not a wall of failures to read through; it is
## one condition, and the check below names it rather than printing them.
##
## Usage:
##   godot4 --headless --path client --import --quit
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
		# a script that failed to parse, having only printed the error.
		# `can_instantiate()` is false for exactly that script and true for
		# one that compiled -- checked against a deliberate
		# `Control.PRESET_BOTTOM_CENTER`, the enum that shipped in v0.1.71.
		#
		# It replaces `reload()`, which answered the same question and
		# **crashed the engine** doing it. Reloading a script swaps it out
		# from under anything already holding it, and this project's
		# autoloads hold several: adding one new file that NetClient
		# references was enough to turn the existing ERR_ALREADY_IN_USE
		# warning into a segfault in CI, on a cold cache, while passing
		# every time locally. Asking a question must not be able to break
		# the thing it is asking about.
		if res is Script:
			if not (res as Script).can_instantiate():
				_failures.append("%s (did not compile)" % path)
				continue
			_scripts += 1
		elif res is PackedScene:
			if not (res as PackedScene).can_instantiate():
				_failures.append("%s (cannot instantiate)" % path)
				continue
			_scenes += 1

	# A cold cache fails almost everything, because no script can see any
	# other's class_name yet. Real breakage is one file or a few; this is a
	# different problem with a different fix, and saying which saves reading
	# a hundred identical lines to find that out.
	var total := _scripts + _scenes + _failures.size()
	if total > 0 and _failures.size() * 3 > total:
		printerr("%d of %d resources failed, which is not a code problem: run" % [_failures.size(), total])
		printerr("  godot4 --headless --path client --import --quit")
		printerr("first, so every class_name is registered before anything is checked.")
		quit(2)
		return

	print("checked %d scripts and %d scenes" % [_scripts, _scenes])
	if _failures.is_empty():
		print("ALL LOAD")
		quit(0)
		return
	printerr("%d resource(s) failed to load:" % _failures.size())
	for path in _failures:
		printerr("  ", path)
	quit(1)
