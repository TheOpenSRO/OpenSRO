class_name BmsCollision

## Turns a `.bms`'s own object navigation mesh (BmsReader.CollisionMesh) into
## real walkable surface geometry and real blocking wall geometry.
##
## This is the per-object counterpart of NvmCollision, which does the same
## job for a region's terrain `.nvm`. The two formats carry the same real
## structure -- vertices, convex navigable cells, and edges that either bound
## the mesh or join two cells -- and, measured across real data, the same
## real edge-flag semantics.
##
## Why this matters for movement: the real client never collides a character
## against a building's *render* geometry. It walks this cell/edge graph and
## takes the character's height straight from the cell it is standing on, so
## a staircase is climbed by walking up its navigation triangles, not by
## stepping onto its render mesh. Building Godot collision from this section
## rather than from the render mesh is what reproduces that.
##
## The blocking rule is the same real `(flags & 3)` test the client's own
## terrain traversal applies -- see NvmCollision's top comment and
## docs/protocol/NVM_FORMAT.md's "Edge flag semantics: solved". That it also
## holds for object navigation meshes is measured, not assumed: across 507
## real collision sections found in a 4,395-file real sample of a real
## Data.pk2, the two real lists separate perfectly by adjacency --
##
##   * all 20,892 real outline edges carry BmsReader.NO_CELL on their far
##     side; 93.5% of them carry real flag 3 (blocking);
##   * all 57,238 real internal edges join two real cells; 99.1% of them
##     carry real flag 4 (passable).
##
## The adjacency split is total, the flag split is not, and that is why this
## file tests the real flags rather than an edge's list: a real internal edge
## may block (0.9% do, mostly real flag 7 -- a real passable bit set
## alongside the real blocking bits), and a real outline edge may not.

## Real mask the client tests an edge's flags against. Same real value as
## NvmCollision.BLOCKING_FLAG_MASK, restated here so this file reads on its
## own; see that file for the derivation from the client's own traversal.
const BLOCKING_FLAG_MASK := 0x3

static func is_blocking(edge: BmsReader.CollisionEdge) -> bool:
	return (edge.flags & BLOCKING_FLAG_MASK) != 0

## Every real edge of the object that blocks movement. Both real lists are
## checked rather than either being assumed: the mask is what decides, not
## which list an edge happens to live in.
static func blocking_edges(collision: BmsReader.CollisionMesh) -> Array[BmsReader.CollisionEdge]:
	var out: Array[BmsReader.CollisionEdge] = []
	for edge in collision.outline_edges:
		if is_blocking(edge):
			out.append(edge)
	for edge in collision.internal_edges:
		if is_blocking(edge):
			out.append(edge)
	return out

## The object's real walkable surface as a triangle soup in the object's own
## local space -- one triangle per real navigable cell, at the real heights
## the file stores. Feed it straight to ConcavePolygonShape3D.set_faces().
##
## Winding is left exactly as the file stores it, and callers are expected to
## set `backface_collision = true` on the shape (see
## ObjectLoader._add_object_navmesh_collision). A one-sided shape is wrong
## for this data regardless of winding: a blocking edge has to stop a
## character approaching from either side.
##
## Godot's ConcavePolygonShape3D is one-sided by default, and that is not a
## detail to leave to chance here -- with it left off, a capsule dropped onto
## a real staircase's navigation mesh falls straight through it. Measured
## across 41,762 real cells, 99.8% have a geometric normal pointing upward as
## stored (right-handed, `(b-a) x (c-a)`), which would suggest the stored
## winding already faces the right way for Godot; the physics behaviour says
## otherwise, and that disagreement is unresolved. Two-sided collision is
## correct either way, so nothing here depends on settling it.
static func surface_triangles(collision: BmsReader.CollisionMesh) -> PackedVector3Array:
	var faces := PackedVector3Array()
	faces.resize(collision.cells.size() * 3)
	var n := 0
	for cell in collision.cells:
		faces[n] = collision.vertices[cell.a].position
		faces[n + 1] = collision.vertices[cell.b].position
		faces[n + 2] = collision.vertices[cell.c].position
		n += 3
	return faces

## Builds a triangle soup of vertical walls, one quad per blocking edge, in
## the object's own local space, rising from each edge's own real endpoint
## heights.
##
## `wall_height` is a project choice, not recovered data -- for the same real
## reason it is in NvmCollision: the real client tests an edge as a 2D line
## rather than as geometry, so nothing in the format gives a wall a height.
## It is required rather than defaulted so no invented number is ever
## presented as if it came from the game.
static func build_wall_triangles(
	collision: BmsReader.CollisionMesh, wall_height: float
) -> PackedVector3Array:
	var faces := PackedVector3Array()
	for edge in blocking_edges(collision):
		if edge.v0 >= collision.vertices.size() or edge.v1 >= collision.vertices.size():
			continue
		var a: Vector3 = collision.vertices[edge.v0].position
		var b: Vector3 = collision.vertices[edge.v1].position
		if a.is_equal_approx(b):
			continue
		var a_hi := a + Vector3.UP * wall_height
		var b_hi := b + Vector3.UP * wall_height
		faces.append_array([a, b, b_hi])
		faces.append_array([a, b_hi, a_hi])
	return faces
