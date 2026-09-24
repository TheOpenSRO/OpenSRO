extends SceneTree

## Exercises MonsterMotion -- how a server-driven monster move is drawn -- and
## the approach walk against a monster that walks away, run headless on the
## render box: `client/tools/remote_godot.sh tests`.
##
## The engine's numbers under test are its mover's: the 160-unit step cap
## (.rdata 0xb45ea8) and the no-overshoot clamp (CGObjMoverByDest::vslot_003,
## 0x48c62b..0x48c63c). Speeds are the roster's own (Mangyang walks 8 and runs
## 22, characterdata cols 46/47); the rest are fixtures.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _moved(id: int, x: float, z: float, dx: float, dz: float, speed: float, mode: int) -> CombatNet.MonsterMoved:
	var m := CombatNet.MonsterMoved.new()
	m.monster_id = id
	m.x = x
	m.z = z
	m.dest_x = dx
	m.dest_z = dz
	m.speed = speed
	m.mode = mode
	return m

## A 40-unit leg at Mangyang's walk, 8 u/s, on the movie writer's fixed 1/60 s
## frame: 5.0 s, give or take the last frame, and never past its end.
func _test_leg_arrives_on_time() -> void:
	var pos := Vector2(100, -200)
	var dest := Vector2(140, -200)
	var frames := 0
	var overshot := false
	var backwards := false
	var last_x := pos.x
	while pos != dest and frames < 1000:
		pos = MonsterMotion.step(pos, dest, 8.0, 1.0 / 60.0)
		frames += 1
		overshot = overshot or pos.x > dest.x
		backwards = backwards or pos.x < last_x
		last_x = pos.x
	_check(absi(frames - 300) <= 1, "a 40-unit leg at 8 u/s arrives in 300 frames +-1 at 1/60 s (took %d)" % frames)
	_check(not overshot and not backwards, "and never overshoots or steps back")

func _test_step_clamps() -> void:
	# 22 u/s x 0.2 s is 4.4, more than the 3 left: the engine's clamp lands it.
	var dest := Vector2(13, 4)
	var landed := MonsterMotion.step(Vector2(10, 4), dest, 22.0, 0.2)
	_check(landed == dest, "a step longer than what is left lands exactly on dest (the 0x48c4e0 clamp) (got %s)" % str(landed))
	var capped := MonsterMotion.step(Vector2.ZERO, Vector2(1000, 0), 300.0, 1.0)
	_check(is_equal_approx(capped.x, 160.0) and capped.y == 0.0,
		"300 u/s over 1 s moves 160, the cap at 0xb45ea8 (got %s)" % str(capped))
	var short := MonsterMotion.step(Vector2.ZERO, Vector2(0, 100), 8.0, 0.5)
	_check(short.is_equal_approx(Vector2(0, 4)), "an ordinary step is speed x delta along the line (got %s)" % str(short))

func _test_gait_type() -> void:
	_check(MonsterMotion.gait_type(0, true) == 1, "mode 0 moving plays the walk (TYPE_WALK 1)")
	_check(MonsterMotion.gait_type(1, true) == 7, "mode 1 moving plays the run (TYPE_RUN 7)")
	_check(MonsterMotion.gait_type(0, false) == 0 and MonsterMotion.gait_type(1, false) == 0,
		"an arrived leg stands (TYPE_STAND 0)")

func _test_needs_height() -> void:
	_check(not MonsterMotion.needs_height(Vector2(5, 5), Vector2(6.9, 5)), "no height ray after 1.9 units")
	_check(MonsterMotion.needs_height(Vector2(5, 5), Vector2(7.0, 5)), "a height ray after 2.0 units")

