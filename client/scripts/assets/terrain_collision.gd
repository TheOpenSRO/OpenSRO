extends RefCounted
class_name TerrainCollision

## A region's terrain collision as a heightfield (round 567): one
## HeightMapShape3D over the region's 97x97 height grid, in place of the
## ConcavePolygonShape3D built from every triangle of every surface of the
## drawn mesh (round 565's MapmTerrainBuilder.surface_faces).
##
## Why a heightfield is exact here: a region's ground is one height per grid
## vertex (MapmReader; docs/protocol/MAPM_FORMAT.md), so it cannot overhang,
## and the drawn mesh is that grid split into two triangles a quad. The
## trimesh held each ground triangle about 2.5 times over -- 45,768 faces for
## 97/168 against the base surface's 18,432, the opaque passes and the blend
## overlays repeating the base's triangles (docs/RE_COMPLETION.md, round 565)
## -- and built a BVH over them on the main thread: `collision` 25-33 ms of a
## streamed cell's 39-51 ms terrain commit after round 565, 27-30 % of the
## streamed cells' whole main-thread commit after round 566 (round 567's
## gate: round 566's benchmark logs, and BASE re-measured).
##
## THE DIAGONAL. The shape has to split each quad the way the mesh does, or
## the two disagree inside every quad whose corners are not coplanar. The
## mesh (MapmTerrainBuilder._textured_surfaces_from_cells and
## _mesh_arrays_from_cells) places vertex (r, c) at local (c * TILE_SIZE, h,
## r * TILE_SIZE) and draws quad (r, c) as [i00, i10, i11] + [i00, i11, i01]
## -- its diagonal joins (r, c) to (r + 1, c + 1). Godot 4.2.2's
## GodotHeightMapShape3D (servers/physics_3d/godot_shape_3d.cpp and .h at the
## 4.2.2-stable tag, read 2026-09-25) reads height (x, z) from
## `heights[z * width + x]`, places it at (x - (width - 1) / 2, h, z -
## (depth - 1) / 2), and splits cell (x, z) into (x, z), (x + 1, z), (x, z +
## 1) and (x + 1, z), (x + 1, z + 1), (x, z + 1) -- the same in `cull` (every
## shape query), `_heightmap_cell_cull_segment` (rays) -- so ITS diagonal joins
## (x + 1, z) to (x, z + 1): the other one. Laid out row for row (z = r, the
## item's first plan) the shape would cut every quad the other way. So the
## rows are stored reversed, z = SIDE - 1 - r, and the shape's own z axis is
## flipped back (shape_transform's -TILE_SIZE): shape cell (x, z) is then the
## mesh's quad (r, c) = (SIDE - 2 - z, x), and its diagonal, shape (x + 1, z)
## to (x, z + 1), is mesh vertex (r + 1, c + 1) to (r, c) -- the mesh's own.
## terrain_collision_test.gd compares every triangle of the two, and fires
## rays at both shapes inside non-planar quads.
##
## The flip also cancels the terrain group's own mirror (World3D's
## `scale.z = -1`, the world's z -> -z un-mirroring): the shape's GLOBAL basis
## is a plain positive scale, diag(TILE_SIZE, 1, TILE_SIZE), not a
## reflection. It is still a non-uniform scale, which CollisionShape3D's
## configuration warning ("A non-uniformly scaled CollisionShape3D node will
## probably not function as expected", scene/3d/collision_shape_3d.cpp,
## 4.2.2) names -- an editor warning, never printed at run time. Whether
## GodotPhysics honours it is MEASURED, not read: terrain_collision_test.gd
## fires rays and sweeps a sphere and a capsule at both shapes under the
## group's transform, and World3D's SRREVAMP_QA_GROUND_RAYS does the same on
## the real regions.
##
## What differs from the trimesh, read from the same 4.2.2 source: a VERTICAL
## ray (one that stays in one cell) tests both faces of a heightfield
## triangle when the query hits back faces (PhysicsRayQueryParameters3D's
## default), where the trimesh's triangles are one-sided (its
## `backface_collision` is false); a ray crossing cells tests front faces
## only, as the trimesh does; and every shape query (the camera arm's sphere,
## the player's capsule) collides with both faces of a heightfield triangle
## (`cull` sets `backface_collision = !p_invert_backface_collision`) where the
## trimesh's are one-sided. So an upward vertical ray from under the ground
## now finds it; the test records that. And MEASURED there (not read): a
## capsule moved down onto the one-sided trimesh under the group's mirror
## with PhysicsServer3D.body_test_motion -- the query
## CharacterBody3D.move_and_slide makes -- reports no contact, while the same
## trimesh unmirrored, or two-sided under the mirror, reports it, and rays
## and cast_motion find it either way; a 2 s move_and_slide walk sinks into
## that trimesh (caught part-way, not a clean fall) and stays on the
## heightfield.
## The sixty-first and sixty-third rounds (docs/WORLD_ISSUES.md) met the same
## mirror on the objects' navigation-mesh collision, which is why
## ObjectLoader._add_object_navmesh_collision sets `backface_collision`.

