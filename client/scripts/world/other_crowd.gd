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

## Round 762 (OURS; docs/rounds/r762.md): one budget a rendered frame for
## everything a crowd arriving or leaving adds to it -- NetClient reading a
## group spawn or despawn, the arrived bodies' holders, their ghosts, a held
## page's reveal and activation, the departures and the holders freed -- so
## that no frame of a walk into or out of a crowd is longer than the crowd's
## own frames (the user's rule: "It should perform that as in the crowd and
## only get faster, not worse").
##
## The frame is aimed at the scene's own frame: the p90 of the last HISTORY
## steady frames' time (no crowd arriving or leaving in them) less the work
## charged here, and at least TARGET_FLOOR_USEC -- a page held before it is
## drawn is a light scene, and the crowd it becomes is heavier.
## This frame's budget is that aim less the last frame's own time, within
## [MIN_USEC, MAX_USEC]: where the scene is already at its aim the work still
## goes on at MIN_USEC a frame. Each user charges what it spent (spend()).
class FrameBudget:
	const TARGET_FLOOR_USEC := 5000
	const MIN_USEC := 1500
	const MAX_USEC := 12000
	const HISTORY := 120
	static var _frame := -1
	static var _t0 := 0
	static var _spent := 0
	static var _budget := MIN_USEC
	static var _own := PackedFloat32Array()
	static var _own_at := 0
	static var _aim := float(TARGET_FLOOR_USEC)
	## QA: the last frame's own time and charged work, and the aim (usec).
	static var last_own := 0
	static var last_spent := 0
	## Round 764: the main thread's wait before this frame (FrameMark), and
	## whether the budget counts the work alone (OPENSRO_QA_BUDGET_WORK=0: the
	## whole frame, as round 762 did).
	static var last_wait := 0
	static var use_work := OS.get_environment("OPENSRO_QA_BUDGET_WORK") != "0"

	## Round 764: a frame's budget from the aim, the last frame's own time
	## (wall less what was charged) and the main thread's wait in it. While
	## the frame keeps to its aim, the aim less the work (own less the wait);
	## past it, the aim less the whole frame; within [MIN_USEC, MAX_USEC].
	static func budget_for(aim: int, own: int, wait: int, work: bool) -> int:
		if work and own <= aim and wait > 0 and wait < own:
			# The review's F5: the wait between frames also holds main-thread
			# work (the deferred calls and the delete queue's flush, input, the
			# physics queries), so it is not all room: WORK_MARGIN of the aim
			# is kept back (OURS).
			return clampi(int(float(aim) * WORK_MARGIN) - (own - wait), MIN_USEC, MAX_USEC)
		return clampi(aim - own, MIN_USEC, MAX_USEC)

	const WORK_MARGIN := 0.85

	## The frame rolls on the first call in it.
	static func _roll() -> void:
		var f := Engine.get_process_frames()
		if f == _frame:
			return
		var now := Time.get_ticks_usec()
		if _frame >= 0 and f == _frame + 1:
			var own := maxi(int(now - _t0) - _spent, 0)
			last_own = own
			last_spent = _spent
			# Only a steady frame (no crowd arriving or leaving, World3D's
			# steady()) is the scene's own: during an arrival the frames are
			# also slowed by what the budget does not see (the templates made
			# on the workers, the render thread's updates), and an aim
			# learned from them rose to 30-36 ms (MEASURED r762.md).
			if _steady:
				if _own.size() < HISTORY:
					_own.append(float(own))
				else:
					_own[_own_at] = float(own)
					_own_at = (_own_at + 1) % HISTORY
			if f % 15 == 0 and _own.size() >= 15:
				var v := _own.duplicate()
				v.sort()
				_aim = maxf(float(TARGET_FLOOR_USEC), v[int(0.9 * (v.size() - 1))])
			# Round 764 (OURS): while the frame keeps to its aim, the budget is
			# what the main thread's WORK leaves of it -- its own time less
			# its wait between frames (FrameMark: the render thread's sync, a
			# vsync), when the main thread is idle and work there does not
			# make the frame longer. Before, the budget was the aim less the
			# whole frame, so on a frame the GPU or the render thread sets (the
			# user's RTX 5080 at 4K: main-thread work p95 2-3 ms in frames of
			# about 11, v0.1.516's log) it sat at MIN_USEC with the main thread
			# idle: a 2,473-body page took 7.2 s to show (r764.md section 2).
			# A frame over its aim falls back to the old rule.
			last_wait = FrameMark.wait_usec
			_budget = budget_for(int(_aim), own, last_wait, use_work)
		else:
			_budget = MIN_USEC
		_frame = f
		_t0 = now
		_spent = 0
		_steady = true

	## World3D, each frame: whether a crowd is arriving or leaving in it.
	static var _steady := true
	static func note_transition(busy: bool) -> void:
		_roll()
		if busy:
			_steady = false

	## What is left of this frame's budget (usec; may be 0 or less).
	static func left() -> int:
		_roll()
		if unlimited:
			return MAX_USEC
		return _budget - _spent

	## Tests: every call has the whole MAX_USEC (a headless suite runs many
	## arrivals and departures in one frame).
	static var unlimited := false

	static func spend(usec: int) -> void:
		_roll()
		_spent += maxi(usec, 0)

	## The budget a share of a group's reading may take now: half what is
	## left (the rest is the bodies'), within [300, 4000] usec.
	static func group_step_usec() -> int:
		return clampi(left() / 2, 300, 4000)

	static func aim_usec() -> int:
		_roll()
		return int(_aim)

