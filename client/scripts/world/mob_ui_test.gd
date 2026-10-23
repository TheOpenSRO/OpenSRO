extends SceneTree

## Round 673: what the user saw over and on monsters, held in the real world
## script. Run headless on the render box: `client/tools/remote_godot.sh tests`.
##
## The world is World3D.tscn with a quiet subclass (monster_draw_test.gd's
## pattern): no archive, no network. The model is SYNTHETIC -- a two-bone
## skeleton handed to the world through its `_monster_assemble` Callable --
## drawn for the code MOB_WC_GUNPOWDERGHOST under its real model path, which
## is only a string here; no game data is read or shipped.
##
## It holds the world to:
## - no bar over a monster's head (the user: "a legacy healthbar above mobs
##   that needs removed");
## - the name plate shown by its owner's distance from the PLAYER, 300 (READ,
##   NamePlates), never cut by its distance from the camera -- a monster 73
##   from the player lost its name looking straight down (round 673's render);
## - a monster of a species the round-533 table did not list turning to its
##   path on a leg and to its target on a blow (the Gun Powder ghosts faced
##   one fixed way on every leg of round 673's live chase).
##
## - the name's look MEASURED from the user's retail screenshot: white, no
##   outline, 12 px, on a black box at alpha 64/255 (READ, round 811), one font pixel one screen
##   pixel x the UI scale;
##
## NEGATIVE, on the base (4104a11): the body carries an "HpBar", the plate's
## visibility_range_end is 80, the world has no plate sweep, and the Gun
## Powder ghost neither starts a turn on its leg nor faces its target.

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
		await _test_monster(world)
		root.remove_child(world)
		world.free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

