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
		var ha := sample_height(region, a.x, a.y)
		var hb := sample_height(region, b.x, b.y)
		var a_lo := Vector3(a.x, ha, a.y)
		var b_lo := Vector3(b.x, hb, b.y)
		var a_hi := Vector3(a.x, ha + wall_height, a.y)
		var b_hi := Vector3(b.x, hb + wall_height, b.y)
		faces.append_array([a_lo, b_lo, b_hi])
		faces.append_array([a_lo, b_hi, a_hi])
	return faces
