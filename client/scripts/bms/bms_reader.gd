extends RefCounted
class_name BmsReader

## Read-only parser for the .bms (JMXVBMS) mesh geometry format.
## See docs/protocol/BMS_FORMAT.md for the on-disk layout. Mirrors
## server/internal/bms's Go implementation; keep the two in sync if the
## format understanding changes.

const MAGIC := "JMXVBMS 0110"
const MAGIC_LEN := 12
const PREAMBLE_END := 0x48
const INDEX_REC_SIZE := 6
const HEADER_PTRS_BASE := 0x10

## The two real per-vertex record sizes found in real files: 44 bytes
## (position+normal+uv+12 unconfirmed trailing bytes -- the only size this
## project's earlier samples, all small character hair/face/body-part
## meshes, ever showed) and 52 bytes (found 2026-08-23, live-testing real,
## larger Jangan palace building meshes -- the same leading
## position+normal+uv fields, but 20 trailing bytes instead of 12). Real
## per-file evidence for 52: pulling and parsing a real
## `cj_pal_bigdoor_roof01.bms` (676 vertices) at the documented 44-byte
## stride produced NaN values and wildly non-unit-length normals starting
## at vertex 1 -- but at 52 bytes, all 676 real vertices decode with a
## unit-length normal and no NaNs, and the resulting mesh's own computed
## vertex bounds land exactly on the file's own declared bounding box. No
## real per-file flag distinguishing the two sizes has been found, so
## _detect_vertex_rec_size picks whichever real size makes every vertex's
## normal come out unit-length -- the same self-validating technique
## already used for .m's two real per-vertex sizes (see MapmReader's own
## detect_vertex_size). See docs/protocol/BMS_FORMAT.md.
const VERTEX_REC_SIZE_CANDIDATES := [44, 52]

## Header offset of the real pointer to the object's own navigation/collision
## mesh -- the real walkable surface the client's own navmesh code uses for
## a placed object (stairs, floors, bridges), as opposed to the render
## geometry the rest of this parser reads. Recovered 2026-09-05; see
## docs/protocol/BMS_FORMAT.md's "Collision section" for the derivation.
## Zero in the great majority of real files (character parts, decoration and
## anything the player can't stand on): 507 of 4,395 real meshes sampled
## across a real Data.pk2 carry one.
const COLLISION_PTR_OFFSET := 0x28
## Header offset of the real per-file bitfield that selects the collision
## section's real record sizes. Each bit was isolated independently, by
## finding real files that set it without the others (see the mask
## constants below).
const COLLISION_FLAGS_OFFSET := 0x38
## Real bit 0: each real edge record carries one extra trailing byte
## (10 bytes instead of 9).
const COLLISION_FLAG_WIDE_EDGE := 0x1
## Real bit 1: each real cell record carries one extra trailing byte
## (9 bytes instead of 8).
const COLLISION_FLAG_WIDE_CELL := 0x2
## Real bit 2: a real list of length-prefixed event names follows the edge
## lists, before the lookup grid.
const COLLISION_FLAG_HAS_EVENTS := 0x4
const COLLISION_VERTEX_REC_SIZE := 13

## One real vertex of an object's own navigation mesh. The real flag byte's
## meaning is not established -- it is carried through unparsed rather than
## guessed at.
class CollisionVertex:
	var position: Vector3
	var flags: int

## One real navigable triangle of an object's own navigation mesh, as three
## real indices into CollisionMesh.vertices.
class CollisionCell:
	var a: int
	var b: int
	var c: int

## One real navigation edge bounding a CollisionCell. Real semantics are
## identical to the terrain .nvm's own edges (see NvmReader.Edge and
## docs/protocol/NVM_FORMAT.md): an edge in outline_edges always has
## cell_to == NO_CELL and blocks, an edge in internal_edges always joins two
## real cells and is passable.
class CollisionEdge:
	var v0: int
	var v1: int
	var cell_from: int
	var cell_to: int
	var flags: int

## One real object-local navigation mesh, read from the real section at
## COLLISION_PTR_OFFSET.
class CollisionMesh:
	var vertices: Array[CollisionVertex] = []
	var cells: Array[CollisionCell] = []
	## Real boundary edges: every one carries NO_CELL on its far side.
	var outline_edges: Array[CollisionEdge] = []
	## Real interior edges: every one joins two real cells.
	var internal_edges: Array[CollisionEdge] = []
	## Real length-prefixed event names, present only when
	## COLLISION_FLAG_HAS_EVENTS is set (empty otherwise). Carried through
	## unparsed -- what the client does with them isn't established.
	var events: Array[String] = []
	## Real origin (x, z) of the lookup grid below.
	var grid_origin: Vector2
	var grid_width: int
	var grid_height: int
	## Real row-major grid_width * grid_height lists of real indices into
	## cells -- a real spatial lookup acceleration structure. Read (rather
	## than skipped) because it is what makes the section's real length
	## self-checking: the parse lands exactly on the file's end.
	var grid_cells: Array[PackedInt32Array] = []

