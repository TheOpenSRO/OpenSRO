extends RefCounted
class_name EfpSimBatch

## Round 759: many effects' simulations stepped at once, spread over
## WorkerThreadPool's threads (EquipFx's masters).
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
## static helpers; efp_sim.gd and efp_reader.gd are in const_array_lint_test's
## WORKER_FILES (no `const` Array read element by element). The one shared
## WRITE, EfpSim.live_total (the global particle cap, OURS), is deferred: each
## sim counts its own spawns and deaths and may add at most its share of what
## the cap left at the batch's start (EfpSim.begin_deferred), so the sum stays
## under the cap; end_deferred adds them back on the main thread. OURS: when
## the cap binds, the room is shared evenly instead of first come, first
## served in node order.
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

	func _claim() -> int:
		mutex.lock()
		var i := next
		if i < n:
			next += 1
		else:
			i = -1
		mutex.unlock()
		return i

	func _finish(helper: bool) -> void:
		mutex.lock()
		done += 1
		if helper:
			by_helpers += 1
		mutex.unlock()

	## A pool task: effects until none is left.
	func help(_task: int) -> void:
		while true:
			var i := _claim()
			if i < 0:
				return
			(effects[i] as EfpEffect).step_sim(delta)
			_finish(true)

	## The main thread: effects until none is left, then the ones the
	## helpers are still on.
	func work_and_wait() -> void:
		while true:
			var i := _claim()
			if i < 0:
				break
			(effects[i] as EfpEffect).step_sim(delta)
			_finish(false)
		while true:
			mutex.lock()
			var d := done
			mutex.unlock()
			if d >= n:
				return
			OS.delay_usec(20)

## Groups whose helpers may not have run yet: [group id, Job] (freed by reap).
static var _pending: Array = []
## QA: the last batch's size, whether it was threaded, and the effects the
## pool's helpers stepped.
static var last := {"n": 0, "threaded": false, "by_helpers": 0}

## Steps every effect of `effects` (EfpEffects whose step_pre returned true)
## by `delta`: EfpEffect.step_sim each, on the pool when there are enough.
static func run(effects: Array, delta: float) -> void:
	reap()
	var n := effects.size()
	last = {"n": n, "threaded": n >= threaded_min, "by_helpers": 0}
	if n < threaded_min:
		for e in effects:
			(e as EfpEffect).step_sim(delta)
		return
	for e in effects:
		var s: EfpSim = (e as EfpEffect).sim
		var limit := EfpSim.MAX_TOTAL if s.reserved else EfpSim.MAX_TOTAL - EfpSim.RESERVE
		s.begin_deferred(maxi(limit - EfpSim.live_total, 0) / n)
	var j := Job.new()
	j.effects = effects
	j.delta = delta
	j.n = n
	var helpers := mini(MAX_HELPERS, n - 1)
	var group := WorkerThreadPool.add_group_task(j.help, helpers, helpers, true, "OpenSRO effect sims")
	_pending.append([group, j])
	j.work_and_wait()
	for e in effects:
		(e as EfpEffect).sim.end_deferred()
	last["by_helpers"] = j.by_helpers

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
