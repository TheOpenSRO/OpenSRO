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

## The height budget takes turns (round 534). NEGATIVE: before it, every frame
## spent MAX_HEIGHT_RESOLVES_PER_FRAME from the first body, so with more
## bodies wanting a ray than the budget covers, the later ones never got one.
func _test_height_turns() -> void:
	var budget := MonsterMotion.MAX_HEIGHT_RESOLVES_PER_FRAME
	_check(budget == 32, "the budget under test is 32 rays a frame")
	var wants: Array = []
	for i in range(40):
		wants.append(true)
	var served := {}
	var first := MonsterMotion.height_turns(wants, 0, budget)
	_check((first["picked"] as Array).size() == 32 and int(first["cursor"]) == 32,
		"frame 1 serves 32 of 40 and the next starts at the 33rd (%s)" % str(first["cursor"]))
	for i in first["picked"]:
		served[i] = true
	# Even if all 40 still want one on the second frame, the eight passed over
	# go first.
	var second := MonsterMotion.height_turns(wants, int(first["cursor"]), budget)
	for i in second["picked"]:
		served[i] = true
	_check(served.size() == 40, "all 40 bodies are served within two frames (served %d)" % served.size())
	_check(int((second["picked"] as Array)[0]) == 32, "and the second frame starts with the ones passed over")
	# The rule it replaces: the same start every frame serves the same 32.
	var fixed := {}
	for _frame in range(2):
		for i in MonsterMotion.height_turns(wants, 0, budget)["picked"]:
			fixed[i] = true
	_check(fixed.size() == 32, "a fixed start leaves 8 bodies unserved (the round-533 rule)")
	# Only the bodies that want a ray are counted against the budget.
	var few: Array = [false, true, false, true]
	var r := MonsterMotion.height_turns(few, 0, budget)
	_check(str(r["picked"]) == "[1, 3]", "only wanting bodies are picked (%s)" % str(r["picked"]))
	_check(str(MonsterMotion.height_turns(few, 7, budget)["picked"]) == "[3, 1]", "a cursor past the end wraps (7 of 4 starts at 3)")
	_check((MonsterMotion.height_turns([], 5, budget)["picked"] as Array).is_empty(), "no bodies, no rays")
	# Round 572: the monsters' share when ground items wait for ground too.
	var share := func(items: int) -> int: return MonsterMotion.monster_height_share(budget, items)
	_check(share.call(0) == budget and share.call(-1) == budget, "no items waiting: the monsters may take the whole budget")
	_check(share.call(3) == budget - 3, "3 items waiting: the monsters may take all but their 3 (%d)" % share.call(3))
	_check(share.call(budget / 2) == budget / 2 and share.call(1000) == budget / 2,
		"half the budget or more wanted by the items: an even split (%d, %d)" % [share.call(budget / 2), share.call(1000)])

## NEGATIVE -- a genuine red before round 533: _spawn_or_update_monster set
## `existing.position = pos` on every list refresh, which teleports a walking
## body back by its lag (docs/TODO.md's "JUMP on the next refresh").
func _test_reconcile() -> void:
	var placed := MonsterMotion.reconcile(Vector2(100, 0), Vector2(97, 0), true)
	_check(placed == Vector2(100, 0),
		"a walking body 3 units ahead of the listed position stays where it is drawn (got %s)" % str(placed))
	_check(MonsterMotion.reconcile(Vector2(100, 0), Vector2(97, 0), false) == Vector2(97, 0),
		"a standing body goes where the list says")
	# Round 853: the list's rule is the 0xB021 source's, 50 (OtherWalk.RESYNC_DISTANCE).
	_check(MonsterMotion.reconcile(Vector2(140, 0), Vector2(100, 0), true) == Vector2(140, 0),
		"a walking body 40 units off the list keeps where it is drawn (within 50; round 533's 32 put it back)")
	_check(MonsterMotion.reconcile(Vector2(160, 0), Vector2(100, 0), true) == Vector2(100, 0),
		"a walking body 60 units off the list is put back (beyond OtherWalk.RESYNC_DISTANCE 50)")

