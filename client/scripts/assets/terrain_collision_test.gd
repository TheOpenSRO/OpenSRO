extends SceneTree

## TerrainCollision (round 567): the terrain's collision as a HeightMapShape3D
## over the region's height grid, held to the drawn mesh -- against synthetic
## MapmReader regions (never real game data). Run headless:
##   godot4 --headless --path client --script res://scripts/assets/terrain_collision_test.gd
##
## Three kinds of check:
## - EVERY VERTEX: each of the 97 x 97 vertex positions of
##   MapmTerrainBuilder.build_full_region_mesh (and of the textured path's base
##   surface) equals the heightmap sample the shape reads for it, placed the
##   way Godot 4.2.2 places it (GodotHeightMapShape3D::_get_point, mirrored in
##   _hm_point below) under TerrainCollision.shape_transform() -- exactly, on
##   the field height = r * 10 + c, where a transposed index is visible (the
##   sample for mesh row 1, column 2 must be 12, not 21), and on a region whose
##   block edges disagree (the later block must win, as the mesh's stitching
##   has it).
## - EVERY TRIANGLE: the two triangles 4.2.2 cuts each heightmap cell into
##   (`cull`: (x, z), (x + 1, z), (x, z + 1) and (x + 1, z), (x + 1, z + 1),
##   (x, z + 1)) are the mesh's own two for that quad. The layout the item's
##   first plan named -- map_data[r * 97 + c] under a (20, 1, 20) scale --
##   puts every vertex in place too but cuts every quad along the other
##   diagonal; the comparator is shown to catch it.
## - IN THE ENGINE: the heightfield and the trimesh it replaces, built from the
##   same non-planar region under a terrain group's own transform (scale.z = -1,
##   a placement offset), each on its own layer, probed in GodotPhysics:
##   vertical and slanted rays inside non-planar quads, a sphere swept down the
##   way the camera spring sweeps (cast_motion), and a capsule moved down the
##   way move_and_slide moves the player (move_and_collide's body_test_motion).
##   They must agree, and the rays must land on the drawn triangles. The
##   first plan's layout, built the same way, must NOT (its rays miss the drawn
##   triangles inside non-planar quads) -- the measurement that says the
##   diagonal matters. Then move_and_slide itself walks a capsule 2 s across
##   rolling ground on each. Differences are recorded, not hidden: an upward
##   vertical ray from under the ground hits the heightfield and not the
##   one-sided trimesh (see TerrainCollision's doc comment); and the one-sided
##   trimesh under the world's mirror is not touched by body_test_motion's
##   cast at all -- the unmirrored or two-sided trimesh is -- and the walk
##   sinks into it, where on the heightfield it stays on the ground.
## - THE GRID LINES (round 572): a vertical ray exactly on one of the
##   heightfield's grid lines often finds nothing (TerrainCollision's doc
##   comment has the reading of 4.2.2's source). A radius-2 grid of 25 regions
##   placed by TerrainCollision.place_group -- World3D's own placement -- at
##   the frame origin, over one world-continuous non-planar field, probed at
##   every one of each region's 9,409 vertices and at the centre's cell-edge
##   midpoints: the plain vertical ray (the NEGATIVE -- it must miss, or the
##   probe is not on the lines) against TerrainCollision.vertical_ray, which
##   must miss at none, and must land within RAY_GRID_EPSILON times the
##   steepest triangle of the drawn vertex height. The band the epsilon was
##   chosen from is re-measured (rays moved (d, d) off every vertex), and a
##   lone region -- its outer edges have no neighbour -- is probed too.
##
## TerrainCollision is reached through load(), so on a tree without it the
## suite FAILS rather than failing to parse.

var _failures := 0

const SIDE := 97 # 6 * (17 - 1) + 1, TerrainCollision.SIDE
const GW := 17 # MapmTerrainBuilder.GRID_WIDTH
const TILE := 20.0 # MapmTerrainBuilder.TILE_SIZE

var TC: GDScript = null

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _make_block(height_fn: Callable) -> MapmReader.Block:
	var block := MapmReader.Block.new()
	block.vertices.resize(GW * GW)
	for r in range(GW):
		for c in range(GW):
			var v := MapmReader.Vertex.new()
			v.height = height_fn.call(r, c)
			v.extra = PackedByteArray([0, 0, 0])
			block.vertices[r * GW + c] = v
	return block

func _make_region(block_fn: Callable) -> MapmReader.ParsedRegion:
	var region := MapmReader.ParsedRegion.new()
	region.version = "1000"
	for band_row in range(MapmReader.BLOCKS_PER_SIDE):
		for band_col in range(MapmReader.BLOCKS_PER_SIDE):
			region.blocks.append(block_fn.call(band_row, band_col))
	return region

## A region whose height at stitched grid (r, c) is `field.call(r, c)`.
func _field_region(field: Callable) -> MapmReader.ParsedRegion:
	return _make_region(func(band_row, band_col):
		return _make_block(func(r, c): return field.call(band_row * (GW - 1) + r, band_col * (GW - 1) + c)))

## The item's field: height = r * 10 + c. Planar, so it cannot tell the two
## diagonals apart by height -- the triangle check does that -- but every
## index mix-up shows in the value.
func _rc_region() -> MapmReader.ParsedRegion:
	return _field_region(func(r, c): return float(r * 10 + c))

## Block edges that disagree: each block adds its own index * 1000, so a
## shared edge vertex tells which block wrote it last.
func _seam_region() -> MapmReader.ParsedRegion:
	return _make_region(func(band_row, band_col):
		var bi: int = band_row * MapmReader.BLOCKS_PER_SIDE + band_col
		return _make_block(func(r, c): return float(bi * 1000 + r * 17 + c)))

