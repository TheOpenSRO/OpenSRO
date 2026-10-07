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
## per point reads only that: NavGraph.landing_height_at and
## NvmCollision.terrain_height walk the graph's own arrays and dictionaries,
## which nothing writes once the region is committed. Each task writes its own
## index of `out`. The main thread waits for the group and applies the heights
## (Node3D.position), as before. No Node is touched off the main thread and no
## `const` Array is read (const_array_lint_test covers nav_graph.gd and
## nvm_collision.gd).
##
## Engine-independent: nothing here works around a 4.2.2 bug.

## Below this many points the tasks cost more than they save: run inline
## (OURS; a group task's dispatch and wait is tens of microseconds).
const THREADED_MIN := 8
## The live threshold (QaCrowdProbe's `inlineh` step sets it out of reach: the
## same heights on the main thread, for the A/B).
static var threaded_min := THREADED_MIN

var graphs: Array = []
var xfs: Array = []
var lx := PackedFloat32Array()
var lz := PackedFloat32Array()
var out: Array = []
## Counts for the QA split.
var last_threaded := false

func clear() -> void:
	graphs.clear()
	xfs.clear()
	lx.clear()
	lz.clear()
	out.clear()

func size() -> int:
	return graphs.size()

## Queues one point: `graph`'s landing height at region-local (`x`, `z`),
## returned through `xf` (the region group's global transform) as a world y.
func add(graph: NavGraph, xf: Transform3D, x: float, z: float) -> int:
	graphs.append(graph)
	xfs.append(xf)
	lx.append(x)
	lz.append(z)
	return graphs.size() - 1

## Every queued point's height into `out` (a world y each).
func resolve() -> void:
	var n := graphs.size()
	out.resize(n)
	last_threaded = n >= threaded_min
	if not last_threaded:
		for i in range(n):
			run(i)
		return
	var task := WorkerThreadPool.add_group_task(run, n, -1, true, "OpenSRO landing heights")
	WorkerThreadPool.wait_for_group_task_completion(task)

## One point (a pool thread, or the caller's).
func run(i: int) -> void:
	var g: NavGraph = graphs[i]
	var x := lx[i]
	var z := lz[i]
	var h := g.landing_height_at(x, z)
	var xf: Transform3D = xfs[i]
	out[i] = (xf * Vector3(x, h, z)).y