## The real "no cell on this side" sentinel, shared with the terrain .nvm.
const NO_CELL := 0xFFFF

class Vertex:
	var position: Vector3
	var normal: Vector3
	var uv: Vector2
	## The trailing bytes at record offset 0x20 onward (12 or 20 bytes,
	## depending on the real per-file record size -- see
	## VERTEX_REC_SIZE_CANDIDATES), not confirmed to have consistent
	## per-vertex meaning -- see docs/protocol/BMS_FORMAT.md.
	var extra: PackedByteArray

class ParsedMesh:
	var mesh_name: String
	var material_name: String
	var vertices: Array[Vertex] = []
	## Flat triangle list; size is always a multiple of 3.
	var indices: PackedInt32Array = PackedInt32Array()
	var bounds_min: Vector3
	var bounds_max: Vector3

## Parses a .bms file's raw bytes. Returns null (and pushes an error) on
## failure.
static func parse(data: PackedByteArray) -> ParsedMesh:
	if data.size() < PREAMBLE_END:
		push_error("bms: file too small to contain a header")
		return null
	var magic := data.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		push_error("bms: bad magic %s, want %s" % [magic, MAGIC])
		return null

	var hdr := PackedInt32Array()
	hdr.resize(6)
	for i in range(6):
		hdr[i] = _le_u32(data, HEADER_PTRS_BASE + i * 4)

	var off := PREAMBLE_END
	var name_result := _read_len_prefixed_string(data, off)
	if name_result == null:
		push_error("bms: reading name")
		return null
	var name: String = name_result[0]
	off = name_result[1]

	var material_result := _read_len_prefixed_string(data, off)
	if material_result == null:
		push_error("bms: reading material name")
		return null
	var material_name: String = material_result[0]
	off = material_result[1]

	if off + 8 > data.size():
		push_error("bms: truncated before vertex count")
		return null
	off += 4 # unconfirmed u32, observed values 12/92/5/0 -- not a reliable signal, see VERTEX_REC_SIZE_CANDIDATES
	var vertex_count := _le_u32(data, off)
	off += 4

	var vertex_rec_size := _detect_vertex_rec_size(data, off, vertex_count, hdr[1])
	if vertex_rec_size == -1:
		push_error("bms: vertex array (count=%d) doesn't fit in the file at any known real record size" % vertex_count)
		return null

	var vertex_end := off + vertex_count * vertex_rec_size
	if vertex_end > data.size():
		push_error("bms: vertex array (count=%d) runs past end of file" % vertex_count)
		return null

	var mesh := ParsedMesh.new()
	mesh.mesh_name = name
	mesh.material_name = material_name

	for i in range(vertex_count):
		var rec_off := off + i * vertex_rec_size
		var v := Vertex.new()
		v.position = Vector3(_le_f32(data, rec_off), _le_f32(data, rec_off + 4), _le_f32(data, rec_off + 8))
		v.normal = Vector3(_le_f32(data, rec_off + 0x0c), _le_f32(data, rec_off + 0x10), _le_f32(data, rec_off + 0x14))
		v.uv = Vector2(_le_f32(data, rec_off + 0x18), _le_f32(data, rec_off + 0x1c))
		v.extra = data.slice(rec_off + 0x20, rec_off + vertex_rec_size)
		mesh.vertices.append(v)

	var index_off := hdr[1]
	if index_off + 4 > data.size():
		push_error("bms: index section offset (hdr[1]) out of range")
		return null
	var tri_count := _le_u32(data, index_off)
	var index_start := index_off + 4
	var index_end := index_start + tri_count * INDEX_REC_SIZE
	if index_end > data.size():
		push_error("bms: index array (triangles=%d) runs past end of file" % tri_count)
		return null
	mesh.indices.resize(tri_count * 3)
	for i in range(tri_count * 3):
		mesh.indices[i] = _le_u16(data, index_start + i * 2)

	var bbox_off := hdr[4]
	if bbox_off + 24 <= data.size():
		mesh.bounds_min = Vector3(_le_f32(data, bbox_off), _le_f32(data, bbox_off + 4), _le_f32(data, bbox_off + 8))
		mesh.bounds_max = Vector3(_le_f32(data, bbox_off + 12), _le_f32(data, bbox_off + 16), _le_f32(data, bbox_off + 20))

	return mesh

