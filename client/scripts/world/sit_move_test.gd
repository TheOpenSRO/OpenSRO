extends SceneTree

## Round 808: a seated player's clicks ask to stand and do nothing else
## (READ: the click 0x78f8d0 and the basic attack 0x791d40 test the sit bit
## and call 0x9d4a20), and a rider's job mark and title ride with its name.
## On a World3D subclass whose frame hooks do nothing and whose
## _request_sit_toggle counts its calls; synthetic nodes, never game data. Run
## headless on the render box: `client/tools/remote_godot.sh tests`.
##
## NEGATIVE (by construction): against v0.1.566 the seated click walks
## (_stand_instead does not exist) and the suite stops at its first check.

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
	if not w3d.get_script_method_list().any(func(m): return m["name"] == "_stand_instead"):
		_check(false, "World3D has the seated click rule (_stand_instead)")
		quit(1)
		return
	var world := _make_world()
	if world != null:
		await process_frame
		await physics_frame
		_test_seated(world)
		_test_plates(world)
		world.queue_free()
		await process_frame
	print("sit_move_test: %s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"var opened: Array = []",
		"var toggles := 0",
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
		"func _request_sit_toggle() -> String:",
		"\ttoggles += 1",
		"\treturn \"counted\"",
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

func _test_seated(world: Node) -> void:
	var player: CharacterBody3D = world.get("player")
	player.global_position = Vector3.ZERO
	var sit: SitState = world.get("_sit")
	sit.sitting = true
	world.set("_has_move_target", false)
	world.call("_try_set_move_target", Vector2(10, 10))
	_check(int(world.get("toggles")) == 1 and not bool(world.get("_has_move_target")),
		"seated, a click on the world asks to stand and walks nowhere")
	var gm: GroundMarkers = world.get("_ground_markers")
	_check(gm == null or not gm.shown, "and places no ring")
	var npc := Node3D.new()
	npc.set_meta("npc_name", "Clerk")
	world.add_child(npc)
	npc.global_position = Vector3(0, 0, -300)
	_check(bool(world.call("_start_talk_approach", npc)) and int(world.get("toggles")) == 2
		and not bool(world.get("_has_move_target")) and (world.get("opened") as Array).is_empty(),
		"an NPC out of reach: stand, no walk, no talk")
	npc.global_position = Vector3(0, 0, -200)
	_check(not bool(world.call("_start_talk_approach", npc)) and int(world.get("toggles")) == 2,
		"an NPC in reach is talked to from the seat (no client test, READ)")
	world.call("_attack_monster", 5)
	_check(int(world.get("toggles")) == 3 and (world.get("_pending_attack") as Dictionary).is_empty(),
		"a basic attack asks to stand instead (0x791d40)")
	# Round 808's follow-up: the arrows spin a seated body, at pi rad/s, and
	# send nothing (the move gate refuses 0x7024 seated).
	player.rotation.y = 0.0
	world.set("_turn_keys", 0x10)
	world.call("_step_arrow_keys", 0.5)
	world.set("_turn_keys", 0)
	_check(absf(absf(player.rotation.y) - PI / 2.0) < 1e-3, "seated, Left turns the body (%.3f rad in 0.5 s)" % player.rotation.y)
	_check(String(world.call("_send_turn_if", 1.0, 0.0)) == "refused", "and its 0x7024 is refused while seated")
	sit.sitting = false
	world.call("_try_set_move_target", Vector2(10, 10))
	_check(int(world.get("toggles")) == 3, "standing, a click asks nothing")
	npc.queue_free()

func _test_plates(world: Node) -> void:
	var body := Node3D.new()
	body.set_meta("character_id", 4242)
	world.add_child(body)
	var plate := Label3D.new()
	plate.name = "Name"
	plate.position = Vector3(0, 21.5, 0)
	body.add_child(plate)
	var mark := Sprite3D.new()
	mark.name = "JobMark"
	mark.position = Vector3(0, 21.5, 0)
	body.add_child(mark)
	var title := Label3D.new()
	title.name = "JobTitle"
	title.position = Vector3(0, 21.5, 0)
	body.add_child(title)
	world.call("_set_plate_y", body, plate, 32.0)
	_check(plate.position.y == 32.0 and mark.position.y == 32.0 and title.position.y == 32.0,
		"a raised plate takes its job mark and title with it")
	var stored: Dictionary = world.get("_rider_plate_y")
	stored[4242] = 21.5
	world.call("_replace_plate_and_click", body, 20.0)
	_check(plate.position.y == 32.0 and mark.position.y == 32.0, "a rider's re-dress leaves its plate over the mount")
	_check(float(stored[4242]) > 20.0 and float(stored[4242]) != 21.5, "and the height to put back at the dismount is the new one")
	stored.erase(4242)
	world.call("_replace_plate_and_click", body, 20.0)
	_check(plate.position.y < 32.0 and is_equal_approx(mark.position.y, plate.position.y) and is_equal_approx(title.position.y, plate.position.y),
		"on foot, a re-dress moves the name and its mark and title together")
	body.queue_free()
