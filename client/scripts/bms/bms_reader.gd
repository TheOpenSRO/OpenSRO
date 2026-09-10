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

## Full weight in the on-disk 16-bit weight fields. A vertex bound entirely
## to one bone reads 65535; a 50/50 blend reads 32765 twice.
const WEIGHT_FULL_SCALE := 65535.0
## Sentinel in the second bone slot meaning "only one influence".
const NO_BONE := 255
## Size of one per-vertex skin record: u8 bone0, u16 weight0, u8 bone1,
## u16 weight1.
const SKIN_REC_SIZE := 6

class Vertex:
	var position: Vector3
	var normal: Vector3
	var uv: Vector2
	## Palette indices into ParsedMesh.bone_names, and their weights,
	## normalised to sum to 1. bone1 is -1 when the vertex has a single
	## influence.
	var bone0: int = -1
	var bone1: int = -1
	var weight0: float = 0.0
	var weight1: float = 0.0
	## The trailing bytes at record offset 0x20 onward (12 or 20 bytes,
	## depending on the real per-file record size -- see
	## VERTEX_REC_SIZE_CANDIDATES), not confirmed to have consistent
	## per-vertex meaning -- see docs/protocol/BMS_FORMAT.md.
	var extra: PackedByteArray

class ParsedMesh:
	var mesh_name: String
	var material_name: String
	## The skeleton bones this mesh is weighted to, in the order its vertex
	## bone indices refer to. Empty for scenery, which carries no skin.
	var bone_names: PackedStringArray = PackedStringArray()

	## True when every vertex carries a usable bone weight.
	func is_skinned() -> bool:
		return not bone_names.is_empty()
	var vertices: Array[Vertex] = []
	## Flat triangle list; size is always a multiple of 3.
	var indices: PackedInt32Array = PackedInt32Array()
	var bounds_min: Vector3
	var bounds_max: Vector3

	## Per-vertex free-movement amounts from the `hdr[2]` section, parallel
	## to `vertices` and empty in the 24,183 of 24,984 real meshes that
	## carry no such section. See parse_vertex_motion.
	var vertex_motion: PackedFloat32Array = PackedFloat32Array()
	## Parallel to vertex_motion: true where the file marks the vertex
	## pinned. Exactly the vertices whose amount is zero, in every one of
	## the 316,452 records measured.
	var vertex_pinned: PackedByteArray = PackedByteArray()

	## Pairs of vertex indices from the `hdr[3]` section, flattened: link i
	## joins `vertex_links[i * 2]` to `vertex_links[i * 2 + 1]`.
	var vertex_links: PackedInt32Array = PackedInt32Array()
	## Parallel to the pairs above, one distance per link.
	var vertex_link_lengths: PackedFloat32Array = PackedFloat32Array()
	## One link index per link, following the records. Every value is a
	## valid index into the links themselves, in all 801 real meshes that
	## carry the section -- an ordering over them. What the order is *for*
	## is not established.
	var vertex_link_order: PackedInt32Array = PackedInt32Array()

## Header offset of the per-vertex section decoded in
## docs/protocol/BMS_FORMAT.md: a count followed by one `float32` +
## `uint32` per vertex.
##
## Confirmed in the client: `CPrimGeometry`'s reader takes a count and reads
## `count * 8` bytes, and resizes the vector it reads into with a default of
## `(1.0f, 0)` -- which is the field split, from the client rather than from
## the byte pattern.
const VERTEX_MOTION_PTR_OFFSET := HEADER_PTRS_BASE + 2 * 4
const VERTEX_MOTION_REC_SIZE := 8

