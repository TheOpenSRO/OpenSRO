extends SceneTree

## Round 653: a click on the sky, or on ground beyond the pick's 1000 units,
## runs the character along the click's heading until a wall stops it
## (SkyRun; World3D._move_by_pick_ray, _start_heading_run, _step_click_walk,
## _move_on_nav_graph). Run headless on the render box:
## `client/tools/remote_godot.sh tests`.
##
## The fixtures are synthetic: a flat collision box for the ground, a camera
## aimed through the screen centre, and a flat two-cell region with one
## blocking edge on the cell boundary at local x = 100.
##
## NEGATIVE: against dev 56e8e24. The clicks go through World3D's own
## `_dispatch_left_click`, which the base has, so the base fails them by
## BEHAVIOUR: a sky click does nothing, and a click on ground 1500 away walks
## to that point. The remote-body check feeds the base its own decoder, which
## drops the heading, so the base aims the body at the position. The rest look
## the new names up before calling them and report FAIL lines on the base.

const TICK := 1.0 / 60.0
const TERRAIN_LAYER := 0b1001 # World3D.TERRAIN_COLLISION_LAYER

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var sr := load("res://scripts/world/sky_run.gd") as GDScript
	_check(sr != null, "SkyRun exists")
	if sr != null:
		_test_rule(sr)
	_test_codec()
	var world := _make_world()
	if world != null:
		await process_frame
		await physics_frame
		await physics_frame
		_check(world.get("player") != null and world.get("camera_3d") != null, "the world has its player and camera")
		await _test_clicks(world)
		await _test_run(world)
		_test_remote(world)
		_test_held_icon_drop(world)
		world.queue_free()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

# --- The rule ------------------------------------------------------------------

func _test_rule(sr: GDScript) -> void:
	_check(is_equal_approx(float(sr.get("PICK_LENGTH")), 1000.0), "the pick reaches 1000 from the camera (READ, 0xd83268)")
	# The ray's ground direction is the heading; y is ignored.
	var h: float = sr.call("heading_of_ray", 0.0, Vector3(1.0, 5.0, 0.0))
	_check(absf(h - PI / 2.0) < 1e-5, "a ray up and toward +x runs on heading pi/2 (%.5f)" % h)
	h = sr.call("heading_of_ray", 1.25, Vector3(0.0, -1.0, 0.0))
	_check(absf(h - 1.25) < 1e-6, "a ray straight down keeps the current heading (FUN_009ed130, 1e-6)")
	# The no-resend window: moving, within 5 degrees, raw difference.
	_check(String(sr.call("click_rule", true, 1.0, 1.0 + 0.08)) == "keep", "moving, 4.6 degrees off the facing: kept, not re-sent")
	_check(String(sr.call("click_rule", true, 1.0, 1.0 + 0.09)) == "run", "moving, 5.2 degrees off: a new run")
	_check(String(sr.call("click_rule", false, 1.0, 1.0)) == "run", "standing, the same heading: a run")
	_check(String(sr.call("click_rule", true, 0.02, TAU - 0.02)) == "run",
		"the difference is raw, as retail's (fsub, no wrap): across the 0/2pi seam it is re-sent")
	# The wire angle and its inverse.
	_check(int(sr.call("wire_angle", RemoteFacing.WIRE_QUARTER_TURN)) == 0, "heading pi/2 (the float32 0xe1b8f0) is wire angle 0 (h - pi/2)")
	_check(int(sr.call("wire_angle", PI)) == 16384, "heading pi is wire angle 16384 (round 16383.75)")
	var worst := 0.0
	for i in range(64):
		var hh := TAU * float(i) / 64.0
		var back := RemoteFacing.from_wire_angle(int(sr.call("wire_angle", hh)))
		var d := absf(back - hh)
		worst = maxf(worst, minf(d, TAU - d))
	_check(worst < 1e-3, "RemoteFacing.from_wire_angle inverts it (worst %.6f rad)" % worst)
	# The run's velocity: the full speed on the heading, at any /speed.
	for speed in [50.0, 200.0, 500.0]:
		var v: Vector2 = sr.call("velocity", PI / 2.0, speed)
		_check(absf(v.x - speed) < 1e-3 and absf(v.y) < 1e-3, "at %.0f u/s the run steps the full speed along its heading (%s)" % [speed, str(v)])

