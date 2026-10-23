class_name NvmCollision

## Turns a parsed `.nvm` region's real cell/edge graph into real blocking
## wall geometry.
##
## The blocking rule is not a guess. The client's own collision traversal
## (`CRTNavMeshTerrain`, `FUN_004047a0`) walks a movement segment cell by
## cell, and on reaching an edge tests `(m_nFlag & 3)`: if set it stops,
## otherwise it either hands off to the neighbouring region (global edge)
## or passes into the adjacent cell. See
## docs/protocol/NVM_FORMAT.md's "Edge flag semantics: solved" section for
## the full derivation, including the three independent confirmations and
## why the polarity is forced rather than assumed.
##
## In real data this resolves cleanly: internal edges carry only flag 2
## (blocking -- and structurally a wall, with no cell on one side) or flag
## 4 (passable, joining two walkable cells), and every global edge carries
## flag 8, which is never blocking because global edges are the only way to
## leave a region.
##
## This is walkability, which is *not* the same thing as the terrain mesh's
## own geometric collision: it is the authoritative boundary the real game
## enforces, and it exists in places no geometry does.

## Real mask the client tests an edge's flags against -- see this file's
## top comment.
const BLOCKING_FLAG_MASK := 0x3

## Real per-region world size and height-grid spacing, matching
## MapmTerrainBuilder.TILE_SIZE and World3D.REGION_SPAN: a region is 96
## quads of 20.0 units across, so 97 height samples span exactly 1920.0.
const TILE_SIZE := 20.0

static func is_blocking(edge: NvmReader.Edge) -> bool:
	return (edge.flags & BLOCKING_FLAG_MASK) != 0

## Every real edge in the region that blocks movement. Global edges are
## checked too rather than assumed passable -- in every real file measured
## none of them block, but the mask is what decides, not the edge's list.
static func blocking_edges(region: NvmReader.ParsedRegion) -> Array[NvmReader.Edge]:
	var out: Array[NvmReader.Edge] = []
	for edge in region.internal_edges:
		if is_blocking(edge):
			out.append(edge)
	for edge in region.global_edges:
		if is_blocking(edge):
			out.append(edge)
	return out

## Bilinearly samples the region's real 97x97 heightmap at a region-local
## X/Z position (both in [0, 1920]). Uses the same axis convention as
## MapmTerrainBuilder -- column maps to X, row maps to Z -- which is what
## lets this share the terrain's own coordinate space.
##
## That a `.nvm`'s own local X is world X and its local Y is world Z (no
## swap, despite World3D's region *grid* axes being swapped) is measured,
## not assumed: see NVM_FORMAT.md's "Real local-axis orientation" section,
## which reads it off every real global edge's boundary geometry.
static func sample_height(region: NvmReader.ParsedRegion, x: float, z: float) -> float:
	var side := NvmReader.HEIGHT_MAP_SIDE
	if region.heights.size() < side * side:
		return 0.0
	var last := float(side - 1)
	var fx := clampf(x / TILE_SIZE, 0.0, last)
	var fz := clampf(z / TILE_SIZE, 0.0, last)
	var c0 := int(floorf(fx))
	var r0 := int(floorf(fz))
	var c1 := mini(c0 + 1, side - 1)
	var r1 := mini(r0 + 1, side - 1)
	var tx := fx - float(c0)
	var tz := fz - float(r0)
	var h00 := region.heights[r0 * side + c0]
	var h10 := region.heights[r0 * side + c1]
	var h01 := region.heights[r1 * side + c0]
	var h11 := region.heights[r1 * side + c1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)

