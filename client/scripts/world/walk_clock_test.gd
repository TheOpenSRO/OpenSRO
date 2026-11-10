extends SceneTree

## Round 878: the own walk keeps the wall clock (WalkClock). Run headless on the
## render box: `client/tools/remote_godot.sh tests`.
##
## Synthetic frames: Godot runs a frame's physics ticks back to back, at most
## 8 a frame, and drops the rest of a longer frame (MEASURED, round 878's lane
## run j1: a 724 ms frame ran 6 ticks and the walk lost 0.6 s); _process reads
## the clock after them. The walk the ticks plus WalkClock's owed time give is
## checked against the wall clock: steady frame rates walk no extra, a stall's
## dropped time is walked back to within SLACK, the time stood is no walk, a
## gap past MAX_CATCH_UP is not walked.
##
## NEGATIVE: without WalkClock (owed always 0) the stall case walks 133 ms of
## the 724 ms frame -- `_ticks_only` replays that and the check holds it short.

const DT := 1.0 / 60.0
const MAX_STEPS := 8

var _fails := 0

func _initialize() -> void:
	_steady_frames_walk_no_extra()
	_a_stall_is_walked_back()
	_standing_owes_nothing()
	_a_long_gap_is_not_walked()
	print("walk_clock_test: %s" % ("ALL PASS" if _fails == 0 else "%d FAIL" % _fails))
	quit(1 if _fails > 0 else 0)

func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
		print("FAIL: " + what)
	else:
		print("PASS: " + what)

## Plays frames of the given lengths (seconds) through Godot's tick rule and
## the clock (`walking` per frame, or the same for all); returns [walked
## seconds, wall seconds while walking].
func _play(frames: Array, walking: Variant = true, clock: WalkClock = null) -> Array:
	var c := clock if clock != null else WalkClock.new()
	var usec := 1000000
	var accum := 0.0
	var walked := 0.0
	var wall := 0.0
	for i in frames.size():
		var frame: float = frames[i]
		var w: bool = walking[i] if walking is Array else bool(walking)
		usec += int(frame * 1000000.0)
		accum += frame
		var steps := int(floor(accum / DT))
		accum -= steps * DT
		if steps > MAX_STEPS:
			steps = MAX_STEPS # the rest of the frame's time is dropped
		for s in steps:
			var owed := c.tick(DT, w)
			if w:
				walked += DT + owed
		if w:
			wall += frame
		c.frame(usec)
	return [walked, wall]

func _ticks_only(frames: Array) -> float:
	var accum := 0.0
	var walked := 0.0
	for i in frames.size():
		accum += float(frames[i])
		var steps := int(floor(accum / DT))
		accum -= steps * DT
		walked += mini(steps, MAX_STEPS) * DT
	return walked

func _steady_frames_walk_no_extra() -> void:
	for fps in [144.0, 60.0, 30.0, 20.0, 12.0, 8.0]:
		var frames := []
		for i in int(fps * 10.0):
			frames.append(1.0 / fps)
		var r := _play(frames)
		var walked: float = r[0]
		var wall: float = r[1]
		_check(absf(walked - wall) <= WalkClock.SLACK + 2.0 * DT, "%d fps for 10 s: walked %.3f s of %.3f" % [int(fps), walked, wall])

func _a_stall_is_walked_back() -> void:
	var frames := []
	for i in 60:
		frames.append(1.0 / 60.0)
	frames.append(0.724) # the stall
	for i in 60:
		frames.append(1.0 / 60.0)
	var r := _play(frames)
	var walked: float = r[0]
	var wall: float = r[1]
	var base := _ticks_only(frames)
	_check(wall - base > 0.5, "the ticks alone lose the stall: %.3f s of %.3f (NEGATIVE)" % [base, wall])
	_check(absf(walked - wall) <= WalkClock.SLACK + 2.0 * DT, "with the clock a 724 ms stall is walked back: %.3f s of %.3f" % [walked, wall])
	# Three stalls in a row (a region load, a window): still the wall clock.
	frames = []
	for k in 3:
		for i in 30:
			frames.append(1.0 / 60.0)
		frames.append(0.4)
	for i in 30:
		frames.append(1.0 / 60.0)
	r = _play(frames)
	_check(absf(float(r[0]) - float(r[1])) <= WalkClock.SLACK + 2.0 * DT, "three 400 ms stalls: walked %.3f s of %.3f" % [float(r[0]), float(r[1])])

func _standing_owes_nothing() -> void:
	# Standing through a stall, then walking: the stall is not walked.
	var walking := [false, false, false, true, true, true]
	var r := _play([0.016, 0.9, 0.016, 0.016, 0.016, 0.016], walking)
	var walked: float = r[0]
	_check(walked <= 4.0 * DT + 0.001, "a stall stood through owes nothing once the walk starts: walked %.3f s" % walked)
	var c := WalkClock.new()
	_play([0.016, 0.9], false, c)
	_check(c.lag == 0.0 and c.tick(DT, false) == 0.0, "standing keeps no lag (%.3f)" % c.lag)

func _a_long_gap_is_not_walked() -> void:
	var r := _play([0.016, 0.016, 5.0, 0.016])
	var walked: float = r[0]
	_check(walked < 1.0, "a 5 s gap (a loading screen) is not walked back: %.3f s" % walked)