## Hills: non-planar quads everywhere (the two diagonals differ by up to ~20
## units at a quad's centre) and slopes up to ~3 units a unit.
func _hill_region() -> MapmReader.ParsedRegion:
	return _field_region(func(r, c):
		return 40.0 * sin(float(r) * 0.9) * cos(float(c) * 0.7) + 3.0 * float((r * 7 + c * 13) % 5))

## GodotHeightMapShape3D::_get_point in Godot 4.2.2
## (servers/physics_3d/godot_shape_3d.h): x - 0.5 * (width - 1),
## heights[z * width + x], z - 0.5 * (depth - 1).
func _hm_point(heights: PackedFloat32Array, x: int, z: int) -> Vector3:
	return Vector3(float(x) - 0.5 * float(SIDE - 1), heights[z * SIDE + x], float(z) - 0.5 * float(SIDE - 1))

## The first plan's layout, for the controls: row for row, no flip.
func _plan_heights(region: MapmReader.ParsedRegion) -> PackedFloat32Array:
	var flipped: PackedFloat32Array = TC.heights_from_region(region)
	var heights := PackedFloat32Array()
	heights.resize(SIDE * SIDE)
	for z in range(SIDE):
		for x in range(SIDE):
			heights[z * SIDE + x] = flipped[(SIDE - 1 - z) * SIDE + x]
	return heights

func _plan_transform() -> Transform3D:
	return Transform3D(Basis(Vector3(TILE, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, TILE)), Vector3(960, 0, 960))

## Mesh vertex (r, c) against the shape sample it maps to: the count of the
## 97 x 97 that differ, for `heights` laid out with shape row `row_of.call(r)`.
func _vertex_mismatches(positions: PackedVector3Array, heights: PackedFloat32Array, xf: Transform3D, row_of: Callable) -> int:
	var bad := 0
	for r in range(SIDE):
		for c in range(SIDE):
			if xf * _hm_point(heights, c, row_of.call(r)) != positions[r * SIDE + c]:
				bad += 1
	return bad

## A triangle as a sortable key: its three corners in (x, z, y) order.
func _tri_key(a: Vector3, b: Vector3, c: Vector3) -> String:
	var pts := [a, b, c]
	pts.sort_custom(func(p, q): return p.x < q.x or (p.x == q.x and p.z < q.z))
	return "%s|%s|%s" % [str(pts[0]), str(pts[1]), str(pts[2])]

## How many quads' triangle pairs differ between the mesh (its index order)
## and 4.2.2's heightmap cells (`cull`'s order) under `xf`.
func _triangle_mismatches(arrays: Array, heights: PackedFloat32Array, xf: Transform3D) -> int:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var mesh_tris := {}
	var i := 0
	while i + 2 < indices.size():
		var key := _tri_key(positions[indices[i]], positions[indices[i + 1]], positions[indices[i + 2]])
		mesh_tris[key] = true
		i += 3
	var bad := 0
	for z in range(SIDE - 1):
		for x in range(SIDE - 1):
			var p00 := xf * _hm_point(heights, x, z)
			var p10 := xf * _hm_point(heights, x + 1, z)
			var p01 := xf * _hm_point(heights, x, z + 1)
			var p11 := xf * _hm_point(heights, x + 1, z + 1)
			if not mesh_tris.has(_tri_key(p00, p10, p01)) or not mesh_tris.has(_tri_key(p10, p11, p01)):
				bad += 1
	return bad

