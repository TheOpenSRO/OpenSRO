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
##   * `step_tracked` -- where does a move from here end up, given what the
##     character is standing on, and what does it stand on afterwards.
##
## **No physics.** Nothing here builds a collision shape. That is the point:
## driving Godot collision from this data was tried and reverted (see
## docs/WORLD_ISSUES.md's sixty-second and sixty-third rounds) because a
## capsule against a two-sided single-thickness surface pins itself, and the
## world's mirrored transform forces that surface to be two-sided. The real
## client has no capsule and no surface -- it finds the cell underfoot, takes
## its height, and tests each edge it crosses as a 2D line. So does this.
##
## ## The movement rule, as the client itself runs it
##
## Recovered from `sro_client.exe`'s own navmesh walk (the decompiled
## `CRTNavMeshTerrain::vslot_002` at 0x4047a0, `RTNavMeshTerrain::FUN_00404060`,
## `CRTNavMeshObj::vslot_002` at 0x44b500, the object-entry test
## `RTNavMeshObj::FUN_0044a790` and the in-object cell walk
## `CRTNavMeshObj::FUN_0044add0`; written up in docs/protocol/NAVMESH_MOVEMENT.md):
##
##   * The character is always either on the terrain or **on one object**, and
##     the client remembers which. Being "on" an object is a state entered by
##     crossing one of its outline edges, never inferred from height.
##   * On the terrain, the move is tested against the terrain's own blocking
##     edges and against the **outline** edges of the objects listed for the
##     cells it passes through. An outline edge with bit 0 set stops the
##     move; one with bit 0 clear lets the character *onto* the object, and
##     the height then comes from that object's cell. Edges with bit 4
##     (0x10) are not tested at all from outside: they are how a character
##     walks *under* a city wall's archway while the wall's own walkway stays
##     fenced (real `cj_s.bsr`: 121 walls, 21 such edges over its gates).
##   * On an object, **only that object's edges** are tested, and only as the
##     walk reaches them **cell by cell** (round 644, `_object_walk`): from the
##     cell the mover is in, that cell's own edges; its internal edges
##     directionally (value 1 blocks a mover on the edge's `cell_to` side,
##     value 2 one on its `cell_from` side), its outline edges as exits
##     (value 2 or 0x10 blocks leaving; anything else steps back onto the
##     terrain). An edge of another part of the same mesh -- a pier on the
##     canyon floor under a bridge deck -- is never met from the deck. Neither the terrain's walls nor any other object's apply
##     while standing on an object, unless the object's own navigation mesh
##     names an event called "event"/"EVENT" (the client's loader sets a
##     byte for exactly those two spellings at 0x449395/0x4495d9, and the
##     terrain walk reads it at 0x404c71): those 59 real objects are all
##     fortress-war structures, dungeon doors and arena pads.
##   * The client pushes the character 0.01 past a crossed edge and 0.01
##     short of a blocking one (the double at 0x00e1b820), and slides along
##     a wall instead of sticking to it.
##
## Measured over every object the object index names (2,043 with a
## navigation mesh, 62,120 outline edges, 90,018 internal ones): 81.1% of
## outline edges carry flag 3 (a wall from both sides), 11.5% flag 0x83, 5.3%
## flag 0 (a doorway: real `cj_weapon.bsr` has 3 of them against 31 walls,
## `cj_pal_indoor.bsr` 10 against 56), 0.9% flag 0x10 (an archway
## underpass). Internal edges are 94.2% flag 4 (open), 3.8% flag 7 (a railing
## across a walkable deck), and 25 in 90,018 are genuinely one-way.
##
## ## What this replaced, and why
##
## The previous model inferred "on an object" from height: whatever surface
## lay within SURFACE_REACH_UP above the mover was the ground, and an
## object's walls only applied to someone already on it. That is exactly how
## a player got trapped inside a building: walking into the footprint of a
## shop whose floor sits a few units up was allowed (its walls were not
## tested for a terrain mover), the floor was then within reach so the
## player was lifted onto it, and from then on the same walls -- now
## applicable -- refused every way out except a doorway they had never used.
## Round 162 measured the Alexandria case at exactly that shape: terrain at
## 863, a floor at 868.5, and a player standing inside. Crossing edges
## instead of inferring height cannot produce that state.
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
## ground under me" by the height *queries* (`surface_at`, `height_at`). A
## project choice, not recovered data: those queries are asked about a point,
## while the real client tracks which cell the character is already in and
## never has to guess. Movement no longer uses it to decide what the mover
## is on (see `step_tracked`); it only settles what to stand on after a
## teleport, a region change or a landing.
const SURFACE_REACH_UP := 12.0

## The object-edge flag bits, as the client's own walk reads them. Names are
## this project's; the values and their tests are the binary's.
## Stops a mover standing on the edge's `cell_to` side -- outside, for an
## outline edge. The entry test (`RTNavMeshObj::FUN_0044a790`) checks only
## this bit.
const EDGE_BLOCKS_FROM_OUTSIDE := 0x01
## Stops a mover standing on the edge's `cell_from` side -- inside, for an
## outline edge; the in-object walk tests it against the current cell.
const EDGE_BLOCKS_FROM_INSIDE := 0x02
## The edge joins two cells of the same object (the second list).
const EDGE_INTERNAL := 0x04
## The edge is stitched to another object's edge (`MapObject.linked_edges`).
const EDGE_LINKED := 0x08
## Not tested for a mover who is not on the object -- they pass beneath --
## and a wall for one who is (`(flags & 0x12) != 0` in the in-object walk).
const EDGE_IGNORED_FROM_OUTSIDE := 0x10

## How far past a crossed edge, and short of a blocking one, the character is
## placed: the client's own value, a double at 0x00e1b820 that both the entry
## test and the in-object walk multiply an edge normal by.
const CONTACT_PUSH := 0.01