## Round 762's review, F1 (OURS): the main thread's wait between frames -- from
## the last _process callback of a frame (the tail mark, the highest
## process_priority) to the first callback of the next (the head mark, the
## lowest process and physics priority): the message flush, the render
## thread's sync and the draw's queueing, and a vsync wait. With the
## RenderingServer on its own thread (project.godot's thread_model 2) that gap
## is time the main thread could spend without making the frame longer; the
## rest of the frame is its work. World3D's background dressing judges its
## room by the work, not the wall time, so a vsync-limited frame leaves room.
class FrameMark extends Node:
	## The last gap measured (usec), and the tail's clock (-1: none since).
	static var wait_usec := 0
	static var _tail_usec := -1
	var head := true

	func _init(is_head: bool = true) -> void:
		head = is_head
		name = "FrameHead" if is_head else "FrameTail"
		process_priority = -1000000 if is_head else 1000000
		process_physics_priority = -1000000

	func _ready() -> void:
		set_physics_process(head)

	func _physics_process(_delta: float) -> void:
		_head()

	func _process(_delta: float) -> void:
		if head:
			_head()
		else:
			_tail_usec = Time.get_ticks_usec()

	static func _head() -> void:
		if _tail_usec >= 0:
			wait_usec = Time.get_ticks_usec() - _tail_usec
			_tail_usec = -1

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
## Round 756 (OURS): the frame the dressing aims to stay under while every
## body waiting for it is already drawn (a ghost, CrowdGpu.add_ghost): the
## dressing is then background work -- the weapon's particles, the posed near
## body, the clip's one-shots -- and is given what a 30 fps frame leaves, not
## what a 90 ms one does. At least one body a frame still.
const GHOST_HITCH_TARGET_USEC := 33000
## Round 756 (OURS): the main-thread time a frame may spend making ghosts
## (World3D._ghost_other: a recipe looked up, a slot and a texel, an instance
## a part; about 40-60 us a body, MEASURED in r756.md), so a page of 1000
## arriving is drawn in one or two frames.
## The budget follows the frame as the dressing's does (BuildQueue.note_frame,
## HITCH_TARGET_USEC), so a crowd whose own frame is already long gets fewer
## ghosts a frame (one at least) rather than a frame over the hitch line.
##
## Round 762: 12 ms at most, following the frame (was 50, aiming at 90 ms). An arriving page is held until it is whole and
## then revealed in one frame (World3D._hold_step), so its ghosts no longer
## need to be made in one or two frames; at 50 ms they made frames far over a
## standing crowd's own (MEASURED r762.md), and the user's rule is that no
## frame of an arrival is worse than standing in the full crowd.
const GHOST_BUDGET_USEC := 12000
## Round 762 (OURS): the frame the ghosts' work aims to stay under: a 60 fps
## frame. A page is held while its ghosts are made, so the crowd is not drawn
## yet and the frame is light (1.4 ms at the live crowd's spot, MEASURED):
## the ghosts take what is left of 16.7 ms, up to GHOST_BUDGET_USEC, one at
## least; where part of the crowd is drawn already, less.
const GHOST_FRAME_TARGET_USEC := 16700
## Round 762 (OURS): the ghosts' least time a frame. MEASURED live: a second
## block's 1,592 arriving into the 2,400 already drawn (frames of 20-25 ms)
## got one ghost a frame with no floor, 8 s for the page.
const GHOST_MIN_BUDGET_USEC := 4000
## Round 762 (OURS): the dressing's time a frame while every waiting body is
## drawn (a ghost): background work, kept under a standing crowd's frame
## (one body a frame at least, as before).
const GHOST_DRESS_BUDGET_USEC := 4000

