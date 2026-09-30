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

## Round 649, the second half of the same rule, and round 653's follow-up:
## whether a walk's step that met a blocking edge ends the walk. It does,
## always. READ (sro_client.exe, docs/protocol/opcodes/movement.md, "The stop
## at a wall"): the mover's tick FUN_009e0e60 hands the step to the collision
## query CRegionManagerBody::vslot_012 (0x412660); its terrain walk (0x4047a0)
## answers a blocking edge with the crossing point, nudged at most 0.2 toward
## the centre of the cell the mover is in (FUN_004472d0, 0xe1b850), and bit 0;
## the tick takes that point and bit 0 ends the movement (+0x84 = 0,
## +0x80 = 0). A refused step (bit 0x10000000) ends it too. There is no
## component along the wall in that branch: retail's mover does not slide, for
## any movement kind -- a walk to a point, a heading run, an approach.
##
## Round 649 had OURS here: our graph slid along the wall and the walk ended
## only when a step covered at most 1 % of what was asked. Round 653's
## follow-up (the user: "when the character collides with a wall or something
## that stops it make sure you stop the running as well and make the
## character stop in place like the original game") walks every order with
## NavGraph.step_tracked's no-slide walk and ends it at the first blocked
## step. An attack's or friendly cast's approach is re-issued by its own tick
## on the next pass (World3D._step_move_order), as retail's attack tick
## re-issues MoveTowardObject while out of reach (auto_command.md, phase 1).
static func blocked_ends(blocked: bool) -> bool:
	return blocked
