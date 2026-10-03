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
	# Real per-pixel byte rates: DXT1 is 4 bits/pixel (0.5 bytes), DXT2/3/5
	# are 8 bits/pixel (1 byte), uncompressed (no FourCC) is assumed RGBA
	# (4 bytes) -- matches what DdjReader.to_texture actually expects each
	# format to provide, so a real payload-size mismatch (like the one
	# DXT2 support surfaced, 2026-08-24) gets caught here instead of
	# silently oversizing every synthetic fixture uniformly.
	var payload_size: int
	match four_cc:
		"DXT1":
			payload_size = maxi(width * height / 2, 8)
		"DXT2", "DXT3", "DXT5":
			payload_size = width * height
		_:
			payload_size = width * height * 4
	var dds_size := 4 + DdjReader.DDS_HEADER_SIZE + payload_size
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

## Builds a 16-bit ARGB1555 .ddj -- the real layout of every file under
## `interface\\` in a real Media.pk2 (verified 2026-09-08 by reading the
## DDS_PIXELFORMAT of mm_window, mm_alpha, mm_sign_npc and ub_deco_left:
## bpp=16, R=0x7C00 G=0x03E0 B=0x001F A=0x8000). The reader used to assume
## 24- or 32-bit BGR(A) here and handed Godot a buffer two-thirds the size
## it needed, so every piece of UI chrome silently failed to build.
##
## pixels are 16-bit values written little-endian, one per texel.
func _build_ddj_argb1555(width: int, height: int, pixels: Array) -> PackedByteArray:
	var payload_size := width * height * 2
	var dds := PackedByteArray()
	dds.resize(4 + DdjReader.DDS_HEADER_SIZE + payload_size)
	var magic_bytes := "DDS ".to_ascii_buffer()
	for i in range(4):
		dds[i] = magic_bytes[i]
	_put_u32(dds, 4, DdjReader.DDS_HEADER_SIZE)
	_put_u32(dds, 4 + 8, height)
	_put_u32(dds, 4 + 12, width)
	_put_u32(dds, 4 + 24, 1)

	var pf_off := 4 + 72
	_put_u32(dds, pf_off, 32)
	_put_u32(dds, pf_off + 4, DdjReader.DDPF_RGB | DdjReader.DDPF_ALPHAPIXELS)
	_put_u32(dds, pf_off + 12, 16)
	_put_u32(dds, pf_off + 16, 0x7C00)
	_put_u32(dds, pf_off + 20, 0x03E0)
	_put_u32(dds, pf_off + 24, 0x001F)
	_put_u32(dds, pf_off + 28, 0x8000)

	var payload_off := 4 + DdjReader.DDS_HEADER_SIZE
	for i in range(pixels.size()):
		dds[payload_off + i * 2] = pixels[i] & 0xFF
		dds[payload_off + i * 2 + 1] = (pixels[i] >> 8) & 0xFF

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

	# Real DXT2 support (2026-08-24, found live-testing a real region
	# outside the initially-tested Jangan cluster): bit-identical block
	# layout to DXT3, decoded the same way -- see DdjReader.to_texture's
	# own doc comment for the real premultiplied-alpha caveat this doesn't
	# need to handle yet.
	var dxt2_data := _build_ddj(64, 64, "DXT2")
	var dxt2_tex := DdjReader.parse(dxt2_data)
	_check(dxt2_tex != null and dxt2_tex.four_cc == "DXT2", "parses synthetic DXT2 texture with correct FourCC")
	if dxt2_tex != null:
		var dxt2_image := DdjReader.to_texture(dxt2_tex)
		_check(dxt2_image != null, "builds a Godot texture from real DXT2 data (decoded as DXT3)")

	var bad_magic := PackedByteArray()
	bad_magic.resize(DdjReader.WRAPPER_SIZE + 4)
	_check(DdjReader.parse(bad_magic) == null, "rejects bad magic")

	# Real file (Prim\Mtrl\Item\China\weapon\shield_90.ddj, 2026-08-24) has a
	# 0x0c field that doesn't equal data.size()-MAGIC_LEN even though it's
	# an otherwise well-formed, fully parseable texture -- parsing must
	# succeed regardless of this field's value.
	var mismatched_size := _build_ddj(4, 4, "")
	_put_u32(mismatched_size, 0x0c, 0xFFFFFFFF)
	_check(DdjReader.parse(mismatched_size) != null, "tolerates mismatched size field")

	# 16-bit ARGB1555, the real interface-art layout. Four texels chosen so
	# every channel and the 1-bit alpha are each checked at both extremes:
	# opaque red, opaque green, opaque blue, transparent white.
	var argb1555 := _build_ddj_argb1555(2, 2, [
		0x8000 | (31 << 10),          # opaque red
		0x8000 | (31 << 5),           # opaque green
		0x8000 | 31,                  # opaque blue
		(31 << 10) | (31 << 5) | 31,  # white, alpha bit clear
	])
	var argb_tex := DdjReader.parse(argb1555)
	_check(argb_tex != null, "parses a 16-bit ARGB1555 texture")
	if argb_tex != null:
		_check(argb_tex.rgb_bit_count == 16, "ARGB1555: reads 16 bits per pixel (got %d)" % argb_tex.rgb_bit_count)
		_check(argb_tex.r_mask == 0x7C00 and argb_tex.a_mask == 0x8000,
			"ARGB1555: reads the channel masks (got R=%x A=%x)" % [argb_tex.r_mask, argb_tex.a_mask])
		var argb_image_tex := DdjReader.to_texture(argb_tex)
		_check(argb_image_tex != null, "builds a Godot texture from 16-bit data")
		if argb_image_tex != null:
			var img := argb_image_tex.get_image()
			# A 5-bit 31 must scale to a full 255, not to 31 -- otherwise
			# every 16-bit texture renders nearly black.
			_check(img.get_pixel(0, 0) == Color8(255, 0, 0, 255),
				"ARGB1555: opaque red scales to full range (got %s)" % img.get_pixel(0, 0))
			_check(img.get_pixel(1, 0) == Color8(0, 255, 0, 255),
				"ARGB1555: opaque green (got %s)" % img.get_pixel(1, 0))
			_check(img.get_pixel(0, 1) == Color8(0, 0, 255, 255),
				"ARGB1555: opaque blue (got %s)" % img.get_pixel(0, 1))
			_check(img.get_pixel(1, 1).a == 0.0,
				"ARGB1555: the 1-bit alpha reads as transparent (got a=%f)" % img.get_pixel(1, 1).a)

	# Round 621: the D3DFORMAT 113 (D3DFMT_A16B16G16R16F) that retail
	# Particles.pk2 stores in the FourCC slot as the bytes 71 00 00 00 ('q').
	# Four half floats a pixel, R first. The header is the DXT5 fixture's with
	# the FourCC and the payload replaced.
	var base := _build_ddj(2, 2, "DXT5")
	var q := base.slice(0, DdjReader.WRAPPER_SIZE + 4 + DdjReader.DDS_HEADER_SIZE)
	var cc_off := DdjReader.WRAPPER_SIZE + 4 + 72 + 8
	q[cc_off] = 0x71
	q[cc_off + 1] = 0
	q[cc_off + 2] = 0
	q[cc_off + 3] = 0
	var px := PackedByteArray()
	px.resize(2 * 2 * 8)
	var texels := [[1.0, 0.0, 0.0, 1.0], [0.0, 1.0, 0.0, 0.5], [0.0, 0.0, 1.0, 0.0], [1.0, 1.0, 1.0, 1.0]]
	for i in range(4):
		for c in range(4):
			px.encode_half(i * 8 + c * 2, texels[i][c])
	q.append_array(px)
	var qt := DdjReader.parse(q)
	_check(qt != null and qt.four_cc == "q", "parses a texture whose FourCC slot holds D3DFORMAT 113 ('q')")
	if qt != null:
		var qi := DdjReader.to_image(qt)
		_check(qi != null, "decodes D3DFMT_A16B16G16R16F")
		if qi != null:
			_check(qi.get_pixel(0, 0) == Color8(255, 0, 0, 255) and qi.get_pixel(1, 0).g8 == 255
				and absf(qi.get_pixel(1, 0).a - 0.5) < 0.01 and qi.get_pixel(0, 1) == Color8(0, 0, 255, 0),
				"A16B16G16R16F: R, G, B, A in memory order (got %s %s %s)" % [qi.get_pixel(0, 0), qi.get_pixel(1, 0), qi.get_pixel(0, 1)])
			# 0.5 rounds to 128; a truncating convert gives 127 (review follow-up).
			_check(qi.get_pixel(1, 0).a8 == 128, "A16B16G16R16F: 0.5 rounds to 128, not 127 (got %d)" % qi.get_pixel(1, 0).a8)
		var short := q.slice(0, q.size() - 8)
		_check(DdjReader.to_image(DdjReader.parse(short)) == null, "a short A16B16G16R16F payload is refused")

	_dxt1_alpha_checks()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## Round 695: under Forward+ (BC1_RGB, alpha ONE) a DXT1's transparent texels