## The bit of a `.nvm` PlaneTypeMap entry that makes the block's plane a
## surface to stand on (round 744, READ). The client's terrain height query,
## `CRTNavMeshTerrain::vslot_001` (0x004051b0), interpolates the heightmap and
## then tests `PlaneTypeMap[row * 6 + col] & 2` (0x405319, `test BYTE PTR
## [edx+esi*1],0x2` at the map's +0x1b360); when it is set and the block's
## PlaneHeight (+0x1b384) is above the interpolated ground, the plane's height
## is the answer (0x405333-0x405347: `fcom`, `test ah,0x41`, `fstp` into y).
## `row` and `col` are the 20-unit tile indices (truncated, `_ftol` at
## 0xb42d10) shifted right by 4 -- the 6x6 blocks of 320. These are the only
## two readers of the map in the client (the other is FUN_00403980, the
## matching ground normal, which returns a flat one on the plane).
##
## MEASURED (waterat -census, all 4,704 regions): the bit is set on exactly
## the 955 blocks whose `.m` PlaneType is 1, the still surface MapmWater draws
## (844 `.nvm` type 3, 111 type 2) -- Karakoram's frozen lake, plane 800, over
## ground at 396-837 in 90/127. Plain water is `.nvm` type 1 and stays wadeable.
const SOLID_PLANE_BIT := 2
## One PlaneTypeMap block's span: 16 tiles of 20 (6 blocks a region).
const PLANE_BLOCK_SPAN := 320.0

## The block of the PlaneTypeMap a region-local point falls in, as
## row * 6 + col, the way vslot_001 indexes it. Outside [0, 1920) the tile is
## clamped to the region's own last one (OURS: the client is only ever asked
## about a point inside the region it holds).
static func plane_index(x: float, z: float) -> int:
	var side := NvmReader.PLANE_MAP_SIDE
	var tiles := NvmReader.TILE_MAP_SIDE
	var tx := clampi(int(floorf(x / TILE_SIZE)), 0, tiles - 1)
	var tz := clampi(int(floorf(z / TILE_SIZE)), 0, tiles - 1)
	return (tz >> 4) * side + (tx >> 4)

## The height of the solid plane over a region-local point -- Karakoram's ice
## -- or NAN where the block has none (SOLID_PLANE_BIT clear).
static func solid_plane_height(region: NvmReader.ParsedRegion, x: float, z: float) -> float:
	var count := NvmReader.PLANE_COUNT
	if region.plane_types.size() < count or region.plane_heights.size() < count:
		return NAN
	var i := plane_index(x, z)
	if (region.plane_types[i] & SOLID_PLANE_BIT) == 0:
		return NAN
	return region.plane_heights[i]

## The terrain's height at a region-local point the way the client's own
## height query gives it (CRTNavMeshTerrain::vslot_001, see SOLID_PLANE_BIT):
## the heightmap, raised to the block's solid plane where there is one and it
## is higher. This, not sample_height, is the ground a character stands on:
## with the heightmap alone a walker on Karakoram's frozen lake sank to the
## lakebed, 260-300 units under the ice drawn over it (round 744).
static func terrain_height(region: NvmReader.ParsedRegion, x: float, z: float) -> float:
	var h := sample_height(region, x, z)
	var plane := solid_plane_height(region, x, z)
	if not is_nan(plane) and plane > h:
		return plane
	return h

## Round 813: the terrain's normal under a character standing at region-local
## (x, y, z), as the original's slope tilt reads it (READ,
## `RTNavMeshTerrain::FUN_00403980`, reached as `CRTNavCellQuad::vslot_004`):
## - the 20-unit tile (`_ftol` of x / 20 and z / 20, 20.0 at 0xe1b830);
## - on a block whose PlaneTypeMap has SOLID_PLANE_BIT, a character whose y IS
##   the block's PlaneHeight (`fucompp` 0x403a4b) stands on the plane: straight
##   up (0xee5c54, (0, 1, 0));
## - else the face normal of the tile's triangle under the point. The tile is
##   split on its (x0, z0)-(x1, z1) diagonal: where the z fraction is below the
##   x fraction, the triangle (x0, z0), (x1, z0), (x1, z1), normal
##   (20 (h00 - h10), 400, -20 (h11 - h10)); else (x0, z0), (x0, z1), (x1, z1),
##   normal (-20 (h11 - h01), 400, 20 (h00 - h01)); both normalised.
## Unlike terrain_height, which interpolates the four corners, this is the
## triangle's own plane. OURS: the tile is clamped to the region (the client
## is only asked about a point inside it), and "y is the plane's height" is
## taken within PLANE_NORMAL_MATCH (our y has been through the scene's float
## transforms; the client compares its own stored y).
const PLANE_NORMAL_MATCH := 0.001
static func terrain_normal(region: NvmReader.ParsedRegion, x: float, z: float, y: float) -> Vector3:
	var side := NvmReader.HEIGHT_MAP_SIDE
	var tiles := NvmReader.TILE_MAP_SIDE
	if region == null or region.heights.size() < side * side:
		return Vector3.UP
	var ix := clampi(int(x / TILE_SIZE), 0, tiles - 1)
	var iz := clampi(int(z / TILE_SIZE), 0, tiles - 1)
	var count := NvmReader.PLANE_COUNT
	if region.plane_types.size() >= count and region.plane_heights.size() >= count:
		var pi := (iz >> 4) * NvmReader.PLANE_MAP_SIDE + (ix >> 4)
		if (region.plane_types[pi] & SOLID_PLANE_BIT) != 0 and absf(region.plane_heights[pi] - y) < PLANE_NORMAL_MATCH:
			return Vector3.UP
	var fx := (x - float(ix) * TILE_SIZE) / TILE_SIZE
	var fz := (z - float(iz) * TILE_SIZE) / TILE_SIZE
	var h00 := region.heights[iz * side + ix]
	var h10 := region.heights[iz * side + ix + 1]
	var h01 := region.heights[(iz + 1) * side + ix]
	var h11 := region.heights[(iz + 1) * side + ix + 1]
	var s := TILE_SIZE
	if fz < fx:
		return Vector3(s * (h00 - h10), s * s, -s * (h11 - h10)).normalized()
	return Vector3(-s * (h11 - h01), s * s, s * (h00 - h01)).normalized()