func _test_begin() -> void:
	var s := MonsterMotion.begin(Vector2(103, -200), _moved(7, 100, -200, 140, -200, 8, 0))
	_check(s["pos"] == Vector2(103, -200) and bool(s["moving"]) and not bool(s["stop"]),
		"a leg starts from where the body is drawn, not the server's position")
	var far := MonsterMotion.begin(Vector2(200, -200), _moved(7, 100, -200, 140, -200, 8, 0))
	_check(far["pos"] == Vector2(100, -200) and float(far["mult"]) == 1.0,
		"a body more than 50 units off starts from the server's position, at its speed")
	_check(MonsterMotion.state_gait(s) == 1 and MonsterMotion.turns_to_face(s), "a walking leg plays the walk and turns the body")

## Round 853 (READ: the 0xB021 handler is every object's, c:0x8a5750 ->
## FUN_009e11e0 / FUN_009e1050 / FUN_009e0550): a monster's leg takes the rules
## another player's does -- OtherWalk's, called, not copied.
func _test_begin_shared_rules() -> void:
	# 40 units behind along the leg: within 50, walked from where it is drawn,
	# at the factor (60 + 40) / 60 = 1.667 -- round 533's 32 put it on the source.
	var behind := MonsterMotion.begin(Vector2(60, -200), _moved(7, 100, -200, 160, -200, 22, 1))
	_check(behind["pos"] == Vector2(60, -200), "40 behind: the leg starts where the body is drawn (got %s)" % str(behind["pos"]))
	_check(is_equal_approx(float(behind["mult"]), 100.0 / 60.0),
		"40 behind on a 60-unit leg: catch-up factor 100/60 (got %.4f)" % float(behind["mult"]))
	# It reaches the end when the server's mover does: 60 / 22 s.
	var t := 0.0
	var pos: Vector2 = behind["pos"]
	behind["pos"] = pos
	while pos != Vector2(160, -200) and t < 10.0:
		pos = MonsterMotion.step_state(behind, 1.0 / 60.0)
		behind["pos"] = pos
		t += 1.0 / 60.0
	_check(absf(t - 60.0 / 22.0) <= 1.0 / 60.0 + 1e-4,
		"and arrives with the server's mover, %.3f s against %.3f" % [t, 60.0 / 22.0])
	# Far behind: the factor stops at 3.0 (float 0xd8adc4).
	var far_behind := MonsterMotion.begin(Vector2(55, -200), _moved(7, 100, -200, 110, -200, 22, 1))
	_check(far_behind["pos"] == Vector2(55, -200) and is_equal_approx(float(far_behind["mult"]), 3.0),
		"45 behind a 10-unit leg: walked, at the 3.0 cap (got %s x%.3f)" % [str(far_behind["pos"]), float(far_behind["mult"])])
	# Ahead of the server's mover: 1.0, never slower.
	var ahead := MonsterMotion.begin(Vector2(120, -200), _moved(7, 100, -200, 160, -200, 22, 1))
	_check(float(ahead["mult"]) == 1.0, "a body ahead of the source walks at its speed")
	# The same answers as OtherWalk's for a sweep of drawn places.
	var same := true
	for dx in [-60.0, -50.5, -49.5, -20.0, 0.0, 15.0, 49.0, 51.0]:
		var drawn := Vector2(100.0 + dx, -200.0 + dx * 0.3)
		var st := MonsterMotion.begin(drawn, _moved(7, 100, -200, 170, -230, 22, 1))
		var want := OtherWalk.start_at(Vector3(drawn.x, 0, drawn.y), Vector3(100, 0, -200), true)
		var want_mult := OtherWalk.catch_up(want, Vector3(100, 0, -200), true, Vector3(170, 0, -230))
		if st["pos"] != Vector2(want.x, want.z) or not is_equal_approx(float(st["mult"]), want_mult):
			same = false
	_check(same, "begin's start and factor are OtherWalk.start_at's and catch_up's")
	# A stop within 50: walked at 3x in the stand clip; beyond 50: put there.
	var near_stop := MonsterMotion.begin(Vector2(110, -200), _moved(7, 100, -200, 100, -200, 22, 1))
	_check(near_stop["pos"] == Vector2(110, -200) and float(near_stop["mult"]) == OtherWalk.CATCH_UP_MAX \
			and MonsterMotion.state_gait(near_stop) == 0,
		"a stop 10 off walks the rest at 3x in the stand clip")
	var far_stop := MonsterMotion.begin(Vector2(160, -200), _moved(7, 100, -200, 100, -200, 22, 1))
	_check(far_stop["pos"] == Vector2(100, -200) and not bool(far_stop["moving"]), "a stop 60 off is put on its point")

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
			s["pos"] = pos
			pos = MonsterMotion.step_state(s, 1.0 / 60.0)
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
	# Round 673: every drawn model turns. The round-533 table left every model
	# off it unturned; the Gun Powder ghost (live, round 673) and the field
	# species round 660 added are -Z by the census (probe_monster_front.gd
	# --all=1: 117 of 155 read -Z, none +-X), and the rest by the engine's one
	# heading convention (INFERRED).
	for model in ["mob\\wchina\\gunpowderghost.bsr", "mob\\wchina\\demonhorse.bsr", "mob\\china\\tiger.bsr",
			"mob\\china\\tombstone.bsr", "mob\\dunhuang\\bugghost.bsr"]:
		_check(MonsterMotion.front_of(model) == "-Z", "%s turns to its path (front -Z), not left unturned" % model)
	_check(MonsterMotion.front_of("") == "", "the capsule (no model) has no front to turn")