## Parses the real object navigation/collision mesh a .bms may carry (see
## COLLISION_PTR_OFFSET). Returns null when the real file has no such
## section -- the common case, and not an error. Returns null and pushes an
## error when a section is present but doesn't decode.
##
## Like NvmReader.parse, this is fully deterministic and self-checking: every
## count is real and self-describing, and the whole section, read in order,
## lands exactly on the real end of the file. Verified against 507 real
## collision sections found in a 4,395-file real sample of a real Data.pk2 --
## all 507 land exactly on the end with zero leftover bytes, at the record
## sizes COLLISION_FLAGS_OFFSET's real bitfield selects.
static func parse_collision(data: PackedByteArray) -> CollisionMesh:
	if data.size() < PREAMBLE_END:
		return null
	var magic := data.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		return null
	var start := _le_u32(data, COLLISION_PTR_OFFSET)
	if start == 0:
		return null # real, valid: this mesh has no navigation data
	if start < PREAMBLE_END or start >= data.size():
		push_error("bms: collision section offset %d out of range" % start)
		return null

	var flags := _le_u32(data, COLLISION_FLAGS_OFFSET)
	var cell_rec_size := 9 if (flags & COLLISION_FLAG_WIDE_CELL) != 0 else 8
	var edge_rec_size := 10 if (flags & COLLISION_FLAG_WIDE_EDGE) != 0 else 9

	var cm := CollisionMesh.new()
	var off := start

	var vertex_count := _le_u32(data, off)
	off += 4
	if off + vertex_count * COLLISION_VERTEX_REC_SIZE > data.size():
		push_error("bms: collision vertex array (count=%d) runs past end of file" % vertex_count)
		return null
	for i in range(vertex_count):
		var rec := off + i * COLLISION_VERTEX_REC_SIZE
		var v := CollisionVertex.new()
		v.position = Vector3(_le_f32(data, rec), _le_f32(data, rec + 4), _le_f32(data, rec + 8))
		v.flags = data[rec + 12]
		cm.vertices.append(v)
	off += vertex_count * COLLISION_VERTEX_REC_SIZE

	if off + 4 > data.size():
		push_error("bms: truncated before collision cell count")
		return null
	var cell_count := _le_u32(data, off)
	off += 4
	if off + cell_count * cell_rec_size > data.size():
		push_error("bms: collision cell array (count=%d) runs past end of file" % cell_count)
		return null
	for i in range(cell_count):
		var rec := off + i * cell_rec_size
		var cell := CollisionCell.new()
		cell.a = _le_u16(data, rec)
		cell.b = _le_u16(data, rec + 2)
		cell.c = _le_u16(data, rec + 4)
		if cell.a >= vertex_count or cell.b >= vertex_count or cell.c >= vertex_count:
			push_error("bms: collision cell %d indexes a vertex outside the real array" % i)
			return null
		cm.cells.append(cell)
	off += cell_count * cell_rec_size

	for list_index in range(2):
		if off + 4 > data.size():
			push_error("bms: truncated before a collision edge count")
			return null
		var edge_count := _le_u32(data, off)
		off += 4
		if off + edge_count * edge_rec_size > data.size():
			push_error("bms: collision edge array (count=%d) runs past end of file" % edge_count)
			return null
		for i in range(edge_count):
			var rec := off + i * edge_rec_size
			var edge := CollisionEdge.new()
			edge.v0 = _le_u16(data, rec)
			edge.v1 = _le_u16(data, rec + 2)
			edge.cell_from = _le_u16(data, rec + 4)
			edge.cell_to = _le_u16(data, rec + 6)
			edge.flags = data[rec + 8]
			if list_index == 0:
				cm.outline_edges.append(edge)
			else:
				cm.internal_edges.append(edge)
		off += edge_count * edge_rec_size

	if (flags & COLLISION_FLAG_HAS_EVENTS) != 0:
		if off + 4 > data.size():
			push_error("bms: truncated before collision event count")
			return null
		var event_count := _le_u32(data, off)
		off += 4
		for _i in range(event_count):
			var name_result := _read_len_prefixed_string(data, off)
			if name_result == null:
				push_error("bms: reading a collision event name")
				return null
			cm.events.append(name_result[0])
			off = name_result[1]

	if off + 20 > data.size():
		push_error("bms: truncated before the collision lookup grid")
		return null
	cm.grid_origin = Vector2(_le_f32(data, off), _le_f32(data, off + 4))
	cm.grid_width = _le_u32(data, off + 8)
	cm.grid_height = _le_u32(data, off + 12)
	var grid_total := _le_u32(data, off + 16)
	off += 20
	if grid_total != cm.grid_width * cm.grid_height:
		push_error("bms: collision grid says %d cells but is %dx%d" % [grid_total, cm.grid_width, cm.grid_height])
		return null
	for _i in range(grid_total):
		if off + 4 > data.size():
			push_error("bms: truncated reading a collision grid list")
			return null
		var n := _le_u32(data, off)
		off += 4
		if off + n * 2 > data.size():
			push_error("bms: a collision grid list runs past end of file")
			return null
		var list := PackedInt32Array()
		list.resize(n)
		for j in range(n):
			list[j] = _le_u16(data, off + j * 2)
		off += n * 2
		cm.grid_cells.append(list)

	if off != data.size():
		push_error("bms: collision section parsed %d bytes but file is %d" % [off, data.size()])
		return null

	return cm

