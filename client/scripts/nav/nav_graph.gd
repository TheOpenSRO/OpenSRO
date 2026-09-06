extends RefCounted
class_name NavGraph

## The real walkable surface of one region: its terrain `.nvm` plus every
## placed object's own navigation mesh, in one region-local coordinate space.
##
## This is the data the real client moves a character on. It answers two
## questions, and deliberately nothing else:
##
##   * `height_at` -- how high is the ground here, counting anything the
##     player can stand on (a bridge deck, a staircase, a raised floor);
##   * `blocked` -- does moving from here to there cross something the real
##     game refuses to let you through.
##
## **No physics.** Nothing here builds a collision shape. That is the point:
## driving Godot collision from this data was tried and reverted (see
## docs/WORLD_ISSUES.md's sixty-second and sixty-third rounds) because a
## capsule against a two-sided single-thickness surface pins itself, and the
## world's mirrored transform forces that surface to be two-sided. The real
## client has no capsule and no surface -- it finds the cell underfoot, takes
## its height, and tests each edge it crosses as a 2D line. So does this.
##
## ## How objects attach to the region
##
## Measured, not assumed (real Jangan region `nv_62a8`, 122 objects):
##
##   * Every object listed in a region's `.nvm` has a navigation mesh --
##     122/122 resolve to a real `.bsr` whose mesh carries a collision
##     section. A region's `.nvm` object list *is* the set of real placed
##     objects a character can stand on.
##   * `MapObject.linked_edges` is **not** the object-to-terrain link. Only 4
##     of the 122 objects carry any, 6 links in total, and every one points at
##     another *object*, in symmetric pairs -- real bridge spans stitched to
##     each other (`cj_pal_south_brid02` <-> `brid03` <-> `brid04`). It joins
##     the parts of a multi-part structure, nothing else.
##   * The real object-to-terrain link is **spatial**: 300 of the region's 334
##     real cells list the objects overlapping them (558 references). Standing
##     in a real terrain cell, that cell names the objects whose own
##     navigation meshes are candidates underfoot. This class uses exactly
##     that -- the real file's own index, not a bounding volume of our own.
##   * A region's `.nvm` carries the same real placements as its `.o`/`.o2`
##     files, in the same space and the same yaw convention: of 115 objects
##     matched by resource id, 103 agree on position to within 0.01 and 111
##     agree on yaw to within 0.001 rad. (The rest are artifacts of matching
##     by nearest instance where several placements share one type id, not a
##     real disagreement.) So an object is placed here the same way World3D
##     places its rendered counterpart.

## Real per-region span and height-grid spacing, matching
## NvmCollision.TILE_SIZE and World3D.REGION_SPAN.
const TILE_SIZE := 20.0

## How far above a reference height a surface may still be chosen as "the
## ground under me". A project choice, not recovered data: it exists because
## `height_at` is asked about a point, while the real client tracks which cell
## the character is already in and never has to guess. Generous enough to step
## onto a real stair tread, small enough not to teleport the player onto a
## bridge passing overhead.
const SURFACE_REACH_UP := 12.0

## One real placed object's navigation mesh, already transformed into the
## region's own coordinate space so nothing downstream repeats the work.
class PlacedObject:
	## Real index into the region's own object list.
	var object_index: int = -1
	var vertices: PackedVector3Array = PackedVector3Array()
	## Flat triples of indices into `vertices`.
	var cells: PackedInt32Array = PackedInt32Array()
	## Flat pairs of 2D points: every real blocking edge, in region space.
	var blocking: PackedVector2Array = PackedVector2Array()
	var bounds_min: Vector2 = Vector2.INF
	var bounds_max: Vector2 = -Vector2.INF

## What `surface_at` found underfoot.
class Surface:
	var height: float = 0.0
	## -1 for the region's own terrain, else a real index into the region's
	## object list.
	var object_index: int = -1
	var is_terrain: bool = true