## Header offset of the link section: a count followed by that many
## 12-byte records, each two vertex indices and a `float32` distance.
## Verified across 801 real meshes and 58,433 records -- every index inside
## the mesh's own vertex count and every distance positive -- and confirmed
## in the client, which reads `count * 0xc` bytes and resizes with a default
## of `(-1, -1, 0.0f)`: two index fields whose "unset" value is -1. See
## docs/protocol/BMS_FORMAT.md.
const VERTEX_LINK_PTR_OFFSET := HEADER_PTRS_BASE + 3 * 4
const VERTEX_LINK_REC_SIZE := 12

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

	# The skin section: a bone palette followed by one weight record per
	# vertex, running from hdr[0] up to the index section at hdr[1].
	#
	# **This is what "no per-vertex skinning data exists" missed.** That
	# conclusion came from accounting for the 44-byte vertex record and
	# finding no room left in it -- which is true, and irrelevant, because
	# the weights are not in the vertex record. They are in their own
	# section, and hdr[0] points at it. See docs/protocol/BMS_FORMAT.md.
	_parse_skin(data, hdr[0], hdr[1], vertex_count, mesh)

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

	_parse_vertex_motion(data, mesh)
	_parse_vertex_links(data, mesh)
	return mesh

## Reads the `hdr[3]` section: a count, then that many (vertex, vertex,
## distance) records.
##
## Read for the same reason as the section above, and validated the same
## way: both indices must be inside the mesh's own vertex count and the
## distance must be positive, which is what says the 12-byte split is in
## the right place. Across 801 real meshes and 58,433 records not one
## violates either, so a file that does is a file this reader has
## misunderstood, and it is left alone rather than half-read.
##
## The section is `4 + count * 16 + 36` bytes long -- the count, the
## records, one index word per link, and 36 bytes whose contents are not
## established. That arithmetic lands exactly on the next section in all
## 801 real meshes that carry one, and the client reads it in the same
## three pieces: `count * 0xc`, then `count * 4`, then `0x24` bytes taken
## inline rather than into an array, which is why the tail never varies.
static func _parse_vertex_links(data: PackedByteArray, mesh: ParsedMesh) -> void:
	var start := _le_u32(data, VERTEX_LINK_PTR_OFFSET)
	if start == 0 or start + 4 > data.size():
		return
	var count := _le_u32(data, start)
	if count == 0 or start + 4 + count * VERTEX_LINK_REC_SIZE > data.size():
		return
	var vertex_count := mesh.vertices.size()
	var links := PackedInt32Array()
	var lengths := PackedFloat32Array()
	links.resize(count * 2)
	lengths.resize(count)
	for i in range(count):
		var rec := start + 4 + i * VERTEX_LINK_REC_SIZE
		var a := _le_u32(data, rec)
		var b := _le_u32(data, rec + 4)
		var d := _le_f32(data, rec + 8)
		if a >= vertex_count or b >= vertex_count or not (d > 0.0):
			return # not the structure this reader thinks it is
		links[i * 2] = a
		links[i * 2 + 1] = b
		lengths[i] = d
	mesh.vertex_links = links
	mesh.vertex_link_lengths = lengths

	# One word per link follows the records, each a valid link index.
	var order_at := start + 4 + count * VERTEX_LINK_REC_SIZE
	if order_at + count * 4 > data.size():
		return
	var order := PackedInt32Array()
	order.resize(count)
	for i in range(count):
		var v := _le_u32(data, order_at + i * 4)
		if v >= count:
			return # leaves the order empty; the links themselves stand
		order[i] = v
	mesh.vertex_link_order = order

## Reads the `hdr[2]` section: one `float32` + `uint32` per vertex.
##
## Nothing renders with this yet. It is read because it is decoded --
## leaving a known section unparsed is how this format's skinning stayed
## hidden for months, and a reader that carries the data is a reader whose
## understanding can be tested. See docs/protocol/BMS_FORMAT.md for the
## measurement: over all 24,984 real meshes in a Data.pk2, 801 carry this
## section, the count equals the vertex count in every one of them, the
## float takes 16 values on a 0.05 ladder, and the integer is 1 in exactly
## the records whose float is zero.
##
## Leaves both arrays empty, without erroring, whenever the section is
## absent or does not fit: 24,183 meshes carry none at all, and 450 have a
## pointer whose declared count runs past the end of the file -- one of them
## claims four billion records, which exhausts memory if believed.
static func _parse_vertex_motion(data: PackedByteArray, mesh: ParsedMesh) -> void:
	var start := _le_u32(data, VERTEX_MOTION_PTR_OFFSET)
	if start == 0 or start + 4 > data.size():
		return
	var count := _le_u32(data, start)
	if count != mesh.vertices.size():
		return
	if start + 4 + count * VERTEX_MOTION_REC_SIZE > data.size():
		return
	mesh.vertex_motion.resize(count)
	mesh.vertex_pinned.resize(count)
	for i in range(count):
		var rec := start + 4 + i * VERTEX_MOTION_REC_SIZE
		mesh.vertex_motion[i] = _le_f32(data, rec)
		mesh.vertex_pinned[i] = 1 if _le_u32(data, rec + 4) != 0 else 0

