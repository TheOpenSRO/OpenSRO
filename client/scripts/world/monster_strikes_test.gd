extends SceneTree

## Exercises MonsterStrikes -- whether the attacker's own client draws a
## counterattack from its OpAttackResult or from the zone's OpMonsterAttacked
## push (0x007D) -- and World3D's glue for the push and for OpMonsterSpawned
## (0x007E), run headless on the render box: `client/tools/remote_godot.sh
## tests`.
##
## The order under test is the server's: a counter is resolved in
## performAttack (session/combat.go), reported in the attacker's
## OpAttackResult, and pushed to the zone right behind it. Every number here
## is a fixture.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _result(damage: int, hp: int, blocked: bool = false, critical: bool = false, died: bool = false) -> CombatNet.AttackResult:
	var r := CombatNet.AttackResult.new()
	r.monster_damage = 20
	r.monster_remaining_hp = 50
	r.monster_id = 7
	r.player_damage_taken = damage
	r.player_hp = hp
	r.player_blocked = blocked
	r.monster_critical = critical
	r.player_died = died
	if died:
		r.death_exp_lost = 25900
	return r

## The push a server with the strike push sends right behind `result`.
func _push_for(result: CombatNet.AttackResult, target: int) -> CombatNet.MonsterAttacked:
	var m := CombatNet.MonsterAttacked.new()
	m.monster_id = result.monster_id
	m.target_character_id = target
	m.damage = result.player_damage_taken
	m.critical = result.monster_critical
	m.blocked = result.player_blocked
	m.target_died = result.player_died
	m.target_hp = result.player_hp
	m.death_exp_lost = result.death_exp_lost
	return m

func _test_result_countered() -> void:
	_check(MonsterStrikes.result_countered(_result(12, 88)), "a blow taken is a counter")
	_check(MonsterStrikes.result_countered(_result(0, 100, true)), "a blow blocked (0 damage) is a counter")
	_check(not MonsterStrikes.result_countered(_result(0, 100)), "a swing inside the ReuseDelay (0, not blocked) is none")
	var killed := _result(0, 100)
	killed.monster_died = true
	_check(not MonsterStrikes.result_countered(killed), "a killing blow draws no counter")
	var refused := _result(0, 0)
	refused.error = "too far away"
	_check(not MonsterStrikes.result_countered(refused), "a refusal carries none")

## How many times a counter is drawn, by World3D's rule: once when the blow
## lands (from the push that claimed its wait, or from the result), and once
## on receipt for a push that claims nothing. `order` is the sequence of
## "push" and "land" events after the result arrives.
func _draws(order: Array, with_push: bool) -> Dictionary:
	var waits := {}
	var result := _result(12, 88)
	var wait := MonsterStrikes.expect(waits, 7, result)
	var from_push := 0
	var from_result := 0
	for ev in order:
		if ev == "push" and with_push:
			if MonsterStrikes.claim(waits, _push_for(result, 42)) == MonsterStrikes.CLAIM_NONE:
				from_push += 1
		elif ev == "land":
			if MonsterStrikes.settle(waits, 7, wait) != null:
				from_push += 1
			else:
				from_result += 1
	return {"push": from_push, "result": from_result, "left": waits.get(7, []).size()}

## NEGATIVE: drawn exactly once whichever way the messages fall. Before round
## 540 the result always drew the counter; a push drawn on its own on top of
## it would draw the attacker's counter twice.
func _test_drawn_once() -> void:
	var usual := _draws(["push", "land"], true)
	_check(usual["push"] == 1 and usual["result"] == 0 and usual["left"] == 0,
		"push before the blow lands: drawn once, from the push, nothing left waiting (%s)" % str(usual))
	var late := _draws(["land", "push"], true)
	_check(late["push"] == 0 and late["result"] == 1 and late["left"] == 0,
		"push after the blow lands: drawn once, from the result; the late push is swallowed (%s)" % str(late))
	var none := _draws(["push", "land"], false)
	_check(none["push"] == 0 and none["result"] == 1,
		"no push (an older server, or the push off): drawn once, from the result (%s)" % str(none))
	_check(none["left"] == 1, "and the drawn wait stays for a push that may still come")