## How many edge events one frame's motion may pass through (a doorway, then
## a wall to slide along, then a second wall...). A project choice; the real
## client recurses without a bound. Eight covers any real frame at walking
## speed, and a corner two walls meet in is stopped rather than looped in.
const MAX_SUBSTEPS := 8

## `standing_on` value for the terrain.
const ON_TERRAIN := -1

## How many edges a cell of an object keeps, and how many of them the
## in-object walk tests. READ: the deserializer (`RTNavMeshObj::FUN_004489b0`)
## hands every edge to its `cell_from` cell and, when it has one, its
## `cell_to` cell through `RTNavMeshObj::FUN_0045dcf0`, which appends it to the
## cell's slot list at +0x28 while the count at +0x24 is below 4; the walk
## (`CRTNavMeshObj::FUN_0044add0`) reads slots 0..2 (`CRTNavCellTri::
## FUN_0045dec0`, `iVar11` 0..2). MEASURED (round 644, `tools/
## nav_phantom_census.gd`): of 2,043 object navigation meshes one has a single
## cell whose slot count is not three.
const CELL_EDGE_SLOTS_KEPT := 4
const CELL_EDGE_SLOTS := 3

## How many cells one in-object walk may pass through before it gives up and
## ends the move where it is. The client bounds its recursion with a budget
## the caller passes in (`param_7[1]`, decremented per edge crossed); its
## value was not read. OURS: far more than any real frame crosses.
const MAX_CELL_STEPS := 512

## How far a terrain-wall stop is moved toward the centre of the cell the
## mover is in, at most: the double 0xb45de8 = 0.2 in the server's
## RTNavMeshTerrain::FUN_009c1050 (asm 0x9c1092 / 0x9c10ac) and 0xe1b850 = 0.2
## in the client's twin FUN_004472d0 (READ). The cell centre is the cell's
## +0x20/+0x24, (min + max) * 0.5, set by CRTNavCellQuad::vslot_010 (client
## 0x4476c0, server 0x9c1210; 0.5 at 0xe1b7d0 / 0xb45c50, READ). Used only by
## the no-slide walk (`step_tracked(..., false)`).
const TERRAIN_BLOCK_NUDGE := 0.2

## One real placed object's navigation mesh, already transformed into the
## region's own coordinate space so nothing downstream repeats the work.
class PlacedObject:
	## Real index into the region's own object list.
	var object_index: int = -1
	var vertices: PackedVector3Array = PackedVector3Array()
	## Flat triples of indices into `vertices`.
	var cells: PackedInt32Array = PackedInt32Array()
	## Flat pairs of 2D points: every real edge whose flags carry either
	## blocking bit, in region space. Kept for the QA reports that list an
	## object's walls; movement reads the per-edge arrays below.
	var blocking: PackedVector2Array = PackedVector2Array()
	## Every real edge, outline list first then internal, as flat 2D pairs
	## in region space, with its file flags, its two vertex indices, whether
	## it is an outline edge, and a point on its `cell_from` side (that cell's
	## centroid) so a mover's side of the line can be told.
	var edges: PackedVector2Array = PackedVector2Array()
	var edge_flags: PackedInt32Array = PackedInt32Array()
	var edge_v0: PackedInt32Array = PackedInt32Array()
	var edge_v1: PackedInt32Array = PackedInt32Array()
	var edge_outline: PackedByteArray = PackedByteArray()
	var edge_inside: PackedVector2Array = PackedVector2Array()
	## The edge's two cells as the file names them, -1 for none (an outline
	## edge's far side). Parallel to `edge_flags`.
	var edge_cell_from: PackedInt32Array = PackedInt32Array()
	var edge_cell_to: PackedInt32Array = PackedInt32Array()
	## Per cell, the edges (indices into `edge_flags`) the in-object walk
	## tests from it: every edge naming the cell, outline list first, in file
	## order, at most CELL_EDGE_SLOTS of them -- the loader's own slots (see
	## CELL_EDGE_SLOTS and `_object_walk`).
	var cell_edges: Array[PackedInt32Array] = []
	## The "event"/"EVENT" marker (see the class comment): the terrain and the
	## other objects keep blocking a mover who stands on this object.
	var terrain_collides: bool = false
	var bounds_min: Vector2 = Vector2.INF
	var bounds_max: Vector2 = -Vector2.INF

## What `surface_at` found underfoot.
class Surface:
	var height: float = 0.0
	## ON_TERRAIN for the region's own terrain, else a real index into the
	## region's object list.
	var object_index: int = -1
	var is_terrain: bool = true

## What one `step_tracked` did.
class StepResult:
	var position: Vector3
	## What the mover stands on afterwards: ON_TERRAIN or an object index.
	var standing_on: int = -1
	## The object stepped onto through one of its outline edges this step, or
	## -1; the object left the same way, or -1; whether a wall stopped or
	## deflected the move. For traces and tests.
	var entered: int = -1
	var exited: int = -1
	var blocked: bool = false
	## A no-slide walk's terrain-wall stop was refused by the cell's objects
	## and the mover put back at the walk's source point (see step_tracked).
	var cancelled: bool = false

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

