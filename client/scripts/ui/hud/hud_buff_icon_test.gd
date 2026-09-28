extends SceneTree

## Round 624: the buff bar's icons as retail's screen shows them
## (HudBuffBoard.AUTHENTIC_ICONS). Synthetic images only -- no archive.
##
##   (a) the switch exists and is on
##   (b) the file: the skill row's col-61 path under `icon\`, the one the
##       skill window loads -- no small or state-icon variant
##   (c) the size: a 32x32 source becomes a 20x20 Image, and the slot's
##       texture is that 20x20
##   (d) the sampling: point samples at (2k+1)*32/40 in each axis (0x6529d0's
##       -0.5 quad edges, no sampler state on the sprite path)
##   (e) the filter: the icon is drawn nearest, so a UI scale shows retail's
##       20x20 pixels rather than the 32x32 file's
##   (f) review follow-up: AUTHENTIC_ICONS is a static var and its false path
##       draws the 32x32 file as before; UiBuilder.load_image reads a
##       synthetic DDJ from a stub archive, and a 16-bit, a 32-bit-with-mips
##       (pixel-format flags 0x41 with a stray 21 in the FourCC slot, the
##       four `*_balance_a` / `light_holy` icons' layout) and a DXT3-with-mips
##       source all come through retail_icon_image as 20x20 point samples
##
## Every new member is reached through get()/has_method()/call(), so the base
## (round 623's board, without them) runs to FAIL lines instead of a parse
## error -- that run is the round's negative.
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_buff_icon_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A 32x32 source whose texel (x, y) is colour (x, y, 7) / 255, opaque.
static func _coded_source(size: int = 32) -> Image:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			img.set_pixel(x, y, Color8(x, y, 7, 255))
	return img

## The static switch, read and written through the class's Script so the
## base (a const, or nothing) gives FAIL lines rather than a parse error.
func _switch() -> Variant:
	var sc: Script = HudBuffBoard
	return sc.get("AUTHENTIC_ICONS")

func _set_switch(on: bool) -> void:
	var sc: Script = HudBuffBoard
	sc.set("AUTHENTIC_ICONS", on)

func _test_constant() -> void:
	var board := HudBuffBoard.new(null, SkillBuffCatalog.new(null))
	var consts: Dictionary = board.get_script().get_script_constant_map()
	board.free()
	_check(_switch() == true or consts.get("AUTHENTIC_ICONS", false) == true,
		"HudBuffBoard.AUTHENTIC_ICONS exists and is on (one switch for a future toggle)")
	_check(not consts.has("AUTHENTIC_ICONS") and _switch() == true,
		"AUTHENTIC_ICONS is a static var, not a const, so a setting can flip it")

func _test_sampling() -> void:
	var board := HudBuffBoard.new(null, SkillBuffCatalog.new(null))
	if not board.has_method("retail_icon_image"):
		_check(false, "HudBuffBoard.retail_icon_image exists")
		_check(false, "32x32 -> 20x20 point samples at floor((2k+1)*32/40)")
		board.free()
		return
	var out: Image = board.call("retail_icon_image", _coded_source())
	_check(out != null and out.get_size() == Vector2i(20, 20), "a 32x32 icon becomes 20x20")
	var want := [0, 2, 4, 5, 7, 8, 10, 12, 13, 15, 16, 18, 20, 21, 23, 24, 26, 28, 29, 31]
	var ok := out != null
	if ok:
		for k in 20:
			var cx := out.get_pixel(k, 0)
			var cy := out.get_pixel(0, k)
			if roundi(cx.r * 255.0) != want[k] or roundi(cy.g * 255.0) != want[k]:
				ok = false
				print("  k %d: x texel %d y texel %d, want %d" % [k, roundi(cx.r * 255.0), roundi(cy.g * 255.0), want[k]])
	_check(ok, "pixel k is texel floor((2k+1)*32/40): 0 2 4 5 7 8 10 12 13 15 16 18 20 21 23 24 26 28 29 31")
	# No blend: every output pixel is one source texel's exact colour.
	var pure := out != null
	if pure:
		for y in 20:
			for x in 20:
				var c := out.get_pixel(x, y)
				if roundi(c.b * 255.0) != 7 or not is_equal_approx(c.a, 1.0):
					pure = false
	_check(pure, "point sampling: no two texels blended into one pixel")
	# A 20x20 source (s_goldtime_icon's size) comes back unchanged.
	var native: Image = board.call("retail_icon_image", _coded_source(20))
	var same := native != null and native.get_size() == Vector2i(20, 20)
	if same:
		for k in 20:
			if roundi(native.get_pixel(k, k).r * 255.0) != k:
				same = false
	_check(same, "a 20x20 source is drawn 1:1")
	board.free()