func _test_claims() -> void:
	var waits := {}
	var r1 := _result(12, 88)
	var w1 := MonsterStrikes.expect(waits, 7, r1)
	# Someone else's blow on the same monster, with other numbers.
	var other := _push_for(_result(9, 140), 55)
	_check(MonsterStrikes.claim(waits, other) == MonsterStrikes.CLAIM_NONE and w1["push"] == null,
		"a push that repeats no waiting counter claims nothing")
	var elsewhere := _push_for(r1, 42)
	elsewhere.monster_id = 8
	_check(MonsterStrikes.claim(waits, elsewhere) == MonsterStrikes.CLAIM_NONE, "nor one from another monster")
	# Two counters whose pushes arrive after both results (a keep-up swing's
	# result from its own goroutine can land between a click's result and
	# its push): each push claims its own, oldest first.
	var r2 := _result(15, 73, false, true)
	var w2 := MonsterStrikes.expect(waits, 7, r2)
	_check(MonsterStrikes.claim(waits, _push_for(r1, 42)) == MonsterStrikes.CLAIM_HELD, "the first push is held")
	_check(MonsterStrikes.claim(waits, _push_for(r2, 42)) == MonsterStrikes.CLAIM_HELD, "the second push is held")
	var s1 := MonsterStrikes.settle(waits, 7, w1)
	var s2 := MonsterStrikes.settle(waits, 7, w2)
	_check(s1 != null and s1.damage == 12 and s2 != null and s2.damage == 15 and s2.critical,
		"each wait settles with its own push")
	_check(not waits.has(7), "and nothing is left waiting")
	# A blocked counter: 0 damage and the block bit, repeated by its push.
	var blocked := _result(0, 100, true)
	var wb := MonsterStrikes.expect(waits, 7, blocked)
	_check(MonsterStrikes.claim(waits, _push_for(blocked, 42)) == MonsterStrikes.CLAIM_HELD
		and MonsterStrikes.settle(waits, 7, wb) != null, "a blocked counter is claimed by its push too")
	# A new counter drops the waits the result already drew.
	var r3 := _result(12, 88)
	MonsterStrikes.settle(waits, 7, MonsterStrikes.expect(waits, 7, r3))
	_check((waits[7] as Array).size() == 1, "a counter drawn from its result leaves its wait")
	var w4 := MonsterStrikes.expect(waits, 7, _result(11, 77))
	_check((waits[7] as Array).size() == 1 and is_same(waits[7][0], w4), "the next counter drops it")

## Round 546: a push with no counter to pair with (the monster's own swing)
## is this player's by elimination -- unless its target is drawn as another
## player, or left the zone inside LEFT_GRACE_MS.
func _test_own_unpaired() -> void:
	var others := {55: true}
	var left := {66: 1000}
	_check(MonsterStrikes.is_own_unpaired(42, others, left, 5000), "a target drawn nowhere is this player")
	_check(not MonsterStrikes.is_own_unpaired(55, others, left, 5000), "a drawn other player is not")
	_check(not MonsterStrikes.is_own_unpaired(66, others, left, 5000), "nor one who left 4 s ago")
	_check(not MonsterStrikes.is_own_unpaired(66, others, left, 1000 + MonsterStrikes.LEFT_GRACE_MS),
		"the grace window is inclusive at LEFT_GRACE_MS")
	_check(MonsterStrikes.is_own_unpaired(66, others, left, 1001 + MonsterStrikes.LEFT_GRACE_MS),
		"past the grace window the id is this player's again")

## Round 548: whether a kill LEFT the player dead. A server with the dead
## state reports HP 0; every server before it respawned the player in the
## same call and reported the respawned HP (40 % of the maximum, above 0).
func _test_leaves_dead() -> void:
	_check(MonsterStrikes.leaves_dead(true, 0), "a kill reported at HP 0 leaves the player dead")
	_check(not MonsterStrikes.leaves_dead(true, 80), "a kill reported with the respawned HP (today's server) does not")
	_check(not MonsterStrikes.leaves_dead(false, 0), "a blow that did not kill never does, whatever the HP")

	# Round 640: a counter the player's wall took whole is a counter; the push
	# repeating it pairs with it by the wall's damage too.
	var walled := _result(0, 100)
	walled.wall = CombatNet.WallHit.new()
	walled.wall.absorbed = true
	walled.wall.damage = 64
	_check(MonsterStrikes.result_countered(walled), "a counter the wall took (0 on the player) is a counter")
	var waits := {}
	var wait := MonsterStrikes.expect(waits, 7, walled)
	var push := _push_for(walled, 42)
	push.wall = CombatNet.WallHit.new()
	push.wall.absorbed = true
	push.wall.damage = 63
	_check(not MonsterStrikes.repeats(wait, push), "a push whose wall took another amount does not repeat it")
	push.wall.damage = 64
	_check(MonsterStrikes.repeats(wait, push), "a push whose wall took the same amount repeats it")

