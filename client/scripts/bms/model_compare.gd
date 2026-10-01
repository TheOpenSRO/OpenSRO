extends RefCounted
class_name ModelCompare

## Deep, bit-exact comparison of two parses of the same model file -- the
## GDScript reader's and the native one's (round 669) -- for
## client/tools/native_parity.gd's model pass and native_models_test.gd.
## Every float is compared by its bit pattern (var_to_bytes), so a NaN
## matches only the same NaN and -0.0 never matches 0.0. Each returns "" when
## the two agree, or the first difference.

static func _bits(v: Variant) -> PackedByteArray:
	return var_to_bytes(v)

static func _same_packed(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is PackedStringArray or a is PackedByteArray:
		return a == b
	return (a as Variant).to_byte_array() == (b as Variant).to_byte_array()

## BmsReader.ParsedMesh: every field, every vertex (a natively parsed mesh's
## vertices are built for this -- call to_arrays first if that path matters),
## and vertex_count/positions.
static func bms_diff(a: BmsReader.ParsedMesh, b: BmsReader.ParsedMesh) -> String:
	if (a == null) != (b == null):
		return "one parse is null (%s / %s)" % [a == null, b == null]
	if a == null:
		return ""
	if a.mesh_name != b.mesh_name:
		return "mesh_name %s / %s" % [a.mesh_name, b.mesh_name]
	if a.material_name != b.material_name:
		return "material_name %s / %s" % [a.material_name, b.material_name]
	if a.bone_names != b.bone_names:
		return "bone_names %s / %s" % [a.bone_names, b.bone_names]
	if a.object_space_vertices != b.object_space_vertices:
		return "object_space_vertices %d / %d" % [a.object_space_vertices, b.object_space_vertices]
	if a.indices != b.indices:
		return "indices differ (%d / %d)" % [a.indices.size(), b.indices.size()]
	if _bits(a.bounds_min) != _bits(b.bounds_min) or _bits(a.bounds_max) != _bits(b.bounds_max):
		return "bounds %s..%s / %s..%s" % [a.bounds_min, a.bounds_max, b.bounds_min, b.bounds_max]
	for f in ["vertex_motion", "vertex_pinned", "vertex_links", "vertex_link_lengths", "vertex_link_order"]:
		if not _same_packed(a.get(f), b.get(f)):
			return "%s differs (%d / %d)" % [f, (a.get(f) as Variant).size(), (b.get(f) as Variant).size()]
	if a.vertex_count() != b.vertex_count():
		return "vertex_count %d / %d" % [a.vertex_count(), b.vertex_count()]
	if not _same_packed(a.positions(), b.positions()):
		return "positions() differ"
	var va := a.vertices
	var vb := b.vertices
	if va.size() != vb.size():
		return "vertices %d / %d" % [va.size(), vb.size()]
	for i in range(va.size()):
		var x: BmsReader.Vertex = va[i]
		var y: BmsReader.Vertex = vb[i]
		if _bits(x.position) != _bits(y.position) or _bits(x.normal) != _bits(y.normal) or _bits(x.uv) != _bits(y.uv):
			return "vertex %d: position/normal/uv %s %s %s / %s %s %s" % [i, x.position, x.normal, x.uv, y.position, y.normal, y.uv]
		if x.extra != y.extra:
			return "vertex %d: extra %s / %s" % [i, x.extra, y.extra]
		if x.bone0 != y.bone0 or x.bone1 != y.bone1 or _bits(x.weight0) != _bits(y.weight0) or _bits(x.weight1) != _bits(y.weight1):
			return "vertex %d: skin (%d %d %.17f %.17f) / (%d %d %.17f %.17f)" % [
				i, x.bone0, x.bone1, x.weight0, x.weight1, y.bone0, y.bone1, y.weight0, y.weight1]
	return ""

## BmsReader.to_arrays' surfaces: every slot, the packed arrays byte for byte.
static func arrays_diff(a: Array, b: Array) -> String:
	if a.size() != b.size():
		return "array count %d / %d" % [a.size(), b.size()]
	for i in range(a.size()):
		if (a[i] == null) != (b[i] == null):
			return "slot %d: %s / %s" % [i, type_string(typeof(a[i])), type_string(typeof(b[i]))]
		if a[i] != null and not _same_packed(a[i], b[i]):
			return "slot %d differs (%d / %d elements)" % [i, (a[i] as Variant).size(), (b[i] as Variant).size()]
	return ""

## BanReader.ParsedAnimation: header, key times, and every keyframe of every bone.
static func ban_diff(a: BanReader.ParsedAnimation, b: BanReader.ParsedAnimation) -> String:
	if (a == null) != (b == null):
		return "one parse is null (%s / %s)" % [a == null, b == null]
	if a == null:
		return ""
	if a.animation_name != b.animation_name:
		return "animation_name %s / %s" % [a.animation_name, b.animation_name]
	if a.duration_ms != b.duration_ms or a.authored_fps != b.authored_fps or a.cyclic != b.cyclic:
		return "header (%d %d %s) / (%d %d %s)" % [a.duration_ms, a.authored_fps, a.cyclic, b.duration_ms, b.authored_fps, b.cyclic]
	if a.key_times != b.key_times:
		return "key_times %s / %s" % [a.key_times, b.key_times]
	if a.bones.size() != b.bones.size():
		return "bones %d / %d" % [a.bones.size(), b.bones.size()]
	for i in range(a.bones.size()):
		var x: BanReader.Bone = a.bones[i]
		var y: BanReader.Bone = b.bones[i]
		if x.bone_name != y.bone_name or x.keyframes.size() != y.keyframes.size():
			return "bone %d: %s (%d keys) / %s (%d keys)" % [i, x.bone_name, x.keyframes.size(), y.bone_name, y.keyframes.size()]
		for k in range(x.keyframes.size()):
			var p: BanReader.Keyframe = x.keyframes[k]
			var q: BanReader.Keyframe = y.keyframes[k]
			if _bits(p.rotation) != _bits(q.rotation) or _bits(p.position) != _bits(q.position):
				return "bone %d key %d: %s %s / %s %s" % [i, k, p.rotation, p.position, q.rotation, q.position]
	return ""

## BskReader.ParsedSkeleton: root, and every bone's name, parent and raw record.
static func bsk_diff(a: BskReader.ParsedSkeleton, b: BskReader.ParsedSkeleton) -> String:
	if (a == null) != (b == null):
		return "one parse is null (%s / %s)" % [a == null, b == null]
	if a == null:
		return ""
	if a.root_name != b.root_name or a.root_transform != b.root_transform:
		return "root %s (%d bytes) / %s (%d bytes)" % [a.root_name, a.root_transform.size(), b.root_name, b.root_transform.size()]
	if a.bones.size() != b.bones.size():
		return "bones %d / %d" % [a.bones.size(), b.bones.size()]
	for i in range(a.bones.size()):
		var x: BskReader.Bone = a.bones[i]
		var y: BskReader.Bone = b.bones[i]
		if x.bone_name != y.bone_name or x.parent_name != y.parent_name or x.transform != y.transform:
			return "bone %d: %s <- '%s' (%d bytes) / %s <- '%s' (%d bytes)" % [
				i, x.bone_name, x.parent_name, x.transform.size(), y.bone_name, y.parent_name, y.transform.size()]
	return ""