func _test_layout() -> void:
	var region := _rc_region()
	var heights: PackedFloat32Array = TC.heights_from_region(region)
	_check(heights.size() == SIDE * SIDE, "heights_from_region gives 97 x 97 heights (got %d)" % heights.size())
	if heights.size() != SIDE * SIDE:
		return
	# The plan's NEGATIVE: the sample the shape reads for mesh row 1, column 2
	# is 1 * 10 + 2 = 12; a transposed layout would read 21.
	_check(heights[(SIDE - 1 - 1) * SIDE + 2] == 12.0,
		"mesh row 1, column 2 is sampled as 12, not 21 (got %s)" % heights[(SIDE - 1 - 1) * SIDE + 2])
	_check(heights[(SIDE - 1) * SIDE + 0] == 0.0 and heights[0 * SIDE + 96] == 1056.0,
		"mesh (0, 0) is shape row 96 and mesh (96, 96) = 1056 is shape row 0, column 96")
	var xf: Transform3D = TC.shape_transform()
	_check(xf == Transform3D(Basis(Vector3(20, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -20)), Vector3(960, 0, 960)),
		"shape_transform: x 20, y 1, z -20 (the reversed rows), origin (960, 0, 960) (got %s)" % str(xf))
	var flipped_row := func(r): return SIDE - 1 - r

	var mesh := MapmTerrainBuilder.build_full_region_mesh(region)
	var arrays := mesh.surface_get_arrays(0)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	_check(positions.size() == SIDE * SIDE, "the mesh has 97 x 97 vertices")
	_check(_vertex_mismatches(positions, heights, xf, flipped_row) == 0,
		"every one of build_full_region_mesh's 97 x 97 vertices is the shape's sample, placed exactly")
	var textured := MapmTerrainBuilder.build_full_region_surfaces_textured(region, {})
	_check(_vertex_mismatches(textured[0]["arrays"][Mesh.ARRAY_VERTEX], heights, xf, flipped_row) == 0,
		"and so is every vertex of the textured path's base surface")
	# Controls: the transposed grid and the plan's row-for-row layout.
	var transposed := PackedFloat32Array()
	transposed.resize(SIDE * SIDE)
	for z in range(SIDE):
		for x in range(SIDE):
			transposed[z * SIDE + x] = heights[x * SIDE + z]
	_check(_vertex_mismatches(positions, transposed, xf, flipped_row) > 0,
		"control: a transposed grid is caught by the vertex check")
	var plan := _plan_heights(region)
	_check(_vertex_mismatches(positions, plan, _plan_transform(), func(r): return r) == 0,
		"control: the first plan's layout (row for row, scale (20, 1, 20)) also places every vertex")

	var seam := _seam_region()
	var seam_positions: PackedVector3Array = MapmTerrainBuilder.build_full_region_mesh(seam).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var seam_heights: PackedFloat32Array = TC.heights_from_region(seam)
	_check(_vertex_mismatches(seam_positions, seam_heights, xf, flipped_row) == 0,
		"block edges that disagree: the heightfield takes the mesh's value at every shared vertex (the later block)")
	# Mesh (16, 16) is shared by blocks 0, 1, 6 and 7; block 7 (the last in
	# nested order) wins, at its own local (0, 0): 7000.
	_check(seam_heights[(SIDE - 1 - 16) * SIDE + 16] == 7000.0,
		"the corner four blocks share takes the last block's own vertex (got %s)" % seam_heights[(SIDE - 1 - 16) * SIDE + 16])

	# The triangles: the mesh's, the heightfield's, the plan's.
	_check(_triangle_mismatches(arrays, heights, xf) == 0,
		"every heightmap cell's two triangles (4.2.2's cull order) are the mesh's own two for that quad")
	var plan_bad := _triangle_mismatches(arrays, plan, _plan_transform())
	_check(plan_bad == (SIDE - 1) * (SIDE - 1),
		"control: the first plan's layout cuts all %d quads along the other diagonal (got %d)" % [(SIDE - 1) * (SIDE - 1), plan_bad])

	_check((TC.heights_from_region(MapmReader.ParsedRegion.new()) as PackedFloat32Array).is_empty() and TC.heights_from_region(null).is_empty(),
		"a region without a real 6x6 block grid gives no heights")
	_check(TC.make_shape(PackedFloat32Array([1.0, 2.0])) == null, "make_shape refuses a grid of the wrong size")
	var shape: HeightMapShape3D = TC.make_shape(heights)
	_check(shape != null and shape.map_width == SIDE and shape.map_depth == SIDE and shape.map_data == heights,
		"make_shape: a 97 x 97 HeightMapShape3D holding the grid")

	# mesh_height_at: the drawn triangle's height, on the hills.
	var hills := _hill_region()
	var hh: PackedFloat32Array = TC.heights_from_region(hills)
	var hp: PackedVector3Array = MapmTerrainBuilder.build_full_region_mesh(hills).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var worst := 0.0
	for r in range(0, SIDE - 1, 7):
		for c in range(0, SIDE - 1, 5):
			for uv in [Vector2(0.45, 0.55), Vector2(0.8, 0.1), Vector2(0.0, 0.0)]:
				var p00 := hp[r * SIDE + c]
				var p10 := hp[r * SIDE + c + 1]
				var p01 := hp[(r + 1) * SIDE + c]
				var p11 := hp[(r + 1) * SIDE + c + 1]
				# The mesh's triangle under (u, v): [i00, i10, i11] if u >= v, else [i00, i11, i01].
				var want: float
				if uv.x >= uv.y:
					want = p00.y + uv.x * (p10.y - p00.y) + uv.y * (p11.y - p10.y)
				else:
					want = p00.y + uv.y * (p01.y - p00.y) + uv.x * (p11.y - p01.y)
				var got: float = TC.mesh_height_at(hh, (c + uv.x) * TILE, (r + uv.y) * TILE)
				worst = maxf(worst, absf(got - want))
	_check(worst < 0.0001, "mesh_height_at is the drawn triangle's height (worst %.6f)" % worst)
	_check(is_nan(TC.mesh_height_at(hh, -1.0, 5.0)) and is_nan(TC.mesh_height_at(hh, 5.0, 1921.0)),
		"mesh_height_at is NAN off the grid")

## A terrain group as World3D._terrain_commit places one -- position
## (placement.x, placement.y, -placement.z), scale.z = -1 (`mirrored`) -- with
## one StaticBody3D on `layer_bit` holding `cs`.
func _terrain_body(placement: Vector3, layer_bit: int, cs: CollisionShape3D, mirrored: bool = true) -> Node3D:
	var group := Node3D.new()
	group.position = Vector3(placement.x, placement.y, -placement.z)
	if mirrored:
		group.scale.z = -1.0
	root.add_child(group)
	var body := StaticBody3D.new()
	body.collision_layer = layer_bit
	body.collision_mask = 0
	body.add_child(cs)
	group.add_child(body)
	return group

## The trimesh World3D built until round 567 (and still builds under
## OPENSRO_TERRAIN_TRIMESH=1): MapmTerrainBuilder.surface_faces of the
## region's surface in a ConcavePolygonShape3D, one-sided unless `two_sided`.
func _trimesh_shape(region: MapmReader.ParsedRegion, two_sided: bool = false) -> CollisionShape3D:
	var tri := ConcavePolygonShape3D.new()
	tri.set_faces(MapmTerrainBuilder.surface_faces([{"arrays": MapmTerrainBuilder.build_full_region_arrays(region)}]))
	tri.backface_collision = two_sided
	var cs := CollisionShape3D.new()
	cs.shape = tri
	return cs

## PhysicsServer3D.body_test_motion of `body` from `from` by `motion`: the
## query CharacterBody3D.move_and_slide / move_and_collide make. The travel
## before contact, or -1.0 for none.
func _body_travel(body: CharacterBody3D, from: Transform3D, motion: Vector3) -> float:
	var params := PhysicsTestMotionParameters3D.new()
	params.from = from
	params.motion = motion
	var result := PhysicsTestMotionResult3D.new()
	if not PhysicsServer3D.body_test_motion(body.get_rid(), params, result):
		return -1.0
	return result.get_travel().length()

