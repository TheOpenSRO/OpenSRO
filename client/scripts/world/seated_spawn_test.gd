extends SceneTree

## Players seated before this client saw them are drawn seated (round 607). Run
## headless on the render box: `client/tools/remote_godot.sh tests`.
##
## Round 607's review measured that a 0x30bf sent right behind the enter-world
## or zone-change result never reached a body: on entry it fired before the
## world scene existed, on a zone change before the new zone's bodies did. The
## state now rides in the result's Seated tail, and World3D._spawn_result_others
## -- what _ready and _on_change_zone_result both spawn the listed players
## through -- seats them as it spawns them.
##
## The world is World3D.tscn with a do-nothing _ready (restored_entry_test.gd's
## pattern), so no archive and no network is opened; the bodies are the
## placeholder capsules a world without character assets draws.
##
## NEGATIVES: without the seating in _spawn_result_others, or with either call
## site back on its own loop, Bram is spawned but not seated.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	var world := _make_world()
	if world != null:
		_test_spawn(world)
		_test_call_sites()
		root.remove_child(world)
		world.free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"func _ready() -> void:",
		"\tpass",
		"func _physics_process(_delta: float) -> void:",
		"\tpass",
		"func _input(_event: InputEvent) -> void:",
		"\tpass",
		"func _unhandled_input(_event: InputEvent) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	return world

func _snap(id: int, name: String) -> WorldNet.EntitySnapshot:
	var s := WorldNet.EntitySnapshot.new()
	s.character_id = id
	s.char_name = name
	s.gender = CharacterNet.GENDER_CHINA_MAN
	return s

func _test_spawn(world: Node) -> void:
	# Entry: Bram sits, Cleo stands.
	var entry := WorldNet.EnterWorldResult.new()
	entry.ok = true
	entry.others = [_snap(42, "Bram"), _snap(43, "Cleo")]
	entry.seated = [42]
	world.call("_spawn_result_others", entry.others, entry.seated)
	var bodies: Dictionary = world.get("_other_bodies")
	var seated: Dictionary = world.get("_other_seated")
	_check(bodies.has(42) and bodies.has(43), "the enter-world result's players are spawned")
	_check(seated.has(42), "Bram, in the result's Seated tail, is drawn seated")
	_check(not seated.has(43), "Cleo, not in it, is not")

	# A zone change: the old zone's bodies go, the new zone's are spawned from
	# its result -- Dara sits there.
	var zone := WorldNet.ChangeZoneResult.new()
	zone.ok = true
	zone.others = [_snap(44, "Dara")]
	zone.seated = [44]
	for id in bodies.keys():
		(bodies[id] as Node).queue_free()
	bodies.clear()
	seated.clear()
	world.call("_spawn_result_others", zone.others, zone.seated)
	_check(bodies.has(44) and seated.has(44), "Dara, seated in the zone-change result, is drawn seated")
	_check(not seated.has(42), "the old zone's sitter is forgotten")

	# A seated id the result does not list is not invented.
	world.call("_spawn_result_others", [], [99])
	_check(not seated.has(99), "an id with no body is not seated")

## Both spawn sites go through _spawn_result_others -- the rule is only as good
## as its call sites, and a site back on its own loop would drop the tail.
func _test_call_sites() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/World3D.gd")
	var ready_at := src.find("func _ready()")
	var zone_at := src.find("func _on_change_zone_result(")
	var ready_body := src.substr(ready_at, src.find("\nfunc ", ready_at + 1) - ready_at)
	var zone_body := src.substr(zone_at, src.find("\nfunc ", zone_at + 1) - zone_at)
	_check(ready_body.contains("_spawn_result_others(result.others, result.seated)"),
		"_ready spawns the enter-world result's players through _spawn_result_others with its Seated tail")
	_check(zone_body.contains("_spawn_result_others(result.others, result.seated)"),
		"_on_change_zone_result spawns the new zone's players through _spawn_result_others with its Seated tail")
