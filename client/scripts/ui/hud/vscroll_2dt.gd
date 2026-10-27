extends RefCounted
class_name VScroll2dt

## A .2dt CNIFVerticalScroll record drawn on its own node (round 834): the
## up and down buttons, the track between them and the square thumb, in the
## Video tab's art (OptionVideoPage, READ there). The Key Map tab draws the
## same pieces (OptionKeyPage._build_scroll, round 833). `changed` gets the
## new line; the owner redraws its rows from it.

signal changed(line: int)

var line := 0
var max_line := 0
var _track: Control
var _thumb: Control

## Builds the pieces on `host` (the record's node) and takes the wheel over
## `pane` too. Returns null without a host.
static func build_on(host: Control, builder: UiBuilder, pane: Control = null) -> VScroll2dt:
	if host == null:
		return null
	var s := VScroll2dt.new()
	host.mouse_filter = Control.MOUSE_FILTER_STOP
	var w := host.size.x
	var track := TextureRect.new()
	track.name = "Track"
	track.texture = builder.load_texture(OptionVideoPage.SCROLL_BAR_DDJ) if builder != null else null
	track.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	track.stretch_mode = TextureRect.STRETCH_SCALE
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.position = Vector2(0, w)
	track.size = Vector2(w, maxf(host.size.y - 2.0 * w, 0.0))
	host.add_child(track)
	s._track = track
	var up := _button(builder, OptionVideoPage.SCROLL_UP_DDJ, Vector2.ZERO, Vector2(w, w))
	up.name = "Up"
	up.pressed.connect(func() -> void: s.scroll_to(s.line - 1))
	host.add_child(up)
	var down := _button(builder, OptionVideoPage.SCROLL_DOWN_DDJ, Vector2(0, host.size.y - w), Vector2(w, w))
	down.name = "Down"
	down.pressed.connect(func() -> void: s.scroll_to(s.line + 1))
	host.add_child(down)
	var thumb := TextureRect.new()
	thumb.name = "Thumb"
	thumb.texture = builder.load_texture(OptionVideoPage.SCROLL_THUMB_DDJ) if builder != null else null
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_SCALE
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb.size = Vector2(w, w)
	host.add_child(thumb)
	s._thumb = thumb
	s._place_thumb()
	host.gui_input.connect(func(e: InputEvent) -> void: s._track_input(e, host))
	if pane != null:
		pane.gui_input.connect(func(e: InputEvent) -> void: s._wheel(e))
	return s

static func _button(builder: UiBuilder, ddj: String, pos: Vector2, sz: Vector2) -> TextureButton:
	var b := TextureButton.new()
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_SCALE
	b.focus_mode = Control.FOCUS_NONE
	if builder != null:
		b.texture_normal = builder.load_texture(ddj)
		var base := ddj.substr(0, ddj.length() - 4)
		b.texture_hover = builder.load_texture(base + "_focus.ddj")
		b.texture_pressed = builder.load_texture(base + "_press.ddj")
	b.position = pos
	b.size = sz
	return b

## Sets the range: lines 0..`last` (0 when everything fits). The line is
## kept inside it.
func set_max_line(last: int) -> void:
	max_line = maxi(last, 0)
	if line > max_line:
		scroll_to(max_line)
	else:
		_place_thumb()

func scroll_to(to: int) -> void:
	var next := clampi(to, 0, max_line)
	if next == line:
		_place_thumb()
		return
	line = next
	_place_thumb()
	changed.emit(line)

func _track_input(e: InputEvent, host: Control) -> void:
	var mb := e as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_LEFT and _track != null:
		var f := clampf((mb.position.y - _track.position.y) / maxf(_track.size.y, 1.0), 0.0, 1.0)
		scroll_to(roundi(f * float(max_line)))
		host.accept_event()
		return
	_wheel(e)

func _wheel(e: InputEvent) -> void:
	var mb := e as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		scroll_to(line - 1)
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		scroll_to(line + 1)

func _place_thumb() -> void:
	if _thumb == null or _track == null:
		return
	var span := maxf(_track.size.y - _thumb.size.y, 0.0)
	var f := float(line) / float(maxi(max_line, 1))
	_thumb.position = Vector2(0, _track.position.y + span * f)