## The Godot Y rotation that turns an object the way the game turns it for a
## stored placement yaw (`.o`, `.o2` or `.nvm`), in the region's own un-mirrored
## coordinates -- the space World3D's terrain group and this class work in.
## It is the NEGATED yaw. Read from the client binary, not inferred:
##
##   * `MapLoader::FUN_0042b8b0` (JMX_Library\navmesh\MapLoader.cpp, "Load
##     Fail(NavMesh Obj)") builds every navmesh object from its placement
##     record: position from the record's words 1..3, and the float at record
##     +0x12 -- the yaw -- handed to `FUN_0043cda0`.
##   * `FUN_0043cda0` zeroes a 4x4 float matrix and writes m[0] = m[10] =
##     cos(yaw), m[2] = sin(yaw), m[8] = -sin(yaw), m[5] = m[15] = 1
##     (`0x43cded`..`0x43cdfb`; its two trig calls are the CRT's cos
##     `0xb44a10` and sin `0xb44b40`, told apart by their x87 fallbacks'
##     own `fcos` at `0xb44a7d` and `fsin` at `0xb44bad`).
##   * That matrix is a Direct3D row-vector matrix: the render-side callers
##     write the position into m[12..14] (`CImitationObj::vslot_027` at
##     `0x9c3d90`, `FUN_009cf600` at +0x30/+0x34/+0x38), so a vertex is placed
##     as `v * M + position`, and local +X goes to (cos, 0, sin), local +Z to
##     (-sin, 0, cos).
##
## Godot's `Basis(UP, a)` sends +X to (cos a, 0, -sin a) and +Z to
## (sin a, 0, cos a), so matching the game needs `a = -yaw`. The positive yaw
## this project used until round 506 turned every object that is not at 0 or
## 180 degrees the wrong way -- a 90-degree building faced 270. Measured
## against the navmesh's own data as well (`client/tools/check_object_yaw.gd`):
## the only object-to-object edge links in Jangan (bridge spans) close to a
## 1.48-unit mean gap under the negated yaw against 58.4 under the positive
## one, and footprint agreement with the cells that list each object is
## highest under it (99.3% against 97.2% over 57 regions).
static func godot_yaw(engine_yaw: float) -> float:
	return -engine_yaw

## Places one real object's navigation mesh into region space. `position` and
## `yaw` are the real values a region's `.nvm` (or equivalently its `.o`, see
## this class's own doc comment) gives for that placement; the yaw is turned
## the game's way by `godot_yaw`.
static func place(
	collision: BmsReader.CollisionMesh, object_index: int, position: Vector3, yaw: float
) -> PlacedObject:
	var placed := PlacedObject.new()
	placed.object_index = object_index
	var xform := Transform3D(Basis(Vector3.UP, godot_yaw(yaw)), position)
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
	placed.cell_edges.resize(collision.cells.size())
	for c in range(collision.cells.size()):
		placed.cell_edges[c] = PackedInt32Array()
	for list_index in range(2):
		var list: Array[BmsReader.CollisionEdge] = collision.outline_edges if list_index == 0 else collision.internal_edges
		for edge in list:
			if edge.v0 >= placed.vertices.size() or edge.v1 >= placed.vertices.size():
				continue
			# Which cell is "from" decides what the directional bits mean, so
			# an edge that names no valid from-cell cannot be tested and is
			# left out rather than guessed at. Real data never does this: all
			# 62,120 outline edges name a real cell on their from side.
			var from_cell := edge.cell_from
			if from_cell == BmsReader.NO_CELL or from_cell * 3 + 2 >= placed.cells.size():
				from_cell = edge.cell_to
			if from_cell == BmsReader.NO_CELL or from_cell * 3 + 2 >= placed.cells.size():
				continue
			var a: Vector3 = placed.vertices[edge.v0]
			var b: Vector3 = placed.vertices[edge.v1]
			var ca: Vector3 = placed.vertices[placed.cells[from_cell * 3]]
			var cb: Vector3 = placed.vertices[placed.cells[from_cell * 3 + 1]]
			var cc: Vector3 = placed.vertices[placed.cells[from_cell * 3 + 2]]
			placed.edges.append(Vector2(a.x, a.z))
			placed.edges.append(Vector2(b.x, b.z))
			placed.edge_flags.append(edge.flags)
			placed.edge_v0.append(edge.v0)
			placed.edge_v1.append(edge.v1)
			placed.edge_outline.append(1 if list_index == 0 else 0)
			placed.edge_inside.append(Vector2((ca.x + cb.x + cc.x) / 3.0, (ca.z + cb.z + cc.z) / 3.0))
			var index := placed.edge_flags.size() - 1
			var raw_from := -1 if edge.cell_from == BmsReader.NO_CELL or edge.cell_from >= collision.cells.size() else edge.cell_from
			var raw_to := -1 if edge.cell_to == BmsReader.NO_CELL or edge.cell_to >= collision.cells.size() else edge.cell_to
			placed.edge_cell_from.append(raw_from)
			placed.edge_cell_to.append(raw_to)
			_slot_edge(placed, raw_from, index)
			if raw_to != raw_from:
				_slot_edge(placed, raw_to, index)
	for name in collision.events:
		# The loader's own comparison: a five-character match against
		# "event" or "EVENT", nothing looser.
		if name == "event" or name == "EVENT":
			placed.terrain_collides = true
	return placed

## Appends an edge to a cell's slot list the way the loader does
## (`RTNavMeshObj::FUN_0045dcf0`: nothing for no cell, nothing past the
## fourth).
static func _slot_edge(placed: PlacedObject, cell: int, edge: int) -> void:
	if cell < 0:
		return
	var slots: PackedInt32Array = placed.cell_edges[cell]
	if slots.size() < CELL_EDGE_SLOTS_KEPT:
		slots.append(edge)
		placed.cell_edges[cell] = slots

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
##
## This is a point query for settling what a *placed* character stands on
## (after a teleport, a landing or a region change); a walking character's
## footing is tracked by `step_tracked` instead, which is what the real
## client does and what keeps a wall a wall.
func surface_at(x: float, z: float, reference_y: float) -> Surface:
	var best := Surface.new()
	best.height = NvmCollision.sample_height(region, x, z)
	best.is_terrain = true
	best.object_index = ON_TERRAIN
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

