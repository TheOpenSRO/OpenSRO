extends RefCounted
class_name HeightBatch

## Round 757: the walkable graph's landing height (NavGraph.landing_height_at)
## for many points at once, spread over WorkerThreadPool's threads.
##
## **Why.** Every other player on a leg (OtherWalk, round 749) takes the ground
## under it every 2 units and on its point, and a landing height scans the
## object cells under the point in GDScript: about 160 us a point on Jangan's
## plaza (MEASURED, round 749). At 7,000 bodies with 2 % walking that was
## 4.5 ms a frame of the main thread (`o_leg_h`, MEASURED round 757), and the
## frame's budget of 32 points left later landings waiting a frame.
##
## **What runs where.** The main thread finds each point's region (a Node's
## transform) and hands over plain data: the graph (RefCounted, read only once
## built), the point in the region's space and the region's transform. A task
## reads only that: NavGraph.landing_height_at and NvmCollision.terrain_height
## walk the graph's own arrays and dictionaries, which nothing writes once the
## region is committed. Each point's height is written to its own index of
## `out`. The main thread applies the heights (Node3D.position), as before. No
## Node is touched off the main thread and no `const` Array is read
## (const_array_lint_test covers nav_graph.gd and nvm_collision.gd).
##
## **The main thread never waits behind the pool's queue** (round 757's review,
## F3: Godot 4.2.2's WorkerThreadPool has one FIFO queue, and a group's waiter
## does no work -- READ worker_thread_pool.cpp l. 224-230, 498-520 -- so a frame
## of walkers waited behind every queued cell prepare). The points are claimed
## one at a time under a Mutex by up to MAX_HELPERS pool tasks AND by the main
## thread itself: with the pool busy, the main thread does all of them, as the
## inline code did; with it free, the helpers share them. The main thread waits
## only for points a helper has already started (one landing height each, about
## 0.2 ms). A helper that starts after every point is taken returns at once; its
## group is waited for (freed) once it is complete, on a later frame (`reap`).
##
## Engine-independent: nothing here works around a 4.2.2 bug.
##
## **No RenderingServer call off the main thread** (round 760): a helper runs
## NavGraph.landing_height_at alone, which reads arrays and dictionaries, so the
## main thread's waits here (the spin in `work_and_wait`, `reap`, `reap_all`)
## cannot meet Godot 4.7.2's queued RenderingServer calls (PoolWait's header);
## they stay plain waits, marked `pool-wait: resource-free` for
## pool_wait_lint_test.gd.

## Below this many points the tasks cost more than they save: run inline
## (OURS; a group task's dispatch and wait is tens of microseconds).
const THREADED_MIN := 8
## The pool tasks a batch posts at most (OURS; the review's `mini(n, 4)`): the
## main thread is one more.
const MAX_HELPERS := 4
## The live threshold (QaCrowdProbe's `inlineh` step sets it out of reach: the
## same heights on the main thread, for the A/B).
static var threaded_min := THREADED_MIN

## One batch's data, kept alive until its group is freed (a helper that starts
## late reads its claim counter).
class Job:
	var graphs: Array = []
	var xfs: Array = []
	var lx := PackedFloat32Array()
	var lz := PackedFloat32Array()
	var out: Array = []
	var n := 0
	var mutex := Mutex.new()
	var next := 0
	var done := 0
	## Points the pool's helpers did (QA).
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

	## A pool task: points until none is left.
	func help(_task: int) -> void:
		while true:
			var i := _claim()
			if i < 0:
				return
			run(i)
			_finish(true)

	## The main thread: points until none is left, then the ones the helpers
	## are still on.
	func work_and_wait() -> void:
		while true:
			var i := _claim()
			if i < 0:
				break
			run(i)
			_finish(false)
		while true:
			mutex.lock()
			var d := done
			mutex.unlock()
			if d >= n:
				return
			OS.delay_usec(20)

	func run(i: int) -> void:
		var g: NavGraph = graphs[i]
		var x := lx[i]
		var z := lz[i]
		var h := g.landing_height_at(x, z)
		var xf: Transform3D = xfs[i]
		out[i] = (xf * Vector3(x, h, z)).y

## Groups whose helpers may not have run yet: [group id, Job] (freed by reap).
static var _pending: Array = []

var _job := Job.new()
var out: Array = []
## Counts for the QA split: this batch posted helpers, and how many points they did.
var last_threaded := false
var last_by_helpers := 0

func clear() -> void:
	_job = Job.new()
	out = []

func size() -> int:
	return _job.graphs.size()

## Queues one point: `graph`'s landing height at region-local (`x`, `z`),
## returned through `xf` (the region group's global transform) as a world y.
func add(graph: NavGraph, xf: Transform3D, x: float, z: float) -> int:
	_job.graphs.append(graph)
	_job.xfs.append(xf)
	_job.lx.append(x)
	_job.lz.append(z)
	return _job.graphs.size() - 1

## Every queued point's height into `out` (a world y each).
func resolve() -> void:
	reap()
	var j := _job
	j.n = j.graphs.size()
	j.out.resize(j.n)
	last_threaded = j.n >= threaded_min
	last_by_helpers = 0
	if last_threaded:
		var helpers := mini(MAX_HELPERS, j.n / 2)
		var group := WorkerThreadPool.add_group_task(j.help, helpers, helpers, true, "OpenSRO landing heights")
		_pending.append([group, j])
	j.work_and_wait()
	last_by_helpers = j.by_helpers
	out = j.out

## Frees the groups whose helpers have all returned.
static func reap() -> void:
	if _pending.is_empty():
		return
	var keep: Array = []
	for p in _pending:
		if WorkerThreadPool.is_group_task_completed(int(p[0])):
			WorkerThreadPool.wait_for_group_task_completion(int(p[0])) # pool-wait: resource-free (completed; NavGraph data only)
		else:
			keep.append(p)
	_pending = keep

## Every group waited for (the world leaving the tree, the tests): the helpers
## left return at once.
static func reap_all() -> void:
	for p in _pending:
		WorkerThreadPool.wait_for_group_task_completion(int(p[0])) # pool-wait: resource-free (NavGraph data only)
	_pending = []
