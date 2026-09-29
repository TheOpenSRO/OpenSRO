extends SceneTree

## Round 637: another player's and a monster's body turn to face where they
## go, at the client's own rate (RemoteFacing, World3D._aim_remote_body /
## _step_remote_turns). Run headless on the render box:
## `client/tools/remote_godot.sh tests`.
##
## Everything under test is READ from sro_client.exe (RemoteFacing's own doc):
## the heading of a vector (FUN_009ed130), the turn (FUN_009e02f0) and its rate,
## 9.42477798461914 / 1000 radians a millisecond (.rdata 0xde3128 / 0xd83268).
## The fixtures are synthetic.
##
## NEGATIVE: against dev 5a82339 the World3D checks fail -- another player's
## body never turned (OpEntityMoved moved only its walk target) and a
## monster's snapped round at once. RemoteFacing is loaded by path so this
## file still compiles there.
##
## Review follow-up (the second negative, against 56840cb, round 637's first
## commit): the spawn's wire angle, the player's own click rule and turn, a
## relocation that places without turning, a stop that snaps and ends a turn,
## and a bare snap that leaves one running. Every new name is looked up
## before it is called, so the older commits report FAIL lines rather than a
## script error.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var rf := load("res://scripts/world/remote_facing.gd") as GDScript
	_check(rf != null, "RemoteFacing exists")
	if rf != null:
		_test_heading(rf)
		_test_turn(rf)
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var world_ok := world_script != null and world_script.can_instantiate()
	_check(world_ok, "World3D compiles")
	if rf != null:
		_test_wire_and_click(rf)
	if world_ok:
		_test_other_player(world_script)
		_test_monster(world_script)
		_test_review_paths(world_script)
		_test_local_player(world_script)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## FUN_009ed130: world +z is heading 0, +x is pi/2 (the client's facing is
## (sin h, 0, -cos h) region-local, and the region group mirrors z), and a
## vector no longer than 1e-6 keeps the heading it had.
func _test_heading(rf: GDScript) -> void:
	var cases := [[Vector3(0, 0, 1), 0.0], [Vector3(1, 0, 0), PI / 2.0], [Vector3(0, 0, -1), PI],
		[Vector3(-1, 0, 0), 1.5 * PI], [Vector3(3, 0, 3), PI / 4.0], [Vector3(-2, 0, 2), 1.75 * PI],
		[Vector3(0, 7, 1), 0.0]]
	for c in cases:
		var h: float = rf.heading_toward(9.0, c[0])
		_check(is_equal_approx(h, float(c[1])), "the heading of %s is %.4f (got %.4f)" % [str(c[0]), float(c[1]), h])
	_check(rf.heading_toward(1.25, Vector3(5e-7, 0, 5e-7)) == 1.25, "a vector of 1e-6 or less keeps the heading (FUN_009ed130's early return)")
	# The client's own facing of the heading, (sin h, -cos h) region-local,
	# mirrored into the world (z -> -z), is the direction the heading came
	# from -- and it is where a node with rotation.y = h points its +Z.
	for d in [Vector3(1, 0, 2), Vector3(-3, 0, 1), Vector3(-1, 0, -4), Vector3(2, 0, -2)]:
		var h: float = rf.heading_toward(0.0, d)
		var local := Vector2(sin(h), -cos(h))
		var world := Vector2(local.x, -local.y)
		var want := Vector2(d.x, d.z).normalized()
		var node_z := Basis(Vector3.UP, rf.yaw_of(h, 0.0)) * Vector3(0, 0, 1)
		_check(world.is_equal_approx(want) and Vector2(node_z.x, node_z.z).is_equal_approx(want),
			"heading %.3f faces %s in the client's frame and on the node (got %s, %s)" % [h, str(want), str(world), str(node_z)])
	_check(absf(float(rf.get_script_constant_map()["TURN_RATE_PER_SECOND"]) - 3.0 * PI) < 1e-6,
		"the turn rate is 3 pi at float precision (0xde3128)")

