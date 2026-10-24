extends SceneTree

## Round 824: CrestNet (the bitmap's quantisation as c:0x4f9d70 does it,
## 0x3257, the crest's picture) and CrestCache (who has which crest, asking
## for it once, keeping it). A synthetic palette and bitmap: no game data.
## `godot4 --headless --path client --script res://scripts/net/crest_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## 256 entries, entry i = (i, 255 - i, i / 2); entry 7 repeated at 9, so a
## tie can be seen.
func _palette() -> PackedByteArray:
	var p := PackedByteArray()
	for i in 256:
		p.append_array(PackedByteArray([i, 255 - i, i / 2]))
	p[9 * 3] = 7
	p[9 * 3 + 1] = 248
	p[9 * 3 + 2] = 3
	return p

## A 16 x 16 24-bit BMP whose pixel n (file order) is colour `colour.call(n)`.
func _bmp(colour: Callable, bits: int = 24, width: int = 16) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(54)
	b[0] = 0x42
	b[1] = 0x4d
	b.encode_u32(2, 54 + 768)
	b.encode_u32(10, 54)
	b.encode_u32(14, 40)
	b.encode_s32(18, width)
	b.encode_s32(22, 16)
	b.encode_u16(26, 1)
	b.encode_u16(28, bits)
	for n in 256:
		var c: Color = colour.call(n)
		b.append_array(PackedByteArray([c.b8, c.g8, c.r8]))
	return b

func _init() -> void:
	var pal := _palette()
	# Exact colours map to their entries; the tie (7 and 9 alike) goes to 9.
	var exact := _bmp(func(n: int) -> Color: return Color8(n, 255 - n, n / 2))
	var got := CrestNet.bmp_to_indices(exact, pal)
	var px: PackedByteArray = got[1]
	_check(int(got[0]) == CrestNet.BMP_OK and px.size() == 256, "a 16 x 16 24-bit bitmap is read")
	_check(px[0] == 0 and px[100] == 100 and px[255] == 255, "each colour its own entry, in the file's order")
	_check(px[7] == 9, "a tie goes to the higher index (<=): entries 7 and 9 alike, 9")
	# Nearest by |dr| + |dg| + |db|: (101, 150, 52) is 4 from entries 104
	# (104, 151, 52) and 105 (105, 150, 52), more from every other; the tie
	# goes to 105.
	var near := CrestNet.bmp_to_indices(_bmp(func(_n: int) -> Color: return Color8(101, 150, 52)), pal)
	_check((near[1] as PackedByteArray)[0] == 105, "the nearest entry by the sum of differences (got %d)" % (near[1] as PackedByteArray)[0])
	_check(int(CrestNet.bmp_to_indices(PackedByteArray(), pal)[0]) == CrestNet.BMP_MISSING, "no file: 1")
	_check(int(CrestNet.bmp_to_indices(_bmp(func(_n: int) -> Color: return Color.BLACK, 32), pal)[0]) == CrestNet.BMP_FORMAT, "32-bit: 2")
	_check(int(CrestNet.bmp_to_indices(_bmp(func(_n: int) -> Color: return Color.BLACK, 24, 32), pal)[0]) == CrestNet.BMP_FORMAT, "32 wide: 2")
	# The picture: byte 0 is the bottom-left pixel.
	var img := CrestNet.image_of(px, pal)
	_check(img != null and img.get_size() == Vector2i(16, 16), "a 16 x 16 picture")
	_check(img.get_pixel(0, 15).is_equal_approx(Color8(0, 255, 0)) and img.get_pixel(15, 0).is_equal_approx(Color8(255, 0, 127)),
		"row 0 of the bytes is the picture's bottom row")

	# 0x3257.
	var u := PackedByteArray([1, 7, 0, 0, 0, 2, 0, 0x41, 0x62, 3, 0, 0, 0])
	var d := CrestNet.decode_update(u)
	_check(d != null and d.kind == 1 and d.id == 7 and d.guild_names == PackedStringArray(["Ab"]) and d.rev == 3, "0x3257 type 1")
	var u2 := PackedByteArray([2, 9, 0, 0, 0, 2, 1, 0, 0x41, 1, 0, 0x42, 4, 0, 0, 0])
	var d2 := CrestNet.decode_update(u2)
	_check(d2 != null and d2.kind == 2 and d2.guild_names == PackedStringArray(["A", "B"]) and d2.rev == 4, "0x3257 type 2")
	_check(CrestNet.decode_update(u.slice(0, 9)) == null, "a short 0x3257 is dropped")

	# The cache.
	var c := CrestCache.new()
	c.palette = pal
	var sent: Array = []
	var changes: Array = []
	c.send = func(op: int, payload: PackedByteArray) -> void: sent.append([op, payload])
	c.changed.connect(func(n: String) -> void: changes.append(n))
	c.note_guild("NoCrest", 5, 0)
	_check(changes.is_empty() and c.texture_for("NoCrest") == null and sent.is_empty(), "no crest: nothing asked, nothing drawn")
	var gid := 900000 + randi() % 99999
	c.note_guild("Verizon", gid, 2)
	_check(changes == ["Verizon"], "a newly known crest redraws its lines once")
	c.note_guild("Verizon", gid, 2)
	_check(changes.size() == 1, "the same note again changes nothing")
	_check(c.texture_for("Verizon") == null and sent.size() == 1 and sent[0][0] == CrestNet.OP_CREST_GET
		and sent[0][1] == CrestNet.encode_get(1, gid, 2), "not here: asked for, once")
	c.texture_for("Verizon")
	_check(sent.size() == 1, "not asked twice")
	var reply := PackedByteArray([1])
	var idrev := PackedByteArray()
	idrev.resize(8)
	idrev.encode_u32(0, gid)
	idrev.encode_u32(4, 2)
	reply.append_array(idrev)
	reply.append(1)
	reply.append_array(px)
	c.handle_data(reply)
	_check(changes.size() == 2 and c.texture_for("Verizon") != null, "its bytes came: drawn, the lines told")
	# Kept on disk under its revision: a new cache finds it without asking.
	var c2 := CrestCache.new()
	c2.palette = pal
	var sent2: Array = []
	c2.send = func(op: int, payload: PackedByteArray) -> void: sent2.append(op)
	c2.note_guild("Verizon", gid, 2)
	_check(c2.texture_for("Verizon") != null and sent2.is_empty(), "the kept file serves its revision")
	c2.note_guild("Verizon", gid, 3)
	_check(c2.texture_for("Verizon") == null and sent2.size() == 1, "a newer revision is asked for")
	# 0x3257 rev 0 clears it.
	var clear := PackedByteArray([1, 0, 0, 0, 0, 7, 0]) + "Verizon".to_utf8_buffer() + PackedByteArray([0, 0, 0, 0])
	clear.encode_u32(1, gid)
	c.handle_update(clear)
	_check(c.texture_for("Verizon") == null and c.rev_of("Verizon") == 0, "rev 0: no crest")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://crest/G%d.rd" % gid))

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