## The height something arriving from above comes to rest at: the highest
## walkable surface over this point, whatever it is.
##
## This is a different question from height_at, and conflating them is a
## real bug rather than a nicety. height_at answers "what is under me now",
## so it refuses a surface more than SURFACE_REACH_UP above the mover --
## correct for walking, since you cannot step up an arbitrary ledge. But
## someone being *placed* into the world has no current height to step from;
## they land on top.
##
## Measured in Jangan town: the octagonal plaza's deck sits **13.8** units
## above the terrain at local 985,1000, and SURFACE_REACH_UP is 12.0, so
## height_at rejected the deck by 1.8 units and every zone change into the
## town square put the player -- and later every NPC on it -- inside the
## plaza rather than on it.
##
## Deliberately not fixed by raising SURFACE_REACH_UP: that constant is a
## considered choice ("generous enough to step onto a stair tread, small
## enough not to teleport the player onto a bridge passing overhead"), and
## widening it to clear one measured plaza would be fitting a threshold to a
## single observation while making every overhead bridge a hazard.
func landing_height_at(x: float, z: float) -> float:
	var best := NvmCollision.sample_height(region, x, z)
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
			if not is_nan(h) and h > best:
				best = h
	return best

## Advances a position on the graph by one horizontal motion without a
## tracked footing: what the mover stands on is settled first by height
## (`surface_at`), then `step_tracked` does the walk. For callers that have no
## state to carry -- tests, one-off probes. A character that keeps walking
## should carry `StepResult.standing_on` from frame to frame instead, because
## inferring footing from height is exactly what let a wall be walked
## through (see the class comment).
func step(from: Vector3, motion: Vector2) -> Vector3:
	var on := surface_at(from.x, from.z, from.y).object_index
	return step_tracked(from, motion, on).position

## Advances a position on the graph by one horizontal motion, the way the real
## client moves a character: the move is walked edge by edge, an outline edge
## crossed lets the character onto or off an object, a blocking edge stops
## the move and the remainder slides along it, and the height then comes
## from whatever real cell is underfoot.
##
## `from` and the result are region-local; `motion` is a region-local X/Z
## displacement, already scaled by the frame's own delta; `standing_on` is
## what the character stands on now, ON_TERRAIN or an object index, as the
## previous step reported it (or `surface_at` settled it after a teleport).
##
## `slide` false stops the move at the first blocking edge instead of sliding
## along it: the server's navmesh walk for a skill's move (Ghost Walk's
## FUN_005862e0 -> CRegionManagerBody::vslot_012 0x98b300, whose loop breaks
## on the walk's blocked bit; round 616-618 integration and its review). What
## the stop is depends on the wall, READ in the terrain walk's block branch
## (server 0x9a0c7e..0x9a0cf8, client 0x4047a0 with FUN_004472d0 and
## FUN_004045f0):
## - a TERRAIN wall: the crossing point, moved toward the centre of the cell
##   the mover is in by at most TERRAIN_BLOCK_NUDGE (FUN_009c1050). Then
##   FUN_009a05a0 tests the move from where the walk entered that cell (the
##   walk's source point: its start, the last cell boundary it crossed, or
##   the last object it stepped on or off -- vslot_012 starts a new walk
##   there) to that stop against every object the cell lists (FUN_009a0030,
##   the object entry test); if any is met, the destination is the source
##   point -- no move in that cell. That "met" means crossing an outline edge
##   not marked 0x10, as the terrain mover's entry test here reads it, is
##   INFERRED.
## - an OBJECT wall: CONTACT_PUSH short along the move, as before (the object
##   walks were not re-read for this).
## `StepResult.cancelled` says the terrain check sent the mover back.
func step_tracked(from: Vector3, motion: Vector2, standing_on: int, slide: bool = true) -> StepResult:
	var result := StepResult.new()
	var pos := from
	var on := standing_on
	# A footing that no longer exists under the mover -- a stale index after a
	# region change, or a surface walked off through a gap in its outline --
	# is the terrain.
	if on != ON_TERRAIN and (not objects.has(on) or is_nan(_surface_near(objects[on], pos.x, pos.z, pos.y))):
		on = ON_TERRAIN
	var remaining := motion
	# Where the current walk began, for the no-slide terrain-wall rule: the
	# start, then each object entered or left.
	var source := Vector2(pos.x, pos.z)
	for _sub in range(MAX_SUBSTEPS):
		if remaining.length_squared() <= 1.0e-10:
			break
		var from2 := Vector2(pos.x, pos.z)
		var to2 := from2 + remaining
		var hit := _first_event(from2, to2, on, pos.y)
		if hit.is_empty():
			pos.x = to2.x
			pos.z = to2.y
			remaining = Vector2.ZERO
			break
		var length := remaining.length()
		var dir := remaining / length
		var contact: Vector2 = hit["point"]
		match String(hit["kind"]):
			"enter":
				var oi: int = hit["object"]
				var placed: PlacedObject = objects[oi]
				var landed := contact + dir * CONTACT_PUSH
				pos.x = landed.x
				pos.z = landed.y
				# The height of the cell just entered, chosen nearest the
				# mover's own height so a stacked floor is entered at the
				# level walked in from; the crossed edge's own height at the
				# crossing when the push lands a hair outside every cell.
				var h := _surface_near(placed, pos.x, pos.z, pos.y)
				if is_nan(h):
					h = _edge_height_at(placed, hit["edge"], contact)
				pos.y = h
				on = oi
				result.entered = oi
				source = landed
				remaining = _onward(to2 - landed, dir)
			"exit":
				var left: int = on
				var landed := contact + dir * CONTACT_PUSH
				pos.x = landed.x
				pos.z = landed.y
				on = ON_TERRAIN
				result.exited = left
				# Stepping off one object straight onto another whose edge
				# lies along the same line -- a stair's head against a deck,
				# one bridge span against the next -- crosses both edges at
				# once, and the push lands past the second one unseen. Hand
				# the footing over when a surface at the mover's own height
				# is right there.
				var reach := _seam_object_at(pos.x, pos.z, pos.y, left)
				if reach != ON_TERRAIN:
					on = reach
					result.entered = reach
					pos.y = _surface_near(objects[reach], pos.x, pos.z, pos.y)
				else:
					pos.y = NvmCollision.sample_height(region, pos.x, pos.z)
				source = landed
				remaining = _onward(to2 - landed, dir)
			"block":
				result.blocked = true
				var short := maxf(from2.distance_to(contact) - CONTACT_PUSH, 0.0)
				var stopped := from2 + dir * short
				pos.x = stopped.x
				pos.z = stopped.y
				if not slide:
					if int(hit["object"]) == ON_TERRAIN and on == ON_TERRAIN:
						var stop: Array = _terrain_block_stop(source, contact, dir)
						pos.x = (stop[0] as Vector2).x
						pos.z = (stop[0] as Vector2).y
						result.cancelled = bool(stop[1])
					remaining = Vector2.ZERO
					break
				# Slide: what is left of the move, projected along the wall,
				# so a wall is followed rather than becoming flypaper.
				var a: Vector2 = hit["a"]
				var b: Vector2 = hit["b"]
				var along := (b - a).normalized()
				var rest := to2 - stopped
				remaining = along * rest.dot(along)
				if remaining.length() < 1.0e-4:
					remaining = Vector2.ZERO
					break
	# The height comes from whatever real cell is underfoot.
	if on != ON_TERRAIN:
		var h := _surface_near(objects[on], pos.x, pos.z, pos.y)
		if is_nan(h):
			on = ON_TERRAIN
		else:
			pos.y = h
	if on == ON_TERRAIN:
		pos.y = NvmCollision.sample_height(region, pos.x, pos.z)
	result.position = pos
	result.standing_on = on
	return result