## NEGATIVE -- a genuine red before round 533: _spawn_or_update_monster set
## `existing.position = pos` on every list refresh, which teleports a walking
## body back by its lag (docs/TODO.md's "JUMP on the next refresh").
func _test_reconcile() -> void:
	var placed := MonsterMotion.reconcile(Vector2(100, 0), Vector2(97, 0), true)
	_check(placed == Vector2(100, 0),
		"a walking body 3 units ahead of the listed position stays where it is drawn (got %s)" % str(placed))
	_check(MonsterMotion.reconcile(Vector2(100, 0), Vector2(97, 0), false) == Vector2(97, 0),
		"a standing body goes where the list says")
	_check(MonsterMotion.reconcile(Vector2(140, 0), Vector2(100, 0), true) == Vector2(100, 0),
		"a walking body 40 units off the list is put back (beyond RESYNC_DISTANCE 32)")

func _test_begin() -> void:
	var s := MonsterMotion.begin(Vector2(103, -200), _moved(7, 100, -200, 140, -200, 8, 0))
	_check(s["pos"] == Vector2(103, -200) and bool(s["moving"]) and not bool(s["stop"]),
		"a leg starts from where the body is drawn, not the server's position")
	var far := MonsterMotion.begin(Vector2(200, -200), _moved(7, 100, -200, 140, -200, 8, 0))
	_check(far["pos"] == Vector2(100, -200), "a body more than 32 units off starts from the server's position")
	_check(MonsterMotion.state_gait(s) == 1 and MonsterMotion.turns_to_face(s), "a walking leg plays the walk and turns the body")

## The stop push (dest == (x, z)): the body is drawn a little off the server's
## position. It ends there, in the stand clip, within a second, and is never
## turned toward the correction -- with the leg's speed, and with none.
func _test_stop_push() -> void:
	for speed in [8.0, 0.0]:
		var s := MonsterMotion.begin(Vector2(100.8, -199.5), _moved(7, 100, -200, 100, -200, speed, 0))
		_check(bool(s["stop"]) and not MonsterMotion.turns_to_face(s),
			"a stop at %.0f u/s does not turn the body" % speed)
		var pos: Vector2 = s["pos"]
		var t := 0.0
		var stood := MonsterMotion.state_gait(s) == 0
		while pos != Vector2(100, -200) and t < 1.0:
			pos = MonsterMotion.step(pos, s["dest"], float(s["speed"]), 1.0 / 60.0)
			t += 1.0 / 60.0
		_check(pos == Vector2(100, -200) and t < 1.0,
			"a stop at %.0f u/s with the body drawn off (x,z) ends at (x,z) within 1 s (t %.2f)" % [speed, t])
		_check(stood, "and plays the stand clip")

func _test_facing() -> void:
	# The measured front is -Z (probe_monster_front.gd). A body turned by the
	# yaw must carry its local -Z onto the path.
	for dir in [Vector2(1, 0), Vector2(0, 1), Vector2(-3, 4), Vector2(0, -2)]:
		var yaw := MonsterMotion.facing_yaw(dir, "-Z")
		var front := Basis(Vector3.UP, yaw) * Vector3(0, 0, -1)
		var want := Vector3(dir.x, 0, dir.y).normalized()
		_check(front.is_equal_approx(want), "a -Z-front body faces %s (front %s)" % [str(dir), str(front)])
	_check(MonsterMotion.front_of("mob\\china\\mangnyang.bsr") == "-Z", "Mangyang's model is measured -Z")
	_check(MonsterMotion.front_of("MOB\\CHINA\\YEOHA.BSR") == "-Z", "the model lookup ignores case")
	_check(MonsterMotion.front_of("mob\\china\\tombstone.bsr") == "", "an unprobed model is facing unmeasured")

func _anim() -> BanReader.ParsedAnimation:
	return BanReader.ParsedAnimation.new()

