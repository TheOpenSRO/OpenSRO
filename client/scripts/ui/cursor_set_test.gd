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
	var c := CursorSet.exe_candidates("D:/opensro/pk2/Data.pk2", "D:/opensro/OpenSRO.exe")
	var want := PackedStringArray([
		"D:/opensro/pk2/sro_client.exe", "D:/opensro/sro_client.exe",
		"D:/opensro/pk2/sro_client_NODLL.exe", "D:/opensro/sro_client_NODLL.exe"])
	_check(c == want, "a pk2 folder beside our exe: pk2/, then the exe's folder (once), per name: %s" % str(c))
	var r := CursorSet.exe_candidates("C:/Silkroad/Data.pk2", "D:/opensro/OpenSRO.exe", "E:/x/sro_client.exe")
	_check(r.size() == 7 and r[0] == "E:/x/sro_client.exe", "the override comes first: %s" % str(r))
	_check(r[1] == "C:/Silkroad/sro_client.exe" and r[2] == "C:/sro_client.exe" and r[3] == "D:/opensro/sro_client.exe",
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

## A PE-signed garbage file (round 697 review, L1): rejected fast and
## quietly, whatever its section count and directory counts claim.
func _garbage_pe(nsec: int, fill: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(1 << 20)
	b.fill(fill)
	b.encode_u16(0, 0x5A4D)
	b.encode_u32(0x3c, 0x40)
	b.encode_u32(0x40, 0x00004550)
	b.encode_u16(0x40 + 6, nsec)
	b.encode_u16(0x40 + 20, 0xe0)
	b.encode_u16(0x40 + 24, 0x10b)
	return b

## The same with one sane section that maps the resource table onto the
## garbage, so the directory walk itself meets the junk counts.
func _garbage_rsrc(fill: int) -> PackedByteArray:
	var b := _garbage_pe(1, fill)
	var opt := 0x40 + 24
	b.encode_u32(opt + 96 + 16, 0x1000)       # resource table RVA
	var sec := opt + 0xe0
	b.encode_u32(sec + 8, 0x100000)            # vsize
	b.encode_u32(sec + 12, 0x1000)             # va
	b.encode_u32(sec + 16, 0x100000)           # rsize
	b.encode_u32(sec + 20, 0x1000)             # raw
	# A directory claiming type 12 again and again, each pointing back at
	# itself: walked once, not forever.
	b.encode_u16(0x1000 + 12, 0)
	b.encode_u16(0x1000 + 14, 300)
	for i in 300:
		b.encode_u32(0x1000 + 16 + 8 * i, 12)
		b.encode_u32(0x1000 + 20 + 8 * i, 0x80000000)
	return b

func _test_garbage_pe() -> void:
	for c in [[0xffff, 0xff], [3, 0xff], [1, 0x00], [2, 0x41], [-1, 0x41], [-1, 0x00], [-1, 0x01]]:
		var path := "user://cursor_garbage_test.exe"
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(_garbage_pe(int(c[0]), int(c[1])) if int(c[0]) >= 0 else _garbage_rsrc(int(c[1])))
		f.close()
		var t0 := Time.get_ticks_msec()
		var got := CursorSet.load_from_exe(path)
		var ms := Time.get_ticks_msec() - t0
		_check(got.is_empty(), "garbage (nsec %d, fill 0x%x): no cursor" % [c[0], c[1]])
		_check(ms < 200, "garbage (nsec %d, fill 0x%x): rejected in %d ms" % [c[0], c[1], ms])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## Round 700: a path a player writes, as files to try.
func _test_expand() -> void:
	_check(CursorSet.expand("") .is_empty() and CursorSet.expand("   ").is_empty(), "empty -> nothing")
	_check(CursorSet.expand("C:\\Program Files (x86)\\Silkroad\\sro_client.exe") == PackedStringArray(["C:/Program Files (x86)/Silkroad/sro_client.exe"]),
		"a Windows path with backslashes: the file, with slashes")
	_check(CursorSet.expand("\"D:/Games/SRO/SRO_Client_VTX.EXE\"") == PackedStringArray(["D:/Games/SRO/SRO_Client_VTX.EXE"]),
		"quoted, any name, any case of .exe: that file")
	_check(CursorSet.expand("D:\\Games\\SRO\\") == PackedStringArray(["D:/Games/SRO/sro_client.exe", "D:/Games/SRO/sro_client_NODLL.exe"]),
		"a folder (trailing separator dropped): each client name in it")
	_check(CursorSet.expand("C:/") == PackedStringArray(["C:/sro_client.exe", "C:/sro_client_NODLL.exe"]), "a drive root stays a root")
	var c := CursorSet.exe_candidates("D:/opensro/pk2/Data.pk2", "D:/opensro/OpenSRO.exe", "C:\\Silkroad")
	_check(c.size() == 6 and c[0] == "C:/Silkroad/sro_client.exe" and c[1] == "C:/Silkroad/sro_client_NODLL.exe" and c[2] == "D:/opensro/pk2/sro_client.exe",
		"OPENSRO_CLIENT_EXE naming a folder (backslashes) comes first: %s" % str(c))
	var dirs := CursorSet.scan_dirs("D:/opensro/pk2/Data.pk2", "D:/opensro/OpenSRO.exe", "C:/Silkroad/SRO_Client_VTX.exe")
	_check(dirs == PackedStringArray(["C:/Silkroad", "D:/opensro/pk2", "D:/opensro"]),
		"the scan's folders: the override's, the pk2 folder, its parent (= our exe's, once): %s" % str(dirs))

## A minimal PE32 whose .rsrc holds one RT_CURSOR (id 1, the synthetic
## image) and one RT_GROUP_CURSOR (id `group_id`) naming it -- the layout of
## the client's resource tree (type -> id -> language -> data entry).
func _tiny_pe(group_id: int) -> PackedByteArray:
	var cur := _synthetic_cursor()
	var rs := PackedByteArray()
	rs.resize(0x200)
	# root: 2 id entries (types 1 and 12) at 0x10
	rs.encode_u16(14, 2)
	rs.encode_u32(16, 1); rs.encode_u32(20, 0x80000000 | 0x30)
	rs.encode_u32(24, 12); rs.encode_u32(28, 0x80000000 | 0x48)
	# type 1 dir at 0x30: id 1 -> lang dir 0x60
	rs.encode_u16(0x30 + 14, 1); rs.encode_u32(0x30 + 16, 1); rs.encode_u32(0x30 + 20, 0x80000000 | 0x60)
	# type 12 dir at 0x48: group_id -> lang dir 0x78
	rs.encode_u16(0x48 + 14, 1); rs.encode_u32(0x48 + 16, group_id); rs.encode_u32(0x48 + 20, 0x80000000 | 0x78)
	# lang dirs -> data entries at 0x90 / 0xa0
	rs.encode_u16(0x60 + 14, 1); rs.encode_u32(0x60 + 16, 0x409); rs.encode_u32(0x60 + 20, 0x90)
	rs.encode_u16(0x78 + 14, 1); rs.encode_u32(0x78 + 16, 0x409); rs.encode_u32(0x78 + 20, 0xa0)
	var va := 0x1000
	# data entries: RVA, size
	rs.encode_u32(0x90, va + 0x100); rs.encode_u32(0x94, cur.size())
	rs.encode_u32(0xa0, va + 0xc0); rs.encode_u32(0xa4, 20)
	# GRPCURSORDIR at 0xc0: reserved, type 2, count 1, one 14-byte entry naming image 1
	rs.encode_u16(0xc0 + 2, 2); rs.encode_u16(0xc0 + 4, 1); rs.encode_u16(0xc0 + 6 + 12, 1)
	for i in cur.size():
		rs[0x100 + i] = cur[i]
	var b := PackedByteArray()
	b.resize(0x200)
	b.encode_u16(0, 0x5A4D)
	b.encode_u32(0x3c, 0x40)
	b.encode_u32(0x40, 0x00004550)
	b.encode_u16(0x44, 0x14c)       # machine
	b.encode_u16(0x46, 1)           # one section
	b.encode_u16(0x54, 0xe0)        # optional header size
	var opt := 0x58
	b.encode_u16(opt, 0x10b)        # PE32
	b.encode_u32(opt + 96 + 16, va) # data directory 2: the resource table
	b.encode_u32(opt + 96 + 20, rs.size())
	var sec := opt + 0xe0
	for i in 5:
		b[sec + i] = ".rsrc".unicode_at(i)
	b.encode_u32(sec + 8, rs.size()); b.encode_u32(sec + 12, va)
	b.encode_u32(sec + 16, rs.size()); b.encode_u32(sec + 20, 0x200)
	b.append_array(rs)
	return b

func _write(path: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()

## Round 700: a renamed client is found by its cursors; the probe reads the
## headers and the resource directory only.
func _test_scan() -> void:
	var dir := ProjectSettings.globalize_path("user://cursor_scan_test")
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	_write(dir.path_join("SRO_Client_VTX.exe"), _tiny_pe(CursorSet.ID_NORMAL))
	_write(dir.path_join("Launcher.exe"), _tiny_pe(0x7901))
	_write(dir.path_join("aaa_garbage.exe"), _garbage_pe(3, 0xff))
	_write(dir.path_join("OpenSRO.exe"), _tiny_pe(CursorSet.ID_NORMAL))
	_write(dir.path_join("Data.pk2"), PackedByteArray([1, 2, 3]))
	_check(CursorSet.probe_has_group(dir.path_join("SRO_Client_VTX.exe"), CursorSet.ID_NORMAL), "the probe sees group 0x95 in a renamed client")
	_check(not CursorSet.probe_has_group(dir.path_join("Launcher.exe"), CursorSet.ID_NORMAL), "not in a launcher whose groups are 0x7901..")
	_check(not CursorSet.probe_has_group(dir.path_join("aaa_garbage.exe"), CursorSet.ID_NORMAL), "not in garbage")
	_check(not CursorSet.probe_has_group(dir.path_join("missing.exe"), CursorSet.ID_NORMAL), "not in a missing file")
	var listed := CursorSet.exes_in(dir, PackedStringArray([dir.path_join("OPENSRO.EXE")]))
	_check(listed == PackedStringArray([dir.path_join("aaa_garbage.exe"), dir.path_join("Launcher.exe"), dir.path_join("SRO_Client_VTX.exe")]),
		"the folder's .exe files, sorted without case, our own skipped without case: %s" % str(listed))
	var r := CursorSet.scan_for_client(PackedStringArray([dir]), PackedStringArray([dir.path_join("OpenSRO.exe")]))
	_check(String(r["path"]) == dir.path_join("SRO_Client_VTX.exe") and (r["cursors"] as Dictionary).has(CursorSet.ID_NORMAL),
		"the scan takes the renamed client: %s" % r["path"])
	var cur: CursorSet.Cursor = (r["cursors"] as Dictionary).get(CursorSet.ID_NORMAL)
	_check(cur != null and cur.hotspot == Vector2i(1, 0) and cur.image.get_width() == 4, "and decodes its cursor")
	_check(int(r["probed"]) == 3, "three files probed (garbage, launcher, client; ours skipped): %d" % int(r["probed"]))
	var none := CursorSet.scan_for_client(PackedStringArray([dir.path_join("nope"), ""]), PackedStringArray())
	_check(String(none["path"]) == "" and int(none["probed"]) == 0, "a missing folder: nothing")
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)

## Round 700: the line a player sees without the cursors.
func _test_hint() -> void:
	GameCursor.install_for_test({})
	var plain := GameCursor.missing_hint("C:/opensro/pk2")
	_check(plain.contains("sro_client.exe") and plain.contains("C:/opensro/pk2"), "no exe: where to copy it (%s)" % plain)
	var c := CursorSet.Cursor.new()
	c.image = Image.create(2, 2, false, Image.FORMAT_RGBA8)
	GameCursor.install_for_test({CursorSet.ID_NORMAL: c})
	_check(GameCursor.missing_hint("x") == "", "with the cursors: no line")
	GameCursor.reset_for_test()

func _init() -> void:
	_test_garbage_pe()
	_test_expand()
	_test_scan()
	_test_hint()
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
