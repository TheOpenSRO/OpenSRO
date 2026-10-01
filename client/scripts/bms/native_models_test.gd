extends SceneTree

## The native .bms, .ban and .bsk readers (round 669; native/src/core/
## bms.rs, ban.rs, bsk.rs) against the GDScript ones on SYNTHETIC input -- never real game
## data: meshes at both vertex record sizes, with a full skin, an empty slot
## (object space), a skin refused part-way (the vertices before it keep
## theirs), Latin-1 and NUL-cut names, a header pointer past 2^31 (left to
## GDScript), and truncations; a clip with a key time past 2^31 and a bone
## without keys; a skeleton with both record shapes, an announcement
## resolved late and a one-byte gap. Each is parsed both ways and compared bit for bit
## (ModelCompare), to_arrays included. Without the library it checks the
## fallback: nothing native is used and the GDScript readers still answer.
##
##   godot4 --headless --path client --script res://scripts/bms/native_models_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _u32(b: PackedByteArray, v: int) -> void:
	var at := b.size()
	b.resize(at + 4)
	b.encode_u32(at, v)

func _f32(b: PackedByteArray, v: float) -> void:
	var at := b.size()
	b.resize(at + 4)
	b.encode_float(at, v)

func _str(b: PackedByteArray, s: PackedByteArray) -> void:
	_u32(b, s.size())
	b.append_array(s)

## A quad at `rec` bytes a vertex; `skin` holds [bone0, weight0, bone1,
## weight1] per vertex (empty: no skin section).
func _bms(rec: int, skin: Array, name := PackedByteArray([113, 117, 97, 100, 0xE9])) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(BmsReader.PREAMBLE_END)
	var magic := BmsReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		b[i] = magic[i]
	_str(b, name)
	_str(b, PackedByteArray([109, 116, 108, 0, 106, 117, 110, 107])) # "mtl\0junk"
	_u32(b, 12)
	_u32(b, 4)
	var pos := [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0.5, 1), Vector3(0, 0, 1)]
	for i in range(4):
		var p: Vector3 = pos[i]
		for f in [p.x, p.y, p.z, 0.0, 1.0, 0.0, p.x, p.z]:
			_f32(b, f)
		for k in range(rec - 0x20):
			b.append((i * 16 + k) & 0xFF)
	var skin_at := b.size()
	_u32(b, 2)
	_str(b, "Bip01".to_ascii_buffer())
	_str(b, "Bip01 Spine".to_ascii_buffer())
	for r in skin:
		b.append(r[0])
		b.append(r[1] & 0xFF)
		b.append(r[1] >> 8)
		b.append(r[2])
		b.append(r[3] & 0xFF)
		b.append(r[3] >> 8)
	var index_at := b.size()
	_u32(b, 2)
	for i in [0, 1, 2, 0, 2, 3]:
		b.append(i)
		b.append(0)
	var bbox_at := b.size()
	for f in [0.0, 0.0, 0.0, 1.0, 0.5, 1.0]:
		_f32(b, f)
	var motion_at := b.size()
	_u32(b, 4)
	for pair in [[0.0, 1], [0.05, 0], [0.1, 0], [0.0, 1]]:
		_f32(b, pair[0])
		_u32(b, pair[1])
	var links_at := b.size()
	_u32(b, 2)
	for l in [[0, 1, 1.0], [1, 2, 1.25]]:
		_u32(b, l[0])
		_u32(b, l[1])
		_f32(b, l[2])
	_u32(b, 1)
	_u32(b, 0)
	b.resize(b.size() + 36)
	var base := BmsReader.HEADER_PTRS_BASE
	b.encode_u32(base, 0 if skin.is_empty() else skin_at)
	b.encode_u32(base + 4, index_at)
	b.encode_u32(base + 8, motion_at)
	b.encode_u32(base + 12, links_at)
	b.encode_u32(base + 16, bbox_at)
	return b

