extends RefCounted
class_name SkillDelayOverlay

## A skill slot's re-use display (round 785; corrected round 786), as retail's
## CIFSlotWithHelp draws it. Labels: READ, MEASURED, INFERRED, OURS.
##
## READ (`sro_client.exe`, UI_SILKMALL::FUN_0067cfb0, from
## CIFSlotWithHelp::vslot_013 0x685e50 after the icon, unless the slot's
## +0x64c byte is set -- 0 from the constructor 0x673c80):
## - a skill slot -- kind 0x49 (the skill window's: CIFSkillSlot::Create
##   0x6a0980 sets its slot child's kind to 0x49 at 0x6a09e5), or a quick
##   slot (kind 0x0c) whose sub-kind (+0x370) is 0x49 or 0x19 (the hotbar's
##   skills) -- whose skill (+0x65c) passes 0x9c0b90 (learned), 0x9372b0 or
##   0x93f5d0 asks SkillCoolTimeManager::FUN_009bb9c0 (through 0x778bb0) for
##   left / total; not 0 ->
##   frame = ftol(239.0 - r * 239.0) (0xda3760), column = frame & 15,
##   row = frame >> 4, drawn with the slot's +0x620 texture
##   (`interface\skill\skill_delay.ddj`, loaded by vslot_010 0x66b460) over
##   the slot's own quad with UVs u = column * 32.0 (0xd99a60) * 1/512
##   (0xda3768), v = row * 32 * 1/512, each cell 32/512 = 1/16 of the sheet;
## - when that is 0: FUN_009bbb60 (the 500 ms tail / 500); not 0 ->
##   frame = ftol(15.0 - f * 15.0) (0xd878a0), column = frame & 3,
##   row = frame >> 2, the +0x624 texture (`skill_charge.ddj`), UVs
##   column * 16.0 (0xe1b8e0) * 1/64 (0xda3758): each cell 1/4 of the sheet.
## The UVs are fractions of the sheet, so the cell is 1/16 (1/4) of whatever
## the sheet's size is. MEASURED (Media.pk2): skill_delay.ddj is 256 x 256
## (A8R8G8B8, no mips) -- a 16 x 16 grid of 16-pixel cells, 240 frames used
## (row 15 empty), frame 0 the whole cell dark; skill_charge.ddj is 64 x 64
## (A8R8G8B8), a 4 x 4 grid of 16-pixel cells. The 512 in the constants is
## not the sheet's size: round 785 read it as one and cut 32-pixel regions,
## which on the 256 sheet is 2 x 2 cells -- four small sweeps in the slot
## (round 786's bug).
##
## Both are drawn over the slot's whole quad (the icon's 32 x 32), stretched:
## a 16-pixel cell covers the 32-pixel icon. MEASURED (the sheet): black at
## alpha 185 where time remains, clear where it has passed, the clear part
## growing clockwise from 12 o'clock.
##
## Not here (READ, OPEN): a quick slot (kind 0x0c) also prints the time left
## (0x67c920 with 0x9bba90's ms: seconds under 61, minutes under 3601, a
## third draw beyond that not read);
## the skill window's kind-0x49 slot does not.

const NODE := "Delay"
const DELAY_DDJ := "interface\\skill\\skill_delay.ddj"
const CHARGE_DDJ := "interface\\skill\\skill_charge.ddj"
## Cells per row and per column of each sheet (READ: 32 * 1/512, 16 * 1/64).
const DELAY_GRID := 16
const CHARGE_GRID := 4

## The pixel region of `frame` on a sheet of `sheet_size` cut in a
## `grid` x `grid` grid (column = frame % grid, row = frame / grid), as
## 0x67cfb0's UVs pick it.
static func cell_region(sheet_size: Vector2, grid: int, frame: int) -> Rect2:
	var cell := sheet_size / float(grid)
	@warning_ignore("integer_division")
	var row := frame / grid
	return Rect2(Vector2(frame % grid, row) * cell, cell)

## Shows the delay cell `delay_frame` (or, when it is -1, the charge cell
## `charge_frame`) over `host`, in `rect` (the icon's rect, host-local; an
## empty rect fills the host); both -1 hides it. `sheet_for(path)` returns
## the sheet's texture (UiBuilder.load_texture). The overlay is made on first
## use and put just after `after` (the icon) when given, else at the end of
## host's children.
static func apply(host: Control, sheet_for: Callable, delay_frame: int, charge_frame: int,
		rect: Rect2, after: Node = null) -> void:
	var over := host.get_node_or_null(NODE) as TextureRect
	if delay_frame < 0 and charge_frame < 0:
		if over != null:
			over.visible = false
		return
	if over == null:
		over = TextureRect.new()
		over.name = NODE
		over.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		over.stretch_mode = TextureRect.STRETCH_SCALE
		over.mouse_filter = Control.MOUSE_FILTER_IGNORE
		host.add_child(over)
		if after != null and after.get_parent() == host:
			host.move_child(over, after.get_index() + 1)
		if rect.size == Vector2.ZERO:
			over.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var delay := delay_frame >= 0
	var path := DELAY_DDJ if delay else CHARGE_DDJ
	var tex: Texture2D = sheet_for.call(path) if sheet_for.is_valid() else null
	if tex == null:
		over.visible = false
		return
	if rect.size != Vector2.ZERO:
		over.position = rect.position
		over.size = rect.size
	var atlas := over.texture as AtlasTexture
	if atlas == null:
		atlas = AtlasTexture.new()
	var frame := delay_frame if delay else charge_frame
	atlas.atlas = tex
	atlas.region = cell_region(tex.get_size(), DELAY_GRID if delay else CHARGE_GRID, frame)
	over.texture = atlas
	over.set_meta("sheet", "delay" if delay else "charge")
	over.set_meta("frame", frame)
	over.visible = true

## What `host`'s overlay shows: [sheet ("delay" / "charge"), frame, region]
## or [] (tests, QA).
static func shown(host: Control) -> Array:
	var over := host.get_node_or_null(NODE) as TextureRect if host != null else null
	if over == null or not over.visible or not (over.texture is AtlasTexture):
		return []
	return [String(over.get_meta("sheet", "")), int(over.get_meta("frame", -1)),
		(over.texture as AtlasTexture).region]
