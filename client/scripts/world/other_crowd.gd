extends RefCounted
class_name OtherCrowd

## Round 739 (crowd_scale.md section 5, lane B): the per-body systems of other
## players, made not to grow with the crowd. Every rule here is OURS (an
## engineering choice, not a retail value) unless it says READ.
##
## - **B1, the interpolation once a rendered frame** (StepGate, lerp_factor,
##   distance_before_last). World3D walked every other player toward its
##   latest position in every physics step; a slow frame runs up to eight
##   steps (Godot's max_physics_steps_per_frame), so a 1000-body crowd paid
##   its walk eight times a frame and the frame got slower still (r736,
##   MEASURED). The loop now runs once a rendered frame with the steps it
##   covers folded in: k steps of `lerp(target, a)` are one
##   `lerp(target, 1 - (1 - a)^k)`, and the gait test the last step made saw
##   `distance x (1 - a)^(k - 1)`. At one step a frame (60 fps and up) the
##   result is the per-step loop's, bit for bit in the formula.
## - **B4, arrivals built over frames** (BuildQueue). A body costs about
##   10 ms to dress (r736, MEASURED: 1000 in 10.3 s, all in one frame). An
##   arrival now makes the body's node at once -- it is in World3D's
##   `_other_bodies`, so its moves, departure and equipment changes act on it
##   as on any other -- and the dressing (skeleton, plate, click body, sounds)
##   is queued and done nearest the player first, BUILD_BUDGET_USEC a rendered
##   frame (at least MIN_BUILDS_PER_FRAME).
## - **B7, the uid lookup** (UidIndex): retail's u32 uid to the character id,
##   from a map instead of a scan of every body.

## B1: the physics steps of a rendered frame, folded into one tick that runs
## after them (round 739's review, F3: World3D._process, so what it places is
## where the frame's last step left things). add() is each physics step's;
## take() answers the time the frame's steps covered, or a negative number
## when no step ran this frame, and `steps` how many there were.
class StepGate:
	var _pending := 0.0
	var _pending_steps := 0
	var steps := 0

	func add(delta: float) -> void:
		_pending += delta
		_pending_steps += 1

	func take() -> float:
		if _pending_steps == 0:
			steps = 0
			return -1.0
		var total := _pending
		steps = _pending_steps
		_pending = 0.0
		_pending_steps = 0
		return total

## B1 (round 739's review, F6): a body this close to its target (squared, in
## units) is put on it. float32 lerps at one or two steps a frame stop an ulp
## or two short and would write `position` every frame for ever (COMPUTED in
## the review); on it, the body is not touched again. OURS: 1e-6 is a
## thousandth of a unit, far under a pixel.
const SNAP_DISTANCE_SQ := 1e-6

## B1: the fraction of the way to its target a body covers in `steps` physics
## steps of `step_delta` seconds each, when each step covers
## min(speed x step_delta, 1) of what is left: 1 - (1 - a)^steps.
static func lerp_factor(speed: float, step_delta: float, steps: int) -> float:
	var a := minf(speed * step_delta, 1.0)
	if steps <= 1:
		return a
	return 1.0 - pow(1.0 - a, float(steps))

## B1: the distance to its target a body had before the last of `steps` steps
## -- what the per-step loop's gait test saw last.
static func distance_before_last(distance: float, speed: float, step_delta: float, steps: int) -> float:
	if steps <= 1:
		return distance
	var a := minf(speed * step_delta, 1.0)
	return distance * pow(1.0 - a, float(steps - 1))