var region: NvmReader.ParsedRegion
## Keyed by real object index, so a caller can place only the objects it has
## actually resolved without disturbing the region's own indexing.
var objects: Dictionary = {}
## Tile index (row * TILE_MAP_SIDE + col) -> real object indices whose
## footprint overlaps that tile.
##
## This exists because the region's own per-cell object lists, which are the
## real file's own index and the mechanism this class prefers, do **not**
## cover every object: measured on real Jangan region `nv_62a8`, of 122 real
## placed objects only 98 have their whole footprint covered by the cells
## listing them, 13 are covered only partly, and 11 are listed by no cell at
## all. Whatever the real client uses that for, it is not a complete
## object-to-ground map, so relying on it alone would silently drop the
## surface out from under a player standing on one of those 24 objects. The
## real list is still consulted first; this only ever adds.
##
## With it, coverage inside a region is complete: of the same 122 real
## objects, all 109 that actually lie within the region's own 1920x1920 extent
## are found somewhere over their own footprint, and the 13 that are not lie
## *wholly* outside it -- real objects a region's `.nvm` lists because they
## overlap it but which are placed in a neighbouring region, whose own graph
## carries them.
var _object_tiles: Dictionary = {}
## Flat pairs of 2D points: every real blocking edge the terrain itself
## carries, in region space.
var terrain_blocking: PackedVector2Array = PackedVector2Array()

## Places one real object's navigation mesh into region space. `position` and
## `yaw` are the real values a region's `.nvm` (or equivalently its `.o`, see
## this class's own doc comment) gives for that placement.
static func place(
	collision: BmsReader.CollisionMesh, object_index: int, position: Vector3, yaw: float
) -> PlacedObject:
	var placed := PlacedObject.new()
	placed.object_index = object_index
	var xform := Transform3D(Basis(Vector3.UP, yaw), position)
	placed.vertices.resize(collision.vertices.size())
	for i in range(collision.vertices.size()):
		var p: Vector3 = xform * collision.vertices[i].position
		placed.vertices[i] = p
		placed.bounds_min = Vector2(minf(placed.bounds_min.x, p.x), minf(placed.bounds_min.y, p.z))
		placed.bounds_max = Vector2(maxf(placed.bounds_max.x, p.x), maxf(placed.bounds_max.y, p.z))
	placed.cells.resize(collision.cells.size() * 3)
	for i in range(collision.cells.size()):
		var cell: BmsReader.CollisionCell = collision.cells[i]
		placed.cells[i * 3] = cell.a
		placed.cells[i * 3 + 1] = cell.b
		placed.cells[i * 3 + 2] = cell.c
	for edge in BmsCollision.blocking_edges(collision):
		if edge.v0 >= placed.vertices.size() or edge.v1 >= placed.vertices.size():
			continue
		var a: Vector3 = placed.vertices[edge.v0]
		var b: Vector3 = placed.vertices[edge.v1]
		placed.blocking.append(Vector2(a.x, a.z))
		placed.blocking.append(Vector2(b.x, b.z))
	return placed

## Builds a graph for one real region. `placed_objects` may be empty (terrain
## only) or hold any subset of the region's own objects.
static func build(
	parsed: NvmReader.ParsedRegion, placed_objects: Array[PlacedObject]
) -> NavGraph:
	var graph := NavGraph.new()
	graph.region = parsed
	for placed in placed_objects:
		graph.objects[placed.object_index] = placed
		if placed.bounds_min.x > placed.bounds_max.x:
			continue # placed from an empty mesh; nothing to index
		var col0 := clampi(int(floorf(placed.bounds_min.x / TILE_SIZE)), 0, NvmReader.TILE_MAP_SIDE - 1)
		var col1 := clampi(int(floorf(placed.bounds_max.x / TILE_SIZE)), 0, NvmReader.TILE_MAP_SIDE - 1)
		var row0 := clampi(int(floorf(placed.bounds_min.y / TILE_SIZE)), 0, NvmReader.TILE_MAP_SIDE - 1)
		var row1 := clampi(int(floorf(placed.bounds_max.y / TILE_SIZE)), 0, NvmReader.TILE_MAP_SIDE - 1)
		for row in range(row0, row1 + 1):
			for col in range(col0, col1 + 1):
				var key := row * NvmReader.TILE_MAP_SIDE + col
				if not graph._object_tiles.has(key):
					graph._object_tiles[key] = PackedInt32Array()
				var bucket: PackedInt32Array = graph._object_tiles[key]
				bucket.append(placed.object_index)
				graph._object_tiles[key] = bucket
	# The real client tests every edge it crosses; which list an edge lives in
	# does not decide whether it blocks (see NvmCollision), so both are walked.
	for edge in parsed.internal_edges:
		if NvmCollision.is_blocking(edge):
			graph.terrain_blocking.append(edge.line_min)
			graph.terrain_blocking.append(edge.line_max)
	for edge in parsed.global_edges:
		if NvmCollision.is_blocking(edge):
			graph.terrain_blocking.append(edge.line_min)
			graph.terrain_blocking.append(edge.line_max)
	return graph

