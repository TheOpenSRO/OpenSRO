extends RefCounted
class_name DoorBlock

## Round 879: a closed trigger door's footprint and the walk's stop at it
## (StructureWorld keeps the holders; this is the geometry, testable without
## the client's autoloads). The user (prod, v0.1.649): "it let me through the
## gate anyways" -- the Wrecked Ship's first door, drawn and closed, was
## walked through on the bridge it stands across. MEASURED: the door's model
## (wreck_event_door.bsr) names wreck_eventdoor01.bms, whose navigation mesh
## is one 153.6 x 31.2 rectangle with every outline edge blocking both ways
## (0x3). StructureWorld places that mesh as a map object is placed
## (NavGraph.place: the record's point, the yaw its angle was made from) and
## keeps its blocking edges under META_SEGMENTS, which the player's walk does
## not cross while the door stands. OURS: the original's run-time
## registration of the door's mesh was not found (CIEventRuntimeObj::
## FUN_00535750 builds the model); the server stops the same leg at the same
## outline (gameworld.DoorStop).

## The holder meta of a closed door's footprint: its blocking edges as flat
## pairs of points in the holder's region group's space (the NavGraph's plan).
const META_SEGMENTS := "door_segments"

## How far short of a door's outline a stopped step ends (the walk's own wall
## nudge, READ: at most 0.2 back from the crossing; NavGraph.step_tracked).
const NUDGE := 0.2

## The yaw (radians, a map object's) a door's wire angle was made from: the
## server's angleOfYaw undone (gameworld/zoneplace.go, INFERRED there).
static func door_yaw(angle: int) -> float:
	return float(angle) / 65536.0 * TAU + PI / 2.0

## Where a step from `from` to `to` (world points) ends at the closed doors
## held by `holders` (uid -> Node3D under its region group): {} when it
## crosses none, else {"at": the world point NUDGE short of the first door
## edge it crosses}.
static func stop(holders: Dictionary, from: Vector3, to: Vector3) -> Dictionary:
	var a := Vector2(from.x, from.z)
	var b := Vector2(to.x, to.z)
	if a == b:
		return {}
	var best := INF
	for uid in holders:
		var h = holders[uid]
		if h == null or not is_instance_valid(h) or not (h as Node).has_meta(META_SEGMENTS):
			continue
		var group := (h as Node3D).get_parent() as Node3D
		if group == null:
			continue
		var segs: PackedVector2Array = (h as Node).get_meta(META_SEGMENTS)
		var y := (h as Node3D).position.y
		# The group's own transform outside a tree (a suite's bare nodes).
		var xf: Transform3D = group.global_transform if group.is_inside_tree() else group.transform
		var i := 0
		while i + 1 < segs.size():
			var p: Vector3 = xf * Vector3(segs[i].x, y, segs[i].y)
			var q: Vector3 = xf * Vector3(segs[i + 1].x, y, segs[i + 1].y)
			i += 2
			var t := crossing(a, b, Vector2(p.x, p.z), Vector2(q.x, q.z))
			if t >= 0.0 and t < best:
				best = t
	if best == INF:
		return {}
	var back := minf(best, NUDGE / a.distance_to(b))
	return {"at": from.lerp(to, best - back)}

## Where (as a fraction of a-b) the segment a-b crosses p-q, -1 for none.
static func crossing(a: Vector2, b: Vector2, p: Vector2, q: Vector2) -> float:
	var r := b - a
	var s := q - p
	var den := r.cross(s)
	if den == 0.0:
		return -1.0
	var t := (p - a).cross(s) / den
	var u := (p - a).cross(r) / den
	if t < 0.0 or t > 1.0 or u < 0.0 or u > 1.0:
		return -1.0
	return t