## A server heading (OpMonsterSpawned's): radians from +x toward +z, the unit
## heading SetHeading (0x00482440) writes as (cos a, 0, sin a).
func _test_heading_dir() -> void:
	_check(MonsterMotion.heading_dir(0.0).is_equal_approx(Vector2(1, 0)), "heading 0 points along +x")
	_check(MonsterMotion.heading_dir(PI / 2.0).is_equal_approx(Vector2(0, 1)), "heading pi/2 points along +z")
	_check(MonsterMotion.heading_dir(PI).is_equal_approx(Vector2(-1, 0)), "heading pi points along -x")
	var yaw := MonsterMotion.facing_yaw(MonsterMotion.heading_dir(PI / 2.0), "-Z")
	var front := Basis(Vector3.UP, yaw) * Vector3(0, 0, -1)
	_check(front.is_equal_approx(Vector3(0, 0, 1)), "a -Z-front body at heading pi/2 faces +z (front %s)" % str(front))

func _anim() -> BanReader.ParsedAnimation:
	return BanReader.ParsedAnimation.new()

## The trap: a swap that appends a loop whenever it finds no loop entry (as
## World3D._set_other_gait did before round 540) meets, during a one-shot, a
## skeleton whose only entry is that one-shot. swap_loop must replace the
## one-shot's stashed resume (entry[6]) and leave one entry.
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
	# A death hold (World3D._play_once's eighth element, true): nothing is
	# swapped.
	var die := _anim()
	animated = [[sk, die, 40, 0.0, false, 1.0, null, true]]
	_check(not MonsterMotion.swap_loop(animated, sk, walk, 30, 2.0) and animated.size() == 1 and animated[0][6] == null,
		"a death hold is left holding")
	# NEGATIVE (round 534; before it any one-shot with nothing to resume was
	# taken for a death): a HIT on a body whose idle was never registered has
	# no resume either, and it is given the walk to resume into.
	animated = [[sk, hit, 10, 0.0, false, 1.0, null, false]]
	_check(MonsterMotion.swap_loop(animated, sk, walk, 30, 2.0) and animated.size() == 1,
		"a hit with nothing to resume takes the walk, in one entry")
	_check(animated[0][1] == hit and animated[0][6] != null and animated[0][6][1] == walk and bool(animated[0][6][4]),
		"the hit keeps playing and resumes into a walk LOOP")
	var run := _anim()
	MonsterMotion.swap_loop(animated, sk, run, 24, 3.0)
	_check(animated.size() == 1 and animated[0][6][1] == run, "a later swap replaces that resume, still one entry")
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
			# A plain swing (skill 0): a refused skill is not sent again (round 534).
			if not CombatNet.should_rewalk(CombatNet.REFUSED_TOO_FAR, true, retries, 0):
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
	_test_height_turns()
	_test_reconcile()
	_test_begin()
	_test_begin_shared_rules()
	_test_stop_push()
	_test_facing()
	_test_heading_dir()
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
		_test_world_gait_drop(world_script)
		_test_world_rewalk(world_script)
		# The height fixture's region group must be IN the tree for
		# to_local/to_global to have a global transform, and a --script
		# suite's root enters the tree only after _initialize returns
		# (hud_click_routing_test measured the `!is_inside_tree()`; this
		# suite's first run printed the same seven times), so it waits a
		# frame. A watchdog fails the suite rather than hanging it if a
		# script error stops it before it reports (round 556's open trap).
		var watchdog := create_timer(60.0)
		watchdog.timeout.connect(func() -> void:
			print("FAIL the suite never reported (a script error stopped it)")
			quit(1))
		await process_frame
		_test_world_height(world_script)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## A region whose terrain is flat at `height`, every tile on cell 0