## Reads the bone palette and per-vertex weights between section_start and
## section_end. Leaves the mesh unskinned, without erroring, whenever the
## section is absent or does not fit -- scenery has no skin, and that is the
## common case rather than a fault.
static func _parse_skin(
	data: PackedByteArray, section_start: int, section_end: int,
	vertex_count: int, mesh: ParsedMesh
) -> void:
	if section_start <= 0 or section_start + 4 > data.size() or section_end > data.size():
		return
	var bone_count := _le_u32(data, section_start)
	if bone_count <= 0 or bone_count > 512:
		return
	var off := section_start + 4
	var names := PackedStringArray()
	for i in range(bone_count):
		if off + 4 > data.size():
			return
		var n := _le_u32(data, off)
		off += 4
		if n <= 0 or n > 128 or off + n > data.size():
			return
		names.append(data.slice(off, off + n).get_string_from_ascii())
		off += n

	# The weights must exactly fill what is left of the section. Requiring
	# that, rather than reading hopefully from wherever the names ended, is
	# what stops a misread palette producing plausible-looking nonsense.
	if section_end - off != vertex_count * SKIN_REC_SIZE:
		return

	for i in range(vertex_count):
		var rec := off + i * SKIN_REC_SIZE
		var b0 := data[rec]
		var w0 := float(data[rec + 1] | (data[rec + 2] << 8))
		var b1 := data[rec + 3]
		var w1 := float(data[rec + 4] | (data[rec + 5] << 8))
		if b0 >= names.size():
			return # a bad index means this isn't the palette we think it is
		var v: Vertex = mesh.vertices[i]
		v.bone0 = b0
		v.bone1 = b1 if b1 != NO_BONE and b1 < names.size() else -1
		# Normalised rather than trusted: most vertices sum to full scale
		# exactly, but a few percent of a real file's do not (measured: 8 of
		# 280 in chinaquest_priest_part1, worst 33% off), and an
		# unnormalised weight stretches the vertex it belongs to.
		var total := w0 + (w1 if v.bone1 != -1 else 0.0)
		if total <= 0.0:
			v.bone0 = -1
			v.bone1 = -1
			continue
		v.weight0 = w0 / total
		v.weight1 = (w1 / total) if v.bone1 != -1 else 0.0
	mesh.bone_names = names

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

	# Skin weights, when the file carries them. Godot wants four influences
	# per vertex; the format supplies at most two, so the spare pair is
	# weighted zero. The bone indices are palette indices -- a Skin resource
	# maps them onto the actual skeleton (see Skeleton3DBuilder.build_skin).
	if mesh.is_skinned():
		var bones := PackedInt32Array()
		var weights := PackedFloat32Array()
		bones.resize(mesh.vertices.size() * 4)
		weights.resize(mesh.vertices.size() * 4)
		for i in range(mesh.vertices.size()):
			var v: Vertex = mesh.vertices[i]
			var base := i * 4
			# A vertex the skin parser rejected falls back to the first
			# palette bone at full weight: better a piece that follows one
			# bone than one that collapses to the origin.
			bones[base] = maxi(v.bone0, 0)
			weights[base] = v.weight0 if v.bone0 >= 0 else 1.0
			bones[base + 1] = maxi(v.bone1, 0)
			weights[base + 1] = v.weight1 if v.bone1 >= 0 else 0.0
			bones[base + 2] = 0
			weights[base + 2] = 0.0
			bones[base + 3] = 0
			weights[base + 3] = 0.0
		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = weights

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