## FUN_009e02f0: the shorter way round, TURN_RATE_PER_SECOND, and the target
## once the step would pass it.
func _test_turn(rf: GDScript) -> void:
	var r: Dictionary = rf.turn(0.0, PI / 2.0, 0.0)
	_check(bool(r["turning"]) and float(r["heading"]) == 0.0, "a call with no time starts the turn and moves nothing (the mover's own call)")
	r = rf.turn(0.0, PI / 2.0, 100.0)
	_check(bool(r["turning"]) and is_equal_approx(float(r["heading"]), 0.942477798461914),
		"100 ms turns 0.9425 rad toward the target (got %.5f)" % float(r["heading"]))
	r = rf.turn(0.0, PI, 333.0)
	_check(bool(r["turning"]), "a half turn is not over at 333 ms")
	r = rf.turn(0.0, PI, 334.0)
	_check(not bool(r["turning"]) and is_equal_approx(float(r["heading"]), PI), "and is over at 334 ms, on the target")
	# The shorter way: from 0.1 to 2 pi - 0.1 turns down through 0.
	r = rf.turn(0.1, TAU - 0.1, 5.0)
	_check(is_equal_approx(float(r["heading"]), 0.1 - 0.04712388992309570), "from 0.1 to 2pi-0.1 turns down (got %.5f)" % float(r["heading"]))
	r = rf.turn(0.02, TAU - 0.1, 5.0)
	_check(is_equal_approx(float(r["heading"]), TAU + 0.02 - 0.04712388992309570), "and wraps into [0, 2pi) (got %.5f)" % float(r["heading"]))
	r = rf.turn(TAU - 0.1, 0.1, 5.0)
	_check(is_equal_approx(float(r["heading"]), TAU - 0.1 + 0.04712388992309570), "from 2pi-0.1 to 0.1 turns up (got %.5f)" % float(r["heading"]))
	# Exactly half a turn: d = pi is not more than pi, so the sign of
	# target - current decides.
	_check(float(rf.turn(0.0, PI, 10.0)["heading"]) > 0.0, "0 -> pi turns up")
	_check(float(rf.turn(PI, 0.0, 10.0)["heading"]) < PI, "pi -> 0 turns down")

## The model's front, world (x, z): the player body's front is its skeleton's
## -Z and World3D turns that skeleton PI inside the body node.
func _player_front(body: Node3D) -> Vector2:
	var skel: Node3D = body.get_child(0)
	var f := body.transform.basis * skel.transform.basis * Vector3(0, 0, -1)
	return Vector2(f.x, f.z)

func _deg(v: Vector2) -> float:
	return rad_to_deg(atan2(v.x, v.y))

func _moved(id: int, x: float, z: float) -> WorldNet.EntityMoved:
	var m := WorldNet.EntityMoved.new()
	m.character_id = id
	m.x = x
	m.y = 0.0
	m.z = z
	return m

## Another player's body, stepped at 60 frames a second the way _physics_step
## steps it (the position lerp is World3D's; the turn is the one under test).
func _test_other_player(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var has_step := world.has_method("_step_remote_turns")
	_check(has_step, "World3D steps remote turns each frame")
	var body := Node3D.new()
	var skel := Node3D.new()
	skel.rotation.y = PI
	body.add_child(skel)
	(world.get("_other_bodies") as Dictionary)[5] = body
	(world.get("_other_body_targets") as Dictionary)[5] = Vector3.ZERO
	var frame := 1.0 / 60.0
	# Eight directions, each walked for a second: the front ends along the
	# movement, whatever way it faced before.
	var dirs := [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1),
		Vector2(1, 1), Vector2(-1, -1), Vector2(-1, 1), Vector2(1, -1)]
	var worst := 0.0
	for d in dirs:
		var dir: Vector2 = (d as Vector2).normalized()
		for i in range(60):
			var at := body.position + Vector3(dir.x, 0, dir.y) * 2.5
			world.call("_on_entity_moved", _moved(5, at.x, at.z))
			body.position = body.position.lerp(at, 0.25)
			if has_step:
				world.call("_step_remote_turns", frame)
		worst = maxf(worst, absf(wrapf(_deg(_player_front(body)) - _deg(dir), -180.0, 180.0)))
	_check(worst < 0.01, "after walking each of 8 directions the body faces its movement (worst %.2f deg)" % worst)
	# A half turn takes a third of a second: 10 frames in, the body is side-on.
	var facing_before := _player_front(body)
	var back := -facing_before
	var at2 := body.position + Vector3(back.x, 0, back.y) * 2.5
	world.call("_on_entity_moved", _moved(5, at2.x, at2.z))
	for i in range(10):
		if has_step:
			world.call("_step_remote_turns", frame)
	var mid := absf(wrapf(_deg(_player_front(body)) - _deg(facing_before), -180.0, 180.0))
	_check(absf(mid - 90.0) < 1.0, "10 frames into a half turn it has turned 90 deg, at 3 pi rad/s (got %.2f)" % mid)
	for i in range(11):
		if has_step:
			world.call("_step_remote_turns", frame)
	var done := absf(wrapf(_deg(_player_front(body)) - _deg(back), -180.0, 180.0))
	_check(done < 0.01, "21 frames (0.35 s) in it faces the new way (off by %.2f deg)" % done)
	# Stopping: no more positions, the facing stays.
	var yaw := body.rotation.y
	for i in range(60):
		if has_step:
			world.call("_step_remote_turns", frame)
	_check(body.rotation.y == yaw, "a body that stops keeps its last facing")
	# A position on the body itself has no heading and changes nothing.
	world.call("_on_entity_moved", _moved(5, body.position.x, body.position.z))
	if has_step:
		world.call("_step_remote_turns", frame)
	_check(is_equal_approx(body.rotation.y, yaw), "a position on the body itself leaves the facing")
	body.free()
	world.free()

