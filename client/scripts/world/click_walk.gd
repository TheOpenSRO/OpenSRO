class_name ClickWalk
extends RefCounted

## Round 649: one tick of a walk to a clicked point, never past the point.
##
## The user's report: at a raised `/speed`, clicking around sometimes left the
## character "stuttering back and forth really fast", seen by other players too,
## and "running in place" on video. MEASURED (docs/WORLD_ISSUES.md, round 649):
## the walk set a full-speed velocity toward the destination on every tick and
## stopped only once it stood within MOVE_TARGET_STOP_DISTANCE (2.39 units). A
## tick's step of `speed / 60` longer than the remaining distance plus that stop
## carried the body past the point to the far side, and the next tick carried
## it back by the same step: a two-tick ping-pong between two fixed points that
## never ends. The position send (every 0.05 s, three ticks) picks alternate
## ends, so the other players' bodies flicked between them too; a recording at
## a divisor of the tick rate samples one end and shows a body running in place.
##
## READ, the retail rule (sro_client.exe, the mover's tick
## `FUN_009e0e60`, called each frame for an object with a movement in effect):
## the step is `speed * elapsed` (the speed at `obj+0x444`, or the walk/run
## slot's times `+0x8c`; the frame's seconds at `0x0110f7fc`); when the mover
## has a destination (`+0x80 == 1`) and the distance to it (`FUN_009ecc70`) is
## no more than the step, the step is CUT to that distance and the move ends
## (`+0x84 = 0`). So a retail mover lands on its destination and never passes
## it, at any speed.
##
## OURS: the early stop within `stop` of the point is kept (the attack approach
## math, CombatNet.approach_aim, is built on it); only a step that would reach
## or pass the point is cut to land on it, as retail's is.

## The result of one tick: `arrived` ends the walk now (the body is within
## `stop`, or already on the point); otherwise `velocity` is the horizontal
## velocity for this tick -- the full speed toward the point, or, when a full
## step would reach or pass it, exactly the speed that lands on it this tick.
static func step(to_target: Vector2, speed: float, delta: float, stop: float) -> Dictionary:
	var left := to_target.length()
	if left <= stop or left <= 0.000001:
		return {"arrived": true, "velocity": Vector2.ZERO}
	var dir := to_target / left
	var full := speed * delta
	if delta > 0.0 and full >= left:
		# READ (FUN_009e0e60): the step is cut to the distance left.
		return {"arrived": false, "velocity": dir * (left / delta), "landing": true}
	return {"arrived": false, "velocity": dir * speed, "landing": false}

## How little of a step's asked length a blocked step may cover and still end
## the walk (OURS): a step the graph stopped dead. A slide along a wall covers
## a real part of the step and goes on.
const BLOCKED_PROGRESS := 0.01

## Round 649, the second half of the same rule: whether a click walk whose
## step the navigation graph BLOCKED ends here. READ (FUN_009e0e60): the
## mover's collision query (`[0x111a02c]` vtable +0x30) returning bit
## 0x10000000 ends the movement -- the retail body stops, it does not keep
## its order. MEASURED on the base (round 649 and its review): walks held
## against an edge north of the Jangan spawn (local z 953.6, the trace's
## footing cj_jang_gate) for 59-219 ticks, 4.7-7.2 units short, the run
## playing on the spot, at /speed 1 too. OURS: "stopped dead" is a
## step covering no more than BLOCKED_PROGRESS of what was asked, since our
## graph slides along a wall where retail's query was not read to.
static func blocked_ends(moved: float, asked: float) -> bool:
	return asked > 0.000001 and moved <= asked * BLOCKED_PROGRESS