## (nav_graph_test.gd's fixture), so the graph's tile -> cell lookup works.
func _flat_region(height: float) -> NvmReader.ParsedRegion:
	var r := NvmReader.ParsedRegion.new()
	r.heights.resize(NvmReader.HEIGHT_COUNT)
	r.heights.fill(height)
	var cell := NvmReader.Cell.new()
	cell.rect_min = Vector2.ZERO
	cell.rect_max = Vector2(1920.0, 1920.0)
	r.cells.append(cell)
	for _i in range(NvmReader.TILE_COUNT):
		var t := NvmReader.Tile.new()
		t.cell_index = 0
		r.tiles.append(t)
	return r

func _cedge(v0: int, v1: int, cell_from: int, cell_to: int, flags: int) -> BmsReader.CollisionEdge:
	var e := BmsReader.CollisionEdge.new()
	e.v0 = v0
	e.v1 = v1
	e.cell_from = cell_from
	e.cell_to = cell_to
	e.flags = flags
	return e

## A flat walkable deck, `size` square, as a placed object at `at`
## (nav_graph_test.gd's _quad: two cells, its sides walls -- flag 3 -- and
## its two ends open -- flag 0 -- with the diagonal internal).
func _deck(size: float, at: Vector3) -> NavGraph.PlacedObject:
	var cm := BmsReader.CollisionMesh.new()
	for p in [Vector3(0.0, 0.0, 0.0), Vector3(size, 0.0, 0.0), Vector3(size, 0.0, size), Vector3(0.0, 0.0, size)]:
		var v := BmsReader.CollisionVertex.new()
		v.position = p
		cm.vertices.append(v)
	for tri in [[0, 1, 2], [0, 2, 3]]:
		var c := BmsReader.CollisionCell.new()
		c.a = tri[0]
		c.b = tri[1]
		c.c = tri[2]
		cm.cells.append(c)
	cm.outline_edges.append(_cedge(0, 1, 0, BmsReader.NO_CELL, 0))
	cm.outline_edges.append(_cedge(1, 2, 0, BmsReader.NO_CELL, 3))
	cm.outline_edges.append(_cedge(2, 3, 1, BmsReader.NO_CELL, 0))
	cm.outline_edges.append(_cedge(3, 0, 1, BmsReader.NO_CELL, 3))
	cm.internal_edges.append(_cedge(0, 2, 0, 1, 4))
	return NavGraph.place(cm, 0, at, 0.0)

