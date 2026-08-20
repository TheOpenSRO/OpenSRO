extends SceneTree

## Exercises DdjReader against synthetic textures (never real game data), run
## headless: `godot4 --headless --path client --script res://scripts/ddj/ddj_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _put_u32(b: PackedByteArray, off: int, v: int) -> void:
	b[off] = v & 0xFF
	b[off + 1] = (v >> 8) & 0xFF
	b[off + 2] = (v >> 16) & 0xFF
	b[off + 3] = (v >> 24) & 0xFF

func _build_ddj(width: int, height: int, four_cc: String) -> PackedByteArray:
	var pixel_bytes := 4
	var dds_size := 4 + DdjReader.DDS_HEADER_SIZE + width * height * pixel_bytes
	var dds := PackedByteArray()
	dds.resize(dds_size)
	var magic_bytes := "DDS ".to_ascii_buffer()
	for i in range(4):
		dds[i] = magic_bytes[i]
	_put_u32(dds, 4, DdjReader.DDS_HEADER_SIZE)
	_put_u32(dds, 4 + 8, height)
	_put_u32(dds, 4 + 12, width)
	_put_u32(dds, 4 + 24, 1)

	var pf_off := 4 + 72
	_put_u32(dds, pf_off, 32)
	if four_cc != "":
		_put_u32(dds, pf_off + 4, DdjReader.DDPF_FOURCC)
		var cc_bytes := four_cc.to_ascii_buffer()
		for i in range(4):
			dds[pf_off + 8 + i] = cc_bytes[i]
	else:
		_put_u32(dds, pf_off + 4, DdjReader.DDPF_RGB | DdjReader.DDPF_ALPHAPIXELS)
		_put_u32(dds, pf_off + 12, 32)

	var buf := PackedByteArray()
	buf.resize(DdjReader.WRAPPER_SIZE + dds.size())
	var magic := DdjReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		buf[i] = magic[i]
	_put_u32(buf, 0x0c, buf.size() - DdjReader.MAGIC_LEN)
	_put_u32(buf, 0x10, 3)
	for i in range(dds.size()):
		buf[DdjReader.WRAPPER_SIZE + i] = dds[i]
	return buf

func _init() -> void:
	var data := _build_ddj(4, 4, "")
	var tex := DdjReader.parse(data)
	_check(tex != null, "parses synthetic uncompressed texture")
	if tex != null:
		_check(tex.width == 4 and tex.height == 4, "dimensions are 4x4 (got %dx%d)" % [tex.width, tex.height])
		_check(tex.four_cc == "", "no FourCC for uncompressed texture (got %s)" % tex.four_cc)
		var image_tex := DdjReader.to_texture(tex)
		_check(image_tex != null, "builds a Godot texture from uncompressed data")

	var compressed := _build_ddj(64, 64, "DXT1")
	var tex2 := DdjReader.parse(compressed)
	_check(tex2 != null and tex2.four_cc == "DXT1", "parses synthetic DXT1 texture with correct FourCC")

	var bad_magic := PackedByteArray()
	bad_magic.resize(DdjReader.WRAPPER_SIZE + 4)
	_check(DdjReader.parse(bad_magic) == null, "rejects bad magic")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