## The trap: _set_other_gait appends a loop when it finds no loop entry, and
## during a one-shot the skeleton's only entry is that one-shot. swap_loop
## must replace the one-shot's stashed resume (entry[6]) and leave one entry.
func _test_swap_loop() -> void:
	var sk := Skeleton3D.new()
	var idle := _anim()
	var walk := _anim()
	var hit := _anim()
	var loop := [sk, idle, 20, 0.37, true, 0.0, null]
	var animated: Array = [[sk, hit, 10, 0.0, false, 1.0, loop]]
	_check(MonsterMotion.swap_loop(animated, sk, walk, 30, 2.0), "a swap during a one-shot changes something")
	_check(animated.size() == 1, "and leaves exactly one entry for the skeleton (got %d)" % animated.size())
	_check(animated[0][1] == hit and animated[0][6][1] == walk and animated[0][6][2] == 30,
		"the one-shot keeps playing and resumes into the walk")

	animated = [[sk, idle, 20, 0.37, true, 0.0, null]]
	MonsterMotion.swap_loop(animated, sk, walk, 30, 2.0)
	_check(animated.size() == 1 and animated[0][1] == walk and animated[0][3] == 0.37,
		"a loop is replaced in place, keeping its phase")

	# A null clip (a model with no walk or run) keeps the loop it has.
	_check(not MonsterMotion.swap_loop(animated, sk, null, 0, 2.0) and animated[0][1] == walk,
		"a missing clip keeps the current loop")
	# A one-shot with nothing to resume is a death hold: nothing is swapped.
	var die := _anim()
	animated = [[sk, die, 40, 0.0, false, 1.0, null]]
	_check(not MonsterMotion.swap_loop(animated, sk, walk, 30, 2.0) and animated.size() == 1 and animated[0][6] == null,
		"a death hold is left holding")
	animated = []
	MonsterMotion.swap_loop(animated, sk, walk, 30, 2.0)
	_check(animated.size() == 1 and animated[0][4] == true, "a skeleton with no entry gets one loop")
	sk.free()

## Gait edges (round 533's review): stand is the assembler's own idle, which
## falls back to the name hints for a file with no groups -- animation_for
## (TYPE_STAND) gives nothing there -- and a model with no walk clip gives
## null, which keeps the loop.
func _test_gait_clip() -> void:
	var assembled := SkinnedBsrAssembler.AssembledCharacter.new()
	var idle := _anim()
	assembled.idle_animation = idle
	_check(MonsterMotion.gait_clip(null, assembled, 0) == idle,
		"stand plays the assembler's idle even with no animation groups")
	_check(MonsterMotion.gait_clip(null, assembled, 1) == null, "no walk clip gives null")
	_check(MonsterMotion.gait_clip(null, null, 0) == null, "no body gives null")

## The run speed the player walks an approach at: 50 world units per second
## (docs/WORLD_ISSUES.md round 231, read at its use-site).
const PLAYER_RUN := 50.0

## The approach walk against a monster walking away, run the way World3D runs
## it: each frame the monster steps (MonsterMotion.step, World3D.
## _step_monster_bodies); the release test is CombatNet.approach_releases
## (_step_pending_attack), or the walk arriving within `arrive` of its point
## (the arrival branch of _physics_process); otherwise the player runs toward
## CombatNet.approach_point at approach_aim. The server measures in_reach
## `delay` seconds after the release, against where the monster is by then; a
## refusal comes back after as long again and CombatNet.should_rewalk decides.
## Returns {"accepted", "releases"}.
func _simulate(band: Vector2, monster_speed: float, known_moving: bool, delay: float, arrive: float) -> Dictionary:
	var dt := 1.0 / 60.0
	var player := Vector2.ZERO
	var monster := Vector2(40, 0)
	var away := Vector2(100000, 0)
	var tight := false
	var retries := 0
	var releases := 0
	var t := 0.0
	while t < 60.0:
		monster = MonsterMotion.step(monster, away, monster_speed, dt)
		var gap := player.distance_to(monster)
		var tight_now := tight or known_moving
		var released := CombatNet.approach_releases(gap, band.x, band.y, tight_now)
		if not released:
			var point := CombatNet.approach_point(player, monster, CombatNet.approach_aim(band.x, tight_now, arrive))
			var to := point - player
			if to.length() <= arrive:
				released = true
			else:
				player += to.normalized() * PLAYER_RUN * dt
		if released:
			releases += 1
			var measured := MonsterMotion.step(monster, away, monster_speed, delay)
			if CombatNet.in_reach(player.distance_to(measured), band.y):
				return {"accepted": true, "releases": releases}
			if not CombatNet.should_rewalk(CombatNet.REFUSED_TOO_FAR, true, retries):
				return {"accepted": false, "releases": releases}
			retries += 1
			tight = true
			monster = MonsterMotion.step(measured, away, monster_speed, delay)
			t += 2.0 * delay
		t += dt
	return {"accepted": false, "releases": releases}

