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

func _init() -> void:
	_test_result_countered()
	_test_drawn_once()
	_test_claims()
	_test_own_unpaired()

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
	world.free()
