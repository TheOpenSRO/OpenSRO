extends Control
class_name RepairFlash

## Round 829: the flash a slot plays when its item's durability rises (a
## repair), READ from sro_client.exe:
##
## - 0x3052's handler (0x8adf50) calls 0x6ab8a0(slot) for a worn slot or
##   0x6b44a0(slot) for a bag slot when the new durability is above the old,
##   and either runs 0x6665d0 on the slot: +0x660 = 20 and timer 1 at 50 ms
##   (0xb93320(1, 0x32)); CIFSlotWithHelp::vslot_005 (0x66bd2d) counts it
##   down a tick at a time and kills the timer at 0 -- 20 frames, 1 s.
## - The draw (0x67e305..0x67e49c): `icon\icon_mall_repair.ddj` (loaded to
##   +0x634 at 0x66b722), a 256 x 128 sheet of 32 x 32 cells, 8 across and 4
##   down; frame f = 20 - counter (0..19) is cell (f % 8, f / 8), drawn 72 x 72
##   at the slot's (x - 20, y - 20), over the 32 x 32 icon. No blend state is
##   set there, so the UI's alpha blend (INFERRED); x, y the slot's top-left
##   (INFERRED).
## MEASURED (the sheet): frames 0..8 sparks bursting yellow-white to red, 9
## empty, 10..18 a white glint sweeping across, 19 empty.

const DDJ := "icon\\icon_mall_repair.ddj"
const FRAMES := 20
const TICK_MS := 50
const CELL := Vector2(32, 32)
const COLUMNS := 8
const DRAWN := Vector2(72, 72)
const OFFSET := Vector2(-20, -20)

var sheet: Texture2D
var _counter := FRAMES
var _acc_ms := 0.0

## Plays the flash over `icon` (a slot's 32 x 32 icon). Null without the sheet.
static func play_on(icon: Control, tex: Texture2D) -> RepairFlash:
	if icon == null or tex == null or not is_instance_valid(icon):
		return null
	var old := icon.get_node_or_null("RepairFlash")
	if old != null:
		# 0x6665d0 starts it again.
		(old as RepairFlash).restart()
		return old as RepairFlash
	var f := RepairFlash.new()
	f.name = "RepairFlash"
	f.sheet = tex
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	f.position = OFFSET
	f.size = DRAWN
	f.z_index = 1
	icon.add_child(f)
	return f

func restart() -> void:
	_counter = FRAMES
	_acc_ms = 0.0
	queue_redraw()

## The frame shown now, 0..19.
func frame() -> int:
	return FRAMES - _counter

## `ms` of time (the process tick; tests call it).
func step(ms: float) -> void:
	_acc_ms += ms
	while _acc_ms >= TICK_MS and _counter > 0:
		_acc_ms -= TICK_MS
		_counter -= 1
	if _counter <= 0:
		queue_free()
	else:
		queue_redraw()

func _process(delta: float) -> void:
	step(delta * 1000.0)

func _draw() -> void:
	if sheet == null or _counter <= 0:
		return
	var f := frame()
	var src := Rect2(Vector2(f % COLUMNS, f / COLUMNS) * CELL, CELL)
	draw_texture_rect_region(sheet, Rect2(Vector2.ZERO, DRAWN), src)