func _test_codec() -> void:
	var wn := load("res://scripts/net/world.gd") as GDScript
	var enc: PackedByteArray = wn.call("encode_move", 1.0, 2.0, 3.0)
	_check(enc.size() == 12, "a walked position is still 12 bytes (%d)" % enc.size())
	var ok := true
	var run: PackedByteArray = PackedByteArray()
	if (wn.get_script_method_list().filter(func(m): return m["name"] == "encode_move")[0]["args"] as Array).size() >= 5:
		run = wn.call("encode_move", 1.0, 2.0, 3.0, false, 0x4000)
	else:
		ok = false
	_check(ok and run.size() == 17 and run[12] == 2 and run[13] == 0 and run[14] == 1 and run.decode_u16(15) == 0x4000,
		"a run's position carries flags bit 1 and retail's heading form: kind 0, command 1, the u16 angle (%s)" % str(run))
	# The relay's decode.
	var moved := PackedByteArray()
	moved.resize(20)
	moved.encode_s64(0, 7)
	moved.encode_float(8, 1.0)
	moved.append_array(PackedByteArray([2, 0, 1, 0x00, 0x40]))
	var m = wn.call("decode_entity_moved", moved)
	_check(m != null and "heading_wire" in m and int(m.get("heading_wire")) == 0x4000 and not bool(m.get("relocated")),
		"EntityMoved's heading form decodes to heading_wire 0x4000")

# --- The world -----------------------------------------------------------------

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
	# The ground: a flat box 4000 wide on the terrain layer, its top at y 0.
	var ground := StaticBody3D.new()
	ground.collision_layer = TERRAIN_LAYER
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000.0, 1.0, 4000.0)
	shape.shape = box
	ground.add_child(shape)
	ground.position = Vector3(0.0, -0.5, 0.0)
	root.add_child(ground)
	return world

## Aims the world's camera from `eye` at `at` and clicks the screen centre
## through World3D's own left-click dispatch. Returns what it answered.
func _click_toward(world: Node, eye: Vector3, at: Vector3) -> String:
	var cam: Camera3D = world.get("camera_3d")
	cam.current = true
	cam.global_position = eye
	cam.look_at(at, Vector3.UP if absf((at - eye).normalized().y) < 0.99 else Vector3.FORWARD)
	var centre := cam.get_viewport().get_visible_rect().size / 2.0
	return String(world.call("_dispatch_left_click", centre))

## A World3D property the base may not have: false / NAN when absent, so the
## base reports FAIL lines instead of a script error.
func _flag(world: Node, name: String) -> bool:
	return name in world and bool(world.get(name))

func _num(world: Node, name: String) -> float:
	return float(world.get(name)) if name in world else NAN

func _reset(world: Node) -> void:
	var player: CharacterBody3D = world.get("player")
	player.global_position = Vector3.ZERO
	player.rotation.y = 0.0
	player.velocity = Vector3.ZERO
	world.set("_has_move_target", false)
	world.set("_player_move_order", false)
	world.set("_move_target", Vector3.ZERO)
	world.set("_player_turn_target", NAN)
	if "_move_heading_run" in world:
		world.set("_move_heading_run", false)

