extends SceneTree

## Round 701: a click on an NPC or a teleport gate out of talk reach walks
## to a point short of it on the line back to the player, puts the ring
## there, and talks on arrival; a monster click selects first and attacks on
## the next click (READ addresses in World3D's TALK_APPROACH_* comment and
## _pick_character). On a World3D subclass whose frame hooks do nothing and
## whose _open_talk records the call; synthetic nodes, never game data. Run
## headless on the render box: `client/tools/remote_godot.sh tests`.
##
## NEGATIVE (by construction): against dev 34286d92 the suite reports one FAIL line and stops
## (talk_needs_approach is not in World3D: every click talked at any range).

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
	var w3d := load("res://scripts/World3D.gd") as GDScript
	if not w3d.get_script_method_list().any(func(m): return m["name"] == "talk_needs_approach"):
		_check(false, "World3D has the talk approach (talk_needs_approach)")
		quit(1)
		return
	_test_rules()
	var world := _make_world()
	if world != null:
		await process_frame
		await physics_frame
		_test_world(world)
		world.queue_free()
		await process_frame
	print("talk_approach_test: %s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)

func _test_rules() -> void:
	var W = load("res://scripts/World3D.gd")
	_check(not W.talk_needs_approach(240.0, false) and W.talk_needs_approach(240.5, false),
		"an NPC: talked to within 240, walked to beyond (READ, double 0xdb9888)")
	_check(not W.talk_needs_approach(800.0, true) and W.talk_needs_approach(800.5, true),
		"a gate: 800 (READ, double 0xd83080)")
	var p: Vector3 = W.talk_approach_point(Vector3(10, 0, 0), Vector3(310, 0, 0), 100.0)
	_check(p.is_equal_approx(Vector3(110, 0, 0)), "the point is d from the target toward the player (%s)" % str(p))
	_check(W.TALK_APPROACH_NEAR == 20.0 and W.TALK_APPROACH_NPC_RANGE == 240.0 and W.TALK_APPROACH_GATE_RANGE == 640.0,
		"the walk's bounds: 20..240 for an NPC, 20..640 for a gate (READ, 0xd88108 / 0xdb9884 / 0xdb9890)")
	_check(not W.monster_click_attacks(false, false, true), "a click on an unselected monster selects it, no attack")
	_check(W.monster_click_attacks(false, true, true), "a click on the selected monster with its target window up attacks")
	_check(not W.monster_click_attacks(false, true, false), "the selection without the target window up does not")
	_check(W.monster_click_attacks(true, false, false), "Ctrl attacks at once (GetKeyState(0x11))")

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"var opened: Array = []",
		"func _ready() -> void:",
		"\tpass",
		"func _physics_process(_delta: float) -> void:",
		"\tpass",
		"func _process(_delta: float) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		"func _open_talk(node: Node) -> void:",
		"\topened.append(node)",
		"var test_tex: Texture2D = ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))",
		"func _marker_texture(_path: String) -> Texture2D:",
		"\treturn test_tex",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	root.add_child(world)
	return world

func _holder(world: Node, at: Vector3, gate: bool) -> Node3D:
	var n := Node3D.new()
	n.set_meta("npc_name", "Gate" if gate else "Clerk")
	if gate:
		n.set_meta("gate_point_id", 7)
	world.add_child(n)
	n.global_position = at
	return n

func _reset(world: Node) -> void:
	var player: CharacterBody3D = world.get("player")
	player.global_position = Vector3.ZERO
	world.set("_has_move_target", false)
	world.set("_player_move_order", false)
	world.set("_move_heading_run", false)
	world.set("_talk_approach", {})
	(world.get("opened") as Array).clear()

func _test_world(world: Node) -> void:
	var player: CharacterBody3D = world.get("player")
	var rng: RandomNumberGenerator = world.get("_talk_rng")
	rng.seed = 701
	_reset(world)
	# In reach: no walk.
	var near := _holder(world, Vector3(0, 0, -200), false)
	_check(not bool(world.call("_start_talk_approach", near)), "an NPC 200 away is talked to where the player stands")
	near.queue_free()
	# Out of reach: the walk, the ring at the point, the talk on arrival.
	var npc := _holder(world, Vector3(0, 0, -300), false)
	_check(bool(world.call("_start_talk_approach", npc)), "an NPC 300 away is walked to first")
	var target: Vector3 = world.get("_move_target")
	var gm: GroundMarkers = world.get("_ground_markers")
	var d := target.distance_to(npc.global_position)
	_check(bool(world.get("_has_move_target")) and absf(target.x) < 1e-4 and target.z < 0.0 and d >= 20.0 - 1e-3 and d <= 240.0 + 1e-3,
		"the walk ends on the line to the player, %.1f short of the NPC (20..240)" % d)
	_check(gm != null and gm.shown and gm.texture_index == 0 and gm.center.distance_to(target) < 1e-3,
		"the ring is at that point with the ground texture, not on the NPC or at the click")
	_check((world.get("opened") as Array).is_empty(), "nothing talks before the arrival")
	world.call("_step_talk_approach")
	_check((world.get("opened") as Array).is_empty(), "nor while walking")
	player.global_position = target
	world.set("_has_move_target", false)
	world.call("_step_talk_approach")
	_check((world.get("opened") as Array).size() == 1 and (world.get("opened") as Array)[0] == npc and (world.get("_talk_approach") as Dictionary).is_empty(),
		"the arrival opens the talk window (READ: FUN_009ec380 -> FUN_0078f5f0)")
	# An arrival short of the server's 300 (a wall ended it): no talk.
	_reset(world)
	world.call("_start_talk_approach", npc)
	player.global_position = Vector3(0, 0, 100)
	world.set("_has_move_target", false)
	world.call("_step_talk_approach")
	_check((world.get("opened") as Array).is_empty(), "a walk that ends 400 away talks to nobody (the server's 300, READ 0x4a8e10)")
	# A new click cancels it.
	_reset(world)
	world.call("_start_talk_approach", npc)
	world.call("_dispatch_left_click", Vector2(10, 10))
	_check((world.get("_talk_approach") as Dictionary).is_empty(), "a new click drops the approach")
	# The target despawning cancels it.
	_reset(world)
	var gone := _holder(world, Vector3(300, 0, 0), false)
	world.call("_start_talk_approach", gone)
	gone.free()
	world.call("_step_talk_approach")
	world.set("_has_move_target", false)
	world.call("_step_talk_approach")
	_check((world.get("opened") as Array).is_empty() and (world.get("_talk_approach") as Dictionary).is_empty(), "the target going drops it, no talk")
	# A gate: 800 and 640.
	_reset(world)
	var gate := _holder(world, Vector3(700, 0, 0), true)
	_check(not bool(world.call("_start_talk_approach", gate)), "a gate 700 away is talked to at once (within 800)")
	gate.global_position = Vector3(900, 0, 0)
	_check(bool(world.call("_start_talk_approach", gate)), "a gate 900 away is walked to")
	target = world.get("_move_target")
	d = target.distance_to(gate.global_position)
	_check(d >= 20.0 - 1e-3 and d <= 640.0 + 1e-3 and target.x > 0.0, "%.1f short of the gate (20..640)" % d)
	# Round 701's review. A typing lock is no arrival: the approach waits and
	# walks on (L4).
	_reset(world)
	world.call("_start_talk_approach", npc)
	var aim: Vector3 = world.get("_move_target")
	world.set("_has_move_target", false)
	world.call("_step_talk_approach", true)
	_check((world.get("opened") as Array).is_empty() and not (world.get("_talk_approach") as Dictionary).is_empty(),
		"a typing lock that stops the walk talks to nobody and keeps the approach")
	world.call("_step_talk_approach", false)
	_check(bool(world.get("_has_move_target")) and (world.get("_move_target") as Vector3).is_equal_approx(aim),
		"the lock lifted, the walk goes on to the same point")
	player.global_position = aim
	world.set("_has_move_target", false)
	world.call("_step_talk_approach", false)
	_check((world.get("opened") as Array).size() == 1, "and the arrival talks")
	# A double click on no monster changes nothing: no second roll (L5).
	_reset(world)
	world.call("_start_talk_approach", npc)
	aim = world.get("_move_target")
	var took: String = world.call("_dispatch_double_click", Vector2(10, 10))
	_check(took == "ignore" and not (world.get("_talk_approach") as Dictionary).is_empty() and (world.get("_move_target") as Vector3).is_equal_approx(aim),
		"a double click's second press on no monster neither re-rolls nor drops the approach (READ: FUN_00792190)")
	# An NPC click moves the selection off a monster; a gate does not (L3).
	world.set("_last_attack_target", 77)
	world.call("_select_for_talk", npc)
	_check(int(world.get("_last_attack_target")) == -1, "talking to an NPC deselects the monster (FUN_00778650)")
	world.set("_last_attack_target", 77)
	world.call("_select_for_talk", gate)
	_check(int(world.get("_last_attack_target")) == 77, "a gate leaves the selection alone")
	# The distance is random over 20..240 (retail's rand()).
	var lo := INF
	var hi := -INF
	for i in 200:
		_reset(world)
		world.call("_start_talk_approach", npc)
		var t: Vector3 = world.get("_move_target")
		var dd := t.distance_to(npc.global_position)
		lo = minf(lo, dd)
		hi = maxf(hi, dd)
	_check(lo >= 20.0 - 1e-3 and hi <= 240.0 + 1e-3 and lo < 40.0 and hi > 220.0, "200 approaches land 20..240 short, spread over it (%.1f..%.1f)" % [lo, hi])
	_reset(world)
