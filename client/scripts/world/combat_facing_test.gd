extends SceneTree

## Round 785: CombatFacing.step, the turn a fighter makes toward what it
## strikes -- 10 radians a second the shorter way round, landing on the
## target within a step, the same at any frame rate.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS ", msg)
	else:
		_failures += 1
		print("FAIL ", msg)

func _near(a: float, b: float) -> bool:
	return absf(wrapf(a - b, -PI, PI)) < 1e-4

func _init() -> void:
	_check(CombatFacing.TURN_RATE == 10.0, "the rate is the client's 10.0 a second (0xe1b840)")
	_check(_near(CombatFacing.step(0.0, 1.0, 0.05), 0.5), "0.05 s turns 0.5 rad toward the target")
	_check(_near(CombatFacing.step(0.0, 0.3, 0.05), 0.3), "within one step it lands on the target")
	_check(_near(CombatFacing.step(0.2, TAU - 0.2, 0.01), 0.1), "the shorter way round, through 0")
	_check(_near(CombatFacing.step(TAU - 0.1, 0.4, 0.02), 0.1), "and back across 2 pi")
	var h := CombatFacing.step(0.0, 3.0, 0.1)
	_check(h >= 0.0 and h < TAU, "the result is in [0, 2 pi)")
	# Frame-rate independence: a half turn takes the same time at 30, 60 and
	# 144 steps a second (pi / 10 = 0.314 s).
	for fps in [30.0, 60.0, 144.0]:
		var cur := 0.0
		var t := 0.0
		while not _near(cur, PI) and t < 2.0:
			cur = CombatFacing.step(cur, PI, 1.0 / fps)
			t += 1.0 / fps
		_check(absf(t - PI / 10.0) <= 1.0 / fps + 1e-6,
			"a half turn at %d steps a second takes %.3f s (pi / 10 = %.3f)" % [int(fps), t, PI / 10.0])
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