## The real terrain cell covering a region-local point, or -1 outside the
## region. Uses the region's own 96x96 tile index -- the real file's own
## lookup structure.
func cell_index_at(x: float, z: float) -> int:
	if region == null or region.tiles.is_empty():
		return -1
	var col := int(floorf(x / TILE_SIZE))
	var row := int(floorf(z / TILE_SIZE))
	if col < 0 or row < 0 or col >= NvmReader.TILE_MAP_SIDE or row >= NvmReader.TILE_MAP_SIDE:
		return -1
	var tile: NvmReader.Tile = region.tiles[row * NvmReader.TILE_MAP_SIDE + col]
	return tile.cell_index

## The real objects whose navigation meshes are candidates underfoot at a
## region-local point.
##
## The region's own cell object list comes first, because that is the real
## file's own answer. The footprint index then fills in what that list leaves
## out -- see `_object_tiles` for why it has to.
func objects_at(x: float, z: float) -> Array[int]:
	var out: Array[int] = []
	var seen := {}
	var ci := cell_index_at(x, z)
	if ci >= 0 and ci < region.cells.size():
		for oi in region.cells[ci].object_indices:
			if objects.has(oi) and not seen.has(oi):
				seen[oi] = true
				out.append(oi)
	var col := int(floorf(x / TILE_SIZE))
	var row := int(floorf(z / TILE_SIZE))
	if col < 0 or row < 0 or col >= NvmReader.TILE_MAP_SIDE or row >= NvmReader.TILE_MAP_SIDE:
		return out
	var key := row * NvmReader.TILE_MAP_SIDE + col
	if _object_tiles.has(key):
		for oi in (_object_tiles[key] as PackedInt32Array):
			if not seen.has(oi):
				seen[oi] = true
				out.append(oi)
	return out

