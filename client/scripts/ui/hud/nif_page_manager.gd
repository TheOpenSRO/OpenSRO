extends Control
class_name NifPageManager

## Round 840 (lane N): retail's `CNIFPageManager` (a `.2dt` record of type
## 14), which draws its own pieces. Built for the stall network's page row
## (`res_ui\stallnetwork.2dt` id 16). Labels: READ (sro_client.exe), INFERRED,
## OURS.
##
## READ (c:0x485580 the constructor, 0x485690 its create, 0x485ee0 its
## buttons, 0x4866c0 SetPage, 0x485940 / 0x485b60 prev / next, 0x4863a0 the
## placing):
##   - prev / next buttons on `interface\mall\mall_page_prev.ddj` /
##     `mall_page_next.ddj`, sized to their textures, created hidden; prev is
##     shown only when a group of pages lies before the shown one, next when
##     one lies after it.
##   - four page buttons a group (+0x354 = 4), each 20 wide (+0x358 = 0x14),
##     captioned `%d` (the page number from 1); the current one in 0xffff9951
##     and bold (0x4774f0(0, 2)), the others 0xffffffff and plain
##     (0x477690(0, 2)); a group shows only the pages it has (the last group
##     of a count that is not a multiple of four is short).
##   - "[" left of the first page button and "]" right of the last (the wide
##     strings 0xe18b24 / 0xe18b28), shown while there is a page.
##   - the page buttons at the control's left edge (alignment +0x356 = 0), at
##     y = height / 2 - 7.
##   - prev moves to the previous group with its LAST page current; next to
##     the next group with its FIRST page current; a page button makes its page
##     current; each sends 0x8071 (here `page_changed(page)`) to the window.
## INFERRED (the placing's operands were read through a garbled decompile):
## prev 13 left of "[", next 4 right of "]"; the brackets 4 wide.

signal page_changed(page: int)

const PREV_DDJ := "interface\\mall\\mall_page_prev.ddj"
const NEXT_DDJ := "interface\\mall\\mall_page_next.ddj"
const GROUP := 4
const BUTTON_W := 20
const BUTTON_H := 14
const BRACKET_W := 4
const PREV_GAP := 13
const NEXT_GAP := 4
const CURRENT_COLOUR := Color8(0xff, 0x99, 0x51)
const NORMAL_COLOUR := Color.WHITE

## Pages in all (+0x348), the first page of the shown group (+0x34c), the
## current page (+0x350).
var count := 0
var group_start := 0
var current := 0

var _prev: TextureButton
var _next: TextureButton
var _open: Label
var _close: Label
var _buttons: Array[TextureButton] = []
var _font: Font
var _bold: Font

func _init(builder = null) -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	_font = builder.font_at(0) if builder != null else null
	# The weight-600 face (0x4774f0(0, 2)): the system's bold file, else the
	# simulation the chat's bold tab uses (round 848; was an embolden of 0.6).
	_bold = HudNotice.bold_file(_font) if _font != null else null
	if _bold == null and _font != null:
		var fv := FontVariation.new()
		fv.base_font = _font
		fv.variation_embolden = 0.6
		_bold = fv
	_prev = _arrow(builder, PREV_DDJ, "Prev")
	_prev.pressed.connect(press_prev)
	_next = _arrow(builder, NEXT_DDJ, "Next")
	_next.pressed.connect(press_next)
	_open = _bracket("[", "Open")
	_close = _bracket("]", "Close")
	# Round 848: a page button is an art-less button with a caption (the
	# client's page buttons draw only their number), not a Godot Button with
	# its styles emptied.
	for i in GROUP:
		var b := TextureButton.new()
		b.name = "Page%d" % i
		b.focus_mode = Control.FOCUS_NONE
		b.size = Vector2(BUTTON_W, BUTTON_H)
		b.custom_minimum_size = b.size
		var cap := Label.new()
		cap.name = "ButtonLabel"
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		cap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		if _font != null:
			cap.add_theme_font_override("font", _font)
		cap.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		b.add_child(cap)
		b.pressed.connect(press_index.bind(i))
		b.visible = false
		add_child(b)
		_buttons.append(b)
	_layout()

func _arrow(builder, ddj: String, node_name: String) -> TextureButton:
	var b := TextureButton.new()
	b.name = node_name
	b.focus_mode = Control.FOCUS_NONE
	var tex: Texture2D = builder.load_texture(ddj) if builder != null else null
	b.texture_normal = tex
	if builder != null:
		b.texture_hover = builder.load_texture(ddj.replace(".ddj", "_focus.ddj"))
		b.texture_pressed = builder.load_texture(ddj.replace(".ddj", "_press.ddj"))
	b.size = tex.get_size() if tex != null else Vector2(10, 11)
	b.visible = false
	add_child(b)
	return b

func _bracket(text: String, node_name: String) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size = Vector2(BRACKET_W, BUTTON_H)
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	l.visible = false
	add_child(l)
	return l

## The pages shown in the current group (+0x355).
func shown() -> int:
	return clampi(count - group_start, 0, GROUP)

## SetPage (c:0x4866c0): `page` current of `pages`; the group holding it
## shown.
func set_page(page: int, pages: int) -> void:
	count = maxi(0, pages)
	current = clampi(page, 0, maxi(0, count - 1))
	group_start = (current / GROUP) * GROUP
	_layout()

func press_index(i: int) -> void:
	var p := group_start + i
	if p >= count or p == current:
		return
	current = p
	_layout()
	page_changed.emit(current)

## c:0x485940: the previous group, its last page current.
func press_prev() -> void:
	if group_start <= 0:
		return
	group_start -= GROUP
	current = group_start + GROUP - 1
	_layout()
	page_changed.emit(current)

## c:0x485b60: the next group, its first page current.
func press_next() -> void:
	if group_start + GROUP >= count:
		return
	group_start += GROUP
	current = group_start
	_layout()
	page_changed.emit(current)

func _layout() -> void:
	var n := shown()
	var y := floorf(size.y / 2.0) - 7.0
	var x0 := float(BRACKET_W)
	for i in GROUP:
		var b := _buttons[i]
		b.visible = i < n
		if i >= n:
			continue
		var page := group_start + i
		var cap := b.get_node("ButtonLabel") as Label
		cap.text = "%d" % (page + 1)
		b.position = Vector2(x0 + BUTTON_W * i, y)
		cap.add_theme_color_override("font_color", CURRENT_COLOUR if page == current else NORMAL_COLOUR)
		if page == current and _bold != null:
			cap.add_theme_font_override("font", _bold)
		elif _font != null:
			cap.add_theme_font_override("font", _font)
	_open.visible = n > 0
	_close.visible = n > 0
	_open.position = Vector2(x0 - BRACKET_W, y)
	_close.position = Vector2(x0 + BUTTON_W * n, y)
	_prev.visible = group_start > 0
	_next.visible = group_start + GROUP < count
	_prev.position = Vector2(x0 - BRACKET_W - PREV_GAP - _prev.size.x, y + (BUTTON_H - _prev.size.y) / 2.0)
	_next.position = Vector2(x0 + BUTTON_W * n + BRACKET_W + NEXT_GAP, y + (BUTTON_H - _next.size.y) / 2.0)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()

## Tests and QA: the page button i's text ("" when hidden).
func button_text(i: int) -> String:
	return (_buttons[i].get_node("ButtonLabel") as Label).text if i < _buttons.size() and _buttons[i].visible else ""

func page_button(i: int) -> TextureButton:
	return _buttons[i] if i < _buttons.size() else null

func prev_button() -> TextureButton:
	return _prev

func next_button() -> TextureButton:
	return _next