## The engine half: the heightfield, the trimesh it replaces and the first
## plan's layout, under a terrain group's transform, probed in GodotPhysics.
func _test_physics() -> void:
	var region := _hill_region()
	var heights: PackedFloat32Array = TC.heights_from_region(region)
	var placement := Vector3(-960.0, -12.5, -960.0) + Vector3(1920.0, 0.0, -3840.0)
	var hf := CollisionShape3D.new()
	hf.shape = TC.make_shape(heights)
	hf.transform = TC.shape_transform()
	var plan := CollisionShape3D.new()
	plan.shape = TC.make_shape(_plan_heights(region))
	plan.transform = _plan_transform()
	# Layer 1: the trimesh; 2: the heightfield; 3: the plan's layout; 4 and
	# 5: the trimesh unmirrored, and two-sided under the mirror (the evidence
	# for the body-motion record below).
	var groups := [
		_terrain_body(placement, 1, _trimesh_shape(region)),
		_terrain_body(placement, 2, hf),
		_terrain_body(placement, 4, plan),
		_terrain_body(placement, 8, _trimesh_shape(region), false),
		_terrain_body(placement, 16, _trimesh_shape(region, true)),
	]
	# The player's capsule (World3D.tscn: radius 3.186667, height 14.34, its
	# CollisionShape3D 7.17 up so the body's origin is its feet), one body per
	# terrain layer it may touch.
	var capsule := CapsuleShape3D.new()
	capsule.radius = 3.186667
	capsule.height = 14.34
	var bodies := {}
	for mask in [1, 2, 8, 16]:
		var cb := CharacterBody3D.new()
		cb.collision_layer = 0
		cb.collision_mask = mask
		var ccs := CollisionShape3D.new()
		ccs.shape = capsule
		ccs.position = Vector3(0, 7.17, 0)
		cb.add_child(ccs)
		root.add_child(cb)
		bodies[mask] = cb
	await physics_frame
	await physics_frame
	var g: Node3D = groups[1]
	var basis_world: Basis = (g.global_transform * (TC.shape_transform() as Transform3D)).basis
	_check(basis_world.is_equal_approx(Basis.from_scale(Vector3(20, 1, 20))),
		"the heightfield's global basis is a plain positive scale (20, 1, 20): the reversed rows cancel the group's mirror (got %s)" % str(basis_world))

	var space := root.get_world_3d().direct_space_state
	var ray_hit := func(mask: int, from_local: Vector3, to_local: Vector3) -> Dictionary:
		var q := PhysicsRayQueryParameters3D.create(g.to_global(from_local), g.to_global(to_local))
		q.collision_mask = mask
		return space.intersect_ray(q)
	var n := 0
	var vertical_worst := 0.0 # trimesh vs heightfield
	var drawn_worst := 0.0 # heightfield vs the drawn triangle
	var plan_worst := 0.0 # the plan's layout vs the drawn triangle
	var misses := 0
	var slant_worst := 0.0 # trimesh vs heightfield, along the ray
	var slant_drawn_worst := [0.0, 0.0] # each hit's height off the drawn surface
	var slant_n := 0
	var slant := Vector3(-1.0, -1.0, -0.6).normalized()
	for r in range(1, SIDE - 2, 6):
		for c in range(2, SIDE - 2, 7):
			for uv in [Vector2(0.45, 0.55), Vector2(0.3, 0.2), Vector2(0.7, 0.9)]:
				var lx: float = (c + uv.x) * TILE
				var lz: float = (r + uv.y) * TILE
				var drawn: float = TC.mesh_height_at(heights, lx, lz)
				var a: Dictionary = ray_hit.call(1, Vector3(lx, drawn + 300, lz), Vector3(lx, drawn - 300, lz))
				var b: Dictionary = ray_hit.call(2, Vector3(lx, drawn + 300, lz), Vector3(lx, drawn - 300, lz))
				var p: Dictionary = ray_hit.call(4, Vector3(lx, drawn + 300, lz), Vector3(lx, drawn - 300, lz))
				n += 1
				if a.is_empty() or b.is_empty() or p.is_empty():
					misses += 1
					continue
				var yb := g.to_local(b.position).y
				vertical_worst = maxf(vertical_worst, absf(g.to_local(a.position).y - yb))
				drawn_worst = maxf(drawn_worst, absf(yb - drawn))
				plan_worst = maxf(plan_worst, absf(g.to_local(p.position).y - drawn))
				# Slanted, through the drawn point: the same first hit.
				var sa: Dictionary = ray_hit.call(1, Vector3(lx, drawn, lz) - slant * 400.0, Vector3(lx, drawn, lz) + slant * 400.0)
				var sb: Dictionary = ray_hit.call(2, Vector3(lx, drawn, lz) - slant * 400.0, Vector3(lx, drawn, lz) + slant * 400.0)
				if sa.is_empty() != sb.is_empty():
					misses += 1
				elif not sa.is_empty():
					slant_n += 1
					slant_worst = maxf(slant_worst, (sa.position as Vector3).distance_to(sb.position))
					var hits := [sa, sb]
					for k in range(2):
						var at := g.to_local(hits[k].position)
						slant_drawn_worst[k] = maxf(slant_drawn_worst[k], absf(at.y - TC.mesh_height_at(heights, at.x, at.z)))
	_check(misses == 0, "every vertical and slanted ray hits both shapes or neither (%d of %d columns missed)" % [misses, n])
	_check(vertical_worst < 0.01, "vertical rays: the heightfield's hit is the trimesh's (worst %.5f over %d columns)" % [vertical_worst, n])
	_check(drawn_worst < 0.01, "vertical rays: the heightfield's hit is on the drawn triangle (worst %.5f)" % drawn_worst)
	# Along a 45-degree ray over 400 units a float's error in the hit's
	# height becomes a larger one along the ray where the slope is steep:
	# both hits are held to the drawn surface, and to each other within 0.1.
	_check(slant_n * 2 > n and slant_drawn_worst[0] < 0.01 and slant_drawn_worst[1] < 0.01 and slant_worst < 0.1,
		"slanted rays: both shapes' first hits lie on the drawn surface (trimesh %.5f, heightfield %.5f off) and within %.4f of each other, over %d" % [
			slant_drawn_worst[0], slant_drawn_worst[1], slant_worst, slant_n])
	_check(plan_worst > 0.5,
		"control, in the engine: the first plan's layout misses the drawn triangle inside non-planar quads by up to %.2f" % plan_worst)

	# The camera spring's query (SpringArm3D sweeps its shape with
	# cast_motion): World3D.tscn's arm sphere, radius 3, swept down 60 from 30
	# above the drawn column; and the player's capsule swept the same way.
	# And move_and_slide's query, body_test_motion, of the capsule body.
	var sphere := SphereShape3D.new()
	sphere.radius = 3.0
	var sweep_worst := 0.0
	var capsule_worst := 0.0
	var body_worst := 0.0
	var probes := 0
	var sweep_misses := 0
	var trimesh_body_hits := 0
	var variant_body_hits := [0, 0] # unmirrored, two-sided
	for r in range(3, SIDE - 3, 9):
		for c in range(4, SIDE - 3, 11):
			var lx: float = (c + 0.45) * TILE
			var lz: float = (r + 0.55) * TILE
			var drawn: float = TC.mesh_height_at(heights, lx, lz)
			var at := Transform3D(Basis(), g.to_global(Vector3(lx, drawn + 30.0, lz)))
			var casts := {}
			for shape_kind in ["sphere", "capsule"]:
				for mask in [1, 2]:
					var params := PhysicsShapeQueryParameters3D.new()
					params.shape = sphere if shape_kind == "sphere" else capsule
					params.collision_mask = mask
					params.transform = at if shape_kind == "sphere" else at.translated(Vector3(0, 7.17, 0))
					params.motion = Vector3(0, -60, 0)
					var f := space.cast_motion(params)
					casts["%s%d" % [shape_kind, mask]] = 60.0 * f[0] if f.size() == 2 and f[0] < 1.0 else -1.0
			var body_hf := _body_travel(bodies[2], at, Vector3(0, -60, 0))
			probes += 1
			if casts["sphere1"] < 0.0 or casts["sphere2"] < 0.0 or casts["capsule1"] < 0.0 or casts["capsule2"] < 0.0 or body_hf < 0.0:
				sweep_misses += 1
				continue
			sweep_worst = maxf(sweep_worst, absf(casts["sphere1"] - casts["sphere2"]))
			capsule_worst = maxf(capsule_worst, absf(casts["capsule1"] - casts["capsule2"]))
			# The heightfield stops the player's body where the trimesh's
			# geometry stops the same capsule swept.
			body_worst = maxf(body_worst, absf(body_hf - casts["capsule1"]))
			if _body_travel(bodies[1], at, Vector3(0, -60, 0)) >= 0.0:
				trimesh_body_hits += 1
			var vg0: Node3D = groups[3]
			var at0 := Transform3D(Basis(), vg0.to_global(Vector3(lx, drawn + 30.0, lz)))
			if _body_travel(bodies[8], at0, Vector3(0, -60, 0)) >= 0.0:
				variant_body_hits[0] += 1
			if _body_travel(bodies[16], at, Vector3(0, -60, 0)) >= 0.0:
				variant_body_hits[1] += 1
	_check(sweep_misses == 0, "every sweep touches both shapes and the capsule body touches the heightfield (%d of %d missed)" % [sweep_misses, probes])
	# cast_motion and body_test_motion bisect the motion eight times (4.2.2,
	# godot_space_3d.cpp): about 1/256 of the 60-unit sweep, 0.23; two steps.
	_check(sweep_worst <= 0.5,
		"the camera spring's sphere sweep stops within 0.5 of the trimesh's on the heightfield (worst %.3f over %d)" % [sweep_worst, probes])
	_check(capsule_worst <= 0.5,
		"the player's capsule, swept, stops within 0.5 of the trimesh's on the heightfield (worst %.3f)" % capsule_worst)
	_check(body_worst <= 0.5,
		"move_and_slide's body_test_motion of the player's body stops on the heightfield within 0.5 of where the trimesh's geometry stops the capsule (worst %.3f)" % body_worst)
	# RECORDED, measured here: the one-sided trimesh under the world's mirror
	# (scale.z = -1) is not touched by body_test_motion at all -- the same
	# trimesh unmirrored, or two-sided under the mirror, is -- while rays and
	# cast_motion find it. So until round 567 the player's move_and_slide
	# fallback (World3D._physics_process, when no walkable graph covers the
	# player) passed through the terrain; the heightfield stops it.
	_check(trimesh_body_hits == 0 and variant_body_hits[0] == probes - sweep_misses and variant_body_hits[1] == probes - sweep_misses,
		"recorded: body_test_motion touches the mirrored one-sided trimesh at %d of %d columns, the unmirrored one at %d, the two-sided one at %d" % [
			trimesh_body_hits, probes - sweep_misses, variant_body_hits[0], variant_body_hits[1]])

	# The recorded ray difference: from under the ground, straight up.
	var lx2 := 40.45 * TILE
	var lz2 := 40.55 * TILE
	var d2: float = TC.mesh_height_at(heights, lx2, lz2)
	var up_tri: Dictionary = ray_hit.call(1, Vector3(lx2, d2 - 50, lz2), Vector3(lx2, d2 + 50, lz2))
	var up_hf: Dictionary = ray_hit.call(2, Vector3(lx2, d2 - 50, lz2), Vector3(lx2, d2 + 50, lz2))
	_check(up_tri.is_empty() and not up_hf.is_empty(),
		"recorded: an upward vertical ray from under the ground hits the heightfield (two-sided in one cell) and not the one-sided trimesh (trimesh %s, heightfield %s)" % [
			"miss" if up_tri.is_empty() else "hit", "miss" if up_hf.is_empty() else "hit"])
	print("info: vertical rays over %d columns: trimesh vs heightfield worst %.5f, heightfield vs drawn %.5f, the plan's layout vs drawn %.3f; slanted %.4f apart; sphere %.3f, capsule %.3f, body %.3f over %d" % [
		n, vertical_worst, drawn_worst, plan_worst, slant_worst, sweep_worst, capsule_worst, body_worst, probes])

	for node in groups + bodies.values():
		(node as Node).queue_free()
	await _test_walk()

