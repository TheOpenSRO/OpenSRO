extends RefCounted
class_name GhostWalk

## Where a ground-cast move (Ghost Walk, the rows carrying `tele`) lands,
## resolved on the client before the cast is sent (round 616-618
## integration). The server has no navmesh; the client has the one the walk
## uses (NavGraph), so the check the retail server runs is run here.
##
## RETAIL (SR_GameServer.exe, READ):
## - FUN_005862e0 takes the requested point and D = (float) tele value[1]. It
##   measures the offset from the caster in THREE dimensions (x*x + y*y + z*z,
##   then its square root, FUN_00405250) and, when that is over D, puts the
##   destination at caster + unit(offset) * D -- a 3-D clamp along the line.
##   The server's own clamp (session/skill.go ghostWalkDestination) is the
##   same, and it stays the authority on distance.
## - It then calls the navmesh manager's CRegionManagerBody::vslot_012
##   (0x98b300, table 0xb431fc slot 12) from the caster's position to that
##   destination, and fills the move record from the destination struct the
##   call has WRITTEN (asm 0x5866c1..0x5866ea read it back after the call).
##   vslot_012 walks the navmesh cell by cell (the mesh's own slot 2 -- the
##   terrain walk 0x9a0710, the same library function as the client's
##   0x4047a0 that NavGraph models) and stops when the walk reports a block
##   (`(result & 0x10000001) != 0` breaks the loop); on a block the terrain
##   walk leaves the destination at the crossing point, nudged back toward
##   the mover by RTNavMeshTerrain::FUN_009c1050 -- it does NOT slide.
## - So a blocked path is not refused: the caster stops at the obstacle. Only
##   bit 0x10000000 refuses the cast (FUN_005862e0 returns 0): a destination
##   more than a region span away, over six mesh hand-overs, a landing outside
##   [0, 1920) of its region or on no cell, and a failed cell check when the
##   caster's own vslot 0x1c or 0x2c says so (what those two mean is OPEN).
##
## HERE: clamp (3-D, as retail), then walk NavGraph from the player toward the
## clamped point with sliding off (`step_tracked(..., false)`) and stop at the
## first wall. The landing's height is the cell's under it -- ground height.
## Walked in WALK_CHUNK pieces so a move crossing into the next region picks
## up that region's graph (OURS: the size is a stepping choice, not data).

## The length of one piece of the walk, in world units. OURS.
const WALK_CHUNK := 1.0

## What resolve() decided.
class Landing:
	## Where the caster ends up (world space), on the ground.
	var position: Vector3
	## What it stands on there: NavGraph.ON_TERRAIN or an object index into
	## `graph`'s region; -2 when no navmesh was under the walk.
	var footing: int = -2
	var graph: NavGraph = null
	## The point after the 3-D clamp, before the walk.
	var clamped: Vector3
	## A wall stopped the walk short of `clamped`.
	var blocked: bool = false
	## No navmesh covered the start: nothing was walked, `position` is the
	## clamped point unchanged.
	var unchecked: bool = false

## Retail's clamp: the point itself within `reach` of `from` (3-D distance),
## else `reach` along the line toward it. A reach of 0 or less leaves the
## point alone (the row carries no tele value[1]; the server clamps).
static func clamp_to_reach(from: Vector3, pick: Vector3, reach: float) -> Vector3:
	var offset := pick - from
	var length := offset.length()
	if reach <= 0.0 or length <= reach:
		return pick
	return from + offset / length * reach

## Resolves a ground-cast landing. `from` is the caster (world), `pick` the
## point picked on the ground (world), `reach` tele value[1]. `footing` is
## what the caster stands on in `footing_graph` (the walk's own _nav_footing),
## or -2 to settle it from the height. `lookup` is Callable(world: Vector3)
## -> [NavGraph, Node3D] or [] -- World3D._nav_graph_for.
static func resolve(from: Vector3, pick: Vector3, reach: float, footing: int,
		footing_graph: NavGraph, lookup: Callable) -> Landing:
	var out := Landing.new()
	out.clamped = clamp_to_reach(from, pick, reach)
	out.position = out.clamped
	var pair: Array = lookup.call(from)
	if pair.is_empty():
		out.unchecked = true
		return out
	var graph: NavGraph = pair[0]
	var group: Node3D = pair[1]
	var pos := from
	var local := group.to_local(pos)
	var on := footing
	if graph != footing_graph or on == -2:
		on = graph.surface_at(local.x, local.z, local.y).object_index
	var flat := Vector2(out.clamped.x - from.x, out.clamped.z - from.z)
	var total := flat.length()
	var dir := flat / total if total > 0.0 else Vector2.ZERO
	var walked := 0.0
	# The start's own height from its cell, so a caster standing a hair off
	# the graph lands on it even for a zero-length move.
	var start := graph.step_tracked(local, Vector2.ZERO, on)
	pos = group.to_global(start.position)
	on = start.standing_on
	while walked < total:
		var piece := minf(WALK_CHUNK, total - walked)
		var here: Array = lookup.call(pos)
		if here.is_empty():
			# Walked off every loaded graph: stop where the graph ended.
			break
		if here[0] != graph:
			graph = here[0]
			group = here[1]
			var l := group.to_local(pos)
			on = graph.surface_at(l.x, l.z, l.y).object_index
		local = group.to_local(pos)
		var target_world := pos + Vector3(dir.x, 0.0, dir.y) * piece
		var target := group.to_local(target_world)
		var step := graph.step_tracked(local, Vector2(target.x - local.x, target.z - local.z), on, false)
		pos = group.to_global(step.position)
		on = step.standing_on
		walked += piece
		if step.blocked:
			out.blocked = true
			break
	out.position = pos
	out.footing = on
	out.graph = graph
	return out