func _test_clicks(world: Node) -> void:
	var eye := Vector3(0.0, 30.0, 0.0)
	# Ground 800 away: inside the pick, a walk to the point.
	_reset(world)
	_click_toward(world, eye, Vector3(0.0, 0.0, -800.0))
	var mt: Vector3 = world.get("_move_target")
	_check(bool(world.get("_has_move_target")) and not _flag(world, "_move_heading_run") and mt.distance_to(Vector3(0.0, 0.0, -800.0)) < 2.0,
		"a click on ground 800 away walks to it (target %s)" % str(mt))
	# Ground 1500 away: beyond the pick's 1000 -- retail runs on the heading.
	_reset(world)
	_click_toward(world, eye, Vector3(0.0, 0.0, -1500.0))
	mt = world.get("_move_target")
	_check(bool(world.get("_has_move_target")) and _flag(world, "_move_heading_run") and absf(_num(world, "_move_heading") - PI) < 1e-3,
		"a click on ground 1500 away (beyond the pick's 1000) runs on its heading, pi, rather than walking to the point (order %s, run %s, target %s)" % [
			str(world.get("_has_move_target")), str(_flag(world, "_move_heading_run")), str(mt)])
	# The sky: nothing under the ray at all.
	_reset(world)
	_click_toward(world, eye, Vector3(1000.0, 90.0, 0.0))
	_check(bool(world.get("_has_move_target")) and _flag(world, "_move_heading_run") and absf(_num(world, "_move_heading") - PI / 2.0) < 1e-3,
		"a click on the sky runs the character on the ray's ground heading, pi/2 (order %s, run %s, heading %s)" % [
			str(world.get("_has_move_target")), str(_flag(world, "_move_heading_run")), str(_num(world, "_move_heading"))])
	if not world.has_method("_start_heading_run"):
		return
	# Moving, a second sky click within 5 degrees of the facing is kept.
	var player: CharacterBody3D = world.get("player")
	player.rotation.y = RemoteFacing.yaw_of(PI / 2.0, 0.0)
	var r := String(world.call("_start_heading_run", Vector3(1.0, 0.2, 0.06)))
	_check(r == "keep" and absf(_num(world, "_move_heading") - PI / 2.0) < 1e-6, "running, a sky click 3.4 degrees off the facing changes nothing (%s)" % r)
	r = String(world.call("_start_heading_run", Vector3(1.0, 0.2, 1.0)))
	_check(r == "run" and absf(_num(world, "_move_heading") - PI / 4.0) < 1e-3, "running, one 45 degrees off starts a new run on it (%s, %.4f)" % [r, _num(world, "_move_heading")])
	# Round 653's review: retail keeps the run only when the move kind is
	# not a walk (+0x6e8 != 1). A sky click within 5 degrees of the facing
	# during a ground WALK starts a run.
	world.set("_move_heading_run", false)
	world.set("_has_move_target", true)
	player.rotation.y = RemoteFacing.yaw_of(PI / 2.0, 0.0)
	r = String(world.call("_start_heading_run", Vector3(1.0, 0.2, 0.06)))
	_check(r == "run" and _flag(world, "_move_heading_run"),
		"walking to a point, a sky click 3.4 degrees off the facing starts a run (+0x6e8 == 1 is not kept) (%s)" % r)
	# A sky click and a ground click each drop a pending pick-up walk.
	world.set("_pending_pickup_id", 7)
	world.call("_start_heading_run", Vector3(-1.0, 0.2, 0.0))
	_check(int(world.get("_pending_pickup_id")) == -1, "a sky click drops a pending pick-up")
	world.set("_pending_pickup_id", 7)
	_click_toward(world, eye, Vector3(0.0, 0.0, -800.0))
	_check(int(world.get("_pending_pickup_id")) == -1, "and so does a ground click")
	world.set("_pending_pickup_id", -1)
	# An accepted zone change or teleport ends the run.
	world.set("_has_move_target", true)
	world.set("_move_heading_run", true)
	player.velocity = Vector3(50.0, 0.0, 0.0)
	world.call("_end_move_order_for_arrival")
	var zsrc := (load("res://scripts/World3D.gd") as GDScript).source_code
	var zbody := zsrc.substr(zsrc.find("func _on_change_zone_result"), 2500)
	_check(not bool(world.get("_has_move_target")) and not _flag(world, "_move_heading_run") and player.velocity.x == 0.0
		and zbody.find("_end_move_order_for_arrival()") != -1,
		"an accepted zone change or teleport ends the run (_on_change_zone_result -> _end_move_order_for_arrival)")
	# Running off the loaded world: no graph and no ground ahead ends the run;
	# ground ahead does not.
	for case in [[Vector3(0.0, 0.0, 0.0), false], [Vector3(2010.5, 0.0, 0.0), true]]:
		player.global_position = case[0]
		player.rotation.y = 0.0
		world.set("_has_move_target", false)
		world.set("_move_speed", 50.0)
		world.call("_start_heading_run", Vector3(1.0, 0.2, 0.0))
		world.call("_step_click_walk", TICK)
		var ended := bool(world.call("_end_run_off_world", TICK))
		_check(ended == bool(case[1]) and bool(world.get("_has_move_target")) != bool(case[1]),
			"a run at x %.1f with %s ahead %s" % [(case[0] as Vector3).x, "no ground" if case[1] else "ground",
				"ends there" if case[1] else "goes on"])
	world.set("_has_move_target", false)
	world.set("_move_heading_run", false)
	player.global_position = Vector3.ZERO
	# A ground click ends the run: the order is the point.
	_click_toward(world, eye, Vector3(0.0, 0.0, -800.0))
	_check(bool(world.get("_has_move_target")) and not _flag(world, "_move_heading_run"),
		"a ground click during a run walks to the point instead")
	# An attack's approach ends it too (the approach sets its own point).
	world.set("_move_heading_run", true)
	var mbody := Node3D.new()
	(world.get("_monster_bodies") as Dictionary)[5] = mbody
	(world.get("_monster_snapshots") as Dictionary)[5] = {"x": 0.0, "z": 300.0}
	world.set("_pending_attack", {"monster": 5, "stop": 2.0, "reach": 3.0})
	world.call("_step_pending_attack")
	_check(bool(world.get("_has_move_target")) and not _flag(world, "_move_heading_run"),
		"an attack's approach replaces the run with its own point")
	world.set("_pending_attack", {})
	(world.get("_monster_bodies") as Dictionary).erase(5)
	(world.get("_monster_snapshots") as Dictionary).erase(5)
	mbody.free()
	_reset(world)

