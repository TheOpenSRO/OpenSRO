extends RefCounted
class_name GhostWalk

## Where a ground-cast move (Ghost Walk, the rows carrying `tele`) lands,
## resolved on the client before the cast is sent (round 616-618 integration
## and its review). The server has no navmesh; the client has the one the
## walk uses (NavGraph), so the check the retail server runs is run here.
##
## RETAIL (SR_GameServer.exe, READ):
## - FUN_005862e0 takes the requested point and D = (float) tele value[1]. It
##   measures the offset from the caster in THREE dimensions (x*x + y*y + z*z,
##   then its square root, FUN_00405250) and, when that is over D, puts the
##   destination at caster + unit(offset) * D -- a 3-D clamp along the line.
## - It then calls CRegionManagerBody::vslot_012 (0x98b300) from the caster to
##   that destination; the call WRITES the destination (a walk on the navmesh
##   that stops at the first wall -- NavGraph.step_tracked(..., false) says
##   exactly where) and the move record is filled from what it wrote. A
##   blocked path is not refused. Only bit 0x10000000 refuses the cast: a
##   destination more than a region span away, over six mesh hand-overs, a
##   landing outside [0, 1920) of its region or on no cell, and a failed cell
##   check when the caster's vslot 0x1c or 0x2c answers non-zero (OPEN).
## - The record keeps the landing as INTEGERS: x, y and z each go through
##   _ftol2 (0x9fbb40, asm 0x5866ca..0x5866ea: truncation toward zero), in
##   the region's own coordinates (the record's u16 region at +6).
##   EngageSkill (0x593540, asm 0x5935e6..0x593652) loads them back with fild
##   and hands slot 305 (CGObjPC::vslot_305 -> GObjPC::FUN_0048b920) the
##   offset to them, which sets the position (slot 0x39c) to current +
##   offset: the character is PUT at the truncated point.
##
## HERE:
## - reach unknown (the skill index not loaded yet): refused (`refused`), the
##   caller sends nothing -- OURS; walking an unclamped pick is no retail case;
## - the 3-D clamp;
## - one no-slide NavGraph step per region the line crosses (a step is cut at
##   the region's edge and continues in the next region's graph, its footing
##   settled there from the height, as click-to-move does at a region change);
## - the landing truncated like the record: x and z toward zero in the
##   region's coordinates, the player then stood at the cell's height there
##   (`position`); the point SENT (`sent`) has y truncated too, as the record
##   -- unless truncating would carry the point over an edge (see _land);
## - `sent` kept within reach in 3-D (y included), so the server's clamp --
##   the authority on distance -- leaves it where it is: when the ground's
##   height carries the landing past D, the walk is repeated to a point on
##   the same line shorter by the overshoot plus a unit (OURS).

## A region's span in its own coordinates (AGENTS.md: local [0, 1920)).
const REGION_SPAN := 1920.0
## How many regions one move may cross. OURS: the longest tele (215) crosses
## at most two borders.
const MAX_REGIONS := 4
const SQRT2 := 1.4142136
## Retries when the ground carries the landing out of reach. OURS.
const REACH_TRIES := 4

## What resolve() decided.
class Landing:
	## Where the caster stands afterwards (world), on the cell's height.
	var position: Vector3
	## The point to send (world): `position` with its region-local y
	## truncated as well, as retail's record keeps it.
	var sent: Vector3
	## What it stands on: NavGraph.ON_TERRAIN or an object index into
	## `graph`'s region; -2 when no navmesh was under the walk.
	var footing: int = -2
	var graph: NavGraph = null
	## The point after the 3-D clamp, before the walk.
	var clamped: Vector3
	## A wall stopped the walk short of `clamped`.
	var blocked: bool = false
	## The terrain wall's cell check put the walk back to its source point.
	var cancelled: bool = false
	## No navmesh covered the start: nothing was walked; `position` and
	## `sent` are the clamped point.
	var unchecked: bool = false
	## The reach is not known: nothing is to be sent.
	var refused: bool = false
	## `sent` is retail's integer point; false when truncating would have
	## crossed the edge the walk stopped at (see _land).
	var truncated: bool = false

## Retail's clamp: the point itself within `reach` of `from` (3-D distance),
## else `reach` along the line toward it.
static func clamp_to_reach(from: Vector3, pick: Vector3, reach: float) -> Vector3:
	var offset := pick - from
	var length := offset.length()
	if length <= reach:
		return pick
	return from + offset / length * reach

## Truncation toward zero, as _ftol2.
static func _trunc(v: float) -> float:
	return float(int(v))