## B4: the main-thread time a rendered frame may spend dressing arrived
## bodies, in microseconds. OURS: two or three bodies (r736 MEASURED about
## 10 ms a body once its templates are cached), plus the one the at-least-one
## rule may let run over, keeps an arriving frame under the gate's 100 ms
## hitch line while the rest of the frame takes up to about 60 ms; 1000
## arrivals are then dressed in about 400 frames instead of one 10 s frame.
## OPENSRO_QA_OTHER_BUILD_BUDGET_MS overrides it (QA only, for measuring).
const BUILD_BUDGET_USEC := 25000
## Bodies dressed in a frame whatever the budget says, so a queue always drains.
const MIN_BUILDS_PER_FRAME := 1
## Round 748 (OURS): the frame an arrival aims to stay under. Each frame the
## budget is what the last frame left of this after its own work without the
## dressing (BuildQueue.note_frame), at most BUILD_BUDGET_USEC: while the
## crowd's own frame is long the queue dresses fewer bodies a frame (one at
## least) instead of adding its whole budget to a frame already near the
## 100 ms hitch line, and once the frame is short it dresses at full budget.
const HITCH_TARGET_USEC := 90000

## B4: the arrived bodies still to dress, and the frame's budget. The queue
## holds ids only; whatever a body is dressed with is read when it is dressed,
## so what changed while it waited (a plus, an item, a seat, a move) is what
## it shows.
class BuildQueue:
	var budget_usec := BUILD_BUDGET_USEC
	var _pending: Dictionary = {}   # id -> true, in arrival order
	var _frame := -1
	var _spent := 0
	var _built_in_frame := 0
	## Since the queue last started (for the log line when it drains).
	var started_usec := -1
	var frames := 0
	var built := 0
	var longest_usec := 0
	## Each frame's dressing time since the queue started, frame -> usec (the
	## drain line's percentiles).
	var spent_by_frame: Dictionary = {}
	var _last_counted_frame := -1
	## Round 748: ids pump() passed over because `ready` said no (tests, QA).
	var waiting_skips := 0
	## Round 748: the frame whose pump went through every queued body with
	## budget to spare (all the rest were waiting on `ready`), and the ids
	## queued since a pump last looked. A second pump in that frame looks at
	## those only: an arrival list outside a group bracket (QA's lineup: 1000
	## spawns in a frame, each pumping) otherwise sorted and asked the whole
	## queue once per arrival -- O(n^2) in one frame, MEASURED about 0.5 s of
	## the 1000-body spawn frame once nothing in it was ready.
	var _passed_frame := -1
	var _fresh: Array = []

	## Round 748: something new may be ready (templates adopted): the next
	## pump looks at the whole queue again, even in the frame of a full pass.
	func reopen() -> void:
		_passed_frame = -1
	const INDEX_BITS := 20
	const INDEX_MASK := (1 << 20) - 1
	const DIST_KEY_MAX := 4.0e12

	func _init() -> void:
		var qa := OS.get_environment("OPENSRO_QA_OTHER_BUILD_BUDGET_MS")
		if qa.is_valid_float():
			budget_usec = int(float(qa) * 1000.0)

	func queue(id: int) -> void:
		_fresh.append(id)
		if _pending.is_empty():
			started_usec = Time.get_ticks_usec()
			frames = 0
			built = 0
			longest_usec = 0
			spent_by_frame = {}
			_last_counted_frame = -1
		_pending[id] = true

	func has(id: int) -> bool:
		return _pending.has(id)

	func drop(id: int) -> void:
		_pending.erase(id)

	func clear() -> void:
		_pending.clear()

	func size() -> int:
		return _pending.size()

	func is_empty() -> bool:
		return _pending.is_empty()

	func ids() -> Array:
		return _pending.keys()

	## Round 748: this frame's budget (note_frame), and what the last pump
	## spent, which note_frame takes out of the frame it is told.
	var _frame_cap := 1 << 30
	var last_spent := 0

	## Round 748: the last frame's wall time, in microseconds; the next
	## frames' budget becomes HITCH_TARGET_USEC less that frame without its
	## dressing, within [0, budget_usec].
	func note_frame(frame_usec: int) -> void:
		_frame_cap = clampi(HITCH_TARGET_USEC - (frame_usec - last_spent), 0, budget_usec)
		last_spent = 0

	## This frame's budget: budget_usec, or less after note_frame.
	func frame_budget() -> int:
		return mini(budget_usec, _frame_cap)

	## Whether this frame may still dress a body.
	func can_build(frame: int) -> bool:
		_roll(frame)
		return _built_in_frame < MIN_BUILDS_PER_FRAME or _spent < frame_budget()

	func _roll(frame: int) -> void:
		if frame != _frame:
			_frame = frame
			_spent = 0
			_built_in_frame = 0

	## Dresses queued bodies, nearest `from` first, while the frame's budget
	## lasts. `bodies` is id -> Node3D (positions in the same space as
	## `from`); an id with no valid node is dropped. `build` is called with
	## each id. `ready` (round 748), when given, is asked first: an id it
	## answers false for stays queued (its templates are still being made off
	## the main thread) and the next nearest is tried. Returns how many were
	## built.
	##
	## Round 748: the order is one native sort a frame of (squared distance,
	## arrival index) packed into an int, not a scan of the queue for every
	## body dressed -- with bodies waiting on `ready` that scan was O(n^2) a
	## frame. Squared distances are kept to 1/256 of a unit squared; ties go
	## to the earlier arrival, as the scan's did.
	func pump(frame: int, from: Vector3, bodies: Dictionary, build: Callable, ready: Callable = Callable()) -> int:
		if _pending.is_empty() or not can_build(frame):
			_fresh.clear()
			return 0
		var ids: Array = _fresh if frame == _passed_frame else _pending.keys()
		_fresh = []
		var order := PackedInt64Array()
		for i in ids.size():
			if not _pending.has(ids[i]):
				continue
			var n = bodies.get(ids[i])
			if not is_instance_valid(n):
				_pending.erase(ids[i])
				continue
			var d := minf((n as Node3D).position.distance_squared_to(from) * 256.0, DIST_KEY_MAX)
			order.append((int(d) << INDEX_BITS) | i)
		order.sort()
		var made := 0
		var all_seen := true
		for key in order:
			if _pending.is_empty() or not can_build(frame):
				all_seen = false
				break
			var id: int = ids[key & INDEX_MASK]
			if not _pending.has(id):
				continue # dropped by an earlier build this frame
			if ready.is_valid() and not bool(ready.call(id)):
				waiting_skips += 1
				continue
			_pending.erase(id)
			var t0 := Time.get_ticks_usec()
			build.call(id)
			_spent += Time.get_ticks_usec() - t0
			_built_in_frame += 1
			made += 1
		if all_seen:
			_passed_frame = frame
		built += made
		last_spent = _spent
		if _last_counted_frame != frame:
			_last_counted_frame = frame
			frames += 1
		longest_usec = maxi(longest_usec, _spent)
		spent_by_frame[frame] = _spent
		return made

	## The drain line's numbers: [p50 ms, p95 ms, frames whose dressing alone
	## took over 100 ms].
	func spent_summary() -> Array:
		var v := PackedFloat32Array()
		for f in spent_by_frame:
			v.append(float(spent_by_frame[f]) / 1000.0)
		if v.is_empty():
			return [0.0, 0.0, 0]
		v.sort()
		var over := 0
		for x in v:
			if x > 100.0:
				over += 1
		return [v[v.size() / 2], v[mini(int(v.size() * 0.95), v.size() - 1)], over]

## B7: retail's u32 uid (a character id's low 32 bits, round 735) to the
## character id, kept as bodies come and go.
class UidIndex:
	var _by_uid: Dictionary = {}

	static func uid_of(character_id: int) -> int:
		return character_id & 0xffffffff

	func add(character_id: int) -> void:
		_by_uid[uid_of(character_id)] = character_id

	func remove(character_id: int) -> void:
		var u := uid_of(character_id)
		if int(_by_uid.get(u, -1)) == character_id:
			_by_uid.erase(u)

	func clear() -> void:
		_by_uid.clear()

	## The character id for `uid`, or -1.
	func find(uid: int) -> int:
		return int(_by_uid.get(uid, -1))

	func size() -> int:
		return _by_uid.size()