## The no-slide stop at a terrain wall met at `contact` by a walk from
## `source` along `dir` (see step_tracked): the contact moved toward the cell
## centre by at most TERRAIN_BLOCK_NUDGE, or the point the walk entered the
## cell when the move there meets one of the cell's objects. Returns
## [stop: Vector2, cancelled: bool].
func _terrain_block_stop(source: Vector2, contact: Vector2, dir: Vector2) -> Array:
	var k := cell_index_at(contact.x - dir.x * 0.001, contact.y - dir.y * 0.001)
	if k < 0 or k >= region.cells.size():
		return [contact - dir * CONTACT_PUSH, false]
	var cell: NvmReader.Cell = region.cells[k]
	var toward := (cell.rect_min + cell.rect_max) * 0.5 - contact
	var stop := contact + (toward if toward.length() <= TERRAIN_BLOCK_NUDGE else toward.normalized() * TERRAIN_BLOCK_NUDGE)
	var entry := _terrain_block_source(source, contact, dir)
	for oi in cell.object_indices:
		if _meets_outline(oi, entry, stop):
			return [entry, true]
	return [stop, false]

## Where a walk from `source` to `contact` entered the terrain cell holding
## the point just before `contact`: `source` itself when it is in that cell,
## else the crossing of the cell's rectangle on the way.
func _terrain_block_source(source: Vector2, contact: Vector2, dir: Vector2) -> Vector2:
	var k := cell_index_at(contact.x - dir.x * 0.001, contact.y - dir.y * 0.001)
	if k < 0 or k >= region.cells.size():
		return source
	var cell: NvmReader.Cell = region.cells[k]
	var lo := cell.rect_min
	var hi := cell.rect_max
	if source.x >= lo.x and source.x <= hi.x and source.y >= lo.y and source.y <= hi.y:
		return source
	# The largest entering parameter over the two slabs.
	var d := contact - source
	var t_in := 0.0
	for axis in 2:
		var s0: float = source[axis]
		var dd: float = d[axis]
		if absf(dd) < 1.0e-9:
			continue
		var t1: float = (lo[axis] - s0) / dd
		var t2: float = (hi[axis] - s0) / dd
		t_in = maxf(t_in, minf(t1, t2))
	return source + d * clampf(t_in, 0.0, 1.0)

## Does the segment a -> b cross an outline edge of object `oi` that the
## terrain mover's entry test would meet (not marked to be passed beneath)?
func _meets_outline(oi: int, a: Vector2, b: Vector2) -> bool:
	if not objects.has(oi):
		return false
	var placed: PlacedObject = objects[oi]
	var e := 0
	while e < placed.edge_flags.size():
		if placed.edge_outline[e] != 0 and (placed.edge_flags[e] & EDGE_IGNORED_FROM_OUTSIDE) == 0:
			if _segment_hit(a, b, placed.edges[e * 2], placed.edges[e * 2 + 1]) != null:
				return true
		e += 1
	return false

## Does moving from `from` to `to` (both region-local X/Z) run into a wall?
## `standing_on` is what the mover stands on, as `step_tracked` reports it.
## A move that merely steps onto or off an object is not blocked.
## `y`, the mover's height, picks the cell of an object it is on where parts
## of the object overlap in plan; without it the highest is taken.
func blocked(from: Vector2, to: Vector2, standing_on: int = ON_TERRAIN, y: float = NAN) -> bool:
	var hit := _first_event(from, to, standing_on, y)
	return not hit.is_empty() and String(hit["kind"]) == "block"