## NEGATIVE (fails before round 557, when a walking body's height was the
## terrain-only ray: in the world that ray sees no placed object, and on
## this bare World3D it has no physics world to fire in at all, so the body
## stays where it was). A body walking over a placed deck is drawn ON the
## deck, at the graph's landing height -- Jangan's plaza case, a deck 13.8
## up against height_at's 12.0 reach (nav_graph_test.gd) -- through the
## same throttled resolve, and the navmesh answers only inside a loaded
## region.
func _test_world_height(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var deck_rise: float = NavGraph.SURFACE_REACH_UP + 1.8
	var decks: Array[NavGraph.PlacedObject] = [_deck(40.0, Vector3(100.0, deck_rise, 200.0))]
	var graph := NavGraph.build(_flat_region(0.0), decks)
	# The region's group node: in the tree so to_local/to_global have a
	# global transform, at the origin so region-local is world.
	var group := Node3D.new()
	root.add_child(group)
	# The pair lives in the world's RegionGridState since round 563; the
	# region named does not matter to a position lookup.
	(world.get("_grid") as RegionGridState).add_nav_graph(0, 0, graph, group)
	var body := Node3D.new()
	body.position = Vector3(110.0, 0.0, 239.0)
	(world.get("_monster_bodies") as Dictionary)[7] = body
	(world.get("_monster_snapshots") as Dictionary)[7] = _snapshot(7, 110.0, 239.0)
	(world.get("_monster_motion") as Dictionary)[7] = {"pos": Vector2(110.0, 239.0), "dest": Vector2(120.0, 239.0),
		"speed": 8.0, "mode": 0, "moving": true, "stop": false, "h_xz": Vector2(-1000.0, -1000.0), "log_frames": 0}
	world.call("_step_monster_bodies", 1.0 / 60.0)
	_check(absf(body.position.y - deck_rise) < 0.01,
		"a walking body over a placed deck %.1f up is drawn on it, at the navmesh landing height (got y %.2f)" % [
			deck_rise, body.position.y])
	_check(body.position.x > 110.0 and body.position.x < 110.2,
		"and the same frame stepped it 8/60 along its leg (x %.3f)" % body.position.x)
	var state: Dictionary = (world.get("_monster_motion") as Dictionary)[7]
	_check(state["h_xz"] == state["pos"], "and the resolve is booked at the body's position for the throttle")
	var on_terrain = world.call("_navmesh_height_at", Vector3(20.0, 50.0, 20.0))
	_check(on_terrain is float and absf(on_terrain) < 0.01,
		"off the deck the navmesh height is the terrain's own, 0 (got %s)" % str(on_terrain))
	var outside = world.call("_navmesh_height_at", Vector3(3000.0, 0.0, 3000.0))
	_check(outside is float and is_nan(outside),
		"outside every loaded region the navmesh has no answer, and the terrain ray's turn comes (got %s)" % str(outside))
	body.free()
	root.remove_child(group)
	group.free()
	world.free()

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
	# The body turns at the client's rate since round 637 (RemoteFacing): half
	# a second is past any turn's end (a half turn takes a third).
	world.call("_step_remote_turns", 0.5)
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

## A clip of `frames` keyframes on one bone (a loop the clip list takes).
func _clip(name: String, frames: int) -> BanReader.ParsedAnimation:
	var a := BanReader.ParsedAnimation.new()
	a.animation_name = name
	a.duration_ms = frames * 33
	a.cyclic = true
	var b := BanReader.Bone.new()
	b.bone_name = "Bip01"
	for i in frames:
		var k := BanReader.Keyframe.new()
		k.rotation = Quaternion.IDENTITY
		b.keyframes.append(k)
	a.bones.append(b)
	return a

## Round 853 (READ c:0xa59680, c:0xa5b550; World3D._body_gait): a walk the
## model has no clip for plays nothing. The loop it had plays on for the
## state exit's 200 ms, then leaves the clip list -- the bones keep their pose
## -- and the arrival's stand starts from its first frame. NEGATIVE: before,
## the model kept the loop it had (a ridden mount was made to run).
func _test_world_gait_drop(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var sk := Skeleton3D.new()
	var assembled := SkinnedBsrAssembler.AssembledCharacter.new()
	assembled.skeleton = sk
	var stand := _clip("stand", 10)
	assembled.idle_animation = stand
	(world.get("_monster_assembled") as Dictionary)[7] = assembled
	var animated: Array = world.get("_animated")
	animated.append([sk, stand, 10, 0.37, true, 0.0, null])
	world.set("_idle_anim_time", 5.0)
	# No archive: the walk has no clip (MonsterMotion.gait_clip -> null).
	world.call("_set_monster_gait", 7, BsrReader.AnimationEntry.TYPE_WALK)
	var entries := func() -> int:
		var n := 0
		for e in (world.get("_animated") as Array):
			if e[0] == sk:
				n += 1
		return n
	_check(entries.call() == 1 and ((world.get("_animated") as Array)[0][1] == stand),
		"a walk with no clip: the stand plays on while it is stopped")
	world.set("_idle_anim_time", 5.15)
	world.call("_step_gait_drops")
	_check(entries.call() == 1, "still there 150 ms on (the stop's 200 ms)")
	world.set("_idle_anim_time", 5.21)
	world.call("_step_gait_drops")
	_check(entries.call() == 0, "dropped after 200 ms: nothing plays, the pose is held")
	world.set("_idle_anim_time", 7.0)
	world.call("_set_monster_gait", 7, BsrReader.AnimationEntry.TYPE_STAND)
	var back: Array = []
	for e in (world.get("_animated") as Array):
		if e[0] == sk:
			back = e
	_check(back.size() > 0 and back[1] == stand and is_equal_approx(7.0 + float(back[3]), 0.0),
		"the arrival's stand plays again from its first frame")
	_check((world.get("_gait_drops") as Dictionary).is_empty(), "and the drop is over")
	# A walk, then the stand inside the 200 ms: the stand (a clip) cancels the
	# drop and the loop stays.
	world.call("_set_monster_gait", 7, BsrReader.AnimationEntry.TYPE_WALK)
	_check(not (world.get("_gait_drops") as Dictionary).is_empty(), "a second walk with no clip schedules a drop")
	world.set("_idle_anim_time", 7.1)
	world.call("_set_monster_gait", 7, BsrReader.AnimationEntry.TYPE_STAND)
	world.set("_idle_anim_time", 7.5)
	world.call("_step_gait_drops")
	_check((world.get("_gait_drops") as Dictionary).is_empty() and entries.call() == 1,
		"a clip played inside the 200 ms cancels the drop")
	sk.free()
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
	var body := Node3D.new()
	world.set("player", player)
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

	# NEGATIVE (round 534; before it a refused skill walked and was cast
	# again): a SKILL the walk released is not walked to again.
	var skill_release := released.duplicate()
	skill_release["skill"] = 50
	skill_release["code"] = "SKILL_CH_SWORD_SMASH_A_01"
	world.set("_has_move_target", false)
	world.set("_released_attack", skill_release)
	world.call("_on_attack_result", refused)
	_check((world.get("_pending_attack") as Dictionary).is_empty() and not bool(world.get("_has_move_target")),
		"a too-far refusal of a skill does not walk again")
	_check((world.get("_released_attack") as Dictionary).is_empty(), "and the result forgets it")

	# NEGATIVE (round 534): a released swing the server dropped gets no reply,
	# so its entry used to outlive it. Any later request forgets it: the next
	# swing or cast (_send_attack; not connected here, so nothing is sent).
	# (The debug tabs' Skills > Use, which did the same, went in round 848.)
	world.set("_released_attack", released.duplicate())
	world.call("_send_attack", 7, 0, "")
	_check((world.get("_released_attack") as Dictionary).is_empty(), "a newer request forgets a stale release")
	world.set("_released_attack", released.duplicate())
	world.call("_on_attack_result", refused)
	_check(not (world.get("_pending_attack") as Dictionary).is_empty(),
		"a refusal right after a release still walks again (the release is not stale)")
	world.set("_pending_attack", {})
	world.set("_has_move_target", false)

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
	player.free()
	world.free()