func _ban() -> PackedByteArray:
	var b := BanReader.MAGIC.to_ascii_buffer()
	b.resize(b.size() + 8)
	_str(b, PackedByteArray([119, 97, 108, 107, 0xFF])) # "walk\xff"
	for v in [2333, 30, 1]:
		_u32(b, v)
	_u32(b, 3)
	for t in [0, 1167, 0x80000000]:
		_u32(b, t)
	_u32(b, 2)
	_str(b, "Bip01".to_ascii_buffer())
	_u32(b, 2)
	for k in range(2):
		for f in [0.0, 0.0, 0.70710677, 0.70710677, float(k), 2.0, -0.0]:
			_f32(b, f)
	_str(b, PackedByteArray())
	_u32(b, 0)
	return b

## root Bip01; Pelvis resolved at once (parent Bip01); Spine announced, Head
## resolved after a one-byte gap (parent Spine), then Spine resolved without a
## parent (92 bytes); the 8-byte trailer.
func _bsk() -> PackedByteArray:
	var b := BskReader.MAGIC.to_ascii_buffer()
	b.resize(b.size() + 5)
	_str(b, "Bip01".to_ascii_buffer())
	for i in range(92):
		b.append(i)
	_str(b, "Bip01 Pelvis".to_ascii_buffer())
	_str(b, "Bip01 Pelvis".to_ascii_buffer())
	_str(b, "Bip01".to_ascii_buffer())
	for i in range(88):
		b.append(7)
	_str(b, "Bip01 Spine".to_ascii_buffer())
	_str(b, "Bip01 Head".to_ascii_buffer())
	b.append(0)
	_str(b, "Bip01 Head".to_ascii_buffer())
	_str(b, "Bip01 Spine".to_ascii_buffer())
	for i in range(88):
		b.append(9)
	_str(b, "Bip01 Spine".to_ascii_buffer())
	for i in range(92):
		b.append(5)
	b.resize(b.size() + 8)
	return b

func _parse_bms(data: PackedByteArray, gdscript: bool) -> BmsReader.ParsedMesh:
	NativeAssets.force_gdscript = gdscript
	var m := BmsReader.parse(data)
	NativeAssets.force_gdscript = false
	return m

func _both_bms(label: String, data: PackedByteArray, native_expected: bool) -> void:
	var g := _parse_bms(data, true)
	var n := _parse_bms(data, false)
	var native_used := n != null and not n._native.is_empty()
	_check(native_used == native_expected, "%s: parsed natively: %s (want %s)" % [label, native_used, native_expected])
	if g != null and n != null:
		var ga := BmsReader.to_arrays(g)
		var na := BmsReader.to_arrays(n) # before the vertices are built: the native to_arrays
		var d := ModelCompare.arrays_diff(ga, na)
		_check(d == "", "%s: to_arrays agree both ways %s" % [label, d])
	var diff := ModelCompare.bms_diff(g, n)
	_check(diff == "", "%s: parses agree both ways %s" % [label, diff])