## A monster's leg: the body is turned toward its destination at the same
## rate, not snapped (the Mangyang model's front is -Z, MonsterMotion).
func _test_monster(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var has_step := world.has_method("_step_remote_turns")
	var body := Node3D.new()
	body.position = Vector3(100, 0, -200)
	body.set_meta("model", "mob\\china\\mangnyang.bsr")
	# Facing world +z to start with: yaw PI puts the -Z front at +z.
	body.rotation.y = PI
	(world.get("_monster_bodies") as Dictionary)[7] = body
	var m := CombatNet.MonsterMoved.new()
	m.monster_id = 7
	m.x = 100
	m.z = -200
	m.dest_x = 140
	m.dest_z = -200
	m.speed = 8.0
	world.call("_on_monster_moved", m)
	var front := Basis(Vector3.UP, body.rotation.y) * Vector3(0, 0, -1)
	_check(absf(_deg(Vector2(front.x, front.z))) < 0.01, "a monster's leg does not snap it round: it still faces +z as the leg starts (got %.2f deg)" % _deg(Vector2(front.x, front.z)))
	for i in range(6):
		if has_step:
			world.call("_step_remote_turns", 1.0 / 60.0)
	front = Basis(Vector3.UP, body.rotation.y) * Vector3(0, 0, -1)
	_check(absf(_deg(Vector2(front.x, front.z)) - 54.0) < 0.5, "6 frames in it has turned 54 deg toward +x (got %.2f)" % _deg(Vector2(front.x, front.z)))
	for i in range(6):
		if has_step:
			world.call("_step_remote_turns", 1.0 / 60.0)
	front = Basis(Vector3.UP, body.rotation.y) * Vector3(0, 0, -1)
	_check(Vector2(front.x, front.z).is_equal_approx(Vector2(1, 0)), "and faces its destination, +x, once the turn is done (got %s)" % str(front))
	body.free()
	world.free()

func _has_static(script: GDScript, name: String) -> bool:
	for m in script.get_script_method_list():
		if String(m["name"]) == name:
			return true
	return false

## FUN_008a5640 + FUN_009c40b0 for the spawn's wire angle, and FUN_009eb2a0's
## three answers for a ground click.
func _test_wire_and_click(rf: GDScript) -> void:
	var has_wire := _has_static(rf, "from_wire_angle")
	_check(has_wire, "RemoteFacing reads a wire angle")
	if has_wire:
		_check(is_equal_approx(float(rf.from_wire_angle(0)), PI / 2.0), "wire angle 0 is heading pi/2 (FUN_009c40b0 adds a quarter turn)")
		_check(absf(float(rf.from_wire_angle(16384)) - PI) < 1e-3, "wire angle 16384 is heading pi")
		var h: float = rf.from_wire_angle(49151)
		_check(h >= 0.0 and h < TAU and minf(h, TAU - h) < 1e-3, "wire angle 49151 is heading 0, in [0, 2pi) (got %.5f)" % h)
		# The server's encoding of every heading comes back within one unit.
		var worst := 0.0
		for i in range(64):
			var want := float(i) / 64.0 * TAU
			var a := wrapf(want - PI / 2.0, 0.0, TAU)
			var wire := int(round(a / TAU * 65535.0)) & 0xffff
			worst = maxf(worst, absf(wrapf(float(rf.from_wire_angle(wire)) - want, -PI, PI)))
		_check(worst < TAU / 65535.0, "64 headings survive the wire within one unit (worst %.6f rad)" % worst)
	var has_click := _has_static(rf, "click_rule")
	_check(has_click, "RemoteFacing has the click rule")
	if has_click:
		_check(rf.click_rule(false, Vector3(4.9, 0, 0), Vector3.ZERO) == "ignore", "an idle click under 5 units is not sent (0xe1b8a0 = 25.0 squared)")
		_check(rf.click_rule(false, Vector3(5.1, 0, 0), Vector3.ZERO) == "turn", "an idle click past 5 units turns")
		_check(rf.click_rule(true, Vector3(4.0, 0, 0), Vector3(200, 0, 0)) == "turn", "with an order in effect a near click is sent and turns")
		var far := Vector3(200, 0, 0)
		var four_deg := Vector3(200.0 * cos(deg_to_rad(4.0)), 0, 200.0 * sin(deg_to_rad(4.0)))
		var six_deg := Vector3(200.0 * cos(deg_to_rad(6.0)), 0, 200.0 * sin(deg_to_rad(6.0)))
		_check(rf.click_rule(true, four_deg, far) == "snap", "a far click 4 deg off a far order snaps (FUN_009e04b0; 0xdb9828 = 5 deg)")
		_check(rf.click_rule(true, six_deg, far) == "turn", "6 deg off it turns")
		_check(rf.click_rule(true, four_deg, Vector3(99, 0, 0)) == "turn", "an order under 100 units away turns (0xd82efc = 10000 squared)")

func _call_if(world: Node, method: String, args: Array = []) -> bool:
	if not world.has_method(method):
		print("FAIL World3D has no %s" % method)
		_failures += 1
		return false
	world.callv(method, args)
	return true

## The spawn's heading, a relocation, a monster's stop, a bare snap.
func _test_review_paths(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var frame := 1.0 / 60.0
	# A relocated position is placed, not turned toward.
	var body := Node3D.new()
	var skel := Node3D.new()
	skel.rotation.y = PI
	body.add_child(skel)
	(world.get("_other_bodies") as Dictionary)[5] = body
	(world.get("_other_body_targets") as Dictionary)[5] = Vector3.ZERO
	var m := _moved(5, 0.0, -300.0)
	m.set("relocated", true)
	world.call("_on_entity_moved", m)
	_call_if(world, "_step_remote_turns", [0.5])
	_check(body.position.is_equal_approx(Vector3(0, 0, -300)), "a relocation puts the body there at once (got %s)" % str(body.position))
	_check(absf(_deg(_player_front(body))) < 0.01, "and does not turn it toward the jump (front %.2f deg)" % _deg(_player_front(body)))
	body.free()
	# OpEntityEntered's heading: the spawn faces it, no turn.
	var snap := WorldNet.EntitySnapshot.new()
	snap.character_id = 9
	snap.char_name = "Aria"
	snap.x = 10.0
	snap.z = 20.0
	snap.set("heading", PI / 2.0)
	var others := Node3D.new()
	world.set("other_entities", others)
	world.call("_on_entity_entered", snap)
	var spawned: Node3D = (world.get("_other_bodies") as Dictionary).get(9)
	_check(spawned != null and is_equal_approx(spawned.rotation.y, PI / 2.0),
		"a spawn with heading pi/2 is placed facing +x (rotation %s)" % (str(spawned.rotation.y) if spawned != null else "none"))
	if spawned != null:
		_check(not (world.get("_remote_turns") as Dictionary).has(spawned.get_instance_id()), "and is not turning")
	# The arrival list's heading ("headings in the arrival lists"): someone
	# already standing there is drawn facing it.
	var listed := WorldNet.EntitySnapshot.new()
	listed.character_id = 11
	listed.char_name = "Cyra"
	listed.x = 30.0
	listed.z = 40.0
	listed.set("heading", PI)
	world.call("_spawn_result_others", [listed], [])
	var standing: Node3D = (world.get("_other_bodies") as Dictionary).get(11)
	_check(standing != null and absf(absf(standing.rotation.y) - PI) < 1e-4,
		"someone in the arrival list with heading pi is drawn facing -z (rotation %s)" % (str(standing.rotation.y) if standing != null else "none"))
	others.free()
	# A monster's stop snaps to the turn's target and ends it.
	var mob := Node3D.new()
	mob.position = Vector3(100, 0, -200)
	mob.set_meta("model", "mob\\china\\mangnyang.bsr")
	mob.rotation.y = PI
	(world.get("_monster_bodies") as Dictionary)[7] = mob
	var leg := CombatNet.MonsterMoved.new()
	leg.monster_id = 7
	leg.x = 100
	leg.z = -200
	leg.dest_x = 140
	leg.dest_z = -200
	leg.speed = 8.0
	world.call("_on_monster_moved", leg)
	var stop := CombatNet.MonsterMoved.new()
	stop.monster_id = 7
	stop.x = 100
	stop.z = -200
	stop.dest_x = 100
	stop.dest_z = -200
	stop.speed = 8.0
	world.call("_on_monster_moved", stop)
	var front := Basis(Vector3.UP, mob.rotation.y) * Vector3(0, 0, -1)
	_check(Vector2(front.x, front.z).is_equal_approx(Vector2(1, 0)),
		"a stop mid-turn snaps to the turn's heading, +x (FUN_009e00f0 -> FUN_009e0050) (got %s)" % str(front))
	_check(not (world.get("_remote_turns") as Dictionary).has(mob.get_instance_id()), "and ends the turn")
	# A bare snap (a standing monster turned to its target) leaves a turn running.
	(world.get("_monster_motion") as Dictionary).erase(7)
	(world.get("_remote_turns") as Dictionary)[mob.get_instance_id()] = {"target": 0.0, "front": PI}
	world.call("_face_monster_toward", 7, Vector2(100, -300))
	_check((world.get("_remote_turns") as Dictionary).has(mob.get_instance_id()),
		"a standing monster turned to its target keeps its turn (a bare FUN_009c4260, INFERRED)")
	mob.free()
	world.free()

## The player's own walk turns at the same rate; a pending snap is at once;
## a placement's OpMove is a relocation.
func _test_local_player(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var player := CharacterBody3D.new()
	world.set("player", player)
	if not _call_if(world, "_aim_local_player", [Vector3(-1, 0, 0)]):
		player.free()
		world.free()
		return
	for i in range(10):
		world.call("_step_local_turn", 1.0 / 60.0)
	var front := Basis(Vector3.UP, player.rotation.y) * Vector3(0, 0, 1)
	_check(absf(rad_to_deg(atan2(front.x, front.z)) + 90.0) < 0.5,
		"10 frames into a quarter turn to -x the player has turned 90 deg the short way (front %s)" % str(front))
	world.call("_aim_local_player", Vector3(1, 0, 0))
	world.call("_step_local_turn", 1.0 / 60.0)
	front = Basis(Vector3.UP, player.rotation.y) * Vector3(0, 0, 1)
	_check(front.x < 0.0, "a reverse click turns, not snaps: one frame in it still faces -x (front %s)" % str(front))
	world.set("_player_turn_snap", true)
	world.call("_aim_local_player", Vector3(0, 0, -1))
	front = Basis(Vector3.UP, player.rotation.y) * Vector3(0, 0, 1)
	_check(front.is_equal_approx(Vector3(0, 0, -1)), "a snap click faces the walk at once (FUN_009e04b0) (front %s)" % str(front))
	# The relocation rule of the position send.
	player.position = Vector3(3, 0, 0)
	world.set("_last_sent_pos", Vector3.ZERO)
	world.set("_walked_since_send", 3.0)
	_check(not bool(world.call("_position_relocated")), "a walked step is not a relocation")
	player.position = Vector3(40, 0, 0)
	world.set("_walked_since_send", 3.0)
	_check(bool(world.call("_position_relocated")), "37 units the walk does not account for is a relocation")
	player.free()
	world.free()
