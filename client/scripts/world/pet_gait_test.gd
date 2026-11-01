extends SceneTree

## Round 852: a pet's walk or run and its clip rate (PetGait, READ CICCos
## slot 9 c:0x9c59c0):
## `godot4 --headless --path client --script res://scripts/world/pet_gait_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	# The gait: run above 20, walk at or below it.
	_check(PetGait.runs(50.0) and PetGait.runs(20.5), "a pet at 50 or 20.5 runs")
	_check(not PetGait.runs(20.0) and not PetGait.runs(16.0), "a pet at 20 or 16 (its owner walking) walks")
	# The rate: speed / 50 while it runs and moves.
	_check(is_equal_approx(PetGait.rate(50.0, true, false), 1.0), "running with its owner at 50: x1.0")
	_check(is_equal_approx(PetGait.rate(62.5, true, false), 1.25), "catching up at 50 x 1.25 = 62.5: x1.25")
	_check(is_equal_approx(PetGait.rate(36.0, true, false), 0.72), "a run of 36: x0.72")
	# Walking, or standing: 1.0 whatever the speed.
	_check(is_equal_approx(PetGait.rate(16.0, true, false), 1.0), "walking at 16: x1.0")
	_check(is_equal_approx(PetGait.rate(62.5, false, false), 1.0), "standing: x1.0")
	# The cap and the frostbite share.
	_check(is_equal_approx(PetGait.rate(150.0, true, false), 1.5), "at 150 (a catch-up factor x3 on 50): at most x1.5")
	_check(is_equal_approx(PetGait.rate(62.5, true, true), 0.625), "frostbite halves a run's rate")
	_check(is_equal_approx(PetGait.rate(16.0, true, true), 0.5), "frostbite halves a walk's")
	_check(is_equal_approx(PetGait.rate(150.0, true, true), 1.5), "the cap is taken after frostbite (150 / 50 / 2)")
	# NEGATIVE: the rate is not speed / 50 below the run threshold.
	_check(not is_equal_approx(PetGait.rate(16.0, true, false), 16.0 / 50.0), "NEGATIVE: a walk does not play at speed / 50")
	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILED" % _failures)
	quit(0 if _failures == 0 else 1)