## move_and_slide itself, the way World3D._physics_process's fallback drives
## the player when no walkable graph covers them: the capsule walks 2 s across
## rolling non-planar ground under gravity (9.8, a stand-in for the test; the
## game's own GRAVITY is not what is being tested), once on the heightfield
## and once on the pre-567 trimesh. The sixty-third round's caution
## (docs/WORLD_ISSUES.md: a two-sided single-thickness surface pinned a
## capsule at a ramp's seam) is why this is measured and not assumed: the
## heightfield's faces are two-sided to shape queries.
func _test_walk() -> void:
	var region := _field_region(func(r, c):
		return 8.0 * sin(float(r) * 0.5) * cos(float(c) * 0.4) + 0.6 * float((r * 3 + c * 5) % 4))
	var heights: PackedFloat32Array = TC.heights_from_region(region)
	var placement := Vector3(-960.0, -12.5, -960.0) + Vector3(1920.0, 0.0, -3840.0)
	var hf := CollisionShape3D.new()
	hf.shape = TC.make_shape(heights)
	hf.transform = TC.shape_transform()
	var groups := [_terrain_body(placement, 32, hf), _terrain_body(placement, 64, _trimesh_shape(region))]
	var g: Node3D = groups[0]
	var capsule := CapsuleShape3D.new()
	capsule.radius = 3.186667
	capsule.height = 14.34
	var walkers := []
	var start_local := Vector3(300.0, 0.0, 300.0)
	start_local.y = TC.mesh_height_at(heights, start_local.x, start_local.z) + 1.0
	for mask in [32, 64]:
		var cb := CharacterBody3D.new()
		cb.collision_layer = 0
		cb.collision_mask = mask
		var ccs := CollisionShape3D.new()
		ccs.shape = capsule
		ccs.position = Vector3(0, 7.17, 0)
		cb.add_child(ccs)
		root.add_child(cb)
		cb.global_position = g.to_global(start_local)
		walkers.append(cb)
	await physics_frame
	await physics_frame
	var speed := 40.0
	var dir := Vector3(0.8, 0.0, 0.6)
	var lowest := [INF, INF] # feet below the drawn surface, worst over the walk
	var steps := 120
	for step in range(steps):
		await physics_frame
		for i in range(2):
			var cb: CharacterBody3D = walkers[i]
			var dt := root.get_physics_process_delta_time()
			cb.velocity.x = dir.x * speed
			cb.velocity.z = dir.z * speed
			cb.velocity.y = 0.0 if cb.is_on_floor() else cb.velocity.y - 9.8 * dt
			cb.move_and_slide()
			var feet := g.to_local(cb.global_position)
			var drawn: float = TC.mesh_height_at(heights, feet.x, feet.z)
			if not is_nan(drawn):
				lowest[i] = minf(lowest[i], feet.y - drawn)
	var walked := Vector2(g.to_local(walkers[0].global_position).x - start_local.x, g.to_local(walkers[0].global_position).z - start_local.z).length()
	var expected := speed * float(steps) / float(Engine.physics_ticks_per_second)
	var feet0 := g.to_local(walkers[0].global_position)
	var end_gap: float = feet0.y - TC.mesh_height_at(heights, feet0.x, feet0.z)
	_check(walked > expected * 0.9 and lowest[0] > -0.5 and absf(end_gap) < 1.0,
		"move_and_slide walks the capsule across the heightfield: %.1f of %.1f units, its feet at least %.2f from the drawn ground (negative: below it), ending %.2f above it" % [
			walked, expected, lowest[0], end_gap])
	# Measured, and recorded as measured: the trimesh does not fail as a
	# clean fall -- its body_test_motion cast finds nothing (above) but the
	# walk sinks into the ground and is caught part-way (3.3 below it at worst
	# on the box, 2026-09-25) -- so the check is only that it goes a unit or
	# more below the drawn ground, where the heightfield's never does.
	var feet1 := g.to_local(walkers[1].global_position)
	_check(lowest[1] < -1.0,
		"recorded: on the pre-567 trimesh the same walk sinks below the drawn ground (%.2f below it at worst; ends %.2f from it)" % [
			-lowest[1], feet1.y - TC.mesh_height_at(heights, feet1.x, feet1.z)])
	for node in groups + walkers:
		(node as Node).queue_free()