func _init() -> void:
	_test_result_countered()
	_test_drawn_once()
	_test_claims()
	_test_own_unpaired()
	_test_leaves_dead()

## World3D's glue, on a bare World3D (no scene; the nodes it touches are set
## by hand). Loaded in _initialize, not _init: World3D names the NetClient
## autoload, which a --script suite registers only after _init
## (monster_motion_test.gd).
func _initialize() -> void:
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var world_ok := world_script != null and world_script.can_instantiate()
	_check(world_ok, "World3D compiles in _initialize")
	if world_ok:
		_test_world_strikes(world_script)
		_test_world_spawn_facing(world_script)
		_test_world_exchange_line(world_script)
		_test_world_dead_state(world_script)
	_test_hud_revive_prompt()
	# The in-tree check waits frames, so a watchdog fails the suite rather
	# than hanging it if a script error stops it before it reports
	# (hud_click_routing_test's pattern).
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	_check(root.is_inside_tree(), "the probe: after one frame the root is in the tree")
	await _test_hud_prompt_off_the_tree()
	await _test_hud_prompt_freed()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## The front a body turned by `yaw` carries its measured -Z onto.
func _front(body: Node3D) -> Vector3:
	return Basis(Vector3.UP, body.rotation.y) * Vector3(0, 0, -1)