func _test_slot() -> void:
	var cat := SkillBuffCatalog.new(null)
	var r := {"id": 113, "level": 1, "icon": "skill\\china\\lightning_gyeonggong_a.ddj",
		"name_code": "SN_X", "desc_code": "", "walk_complete": true}
	for t in SkillBuffCatalog.BUFF_TAGS:
		r[t] = false
	cat.set_row(r)
	var board := HudBuffBoard.new(null, cat)
	board.sound_player = func(_p: String) -> void: pass
	board.ui_text = func(t: String) -> String: return t
	var asked: Array = []
	var src := _coded_source()
	board.set("icon_image_source", func(path: String) -> Image:
		asked.append(path)
		return src)
	board.setup()
	board.add_buff(-1, 113, 7001, 60000, 60000)
	var slot = board.buff(7001).slot
	_check(asked == ["icon\\skill\\china\\lightning_gyeonggong_a.ddj"],
		"the file read is col 61 under icon\\ -- the skill window's own (asked %s)" % str(asked))
	var tex: Texture2D = slot.icon.texture
	_check(tex != null and tex.get_size() == Vector2(20, 20), "the slot's icon texture is 20x20 (was the 32x32 file)")
	_check(slot.icon.size == Vector2(20, 20), "drawn in a 20x20 rect")
	_check(slot.icon.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"the icon is filtered nearest (texture_filter %d; the base left 0, inherit -> the canvas linear)" % slot.icon.texture_filter)
	board.add_buff(-1, 113, 7002, 60000, 60000)
	_check(asked.size() == 1, "a second icon of the same skill reuses the cached image")
	board.free()

func _test_false_path() -> void:
	if _switch() != true:
		_check(false, "AUTHENTIC_ICONS can be switched off (a static var)")
		return
	var cat := SkillBuffCatalog.new(null)
	var r := {"id": 5, "level": 1, "icon": "skill\\china\\y.ddj", "name_code": "SN_Y", "desc_code": "",
		"walk_complete": true}
	for t in SkillBuffCatalog.BUFF_TAGS:
		r[t] = false
	cat.set_row(r)
	_set_switch(false)
	var board := HudBuffBoard.new(null, cat)
	board.sound_player = func(_p: String) -> void: pass
	board.ui_text = func(t: String) -> String: return t
	var asked: Array = []
	board.set("icon_image_source", func(path: String) -> Image:
		asked.append(path)
		return Image.create(32, 32, false, Image.FORMAT_RGBA8))
	board.setup()
	board.add_buff(-1, 5, 7101, 60000, 60000)
	var slot = board.buff(7101).slot
	_check(asked.is_empty(), "switched off: no 20x20 resample is made")
	_check(slot.icon.texture_filter == CanvasItem.TEXTURE_FILTER_PARENT_NODE,
		"switched off: the icon inherits the canvas's linear filter, as rounds 618-623 drew it")
	_check(slot.icon.texture == null, "switched off, no archive: the 32x32 path has nothing to load")
	board.free()
	_set_switch(true)
	_check(_switch() == true, "switched back on")

