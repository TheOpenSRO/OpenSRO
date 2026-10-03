extends SceneTree

## CursorSet's RT_CURSOR decoder against a cursor built here byte by byte:
## a 4x2 8-bit image with a two-colour palette, a bottom-up XOR bitmap, an
## AND mask that hides one pixel on each row, and a hotspot. No game data is
## involved -- the real exe is read on the render box, this pins the format.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## hotspot (1,0); BITMAPINFOHEADER 4 wide, height 4 (= 2 rows of colour over
## 2 rows of mask), 8 bpp, 2 palette entries; XOR rows stored bottom-up.
func _synthetic_cursor() -> PackedByteArray:
	var d := PackedByteArray()
	d.resize(4 + 40 + 2 * 4 + 2 * 4 + 2 * 4)
	d.encode_u16(0, 1)   # xHot
	d.encode_u16(2, 0)   # yHot
	var h := 4
	d.encode_u32(h + 0, 40)     # biSize
	d.encode_s32(h + 4, 4)      # biWidth
	d.encode_s32(h + 8, 4)      # biHeight = 2 * 2
	d.encode_u16(h + 12, 1)     # biPlanes
	d.encode_u16(h + 14, 8)     # biBitCount
	d.encode_u32(h + 32, 2)     # biClrUsed
	var pal := h + 40
	# index 0 = red (B,G,R,0), index 1 = blue
	d[pal + 0] = 0; d[pal + 1] = 0; d[pal + 2] = 255; d[pal + 3] = 0
	d[pal + 4] = 255; d[pal + 5] = 0; d[pal + 6] = 0; d[pal + 7] = 0
	var xor := pal + 8
	# bottom row first: [0,1,0,1], then the top row: [1,1,0,0]
	d[xor + 0] = 0; d[xor + 1] = 1; d[xor + 2] = 0; d[xor + 3] = 1
	d[xor + 4] = 1; d[xor + 5] = 1; d[xor + 6] = 0; d[xor + 7] = 0
	var and_off := xor + 8
	d[and_off + 0] = 0x80   # bottom row: pixel 0 transparent
	d[and_off + 4] = 0x10   # top row: pixel 3 transparent
	return d

func _test_decode() -> void:
	var cur := CursorSet.decode_cursor_image(_synthetic_cursor())
	_check(cur != null, "a well-formed cursor decodes")
	if cur == null:
		return
	_check(cur.hotspot == Vector2i(1, 0), "hotspot is read from the first two words: %s" % str(cur.hotspot))
	_check(cur.image.get_width() == 4 and cur.image.get_height() == 2, "image is 4x2 (height halved for the mask)")
	# Top row (image y=0) is the LAST stored XOR row: blue, blue, red, red; pixel 3 masked.
	_check(cur.image.get_pixel(0, 0) == Color(0, 0, 1, 1), "top-left is palette 1 (blue), opaque")
	_check(cur.image.get_pixel(2, 0) == Color(1, 0, 0, 1), "top row pixel 2 is palette 0 (red)")
	_check(cur.image.get_pixel(3, 0).a == 0.0, "top row pixel 3 is transparent (AND bit set)")
	# Bottom row (image y=1) is the FIRST stored row: red, blue, red, blue; pixel 0 masked.
	_check(cur.image.get_pixel(0, 1).a == 0.0, "bottom row pixel 0 is transparent")
	_check(cur.image.get_pixel(1, 1) == Color(0, 0, 1, 1), "bottom row pixel 1 is blue")
	_check(cur.image.get_pixel(3, 1) == Color(0, 0, 1, 1), "bottom row pixel 3 is blue")

func _test_rejects_garbage() -> void:
	_check(CursorSet.decode_cursor_image(PackedByteArray([1, 2, 3])) == null, "too short -> null")
	var d := _synthetic_cursor()
	d.encode_s32(4 + 4, 100000)  # absurd width
	_check(CursorSet.decode_cursor_image(d) == null, "absurd width -> null")

func _test_exe_beside() -> void:
	_check(CursorSet.exe_beside("C:/Games/Silkroad/Data.pk2") == "C:/Games/Silkroad/sro_client.exe", "exe path is next to Data.pk2")
	_check(CursorSet.exe_beside("") == "", "no archive -> no exe path")
	_check(CursorSet.load_from_exe("/definitely/not/here.exe").is_empty(), "missing exe -> empty set, no error")

