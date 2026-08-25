extends RefCounted
class_name BsrReader

## Read-only parser for the .bsr (JMXVRES) "static object" resource format.
## See docs/protocol/BSR_FORMAT.md for the on-disk layout. Mirrors
## server/internal/bsr's Go implementation; keep the two in sync if the
## format understanding changes.

const MAGIC := "JMXVRES 0109"
const MAGIC_LEN := 12
const PREAMBLE_END := 0x44
const MAX_PATH_LEN := 512

class ParsedObject:
	var object_name: String
	var mesh_path: String
	var material_path: String
	var sub_mesh_paths: Array[String] = []
	var has_bounds: bool = false
	var bounds_min: Vector3
	var bounds_max: Vector3

## Parses a .bsr file's raw bytes. Returns null (and pushes an error) on
## failure -- including the known edge case of a file with an empty mesh
## path (see docs/protocol/BSR_FORMAT.md).
static func parse(data: PackedByteArray) -> ParsedObject:
	if data.size() < PREAMBLE_END:
		push_error("bsr: file too small to contain a header")
		return null
	var magic := data.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		push_error("bsr: bad magic %s, want %s" % [magic, MAGIC])
		return null

	var off := PREAMBLE_END
	var name_result = _read_len_prefixed_string(data, off)
	if name_result == null:
		push_error("bsr: reading name")
		return null
	var name: String = name_result[0]
	off = name_result[1]

	# The exact byte layout between the name and the mesh/material paths
	# isn't fully understood (a fixed-looking header field that should
	# point at the mesh path turned out not to, in at least one real
	# file) -- so instead of trusting an offset, scan forward for the
	# first plausible length-prefixed path string. Real files were also
	# found to genuinely differ in *field order*: "building"-category
	# files (res\bldg\...) put the mesh path first, then the bounding box,
	# then the material path; "nature"-category files (res\nature\...,
	# e.g. vegetation/scatter objects) put the bounding box and material
	# path first, with the mesh path last -- see
	# docs/protocol/BSR_FORMAT.md. Scanning independently for the first
	# string ending in ".bms" and the first ending in ".bmt" (not
	# "whichever plausible string comes first, unconditionally called the
	# mesh path") finds the right field either way, since it doesn't
	# assume an order.
	var mesh_off := _scan_for_path_string_with_suffix(data, off, ".bms")
	var mat_off := _scan_for_path_string_with_suffix(data, off, ".bmt")
	if mat_off < 0:
		push_error("bsr: couldn't locate material path")
		return null

	var mat_result = _read_len_prefixed_string(data, mat_off)
	if mat_result == null:
		push_error("bsr: reading material path")
		return null
	var material_path: String = mat_result[0]
	var mat_end: int = mat_result[1]

	if mesh_off < 0:
		# A real, genuine mesh-less variant, not a parse failure: real
		# "*_particle.bsr" files (e.g. wreck_sship_particle.bsr, placed
		# over 1,200 times combined across a real client's map data --
		# found auditing this project's own full real object catalog,
		# 2026-08-25) carry a real material plus one or more real .efp
		# particle-effect references instead of any .bms mesh at all --
		# they're invisible particle-emitter markers, not scenery with a
		# missing/corrupt mesh. Returning a real ParsedObject with an empty
		# mesh_path (same "empty is a real, valid value" treatment
		# material_path already gets) lets a caller render just the real
		# particle effect (once this project has a real .efp renderer) or
		# skip the object's visual entirely, instead of treating every one
		# of these as a hard failure.
		var particle_obj := ParsedObject.new()
		particle_obj.object_name = name
		particle_obj.material_path = material_path
		return particle_obj

	var mesh_result = _read_len_prefixed_string(data, mesh_off)
	if mesh_result == null:
		push_error("bsr: reading mesh path")
		return null
	var mesh_path: String = mesh_result[0]
	var mesh_end: int = mesh_result[1]

	var obj := ParsedObject.new()
	obj.object_name = name
	obj.mesh_path = mesh_path
	obj.material_path = material_path

	if mesh_off >= mat_off:
		# Nature-category order (material, then mesh) -- confirmed real,
		# but nothing past the mesh path is understood for this layout
		# yet (no confirmed bounding-box position or sub-mesh-list
		# convention), so this is where a real file's real data ends as
		# far as this reader is concerned. Not guessed at.
		return obj

	# Building-category order (mesh, then material): best-effort bounding
	# box, observed as 6 floats (min xyz, max xyz) at the very start of
	# the gap between the mesh path and the material path in most real
	# files checked -- but not confirmed in all of them, so this is
	# skipped rather than guessed at when the gap is too short.
	var gap := mat_off - mesh_end
	if gap >= 24:
		obj.bounds_min = Vector3(_le_f32(data, mesh_end), _le_f32(data, mesh_end + 4), _le_f32(data, mesh_end + 8))
		obj.bounds_max = Vector3(_le_f32(data, mesh_end + 12), _le_f32(data, mesh_end + 16), _le_f32(data, mesh_end + 20))
		obj.has_bounds = true

	off = mat_end
	if off + 4 > data.size():
		return obj

	var sub_count := _le_u32(data, off)
	off += 4
	if sub_count > 1000:
		return obj

	# A real, larger multi-piece building (2026-08-23: found live-testing
	# real Jangan palace buildings, the first real content this project had
	# tested with more than a couple of sub-mesh pieces) can have its
	# declared sub_count not exactly match how many further length-prefixed
	# strings are actually still real path-shaped data -- the exact real
	# cause isn't confirmed (a real trailing per-piece field this project's
	# simpler samples never had enough pieces to expose, most likely).
	# Previously this failed the *entire* object, discarding the already-
	# confirmed-real primary mesh_path/material_path along with it over one
	# bad trailing sub-piece -- a disproportionate real failure mode. Now
	# it keeps whatever real sub-mesh paths parsed successfully and stops,
	# same "return the real partial result rather than nothing" precedent
	# already used elsewhere in this reader (see the nature-category
	# early-return above).
	for i in range(sub_count):
		var sub_result = _read_len_prefixed_string(data, off)
		if sub_result == null:
			push_error("bsr: reading sub-mesh path %d/%d -- keeping the %d real sub-mesh(es) already parsed" % [i + 1, sub_count, obj.sub_mesh_paths.size()])
			break
		var sub_path: String = sub_result[0]
		off = sub_result[1]
		# A real sub-mesh path that isn't a plausible ".bms" path (2026-08-23:
		# found live-testing real Jangan-adjacent trees) is never a real,
		# usable sub-mesh reference -- no real file has an empty name or a
		# single stray byte like "6" as a mesh path. It means the true real
		# sub-mesh list already ended and this read has spilled into the
		# file's own trailing boilerplate (the fixed 20-byte block +
		# "default" string documented above), which can contain real byte
		# sequences that happen to parse as a valid-looking but wrong
		# length-prefixed string rather than failing outright (an exactly
		# empty string from `tre_bank02.bsr`; a single real byte "6" from
		# `tre_maple01.bsr`). Stop here, same as a real read failure,
		# rather than recording a sub-mesh path `ObjectLoader` can never
		# resolve.
		if not (_is_plausible_path(sub_path.to_ascii_buffer()) and sub_path.to_lower().ends_with(".bms")):
			break
		obj.sub_mesh_paths.append(sub_path)

	return obj

