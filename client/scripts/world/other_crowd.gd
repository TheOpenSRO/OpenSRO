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

## B1: the physics steps since the last rendered frame ticked, folded into one
## tick (as MonsterCrowd.TickGate, which also counts them). take() answers the
## delta to tick with, or a negative number when this rendered frame has ticked
## already; `steps` is how many physics steps the last tick covers.
class StepGate:
	var _frame := -1
	var _pending := 0.0
	var _pending_steps := 0
	var steps := 0

	func take(frame: int, delta: float) -> float:
		if frame == _frame:
			_pending += delta
			_pending_steps += 1
			return -1.0
		_frame = frame
		var total := _pending + delta
		steps = _pending_steps + 1
		_pending = 0.0
		_pending_steps = 0
		return total

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

	func _init() -> void:
		var qa := OS.get_environment("OPENSRO_QA_OTHER_BUILD_BUDGET_MS")
		if qa.is_valid_float():
			budget_usec = int(float(qa) * 1000.0)

	func queue(id: int) -> void:
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

	## Whether this frame may still dress a body.
	func can_build(frame: int) -> bool:
		_roll(frame)
		return _built_in_frame < MIN_BUILDS_PER_FRAME or _spent < budget_usec

	func _roll(frame: int) -> void:
		if frame != _frame:
			_frame = frame
			_spent = 0
			_built_in_frame = 0

	## Dresses queued bodies, nearest `from` first, while the frame's budget
	## lasts. `bodies` is id -> Node3D (positions in the same space as
	## `from`); an id with no valid node is dropped. `build` is called with
	## each id. Returns how many were built.
	func pump(frame: int, from: Vector3, bodies: Dictionary, build: Callable) -> int:
		if _pending.is_empty() or not can_build(frame):
			return 0
		var ids := _pending.keys()
		var dist := PackedFloat32Array()
		dist.resize(ids.size())
		for i in ids.size():
			var n = bodies.get(ids[i])
			if not is_instance_valid(n):
				_pending.erase(ids[i])
				dist[i] = INF
				continue
			dist[i] = (n as Node3D).position.distance_squared_to(from)
		var made := 0
		while not _pending.is_empty() and can_build(frame):
			var best := -1
			var best_d := INF
			for i in ids.size():
				if dist[i] < best_d:
					best_d = dist[i]
					best = i
			if best < 0:
				break
			var id: int = ids[best]
			dist[best] = INF
			_pending.erase(id)
			var t0 := Time.get_ticks_usec()
			build.call(id)
			_spent += Time.get_ticks_usec() - t0
			_built_in_frame += 1
			made += 1
		built += made
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
