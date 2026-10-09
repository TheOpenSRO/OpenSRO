extends RefCounted
class_name EfpSimBatch

## Round 759: many effects' simulations stepped at once, spread over
## WorkerThreadPool's threads (EquipFx's masters).
##
## Round 763: when every effect simulates natively (EfpSimNative, EquipFx's
## masters with the library), run() hands the whole batch to Rust
## (native/src/core/efp_batch.rs: this ordered cap, on a Rust thread pool);
## this GDScript Job is the fallback.
##
## **Why.** In the live swarm (7,000 bots in real gear, round 759) the weapons
## in view carry about 50 effect files, and EquipFx keeps one simulated master
## a file: 33 masters active, each 50 ms step about 0.33 ms of GDScript, so
## `efp_sim` was 14.8 ms of a 67.6 ms frame on the main thread (MEASURED,
## the live base step).
##
## **What runs where.** EfpEffect.step_pre (placement: nodes) and step_post
## (the draws: MultiMeshes) stay on the main thread; step_sim -- EfpSim.advance,
## pure data ("no nodes, no textures", EfpSim's header) on the sim's own
## particles, emitters and RandomNumberGenerator -- runs on a pool thread or
## the main thread. An effect is stepped by exactly one thread. The shared
## pieces are read only while the batch runs: each sim's compiled Template
## (built once, before), EfpSim's static quality globals, and EfpReader's
## static helpers; efp_sim.gd, efp_reader.gd and this file are in
## const_array_lint_test's WORKER_FILES (no `const` Array read element by
## element).
##
## **The global particle cap (OURS) decides as the main thread did** (round
## 761; round 759's review F1). The main thread advanced the effects one after
## another in the list's order, each spawn taken while `live_total < limit`.
## So effect i's spawns see base_i = live_total at the batch's start plus the
## whole advance's change of every effect before it, plus its own change so
## far: taken iff base_i + d < limit_i. Here the one shared write,
## EfpSim.live_total, is deferred (each sim counts its own spawns and deaths,
## end_deferred adds them back on the main thread), and the Job answers that
## test for effect i (Job.admit) from what it knows of base_i:
## - effects before i that have finished: their exact change;
## - the rest: bounds (least, most) that each publishes when it starts
##   (EfpSim.growth_bounds: deaths only of those queued, spawns only from
##   emitters that fire), and base_(j+1) <= max(base_j, limit_j), since a
##   spawn is only ever taken below the limit.
## When the bounds decide the test, effect i goes on at once; when they do
## not, it waits (Job.admit's spin) until enough of the effects before it
## have finished -- at the latest all of them, and then base_i is exact. The
## effects are claimed in the list's order, so every effect before i is
## already being stepped, and the first unfinished one never waits: no
## deadlock. Every decision is therefore the main thread's, and so is every
## particle (efp_sim_batch_test: equal frame for frame, per sim, at 8 / 33 /
## 60 sims with the cap binding; round 759's even share, which re-dealt the
## room and never gave out its remainder, is gone). When the cap does not
## bind, the bounds decide every spawn and nothing waits.
##
## **The main thread never waits behind the pool's queue** (HeightBatch's
## pattern, round 757's review F3): the effects are claimed one at a time
## under a Mutex by up to MAX_HELPERS pool tasks and by the main thread
## itself, which waits only for effects a helper has already started.
##
## **No RenderingServer call off the main thread** (round 760): a helper runs
## step_sim alone (EfpSim.advance, data only), so the waits here cannot meet
## Godot 4.7.2's queued RenderingServer calls (PoolWait's header); they stay
## plain waits, marked for pool_wait_lint_test.gd.

## Below this many effects the dispatch costs more than it saves (OURS).
const THREADED_MIN := 4
## Pool tasks a batch posts at most (OURS, HeightBatch's): the main thread is
## one more.
const MAX_HELPERS := 4
## OPENSRO_QA_EFP_THREADS=0 (QA): every effect stepped on the main thread,
## for the A/B.
static var threaded_min := THREADED_MIN if OS.get_environment("OPENSRO_QA_EFP_THREADS") != "0" else 1 << 30

