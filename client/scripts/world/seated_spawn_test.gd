extends SceneTree

## Players seated before this client saw them are drawn seated (round 607). Run
## headless on the render box: `client/tools/remote_godot.sh tests`.
##
## Round 607's review measured that a 0x30bf sent right behind the enter-world
## or zone-change result never reached a body: on entry it fired before the
## world scene existed, on a zone change before the new zone's bodies did. The
## state now rides in the result's Seated tail, and World3D._spawn_result_others
## seats the listed players as it spawns them.
##
## What is checked is what a player sees: the body's animation loop. The world
## is World3D.tscn with a subclass (restored_entry_test.gd's pattern) whose
## _ready does nothing, and whose asset hooks hand out a bare Skeleton3D as each
## other player's body and one synthetic two-keyframe clip per action type
## (_build_assembled_character, _body_animation_for) -- so the real
## _spawn_or_update_other registers a stand loop in _animated and the real
## seating swaps it. The zone change runs the real _on_change_zone_result, with
## the loading screen, the zone build and the placement stubbed.
##
## NEGATIVES (round 607's third review): deleting the seating lines in
## _spawn_result_others (gait["sitting"] and the swap to type 14) left the
## earlier version of this suite ALL PASS; here Bram's and Dara's loops stay
## the stand clip. A zone change back on its own spawn loop leaves Dara standing.

var _failures := 0
var _net: Node

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
	_net = root.get_node_or_null("NetClient")
	var world := _make_world()
	if world != null:
		_test_entry(world)
		await _test_zone_change(world)
		_test_stats_while_dead(world)
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
		"var clips: Dictionary = {}",
		"var hp_calls: Array = []",
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
		"func _build_assembled_character(_look: CharacterLook, _body: String = \"\") -> Skeleton3D:",
		"\treturn Skeleton3D.new()",
		"func _body_animation_for(_gender: String, action_type: int, _group: String = \"default\") -> BanReader.ParsedAnimation:",
		"\tif not clips.has(action_type):",
		"\t\tvar a := BanReader.ParsedAnimation.new()",
		"\t\ta.animation_name = \"type%d\" % action_type",
		"\t\ta.duration_ms = 1000",
		"\t\tvar b := BanReader.Bone.new()",
		"\t\tb.keyframes.append(BanReader.Keyframe.new())",
		"\t\tb.keyframes.append(BanReader.Keyframe.new())",
		"\t\ta.bones.append(b)",
		"\t\tclips[action_type] = a",
		"\treturn clips[action_type]",
		"func _body_animation_path(_gender: String, action_type: int, _group: String) -> String:",
		"\treturn \"type%d\" % action_type",
		"func _show_loading_screen(_region_id: int = -1) -> int:",
		"\treturn 0",
		"func _reload_zone_assets(_zone: String, _frame: String = \"\") -> void:",
		"\tpass",
		"func _place_at_zone_spawn(_zone: String) -> bool:",
		"\treturn true",
		"func _drain_initial_load(_started: int, _frames: int = 0) -> void:",
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

## The loop clip _animated drives id's body with, or null.
func _loop_of(world: Node, id: int) -> BanReader.ParsedAnimation:
	var gait: Dictionary = (world.get("_other_gaits") as Dictionary).get(id, {})
	if gait.is_empty():
		return null
	for entry in world.get("_animated"):
		if entry[0] == gait["skeleton"]:
			return entry[1] if entry[4] else (entry[6][1] if entry[6] != null else null)
	return null

func _clip(world: Node, action_type: int) -> BanReader.ParsedAnimation:
	return world.call("_body_animation_for", "", action_type, "default")

func _test_entry(world: Node) -> void:
	var sitting := _clip(world, BsrReader.AnimationEntry.TYPE_SITTING)
	var standing := _clip(world, BsrReader.AnimationEntry.TYPE_STAND)
	world.call("_spawn_result_others", [_snap(42, "Bram"), _snap(43, "Cleo")], [42])
	_check((world.get("_other_gaits") as Dictionary).has(42), "Bram is spawned as an assembled body")
	_check(_loop_of(world, 42) == sitting, "Bram, in the enter-world result's Seated tail, loops the sitting clip (type 14) (got %s)" % _name(_loop_of(world, 42)))
	_check(bool((world.get("_other_gaits") as Dictionary)[42].get("sitting", false)), "and his gait is marked sitting")
	_check(_loop_of(world, 43) == standing, "Cleo, not in it, loops the stand clip (got %s)" % _name(_loop_of(world, 43)))
	var once := false
	for entry in world.get("_animated"):
		if entry[1] == _clip(world, BsrReader.AnimationEntry.TYPE_SIT_DOWN):
			once = true
	_check(not once, "a body drawn seated does not play the sit-down clip")

## The real _on_change_zone_result: the old zone's bodies go, the new zone's
## result spawns Dara seated.
func _test_zone_change(world: Node) -> void:
	var sitting := _clip(world, BsrReader.AnimationEntry.TYPE_SITTING)
	var zone := WorldNet.ChangeZoneResult.new()
	zone.ok = true
	zone.zone = "donwhang"
	zone.others = [_snap(44, "Dara"), _snap(45, "Eun")]
	zone.seated = [44]
	await world.call("_on_change_zone_result", zone)
	var gaits: Dictionary = world.get("_other_gaits")
	_check(not gaits.has(42) and not gaits.has(43), "the old zone's bodies are gone")
	_check(gaits.has(44) and gaits.has(45), "the new zone's players are spawned")
	_check(_loop_of(world, 44) == sitting, "Dara, in the zone-change result's Seated tail, loops the sitting clip (got %s)" % _name(_loop_of(world, 44)))
	_check(_loop_of(world, 45) != sitting, "Eun, not in it, does not")

## Round 607's third review: a regen stats push built before a lethal blow can
## arrive after the death; while dead, a stats reply's HP is not taken.
func _test_stats_while_dead(world: Node) -> void:
	var stats := StatsNet.Stats.new()
	stats.hp = 101
	stats.max_hp = 200
	stats.level = 1
	world.set("_last_enter_world_hp", 0)
	world.set("_player_dead", true)
	world.call("_on_world_stats", stats)
	_check(int(world.get("_last_enter_world_hp")) == 0, "a stats reply while dead does not raise the HP (got %d)" % int(world.get("_last_enter_world_hp")))
	world.set("_player_dead", false)
	world.call("_on_world_stats", stats)
	_check(int(world.get("_last_enter_world_hp")) == 101, "alive, the same reply is taken (got %d)" % int(world.get("_last_enter_world_hp")))

func _name(a: BanReader.ParsedAnimation) -> String:
	return "null" if a == null else a.animation_name