const CODE := "MOB_WC_GUNPOWDERGHOST"
const MODEL := "mob\\wchina\\gunpowderghost.bsr"

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
	_check(sub.reload() == OK and sub.can_instantiate(), "a quiet subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	world.set("_monster_models_loaded", true)
	world.set("_monster_models_by_code", {CODE: MODEL})
	world.set("_monster_assemble", _synthetic_model)
	root.add_child(world)
	return world

func _synthetic_model(_path: String) -> SkinnedBsrAssembler.AssembledCharacter:
	var skel := Skeleton3D.new()
	skel.add_bone("root")
	skel.add_bone("head")
	skel.set_bone_parent(1, 0)
	skel.set_bone_rest(1, Transform3D(Basis(), Vector3(0.0, 12.0, 0.0)))
	skel.set_bone_pose_position(1, Vector3(0.0, 12.0, 0.0))
	var result := SkinnedBsrAssembler.AssembledCharacter.new()
	result.skeleton = skel
	return result

func _snapshot(id: int, x: float, z: float) -> CombatNet.MonsterSnapshot:
	var snap := CombatNet.MonsterSnapshot.new()
	snap.monster_id = id
	snap.code_name = CODE
	snap.monster_name = "Gun Powder"
	snap.x = x
	snap.y = 0.0
	snap.z = z
	snap.hp = 40
	snap.max_hp = 50
	return snap

## The way the body's model faces in the world: its skeleton's -Z (MonsterMotion).
func _front(body: Node3D) -> Vector2:
	var f := body.global_basis * Vector3(0, 0, -1)
	return Vector2(f.x, f.z).normalized()

func _test_monster(world: Node) -> void:
	var bodies: Dictionary = world.get("_monster_bodies")
	var player := world.get("player") as Node3D
	_check(player != null, "the world has its player node")
	if player == null:
		return
	player.global_position = Vector3.ZERO
	world.call("_sync_monster_bodies", [_snapshot(7001, 60.0, 40.0), _snapshot(7002, 260.0, 220.0)])
	for i in range(5):
		world.call("_pump_monster_builds")
	await process_frame
	_check(bodies.has(7001) and bodies.has(7002), "both monsters have bodies")
	if not bodies.has(7001) or not bodies.has(7002):
		return
	var body: Node3D = bodies[7001]
	var far_body: Node3D = bodies[7002]
	_check(String(body.get_meta("model", "")) == MODEL, "the body is drawn as its model (%s)" % String(body.get_meta("model", "")))

	# 1. No bar over its head.
	_check(body.get_node_or_null("HpBar") == null, "no HP bar hangs over the monster")
	var sprites: Array = []
	for n in body.find_children("*", "Sprite3D", true, false):
		if n.name != "NameBox":
			sprites.append(n)
	_check(sprites.is_empty(), "nothing billboarded but its name (and the name's box) hangs over it (%d other Sprite3D)" % sprites.size())
	# A hit still reaches the snapshot (the target window reads it).
	var damaged := CombatNet.MonsterDamaged.new()
	damaged.monster_id = 7001
	damaged.damage = 10
	damaged.remaining_hp = 30
	world.call("_on_monster_damaged", damaged)
	var snaps: Dictionary = world.get("_monster_snapshots")
	_check((snaps[7001] as CombatNet.MonsterSnapshot).hp == 30, "a hit still updates the monster's health")
	var text_y := float(world.call("_monster_text_height", 7001))
	var label := body.get_node_or_null("Label") as Label3D
	_check(label != null, "the monster has its name plate")
	if label == null:
		return
	_check(absf(text_y - label.position.y * 0.9) < 0.001, "a damage number starts under the name, where the bar sat (%.2f)" % text_y)

	# 1b. The name's look, MEASURED from the user's retail screenshot (round
	# 673): white, no outline, FontIndex 0's 12 px, a black box (alpha READ in round 811)
	# two pixels wider than the text each side and 16 tall; one font pixel one
	# screen pixel (x the UI scale) under the camera.
	_check(label.modulate.is_equal_approx(Color(1, 1, 1)), "the name is white (%s)" % str(label.modulate))
	_check(label.outline_size == 0, "with no outline (%d)" % label.outline_size)
	_check(label.font_size == 12, "at FontIndex 0's 12 px (%d)" % label.font_size)
	var box := label.get_node_or_null("NameBox") as Sprite3D
	_check(box != null, "on a box")
	if box != null:
		# Round 811: the alpha READ (FUN_008b3bd0's 0x40000000), not round 673's measured 0.29.
		_check(is_equal_approx(box.modulate.a, 64.0 / 255.0) and box.modulate.r == 0.0, "the box is black at alpha 64/255 (%s)" % str(box.modulate))
		var font: Font = label.font if label.font != null else ThemeDB.fallback_font
		var text_w := font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x
		var tex := box.texture
		_check(tex != null and tex.get_height() == 16 and absf(float(tex.get_width()) - (text_w + 4.0)) <= 1.0,
			"16 px tall and the text's width + 4 (%s against %.1f)" % [str(tex.get_size()) if tex != null else "none", text_w + 4.0])
		_check(is_equal_approx(box.pixel_size, label.pixel_size), "drawn at the plate's scale")
	var cam0 := world.get_viewport().get_camera_3d()
	if cam0 != null:
		var want := 2.0 * tan(deg_to_rad(cam0.fov) * 0.5) / float(world.get_window().size.y) * world.get_window().content_scale_factor
		_check(absf(label.pixel_size - want) < 1e-7, "one font pixel is one screen pixel x the UI scale (pixel_size %.7f, want %.7f)" % [label.pixel_size, want])

	# 1c. Round 673's review: a party mark follows its plate when the plate is
	# re-sized (a UI-scale change, a resize). Made here as _party_mark makes
	# it (its pixel_size the plate's times its text's line height over 16);
	# the archive's icon is not in this test, so a 16 x 16 stand-in.
	await _test_party_mark_rescale(world, label)

	# 2. The name: by distance from the player, never from the camera.
	_check(label.visibility_range_end == 0.0, "the plate has no camera-distance cut (visibility_range_end %.0f)" % label.visibility_range_end)
	var sweep = world.get("_plate_sweep")
	_check(sweep != null, "the world keeps a plate sweep (NamePlates.Sweep)")
	if sweep != null:
		_test_plates(world, sweep, player, label, far_body.get_node("Label") as Label3D)

	# 2b. Round 673's review: a dropped item's name keeps its own rule (shown
	# only while hovered or Z is held, GroundItems.update_labels); the sweep
	# must not show it.
	_test_ground_item_plate(world, player)

	# 3. Facing: a leg turns it to its path, a blow to its target.
	body.rotation.y = 0.0
	var turns: Dictionary = world.get("_remote_turns")
	var moved := CombatNet.MonsterMoved.new()
	moved.monster_id = 7001
	moved.x = body.position.x
	moved.z = body.position.z
	moved.dest_x = body.position.x + 100.0
	moved.dest_z = body.position.z
	moved.speed = 40.0
	moved.mode = 1
	world.call("_on_monster_moved", moved)
	_check(turns.has(body.get_instance_id()), "a leg starts the Gun Powder ghost's turn toward its path")
	world.call("_step_remote_turns", 1.0)
	var f := _front(body)
	_check(f.dot(Vector2(1, 0)) > 0.999, "and after the turn its model faces along the leg (+x), front (%.3f, %.3f)" % [f.x, f.y])
	world.call("_stop_monster_motion", 7001)
	body.rotation.y = 0.0
	world.call("_face_monster_toward", 7001, Vector2(body.position.x, body.position.z + 50.0))
	f = _front(body)
	_check(f.dot(Vector2(0, 1)) > 0.999, "a blow turns it to face its target (+z), front (%.3f, %.3f)" % [f.x, f.y])
	world.call("_sync_monster_bodies", [])
	await process_frame

func _test_plates(world: Node, sweep, player: Node3D, label: Label3D, far_label: Label3D) -> void:
	sweep.step(player.global_position)
	_check(label.visible, "the name of a monster 72 from the player shows")
	_check(not far_label.visible, "the name of one 340 away does not")
	# Wherever the camera is: put it 2,000 units up, looking straight down.
	var cam := world.get_viewport().get_camera_3d()
	if cam != null:
		cam.global_position = Vector3(0.0, 2000.0, 0.0)
	for i in range(10):
		sweep.step(player.global_position)
	_check(label.visible and not far_label.visible, "and neither changes with the camera 2,000 units away")
	player.global_position = Vector3(200.0, 0.0, 200.0)
	for i in range(10):
		sweep.step(player.global_position)
	_check(far_label.visible, "the far monster's name shows once the player comes within 300")
	world.call("set_name_plate_range", 50.0)
	sweep.step(player.global_position)
	_check(not far_label.visible, "the debug slider's range applies at once (63 > 50)")
	world.call("set_name_plate_range", 300.0)
	player.global_position = Vector3.ZERO

func _test_party_mark_rescale(world: Node, label: Label3D) -> void:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var mark := Sprite3D.new()
	mark.name = "PartyMark"
	mark.texture = ImageTexture.create_from_image(img)
	var font: Font = label.font if label.font != null else ThemeDB.fallback_font
	var k := font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).y / 16.0
	mark.pixel_size = label.pixel_size * k
	label.add_child(mark)
	var window := world.get_window()
	var was := window.content_scale_factor
	window.content_scale_factor = 2.0
	world.call("_step_monster_plate_scale")
	var plate_now := label.pixel_size
	_check(plate_now > 0.0 and absf(mark.pixel_size - plate_now * k) < 1e-7,
		"at UI scale 2 the party mark is re-sized with its plate (mark %.7f, want %.7f)" % [mark.pixel_size, plate_now * k])
	window.content_scale_factor = was
	world.call("_step_monster_plate_scale")
	_check(absf(mark.pixel_size - label.pixel_size * k) < 1e-7, "and back at the old scale with it")
	label.remove_child(mark)
	mark.free()
	await process_frame

