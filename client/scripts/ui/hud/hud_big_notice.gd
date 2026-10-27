extends Control
class_name HudBigNotice

## Round 837 (OURS; the user's request): a very large notice across the
## middle of the screen -- the server's 0x00D8 {u16 len, text}, sent to an
## account OPENSRO_LOGIN_NOTICES names when it enters the world. Not retail:
## the client's own notices (HudNotice) are one line of UI text. Built in UI
## units, so it scales with the UI.

## How long it stays, and the fade at its end (ms, OURS).
const SHOW_MS := 10000
const FADE_MS := 1500
## The text's size in UI pixels and its colours (OURS).
const FONT_PX := 72
const COLOR := Color(1.0, 0.85, 0.2)
const OUTLINE := Color(0.25, 0.0, 0.0)
const OUTLINE_PX := 10

var _label: Label
var _left_ms := 0

func _init() -> void:
	name = "BigNotice"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", FONT_PX)
	_label.add_theme_color_override("font_color", COLOR)
	_label.add_theme_color_override("font_outline_color", OUTLINE)
	_label.add_theme_constant_override("outline_size", OUTLINE_PX)
	add_child(_label)
	visible = false

## The face: the UI's own, bold when the system has a bold file.
func setup(builder: UiBuilder) -> void:
	if builder == null:
		return
	var f: Font = builder.font_at(0)
	var bold := HudNotice.bold_file(f) if f != null else null
	_label.add_theme_font_override("font", bold if bold != null else f)

## Sized from the screen, not anchored to its parent: HudPanels can be
## zero-sized under its layer, which left the text one letter wide.
func _fit() -> void:
	if not is_inside_tree():
		return
	top_level = true
	global_position = Vector2.ZERO
	size = get_viewport_rect().size
	_label.position = Vector2.ZERO
	_label.size = size

func show_text(text: String) -> void:
	_fit()
	_label.text = text
	_left_ms = SHOW_MS
	modulate.a = 1.0
	visible = text != ""
	move_to_front()

func text() -> String:
	return _label.text

func _process(delta: float) -> void:
	if not visible:
		return
	_fit()
	_left_ms -= int(delta * 1000.0)
	if _left_ms <= 0:
		visible = false
		return
	modulate.a = clampf(float(_left_ms) / FADE_MS, 0.0, 1.0)