## Round 533's review, blocking: released at the band's outer edge, an attack
## on a monster walking away at 8 u/s is out of reach when the server measures
## it 150 ms later, and before round 533 the refusal was final.
func _test_receding_target(arrive: float) -> void:
	for band in [CombatNet.approach_band(4, 6, 0.0), CombatNet.approach_band(4, 6, 6.0)]:
		var known := _simulate(band, 8.0, true, 0.15, arrive)
		_check(bool(known["accepted"]) and int(known["releases"]) == 1,
			"band %s: a target known to be walking away at 8 u/s is struck on the first release, 150 ms late (%s)" % [str(band), str(known)])
		var unknown := _simulate(band, 8.0, false, 0.15, arrive)
		_check(bool(unknown["accepted"]) and int(unknown["releases"]) == 2,
			"band %s: released at the slack edge it is refused, walks again and is struck (%s)" % [str(band), str(unknown)])
	# Too slow a round trip for any margin: the walk gives up at the cap
	# instead of walking for ever.
	var hopeless := _simulate(CombatNet.approach_band(4, 6, 0.0), 8.0, true, 0.6, arrive)
	_check(not bool(hopeless["accepted"]) and int(hopeless["releases"]) == 1 + CombatNet.APPROACH_RETRY_CAP,
		"a target always out of reach when measured stops after %d walks (%s)" % [1 + CombatNet.APPROACH_RETRY_CAP, str(hopeless)])

func _init() -> void:
	_test_leg_arrives_on_time()
	_test_step_clamps()
	_test_gait_type()
	_test_needs_height()
	_test_reconcile()
	_test_begin()
	_test_stop_push()
	_test_facing()
	_test_swap_loop()
	_test_gait_clip()

## World3D's glue, on a bare World3D (no scene; the nodes it touches are set
## by hand). Loaded by path in _initialize, not _init: World3D names the
## NetClient autoload, which a --script suite registers only after _init
## (error_text_test.gd, guild_test.gd).
func _initialize() -> void:
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var world_ok := world_script != null and world_script.can_instantiate()
	_check(world_ok, "World3D compiles in _initialize")
	if world_ok:
		var arrive: float = world_script.get_script_constant_map()["MOVE_TARGET_STOP_DISTANCE"]
		_test_receding_target(arrive)
		_test_world_move(world_script)
		_test_world_rewalk(world_script)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _snapshot(id: int, x: float, z: float) -> CombatNet.MonsterSnapshot:
	var snap := CombatNet.MonsterSnapshot.new()
	snap.monster_id = id
	snap.monster_name = "Mangyang"
	snap.code_name = "MOB_CH_MANGNYANG"
	snap.x = x
	snap.z = z
	return snap