func _init() -> void:
	var full := [[0, 0xFFFF, 255, 0], [1, 0xFFFF, 255, 0], [0, 32765, 1, 32765], [255, 0, 1, 0xFFFF]]
	if not NativeAssets.library_usable():
		print("no usable native library (%s): checking the fallback" % NativeAssets.api_verdict(NativeAssets.library_api()))
		_check(NativeAssets.models() == null, "no native model reader without the library")
		var m := BmsReader.parse(_bms(44, full))
		_check(m != null and m.vertex_count() == 4 and m._native.is_empty(), "the GDScript .bms reader still answers")
		_check(m != null and m.positions()[2] == Vector3(1, 0.5, 1), "positions() from the GDScript vertices")
		var a := BanReader.parse(_ban())
		_check(a != null and a.bones.size() == 2, "the GDScript .ban reader still answers")
		var k := BskReader.parse(_bsk())
		_check(k != null and k.bones.size() == 3, "the GDScript .bsk reader still answers")
	else:
		NativeAssets.available()
		_check(NativeAssets.models() != null, "the native model reader is there")
		for rec in [44, 52]:
			_both_bms("rec %d, full skin" % rec, _bms(rec, full), true)
			_both_bms("rec %d, no skin" % rec, _bms(rec, []), true)
		_both_bms("an empty slot (object space)", _bms(44, [[0, 0xFFFF, 255, 0], [255, 0, 255, 0], [255, 0, 1, 0xFFFF], [0, 100, 1, 300]]), true)
		# 1000 / (1000 + 3001) is not an f32: the blend must stay a double.
		_both_bms("an uneven blend", _bms(44, [[0, 1000, 1, 3001], [0, 0xFFFF, 255, 0], [1, 0xFFFF, 255, 0], [0, 0xFFFF, 255, 0]]), true)
		_both_bms("a skin refused at vertex 2", _bms(44, [[1, 0xFFFF, 255, 0], [255, 0, 255, 0], [7, 0xFFFF, 255, 0], [0, 0xFFFF, 255, 0]]), true)
		_both_bms("a NUL-cut name", _bms(44, full, PackedByteArray([97, 0, 98])), true)
		var n := _parse_bms(_bms(44, full), false)
		_check(n.mesh_name == "quadé" and n.material_name == "mtl", "Latin-1 and NUL-cut names, as get_string_from_ascii (%s, %s)" % [n.mesh_name, n.material_name])
		_check(n.vertex_count() == 4 and not n._native.is_empty(), "vertex_count without building the vertices")
		var high := _bms(44, full)
		high.encode_u32(BmsReader.HEADER_PTRS_BASE + 16, 0xFFFFFFF0) # the box pointer, -16 in hdr
		_both_bms("a header pointer past 2^31 (left to GDScript)", high, false)
		var whole := _bms(52, full)
		# (Not a cut inside the name: GDScript's _read_len_prefixed_string answers
		# [] there, not null, and the reader then fails on a script error.)
		for cut in [0, 0x47, 0x80, 200, whole.size() - 50, whole.size() - 1]:
			_both_bms("truncated to %d bytes" % cut, whole.slice(0, cut), false if cut < whole.size() - 60 else true)
		var ga: BanReader.ParsedAnimation = null
		NativeAssets.force_gdscript = true
		ga = BanReader.parse(_ban())
		NativeAssets.force_gdscript = false
		var na := BanReader.parse(_ban())
		var d := ModelCompare.ban_diff(ga, na)
		_check(d == "", "a clip agrees both ways %s" % d)
		_check(na != null and na.key_times[2] == -2147483648 and na.bones[1].keyframes.is_empty(), "a key time past 2^31 wraps; a bone without keys")
		var nd: Dictionary = NativeAssets.models().call("ban_parse", _ban().slice(0, 40))
		_check(nd.has("error"), "a truncated clip is an error natively (GDScript then answers)")
		_check(ModelCompare.ban_diff(BanReader.parse(_ban().slice(0, 40)), null) == "", "and GDScript's answer is null")
		NativeAssets.force_gdscript = true
		var gk := BskReader.parse(_bsk())
		NativeAssets.force_gdscript = false
		var nk := BskReader.parse(_bsk())
		d = ModelCompare.bsk_diff(gk, nk)
		_check(gk != null and d == "", "a skeleton agrees both ways %s" % d)
		_check(nk != null and nk.bones.size() == 3 and nk.bones[1].parent_name == "Bip01 Spine" and nk.bones[2].parent_name == "" and nk.bones[2].transform.size() == 92,
			"both record shapes, a late resolution and a one-byte gap")
		var kd: Dictionary = NativeAssets.models().call("bsk_parse", _bsk().slice(0, 150))
		_check(kd.has("error"), "a truncated skeleton is an error natively (GDScript then answers)")
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