## A flat synthetic region of two cells split at local x = 100, with a
## blocking edge (flag 2) on that boundary from z 0 to 200 -- the shape a
## real region has, where a blocking edge is a cell boundary (the fixture of
## ghost_walk_review_test.gd). The no-slide stop moves the crossing toward
## the centre of the cell the mover is in, so the mover's cell must be on its
## side of the edge, as it is in real data.
func _walled_graph() -> NavGraph:
	var r := NvmReader.ParsedRegion.new()
	r.heights.resize(NvmReader.HEIGHT_COUNT)
	r.heights.fill(0.0)
	for rect in [[Vector2.ZERO, Vector2(100.0, 1920.0)], [Vector2(100.0, 0.0), Vector2(1920.0, 1920.0)]]:
		var cell := NvmReader.Cell.new()
		cell.rect_min = rect[0]
		cell.rect_max = rect[1]
		r.cells.append(cell)
	for i in range(NvmReader.TILE_COUNT):
		var t := NvmReader.Tile.new()
		t.cell_index = 1 if (i % NvmReader.TILE_MAP_SIDE) * NavGraph.TILE_SIZE >= 100.0 else 0
		r.tiles.append(t)
	var e := NvmReader.Edge.new()
	e.flags = 2
	e.line_min = Vector2(100.0, 0.0)
	e.line_max = Vector2(100.0, 200.0)
	r.internal_edges = [e]
	return NavGraph.build(r, [] as Array[NavGraph.PlacedObject])

## Runs World3D's own tick (_step_click_walk, then _move_on_nav_graph) for up
## to `ticks` ticks on a heading run from `from` along `dir`. Returns
## [ticks run with the order in effect, final position, the order still on].
func _run_from(world: Node, from: Vector3, dir: Vector3, speed: float, ticks: int) -> Array:
	var player: CharacterBody3D = world.get("player")
	player.global_position = from
	player.rotation.y = 0.0
	world.set("_nav_footing_pos", Vector3.INF)
	world.set("_move_speed", speed)
	world.set("_has_move_target", false)
	world.call("_start_heading_run", dir)
	var n := 0
	for i in range(ticks):
		if not bool(world.get("_has_move_target")):
			break
		world.call("_step_click_walk", TICK)
		world.call("_move_on_nav_graph", TICK)
		world.call("_step_local_turn", TICK)
		n += 1
	return [n, player.global_position, bool(world.get("_has_move_target"))]

