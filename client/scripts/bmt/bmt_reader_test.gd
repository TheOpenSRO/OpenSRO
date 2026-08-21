extends SceneTree

## Exercises BmtReader (and its Inflate dependency) against a synthetic
## material (never real game data), run headless:
## `godot4 --headless --path client --script res://scripts/bmt/bmt_reader_test.gd`
##
## The fixture bytes below are a real zlib-compressed stream (generated
## once via Python's zlib, not Godot's own compressor -- see inflate.gd for
## why: Godot's built-in decompressor was confirmed unreliable on at least
## one real .bmt file's zlib stream, which is exactly the failure mode this
## test needs to catch, so the fixture must be built by an independent,
## known-correct implementation).
const FIXTURE_HEX := "d0000000789cf3f28d0873f20d5130303430626260606001e2a4c4e254ed76317b18666068b047e7a7a5a5c13188cf8002207c476606060ea8797a2929590a1c0cac406e4a6a72620eba79a866106f3e27cc40a80500c64a2684"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## Real files from a live client Data tree (Prim/Mtrl/Char/China/man/*.bmt)
## are stored with no zlib wrapper at all -- the raw "JMXVBMT 0102" magic
## sits at byte 0 -- confirmed across 3 real files (chinaman_warrior.bmt,
## chinaman_bogy.bmt, chinaman_monk.bmt). Builds that layout directly
## (never real game data) to cover BmtReader's uncompressed-detection path.
func _append_u32(b: PackedByteArray, v: int) -> void:
	b.append(v & 0xFF)
	b.append((v >> 8) & 0xFF)
	b.append((v >> 16) & 0xFF)
	b.append((v >> 24) & 0xFF)

func _append_len_prefixed(b: PackedByteArray, s: String) -> void:
	var ascii := s.to_ascii_buffer()
	_append_u32(b, ascii.size())
	b.append_array(ascii)

func _append_f32(b: PackedByteArray, v: float) -> void:
	var tmp := PackedByteArray()
	tmp.resize(4)
	tmp.encode_float(0, v)
	b.append_array(tmp)

func _check_uncompressed_variant() -> void:
	var dec := PackedByteArray()
	dec.append_array("JMXVBMT 0102".to_ascii_buffer())
	_append_u32(dec, 1)
	_append_len_prefixed(dec, "chinaman_body")
	for i in range(4): _append_f32(dec, 1.0) # ambient
	for i in range(4): _append_f32(dec, 1.0) # diffuse
	for i in range(4): _append_f32(dec, 1.0) # specular
	for i in range(4): _append_f32(dec, 0.0) # emissive
	_append_f32(dec, 0.0) # power
	_append_u32(dec, 0) # unknown
	_append_len_prefixed(dec, "chinaman_warrior_body.ddj")

	var m := BmtReader.parse(dec)
	_check(m != null, "parses uncompressed (no zlib wrapper) synthetic material")
	if m != null:
		_check(m.layers.size() == 1, "uncompressed variant: 1 layer (got %d)" % m.layers.size())
		if m.layers.size() == 1:
			_check(m.layers[0].layer_name == "chinaman_body", "uncompressed variant: layer name (got %s)" % m.layers[0].layer_name)
			_check(m.layers[0].texture_path == "chinaman_warrior_body.ddj", "uncompressed variant: texture (got %s)" % m.layers[0].texture_path)

func _init() -> void:
	var data := FIXTURE_HEX.hex_decode()

	var m := BmtReader.parse(data)
	_check(m != null, "parses synthetic material (zlib stream from an independent encoder)")
	if m != null:
		_check(m.layers.size() == 2, "2 layers (got %d)" % m.layers.size())
		if m.layers.size() == 2:
			_check(m.layers[0].layer_name == "base", "layer 0 name (got %s)" % m.layers[0].layer_name)
			_check(m.layers[0].texture_path == "base.ddj", "layer 0 texture (got %s)" % m.layers[0].texture_path)
			_check(m.layers[0].diffuse.is_equal_approx(Color(0.588, 0.588, 0.588, 1)), "layer 0 diffuse (got %s)" % m.layers[0].diffuse)
			_check(m.layers[1].layer_name == "decal", "layer 1 name (got %s)" % m.layers[1].layer_name)
			_check(m.layers[1].texture_path == "decal.ddj", "layer 1 texture (got %s)" % m.layers[1].texture_path)
			_check(m.layers[1].diffuse.is_equal_approx(Color(1, 0, 0, 1)), "layer 1 diffuse (got %s)" % m.layers[1].diffuse)

	var bad := PackedByteArray()
	bad.resize(20)
	_check(BmtReader.parse(bad) == null, "rejects non-zlib data")

	_check_uncompressed_variant()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