## Builds a renderable Godot ArrayMesh from a parsed Mesh.
static func to_array_mesh(mesh: ParsedMesh) -> ArrayMesh:
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	positions.resize(mesh.vertices.size())
	normals.resize(mesh.vertices.size())
	uvs.resize(mesh.vertices.size())
	for i in range(mesh.vertices.size()):
		positions[i] = mesh.vertices[i].position
		normals[i] = mesh.vertices[i].normal
		uvs[i] = mesh.vertices[i].uv

	# **Winding reversed 2026-09-02** (see docs/WORLD_ISSUES.md's
	# forty-seventh round). The real .bms index buffer lists each triangle's
	# three vertices in the opposite order from the front-face winding Godot
	# expects, so feeding it through unchanged made every real object render
	# inside-out: with normal back-face culling on, a real building's
	# outward-facing surfaces were culled and only its interior showed,
	# which is what made real buildings and creatures look broken. Proved
	# with a real controlled render of a real building (`cj_sugi_house_01`):
	# unchanged it renders as a sparse skeleton of poles with no walls or
	# roof; with culling forced off it renders as a complete, correct
	# thatched hut; and with the winding reversed it renders as that same
	# correct hut *with normal culling still enabled* -- i.e. the geometry
	# was always right and only the winding was wrong. Reversing here rather
	# than disabling culling keeps real back-face culling doing its job.
	# Per-vertex normals come from the real file, not from winding, so
	# lighting is unaffected by this.
	var indices := PackedInt32Array()
	indices.resize(mesh.indices.size())
	for i in range(0, mesh.indices.size() - 2, 3):
		indices[i] = mesh.indices[i]
		indices[i + 1] = mesh.indices[i + 2]
		indices[i + 2] = mesh.indices[i + 1]

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return array_mesh

## Picks whichever real candidate size in VERTEX_REC_SIZE_CANDIDATES makes
## every one of vertex_count real vertices starting at off decode a real,
## plausible unit-length normal (see VERTEX_REC_SIZE_CANDIDATES's doc
## comment for the real evidence this is based on) -- the same
## self-validating approach MapmReader's own detect_vertex_size uses for
## that format's own two real per-vertex sizes. Returns -1 if vertex_count
## doesn't fit in the file (and before index_off, when known) at either
## candidate size.
static func _detect_vertex_rec_size(data: PackedByteArray, off: int, vertex_count: int, index_off: int) -> int:
	var best_size := -1
	var best_bad := -1
	for size_variant in VERTEX_REC_SIZE_CANDIDATES:
		var size: int = size_variant
		var end: int = off + vertex_count * size
		if end > data.size() or (index_off > 0 and end > index_off):
			continue
		var bad := 0
		for i in range(vertex_count):
			var rec_off := off + i * size
			var nx := _le_f32(data, rec_off + 0x0c)
			var ny := _le_f32(data, rec_off + 0x10)
			var nz := _le_f32(data, rec_off + 0x14)
			var length := sqrt(nx * nx + ny * ny + nz * nz)
			if is_nan(length) or length < 0.9 or length > 1.1:
				bad += 1
		if best_bad == -1 or bad < best_bad:
			best_bad = bad
			best_size = size
	return best_size

static func _read_len_prefixed_string(data: PackedByteArray, off: int) -> Array:
	if off + 4 > data.size():
		return []
	var n := _le_u32(data, off)
	off += 4
	if n < 0 or off + n > data.size():
		return []
	return [data.slice(off, off + n).get_string_from_ascii(), off + n]

static func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)

static func _le_u16(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8)

static func _le_f32(b: PackedByteArray, off: int) -> float:
	var bytes := b.slice(off, off + 4)
	return bytes.decode_float(0)