## A Media.pk2 stand-in serving files from memory under their folders. No
## archive is shipped (docs/LEGAL.md): every file is built below.
class StubMedia extends Pk2Reader:
	var tree := {}   # folder path ("" = root) -> Array[Pk2Reader.Entry]
	var files := {}  # Entry -> PackedByteArray
	var dirs := {}   # Entry -> folder path
	func add(path: String, data: PackedByteArray) -> void:
		var parts := path.split("\\")
		var at := ""
		for i in parts.size():
			if not tree.has(at):
				var none: Array[Pk2Reader.Entry] = []
				tree[at] = none
			var name := parts[i]
			var next := name if at == "" else at + "\\" + name
			var found: Pk2Reader.Entry = null
			for e in tree[at]:
				if e.name == name:
					found = e
			if found == null:
				found = Pk2Reader.Entry.new()
				found.name = name
				found.is_dir = i < parts.size() - 1
				tree[at].append(found)
				if found.is_dir:
					dirs[found] = next
				else:
					files[found] = data
					found.size = data.size()
			at = next
	func read_dir() -> Array[Pk2Reader.Entry]:
		var none: Array[Pk2Reader.Entry] = []
		return tree.get("", none)
	func read_dir_at(dir: Pk2Reader.Entry) -> Array[Pk2Reader.Entry]:
		var none: Array[Pk2Reader.Entry] = []
		return tree.get(dirs.get(dir, "?"), none)
	func read_file(file: Pk2Reader.Entry) -> PackedByteArray:
		return files.get(file, PackedByteArray())

static func _u32(b: PackedByteArray, v: int) -> void:
	b.append(v & 0xff)
	b.append((v >> 8) & 0xff)
	b.append((v >> 16) & 0xff)
	b.append((v >> 24) & 0xff)

## A synthetic DDJ: the 20-byte JMXV wrapper, a DDS header and `payload`.
static func _ddj(w: int, h: int, mips: int, pf_flags: int, fourcc: int, bits: int,
		masks: Array, payload: PackedByteArray) -> PackedByteArray:
	var dds := PackedByteArray("DDS ".to_ascii_buffer())
	_u32(dds, 124)
	_u32(dds, 0x1007 | (0x20000 if mips > 1 else 0))
	_u32(dds, h)
	_u32(dds, w)
	_u32(dds, 0)
	_u32(dds, 0)
	_u32(dds, mips)
	for i in 11:
		_u32(dds, 0)
	_u32(dds, 32)
	_u32(dds, pf_flags)
	_u32(dds, fourcc)
	_u32(dds, bits)
	for m in masks:
		_u32(dds, m)
	for i in 5:
		_u32(dds, 0)
	var out := PackedByteArray("JMXVDDJ 1000".to_ascii_buffer())
	_u32(out, dds.size() + payload.size() + 8)
	_u32(out, 0)
	out.append_array(dds)
	out.append_array(payload)
	return out

## The point-sample texel of output pixel k on a 32-texel side.
const WANT := [0, 2, 4, 5, 7, 8, 10, 12, 13, 15, 16, 18, 20, 21, 23, 24, 26, 28, 29, 31]

## Whether `out` (20x20) is `src` point-sampled at WANT in both axes.
func _is_point_sample(out: Image, src: Image) -> bool:
	if out == null or src == null or out.get_size() != Vector2i(20, 20):
		return false
	for y in 20:
		for x in 20:
			if not out.get_pixel(x, y).is_equal_approx(src.get_pixel(WANT[x], WANT[y])):
				return false
	return true