## B4: the arrived bodies still to dress, and the frame's budget. The queue
## holds ids only; whatever a body is dressed with is read when it is dressed,
## so what changed while it waited (a plus, an item, a seat, a move) is what
## it shows.
class BuildQueue:
	var budget_usec := BUILD_BUDGET_USEC
	## Round 756: what note_frame aims a frame at (HITCH_TARGET_USEC, or
	## GHOST_HITCH_TARGET_USEC while every waiting body is drawn).
	var target_usec := HITCH_TARGET_USEC
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
		_idle = false
		_rewind = true

	## Round 762 (OURS): arrival order instead of nearest first, walked with a
	## cursor (World3D's ghosts: a held page is revealed whole, so the order
	## its ghosts are made in is not seen). The nearest-first pass builds and
	## sorts a key for every queued id each frame: with a page of 4,000
	## waiting that was about 6 ms of a 12 ms budget a frame (MEASURED
	## r762.md). A pass goes on from where the last one stopped; reopen()
	## starts it again from the oldest.
	var fifo := false
	var _fifo: Array = []
	var _fifo_at := 0
	var _rewind := false

	## Round 762: the last pass went through every queued id with budget to
	## spare: until something changes (reopen) or arrives (queue), there is
	## nothing to look at -- a crowd of 4,000 waiting on its templates, or
	## ghosts beyond the dressing's reach, was a sort and a `ready` call each
	## a frame for nothing (MEASURED r762.md: 80-100 ms frames).
	var _idle := false
	const INDEX_BITS := 20
	const INDEX_MASK := (1 << 20) - 1
	## Squared distance x 256, capped (about 98,800 units): three bands of it,
	## shifted by INDEX_BITS, stay under the int64 range (round 756).
	const DIST_KEY_MAX := 2.5e12

	## The frame the dressing aims to stay under (HITCH_TARGET_USEC);
	## OPENSRO_QA_OTHER_BUILD_HITCH_MS overrides it (round 757, QA only: a
	## 7,000-body lineup otherwise takes about 8 minutes to dress, MEASURED).
	var hitch_usec := HITCH_TARGET_USEC
	var hitch_qa := false

	func _init() -> void:
		var qa := OS.get_environment("OPENSRO_QA_OTHER_BUILD_BUDGET_MS")
		if qa.is_valid_float():
			budget_usec = int(float(qa) * 1000.0)
		var qh := OS.get_environment("OPENSRO_QA_OTHER_BUILD_HITCH_MS")
		if qh.is_valid_float():
			hitch_usec = int(float(qh) * 1000.0)
			hitch_qa = true
		target_usec = hitch_usec

	## Round 756's review, F1: ids dressed before every other, nearest first
	## among themselves (a ghost an aura is waiting on).
	var urgent := {}

	## Puts a queued id first (urgent). Round 762's review, F2: an id not
	## queued (a ghost held with its page, a body not a ghost yet) is
	## remembered, and is urgent when it is queued; forget() drops it (a
	## departure).
	func promote(id: int) -> void:
		if not _pending.has(id):
			_promote_later[id] = true
			return
		if not urgent.has(id):
			urgent[id] = true
			reopen()

	var _promote_later := {}

	## Remembers `id` to be urgent once it is queued again (or wake()), queued
	## now or not: a body whose page is still arriving is not dressed before
	## its page shows.
	func promote_later(id: int) -> void:
		_promote_later[id] = true

	## A remembered id (promote_later) that is queued now is urgent from now.
	func wake(id: int) -> void:
		if _promote_later.has(id) and _pending.has(id):
			_promote_later.erase(id)
			urgent[id] = true
			reopen()

	func remembers(id: int) -> bool:
		return _promote_later.has(id)

	func forget(id: int) -> void:
		_promote_later.erase(id)
		drop(id)

	var _later_built_frame := -1
	## Round 762's review, F1: the last pass stopped at a ghost for want of the
	## background dressing's room.
	var _room_wait := false

	## Round 762: the last pump dressed nothing and stopped at `later_within_sq`:
	## whatever is still queued is a ghost beyond the dressing's reach.
	var settled := false

	func queue(id: int) -> void:
		settled = false
		if _promote_later.has(id):
			_promote_later.erase(id)
			urgent[id] = true
			reopen()
		if fifo:
			if not _pending.has(id):
				_fifo.append(id)
		else:
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
		urgent.erase(id)

	func clear() -> void:
		_pending.clear()
		urgent.clear()
		_promote_later.clear()
		_fifo.clear()
		_fifo_at = 0

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
	## Round 762: the bodies built by the last pump's frame, and the least
	## budget a frame keeps however long the frame was (World3D's ghosts:
	## GHOST_MIN_BUDGET_USEC, so a page arriving into a crowd already drawn
	## still comes in a few seconds).
	var last_built := 0
	var min_budget_usec := 0

	## Round 748: the last frame's wall time, in microseconds; the next
	## frames' budget becomes HITCH_TARGET_USEC less that frame without its
	## dressing, within [0, budget_usec].
	func note_frame(frame_usec: int) -> void:
		_frame_cap = clampi(target_usec - (frame_usec - last_spent), mini(min_budget_usec, budget_usec), budget_usec)
		last_spent = 0
		last_built = 0

	## Round 762: a cap on the frame's budget (World3D: GHOST_DRESS_BUDGET_USEC
	## while every waiting body is drawn).
	var cap_usec := 1 << 30

	## This frame's budget: budget_usec, or less after note_frame.
	func frame_budget() -> int:
		return mini(mini(budget_usec, _frame_cap), cap_usec)

	## Round 762: the bodies built a frame whatever the budget says
	## (MIN_BUILDS_PER_FRAME; World3D: 0 for the background dressing, which
	## waits for a frame with room for it).
	var min_builds := MIN_BUILDS_PER_FRAME

	## Whether this frame may still dress a body.
	func can_build(frame: int) -> bool:
		_roll(frame)
		return _built_in_frame < min_builds or _spent < frame_budget()

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
	##
	## Round 756: an id in `later` (bodies already drawn, ghosts) sorts after
	## every id not in it, nearest first among themselves: a body nobody sees
	## yet is dressed before one that is only waiting for its nodes.
	##
	## Round 762: `later_within_sq`, the squared distance past which an id in
	## `later` is not dressed (World3D: the DRESS_NEAREST nearest); the order
	## being nearest first, the pass ends at the first such id.
	##
	## Round 762: `later_room_usec` (>= 0), the background dressing's room
	## this frame: an id in `later` is built only when it is above 0, one a
	## frame at most (World3D: a ghost is drawn already, and is dressed only
	## in a frame with room for it under the crowd's own frames).
	func pump(frame: int, from: Vector3, bodies: Dictionary, build: Callable, ready: Callable = Callable(), later: Dictionary = {},
			later_within_sq: float = INF, later_room_usec: int = -1) -> int:
		if fifo:
			return _pump_fifo(frame, bodies, build, ready)
		if _pending.is_empty() or not can_build(frame):
			_fresh.clear()
			return 0
		# Round 762's review, F1: a pass that stopped at the ghosts for want of
		# room is taken again whole in a frame that has room (before, the queue
		# went idle there and never looked at them again: no ghost was ever
		# dressed in the background).
		var room_again := _room_wait and later_room_usec > 0 and _later_built_frame != frame
		var full := not ((frame == _passed_frame or _idle) and not room_again)
		var ids: Array = _pending.keys() if full else _fresh
		_fresh = []
		if ids.is_empty():
			return 0
		var order := PackedInt64Array()
		for i in ids.size():
			if not _pending.has(ids[i]):
				continue
			var n = bodies.get(ids[i])
			if not is_instance_valid(n):
				_pending.erase(ids[i])
				urgent.erase(ids[i])
				continue
			var d := minf((n as Node3D).position.distance_squared_to(from) * 256.0, DIST_KEY_MAX)
			# Three bands, nearest first within each: urgent, unseen, ghosts.
			if not urgent.has(ids[i]):
				d += DIST_KEY_MAX * (2.0 if later.has(ids[i]) else 1.0)
			order.append((int(d) << INDEX_BITS) | i)
		order.sort()
		var made := 0
		var all_seen := true
		var cut_on := later_within_sq < INF
		var later_cut := (int(minf(later_within_sq * 256.0, DIST_KEY_MAX) + DIST_KEY_MAX * 2.0) + 1) << INDEX_BITS if cut_on else 0
		var cut := false
		# Round 762: the pass's own time (the `ready` asks too, not only the
		# builds) is held to the frame's budget; the rest of the pass is the
		# next frame's (a page of thousands of new kinds asked in one frame
		# was a 786 ms frame, MEASURED r762.md).
		var pass_t0 := Time.get_ticks_usec()
		var asked := 0
		var later_band := int(DIST_KEY_MAX * 2.0) << INDEX_BITS
		var room_wait := false
		for key in order:
			if _pending.is_empty() or not can_build(frame):
				all_seen = false
				break
			if asked > 0 and Time.get_ticks_usec() - pass_t0 >= frame_budget():
				all_seen = false
				break
			if cut_on and key >= later_cut:
				cut = true
				break
			if later_room_usec >= 0 and key >= later_band and (later_room_usec == 0 or _later_built_frame == frame):
				# The rest are ghosts too (nearest first, the last band).
				room_wait = true
				break
			asked += 1
			var id: int = ids[key & INDEX_MASK]
			if not _pending.has(id):
				continue # dropped by an earlier build this frame
			if ready.is_valid() and not bool(ready.call(id)):
				waiting_skips += 1
				continue
			_pending.erase(id)
			urgent.erase(id)
			if key >= later_band:
				_later_built_frame = frame
			var t0 := Time.get_ticks_usec()
			build.call(id)
			_spent += Time.get_ticks_usec() - t0
			_built_in_frame += 1
			made += 1
		if all_seen:
			_passed_frame = frame
			_idle = true
		else:
			# The budget ran out: what this pass did not reach is looked at
			# again whole (a pass over `_fresh` alone would lose it).
			_idle = false
		settled = cut and made == 0
		_room_wait = room_wait if full else (_room_wait or room_wait)
		built += made
		last_spent = _spent
		last_built = _built_in_frame
		if _last_counted_frame != frame:
			_last_counted_frame = frame
			frames += 1
		longest_usec = maxi(longest_usec, _spent)
		spent_by_frame[frame] = _spent
		return made

	## Round 762: pump() in arrival order (`fifo`): from the cursor, while the
	## frame's budget lasts (one body at least); an id `ready` says no to is
	## passed and asked again after the next reopen().
	func _pump_fifo(frame: int, bodies: Dictionary, build: Callable, ready: Callable) -> int:
		if _pending.is_empty():
			_fifo.clear()
			_fifo_at = 0
			_rewind = false
			return 0
		if not can_build(frame):
			return 0
		# A pass under way runs to its end before a reopen() starts the next
		# from the oldest (a rewind every adoption re-asked the oldest waiting
		# ids frame after frame and never reached the ready ones behind them).
		if _fifo_at >= _fifo.size():
			if not _rewind:
				return 0
			_rewind = false
			_fifo = _pending.keys()
			_fifo_at = 0
		var made := 0
		var pass_t0 := Time.get_ticks_usec()
		var asked := 0
		while _fifo_at < _fifo.size():
			if not can_build(frame) or (asked > 0 and Time.get_ticks_usec() - pass_t0 >= frame_budget()):
				break
			var id: int = _fifo[_fifo_at]
			_fifo_at += 1
			if not _pending.has(id):
				continue
			var n = bodies.get(id)
			if not is_instance_valid(n):
				_pending.erase(id)
				urgent.erase(id)
				continue
			asked += 1
			if ready.is_valid() and not bool(ready.call(id)):
				waiting_skips += 1
				continue
			_pending.erase(id)
			urgent.erase(id)
			var t0 := Time.get_ticks_usec()
			build.call(id)
			_spent += Time.get_ticks_usec() - t0
			_built_in_frame += 1
			made += 1
		if _fifo_at >= _fifo.size():
			# Every queued id looked at: nothing to do until reopen() or queue().
			_fifo.clear()
			_fifo_at = 0
		elif _fifo_at > 4096:
			_fifo = _fifo.slice(_fifo_at)
			_fifo_at = 0
		built += made
		last_spent = _spent
		last_built = _built_in_frame
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