## Looks for the next plausible length-prefixed path string starting at or
## after off whose content ends with suffix (case-insensitive -- real
## paths use inconsistent casing throughout this project's data),
## returning its offset. Filtering by suffix (rather than accepting the
## first plausible string unconditionally) is what lets one scan
## correctly find the mesh path or material path regardless of which
## order a real file puts them in.
static func _scan_for_path_string_with_suffix(data: PackedByteArray, off: int, suffix: String) -> int:
	var pos := off
	while pos + 4 <= data.size():
		var n := _le_u32(data, pos)
		if n > 0 and n <= MAX_PATH_LEN and pos + 4 + n <= data.size():
			var candidate := data.slice(pos + 4, pos + 4 + n)
			if _is_plausible_path(candidate) and candidate.get_string_from_ascii().to_lower().ends_with(suffix):
				return pos
		pos += 1
	return -1

static func _is_plausible_path(b: PackedByteArray) -> bool:
	if b.size() == 0:
		return false
	for c in b:
		var is_alnum := (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57)
		var is_extra := c == 92 or c == 46 or c == 95 or c == 45 or c == 32 # \ . _ - space
		if not (is_alnum or is_extra):
			return false
	return true

static func _read_len_prefixed_string(data: PackedByteArray, off: int):
	if off + 4 > data.size():
		return null
	var n := _le_u32(data, off)
	off += 4
	if n < 0 or off + n > data.size():
		return null
	return [data.slice(off, off + n).get_string_from_ascii(), off + n]

static func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)

static func _le_f32(b: PackedByteArray, off: int) -> float:
	return b.slice(off, off + 4).decode_float(0)
