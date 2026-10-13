extends SceneTree

## Round 786: a unique's minimap sign, World3D's side. Run headless on the
## render box: `client/tools/remote_godot.sh tests`.
##
## READ (vslot_013, 0x663780..0x6637ac): a CICMonster whose +0x7ac is 3 or 8
## is drawn with CIFMinimap +0x3b0 (mm_sign_unique), any other monster with
## +0x3ac (mm_sign_monster); HudMinimap.monster_sign_kind is that rule and
## hud_minimap_test.gd / minimap_signs_test.gd hold it and the drawing.
## Holds here: World3D decides a monster's sign once, when its body is built,
## from the snapshot's rarity; the frame's fill hands a unique to the unique
## list and not the monster list, and a normal monster to the monster list
## only; a unique that leaves, or a zone change, takes it out of the set.
##
## Everything is SYNTHETIC (a one-bone skeleton, no mesh); no game data.
##
## NEGATIVE, on the base (dev 710d7e97): World3D has no _minimap_fill_monsters
## or _minimap_unique_bodies, and every monster -- Lord Yarkan included --
## went to the one monster list (the suite prints its FAIL lines).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(120.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	var world := _make_world()
	if world != null:
		await process_frame
		_test_split(world)
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
		"func _process(_delta: float) -> void:",
		"\tpass",
		"func _input(_event: InputEvent) -> void:",
		"\tpass",
		"func _unhandled_input(_event: InputEvent) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a quiet subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	world.set("_monster_models_loaded", true)
	world.set("_monster_models_by_code", {"MOB_UNIQUE_TEST": "synthetic\\unique.bsr"})
	world.set("_monster_assemble", _synthetic_model)
	root.add_child(world)
	return world

func _synthetic_model(_path: String) -> SkinnedBsrAssembler.AssembledCharacter:
	var skel := Skeleton3D.new()
	skel.add_bone("root")
	var result := SkinnedBsrAssembler.AssembledCharacter.new()
	result.skeleton = skel
	return result

func _snap(id: int, rarity: int, x: float) -> CombatNet.MonsterSnapshot:
	var snap := CombatNet.MonsterSnapshot.new()
	snap.monster_id = id
	snap.code_name = "MOB_UNIQUE_TEST"
	snap.monster_name = "Unique test %d" % rarity
	snap.max_hp = 10
	snap.hp = 10
	snap.rarity = rarity
	snap.x = x
	return snap

func _has(list: Array, at: Vector3) -> bool:
	for p in list:
		if (p as Vector3).is_equal_approx(at):
			return true
	return false

func _test_split(world: Node) -> void:
	if not world.has_method("_minimap_fill_monsters"):
		_check(false, "World3D._minimap_fill_monsters exists")
		return
	# A normal monster, Lord Yarkan's rarity (3) and a rarity-8 boss.
	world.call("_spawn_or_update_monster", _snap(78601, 0, 10.0))
	world.call("_spawn_or_update_monster", _snap(78603, 3, 20.0))
	world.call("_spawn_or_update_monster", _snap(78608, 8, 30.0))
	var bodies: Dictionary = world.get("_monster_bodies")
	var uniques: Dictionary = world.get("_minimap_unique_bodies")
	_check(bodies.has(78601) and bodies.has(78603) and bodies.has(78608), "the three bodies are built")
	if not (bodies.has(78601) and bodies.has(78603) and bodies.has(78608)):
		return
	_check(uniques.size() == 2 and uniques.has(78603) and uniques.has(78608) and not uniques.has(78601),
		"the rarity-3 and rarity-8 monsters are kept as uniques at spawn, the normal one is not (%s)" % str(uniques.keys()))
	var normal_at: Vector3 = (bodies[78601] as Node3D).global_position
	var r3_at: Vector3 = (bodies[78603] as Node3D).global_position
	var r8_at: Vector3 = (bodies[78608] as Node3D).global_position
	world.call("_minimap_fill_monsters", normal_at, INF)
	var monsters: Array = world.get("_minimap_monsters")
	var unique_list: Array = world.get("_minimap_uniques")
	_check(monsters.size() == 1 and _has(monsters, normal_at),
		"the monster list holds the normal monster only (%d)" % monsters.size())
	_check(unique_list.size() == 2 and _has(unique_list, r3_at) and _has(unique_list, r8_at),
		"the unique list holds the rarity-3 and rarity-8 monsters (%d)" % unique_list.size())
	_check(not _has(monsters, r3_at) and not _has(monsters, r8_at), "a unique is not in the monster list too")
	# The reach still applies to both lists.
	world.call("_minimap_fill_monsters", normal_at, 15.0)
	_check(monsters.size() == 1 and (world.get("_minimap_uniques") as Array).size() == 1,
		"the sign reach cuts both lists (monsters %d, uniques %d)" % [monsters.size(), (world.get("_minimap_uniques") as Array).size()])
	# A unique that leaves is out of the set; the others stay.
	world.call("_on_monster_left", [78603])
	_check(not uniques.has(78603) and uniques.has(78608), "a unique that leaves is dropped from the set")
	world.call("_minimap_fill_monsters", normal_at, INF)
	_check((world.get("_minimap_uniques") as Array).size() == 1 and monsters.size() == 1,
		"and its sign goes with it")
	# No unique loaded: the monster list is every monster, as before.
	world.call("_on_monster_left", [78608])
	_check(uniques.is_empty(), "the set empties")
	world.call("_minimap_fill_monsters", normal_at, INF)
	_check(monsters.size() == 1 and (world.get("_minimap_uniques") as Array).is_empty(),
		"with no unique, the monster sign is unchanged and no unique sign is drawn")
	world.call("_on_monster_left", [78601])