## Vertices a side of a stitched region: six 17-wide blocks sharing their
## edge vertices, 6 * 16 + 1 = 97 (MapmTerrainBuilder.build_full_region_mesh's
## doc comment; docs/protocol/MAPM_FORMAT.md).
const SIDE := MapmReader.BLOCKS_PER_SIDE * (MapmTerrainBuilder.GRID_WIDTH - 1) + 1

## The region's height grid as a HeightMapShape3D's map_data: SIDE x SIDE
## heights, the mesh's row r stored at shape row SIDE - 1 - r (see THE
## DIAGONAL above), column c at shape column c. Stitched exactly as
## MapmTerrainBuilder._full_region_cells stitches the mesh -- the blocks in
## nested file order, each writing its 17 x 17 vertices, so a later block
## wins a shared edge -- which terrain_collision_test.gd holds against
## build_full_region_mesh's vertices on a region whose block edges disagree.
## Empty for a region without a real 6x6 block grid. Plain data: a
## WorkerThreadPool task may build it (World3D._terrain_prepare_build).
static func heights_from_region(region: MapmReader.ParsedRegion) -> PackedFloat32Array:
	var heights := PackedFloat32Array()
	var bands := MapmReader.BLOCKS_PER_SIDE
	if region == null or region.blocks.size() != bands * bands:
		return heights
	var gw := MapmTerrainBuilder.GRID_WIDTH
	heights.resize(SIDE * SIDE)
	for band_row in range(bands):
		for band_col in range(bands):
			var block: MapmReader.Block = region.blocks[band_row * bands + band_col]
			for local_r in range(gw):
				var r := band_row * (gw - 1) + local_r
				var base := (SIDE - 1 - r) * SIDE + band_col * (gw - 1)
				for local_c in range(gw):
					heights[base + local_c] = (block.vertices[local_r * gw + local_c] as MapmReader.Vertex).height
	return heights

## The CollisionShape3D's transform in the terrain group's local space, where
## the mesh spans 0..(SIDE - 1) * TILE_SIZE = 1920 on x and z from the
## group's origin: a HeightMapShape3D spans (width - 1) x (depth - 1) units
## centred on its own origin (4.2.2's `_get_point`), so it is scaled by
## TILE_SIZE on x, by -TILE_SIZE on z (the reversed rows, THE DIAGONAL) and
## moved to the grid's centre, 960 on both axes. Heights are not scaled.
static func shape_transform() -> Transform3D:
	var tile := MapmTerrainBuilder.TILE_SIZE
	var half := float(SIDE - 1) * tile / 2.0
	return Transform3D(Basis(Vector3(tile, 0.0, 0.0), Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, -tile)),
		Vector3(half, 0.0, half))

## The shape, from heights_from_region's grid, or null for a grid of the wrong
## size. Main thread only: a Shape3D owns a PhysicsServer RID (the
## prepare-thread rule, World3D._terrain_prepare).
static func make_shape(heights: PackedFloat32Array) -> HeightMapShape3D:
	if heights.size() != SIDE * SIDE:
		return null
	var shape := HeightMapShape3D.new()
	shape.map_width = SIDE
	shape.map_depth = SIDE
	shape.map_data = heights
	return shape

## The height of the DRAWN mesh's own triangle at group-local (x, z), from
## heights_from_region's grid: the quad's corners interpolated on the side of
## the mesh's (r, c)-(r + 1, c + 1) diagonal the point is on. NAN outside the
## grid. What World3D's SRREVAMP_QA_GROUND_RAYS holds every terrain ray's hit
## against, so a ray is compared with the ground that is drawn, not with the
## shape that answered it.
static func mesh_height_at(heights: PackedFloat32Array, x: float, z: float) -> float:
	var tile := MapmTerrainBuilder.TILE_SIZE
	var fx := x / tile
	var fz := z / tile
	if heights.size() != SIDE * SIDE or fx < 0.0 or fz < 0.0 or fx > float(SIDE - 1) or fz > float(SIDE - 1):
		return NAN
	var c := mini(int(floor(fx)), SIDE - 2)
	var r := mini(int(floor(fz)), SIDE - 2)
	var u := fx - float(c)
	var v := fz - float(r)
	var h00 := heights[(SIDE - 1 - r) * SIDE + c]
	var h10 := heights[(SIDE - 1 - r) * SIDE + c + 1]
	var h01 := heights[(SIDE - 2 - r) * SIDE + c]
	var h11 := heights[(SIDE - 2 - r) * SIDE + c + 1]
	if u >= v:
		# [i00, i10, i11]
		return h00 + u * (h10 - h00) + v * (h11 - h10)
	# [i00, i11, i01]
	return h00 + v * (h01 - h00) + u * (h11 - h01)
