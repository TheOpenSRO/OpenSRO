extends Control
class_name DurabilityMark

## Round 829: what a slot draws over a worn-out item, READ from sro_client.exe
## (the slot draw 0x67cfb0, block 0x67dfb8..0x67e2c7; the textures loaded by
## CIFSlotWithHelp::vslot_010 0x66b460):
##
## - The icon is never darkened: every mark is a quad of its own over it (FVF
##   0x104, no vertex colour); the red is the textures'.
## - **Broken** (durability 0 on an item with a maximum, +0xf4 != 0: the
##   usable check 0x8bb570's bit 4): `icon\icon_item_broken.ddj`, a still red
##   box (MEASURED: a 3-pixel red border round a 50 % red fill).
## - **Low** (1..6 points, `cmp eax,6; jg` at 0x67e0fa, on equipment that is
##   not an accessory -- 0x56fb40 -- with a maximum): `icon\icon_item_warning.ddj`,
##   a 128 x 64 sheet of 16 x 16 cells, frame n = ftol(c / 17 x 16) at cell
##   (n % 8, n / 8), stretched over the icon. c is the interface's counter
##   +0x4ec, one step a tick of timer 3 (80 ms, 0x7872b0), wrapping at 17
##   (CGInterface::vslot_005 case 3, 0x789e66): a 1360 ms loop -- a red disc
##   growing to a full square and hollowing to a ring (MEASURED). Only the bag
##   and the equipment slots are handed the counter (0x6b3df0, 0x6ab870); a
##   quick slot's copy stays on frame 0 (INFERRED from that).
## - Which slots: the bag (0x46), the equipment (0x47) and a quick slot of a
##   bag or worn item (0x0c / 0x46, 0x47); not the storage, the exchange or a
##   store.
## Not built (OPEN): `icon\icon_disable.ddj`, drawn instead when an item fails
## the usable check for another reason too (a level, a race).

const BROKEN_DDJ := "icon\\icon_item_broken.ddj"
const WARNING_DDJ := "icon\\icon_item_warning.ddj"
const NODE := "DurabilityMark"
const LOW_MAX := 6
const TICK_MS := 80
const STEPS := 17
const FRAMES := 16
const CELL := Vector2(16, 16)
const COLUMNS := 8

enum State { NONE, LOW, BROKEN }

var state := State.NONE
var broken_tex: Texture2D
var warning_tex: Texture2D
## False on a quick slot: no counter, frame 0.
var animate := true

## The mark an item gets: `types` its TypeIDs, `cur` / `maximum` its
## durability (maximum 0: untracked).
static func state_for(types: PackedInt32Array, cur: int, maximum: int) -> int:
	if maximum <= 0:
		return State.NONE
	if cur <= 0:
		return State.BROKEN
	var equipment := types.size() >= 3 and types[0] == 3 and types[1] == 1 and types[2] != 5 and types[2] != 12
	return State.LOW if equipment and cur <= LOW_MAX else State.NONE

## The interface counter now (0..16).
static func counter_now() -> int:
	return int(Time.get_ticks_msec() / TICK_MS) % STEPS

## The warning's frame for counter c (0..15).
static func frame_for(c: int) -> int:
	return int(float(c) / float(STEPS) * float(FRAMES))

## Puts (or takes off) the mark on `icon`.
static func apply(icon: Control, mark_state: int, broken: Texture2D, warning: Texture2D, animated := true) -> void:
	if icon == null or not is_instance_valid(icon):
		return
	var m := icon.get_node_or_null(NODE) as DurabilityMark
	if mark_state == State.NONE:
		if m != null:
			m.queue_free()
			icon.remove_child(m)
		return
	if m == null:
		m = DurabilityMark.new()
		m.name = NODE
		m.mouse_filter = Control.MOUSE_FILTER_IGNORE
		m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		icon.add_child(m)
	m.state = mark_state
	m.broken_tex = broken
	m.warning_tex = warning
	m.animate = animated
	m.set_process(mark_state == State.LOW and animated)
	m.queue_redraw()

## The state on `icon`, NONE without a mark.
static func state_on(icon: Control) -> int:
	var m := icon.get_node_or_null(NODE) as DurabilityMark if icon != null else null
	return m.state if m != null else State.NONE

var _last_frame := -1

func _process(_delta: float) -> void:
	var f := frame_for(counter_now())
	if f != _last_frame:
		_last_frame = f
		queue_redraw()

func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if state == State.BROKEN and broken_tex != null:
		draw_texture_rect(broken_tex, r, false)
	elif state == State.LOW and warning_tex != null:
		var f := frame_for(counter_now()) if animate else 0
		draw_texture_rect_region(warning_tex, r, Rect2(Vector2(f % COLUMNS, f / COLUMNS) * CELL, CELL))
