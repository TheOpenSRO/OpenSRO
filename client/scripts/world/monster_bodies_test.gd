extends SceneTree

## Exercises MonsterBodies -- when a monster's body leaves the world, and the
## hold the killer's own client sets on a kill -- run headless:
## `godot4 --headless --path client --script res://scripts/world/monster_bodies_test.gd`
##
## The numbers are fixtures, not the game's: 0.651 s stands in for a swing's
## hit event and 1.4 s for a die clip's length. What is held to account is
## the rule, not a clip.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_live_is_never_freed() -> void:
	var live := {7: true}
	_check(not MonsterBodies.should_free(7, live, {}, 100.0), "a live id is never freed")
	_check(not MonsterBodies.should_free(7, live, {7: 1.0}, 100.0),
		"a live id is never freed, even with an expired hold on it")

func _test_gone_without_hold_is_freed() -> void:
	# Today's rule for anyone else's kill once its clip has run, and for a
	# monster that simply left the list.
	_check(MonsterBodies.should_free(7, {}, {}, 10.0), "an id not in the list and with no hold is freed")
	_check(MonsterBodies.should_free(7, {8: true}, {9: 99.0}, 10.0),
		"another id's hold does not keep this one")

func _test_kill_hold_runs_to_clip_end() -> void:
	var d := {}
	MonsterBodies.hold_for_kill(d, 7, 10.0, 0.651, 1.4)
	_check(not MonsterBodies.should_free(7, {}, d, 11.9),
		"a killed monster is kept while its die clip still runs (t 11.9 < 10.0 + 0.651 + 1.4)")
	_check(MonsterBodies.should_free(7, {}, d, 12.052),
		"a killed monster is freed once its die clip has run (t 12.052)")

func _test_negative_list_right_after_kill() -> void:
	# NEGATIVE: the list reply that follows the kill result by a few ms, and
	# no longer names the monster, must not free it. Before the killer's
	# hold existed this freed the body at once -- the monster vanished.
	var d := {}
	MonsterBodies.hold_for_kill(d, 7, 10.0, 0.651, 1.4)
	_check(not MonsterBodies.should_free(7, {}, d, 10.005),
		"NEGATIVE: a list 5 ms after the kill result, omitting the monster, does not free it")

func _test_no_clip_sets_no_hold() -> void:
	var d := {}
	MonsterBodies.hold_for_kill(d, 7, 10.0, 0.651, 0.0)
	_check(not d.has(7), "die_seconds 0 (no clip to play) sets no hold")
	_check(MonsterBodies.should_free(7, {}, d, 10.005), "so a body with no die clip goes on the next list")

func _test_existing_later_hold_kept() -> void:
	var d := {7: 20.0}
	MonsterBodies.hold_for_kill(d, 7, 10.0, 0.651, 1.4)
	_check(is_equal_approx(float(d[7]), 20.0), "a later hold already on the id is kept")

func _test_clip_start_overwrites_hold() -> void:
	# _begin_monster_death restarts the hold from the clip's real start:
	# the blow landed later than predicted, so the hold moves later.
	var d := {}
	MonsterBodies.hold_for_kill(d, 7, 10.0, 0.651, 1.4)
	d[7] = 10.7 + 1.4
	_check(not MonsterBodies.should_free(7, {}, d, 12.06),
		"the clip-start hold is honoured past the predicted one (t 12.06 < 12.1)")
	_check(MonsterBodies.should_free(7, {}, d, 12.11), "and frees the body when the clip has run")

func _init() -> void:
	_test_live_is_never_freed()
	_test_gone_without_hold_is_freed()
	_test_kill_hold_runs_to_clip_end()
	_test_negative_list_right_after_kill()
	_test_no_clip_sets_no_hold()
	_test_existing_later_hold_kept()
	_test_clip_start_overwrites_hold()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