func _test_ground_item_plate(world: Node, player: Node3D) -> void:
	world.set("_data_pk2", Pk2Reader.new())
	world.call("_try_setup_ground_items")
	var items = world.get("_ground_items")
	_check(items != null, "the world sets up its ground items")
	if items == null:
		return
	var snap := GroundItemsNet.Snapshot.new()
	snap.id = 1
	snap.gold = true
	snap.quantity = 50
	snap.x = player.global_position.x + 20.0
	snap.y = player.global_position.y
	snap.z = player.global_position.z
	items.spawn(snap)
	var body := (items as Node).get_node_or_null("GroundItem_1") as Node3D
	var label := body.get_node_or_null("Label") as Label3D if body != null else null
	_check(label != null, "a dropped gold stack has a name plate")
	if label == null:
		return
	var sweep = world.get("_plate_sweep")
	var shown := 0
	for i in range(60):
		# Not hovered, Z not held: the item's own rule hides it every frame,
		# then the frame's plate sweep runs (World3D's order).
		items.update_labels(player.global_position, 0.0, -1)
		if sweep != null:
			sweep.step(player.global_position)
		if label.visible:
			shown += 1
	_check(shown == 0, "an item's name not hovered stays hidden across the plate sweep (visible after %d of 60 frames)" % shown)
	items.update_labels(player.global_position, 0.0, 1)
	if sweep != null:
		sweep.step(player.global_position)
	_check(label.visible, "and shows when hovered")
	(items as Node).get_parent().remove_child(items)
	(items as Node).free()
	world.set("_ground_items", null)
	world.set("_data_pk2", null)