## The first thing along the move that changes it: the nearest wall, doorway
## or exit edge, as {kind, point, a, b, object, edge}, or {} when the move is
## clear. `kind` is "block", "enter" or "exit".
##
## A mover on the terrain (or on an object that keeps terrain collision)
## meets the terrain's blocking edges and the outline edges of every object
## the move passes; a mover on an object meets the edges of the cells its
## walk crosses (`_object_walk`), starting from the cell nearest `from_y`.
func _first_event(from: Vector2, to: Vector2, standing_on: int, from_y: float = NAN) -> Dictionary:
	var best := {}
	var best_d := INF
	var on_object := standing_on != ON_TERRAIN and objects.has(standing_on)
	var test_world := not on_object or (objects[standing_on] as PlacedObject).terrain_collides
	if test_world:
		var t := _first_crossing(terrain_blocking, from, to)
		if t >= 0:
			var p: Vector2 = terrain_blocking[t]
			var q: Vector2 = terrain_blocking[t + 1]
			var hit: Variant = Geometry2D.segment_intersects_segment(from, to, p, q)
			if hit != null:
				var d: float = from.distance_squared_to(hit)
				if d < best_d:
					best_d = d
					best = {"kind": "block", "point": hit, "a": p, "b": q, "object": ON_TERRAIN, "edge": t / 2}
		for oi in _candidate_objects(from, to):
			if oi == standing_on or not objects.has(oi):
				continue
			var placed: PlacedObject = objects[oi]
			if maxf(from.x, to.x) < placed.bounds_min.x or minf(from.x, to.x) > placed.bounds_max.x:
				continue
			if maxf(from.y, to.y) < placed.bounds_min.y or minf(from.y, to.y) > placed.bounds_max.y:
				continue
			var e := 0
			while e < placed.edge_flags.size():
				var flags := placed.edge_flags[e]
				# The entry test walks only outline edges, and skips those
				# marked to be passed beneath.
				if placed.edge_outline[e] == 0 or (flags & EDGE_IGNORED_FROM_OUTSIDE) != 0:
					e += 1
					continue
				var a: Vector2 = placed.edges[e * 2]
				var b: Vector2 = placed.edges[e * 2 + 1]
				var hit: Variant = _segment_hit(from, to, a, b)
				if hit != null:
					var d: float = from.distance_squared_to(hit)
					if d < best_d:
						if _on_from_side(a, b, from, placed.edge_inside[e]):
							# Already inside the outline, on the terrain, and
							# walking out. The client's entry test does not
							# distinguish sides and would refuse a wall from
							# within too; letting the mover out is this
							# project's choice, because the only ways into
							# that state -- a teleport, a gap in an outline --
							# are not the player's doing, and refusing turns
							# each into a trap.
							pass
						elif (flags & EDGE_BLOCKS_FROM_OUTSIDE) != 0:
							best_d = d
							best = {"kind": "block", "point": hit, "a": a, "b": b, "object": oi, "edge": e}
						else:
							best_d = d
							best = {"kind": "enter", "point": hit, "a": a, "b": b, "object": oi, "edge": e}
				e += 1
	if on_object:
		var hit := _object_walk(standing_on, from, to, from_y)
		if not hit.is_empty():
			var d: float = from.distance_squared_to(hit["point"])
			if d < best_d:
				best_d = d
				best = hit
	return best

## The client's in-object walk (`CRTNavMeshObj::FUN_0044add0`, READ round
## 644) for a mover on object `oi` moving from `from` to `to` at height
## `from_y`: the first wall or exit met, as `_first_event` reports it, or {}
## when the move ends on the object.
##
## The walk goes **cell to cell**. From the cell the mover is in it tests
## only that cell's own edge slots (CELL_EDGE_SLOTS), less the edge it came
## in by; an internal edge crossed hands the move to the cell on its other
## side unless the edge's direction bits stop it (value 2 against a mover in
## its `cell_from`, value 1 against one in its `cell_to`); an outline edge
## crossed is a wall when it carries 0x02 or 0x10 and an exit otherwise.
## Nothing else of the object is tested. Until round 644 this tested every
## edge of the object in plan view, whatever cell it bounded: a bridge deck
## met the outline of its own piers on the canyon floor 460 units below and
## stopped the player half-way across (Black Robber Den; 73 objects and 86
## map placements carry such edges, `tools/nav_phantom_census.gd`).
##
## Which cell the mover is in is not carried from step to step here, unlike
## the client, which keeps a cell pointer in the position (`vslot_002`
## 0x44b500 reads `*param_4`): it is the cell under the point whose height is
## nearest the mover's (`_cells_under`) -- OURS, and the same choice
## `_surface_near` makes for the height. A candidate edge must also be one the
## move leaves the current cell through (the cell's centroid on the far
## side), so a move through a vertex shared by several cells cannot bounce
## between them -- OURS; the client's segment test (`FUN_00447b30`) has no such
## guard and relies on its recursion budget.
func _object_walk(oi: int, from: Vector2, to: Vector2, from_y: float) -> Dictionary:
	var placed: PlacedObject = objects[oi]
	if (to - from).length_squared() <= 0.0:
		return {}
	var starts := _cells_under(placed, from.x, from.y, from_y)
	if starts.is_empty():
		return {}
	# The cell the mover is in is inferred, and a point a hair from a shared
	# edge or vertex is under two or three cells within _triangle_height's
	# tolerance. A walk from the wrong one of them can leave it through the
	# shared vertex without crossing any of its edges -- measured on real
	# `cj_field_lamp` (round 644's sweep): a player sliding into the corner of
	# the sealed lamp base walked out through it. So a walk that meets nothing
	# must end inside the cell it reached; if it does not, the next candidate
	# cell is tried, and if none explains the move it is stopped where it is.
	for cell in starts:
		var walked := _walk_cells(placed, oi, cell, from, to)
		var hit: Dictionary = walked[0]
		if not hit.is_empty():
			return hit
		if _in_cell(placed, int(walked[1]), to):
			return {}
	return _stop_in_cell(placed, oi, starts[0], from, to)

