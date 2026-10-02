extends Control
class_name CharCreateSlider

## One of the customize panel's five sliders: retail's CIFSliderCtrl (ids
## 45..49, 120x24 in the `Custom` section) built from the layout's `Slider`
## section (READ, the create layouts):
##   71 GDR_BTN_PREV   arrow_left.ddj   at (0, 2), 20x20
##   72 GDR_BTN_NEXT   arrow_right.ddj  at (120, 2), 20x20
##   73 GDR_BTN_THUMB  slider.ddj       at (20, 0), 16x24
## each with its `_focus` / `_press` art (MEASURED: present for all three).
## OnCreate (0x8503ab..0x8503b4) builds each slider from those three ids
## (FUN_00659620(0x47, 0x48, 0x49) -- the button ids as given there) and sets
## its track to 0x54 = 84 (FUN_00659840).
##
## INFERRED (the slider's own draw and drag are not read): the thumb travels
## the 84 pixels from x 20 (the prev arrow's right edge) to x 104, where its
## right edge meets the slider's own width 120; value v of [min, max] puts it
## at 20 + 84 * (v - min) / (max - min). An arrow steps the value by one
## (the range's step is 1, FUN_006599e0's third argument). Dragging the thumb
## sets the nearest value. The track itself is drawn by the panel's art
## (customize_window.ddj), not by the slider.

signal value_changed(value: int)
signal hovered

const TRACK_X := 20.0
const TRACK_LEN := 84.0
const THUMB_W := 16.0

var min_value := 0
var max_value := 0
var value := 0
var prev_button: TextureButton
var next_button: TextureButton
var thumb: TextureButton
var _dragging := false

## `art` maps 71/72/73 to [normal, focus, press] textures (any may be null);
## `defs` maps them to their ControlDefs (for the rects).
func build(defs: Dictionary, art: Dictionary) -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	prev_button = _button(defs.get(CharCreateModel.ID_SLIDER_PREV), art.get(CharCreateModel.ID_SLIDER_PREV, []))
	next_button = _button(defs.get(CharCreateModel.ID_SLIDER_NEXT), art.get(CharCreateModel.ID_SLIDER_NEXT, []))
	thumb = _button(defs.get(CharCreateModel.ID_SLIDER_THUMB), art.get(CharCreateModel.ID_SLIDER_THUMB, []))
	prev_button.pressed.connect(func(): _user_set(value - 1))
	next_button.pressed.connect(func(): _user_set(value + 1))
	thumb.button_down.connect(func(): _dragging = true)
	thumb.button_up.connect(func(): _dragging = false)
	mouse_entered.connect(func(): hovered.emit())
	for b in [prev_button, next_button, thumb]:
		b.mouse_entered.connect(func(): hovered.emit())
	_place_thumb()

func _button(d: UiLayoutParser.ControlDef, tex: Array) -> TextureButton:
	var b := TextureButton.new()
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_SCALE
	if d != null:
		b.position = Vector2(d.rect.position)
		b.size = Vector2(d.rect.size)
	if tex.size() > 0: b.texture_normal = tex[0]
	if tex.size() > 1: b.texture_hover = tex[1]
	if tex.size() > 2: b.texture_pressed = tex[2]
	b.focus_mode = Control.FOCUS_NONE
	add_child(b)
	return b

func set_range(lo: int, hi: int) -> void:
	min_value = lo
	max_value = maxi(hi, lo)
	set_value_quiet(value)

## Sets the value without emitting (the model already holds it).
func set_value_quiet(v: int) -> void:
	value = clampi(v, min_value, max_value)
	_place_thumb()

func _user_set(v: int) -> void:
	v = clampi(v, min_value, max_value)
	if v == value:
		return
	value = v
	_place_thumb()
	value_changed.emit(value)

## The thumb's x for a value (INFERRED, header).
static func thumb_x(v: int, lo: int, hi: int) -> float:
	if hi <= lo:
		return TRACK_X
	return TRACK_X + TRACK_LEN * float(clampi(v, lo, hi) - lo) / float(hi - lo)

## The value nearest a thumb x (the drag).
static func value_at(x: float, lo: int, hi: int) -> int:
	if hi <= lo:
		return lo
	var u := clampf((x - TRACK_X) / TRACK_LEN, 0.0, 1.0)
	return lo + int(roundf(u * float(hi - lo)))

func _place_thumb() -> void:
	if thumb != null:
		thumb.position.x = thumb_x(value, min_value, max_value)

func _input(event: InputEvent) -> void:
	if not _dragging:
		return
	if event is InputEventMouseMotion:
		var local := get_local_mouse_position()
		_user_set(value_at(local.x - THUMB_W * 0.5, min_value, max_value))
	elif event is InputEventMouseButton and not (event as InputEventMouseButton).pressed:
		_dragging = false
