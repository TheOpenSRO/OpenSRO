extends SceneTree

## Round 785's World3D glue for the plain fight, on a bare World3D (no scene;
## the nodes it touches are set by hand), run headless on the render box:
## `client/tools/remote_godot.sh tests`.
##   - a fighter turns to face what it strikes, over the swing, at
##     CombatFacing's rate, and a walking player is not turned;
##   - the keep-up's own "too far away" walks the player back in for the
##     monster it fights, at most CombatNet.APPROACH_RETRY_CAP times running,
##     and not for any other monster;
##   - a monster's blow on this player reports the HP and the death as the
##     blow lands, not when the push arrives.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var ok := world_script != null and world_script.can_instantiate()
	_check(ok, "World3D compiles in _initialize")
	if ok:
		_test_player_faces_its_target(world_script)
		_test_keepup_refusal_walks_back(world_script)
		# The clip tick wants its skeleton in the tree, which a node added in
		# _initialize is only after a frame (monster_strikes_test's pattern).
		var watchdog := create_timer(60.0)
		watchdog.timeout.connect(func() -> void:
			print("FAIL the suite never reported (a script error stopped it)")
			quit(1))
		await process_frame
		await _test_one_shot_hands_back_once(world_script)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## The player's front, +Z of its rotation (RemoteFacing's heading 0 is +Z).
func _player_front(p: Node3D) -> Vector3:
	return Basis(Vector3.UP, p.rotation.y) * Vector3(0, 0, 1)

func _test_player_faces_its_target(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var player := CharacterBody3D.new()
	world.set("player", player)
	var body := Node3D.new()
	body.position = Vector3(10, 0, 0)
	(world.get("_monster_bodies") as Dictionary)[7] = body
	world.call("_face_while_striking", player, 0.0, Callable(world, "_monster_position_of").bind(7), 1.0, 7)
	world.call("_step_combat_faces", 0.05)
	var after_step := absf(float(player.rotation.y))
	_check(after_step > 0.45 and after_step < 0.55,
		"one 50 ms step turns the player 0.5 rad toward the monster (%.3f)" % after_step)
	world.call("_step_combat_faces", 1.0)
	_check(_player_front(player).is_equal_approx(Vector3(1, 0, 0)),
		"over the swing it faces the monster, +X (front %s)" % str(_player_front(player)))
	# A walking player is not turned; its turn entry ends.
	body.position = Vector3(0, 0, -10)
	world.call("_face_while_striking", player, 0.0, Callable(world, "_monster_position_of").bind(7), 1.0, 7)
	world.set("_has_move_target", true)
	world.call("_step_combat_faces", 1.0)
	_check(_player_front(player).is_equal_approx(Vector3(1, 0, 0)) and (world.get("_combat_faces") as Dictionary).is_empty(),
		"a walking player keeps the heading its walk gives it")
	world.set("_has_move_target", false)
	# A monster gone: the turn ends.
	world.call("_face_while_striking", player, 0.0, Callable(world, "_monster_position_of").bind(8), 1.0, 8)
	world.call("_step_combat_faces", 0.1)
	_check((world.get("_combat_faces") as Dictionary).is_empty(), "a target that is gone ends the turn")
	body.free()
	player.free()
	world.free()

## A clip of `frames` keyframes on one bone, `ms` long.
func _clip(frames: int, ms: int) -> BanReader.ParsedAnimation:
	var anim := BanReader.ParsedAnimation.new()
	anim.duration_ms = ms
	var bone := BanReader.Bone.new()
	for i in frames:
		bone.keyframes.append(BanReader.Keyframe.new())
	anim.bones.append(bone)
	return anim

## A one-shot over a loop, ended: the clip tick keeps the loop alone. Until
## round 785 the swap of one entry for another left the count unchanged and
## the tick kept its OLD list, so the ended one-shot "ended" again on every
## frame after (and its sounds fired every frame).
func _test_one_shot_hands_back_once(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var skel := Skeleton3D.new()
	root.add_child(skel)
	await process_frame
	var loop := _clip(3, 1000)
	var hit := _clip(3, 400)
	world.call("_animate_skeleton", skel, loop)
	world.call("_play_once", skel, hit)
	var animated: Array = world.get("_animated")
	_check(animated.size() == 1 and is_same(animated[0][1], hit), "the hit one-shot replaced the loop's entry")
	_check(skel.is_inside_tree(), "the skeleton is in the tree")
	world.call("_tick_idle_animations", 1.0 / 60.0)
	_check((world.get("_animated") as Array).size() == 1, "one tick in, the one-shot still plays (%d entries)" % (world.get("_animated") as Array).size())
	for i in 30:
		world.call("_tick_idle_animations", 1.0 / 60.0)
	animated = world.get("_animated")
	_check(animated.size() == 1 and is_same(animated[0][1], loop) and bool(animated[0][4]),
		"after the hit's 400 ms the loop alone is left (%d entries, first %s)" % [animated.size(),
			"loop" if animated.size() > 0 and is_same(animated[0][1], loop) else "not the loop"])
	skel.queue_free()
	world.free()

func _refusal(monster: int) -> CombatNet.AttackResult:
	var r := CombatNet.AttackResult.new()
	r.error = CombatNet.REFUSED_TOO_FAR
	r.monster_id = monster
	return r

func _test_keepup_refusal_walks_back(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var player := CharacterBody3D.new()
	world.set("player", player)
	var body := Node3D.new()
	body.position = Vector3(30, 0, 0)
	var snap := CombatNet.MonsterSnapshot.new()
	snap.monster_id = 7
	snap.x = 30.0
	(world.get("_monster_bodies") as Dictionary)[7] = body
	(world.get("_monster_snapshots") as Dictionary)[7] = snap
	world.set("_last_attack_target", 7)
	_check(not bool(world.call("_rewalk_after_keepup_refusal", _refusal(9))),
		"a refusal for another monster walks nowhere")
	for n in range(CombatNet.APPROACH_RETRY_CAP):
		_check(bool(world.call("_rewalk_after_keepup_refusal", _refusal(7))),
			"the keep-up's refusal %d walks back for the monster it fought" % (n + 1))
		world.set("_pending_attack", {})
		world.set("_has_move_target", false)
	_check(not bool(world.call("_rewalk_after_keepup_refusal", _refusal(7))),
		"past %d walks back with no blow between, it stops following" % CombatNet.APPROACH_RETRY_CAP)
	world.set("_keepup_rewalks", 0)
	world.set("_player_dead", true)
	_check(not bool(world.call("_rewalk_after_keepup_refusal", _refusal(7))), "a dead player walks nowhere")
	world.set("_player_dead", false)
	(world.get("_dying_until") as Dictionary)[7] = 1.0
	_check(not bool(world.call("_rewalk_after_keepup_refusal", _refusal(7))), "nor for a dying monster")
	body.free()
	player.free()
	world.free()