## One cell-to-cell walk from `cell` (see `_object_walk`): [event or {}, the
## cell it ended in].
func _walk_cells(placed: PlacedObject, oi: int, cell: int, from: Vector2, to: Vector2) -> Array:
	var d := to - from
	var len2 := d.length_squared()
	var came_by := -1
	var t_at := 0.0
	for _step in range(MAX_CELL_STEPS):
		var centre := _cell_centroid(placed, cell)
		var slots: PackedInt32Array = placed.cell_edges[cell]
		var best_e := -1
		var best_t := INF
		var best_p := Vector2.ZERO
		for k in range(mini(CELL_EDGE_SLOTS, slots.size())):
			var e := slots[k]
			if e == came_by:
				continue
			var a: Vector2 = placed.edges[e * 2]
			var b: Vector2 = placed.edges[e * 2 + 1]
			# Only an edge the move goes out through: the cell's centre on one
			# side of it, the direction of travel toward the other.
			var along := b - a
			if signf(along.cross(d)) == signf(along.cross(centre - a)):
				continue
			var hit: Variant = _segment_hit(from, to, a, b)
			if hit == null:
				continue
			var t: float = ((hit as Vector2) - from).dot(d) / len2
			if t < t_at - 1.0e-6 or t >= best_t:
				continue
			best_e = e
			best_t = t
			best_p = hit
		if best_e < 0:
			return [{}, cell]
		var flags := placed.edge_flags[best_e]
		var a2: Vector2 = placed.edges[best_e * 2]
		var b2: Vector2 = placed.edges[best_e * 2 + 1]
		if placed.edge_outline[best_e] != 0:
			var kind := "block" if (flags & (EDGE_BLOCKS_FROM_INSIDE | EDGE_IGNORED_FROM_OUTSIDE)) != 0 else "exit"
			return [{"kind": kind, "point": best_p, "a": a2, "b": b2, "object": oi, "edge": best_e}, cell]
		var cf := placed.edge_cell_from[best_e]
		var ct := placed.edge_cell_to[best_e]
		if ((flags & EDGE_BLOCKS_FROM_INSIDE) != 0 and cf == cell) or ((flags & EDGE_BLOCKS_FROM_OUTSIDE) != 0 and ct == cell):
			return [{"kind": "block", "point": best_p, "a": a2, "b": b2, "object": oi, "edge": best_e}, cell]
		var next := ct if cf == cell else cf
		if next < 0 or next >= placed.cell_edges.size():
			return [{}, cell]
		cell = next
		came_by = best_e
		t_at = best_t
	return [{}, cell]

## A move no candidate cell explains (see `_object_walk`): stopped where it
## starts, against the edge of `cell` nearest where it was going, so the
## step's slide can still follow that edge. OURS.
func _stop_in_cell(placed: PlacedObject, oi: int, cell: int, from: Vector2, to: Vector2) -> Dictionary:
	var slots: PackedInt32Array = placed.cell_edges[cell]
	var best_e := -1
	var best_d := INF
	for k in range(mini(CELL_EDGE_SLOTS, slots.size())):
		var e := slots[k]
		var q := Geometry2D.get_closest_point_to_segment(to, placed.edges[e * 2], placed.edges[e * 2 + 1])
		var dist := q.distance_squared_to(to)
		if dist < best_d:
			best_d = dist
			best_e = e
	if best_e < 0:
		return {"kind": "block", "point": from, "a": from, "b": from + Vector2(1.0, 0.0), "object": oi, "edge": -1}
	return {"kind": "block", "point": from, "a": placed.edges[best_e * 2], "b": placed.edges[best_e * 2 + 1], "object": oi, "edge": best_e}

## The cells of `placed` under (x, z), nearest `reference_y` first (with no
## reference height, highest first), and among cells at the same height the
## one the point lies most clearly inside first. OURS: the client carries
## its cell instead of inferring it (see `_object_walk`).
static func _cells_under(placed: PlacedObject, x: float, z: float, reference_y: float) -> Array[int]:
	var found: Array = []
	var i := 0
	while i + 2 <= placed.cells.size() - 1:
		var a: Vector3 = placed.vertices[placed.cells[i]]
		var b: Vector3 = placed.vertices[placed.cells[i + 1]]
		var c: Vector3 = placed.vertices[placed.cells[i + 2]]
		var h := _triangle_height(a, b, c, x, z)
		if not is_nan(h):
			var gap := -h if is_nan(reference_y) else absf(h - reference_y)
			found.append([snappedf(gap, 0.01), -_triangle_margin(a, b, c, x, z), i / 3])
		i += 3
	found.sort_custom(func(p: Array, q: Array) -> bool:
		if p[0] != q[0]:
			return p[0] < q[0]
		if p[1] != q[1]:
			return p[1] < q[1]
		return p[2] < q[2])
	var out: Array[int] = []
	for f in found:
		out.append(int(f[2]))
	return out

## Is `p` under cell `cell` of `placed` (within _triangle_height's tolerance)?
static func _in_cell(placed: PlacedObject, cell: int, p: Vector2) -> bool:
	if cell < 0 or cell * 3 + 2 >= placed.cells.size():
		return false
	return not is_nan(_triangle_height(placed.vertices[placed.cells[cell * 3]], placed.vertices[placed.cells[cell * 3 + 1]], placed.vertices[placed.cells[cell * 3 + 2]], p.x, p.y))