func _test_load_image() -> void:
	var media := StubMedia.new()
	# A1R5G5B5: texel (x, y) is r5 = x, g5 = y, opaque.
	var p16 := PackedByteArray()
	for y in 32:
		for x in 32:
			var v := 0x8000 | (x << 10) | (y << 5)
			p16.append(v & 0xff)
			p16.append(v >> 8)
	media.add("icon\\skill\\t16.ddj", _ddj(32, 32, 0, 0x41, 0, 16, [0x7c00, 0x3e0, 0x1f, 0x8000], p16))
	# A8R8G8B8 with 6 mips, flags 0x41 and a stray 21 in the FourCC slot:
	# r = 8x, g = 8y; the mip levels are filler.
	var p32 := PackedByteArray()
	for y in 32:
		for x in 32:
			p32.append_array(PackedByteArray([0, 8 * y, 8 * x, 255]))
	for lv in [16, 8, 4, 2, 1]:
		var fill := PackedByteArray()
		fill.resize(lv * lv * 4)
		fill.fill(0x5a)
		p32.append_array(fill)
	media.add("icon\\skill\\t32.ddj", _ddj(32, 32, 6, 0x41, 21, 32,
		[0xff0000, 0xff00, 0xff, 0xff000000], p32))
	# DXT3 with 6 mips: block (bx, by) is one 565 colour, r5 = 4bx, g6 = 8by.
	var dxt := PackedByteArray()
	for lv in [32, 16, 8, 4, 2, 1]:
		var n: int = maxi(1, lv / 4)
		for by in n:
			for bx in n:
				for i in 8:
					dxt.append(0xff)
				var c := ((4 * bx) << 11) | ((8 * by) << 5)
				dxt.append(c & 0xff)
				dxt.append(c >> 8)
				dxt.append(c & 0xff)
				dxt.append(c >> 8)
				_u32(dxt, 0)
	media.add("icon\\skill\\t3.ddj", _ddj(32, 32, 6, 0x4, 0x33545844, 0, [0, 0, 0, 0], dxt))
	var builder := UiBuilder.new(media)
	if not builder.has_method("load_image"):
		_check(false, "UiBuilder.load_image exists")
		return
	var board := HudBuffBoard.new(null, SkillBuffCatalog.new(null))
	for name in ["t16", "t32", "t3"]:
		var src: Image = builder.call("load_image", "icon\\skill\\%s.ddj" % name)
		_check(src != null and src.get_size() == Vector2i(32, 32), "load_image decodes %s to 32x32" % name)
		if src == null or not board.has_method("retail_icon_image"):
			continue
		var out: Image = board.call("retail_icon_image", src)
		_check(_is_point_sample(out, src.duplicate() if not src.is_compressed() else _decompressed(src)),
			"%s: retail_icon_image is its 20x20 point sample" % name)
		if name == "t16":
			var ok := true
			for k in 20:
				var c := out.get_pixel(k, k)
				if absi(roundi(c.r * 31.0) - WANT[k]) > 0 or absi(roundi(c.g * 31.0) - WANT[k]) > 0:
					ok = false
			_check(ok, "t16: pixel k carries 5-bit value WANT[k] in red and green")
		elif name == "t32":
			var ok := true
			for k in 20:
				var c := out.get_pixel(k, 0)
				if roundi(c.r * 255.0) != 8 * WANT[k]:
					ok = false
			_check(ok, "t32 (flags 0x41, FourCC slot 21, 6 mips): the top level, pixel k red 8*WANT[k]")
		else:
			var ok := true
			for k in 20:
				var c := out.get_pixel(k, 0)
				if roundi(c.r * 31.0) != 4 * (WANT[k] / 4):
					ok = false
			_check(ok, "t3 (DXT3, 6 mips): the top level, pixel k in block WANT[k] / 4")
	_check(builder.call("load_image", "icon\\skill\\missing.ddj") == null, "load_image: a missing file is null")
	board.free()

static func _decompressed(src: Image) -> Image:
	var d := src.duplicate() as Image
	d.decompress()
	d.clear_mipmaps()
	d.convert(Image.FORMAT_RGBA8)
	return d

func _init() -> void:
	_test_constant()
	_test_sampling()
	_test_slot()
	_test_false_path()
	_test_load_image()
	if _failures == 0:
		print("hud_buff_icon_test: all passed")
	else:
		print("hud_buff_icon_test: %d FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
