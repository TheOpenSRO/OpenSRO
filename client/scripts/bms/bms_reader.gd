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
