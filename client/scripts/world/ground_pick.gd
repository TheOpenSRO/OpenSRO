class_name GroundPick
extends RefCounted

## The walk's click on the world (round 781): what a click can land on, as
## retail's pick SWorld::vslot_034 (0xa01310, READ) tests it -- the terrain
## and the walkable navigation surfaces, never the drawn meshes.
##
## READ (0xa01310): for each loaded region (the ten slots at +0x2783) it
## tests the ray against the region's terrain height grid, two triangles a
## tile (FUN_0045c420 builds each, FUN_0045c750 is the segment test), and
## against its water plane where the region has one (+0x7ed == 1, +0x7ee set,
## the plane at +0x7ef); then it asks the region manager (DAT_0111a02c, slot
## 0x3c) for the navigation mesh's hit -- the placed objects' own walkable
## cells; the nearest wins (the distance through FUN_00b42de0). A drawn mesh
## with no navigation cells -- grass, flowers, a bush, a lamp -- is never
## tested, so a click through it lands on the ground behind.
##
## OpenSRO: the terrain by its physics body (TERRAIN_ONLY mask, the terrain
## alone), and the placed objects by their walkable cells in each loaded
## NavGraph (a dungeon's rooms included). The water plane is not tested
## (OPEN: OpenSRO's water has no pick body; a click on a lake lands on its
## bed under the same screen point).

## The nearest hit of the segment `from`..`from + dir * length` (world space)
## on any loaded graph's object cells: {"position": Vector3, "distance":
## float, "object": int} or {}. `pairs` is [[NavGraph, Node3D group], ...].
static func object_cells_hit(pairs: Array, from: Vector3, dir: Vector3, length: float) -> Dictionary:
	var best := {}
	var best_d := INF
	var to := from + dir.normalized() * length
	for pair in pairs:
		var graph: NavGraph = pair[0]
		var group: Node3D = pair[1]
		if graph == null or group == null or not is_instance_valid(group):
			continue
		var lf := group.to_local(from)
		var lt := group.to_local(to)
		var hit := segment_hit_in_graph(graph, lf, lt)
		if hit.is_empty():
			continue
		var world: Vector3 = group.to_global(hit["position"])
		var d := from.distance_to(world)
		if d < best_d:
			best_d = d
			best = {"position": world, "distance": d, "object": hit["object"]}
	return best

## The nearest hit, in the graph's own space, of the segment lf..lt on its
## objects' cells: {"position", "object"} or {}.
static func segment_hit_in_graph(graph: NavGraph, lf: Vector3, lt: Vector3) -> Dictionary:
	var best := {}
	var best_d := INF
	var f2 := Vector2(lf.x, lf.z)
	var t2 := Vector2(lt.x, lt.z)
	var lo := Vector2(minf(f2.x, t2.x), minf(f2.y, t2.y))
	var hi := Vector2(maxf(f2.x, t2.x), maxf(f2.y, t2.y))
	var candidates: Array[int] = graph._candidate_objects(f2, t2)
	for oi in candidates:
		if not graph.objects.has(oi):
			continue
		var placed: NavGraph.PlacedObject = graph.objects[oi]
		if placed.bounds_max.x < lo.x or placed.bounds_min.x > hi.x or placed.bounds_max.y < lo.y or placed.bounds_min.y > hi.y:
			continue
		var i := 0
		while i + 2 < placed.cells.size():
			var a: Vector3 = placed.vertices[placed.cells[i]]
			var b: Vector3 = placed.vertices[placed.cells[i + 1]]
			var c: Vector3 = placed.vertices[placed.cells[i + 2]]
			i += 3
			var p: Variant = Geometry3D.segment_intersects_triangle(lf, lt, a, b, c)
			if p == null:
				p = Geometry3D.segment_intersects_triangle(lf, lt, a, c, b)
			if p == null:
				continue
			var d := lf.distance_to(p)
			if d < best_d:
				best_d = d
				best = {"position": p, "object": oi}
	return best

## The pick: the nearer of `terrain` (a physics hit, {} for none) and the
## object cells' hit. Returns the physics-hit-shaped {"position": ...} or {}.
static func nearest(from: Vector3, terrain: Dictionary, cells: Dictionary) -> Dictionary:
	if cells.is_empty():
		return terrain
	if terrain.is_empty():
		return {"position": cells["position"], "object": cells["object"]}
	var dt := from.distance_to(terrain["position"])
	if float(cells["distance"]) < dt:
		return {"position": cells["position"], "object": cells["object"]}
	return terrain