## would draw opaque black, so DdjReader decodes such a texture to RGBA8 with
## the engine's own decoder (what Compatibility samples); under Compatibility,
## and for a DXT1 with no transparent texel, it stays DXT1. The override is set
## through the script object so the base, which lacks it, runs these checks
## and fails them.
func _dxt1_block(c0: int, c1: int, idx: Array) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_u16(0, c0)
	b.encode_u16(2, c1)
	var v := 0
	for i in range(16):
		v |= int(idx[i]) << (2 * i)
	b.encode_u32(4, v)
	return b

## A w x h DXT1 .ddj whose payload is `blocks`, with `mips` levels declared.
func _dxt1_ddj(w: int, h: int, blocks: Array, mips: int = 1) -> PackedByteArray:
	var buf := _build_ddj(w, h, "DXT1")
	var off := DdjReader.WRAPPER_SIZE + 4 + DdjReader.DDS_HEADER_SIZE
	buf.resize(off + 8 * blocks.size())
	_put_u32(buf, DdjReader.WRAPPER_SIZE + 4 + 24, mips)
	var at := 0
	for blk in blocks:
		for i in range(8):
			buf[off + at + i] = (blk as PackedByteArray)[i]
		at += 8
	return buf

func _dxt1_alpha_checks() -> void:
	var reader := load("res://scripts/ddj/ddj_reader.gd") as GDScript
	# Three-colour (c0 <= c1), every index used, index 3 transparent; then a
	# four-colour block.
	var idx := [0, 1, 3, 3, 1, 0, 3, 1, 0, 2, 2, 0, 3, 3, 3, 3]
	var three := _dxt1_block(0x2104, 0x630C, idx)
	var four := _dxt1_block(0xF800, 0x001F, [0, 1, 2, 3, 3, 2, 1, 0, 0, 1, 2, 3, 3, 2, 1, 0])
	var data := _dxt1_ddj(8, 4, [three, four])
	# What Compatibility samples: the engine's own DXT1 decode, alpha kept.
	var payload := data.slice(DdjReader.WRAPPER_SIZE + 4 + DdjReader.DDS_HEADER_SIZE)
	var want := Image.create_from_data(8, 4, false, Image.FORMAT_DXT1, payload)
	want.decompress()
	_check(want.get_pixel(2, 0) == Color(0, 0, 0, 0) and want.get_pixel(0, 0).a == 1.0,
		"DXT1 reference: index 3 of a three-colour block is (0, 0, 0, 0), index 0 opaque")
	# 8x8 with its mip chain (4 + 1 + 1 + 1 blocks), the transparent texel
	# only in the 1x1 level: the scan covers every level, and the levels stay.
	var mipped := _dxt1_ddj(8, 8, [four, four, four, four, four, four, _dxt1_block(0x0000, 0xFFFF, [3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])], 4)
	var modes: Array = [true]
	if NativeAssets.library_usable():
		modes.append(false)
	for gd in modes:
		NativeAssets.force_gdscript = gd
		var path := "GDScript" if gd else "native"
		reader.set("dxt1_alpha_override", 1)
		var img := DdjReader.to_image(DdjReader.parse(data))
		_check(img != null and img.get_format() == Image.FORMAT_RGBA8,
			"Forward+ (%s): a DXT1 with transparent texels is decoded to RGBA8 (got format %s)" % [path, img.get_format() if img != null else -1])
		if img != null and img.get_format() == Image.FORMAT_RGBA8:
			_check(img.get_data() == want.get_data(), "Forward+ (%s): every texel, alpha and colour, is what Compatibility samples" % path)
		var mi := DdjReader.to_image(DdjReader.parse(mipped))
		_check(mi != null and mi.get_format() == Image.FORMAT_RGBA8 and mi.has_mipmaps() and mi.get_mipmap_count() == 3,
			"Forward+ (%s): a transparent texel in the last mip level counts, and the levels stay (got %s, %s mips)" % [
				path, mi.get_format() if mi != null else -1, mi.get_mipmap_count() if mi != null else -1])
		# A DXT1 without a transparent texel stays DXT1, and so does every
		# DXT1 under Compatibility.
		var opaque := _dxt1_ddj(8, 4, [_dxt1_block(0x2104, 0x630C, [0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0]), four])
		var oi := DdjReader.to_image(DdjReader.parse(opaque))
		_check(oi != null and oi.get_format() == Image.FORMAT_DXT1, "Forward+ (%s): a DXT1 with no transparent texel stays DXT1" % path)
		reader.set("dxt1_alpha_override", 0)
		var ci := DdjReader.to_image(DdjReader.parse(data))
		_check(ci != null and ci.get_format() == Image.FORMAT_DXT1, "Compatibility (%s): DXT1 stays DXT1" % path)
	NativeAssets.force_gdscript = false
	reader.set("dxt1_alpha_override", -1)
	var scan_ok: bool = reader.has_method("dxt1_has_transparent") and bool(reader.call("dxt1_has_transparent", three + four)) \
		and not bool(reader.call("dxt1_has_transparent", four))
	_check(scan_ok, "the block scan finds index 3 only in three-colour mode")