## One world-continuous field for the grid probe: the height at world
## vertex (gi, gk) -- world (20 gi, 20 gk) -- so regions that share an edge
## share its heights, as real neighbours do (World3D._cell_offset's
## doc comment: 0.000000 mean difference on real edges). Non-planar, with
## slopes of a few units a unit.
func _world_field(gi: int, gk: int) -> float:
	return 40.0 * sin(float(gi) * 0.9) * cos(float(gk) * 0.7) + 3.0 * float(posmod(gi * 7 + gk * 13, 5))

## The group-local region whose group place_group puts at `offset`, heights
## from _world_field at each vertex's world position: mesh vertex (r, c) is
## at group-local (20 c, 20 r) and its world position is read back through
## the group itself (in the tree), so the probe does not restate the
## placement.
func _grid_region_heights(g: Node3D) -> PackedFloat32Array:
	var region := _field_region(func(r, c):
		var w := g.to_global(Vector3(float(c) * TILE, 0.0, float(r) * TILE))
		return _world_field(roundi(w.x / TILE), roundi(w.z / TILE)))
	return TC.heights_from_region(region)

## The steepest drawn triangle of a height grid, as |dh/dx| + |dh/dz| (the
## mesh's split; World3D._qa_terrain_slope_report reads real regions the same
## way): what bounds how far a height read RAY_GRID_EPSILON off on each axis
## can be from the exact column's.
func _steepest(heights: PackedFloat32Array) -> float:
	var steepest := 0.0
	for r in range(SIDE - 1):
		for c in range(SIDE - 1):
			var h00 := heights[(SIDE - 1 - r) * SIDE + c]
			var h10 := heights[(SIDE - 1 - r) * SIDE + c + 1]
			var h01 := heights[(SIDE - 2 - r) * SIDE + c]
			var h11 := heights[(SIDE - 2 - r) * SIDE + c + 1]
			steepest = maxf(steepest, maxf(absf(h10 - h00) + absf(h11 - h10), absf(h11 - h01) + absf(h01 - h00)) / TILE)
	return steepest

