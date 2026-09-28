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

func _test_constant() -> void:
	var consts: Dictionary = HudBuffBoard.new(null, SkillBuffCatalog.new(null)).get_script().get_script_constant_map()
	_check(consts.has("AUTHENTIC_ICONS"), "HudBuffBoard.AUTHENTIC_ICONS exists (one switch for a future toggle)")
	_check(consts.get("AUTHENTIC_ICONS", false) == true, "AUTHENTIC_ICONS is on")

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

func _init() -> void:
	_test_constant()
	_test_sampling()
	_test_slot()
	if _failures == 0:
		print("hud_buff_icon_test: all passed")
	else:
		print("hud_buff_icon_test: %d FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