class Job:
	var effects: Array = []
	var delta := 0.0
	var n := 0
	var mutex := Mutex.new()
	var next := 0
	var done := 0
	var by_helpers := 0
	## The ordered cap (round 761), under `mutex` except `limits` (written
	## before the batch, only read during it). Per effect: its cap, the
	## bounds of its change (least, most), whether it finished, and its
	## change. The finished prefix -- effects 0..prefix_n-1 -- with
	## live_total after it.
	var limits := PackedInt32Array()
	var least := PackedInt32Array()
	var most := PackedInt32Array()
	var fin := PackedByteArray()
	var change := PackedInt32Array()
	var prefix_n := 0
	var prefix_base := 0
	var waits := 0
	var wait_usec := 0
	## Effects whose change fell outside the bounds they published (a bug in
	## EfpSim.growth_bounds; the tests hold it at 0).
	var misses := 0
	## QA: thread time (us) in growth_bounds and in the simulations (waits
	## included).
	var bounds_usec := 0
	var sim_usec := 0

	func _claim() -> int:
		mutex.lock()
		var i := next
		if i < n:
			next += 1
		else:
			i = -1
		mutex.unlock()
		return i

	## Effect i: its bounds published, its simulation advanced, its change
	## recorded and the finished prefix walked forward.
	func _step(i: int, helper: bool) -> void:
		var e: EfpEffect = effects[i]
		var sim: EfpSim = e.sim
		var t0 := Time.get_ticks_usec()
		var b: Vector2i = sim.growth_bounds(delta)
		var t1 := Time.get_ticks_usec()
		mutex.lock()
		least[i] = b.x
		most[i] = b.y
		mutex.unlock()
		e.step_sim(delta)
		var d: int = sim._live_delta
		var t2 := Time.get_ticks_usec()
		mutex.lock()
		fin[i] = 1
		change[i] = d
		if d < b.x or d > b.y:
			misses += 1
		while prefix_n < n and fin[prefix_n] != 0:
			prefix_base += change[prefix_n]
			prefix_n += 1
		done += 1
		if helper:
			by_helpers += 1
		bounds_usec += t1 - t0
		sim_usec += t2 - t1
		mutex.unlock()

	## Effect i's spawn at its own change `d`: Vector2i(a, r) such that a
	## spawn at a change below a is surely taken and one at r or above surely
	## refused, with d decided (d < a or d >= r). Waits while d is not,
	## looking again only when another effect has finished (the bounds inline:
	## on the pool's threads every GDScript call is costly, round 761's
	## bench, and a spinning thread must not slow the ones it waits for).
	func admit(i: int, d: int) -> Vector2i:
		var limit: int = limits[i]
		var t0 := 0
		var seen := -1
		while true:
			mutex.lock()
			if done == seen:
				mutex.unlock()
				OS.delay_usec(20)
				continue
			seen = done
			var lo := prefix_base
			var hi := prefix_base
			for j in range(prefix_n, i):
				if fin[j] != 0:
					lo += change[j]
					hi += change[j]
				else:
					lo += least[j]
					hi = mini(hi + most[j], maxi(hi, limits[j]))
			if t0 != 0 and (d < limit - hi or d >= limit - lo):
				waits += 1
				wait_usec += Time.get_ticks_usec() - t0
			mutex.unlock()
			var sure := Vector2i(limit - hi, limit - lo)
			if d < sure.x or d >= sure.y:
				return sure
			if t0 == 0:
				t0 = Time.get_ticks_usec()
		return Vector2i.ZERO

	## A pool task: effects until none is left.
	func help(_task: int) -> void:
		while true:
			var i := _claim()
			if i < 0:
				return
			_step(i, true)

	## The main thread: effects until none is left, then the ones the
	## helpers are still on.
	func work_and_wait() -> void:
		while true:
			var i := _claim()
			if i < 0:
				break
			_step(i, false)
		while true:
			mutex.lock()
			var d := done
			mutex.unlock()
			if d >= n:
				return
			OS.delay_usec(20)

