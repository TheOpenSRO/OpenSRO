extends SceneTree

## Round 780: GameIcon's RT_GROUP_ICON / RT_ICON read against a PE built here
## byte by byte (no game data; the real exe is read on the render box).
##   godot4 --headless --path client --script res://scripts/ui/game_icon_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_test_pe()
	_test_32bit_alpha()
	_check(GameIcon.from_pe_bytes(PackedByteArray([1, 2, 3])) == null, "garbage: no icon")
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## A 4x2 8-bit icon: two-colour palette (red, blue), bottom-up rows, an AND
## mask hiding one pixel a row. An RT_ICON has no hotspot words.
func _icon_8bit() -> PackedByteArray:
	var d := PackedByteArray()
	d.resize(40 + 2 * 4 + 2 * 4 + 2 * 4)
	d.encode_u32(0, 40)
	d.encode_s32(4, 4)
	d.encode_s32(8, 4)
	d.encode_u16(12, 1)
	d.encode_u16(14, 8)
	d.encode_u32(32, 2)
	var pal := 40
	d[pal + 2] = 255                 # index 0 red
	d[pal + 4] = 255                 # index 1 blue
	var xor := pal + 8
	d[xor + 1] = 1; d[xor + 3] = 1   # bottom row: red blue red blue
	d[xor + 4] = 1; d[xor + 5] = 1   # top row: blue blue red red
	var and_off := xor + 8
	d[and_off + 0] = 0x80            # bottom row pixel 0 hidden
	d[and_off + 4] = 0x10            # top row pixel 3 hidden
	return d

## A PE32 whose .rsrc holds RT_ICON 1 and RT_GROUP_ICON 132 naming it.
func _tiny_pe() -> PackedByteArray:
	var icon := _icon_8bit()
	var rs := PackedByteArray()
	rs.resize(0x200)
	rs.encode_u16(14, 2)
	rs.encode_u32(16, GameIcon.RT_ICON); rs.encode_u32(20, 0x80000000 | 0x30)
	rs.encode_u32(24, GameIcon.RT_GROUP_ICON); rs.encode_u32(28, 0x80000000 | 0x48)
	rs.encode_u16(0x30 + 14, 1); rs.encode_u32(0x30 + 16, 1); rs.encode_u32(0x30 + 20, 0x80000000 | 0x60)
	rs.encode_u16(0x48 + 14, 1); rs.encode_u32(0x48 + 16, 132); rs.encode_u32(0x48 + 20, 0x80000000 | 0x78)
	rs.encode_u16(0x60 + 14, 1); rs.encode_u32(0x60 + 16, 0x409); rs.encode_u32(0x60 + 20, 0x90)
	rs.encode_u16(0x78 + 14, 1); rs.encode_u32(0x78 + 16, 0x409); rs.encode_u32(0x78 + 20, 0xa0)
	var va := 0x1000
	rs.encode_u32(0x90, va + 0x100); rs.encode_u32(0x94, icon.size())
	rs.encode_u32(0xa0, va + 0xc0); rs.encode_u32(0xa4, 20)
	# GRPICONDIR: reserved, type 1, count 1; entry: w 4, h 2, colours, res, planes 1, bpp 8, size, id 1
	rs.encode_u16(0xc0 + 2, 1); rs.encode_u16(0xc0 + 4, 1)
	rs[0xc6] = 4; rs[0xc7] = 2
	rs.encode_u16(0xc6 + 4, 1); rs.encode_u16(0xc6 + 6, 8)
	rs.encode_u32(0xc6 + 8, icon.size()); rs.encode_u16(0xc6 + 12, 1)
	for i in icon.size():
		rs[0x100 + i] = icon[i]
	var b := PackedByteArray()
	b.resize(0x200)
	b.encode_u16(0, 0x5A4D)
	b.encode_u32(0x3c, 0x40)
	b.encode_u32(0x40, 0x00004550)
	b.encode_u16(0x44, 0x14c)
	b.encode_u16(0x46, 1)
	b.encode_u16(0x54, 0xe0)
	var opt := 0x58
	b.encode_u16(opt, 0x10b)
	b.encode_u32(opt + 96 + 16, va)
	b.encode_u32(opt + 96 + 20, rs.size())
	var sec := opt + 0xe0
	for i in 5:
		b[sec + i] = ".rsrc".unicode_at(i)
	b.encode_u32(sec + 8, rs.size()); b.encode_u32(sec + 12, va)
	b.encode_u32(sec + 16, rs.size()); b.encode_u32(sec + 20, 0x200)
	b.append_array(rs)
	return b

func _test_pe() -> void:
	var img := GameIcon.from_pe_bytes(_tiny_pe())
	_check(img != null and img.get_width() == 4 and img.get_height() == 2, "the group's icon decodes, 4x2")
	if img == null:
		return
	_check(img.get_pixel(0, 0) == Color(0, 0, 1, 1) and img.get_pixel(2, 0) == Color(1, 0, 0, 1), "top row blue, blue, red (bottom-up rows)")
	_check(img.get_pixel(3, 0).a == 0.0 and img.get_pixel(0, 1).a == 0.0, "the AND mask's pixels are transparent")

func _test_32bit_alpha() -> void:
	var d := PackedByteArray()
	d.resize(40 + 2 * 1 * 4 + 2 * 4)
	d.encode_u32(0, 40)
	d.encode_s32(4, 1)
	d.encode_s32(8, 4)
	d.encode_u16(12, 1)
	d.encode_u16(14, 32)
	d[40 + 0] = 255; d[40 + 3] = 128   # bottom pixel: blue, alpha 128
	d[44 + 1] = 255; d[44 + 3] = 255   # top pixel: green, opaque
	var img := GameIcon.decode_icon_image(d)
	_check(img != null and is_equal_approx(img.get_pixel(0, 1).a, 128.0 / 255.0) and img.get_pixel(0, 0).a == 1.0,
		"a 32-bit icon keeps its own alpha")