## Every real surface a character could be standing on at a region-local
## point: the terrain, plus any real object cell covering it. Heights only.
func heights_at(x: float, z: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.append(NvmCollision.sample_height(region, x, z))
	for oi in objects_at(x, z):
		var placed: PlacedObject = objects[oi]
		if x < placed.bounds_min.x or x > placed.bounds_max.x:
			continue
		if z < placed.bounds_min.y or z > placed.bounds_max.y:
			continue
		var i := 0
		while i + 2 <= placed.cells.size() - 1:
			var a: Vector3 = placed.vertices[placed.cells[i]]
			var b: Vector3 = placed.vertices[placed.cells[i + 1]]
			var c: Vector3 = placed.vertices[placed.cells[i + 2]]
			i += 3
			var h := _triangle_height(a, b, c, x, z)
			if not is_nan(h):
				out.append(h)
	return out

## The real surface underfoot at a region-local point, choosing between them
## the way a character standing at `reference_y` would: the highest surface
## that is not more than SURFACE_REACH_UP above them, so a real bridge passing
## overhead is not mistaken for the ground. Falls back to the lowest surface
## when every candidate is out of reach above.
func surface_at(x: float, z: float, reference_y: float) -> Surface:
	var best := Surface.new()
	best.height = NvmCollision.sample_height(region, x, z)
	best.is_terrain = true
	best.object_index = -1
	var found := false
	for oi in objects_at(x, z):
		var placed: PlacedObject = objects[oi]
		if x < placed.bounds_min.x or x > placed.bounds_max.x:
			continue
		if z < placed.bounds_min.y or z > placed.bounds_max.y:
			continue
		var i := 0
		while i + 2 <= placed.cells.size() - 1:
			var a: Vector3 = placed.vertices[placed.cells[i]]
			var b: Vector3 = placed.vertices[placed.cells[i + 1]]
			var c: Vector3 = placed.vertices[placed.cells[i + 2]]
			i += 3
			var h := _triangle_height(a, b, c, x, z)
			if is_nan(h):
				continue
			if h > reference_y + SURFACE_REACH_UP:
				continue
			if not found or h > best.height:
				found = true
				best.height = h
				best.is_terrain = false
				best.object_index = oi
	if not found and best.height > reference_y + SURFACE_REACH_UP:
		# Terrain itself is out of reach above; nothing sensible to stand on.
		best.height = minf(best.height, reference_y)
	return best

## Convenience wrapper around surface_at.
func height_at(x: float, z: float, reference_y: float) -> float:
	return surface_at(x, z, reference_y).height

## Advances a position on the graph by one horizontal motion, the way the real
## client moves a character: a move that crosses a real blocking edge is
## refused, and the height then comes from whatever real cell is underfoot.
##
## This is the whole movement model, deliberately kept here rather than in
## World3D so it can be exercised headless. The two bugs that cost this
## project a bad release were both movement bugs that only showed up in a
## running world -- a character that stood on a surface and could not move
## along it, and one that fell through. Both are expressible against a
## synthetic ramp in a unit test, and now are.
##
## `from` and the result are region-local; `motion` is a region-local X/Z
## displacement, already scaled by the frame's own delta.
func step(from: Vector3, motion: Vector2) -> Vector3:
	var pos := from
	if motion.length_squared() > 0.0:
		var from2 := Vector2(from.x, from.z)
		var to2 := from2 + motion
		if not blocked(from2, to2):
			pos = Vector3(to2.x, from.y, to2.y)
		else:
			# Slide: keep whichever single axis of the move is still allowed,
			# so a real wall is followed rather than becoming flypaper.
			var along_x := Vector2(to2.x, from2.y)
			var along_z := Vector2(from2.x, to2.y)
			if not blocked(from2, along_x):
				pos = Vector3(along_x.x, from.y, along_x.y)
			elif not blocked(from2, along_z):
				pos = Vector3(along_z.x, from.y, along_z.y)
	pos.y = height_at(pos.x, pos.z, pos.y)
	return pos

## Does moving from `from` to `to` (both region-local X/Z) cross a real
## blocking edge? This is the real client's own test: an edge is a 2D line,
## not geometry, so nothing here depends on heights, winding or shape
## thickness.
func blocked(from: Vector2, to: Vector2) -> bool:
	if _crosses_any(terrain_blocking, from, to):
		return true
	for oi in _candidate_objects(from, to):
		var placed: PlacedObject = objects[oi]
		if maxf(from.x, to.x) < placed.bounds_min.x or minf(from.x, to.x) > placed.bounds_max.x:
			continue
		if maxf(from.y, to.y) < placed.bounds_min.y or minf(from.y, to.y) > placed.bounds_max.y:
			continue
		if _crosses_any(placed.blocking, from, to):
			return true
	return false

## Real objects worth testing for a move: those listed by the real cells the
## move passes through, sampled along its length so a move spanning several
## cells does not miss one.
func _candidate_objects(from: Vector2, to: Vector2) -> Array[int]:
	var seen := {}
	var out: Array[int] = []
	var steps := maxi(1, int(ceilf(from.distance_to(to) / TILE_SIZE)) + 1)
	for s in range(steps + 1):
		var p := from.lerp(to, float(s) / float(steps))
		for oi in objects_at(p.x, p.y):
			if not seen.has(oi):
				seen[oi] = true
				out.append(oi)
	return out

static func _crosses_any(segments: PackedVector2Array, from: Vector2, to: Vector2) -> bool:
	var i := 0
	while i + 1 <= segments.size() - 1:
		var a: Vector2 = segments[i]
		var b: Vector2 = segments[i + 1]
		i += 2
		if maxf(a.x, b.x) < minf(from.x, to.x) or minf(a.x, b.x) > maxf(from.x, to.x):
			continue
		if maxf(a.y, b.y) < minf(from.y, to.y) or minf(a.y, b.y) > maxf(from.y, to.y):
			continue
		if Geometry2D.segment_intersects_segment(from, to, a, b) != null:
			return true
	return false

## Height of the plane of triangle (a, b, c) at (x, z), or NAN when (x, z)
## lies outside the triangle in plan view.
static func _triangle_height(a: Vector3, b: Vector3, c: Vector3, x: float, z: float) -> float:
	var v0x := c.x - a.x
	var v0z := c.z - a.z
	var v1x := b.x - a.x
	var v1z := b.z - a.z
	var v2x := x - a.x
	var v2z := z - a.z
	var den := v0x * v1z - v1x * v0z
	if absf(den) < 0.000001:
		return NAN
	var u := (v2x * v1z - v1x * v2z) / den
	var v := (v0x * v2z - v2x * v0z) / den
	# A small tolerance so a point exactly on a shared edge belongs to a
	# triangle rather than falling between two of them.
	const EPS := 0.0001
	if u < -EPS or v < -EPS or u + v > 1.0 + EPS:
		return NAN
	return a.y + u * (c.y - a.y) + v * (b.y - a.y)
