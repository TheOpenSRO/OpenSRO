extends TextureRect
class_name QuestInfoGuide

## The quest-information guide icon under the minimap (round 785, the user's
## request): GDR_QUESTINFO_GUIDE, class CIFQuestInfoGuide (ginterface id 46),
## READ from sro_client.exe:
##
## - **Look:** 40x40, alternating `icon\etc\qstinfoic_1.ddj` and
##   `qstinfoic_2.ddj`, two frames at 500 ms (vslot_010 0x731b50). The
##   archive's `qstinfoic_3` / `_4` are referenced by no code (MEASURED).
## - **Place:** it lives in CAlramGuideMgrWnd (GDR 158), anchored at
##   (screen width - 6, 180) (FUN_0079f030, 0x79f2a3..0x79f2b6); each icon
##   sits 42 px further left, the first 42 px left of the anchor; every 4
##   icons a new row 44 px lower (FUN_0065c430). This client has no other
##   alarm icon, so it is always the first. INFERRED: the 42 px is the
##   icon's left edge from the anchor.
## - **When:** only at a level-up (Client_ApplyExpAndLevelUp ->
##   FUN_00798f60(1) -> FUN_00940210(newLevel, race, out, 40)), shown when
##   that count is above 0 and removed when it is 0 (QuestHud.on_level_up).
##   No server message drives it.
## - **Click (vslot_029):** opens the quest information list with the
##   counted quests and hides the icon (FUN_0065c870 removes it from the
##   column).

signal clicked

const FRAMES := ["icon\\etc\\qstinfoic_1.ddj", "icon\\etc\\qstinfoic_2.ddj"]
const FRAME_MS := 500
const ICON_SIZE := Vector2(40, 40)
const ANCHOR_RIGHT_INSET := 6.0
const ANCHOR_Y := 180.0
const STEP_X := 42.0

var _frames: Array = []
## Seconds into the current frame (round 785's client review, finding 13: a
## float, so a frame's delta is never truncated -- whole milliseconds ran
## the flip ~4 % slow at 60 fps and never at 1000+ fps).
var _s := 0.0
var frame := 0

func _init(builder: UiBuilder = null) -> void:
	name = "QuestInfoGuide"
	size = ICON_SIZE
	custom_minimum_size = ICON_SIZE
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_SCALE
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	if builder != null:
		for p in FRAMES:
			_frames.append(builder.load_texture(p))
	if not _frames.is_empty():
		texture = _frames[0]

## The first slot of the alarm column for a screen of `view` size.
static func slot_position(view: Vector2, index: int = 0) -> Vector2:
	var col := index % 4
	var row := index / 4
	return Vector2(view.x - ANCHOR_RIGHT_INSET - STEP_X * float(col + 1), ANCHOR_Y + 44.0 * float(row))

func place(view: Vector2) -> void:
	position = slot_position(view)

func _process(delta: float) -> void:
	if not visible or _frames.size() < 2:
		return
	advance_seconds(delta)

## `ms` milliseconds on (advance_seconds in whole milliseconds).
func advance(ms: int) -> void:
	advance_seconds(float(ms) / 1000.0)

## `seconds` on: the frames flip every FRAME_MS.
func advance_seconds(seconds: float) -> void:
	_s += maxf(seconds, 0.0)
	var period := float(FRAME_MS) / 1000.0
	# A part in a billion short still flips: 499 ms then 1 ms is the frame's
	# whole 500 ms, whatever the sum rounds to.
	while _s >= period - 1e-9:
		_s = maxf(_s - period, 0.0)
		frame = (frame + 1) % 2
		if frame < _frames.size():
			texture = _frames[frame]

func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		clicked.emit()