## A terrain group at `offset` (whole region spans from the frame origin),
## placed by TerrainCollision.place_group, its heightfield on `layer`.
func _grid_region(offset: Vector3, layer: int) -> Array:
	var g := Node3D.new()
	TC.place_group(g, offset, 12.5)
	root.add_child(g)
	var heights := _grid_region_heights(g)
	var body := StaticBody3D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.shape = TC.make_shape(heights)
	cs.transform = TC.shape_transform()
	body.add_child(cs)
	g.add_child(body)
	return [g, heights]

func _plain_hit(space: PhysicsDirectSpaceState3D, x: float, z: float, mask: int) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, 1000.0, z), Vector3(x, -1000.0, z))
	q.collision_mask = mask
	return space.intersect_ray(q)

func _test_grid_lines() -> void:
	var started := Time.get_ticks_msec()
	var eps: float = TC.RAY_GRID_EPSILON
	# ray_columns, by value.
	var cols: PackedFloat64Array = TC.ray_columns(123.4)
	_check(cols.size() == 1 and cols[0] == 123.4, "a column off every grid line is fired as it is (got %s)" % str(cols))
	cols = TC.ray_columns(340.0)
	_check(cols.size() == 2 and cols[0] == 340.0 + eps and cols[1] == 340.0 - eps,
		"a column on a grid line (340, a multiple of 20) is fired %.2f off it, the + side first, then the - side (got %s)" % [eps, str(cols)])
	cols = TC.ray_columns(339.996)
	_check(cols.size() == 2 and cols[0] == 340.0 - eps and cols[1] == 340.0 + eps,
		"a column just under a line is moved to the - side first (got %s)" % str(cols))
	cols = TC.ray_columns(-500.0)
	_check(cols.size() == 2 and cols[0] == -500.0 + eps and cols[1] == -500.0 - eps,
		"negative coordinates too (got %s)" % str(cols))
	cols = TC.ray_columns(340.0 + 2.0 * eps)
	_check(cols.size() == 1, "a column twice the epsilon off a line is left alone (got %s)" % str(cols))

	# The radius-2 grid at the frame origin, on layer 256 (bit 9), which no
	# other probe in this suite uses.
	var layer := 256
	var regions := {}
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			regions[Vector2i(dx, dz)] = _grid_region(Vector3(float(dx) * 1920.0, 0.0, float(dz) * 1920.0), layer)
	await physics_frame
	await physics_frame
	var space := root.get_world_3d().direct_space_state
	var steepest := 0.0
	for key in regions:
		steepest = maxf(steepest, _steepest(regions[key][1]))
	var off_lattice := 0
	var plain_total := 0
	var plain_regions := 0
	var helper_total := 0
	var worst := 0.0
	var centre_plain := 0
	var centre_helper := 0
	var per_region := PackedStringArray()
	for key in regions:
		var g: Node3D = regions[key][0]
		var heights: PackedFloat32Array = regions[key][1]
		var plain := 0
		var helper := 0
		for j in range(SIDE):
			for i in range(SIDE):
				var w := g.to_global(Vector3(float(i) * TILE, 0.0, float(j) * TILE))
				# place_group puts every vertex on world multiples of TILE_SIZE,
				# the lines ray_columns steps off.
				if fmod(absf(w.x), TILE) != 0.0 or fmod(absf(w.z), TILE) != 0.0:
					off_lattice += 1
				if _plain_hit(space, w.x, w.z, layer).is_empty():
					plain += 1
				var hit: Dictionary = TC.vertical_ray(space, w.x, w.z, 1000.0, -1000.0, layer)
				if hit.is_empty():
					helper += 1
				else:
					var drawn := g.to_global(Vector3(float(i) * TILE, heights[(SIDE - 1 - j) * SIDE + i], float(j) * TILE)).y
					worst = maxf(worst, absf((hit.position as Vector3).y - drawn))
		plain_total += plain
		helper_total += helper
		if plain > 0:
			plain_regions += 1
			per_region.append("%s %d" % [str(key), plain])
		if key == Vector2i(0, 0):
			centre_plain = plain
			centre_helper = helper
	_check(off_lattice == 0, "place_group puts every vertex of the 25 regions on world multiples of %.0f, the lines ray_columns knows (%d off)" % [TILE, off_lattice])
	# The NEGATIVE: the probe is on the lines -- the plain vertical ray misses.
	_check(centre_plain > 0,
		"NEGATIVE: at the frame origin's region the plain vertical ray misses at %d of its 9,409 vertices" % centre_plain)
	_check(centre_helper == 0,
		"TerrainCollision.vertical_ray misses at none of the centre region's 9,409 vertices (missed %d)" % centre_helper)
	_check(helper_total == 0,
		"nor at any of the 25 regions' 235,225 (missed %d; the plain ray %d, in %d regions: %s)" % [
			helper_total, plain_total, plain_regions, ", ".join(per_region)])
	_check(worst <= eps * steepest + 0.001,
		"each hit is within the epsilon times the steepest triangle (%.3f x %.3f = %.4f) of the drawn vertex height (worst %.4f)" % [
			eps, steepest, eps * steepest, worst])

	# The centre's cell-edge midpoints: on one grid line, halfway along a cell.
	var g0: Node3D = regions[Vector2i(0, 0)][0]
	var edge_plain := [0, 0]
	var edge_helper := [0, 0]
	for j in range(SIDE):
		for i in range(SIDE):
			for k in range(2):
				if (k == 0 and i == SIDE - 1) or (k == 1 and j == SIDE - 1):
					continue
				var local := Vector3((float(i) + (0.5 if k == 0 else 0.0)) * TILE, 0.0, (float(j) + (0.5 if k == 1 else 0.0)) * TILE)
				var w := g0.to_global(local)
				if _plain_hit(space, w.x, w.z, layer).is_empty():
					edge_plain[k] += 1
				if (TC.vertical_ray(space, w.x, w.z, 1000.0, -1000.0, layer) as Dictionary).is_empty():
					edge_helper[k] += 1
	_check(edge_helper[0] == 0 and edge_helper[1] == 0,
		"the centre's 9,312 + 9,312 cell-edge midpoints: the helper misses none (%d, %d); the plain ray %d on lines of constant z, %d on lines of constant x" % [
			edge_helper[0], edge_helper[1], edge_plain[0], edge_plain[1]])

	# The band RAY_GRID_EPSILON was chosen from: every vertex of the 25
	# regions moved (d, d) into its own cell (towards its region's interior on
	# the regions' last rows and columns, which have no cell beyond them in
	# that region), plain rays.
	var band := {}
	for d in [0.00001, 0.0001, 0.001, eps]:
		var missed := 0
		for key in regions:
			var g: Node3D = regions[key][0]
			for j in range(SIDE):
				for i in range(SIDE):
					var local := Vector3(float(i) * TILE + (d if i < SIDE - 1 else -d), 0.0, float(j) * TILE + (d if j < SIDE - 1 else -d))
					var w := g.to_global(local)
					if _plain_hit(space, w.x, w.z, layer).is_empty():
						missed += 1
		band[d] = missed
	print("info: plain rays moved (d, d) off the 25 regions' 235,225 vertices, misses: d 0.00001 -> %d, 0.0001 -> %d, 0.001 -> %d, %s -> %d" % [
		band[0.00001], band[0.0001], band[0.001], str(eps), band[eps]])
	_check(band[0.00001] > 0 and band[eps] == 0,
		"the band: 0.00001 off the vertices still misses (%d), RAY_GRID_EPSILON (%s) off misses none (%d)" % [band[0.00001], str(eps), band[eps]])
	for key in regions:
		(regions[key][0] as Node).queue_free()
	await physics_frame

	# A lone region at the frame origin: its outer edges have no neighbour,
	# so a vertex there answers only from the side ray_columns tries second.
	var lone: Array = _grid_region(Vector3.ZERO, layer)
	await physics_frame
	await physics_frame
	var lone_g: Node3D = lone[0]
	var lone_miss := 0
	var lone_plain := 0
	for j in range(SIDE):
		for i in range(SIDE):
			var w := lone_g.to_global(Vector3(float(i) * TILE, 0.0, float(j) * TILE))
			if (TC.vertical_ray(space, w.x, w.z, 1000.0, -1000.0, layer) as Dictionary).is_empty():
				lone_miss += 1
			if _plain_hit(space, w.x, w.z, layer).is_empty():
				lone_plain += 1
	_check(lone_miss == 0, "a lone region (no neighbours): the helper misses none of its 9,409 vertices, its outer edges included (missed %d; plain %d)" % [lone_miss, lone_plain])
	lone_g.queue_free()

	# Far from the frame origin the same placement leaves the shape's local
	# coordinates inexact, and the plain ray does not miss there: recorded.
	# Two far cells: 60 region spans out on both axes (world ~115,000), and the
	# far corner cell of Constantinople's radius-2 grid in 97/168's frame --
	# the server's -single-frame (round 571): World3D._cell_offset(10, -91),
	# world x from -175,680 to -173,760, where float32's spacing is 1/64 and
	# the helper's 0.01 rounds to 0.015625 off the line (RAY_GRID_EPSILON's
	# doc comment).
	var fars := [
		["60 region spans out (world ~115,000)", Vector3(60.0 * 1920.0, 0.0, 60.0 * 1920.0)],
		["Constantinople's radius-2 far corner under -single-frame (world x to -175,680)", Vector3(-91.0 * 1920.0, 0.0, 10.0 * 1920.0)],
	]
	for far_case in fars:
		var far: Array = _grid_region(far_case[1], layer)
		await physics_frame
		await physics_frame
		var far_g: Node3D = far[0]
		var far_plain := 0
		var far_helper := 0
		for j in range(SIDE):
			for i in range(SIDE):
				var w := far_g.to_global(Vector3(float(i) * TILE, 0.0, float(j) * TILE))
				if _plain_hit(space, w.x, w.z, layer).is_empty():
					far_plain += 1
				if (TC.vertical_ray(space, w.x, w.z, 1000.0, -1000.0, layer) as Dictionary).is_empty():
					far_helper += 1
		_check(far_helper == 0, "%s: the helper misses none of 9,409 (%d; plain %d, recorded)" % [far_case[0], far_helper, far_plain])
		far_g.queue_free()
	print("info: the grid probe took %d ms" % (Time.get_ticks_msec() - started))

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	TC = load("res://scripts/assets/terrain_collision.gd") as GDScript
	_check(TC != null, "TerrainCollision loads (absent before round 567)")
	if TC == null:
		_finish()
		return
	_test_layout()
	await _test_physics()
	if TC.get_script_constant_map().has("RAY_GRID_EPSILON"):
		await _test_grid_lines()
	else:
		_check(false, "TerrainCollision has RAY_GRID_EPSILON and vertical_ray (absent before round 572)")
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