## A Mangyang body (a -Z front, round 533) at the origin, the player 10 along
## +x, another player 10 along +z. The fallback never turns the monster, the
## push path turns it toward its target, so the body's facing says which of
## the two drew the blow.
func _test_world_strikes(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var player := CharacterBody3D.new()
	player.position = Vector3(10, 0, 0)
	var label := Label.new()
	var body := Node3D.new()
	body.set_meta("model", "mob\\china\\mangnyang.bsr")
	var other := Node3D.new()
	other.position = Vector3(0, 0, 10)
	world.set("player", player)
	world.set("monster_status_label", label)
	(world.get("_monster_bodies") as Dictionary)[7] = body
	(world.get("_other_bodies") as Dictionary)[55] = other
	var waits: Dictionary = world.get("_strike_waits")

	# The usual order: the result, the push, then the blow lands.
	var r1 := _result(12, 88)
	var w1 := MonsterStrikes.expect(waits, 7, r1)
	world.call("_on_monster_attacked", _push_for(r1, 42))
	_check(body.rotation.y == 0.0, "the attacker's own push is not drawn on receipt")
	world.call("_settle_counter", 7, r1, w1)
	_check(_front(body).is_equal_approx(Vector3(1, 0, 0)),
		"as the blow lands the push draws it: the monster turns to the player, +X (front %s)" % str(_front(body)))
	_check(not waits.has(7), "and the wait is done")

	# No push by the time the blow lands (lands_after 0 settles at once).
	body.rotation.y = 0.0
	var r2 := _result(15, 73)
	world.call("_draw_counter_at_landing", 7, r2, 0.0)
	_check(waits.has(7) and bool(waits[7][0]["drawn"]), "with no push the result draws it and the wait is marked drawn")
	world.call("_on_monster_attacked", _push_for(r2, 42))
	_check(body.rotation.y == 0.0 and not waits.has(7), "a push that comes late is swallowed, not drawn a second time")

	# Another player's blow, even one repeating a counter this client waits
	# on: drawn at once, on that player, and the wait is left alone.
	var r3 := _result(9, 140)
	var w3 := MonsterStrikes.expect(waits, 7, r3)
	world.call("_on_monster_attacked", _push_for(r3, 55))
	_check(_front(body).is_equal_approx(Vector3(0, 0, 1)),
		"a blow on another player is drawn at once, the monster turned to that body, +Z (front %s)" % str(_front(body)))
	_check(w3["push"] == null, "and does not claim this client's own counter")
	waits.clear()

	# A blow on a target this client has not drawn was the swing alone,
	# unturned, in round 540; since round 546 it is this player's own blow by
	# elimination -- the case below, "Round 546, the monster's own swing".

	# A killing counter shows the death line.
	var r4 := _result(200, 76, false, true, true)
	MonsterStrikes.expect(waits, 7, r4)
	label.text = ""
	world.call("_on_monster_attacked", _push_for(r4, 42))
	_check(label.text == "You were killed. Lost 25900 experience.", "a killing blow on this player shows the death line (got '%s')" % label.text)
	waits.clear()

	# A late push for a killing counter the result already drew (CLAIM_DRAWN)
	# repaints nothing: a status line written since stays, as the HP a newer
	# result set would on a real HUD (the same _show_own_strike sets both).
	# Until round 544 it wrote the death line and the push's HP over them.
	var r5 := _result(200, 76, false, true, true)
	world.call("_draw_counter_at_landing", 7, r5, 0.0)
	label.text = "Hit for 30 -- it died!"
	world.call("_on_monster_attacked", _push_for(r5, 42))
	_check(label.text == "Hit for 30 -- it died!" and not waits.has(7),
		"a late push for a counter the result drew is swallowed without repainting (got '%s')" % label.text)

	# A body walking a leg is not turned by a blow it deals: it keeps facing
	# its path, as a spawn heading leaves it (round 544).
	body.rotation.y = 0.0
	(world.get("_monster_motion") as Dictionary)[7] = {"pos": Vector2.ZERO, "dest": Vector2(0, 40), "speed": 8.0,
		"mode": 0, "moving": true, "stop": false}
	world.call("_on_monster_attacked", _push_for(_result(9, 140), 55))
	_check(body.rotation.y == 0.0, "a blow drawn on a walking monster does not turn it off its path")
	(world.get("_monster_motion") as Dictionary).erase(7)

	# Round 546, the monster's own swing: a push on a target drawn nowhere,
	# with no counter waiting, is this player's -- drawn at once, the monster
	# turned to the player, and a killing one shows the death line. Before
	# this round it was the swing alone, unturned, and no line.
	body.rotation.y = 0.0
	label.text = ""
	world.call("_on_monster_attacked", _push_for(_result(200, 76, false, true, true), 77))
	_check(_front(body).is_equal_approx(Vector3(1, 0, 0)),
		"an unpaired blow on an undrawn target is drawn on this player: the monster turns to +X (front %s)" % str(_front(body)))
	_check(label.text == "You were killed. Lost 25900 experience.",
		"and a killing one shows the death line (got '%s')" % label.text)
	_check(not waits.has(7), "and it leaves no wait behind")
	# ...unless that target left the zone a moment ago: the swing alone.
	body.rotation.y = 0.0
	label.text = ""
	(world.get("_recently_left") as Dictionary)[78] = Time.get_ticks_msec()
	world.call("_on_monster_attacked", _push_for(_result(200, 76, false, true, true), 78))
	_check(body.rotation.y == 0.0 and label.text == "",
		"a blow on a player who left inside the grace window is the swing alone (label '%s')" % label.text)
	(world.get("_recently_left") as Dictionary).clear()

	other.free()
	body.free()
	label.free()
	player.free()
	world.free()

## OpMonsterSpawned's heading faces a standing body; a walking one keeps
## facing its path.
func _test_world_spawn_facing(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var body := Node3D.new()
	body.set_meta("model", "mob\\china\\mangnyang.bsr")
	(world.get("_monster_bodies") as Dictionary)[31] = body
	world.call("_face_monster_heading", 31, PI / 2.0)
	_check(_front(body).is_equal_approx(Vector3(0, 0, 1)), "heading pi/2 faces the body +Z (front %s)" % str(_front(body)))
	world.call("_face_monster_heading", 31, 0.0)
	_check(_front(body).is_equal_approx(Vector3(1, 0, 0)), "heading 0 faces it +X (front %s)" % str(_front(body)))
	(world.get("_monster_motion") as Dictionary)[31] = {"pos": Vector2.ZERO, "dest": Vector2(0, 40), "speed": 8.0,
		"mode": 0, "moving": true, "stop": false}
	world.call("_face_monster_heading", 31, PI)
	_check(_front(body).is_equal_approx(Vector3(1, 0, 0)), "a body walking a leg is not re-faced")
	var capsule := Node3D.new()
	(world.get("_monster_bodies") as Dictionary)[32] = capsule
	world.call("_face_monster_heading", 32, PI / 2.0)
	_check(capsule.rotation.y == 0.0, "a body with no measured front is left as it is")
	capsule.free()
	body.free()
	world.free()

## The combat status label: "Took N" only when a counter dealt N > 0.
func _test_world_exchange_line(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var quiet := String(world.call("_exchange_line", _result(0, 100)))
	_check(not quiet.contains("Took") and not quiet.contains("Blocked"),
		"a swing with no counter says nothing about one (got '%s')" % quiet)
	_check(String(world.call("_exchange_line", _result(12, 88))).ends_with("Took 12 damage (HP 88)."), "a counter says what it took")
	_check(String(world.call("_exchange_line", _result(24, 76, false, true))).contains("Took 24 -- critical!"), "a critical says so")
	_check(String(world.call("_exchange_line", _result(0, 100, true))).ends_with("Blocked it (HP 100)."), "a block says so")
	var walled := _result(0, 100)
	walled.wall = CombatNet.WallHit.new()
	walled.wall.absorbed = true
	walled.wall.damage = 64
	_check(String(world.call("_exchange_line", walled)).ends_with("Your wall took 64 (HP 100)."), "a wall's blow says so")
	world.free()

## Round 548, the dead state: a killing blow reported at HP 0 enters it --
## input locked, the state set -- and one reported with the respawned HP
## (today's server) does not; a refused OpReviveResult leaves it as it was and
## one with no error brings the player back. Driven through the push path:
## the monster's own swing under -monster-battle is the case with no result
## before it. Not driven: the die clip (no body here) and the HUD (below).
func _test_world_dead_state(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var player := CharacterBody3D.new()
	var label := Label.new()
	world.set("player", player)
	world.set("monster_status_label", label)

	# Today's server: the kill and the respawn in one report, HP 76 after.
	world.call("_on_monster_attacked", _push_for(_result(200, 76, false, true, true), 77))
	_check(not bool(world.get("_player_dead")), "a kill reported with the respawned HP leaves the player alive (today's server)")
	_check(label.text == "You were killed. Lost 25900 experience.", "and still shows the death line (got '%s')" % label.text)

	# A server with the dead state: HP 0, and the player stays down.
	world.set("_has_move_target", true)
	world.set("_left_steering", true)
	world.set("_qa_attacking", true)
	world.call("_on_monster_attacked", _push_for(_result(200, 0, false, true, true), 77))
	_check(bool(world.get("_player_dead")), "a kill reported at HP 0 leaves the player dead")
	_check(not bool(world.get("_has_move_target")) and not bool(world.get("_left_steering")),
		"the walk under way ends with it")
	_check(not bool(world.get("_qa_attacking")), "and so does the QA attack loop")
	_check(String(world.call("_dispatch_left_click", Vector2.ZERO)) == "dead", "a world click does nothing while dead")
	world.call("_attack_monster", 7)
	_check((world.get("_pending_attack") as Dictionary).is_empty(), "an attack while dead is neither walked nor sent")
	# Round 550: the Skills tab's Use, the one cast route round 548 missed. A
	# skill and a target are selected, so the ungated path would reach the
	# send -- and would first forget the released attack (_released_attack),
	# which is the sentinel here (NetClient is not connected in this suite).
	var skill_list := ItemList.new()
	skill_list.add_item("Smash")
	skill_list.select(0)
	var monster_list := ItemList.new()
	monster_list.add_item("Mangyang")
	monster_list.select(0)
	var skills: Array[SkillNet.SkillSnapshot] = [SkillNet.SkillSnapshot.new()]
	var monsters: Array[CombatNet.MonsterSnapshot] = [CombatNet.MonsterSnapshot.new()]
	world.set("skill_list", skill_list)
	world.set("monster_list", monster_list)
	world.set("_skills", skills)
	world.set("_monsters", monsters)
	world.set("_released_attack", {"monster_id": 7})
	world.call("_on_skill_use_pressed")
	_check(not (world.get("_released_attack") as Dictionary).is_empty(), "the Skills tab's Use while dead sends nothing (the released attack is not forgotten)")
	# Round 550: a held pose is not replaced. The die clip is held; a swing
	# whose result arrives after it is refused, and the held clip stays.
	var die := _clip(2)
	var swing := _clip(2)
	world.call("_hold_player_one_shot", die)
	_check(is_same(world.get("_player_one_shot"), die) and bool(world.get("_player_one_shot_hold")), "the die clip is played and held")
	_check(float(world.call("_play_player_once", swing)) == 0.0 and is_same(world.get("_player_one_shot"), die),
		"a one-shot started over the held die clip is refused, and the held clip stays")
	world.call("_hold_player_one_shot", die)
	_check(is_same(world.get("_player_one_shot"), die) and bool(world.get("_player_one_shot_hold")), "the repeated kill report's second pose keeps the hold")
	# A second kill report (the push repeating a result's) changes nothing.
	world.call("_on_monster_attacked", _push_for(_result(200, 0, false, true, true), 77))
	_check(bool(world.get("_player_dead")), "a repeated kill report keeps the state")

	# The server refused the revive: still dead.
	var refused := WorldNet.ReviveResult.new()
	refused.error = "not dead"
	world.call("_on_revive_result", refused)
	_check(bool(world.get("_player_dead")), "a refused revive leaves the player dead")

	# Revived at 40 % (80 of 200): back on its feet.
	var revived := WorldNet.ReviveResult.new()
	revived.hp = 80
	revived.mp = 40
	world.call("_on_revive_result", revived)
	_check(not bool(world.get("_player_dead")), "a revive result with no error brings the player back")
	_check(not bool(world.get("_player_one_shot_hold")), "and releases the held pose")
	# Alive again: the Skills tab's Use goes through (to a NetClient that is
	# not connected, which sends nothing), and a one-frame die clip -- one
	# that cannot start -- sets no hold on the swing that is playing.
	world.set("_released_attack", {"monster_id": 7})
	world.call("_on_skill_use_pressed")
	_check((world.get("_released_attack") as Dictionary).is_empty(), "revived, the Skills tab's Use goes through")
	world.call("_play_player_once", swing)
	world.call("_hold_player_one_shot", _clip(1))
	_check(is_same(world.get("_player_one_shot"), swing) and not bool(world.get("_player_one_shot_hold")),
		"a die clip of one frame starts nothing and holds nothing (the swing under way is not pinned)")

	skill_list.free()
	monster_list.free()
	label.free()
	player.free()
	world.free()

## A clip of `frames` keyframes on one bone, half a second long.
func _clip(frames: int) -> BanReader.ParsedAnimation:
	var anim := BanReader.ParsedAnimation.new()
	anim.duration_ms = 500
	var bone := BanReader.Bone.new()
	for i in frames:
		bone.keyframes.append(BanReader.Keyframe.new())
	anim.bones.append(bone)
	return anim

## Round 548, the Revive button on a bare HUD (no archive, not in the tree):
## show puts one prompt up with a Revive button whose click emits
## revive_requested; a second show replaces the first; hide takes it down.
func _test_hud_revive_prompt() -> void:
	var panels_script := load("res://scripts/ui/hud/hud_panels.gd") as GDScript
	var panels_ok := panels_script != null and panels_script.can_instantiate()
	_check(panels_ok, "HudPanels compiles in _initialize")
	if not panels_ok:
		return
	var panels: Control = panels_script.new()
	var fired := [0]
	panels.connect("revive_requested", func() -> void: fired[0] += 1)
	panels.call("show_revive_prompt", "You were killed.")
	var prompt := panels.get_node_or_null("RevivePrompt")
	_check(prompt != null, "show_revive_prompt puts the prompt on the HUD")
	var button: Button = prompt.find_child("Revive", true, false) as Button if prompt != null else null
	_check(button != null, "with a Revive button")
	if button != null:
		button.pressed.emit()
	_check(fired[0] == 1, "clicking it emits revive_requested once (got %d)" % fired[0])
	panels.call("show_revive_prompt", "You were killed.")
	var prompts := panels.get_children().filter(func(c: Node) -> bool: return c.name == "RevivePrompt")
	_check(prompts.size() == 1, "a second show replaces the first (%d prompt(s) on the HUD)" % prompts.size())
	panels.call("hide_revive_prompt")
	_check(panels.get_node_or_null("RevivePrompt") == null, "hide_revive_prompt takes it down")
	# Round 550: the bag's right-click use while dead goes to chat, not out.
	var notices: Array[String] = []
	panels.connect("system_notice", func(text: String) -> void: notices.append(text))
	var icon := TextureRect.new()
	icon.set_meta("inv_slot", 3)
	icon.set_meta("inv_item_id", 4)
	icon.set_meta("inv_qty", 1)
	# The use is on the right RELEASE (round 652: CIFSlotWithHelp's vslot 33).
	var right := InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = false
	panels.set("player_dead", true)
	panels.call("_on_inventory_cell_input", right, icon)
	_check(notices.size() == 1 and notices[0] == "You are dead. Revive first.", "a right-click on a bag item while dead says so in chat (got %s)" % str(notices))
	panels.set("player_dead", false)
	panels.call("_on_inventory_cell_input", right, icon)
	_check(notices.size() == 1, "alive, the same click is not refused here (the server decides)")
	icon.free()
	panels.free()

## Round 550: a prompt whose HUD leaves the tree before the frame it waits
## for is left where it is -- no viewport is read off the tree. Until then
## is_instance_valid let get_viewport_rect run on the node outside the tree
## (an engine error) and placed it at a negative x. Needs the root in the
## tree, which a --script suite has only after _initialize's first frame.
func _test_hud_prompt_off_the_tree() -> void:
	var panels_script := load("res://scripts/ui/hud/hud_panels.gd") as GDScript
	if panels_script == null:
		return
	var panels: Control = panels_script.new()
	root.add_child(panels)
	_check(panels.is_inside_tree(), "the probe: the HUD is in the tree")
	panels.call("show_revive_prompt", "You were killed.")
	var prompt: Control = panels.get_node_or_null("RevivePrompt")
	_check(prompt != null and prompt.is_inside_tree(), "the prompt is up, waiting for its frame")
	root.remove_child(panels)
	await process_frame
	await process_frame
	_check(is_instance_valid(prompt) and prompt.position == Vector2.ZERO,
		"a prompt whose HUD left the tree before its frame is left unplaced (position %s)" % (str(prompt.position) if is_instance_valid(prompt) else "freed"))
	panels.free()

## Round 551: a prompt hidden in the same frame it was shown -- a kill result
## and a revive result in one NetClient batch, or a second show, which hides
## first -- is FREED before show_revive_prompt's coroutine resumes:
## hide_revive_prompt's queue_free runs at the end of that frame, the
## coroutine on the next frame's process_frame. The coroutine must test
## is_instance_valid before it asks the node anything; round 550's
## is_inside_tree alone was "Attempt to call function 'is_inside_tree' in
## base 'previously freed'", a script error. The harness greps output for
## FAIL and a script error prints no such word, so the negative's evidence is
## that SCRIPT ERROR line (RE_COMPLETION round 551); this case asserts what a
## script can see -- the freed prompt (the probe), a HUD left clean, and a
## fresh prompt afterwards placed after its own frame.
func _test_hud_prompt_freed() -> void:
	var panels_script := load("res://scripts/ui/hud/hud_panels.gd") as GDScript
	if panels_script == null:
		return
	var panels: Control = panels_script.new()
	root.add_child(panels)
	panels.call("show_revive_prompt", "You were killed.")
	var prompt: Control = panels.get_node_or_null("RevivePrompt")
	_check(prompt != null and prompt.is_inside_tree(), "the prompt is up, waiting for its frame")
	panels.call("hide_revive_prompt") # the same frame: removed now, freed at its end
	await process_frame
	await process_frame
	_check(not is_instance_valid(prompt), "the probe: the hidden prompt was freed before the coroutine resumed")
	_check(panels.get_node_or_null("RevivePrompt") == null, "no prompt is left on the HUD")
	panels.call("show_revive_prompt", "You were killed again.")
	var again: Control = panels.get_node_or_null("RevivePrompt")
	await process_frame
	await process_frame
	_check(is_instance_valid(again) and again.is_inside_tree() and again.position != Vector2.ZERO,
		"a fresh prompt after the freed one is placed after its frame (position %s)" % (str(again.position) if is_instance_valid(again) else "freed"))
	root.remove_child(panels)
	panels.free()