## _on_monster_moved on a body of the -Z-measured Mangyang model: the leg
## starts from where the body is drawn and the body turns along it; a stop
## push after it leaves the facing alone.
func _test_world_move(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var body := Node3D.new()
	body.position = Vector3(103, 0, -200)
	body.set_meta("model", "mob\\china\\mangnyang.bsr")
	(world.get("_monster_bodies") as Dictionary)[7] = body
	(world.get("_monster_snapshots") as Dictionary)[7] = _snapshot(7, 100, -200)
	world.call("_on_monster_moved", CombatNet.decode_monster_moved(_fixture_moved()))
	var state = (world.get("_monster_motion") as Dictionary).get(7)
	_check(state != null and state["pos"] == Vector2(103, -200) and bool(state["moving"]),
		"a push starts the body's leg from where it is drawn")
	var front := Basis(Vector3.UP, body.rotation.y) * Vector3(0, 0, -1)
	_check(front.is_equal_approx(Vector3(1, 0, 0)), "the body's front turns toward its destination, +X (got %s)" % str(front))
	var yaw := body.rotation.y
	world.call("_on_monster_moved", _moved(7, 102.5, -200.4, 102.5, -200.4, 8.0, 0))
	state = (world.get("_monster_motion") as Dictionary).get(7)
	_check(bool(state["stop"]) and body.rotation.y == yaw, "a stop push leaves the facing unchanged")
	_check(not bool(world.call("_monster_is_moving", 7)), "a stop's glide does not count as walking for the approach walk")
	# A move for a monster with no body only asks for the list (not connected
	# here, so nothing is sent) and starts nothing.
	world.call("_on_monster_moved", _moved(99, 0, 0, 10, 0, 8.0, 0))
	_check(not (world.get("_monster_motion") as Dictionary).has(99), "a move for an unknown monster starts no leg")
	body.free()
	world.free()

func _fixture_moved() -> PackedByteArray:
	return PackedByteArray([0x07, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0xc8, 0x42, 0x00, 0x00, 0x48, 0xc3,
		0x00, 0x00, 0x0c, 0x43, 0x00, 0x00, 0x48, 0xc3, 0x00, 0x00, 0x00, 0x41, 0x00])

## NEGATIVE (fails before round 533, where a refusal was final: the handler
## printed 'too far away' and returned). An attack the approach walk released
## and the server refused as too far away walks again, releasing only inside
## the stop; other refusals, a dying target and the cap do not.
func _test_world_rewalk(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var player := CharacterBody3D.new()
	var label := Label.new()
	var body := Node3D.new()
	world.set("player", player)
	world.set("monster_status_label", label)
	(world.get("_monster_bodies") as Dictionary)[7] = body
	(world.get("_monster_snapshots") as Dictionary)[7] = _snapshot(7, 30, 0)
	var released := {"monster": 7, "skill": 0, "code": "", "stop": 10.0, "reach": 10.0, "tight": false, "retries": 0}

	var refused := CombatNet.AttackResult.new()
	refused.error = CombatNet.REFUSED_TOO_FAR
	refused.monster_id = 7
	world.set("_released_attack", released.duplicate())
	world.call("_on_attack_result", refused)
	var pending: Dictionary = world.get("_pending_attack")
	_check(not pending.is_empty() and int(pending.get("monster", -1)) == 7,
		"a too-far refusal of a released approach walks to the monster again")
	_check(bool(pending.get("tight", false)) and int(pending.get("retries", 0)) == 1,
		"and now releases only inside the stop, as retry 1 (%s)" % str(pending))
	_check(bool(world.get("_has_move_target")), "the walk is under way")

	world.set("_pending_attack", {})
	var capped := released.duplicate()
	capped["retries"] = CombatNet.APPROACH_RETRY_CAP
	world.set("_released_attack", capped)
	world.call("_on_attack_result", refused)
	_check((world.get("_pending_attack") as Dictionary).is_empty(), "at the retry cap it gives up")

	var cooldown := CombatNet.AttackResult.new()
	cooldown.error = "skill on cooldown"
	cooldown.monster_id = 7
	world.set("_released_attack", released.duplicate())
	world.call("_on_attack_result", cooldown)
	_check((world.get("_pending_attack") as Dictionary).is_empty(), "another refusal does not walk again")

	(world.get("_dying_until") as Dictionary)[7] = 99.0
	world.set("_released_attack", released.duplicate())
	world.call("_on_attack_result", refused)
	_check((world.get("_pending_attack") as Dictionary).is_empty(), "a dying target is not walked to again")
	(world.get("_dying_until") as Dictionary).erase(7)

	# The release itself records the attack: standing inside the reach, the
	# pending attack goes out (not connected here, so nothing is sent).
	player.position = Vector3(21, 0, 0)
	world.set("_pending_attack", released.duplicate())
	world.call("_step_pending_attack")
	_check(int((world.get("_released_attack") as Dictionary).get("monster", -1)) == 7,
		"a release keeps the attack until its result")
	world.call("_drop_pending_attack")
	_check((world.get("_released_attack") as Dictionary).is_empty(), "anything the player does next forgets it")
	body.free()
	label.free()
	player.free()
	world.free()