## Resolves a ground-cast landing. `from` is the caster (world), `pick` the
## point picked on the ground (world), `reach` tele value[1] (0 or less:
## refused). `footing` is what the caster stands on in `footing_graph` (the
## walk's own _nav_footing), or -2 to settle it from the height. `lookup` is
## Callable(world: Vector3) -> [NavGraph, Node3D] or [] -- World3D._nav_graph_for.
static func resolve(from: Vector3, pick: Vector3, reach: float, footing: int,
		footing_graph: NavGraph, lookup: Callable) -> Landing:
	var out := Landing.new()
	if reach <= 0.0:
		out.refused = true
		out.clamped = pick
		out.position = from
		out.sent = from
		return out
	out.clamped = clamp_to_reach(from, pick, reach)
	var first: Array = lookup.call(from)
	if first.is_empty():
		out.unchecked = true
		out.position = out.clamped
		out.sent = out.clamped
		return out
	var done := _land(from, out.clamped, footing, footing_graph, lookup)
	# The ground's height (or the truncated y) took it past D: walk again to
	# a point on the same line shorter by the overshoot and one unit more for
	# the truncation (which shifts x and z by under a unit each, so under
	# sqrt 2 across). A no-slide walk runs along that straight line, so a
	# shorter target crosses nothing new. Rarely more than one retry.
	var tries := 0
	while from.distance_to(done["sent"]) > reach and tries < REACH_TRIES:
		var at: Vector3 = done["walked"]
		var flat := Vector2(at.x - from.x, at.z - from.z)
		var length := flat.length()
		var shorter := maxf(length - (from.distance_to(done["sent"]) - reach) - SQRT2, 0.0)
		var dir := flat / length if length > 0.0 else Vector2.ZERO
		done = _land(from, from + Vector3(dir.x, 0.0, dir.y) * shorter, footing, footing_graph, lookup)
		tries += 1
	if from.distance_to(done["sent"]) > reach:
		done = _land(from, from, footing, footing_graph, lookup)
	out.position = done["position"]
	out.sent = done["sent"]
	out.footing = done["footing"]
	out.graph = done["graph"]
	out.blocked = done["blocked"]
	out.cancelled = done["cancelled"]
	out.truncated = done["truncated"]
	return out

## One walk from `from` toward `target` (world), region by region, then the
## truncation. {position, sent, footing, graph, blocked, cancelled}.
static func _land(from: Vector3, target: Vector3, footing: int, footing_graph: NavGraph,
		lookup: Callable) -> Dictionary:
	var pair: Array = lookup.call(from)
	var graph: NavGraph = pair[0]
	var group: Node3D = pair[1]
	var pos := from
	var local := group.to_local(pos)
	var on := footing
	if graph != footing_graph or on == -2:
		on = graph.surface_at(local.x, local.z, local.y).object_index
	var blocked := false
	var cancelled := false
	# The caster's own height from its cell first, so a caster standing a
	# hair off the graph lands on it even for a zero-length move.
	var start := graph.step_tracked(local, Vector2.ZERO, on, false)
	local = start.position
	on = start.standing_on
	for _r in range(MAX_REGIONS):
		var aim := group.to_local(target)
		var motion := Vector2(aim.x - local.x, aim.z - local.z)
		# Cut the step at the region's edge.
		var t := 1.0
		for axis in [0, 2]:
			var d: float = motion.x if axis == 0 else motion.y
			var p: float = local[axis]
			if d > 0.0 and p + d > REGION_SPAN:
				t = minf(t, (REGION_SPAN - p) / d)
			elif d < 0.0 and p + d < 0.0:
				t = minf(t, -p / d)
		var step := graph.step_tracked(local, motion * t, on, false)
		local = step.position
		on = step.standing_on
		if step.blocked:
			blocked = true
			cancelled = step.cancelled
			break
		if t >= 1.0:
			break
		# Over the edge: the next region's graph, its footing from the height
		# (click-to-move's re-settle at a region change).
		var here := group.to_global(local)
		var dir := Vector3(motion.x, 0.0, motion.y).normalized()
		var next: Array = lookup.call(here + group.global_transform.basis * dir * 0.05)
		if next.is_empty() or next[0] == graph:
			break
		graph = next[0]
		group = next[1]
		local = group.to_local(here)
		on = graph.surface_at(local.x, local.z, local.y).object_index
	# The record's integers: x and z truncated, the player stood at the
	# cell's height there; the sent y truncated as well. Truncation moves the
	# point up to a unit toward the region's origin, which can carry it over
	# the edge the walk stopped at (Jangan's pit railing: 953.46 -> 953,
	# MEASURED) -- then this keeps the walked, unrounded stop instead (OURS:
	# where retail's character ends up in that case was not read, OPEN).
	var tx := _trunc(local.x)
	var tz := _trunc(local.z)
	var truncated := true
	var over := graph.step_tracked(local, Vector2(tx - local.x, tz - local.z), on, false)
	if over.blocked or over.entered != -1 or over.exited != -1 or over.standing_on != on:
		tx = local.x
		tz = local.z
		truncated = false
	# The height of what the walk stands on: its object's cell nearest the
	# walked height, else the terrain (never a surface picked by height alone,
	# which would lift a walker under a roof onto it).
	var h := NAN
	if on != NavGraph.ON_TERRAIN and graph.objects.has(on):
		h = NavGraph._surface_near(graph.objects[on], tx, tz, local.y)
	if is_nan(h):
		on = NavGraph.ON_TERRAIN
		h = NvmCollision.sample_height(graph.region, tx, tz)
	return {
		"position": group.to_global(Vector3(tx, h, tz)),
		"sent": group.to_global(Vector3(tx, _trunc(h) if truncated else h, tz)),
		"truncated": truncated,
		"walked": group.to_global(local),
		"footing": on,
		"graph": graph,
		"blocked": blocked,
		"cancelled": cancelled,
	}
