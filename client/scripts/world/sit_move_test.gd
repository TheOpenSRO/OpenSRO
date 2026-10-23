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
		_test_plate_layout(world)
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

## Round 811: a suited plate as the original lays out a title (FUN_009d0a80):
## title and name centred together, 2 px + the title's space apart, the box
## under both, the title's shadow 1 px right and down, the mark 16 px clear
## of the name; the box READ black at 64/255.
func _test_plate_layout(world: Node) -> void:
	var body := Node3D.new()
	world.add_child(body)
	var plate := Label3D.new()
	plate.name = "Name"
	plate.text = "*Merchy"
	body.add_child(plate)
	world.call("_retail_plate_look", plate, Color.WHITE)
	_check(plate.modulate == Color.WHITE and plate.outline_size == 0 and plate.font_size == UiBuilder.FONT_SIZES[0] * int(FontOversampling.factor())
		and bool(plate.get_meta(NamePlates.BOX_META, false)), "a player's plate is the original's: white, no outline, font 0, on its box")
	var box := plate.get_node_or_null("NameBox") as Sprite3D
	_check(box != null and is_equal_approx(box.modulate.a, 64.0 / 255.0), "the box is black at 64/255")
	var title := Label3D.new()
	title.name = "JobTitle"
	title.text = "Amateur Trader"
	world.call("_retail_plate_look", title, Color.YELLOW, false)
	var shadow := Label3D.new()
	shadow.name = "Shadow"
	title.add_child(shadow)
	body.add_child(title)
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	var mark := Sprite3D.new()
	mark.name = "JobMark"
	mark.texture = ImageTexture.create_from_image(img)
	body.add_child(mark)
	world.call("_layout_job_decor", plate, body)
	var fk := FontOversampling.factor()
	var name_w := float(world.call("_plate_text_width", plate, plate.text))
	var title_w := float(world.call("_plate_text_width", title, title.text))
	var space := float(world.call("_plate_text_width", title, " "))
	var t_left := title.offset.x - title_w * 0.5
	var n_left := plate.offset.x - name_w * 0.5
	var n_right := plate.offset.x + name_w * 0.5
	_check(is_equal_approx(t_left, -n_right), "title and name are centred together on the point (%.1f .. %.1f)" % [t_left, n_right])
	_check(is_equal_approx(n_left - (title.offset.x + title_w * 0.5), space + 2.0 * fk), "the name starts the title's space + 2 px after it")
	var r := NamePlates.box_rect(plate)
	_check(absf(r.position.x) < 1.0 and absf(r.size.x - ceilf(title_w + space + 2.0 * fk + name_w + 4.0 * fk)) < 0.01,
		"one box under title and name (%s)" % str(r))
	_check(box.offset.is_equal_approx(r.position), "the NameBox is drawn there")
	_check(shadow.offset.is_equal_approx(title.offset + Vector2(fk, -fk)) and shadow.text == title.text, "the title's shadow is 1 px right and down")
	var mark_x := mark.offset.x * mark.pixel_size / plate.pixel_size
	_check(is_equal_approx(mark_x, n_right + (4.0 + 8.0) * fk), "the mark is 4 px right of the name with a title (%.1f)" % mark_x)
	_check(is_equal_approx(mark.pixel_size * 16.0, plate.pixel_size * fk * 16.0), "and 16 px of the original")
	body.remove_child(title)
	title.free()
	world.call("_layout_job_decor", plate, body)
	mark_x = mark.offset.x * mark.pixel_size / plate.pixel_size
	_check(plate.offset.x == 0.0 and is_equal_approx(mark_x, -(name_w * 0.5 + 12.0 * fk)), "without a title the name is centred and the mark left of it")
	var me := world.get("player") as Node3D
	if me != null:
		_check(world.call("_plate_of_key", "player:-1") == me.get_node_or_null("Name"), "the own selection key finds the own plate")
	_check(world.call("_plate_of_key", "monster:x") == null, "a malformed key finds none")
	body.queue_free()

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
	# Round 810: a rider's plate is the mount's height + 7 over the ground
	# (READ), not over the seat (round 809's, a rider's height too high), and
	# at least COS_SEATED_PLATE over the seat (its `saddle` bone at rest).
	var mount := Node3D.new()
	world.add_child(mount)
	var mskel := Skeleton3D.new()
	mskel.add_bone("root")
	mskel.add_bone("saddle")
	mskel.set_bone_parent(1, 0)
	mskel.set_bone_rest(1, Transform3D(Basis(), Vector3(0, 15.0, 2.0)))
	mskel.reset_bone_poses()
	mount.add_child(mskel)
	var a := SkinnedBsrAssembler.AssembledCharacter.new()
	a.skeleton = mskel
	(world.get("_cos_bodies") as Dictionary)[777] = mount
	(world.get("_cos_assembled") as Dictionary)[777] = a
	mount.set_meta("cos_height", 18.0)
	_check(is_equal_approx(float(world.call("_cos_seat_height", mount)), 15.0), "a mount's seat is its saddle bone's rest height")
	var bare := Node3D.new()
	world.add_child(bare)
	_check(is_zero_approx(float(world.call("_cos_seat_height", bare))), "a mount with no saddle seats at its root")
	var rroot := Node3D.new()
	world.add_child(rroot)
	var rplate := Label3D.new()
	rplate.name = "Name"
	rplate.position.y = 21.5
	rroot.add_child(rplate)
	(world.get("_other_bodies") as Dictionary)[4343] = rroot
	mount.set_meta("cos_height", 20.0)
	world.call("_raise_rider_plate", 4343, mount, true)
	_check(is_equal_approx(rplate.position.y, 27.0), "a rider's plate is the mount's height + 7 over the ground, not over the seat (%.1f)" % rplate.position.y)
	mount.set_meta("cos_height", 1.0)
	world.call("_raise_rider_plate", 4343, mount, true)
	_check(is_equal_approx(rplate.position.y, 26.0), "and never under 11 over the seat (%.1f)" % rplate.position.y)
	world.call("_raise_rider_plate", 4343, mount, false)
	_check(is_equal_approx(rplate.position.y, 21.5), "the dismount puts the plate back")
	(world.get("_other_bodies") as Dictionary).erase(4343)
	rroot.queue_free()
	(world.get("_cos_bodies") as Dictionary).erase(777)
	(world.get("_cos_assembled") as Dictionary).erase(777)
	mount.queue_free()
	bare.queue_free()
	body.queue_free()
