extends SceneTree

## No state crosses World3D instances (round 560): a second login in one
## client process gets its own ground/water/environment caches, and leaving
## the tree frees the NPC templates the instance built. Run headless:
##   godot4 --headless --path client --script res://scripts/world/world3d_reentry_test.gd
##
## Two bare instances of the script (no _ready runs, no @onready member is
## touched) stand in for two logins. Until round 560 the caches were
## `static var`s -- one Dictionary per process, so instance b saw whatever a
## had cached: round 558's scripted reconnect measured entry 2 starting with
## entry 1's 43 ground textures (`cache_ground=43`) before it had loaded a
## region. Both access paths are asserted: the instance members, and
## `Script.get()`, which answers a script-level static by name.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## World3D.gd needs the NetClient autoload registered before it compiles,
## which is the case in _initialize and not in _init (hud_window_test.gd's
## pattern).
func _initialize() -> void:
	var S := load("res://scripts/World3D.gd") as GDScript
	_check(S != null and S.can_instantiate(), "World3D.gd loads and can instantiate headless")
	if S == null or not S.can_instantiate():
		_finish()
		return
	var a: Node = S.new()
	var b: Node = S.new()
	_check(a != null and b != null, "two bare World3D instances exist side by side")

	# Instance a caches what a first login would; b is the second login.
	a._ground_texture_cache["probe.ddj"] = null
	a._water_frames_cache.append(null)
	a._water_frames_load_attempted = true
	a._environment_load_attempted = true
	_check(not b._ground_texture_cache.has("probe.ddj"),
		"ground texture cache is per World3D instance (b does not see a's probe.ddj)")
	_check(b._water_frames_cache.is_empty(),
		"water frames cache is per World3D instance")
	_check(b._water_frames_load_attempted == false,
		"water load flag is per World3D instance")
	_check(b._environment_load_attempted == false,
		"environment load flag is per World3D instance")
	_check(b._environment_table == null,
		"environment table is per World3D instance")
	# The script itself holds none of them: Script.get() names a static.
	for name in ["_ground_texture_cache", "_water_frames_cache", "_water_frames_load_attempted",
			"_environment_table", "_environment_load_attempted"]:
		_check(S.get(name) == null, "World3D.gd has no script-level static %s" % name)

	# Leaving the tree frees what the instance built outside it: an NPC
	# template is a never-parented Skeleton3D (the _npc_model_cache doc
	# comment), so nothing else frees it. _exit_tree is called directly on
	# the detached instance; it must cope with no viewport.
	var template := SkinnedBsrAssembler.AssembledCharacter.new()
	template.skeleton = Skeleton3D.new()
	var skeleton := template.skeleton
	a._npc_model_cache["probe.bsr"] = template
	a._exit_tree()
	_check(not is_instance_valid(skeleton), "_exit_tree frees the NPC templates")
	_check(a._npc_model_cache.is_empty(), "_exit_tree empties the NPC template cache")
	_check(a._ground_texture_cache.is_empty() and a._water_frames_cache.is_empty()
			and not a._water_frames_load_attempted and not a._environment_load_attempted,
		"_exit_tree clears this instance's ground, water and environment caches")

	a.free()
	b.free()
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
