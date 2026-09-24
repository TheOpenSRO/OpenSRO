extends SceneTree

## Exercises QaAttackGoto -- which monster SRREVAMP_QA_ATTACK_GOTO stands
## beside, and where, from a fresh monster list (round 539) -- run headless:
## `godot4 --headless --path client --script res://scripts/qa/qa_attack_goto_test.gd`
##
## The monsters are fixtures, not the game's. What is held to account is the
## rule: the list's own positions, the preferred id first, the name filter,
## and never a dead or dying monster.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _snap(id: int, species: String, x: float, z: float, hp: int = 100) -> CombatNet.MonsterSnapshot:
	var m := CombatNet.MonsterSnapshot.new()
	m.monster_id = id
	m.monster_name = species
	m.x = x
	m.y = 5.0
	m.z = z
	m.hp = hp
	m.max_hp = 100
	return m

func _id_of(m: CombatNet.MonsterSnapshot) -> int:
	return -1 if m == null else m.monster_id

func _test_preferred_id_wins_while_listed_alive() -> void:
	var fresh := [_snap(4, "Mangyang", 30.0, 0.0), _snap(7, "Mangyang", 300.0, 0.0)]
	_check(_id_of(QaAttackGoto.pick(fresh, 7, "Mangyang", Vector3.ZERO, {})) == 7,
		"the id picked from the drawn bodies is kept while the fresh list has it alive, nearer ones notwithstanding")

func _test_nearest_by_the_lists_position_otherwise() -> void:
	# The preferred id died since: the nearest by the LIST's positions, not by
	# anything drawn.
	var fresh := [_snap(4, "Mangyang", 90.0, 0.0), _snap(10, "Mangyang", 0.0, 40.0)]
	_check(_id_of(QaAttackGoto.pick(fresh, 7, "Mangyang", Vector3(0.0, 99.0, 0.0), {})) == 10,
		"without the preferred id, the listed monster nearest the player on the ground plane")

func _test_name_filter() -> void:
	var fresh := [_snap(3, "Yeoha", 5.0, 0.0), _snap(4, "Mangyang", 50.0, 0.0)]
	_check(_id_of(QaAttackGoto.pick(fresh, -1, "Mangyang", Vector3.ZERO, {})) == 4,
		"SRREVAMP_QA_ATTACK_NAME narrows the pick (the nearer Yeoha is passed over)")
	_check(_id_of(QaAttackGoto.pick(fresh, -1, "", Vector3.ZERO, {})) == 3,
		"no name: any species")
	_check(_id_of(QaAttackGoto.pick(fresh, 3, "Mangyang", Vector3.ZERO, {})) == 4,
		"a preferred id whose name does not match is not taken")

func _test_never_dead_or_dying() -> void:
	var fresh := [_snap(4, "Mangyang", 5.0, 0.0, 0), _snap(7, "Mangyang", 6.0, 0.0), _snap(10, "Mangyang", 60.0, 0.0)]
	_check(_id_of(QaAttackGoto.pick(fresh, 4, "Mangyang", Vector3.ZERO, {7: 12.5})) == 10,
		"a listed monster with no HP, or one held for its death clip, is never picked")
	_check(QaAttackGoto.pick([], 4, "Mangyang", Vector3.ZERO, {}) == null, "an empty list picks nothing")

func _test_stand_spot_is_the_lists_position() -> void:
	var m := _snap(4, "Mangyang", 120.0, -40.0)
	var spot := QaAttackGoto.stand_spot(m)
	_check(spot.is_equal_approx(Vector3(128.0, 5.0, -40.0)),
		"the player stands STAND_OFFSET (8 along +x) from the listed position: %s" % str(spot))
	_check(QaAttackGoto.STAND_OFFSET.length() <= CombatNet.approach_band(CombatNet.PLAYER_BC_RADIUS, 6, 0.0).x,
		"the offset is inside an unarmed swing's stop distance on a Mangyang (BCRadius 6)")

func _test_no_second_teleport_onto_the_spot() -> void:
	var spot := Vector3(128.0, 5.0, -40.0)
	_check(not QaAttackGoto.needs_teleport(Vector3(128.4, 9.0, -40.3), spot),
		"a player already on the stand spot (0.5 away, any height) is not moved again")
	_check(QaAttackGoto.needs_teleport(Vector3(128.0, 5.0, -38.9), spot),
		"a player 1.1 from the stand spot is moved")
	_check(QaAttackGoto.needs_teleport(Vector3(1500.0, 5.0, 900.0), spot), "a player far away is moved")

func _init() -> void:
	_test_preferred_id_wins_while_listed_alive()
	_test_nearest_by_the_lists_position_otherwise()
	_test_name_filter()
	_test_never_dead_or_dying()
	_test_stand_spot_is_the_lists_position()
	_test_no_second_teleport_onto_the_spot()
	if _failures == 0:
		print("qa_attack_goto_test: all passed")
	else:
		print("qa_attack_goto_test: %d FAILURES" % _failures)
	quit(1 if _failures > 0 else 0)
