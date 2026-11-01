class_name BodyWalk
extends RefCounted

## Round 852: how a body this client draws for someone else walks into a wall --
## another player on foot or riding, a COS, a monster -- one walker for all of
## them (round 851's CosWalk, which walked a COS's leg only, made general).
##
## READ (sro_client.exe): every character's tick (CICharactor slot 9,
## GlobalDataManager::FUN_009d1d60, CICCos slot 9 c:0x9c59c0 calling it) steps
## its mover with FUN_009e0e60 whenever it does not ride (FUN_009ce930 0), and
## that tick hands each step to the collision query CRegionManagerBody::
## vslot_012 (c:0x412660, called at c:0x9e0fca) and ends the movement on its
## refused bit (0x10000000: no step) or its stop bit (bit 0: the step, clipped
## at the wall, and the movement over). The query's first argument is 1 only
## for the own player (IsKindOf CICPlayer 0xef1b44) and a COS the player owns
## (CICCos 0xeef6f0 whose owner is DAT_00eef5ec), 0 for every other body
## (c:0x9e0f45..0x9e0fc3); the second is always 1. The query passes both to
## the navmesh walk (c:0x41290a..0x41291c); the terrain walk
## CRTNavMeshTerrain::vslot_002 (c:0x4047a0) tests the first's bit 0 at three
## places only -- c:0x404ab9, c:0x404c30, c:0x404f20, the re-checks of the
## cell's objects after an object stop, at a cell crossing and at the terrain
## wall -- and hands it down unread everywhere else; the object walk takes the
## second (round 644, 1 here: an object's outline blocks every mover). So an
## observer's client stops another player, its horse or transport, a pet or a
## monster at the same trunks, railings and walls the server stops it at, and
## draws it there -- not walked into the wall and put back by the server's
## 0xB023. The server side is the same rule (round 851, s:0x485740).
##
## OURS, disclosed:
##   - The flag's three re-checks are not modelled (every kind walks
##     NavGraph.step_tracked with no slide; round 851 found the same for the
##     server). INFERRED to differ only where a terrain wall and an object wall
##     fall within one step of each other.
##   - A straight leg is walked once, when it starts (plan): a leg the walk
##     finds clear is the straight step, and one it finds walled ends at the
##     walk's stop. A no-slide walk frame by frame along the same line crosses
##     the same edges and stops at the same point -- an object wall
##     CONTACT_PUSH short, a terrain wall at its nudged crossing -- so only
##     what the one walk cannot answer is walked a frame at a time (step): no
##     graph under the body yet, an end outside its region, a terrain wall
##     whose cell's objects send the mover back (the send-back point is the
##     walk's source, which a frame's walk moves), and a heading run (no end).
##     Frame by frame for every walker cost about 0.1 ms a body a frame in
##     GDScript (MEASURED, tools/walk_probe.gd --bench-legs).
##   - The footing (terrain or an object) is settled from the height at the
##     first step and carried from frame to frame, as the own player's walk
##     carries it (World3D._move_on_nav_graph); the original carries a cell.

## Region-local extent of a field graph (World3D.REGION_SPAN).
const REGION_SPAN := 1920.0

## plan's answers.
const CLEAR := 0
## The leg ends at a wall: "stop" is where (world x, z).
const STOP := 1
## The leg is walked a frame at a time (step).
const FRAMES := 2

## The straight leg from `from` (world; its drawn height) to `dest` (world x,
## z) walked once on `graph` (whose terrain group's global transform is `xf`)
## with no slide: {"kind": CLEAR | STOP | FRAMES, "stop": Vector2 for STOP}.
static func plan(graph: NavGraph, xf: Transform3D, from: Vector3, dest: Vector2) -> Dictionary:
	if graph == null:
		return {"kind": FRAMES}
	var inv := xf.affine_inverse()
	var lf := inv * from
	var ld := inv * Vector3(dest.x, from.y, dest.y)
	if not graph.dungeon and (ld.x < 0.0 or ld.z < 0.0 or ld.x > REGION_SPAN or ld.z > REGION_SPAN):
		return {"kind": FRAMES}
	var motion := Vector2(ld.x - lf.x, ld.z - lf.z)
	if motion.length_squared() <= 1.0e-10:
		return {"kind": CLEAR}
	var on := graph.surface_at(lf.x, lf.z, lf.y).object_index
	var r := graph.step_tracked(lf, motion, on, false)
	if not r.blocked:
		return {"kind": CLEAR}
	if r.cancelled:
		return {"kind": FRAMES}
	var w := xf * r.position
	return {"kind": STOP, "stop": Vector2(w.x, w.z)}

## Whether the straight leg meets a wall (plan's answer is not CLEAR).
static func meets_wall(graph: NavGraph, xf: Transform3D, from: Vector3, dest: Vector2) -> bool:
	return int(plan(graph, xf, from, dest)["kind"]) != CLEAR

## One frame of a leg walked a frame at a time: the step from `from` (world;
## its drawn height) to `next` (world x, z) walked on `graph` with no slide.
## `track` is the leg's own Dictionary: it carries the footing ("on", for
## "graph") from frame to frame and is told "blocked" true when a wall stopped
## the step (the leg is then over). Returns where the body stands (x, z).
## graph null: the straight step.
static func step(track: Dictionary, graph: NavGraph, xf: Transform3D, from: Vector3, next: Vector2) -> Vector2:
	track["blocked"] = false
	if graph == null or next == Vector2(from.x, from.z):
		return next
	var inv := xf.affine_inverse()
	var lf := inv * from
	var on := NavGraph.ON_TERRAIN
	if track.has("on") and track.get("graph") == graph:
		on = int(track["on"])
		# The walk's own height where it left the body (the drawn height is
		# resolved only every few units, MonsterMotion.needs_height).
		var last: Vector3 = track.get("at", Vector3.INF)
		if last.x == from.x and last.z == from.z:
			lf = inv * last
	else:
		on = graph.surface_at(lf.x, lf.z, lf.y).object_index
	var ln := inv * Vector3(next.x, from.y, next.y)
	var r := graph.step_tracked(lf, Vector2(ln.x - lf.x, ln.z - lf.z), on, false)
	track["on"] = r.standing_on
	track["graph"] = graph
	var w := xf * r.position
	track["at"] = w
	if r.blocked:
		track["blocked"] = true
	return Vector2(w.x, w.z)