func _test_run(world: Node) -> void:
	if not world.has_method("_start_heading_run"):
		_check(false, "World3D._start_heading_run exists (the run)")
		return
	var player: CharacterBody3D = world.get("player")
	var group := Node3D.new()
	root.add_child(group)
	await process_frame
	var grid = world.get("_grid")
	grid.call("add_nav_graph", 0, 0, _walled_graph(), group)
	# Open ground: it runs, and goes on running -- no destination ends it.
	var open := _run_from(world, Vector3(200.0, 0.0, 1000.0), Vector3(1.0, 0.3, 0.0), 50.0, 600)
	var op: Vector3 = open[1]
	_check(bool(open[2]) and int(open[0]) == 600 and absf(op.x - 700.0) < 0.5 and absf(op.z - 1000.0) < 1e-3,
		"on open ground a run at 50 u/s is still running after 10 s, 500 units on its heading (x %.2f, z %.3f)" % [op.x, op.z])
	# Its facing has turned to the heading (3 pi rad/s, well within 10 s).
	var facing := RemoteFacing.heading_of_yaw(player.rotation.y, 0.0)
	_check(absf(facing - PI / 2.0) < 1e-3, "and the body faces the run's heading (%.4f)" % facing)
	# Straight into the wall, at /speed 1, 4 and 10: it stops there.
	for speed in [50.0, 200.0, 500.0]:
		var s := _run_from(world, Vector3(90.0, 0.0, 100.0), Vector3(1.0, 0.3, 0.0), speed, 240)
		var sp: Vector3 = s[1]
		var need := int(ceil(10.0 / (speed * TICK))) + 1
		_check(not bool(s[2]) and sp.x < 100.0 and sp.x > 99.0 and int(s[0]) <= need,
			"a run at %.0f u/s into a blocking edge stops at it (%d ticks, x %.3f, order %s)" % [speed, int(s[0]), sp.x, str(s[2])])
	# Oblique: retail's mover does not slide -- it stops at first contact,
	# where a click walk (round 649) slides on along the edge.
	var o := _run_from(world, Vector3(90.0, 0.0, 100.0), Vector3(1.0, 0.0, 1.0), 50.0, 600)
	var opos: Vector3 = o[1]
	_check(not bool(o[2]) and opos.x < 100.0 and opos.z < 111.0,
		"an oblique run stops where it meets the edge, not sliding along it (x %.3f, z %.3f, %d ticks)" % [opos.x, opos.z, int(o[0])])
	world.set("_has_move_target", false)
	world.set("_move_heading_run", false)
	group.queue_free()

## Another player on a heading run: the body faces the run's heading, not the
## position it is sent to.
func _test_remote(world: Node) -> void:
	var body := Node3D.new()
	world.add_child(body)
	var bodies: Dictionary = world.get("_other_bodies")
	bodies[77] = body
	var wn := load("res://scripts/net/world.gd") as GDScript
	var moved := PackedByteArray()
	moved.resize(20)
	moved.encode_s64(0, 77)
	moved.encode_float(8, 0.0)
	moved.encode_float(12, 0.0)
	moved.encode_float(16, 20.0) # the next position: +z, heading 0
	var wire := 0 # heading pi/2, +x
	moved.append_array(PackedByteArray([2, 0, 1, wire & 0xff, (wire >> 8) & 0xff]))
	world.call("_on_entity_moved", wn.call("decode_entity_moved", moved))
	var turns: Dictionary = world.get("_remote_turns")
	var t: Dictionary = turns.get(body.get_instance_id(), {})
	var target := float(t.get("target", -1.0))
	_check(absf(target - PI / 2.0) < 1e-3, "a remote heading run turns the body to the run's heading pi/2, not toward its next position (target %.4f)" % target)
	bodies.erase(77)
	turns.erase(body.get_instance_id())
	body.queue_free()

## Round 652's held icon put down on the world is the icon's drop, not a
## move: HudPanels swallows the click (HeldIcon.handle) and hands it to
## _on_held_dropped_outside, which neither walks nor runs.
func _test_held_icon_drop(world: Node) -> void:
	_reset(world)
	var held := HeldIcon.new()
	root.add_child(held)
	held.pick_up({"kind": "worn", "slot": 1}, null, null, Vector2.ZERO)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	var took_press := held.handle(press)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	var took_release := held.handle(release)
	world.call("_on_held_dropped_outside", {"kind": "worn", "slot": 1}, Vector2(10.0, 10.0))
	_check(took_press and took_release and not bool(world.get("_has_move_target")),
		"a click while holding an icon is the icon's (press %s, release %s) and starts no run or walk" % [str(took_press), str(took_release)])
	held.queue_free()