## The smallest barycentric coordinate of (x, z) in triangle (a, b, c) in
## plan view: positive inside, zero on an edge, negative outside.
static func _triangle_margin(a: Vector3, b: Vector3, c: Vector3, x: float, z: float) -> float:
	var v0x := c.x - a.x
	var v0z := c.z - a.z
	var v1x := b.x - a.x
	var v1z := b.z - a.z
	var den := v0x * v1z - v1x * v0z
	if absf(den) < 0.000001:
		return -INF
	var u := ((x - a.x) * v1z - v1x * (z - a.z)) / den
	var v := (v0x * (z - a.z) - (x - a.x) * v0z) / den
	return minf(minf(u, v), 1.0 - u - v)

static func _cell_centroid(placed: PlacedObject, cell: int) -> Vector2:
	var a: Vector3 = placed.vertices[placed.cells[cell * 3]]
	var b: Vector3 = placed.vertices[placed.cells[cell * 3 + 1]]
	var c: Vector3 = placed.vertices[placed.cells[cell * 3 + 2]]
	return Vector2((a.x + b.x + c.x) / 3.0, (a.z + b.z + c.z) / 3.0)

## What is left of a move after the push past an edge: nothing, when the
## edge was met at the very end of the move and the push overshot it. Without
## this a crossing that lands exactly on an edge steps back and forth over it
## until the sub-step budget runs out.
static func _onward(rest: Vector2, dir: Vector2) -> Vector2:
	return rest if rest.dot(dir) > 0.0 else Vector2.ZERO

## An object other than `except` with a walkable cell at (x, z) within
## SURFACE_REACH_UP of `y`, or ON_TERRAIN. The seam hand-off of `step_tracked`.
func _seam_object_at(x: float, z: float, y: float, except: int) -> int:
	var best := ON_TERRAIN
	var best_gap := INF
	for oi in objects_at(x, z):
		if oi == except:
			continue
		var placed: PlacedObject = objects[oi]
		var h := _surface_near(placed, x, z, y)
		if is_nan(h):
			continue
		var gap := absf(h - y)
		if gap <= SURFACE_REACH_UP and gap < best_gap:
			best_gap = gap
			best = oi
	return best

## The highest point of one placed object's own walkable surface at (x, z),
## or NAN where that object has no surface there.
static func surface_height_of(placed: PlacedObject, x: float, z: float) -> float:
	var best := NAN
	var i := 0
	while i + 2 <= placed.cells.size() - 1:
		var a: Vector3 = placed.vertices[placed.cells[i]]
		var b: Vector3 = placed.vertices[placed.cells[i + 1]]
		var c: Vector3 = placed.vertices[placed.cells[i + 2]]
		i += 3
		var h := _triangle_height(a, b, c, x, z)
		if is_nan(h):
			continue
		if is_nan(best) or h > best:
			best = h
	return best

## The height of the object's cell at (x, z) nearest to `reference_y` -- the
## floor a mover at that height is on, where an object stacks several -- or
## NAN where the object has no cell there.
static func _surface_near(placed: PlacedObject, x: float, z: float, reference_y: float) -> float:
	var best := NAN
	var i := 0
	while i + 2 <= placed.cells.size() - 1:
		var a: Vector3 = placed.vertices[placed.cells[i]]
		var b: Vector3 = placed.vertices[placed.cells[i + 1]]
		var c: Vector3 = placed.vertices[placed.cells[i + 2]]
		i += 3
		var h := _triangle_height(a, b, c, x, z)
		if is_nan(h):
			continue
		if is_nan(best) or absf(h - reference_y) < absf(best - reference_y):
			best = h
	return best

## The height along one of the object's edges at the 2D point `at` on it.
static func _edge_height_at(placed: PlacedObject, edge: int, at: Vector2) -> float:
	var a: Vector3 = placed.vertices[placed.edge_v0[edge]]
	var b: Vector3 = placed.vertices[placed.edge_v1[edge]]
	var a2 := Vector2(a.x, a.z)
	var b2 := Vector2(b.x, b.z)
	var span := a2.distance_to(b2)
	if span < 1.0e-6:
		return a.y
	var s := clampf(a2.distance_to(at) / span, 0.0, 1.0)
	return a.y + s * (b.y - a.y)

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

## Is `p` on the same side of the line through a and b as `inside`? A point
## on the line itself counts as inside, so a mover standing exactly on an
## edge is judged by the rule for the cell the edge belongs to.
static func _on_from_side(a: Vector2, b: Vector2, p: Vector2, inside: Vector2) -> bool:
	var dir := b - a
	var side_p := dir.cross(p - a)
	var side_in := dir.cross(inside - a)
	if side_p == 0.0:
		return true
	return (side_p > 0.0) == (side_in > 0.0)

## The crossing of the move with one edge, or null. A bounding check first,
## because an object's edge list is long and most of it is nowhere near.
static func _segment_hit(from: Vector2, to: Vector2, a: Vector2, b: Vector2) -> Variant:
	if maxf(a.x, b.x) < minf(from.x, to.x) or minf(a.x, b.x) > maxf(from.x, to.x):
		return null
	if maxf(a.y, b.y) < minf(from.y, to.y) or minf(a.y, b.y) > maxf(from.y, to.y):
		return null
	return Geometry2D.segment_intersects_segment(from, to, a, b)

## Index (into the flat pair array) of the segment the move crosses first, or
## -1 when it crosses none.
static func _first_crossing(segments: PackedVector2Array, from: Vector2, to: Vector2) -> int:
	var best := -1
	var best_d := INF
	var i := 0
	while i + 1 <= segments.size() - 1:
		var a: Vector2 = segments[i]
		var b: Vector2 = segments[i + 1]
		var hit: Variant = _segment_hit(from, to, a, b)
		if hit != null:
			var d: float = from.distance_squared_to(hit)
			if d < best_d:
				best_d = d
				best = i
		i += 2
	return best

static func _crosses_any(segments: PackedVector2Array, from: Vector2, to: Vector2) -> bool:
	return _first_crossing(segments, from, to) >= 0

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
