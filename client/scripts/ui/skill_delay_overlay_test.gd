extends SceneTree

## A skill slot's re-use display (SkillDelayOverlay, round 786): one cell of
## skill_delay.ddj / skill_charge.ddj stretched over the whole icon. The
## sheets are synthetic, at the MEASURED sizes of the real ones (256 x 256 and
## 64 x 64, Media.pk2) -- no archive:
##   godot4 --headless --path client --script res://scripts/ui/skill_delay_overlay_test.gd
##
## Round 785 cut 32-pixel cells (it read 0x67cfb0's `32 * 1/512` as a 512
## sheet of 32-pixel cells); on the real 256 sheet that is 2 x 2 cells, four
## small sweeps in the slot. These checks fail on that.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_arithmetic()
	_node()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## A synthetic sheet of `size` x `size`.
static func sheet(size: int) -> Texture2D:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0.5))
	return ImageTexture.create_from_image(img)

func _arithmetic() -> void:
	_check(int(SkillDelayOverlay.DELAY_GRID) == 16 and int(SkillDelayOverlay.CHARGE_GRID) == 4,
		"16 x 16 delay cells, 4 x 4 charge cells (0x67cfb0: 32 * 1/512, 16 * 1/64)")
	var d := Vector2(256, 256)
	_check(SkillDelayOverlay.cell_region(d, 16, 0) == Rect2(0, 0, 16, 16),
		"frame 0 of the 256 x 256 delay sheet is its 16-pixel top-left cell (got %s)" % SkillDelayOverlay.cell_region(d, 16, 0))
	_check(SkillDelayOverlay.cell_region(d, 16, 17) == Rect2(16, 16, 16, 16),
		"frame 17: column 17 & 15 = 1, row 17 >> 4 = 1 (got %s)" % SkillDelayOverlay.cell_region(d, 16, 17))
	_check(SkillDelayOverlay.cell_region(d, 16, 239) == Rect2(240, 224, 16, 16),
		"frame 239 (r just above 0): column 15, row 14 -- inside the sheet (got %s)" % SkillDelayOverlay.cell_region(d, 16, 239))
	var c := Vector2(64, 64)
	_check(SkillDelayOverlay.cell_region(c, 4, 5) == Rect2(16, 16, 16, 16) and SkillDelayOverlay.cell_region(c, 4, 15) == Rect2(48, 48, 16, 16),
		"the 64 x 64 charge sheet: frame 5 at (16,16), frame 15 at (48,48), 16-pixel cells")
	# The UVs are fractions of the sheet: a cell is 1/16 of any size.
	_check(SkillDelayOverlay.cell_region(Vector2(512, 512), 16, 17) == Rect2(32, 32, 32, 32),
		"a 512 sheet would have 32-pixel cells: the cell follows the sheet's size")
	# Every frame SkillCooldowns can pick lands in the sheet.
	var inside := true
	for r in [1.0, 0.75, 0.5, 0.01, 0.0001]:
		var f: int = SkillCooldowns.delay_frame(r)
		inside = inside and Rect2(Vector2.ZERO, d).encloses(SkillDelayOverlay.cell_region(d, 16, f))
	for f2 in [1.0, 0.5, 0.001]:
		inside = inside and Rect2(Vector2.ZERO, c).encloses(SkillDelayOverlay.cell_region(c, 4, SkillCooldowns.charge_frame(f2)))
	_check(inside, "every delay frame (0..239) and charge frame (0..15) is a cell inside its sheet")

func _node() -> void:
	var sheets := {SkillDelayOverlay.DELAY_DDJ: sheet(256), SkillDelayOverlay.CHARGE_DDJ: sheet(64)}
	var sheet_for := func(path: String) -> Texture2D: return sheets.get(path)
	var host := Control.new()
	host.size = Vector2(32, 32)
	var icon := TextureRect.new()
	icon.name = "Icon"
	host.add_child(icon)
	var count := Control.new()
	count.name = "Count"
	host.add_child(count)
	SkillDelayOverlay.apply(host, sheet_for, 17, -1, Rect2(), icon)
	var over := host.get_node_or_null(SkillDelayOverlay.NODE) as TextureRect
	_check(over != null and over.visible, "a running sweep shows the overlay")
	if over == null:
		host.free()
		return
	_check(over.get_index() == icon.get_index() + 1 and over.get_index() < count.get_index(),
		"the overlay sits right over the icon, under what follows it")
	var a := over.texture as AtlasTexture
	_check(a != null and a.region == Rect2(16, 16, 16, 16),
		"ONE 16-pixel cell of the 256 sheet, not a 32-pixel block of four (got %s)" % (str(a.region) if a else "none"))
	_check(over.anchor_right == 1.0 and over.anchor_bottom == 1.0 and over.expand_mode == TextureRect.EXPAND_IGNORE_SIZE
		and over.stretch_mode == TextureRect.STRETCH_SCALE, "stretched over the whole slot")
	_check(SkillDelayOverlay.shown(host) == ["delay", 17, Rect2(16, 16, 16, 16)], "shown() reports the sheet, frame and region")
	SkillDelayOverlay.apply(host, sheet_for, -1, 5, Rect2(), icon)
	_check(SkillDelayOverlay.shown(host) == ["charge", 5, Rect2(16, 16, 16, 16)] and (over.texture as AtlasTexture).atlas == sheets[SkillDelayOverlay.CHARGE_DDJ],
		"the charged flash: frame 5 of the 64 sheet, the same node (got %s)" % [SkillDelayOverlay.shown(host)])
	SkillDelayOverlay.apply(host, sheet_for, -1, -1, Rect2(), icon)
	_check(not over.visible and SkillDelayOverlay.shown(host) == [], "both -1 hides it")
	SkillDelayOverlay.apply(host, Callable(), 3, -1, Rect2(), icon)
	_check(not over.visible, "no sheet (no archive): nothing drawn")
	# A host larger than the icon (the skill window's 36 x 56 slot): the
	# overlay takes the icon's rect.
	var slot := Control.new()
	slot.size = Vector2(36, 56)
	SkillDelayOverlay.apply(slot, sheet_for, 0, -1, Rect2(0, 0, 32, 32))
	var o2 := slot.get_node_or_null(SkillDelayOverlay.NODE) as Control
	_check(o2 != null and o2.position == Vector2.ZERO and o2.size == Vector2(32, 32),
		"in a larger slot it covers the icon's 32 x 32")
	host.free()
	slot.free()
