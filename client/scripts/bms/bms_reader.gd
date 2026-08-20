extends RefCounted
class_name BmsReader

## Read-only parser for the .bms (JMXVBMS) mesh geometry format.
## See docs/protocol/BMS_FORMAT.md for the on-disk layout. Mirrors
## server/internal/bms's Go implementation; keep the two in sync if the
## format understanding changes.

const MAGIC := "JMXVBMS 0110"
const MAGIC_LEN := 12
const PREAMBLE_END := 0x48
const VERTEX_REC_SIZE := 44
const INDEX_REC_SIZE := 6
const HEADER_PTRS_BASE := 0x10

class Vertex:
	var position: Vector3
	var normal: Vector3
	var uv: Vector2
	## The 12 bytes at record offset 0x20-0x2B, not confirmed to have
	## consistent per-vertex meaning -- see docs/protocol/BMS_FORMAT.md.
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
	off += 4 # unconfirmed u32, observed constant 1
	var vertex_count := _le_u32(data, off)
	off += 4

	var vertex_end := off + vertex_count * VERTEX_REC_SIZE
	if vertex_end > data.size():
		push_error("bms: vertex array (count=%d) runs past end of file" % vertex_count)
		return null

	var mesh := ParsedMesh.new()
	mesh.mesh_name = name
	mesh.material_name = material_name

	for i in range(vertex_count):
		var rec_off := off + i * VERTEX_REC_SIZE
		var v := Vertex.new()
		v.position = Vector3(_le_f32(data, rec_off), _le_f32(data, rec_off + 4), _le_f32(data, rec_off + 8))
		v.normal = Vector3(_le_f32(data, rec_off + 0x0c), _le_f32(data, rec_off + 0x10), _le_f32(data, rec_off + 0x14))
		v.uv = Vector2(_le_f32(data, rec_off + 0x18), _le_f32(data, rec_off + 0x1c))
		v.extra = data.slice(rec_off + 0x20, rec_off + 0x2c)
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

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = mesh.indices

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return array_mesh

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