## Groups whose helpers may not have run yet: [group id, Job] (freed by reap).
static var _pending: Array = []
## QA: the last batch's size, whether it was threaded, the effects the
## pool's helpers stepped, how many spawns waited for the effects before
## theirs (and for how long, us), Job.misses, and the thread time in the
## bounds and the simulations (us).
static var last := {"n": 0, "threaded": false, "by_helpers": 0, "waits": 0, "wait_usec": 0, "misses": 0, "bounds_usec": 0, "sim_usec": 0}

## Steps every effect of `effects` (EfpEffects whose step_pre returned true)
## by `delta`: EfpEffect.step_sim each, on the pool when there are enough.
static func run(all: Array, delta: float) -> void:
	reap()
	# Round 763: masters simulated in Rust (EfpSimNative) are stepped by one
	# native batch -- the same ordered cap, on a Rust thread pool, their draws
	# built there too. Its review, L5: a mixed list is split, the native sims
	# to that batch alone and only the GDScript ones to the Job below (never a
	# native sim from a WorkerThreadPool thread). The split changes no
	# decision: the native masters count their particles apart and have no
	# cap (EfpSimNative.live_native), so the two halves never meet. A failed
	# native batch has put its sims back on GDScript: they go below.
	var effects: Array = []
	var native: Array = []
	for e in all:
		var s = (e as EfpEffect).sim
		if s is EfpSimNative and (s as EfpSimNative).is_native():
			native.append(e)
		else:
			effects.append(e)
	if not native.is_empty() and not EfpSimNative.run_batch(native, delta):
		effects = all
	if effects.is_empty():
		return
	var n := effects.size()
	last = {"n": n, "threaded": n >= threaded_min, "by_helpers": 0, "waits": 0, "wait_usec": 0, "misses": 0, "bounds_usec": 0, "sim_usec": 0}
	if n < threaded_min:
		for e in effects:
			(e as EfpEffect).step_sim(delta)
		return
	var j := Job.new()
	j.effects = effects
	j.delta = delta
	j.n = n
	j.limits.resize(n)
	j.least.resize(n)
	j.most.resize(n)
	j.fin.resize(n)
	j.fin.fill(0)
	j.change.resize(n)
	j.change.fill(0)
	j.prefix_base = EfpSim.live_total
	for i in range(n):
		var s: EfpSim = (effects[i] as EfpEffect).sim
		j.limits[i] = EfpSim.limit_for(s.reserved)
		# Until the effect publishes its own (Job._step): all of its
		# particles may die, and it may fill up to MAX_PARTICLES.
		var c := s.particles.size()
		j.least[i] = -c
		j.most[i] = EfpSim.MAX_PARTICLES - c
		s.begin_deferred(j, i)
	var helpers := mini(MAX_HELPERS, n - 1)
	var group := WorkerThreadPool.add_group_task(j.help, helpers, helpers, true, "OpenSRO effect sims")
	_pending.append([group, j])
	j.work_and_wait()
	for e in effects:
		(e as EfpEffect).sim.end_deferred()
	last["by_helpers"] = j.by_helpers
	last["waits"] = j.waits
	last["wait_usec"] = j.wait_usec
	last["misses"] = j.misses
	last["bounds_usec"] = j.bounds_usec
	last["sim_usec"] = j.sim_usec

## Frees the groups whose helpers have all run (a helper that starts after
## every effect is taken returns at once).
static func reap() -> void:
	var keep: Array = []
	for pg in _pending:
		if WorkerThreadPool.is_group_task_completed(int(pg[0])):
			WorkerThreadPool.wait_for_group_task_completion(int(pg[0])) # pool-wait: resource-free (completed; EfpSim data only)
		else:
			keep.append(pg)
	_pending = keep

## Every group waited for (the world's exit).
static func reap_all() -> void:
	for pg in _pending:
		WorkerThreadPool.wait_for_group_task_completion(int(pg[0])) # pool-wait: resource-free (EfpSim data only)
	_pending.clear()
