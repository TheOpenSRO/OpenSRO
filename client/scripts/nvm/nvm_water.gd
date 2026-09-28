class_name NvmWater

## **Not what the world draws since round 627.** The client draws water from
## the `.m` blocks' PlaneType/PlaneHeight (MapmWater, docs/protocol/
## MAPM_FORMAT.md "Water"). This plane map marks 3,846 blocks water that the
## `.m` does not and misses 6,259 it draws, and the quads below face down
## (Godot's front face is Plane(a, b, c)), which hid them from above. Kept
## for its reader-side tests and as round 627's negative's baseline.
##
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

## ## Why both sources, measured
##
## The plane map alone is far too coarse to be the water's *shape*: one cell
## covers 320x320 units, which is bigger than most real ponds. Measured on
## real Jangan region `nv_62a8`: the plane map marks **17 of its 36 cells**
## as water, but only **134 of its 9,216 real tiles** actually carry a real
## WATER/DEEP_WATER type -- the plane cells cover roughly thirty times more
## ground than there is real water. Emitting a plane per cell therefore
## flooded whole blocks, nearly all of it buried under terrain and invisible,
## while real garden ponds sat dry. That is what a real playtest saw on
## 2026-09-06: a real pond bed with real lotus-flower props floating over
## bare ground.
##
## The per-tile flags alone are no better, for the opposite reason: they say
## exactly where water is at 20-unit resolution but carry no level, which is
## why the earlier per-tile approach draped water over the terrain and made
## ponds look like jagged sheets.
##
## So: **shape from the real tiles, level from the real plane cell**. The two
## nest cleanly -- all 134 of those real water tiles fall inside a real water
## plane cell, and none outside -- so the pairing is unambiguous and needs no
## invented fallback.

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

## How many of a region's real plane cells are marked as water, regardless
## of whether any tile under them resolved to a water tile. Reported
## alongside a failure to build water, so "no water here" can be told apart
## from "water here that did not build".
static func water_plane_cell_count(region: NvmReader.ParsedRegion) -> int:
	if region == null:
		return 0
	var n := 0
	for t in region.plane_types:
		if t == PLANE_TYPE_WATER:
			n += 1
	return n

## Builds a flat water surface mesh in region-local space (the same space
## NvmCollision uses -- local X is world X, local Y is world Z; see
## NVM_FORMAT.md's "Real local-axis orientation"). Returns null when the
## region has no real water at all, so a caller can skip adding a pointless
## node.
##
## Each quad gets its own 0..1 UV so a real animated water texture tiles
## per block rather than being stretched across the whole region, matching
## the per-quad convention the ground meshes already use.
static func build_water_mesh(
	region: NvmReader.ParsedRegion, tile_table: TileIndexReader.Table
) -> ArrayMesh:
	if region == null or tile_table == null:
		return null
	if region.tiles.size() < NvmReader.TILE_COUNT:
		return null
	var side := NvmReader.PLANE_MAP_SIDE
	if region.plane_types.size() < side * side or region.plane_heights.size() < side * side:
		return null

	var positions := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	# Shape comes from the real per-tile water flags, level from the real
	# plane map. Neither alone is right, and this is measured rather than
	# assumed -- see this file's own "Why both sources" comment.
	var tside := NvmReader.TILE_MAP_SIDE
	var tile_span := 1920.0 / float(tside)
	for row in range(tside):
		for col in range(tside):
			var tile: NvmReader.Tile = region.tiles[row * tside + col]
			var entry = tile_table.lookup(tile.texture_id)
			if entry == null:
				continue
			if entry.type != TileIndexReader.TileType.WATER and entry.type != TileIndexReader.TileType.DEEP_WATER:
				continue
			var pcol := int(float(col) / float(tside) * float(side))
			var prow := int(float(row) / float(tside) * float(side))
			if region.plane_types[prow * side + pcol] != PLANE_TYPE_WATER:
				# No real level to place this tile at. Measured never to
				# happen in real data (134 of 134 real water tiles in real
				# Jangan fall inside a real water plane cell), so this skips
				# rather than inventing a height.
				continue
			var height := region.plane_heights[prow * side + pcol]
			var x0 := float(col) * tile_span
			var x1 := x0 + tile_span
			var z0 := float(row) * tile_span
			var z1 := z0 + tile_span
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