## The exe search order (round 697): override, then each name in the
## Data.pk2 folder, its parent, our own exe's folder; no duplicates.
func _test_exe_candidates() -> void:
	var c := CursorSet.exe_candidates("D:/srrevamp/pk2/Data.pk2", "D:/srrevamp/SRRevamp.exe")
	var want := PackedStringArray([
		"D:/srrevamp/pk2/sro_client.exe", "D:/srrevamp/sro_client.exe",
		"D:/srrevamp/pk2/sro_client_NODLL.exe", "D:/srrevamp/sro_client_NODLL.exe"])
	_check(c == want, "a pk2 folder beside our exe: pk2/, then the exe's folder (once), per name: %s" % str(c))
	var r := CursorSet.exe_candidates("C:/Silkroad/Data.pk2", "D:/srrevamp/SRRevamp.exe", "E:/x/sro_client.exe")
	_check(r.size() == 7 and r[0] == "E:/x/sro_client.exe", "the override comes first: %s" % str(r))
	_check(r[1] == "C:/Silkroad/sro_client.exe" and r[2] == "C:/sro_client.exe" and r[3] == "D:/srrevamp/sro_client.exe",
		"retail's layout, its parent, our exe's folder: %s" % str(r))
	_check(CursorSet.exe_candidates("", "") .is_empty(), "nothing known -> nothing to try")
	_check(not CursorSet.EXE_NAMES.has("silkroad.exe"), "the launcher is not a client exe")
	var none := CursorSet.load_first(PackedStringArray(["/definitely/not/here/sro_client.exe"]))
	_check(none["path"] == "" and (none["cursors"] as Dictionary).is_empty() and (none["tried"] as PackedStringArray).size() == 1,
		"a missing exe: no set, and the path is in the tried list")

## A 32 x 32 cursor with its hotspot at (2, 1), as 0x95 has (MEASURED).
func _cursor_32(hot: Vector2i) -> CursorSet.Cursor:
	var cur := CursorSet.Cursor.new()
	cur.image = Image.create(32, 32, false, Image.FORMAT_RGBA8)
	cur.image.fill(Color(0, 0, 0, 0))
	cur.image.set_pixelv(hot, Color(1, 0, 0, 1))
	cur.hotspot = hot
	return cur

## Scaling (round 697, OURS: the user's decision): size, nearest pixels, and
## the hotspot inside its own source pixel's block, at 1.0, 1.5, 1.95, 2.0.
func _test_scaled() -> void:
	for hot in [Vector2i(2, 1), Vector2i(2, 26), Vector2i(0, 0), Vector2i(31, 31)]:
		var cur := _cursor_32(hot)
		for k in [1.0, 1.5, 1.95, 2.0]:
			var pair := CursorSet.scaled(cur, k)
			var img: Image = pair[0]
			var h: Vector2i = pair[1]
			var n := roundi(32 * k)
			_check(img.get_width() == n and img.get_height() == n, "%.2f: %dx%d (got %dx%d)" % [k, n, n, img.get_width(), img.get_height()])
			var src := Vector2i(floori(h.x * 32.0 / n), floori(h.y * 32.0 / n))
			_check(src == hot, "%.2f: hotspot %s maps back to source pixel %s (got %s)" % [k, str(h), str(hot), str(src)])
			_check(img.get_pixelv(h) == Color(1, 0, 0, 1), "%.2f: the pixel under hotspot %s is the hotspot's own (nearest)" % [k, str(h)])
	var big := CursorSet.scaled(_cursor_32(Vector2i(2, 1)), 9.0)
	_check((big[0] as Image).get_width() == CursorSet.MAX_CURSOR_SIZE, "a huge scale clamps to Godot's 256 (got %d)" % (big[0] as Image).get_width())
	_check((big[1] as Vector2i).x < CursorSet.MAX_CURSOR_SIZE, "and the hotspot stays inside")
	var same := CursorSet.scaled(_cursor_32(Vector2i(2, 1)), 1.0)
	_check(same[1] == Vector2i(2, 1), "1.0 keeps the file's hotspot exactly")

func _init() -> void:
	_test_decode()
	_test_rejects_garbage()
	_test_exe_beside()
	_test_exe_candidates()
	_test_scaled()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
