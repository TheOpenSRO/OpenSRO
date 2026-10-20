extends Control
class_name StripBars

## Round 800: the job suit's 10 seconds over a player's head (READ,
## CICUser::vslot_010 0x9dd350, the bar's half at 0x9dd47b..0x9dd5e8): while
## the object's strip seconds (+0x7bc, set with the tick at +0x7b8 by
## FUN_009dafe0 from 0x3041 type 2 sub 2) have not run out, one flat quad
## (FUN_00842230, no texture) is drawn at the head's projected point --
## height +0x22c plus 2.0, or the mount's plus 7.0 -- from x - 24 to x - 24 +
## seconds x 4.8 - trunc(elapsed / 100 ms) x 0.48, and from y + 10 to y + 12,
## in 0xffffee1f: 48 x 2 px of yellow at the start, shrinking to nothing at
## the end. 0x3042 (FUN_008825d0) zeroes the seconds. The head point here is
## the name plate's anchor, which sits at the same height (World3D).

const COLOUR := Color8(0xff, 0xee, 0x1f, 0xff)
const LEFT_PX := 24.0
const PX_PER_SECOND := 4.8
const PX_PER_100MS := 0.48
const TOP_PX := 10.0
const BOTTOM_PX := 12.0

## uid -> {"seconds": int, "start": msec}.
var bars := {}
## uid -> the world point the bar hangs under (null: not drawn).
var anchor_of: Callable
var camera_of: Callable

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

func start(uid: int, seconds: int, now_ms: int) -> void:
	if seconds <= 0:
		bars.erase(uid)
	else:
		bars[uid] = {"seconds": seconds, "start": now_ms}
	queue_redraw()

func stop(uid: int) -> void:
	bars.erase(uid)
	queue_redraw()

## The bar's rect at `elapsed_ms` from screen point `at`, or an empty rect
## once it has run out.
static func rect_at(at: Vector2, seconds: int, elapsed_ms: int) -> Rect2:
	if elapsed_ms > seconds * 1000:
		return Rect2()
	var x1 := at.x - LEFT_PX
	var x2 := x1 + float(seconds) * PX_PER_SECOND - float(int(elapsed_ms / 100)) * PX_PER_100MS
	return Rect2(Vector2(x1, at.y + TOP_PX), Vector2(maxf(x2 - x1, 0.0), BOTTOM_PX - TOP_PX))

func _process(_delta: float) -> void:
	if not bars.is_empty():
		queue_redraw()

func _draw() -> void:
	if bars.is_empty() or not camera_of.is_valid() or not anchor_of.is_valid():
		return
	var cam: Camera3D = camera_of.call()
	if cam == null:
		return
	var now := Time.get_ticks_msec()
	for uid in bars.keys():
		var b: Dictionary = bars[uid]
		var elapsed := now - int(b["start"])
		if elapsed > int(b["seconds"]) * 1000:
			bars.erase(uid)
			continue
		var p = anchor_of.call(int(uid))
		if p == null or cam.is_position_behind(p):
			continue
		var r := rect_at(cam.unproject_position(p), int(b["seconds"]), elapsed)
		if r.size.x > 0.0:
			draw_rect(r, COLOUR)
