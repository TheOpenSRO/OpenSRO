class_name NvmWater

## Builds a real region's water surfaces from its `.nvm` plane maps.
##
## The real `.nvm` carries a 6x6 `PlaneTypeMap` and `PlaneHeightMap`
## alongside the heightmap (see docs/protocol/NVM_FORMAT.md). Each entry
## covers one sixth of the region per axis -- a real 320x320 unit block --
## and where the type is water the height is that body of water's own flat
## surface level.
##
## That level is exactly what this project previously had no source for.
## `MapmTerrainBuilder.build_water_mesh` classified water per *terrain
## tile* and then placed each quad at that tile's own terrain height,
## explicitly because there was "no real per-body-of-water reference height
## to compute anyway". The result followed the ground instead of lying
## flat, so real ponds rendered as jagged tile-shaped sheets cutting through
## the terrain -- reported from a real playtest of the real Jangan temple
## garden. The plane maps are that missing reference.
##
## A real water plane is emitted flat across its whole block; terrain
## standing above it simply occludes it, which is what produces a real
## shoreline. No clipping against the ground is needed or wanted.

## Real plane type meaning water.
##
## Established by measurement across **264 real `.nvm` files**, not
## assumed: for every real plane cell, the share of that cell's own terrain
## lying below its own plane height is **92.4%** for type 1 against
## **39.9%** for type 0 (1,885 and 7,619 real cells). Type 1 cells are
## almost entirely submerged; type 0's height means nothing.
const PLANE_TYPE_WATER := 1

## Real world size of one plane cell: a region is REGION_SPAN across and
## the plane map is PLANE_MAP_SIDE cells per axis.
const PLANE_CELL_SPAN := 1920.0 / float(NvmReader.PLANE_MAP_SIDE)

## Builds a flat water surface mesh in region-local space (the same space
## NvmCollision uses -- local X is world X, local Y is world Z; see
## NVM_FORMAT.md's "Real local-axis orientation"). Returns null when the
## region has no real water at all, so a caller can skip adding a pointless
## node.
##
## Each quad gets its own 0..1 UV so a real animated water texture tiles
## per block rather than being stretched across the whole region, matching
## the per-quad convention the ground meshes already use.
static func build_water_mesh(region: NvmReader.ParsedRegion) -> ArrayMesh:
	if region == null:
		return null
	var side := NvmReader.PLANE_MAP_SIDE
	if region.plane_types.size() < side * side or region.plane_heights.size() < side * side:
		return null

	var positions := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	for row in range(side):
		for col in range(side):
			if region.plane_types[row * side + col] != PLANE_TYPE_WATER:
				continue
			var height := region.plane_heights[row * side + col]
			var x0 := float(col) * PLANE_CELL_SPAN
			var x1 := x0 + PLANE_CELL_SPAN
			var z0 := float(row) * PLANE_CELL_SPAN
			var z1 := z0 + PLANE_CELL_SPAN
			var base := positions.size()
			positions.append_array([
				Vector3(x0, height, z0),
				Vector3(x1, height, z0),
				Vector3(x1, height, z1),
				Vector3(x0, height, z1),
			])
			uvs.append_array([
				Vector2(0.0, 0.0), Vector2(1.0, 0.0),
				Vector2(1.0, 1.0), Vector2(0.0, 1.0),
			])
			# Wound so the surface faces up, which is the only side a real
			# player ever sees it from.
			indices.append_array([
				base, base + 2, base + 1,
				base, base + 3, base + 2,
			])

	if indices.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

## Whether the region has any real water plane at all.
static func has_water(region: NvmReader.ParsedRegion) -> bool:
	if region == null:
		return false
	for t in region.plane_types:
		if t == PLANE_TYPE_WATER:
			return true
	return false