## The solid planes as collision triangles, region-local: one flat 320 x 320
## quad at PlaneHeight per block with SOLID_PLANE_BIT, two triangles each, for
## a ConcavePolygonShape3D on the terrain layer -- so the click-to-move ray, the
## camera and every terrain ray stop at the ice instead of the lakebed under
## it. The caller makes the shape two-sided (World3D's terrain group mirrors z,
## which flips any winding). Empty for a region with no solid plane. Plain
## data (the terrain prepare runs it on a task).
static func solid_plane_faces(region: NvmReader.ParsedRegion) -> PackedVector3Array:
	var faces := PackedVector3Array()
	var side := NvmReader.PLANE_MAP_SIDE
	if region == null or region.plane_types.size() < side * side or region.plane_heights.size() < side * side:
		return faces
	for row in range(side):
		for col in range(side):
			var i := row * side + col
			if (region.plane_types[i] & SOLID_PLANE_BIT) == 0:
				continue
			var h := region.plane_heights[i]
			var x0 := col * PLANE_BLOCK_SPAN
			var z0 := row * PLANE_BLOCK_SPAN
			var x1 := x0 + PLANE_BLOCK_SPAN
			var z1 := z0 + PLANE_BLOCK_SPAN
			faces.append_array([
				Vector3(x0, h, z0), Vector3(x0, h, z1), Vector3(x1, h, z1),
				Vector3(x0, h, z0), Vector3(x1, h, z1), Vector3(x1, h, z0),
			])
	return faces

## Builds a triangle soup of vertical walls, one quad per blocking edge,
## in region-local space (X/Z in [0, 1920], Y from the region's own
## heightmap). Feed it straight to ConcavePolygonShape3D.set_faces().
##
## `wall_height` is a project choice, not recovered data -- nothing in the
## format or the client's collision code gives a wall a height, because the
## real client tests the edge as an infinite 2D line rather than as
## geometry. It is required rather than defaulted so no invented number is
## ever presented as if it came from the game.
static func build_wall_triangles(
	region: NvmReader.ParsedRegion, wall_height: float
) -> PackedVector3Array:
	var faces := PackedVector3Array()
	for edge in blocking_edges(region):
		var a := edge.line_min
		var b := edge.line_max
		if a.is_equal_approx(b):
			continue
		var ha := terrain_height(region, a.x, a.y)
		var hb := terrain_height(region, b.x, b.y)
		var a_lo := Vector3(a.x, ha, a.y)
		var b_lo := Vector3(b.x, hb, b.y)
		var a_hi := Vector3(a.x, ha + wall_height, a.y)
		var b_hi := Vector3(b.x, hb + wall_height, b.y)
		faces.append_array([a_lo, b_lo, b_hi])
		faces.append_array([a_lo, b_hi, a_hi])
	return faces
