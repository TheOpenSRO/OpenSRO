extends RefCounted
class_name OptionKeyPage

## The Option window's Key Map tab (round 833): `res_ui\optionwnd.2dt`'s pane
## 109, the original's key rebinding. OptionWindow owns one. Labels: READ
## (sro_client.exe), INFERRED, OURS.
##
## **The controls (READ, 0x5fb9e0 and the file):**
##   109 -> 110 / 111   the mouse radios (+0x1104 / +0x1108), labels 189 / 190
##   109 -> 20          the list's scroll bar (+0x110c)
##   109 -> 77 -> 210, 213 .. 249  fourteen CNIFKeyOptionSlot rows, two a line,
##                      each a key box 211 and a label 212 (+0x1744, file order)
##   109 -> 78          "Custom shortcut", a lone tab with no pane
##   109 -> 191         an empty static
##
## **The rows (READ).** Row i is KeyMap slot i (0x5f68e0); its label is the
## slot's row text (0x5fb9e0). Line L of the list shows rows 2L and 2L + 1
## (0x5fc530); a row past 32 hides its slot. The scroll runs over lines 0..10
## (0x478ab0(0, ceil((33 - 14) / 2), 1)); a line a step is INFERRED.
##
## **Rebinding (READ).** A left press on a row (CNIFKeyOptionSlot vslot_017
## 0x6ed820 -> 0x5fc5f0) clears the flag of every row shown, sets the pressed
## row's flag and makes it the selected row (+0x1214); a flagged row's key box
## shows `interface\option\opt_key_select.ddj` (0x6ee0c0). While the Key Map
## tab is up, a key-down (0x5fb460) the row takes (KeyNames.accepts) unbinds
## every row WITHOUT the flag that holds that key, then gives it to the
## selected row -- no swap, no message. A refused key changes nothing. The
## selection never ends: the row stays selected, and takes the next key too,
## until another row is pressed. Esc is refused; its WM_CHAR closes the window
## (0x5f6470 -> 0x5f63b0).
##
## **The radios (READ).** 110 is mode 0 ("Wheel [use shortcut], Right Button
## [change view]"), 111 mode 1; they set GI+0x4f9 on Apply or Confirm
## (0x5f6970). ClientSettings.mouse_mode holds it; World3D reads it.
##
## **Default (0x5fcda0, READ):** mode 0 at once (live, before Apply), radio 110
## checked, the rows back to the 33 defaults (in force on Apply).
##
## OURS: the key that rebinds a row is not also run by the game (whether the
## original's dispatcher 0x780610 sees it too is OPEN); the wheel over the list
## scrolls it.

const ID_PANE := 109
const ID_LIST := 77
const ID_RADIO_0 := 110
const ID_RADIO_1 := 111
const ID_SCROLL := 20
const ID_KEY_BOX := 211
const ID_LABEL := 212
const SLOT_CLASS := "CNIFKeyOptionSlot"
const SELECT_DDJ := "interface\\option\\opt_key_select.ddj"
const COLUMNS := 2
const ROWS := 33
## The scroll bar's art, the Video tab's (CNIFVerticalScroll, READ there).
const SCROLL_BAR_DDJ := OptionVideoPage.SCROLL_BAR_DDJ
const SCROLL_UP_DDJ := OptionVideoPage.SCROLL_UP_DDJ
const SCROLL_DOWN_DDJ := OptionVideoPage.SCROLL_DOWN_DDJ
const SCROLL_THUMB_DDJ := OptionVideoPage.SCROLL_THUMB_DDJ

var _builder: UiBuilder
var _twodt: TwoDtBuilder
var _root: Control
## The working keys (+0x1218): Godot keycodes, row order.
var keys := PackedInt32Array()
## The rows' flags (row +0).
var _flags: Array[bool] = []
## The selected row (+0x1214), -1 before the first press.
var selected := -1
## The radios' mode, as edited.
var mouse_mode := 0
## Per visible slot: [slot, key box, select overlay, key label, row label].
var _slots: Array = []
var _line := 0
var _radios: Array = []
var _scroll_track: Control
var _scroll_thumb: Control
## Whether the Key Map tab is the window's current one (set by OptionWindow).
var tab_shown := false

signal changed

func _init(builder: UiBuilder, root: Control) -> void:
	_builder = builder
	_twodt = TwoDtBuilder.new(builder) if builder != null else null
	_root = root

func at(path: Array) -> Control:
	return TwoDtBuilder.find_path(_root, path) if _root != null else null

## Builds the pieces over the file's controls with `live` keys (33) and the
## mouse `mode`.
func build(live: PackedInt32Array, mode: int) -> void:
	keys = live.duplicate()
	_flags.resize(ROWS)
	_flags.fill(false)
	mouse_mode = mode
	var list := at([ID_PANE, ID_LIST])
	if list == null:
		return
	for c in list.get_children():
		if String(c.get_meta(TwoDtBuilder.META_CLASS, "")) != SLOT_CLASS:
			continue
		var slot := c as Control
		var box := TwoDtBuilder.child(slot, ID_KEY_BOX)
		var label := TwoDtBuilder.child(slot, ID_LABEL)
		var mark := TextureRect.new()
		mark.name = "Select"
		mark.texture = _builder.load_texture(SELECT_DDJ) if _builder != null else null
		mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		mark.stretch_mode = TextureRect.STRETCH_SCALE
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mark.visible = false
		if box != null:
			mark.size = box.size
			box.add_child(mark)
			box.move_child(mark, 0)
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		var n: int = _slots.size()
		slot.gui_input.connect(func(e: InputEvent) -> void: _slot_input(n, e))
		_slots.append([slot, box, mark, label])
	_radios = [at([ID_PANE, ID_RADIO_0]), at([ID_PANE, ID_RADIO_1])]
	for i in _radios.size():
		var r := _radios[i] as BaseButton
		if r != null:
			var m: int = i
			r.toggled.connect(func(_on: bool) -> void: set_mouse_mode(m))
	_build_scroll(at([ID_PANE, ID_SCROLL]), at([ID_PANE]))
	show_values()

# --- rows -------------------------------------------------------------------------

## The row a visible slot shows, or -1 past the last row.
func row_at_slot(n: int) -> int:
	var i := _line * COLUMNS + n
	return i if i < ROWS else -1

func lines() -> int:
	return (ROWS + COLUMNS - 1) / COLUMNS

## The last top line (READ: ceil((33 - 14) / 2) = 10).
func max_line() -> int:
	return maxi(ceili(float(ROWS - _slots.size()) / float(COLUMNS)), 0)

func scroll_line() -> int:
	return _line

func scroll_to(line: int) -> void:
	_line = clampi(line, 0, max_line())
	show_values()

func slot_count() -> int:
	return _slots.size()

## A row pressed (0x5fc5f0): the shown rows' flags cleared, its own set.
func select_row(row: int) -> void:
	if row < 0 or row >= ROWS:
		return
	for n in _slots.size():
		var r := row_at_slot(n)
		if r >= 0:
			_flags[r] = false
	_flags[row] = true
	selected = row
	show_values()

func _slot_input(n: int, e: InputEvent) -> void:
	var mb := e as InputEventMouseButton
	if mb == null or not mb.pressed:
		_wheel(e)
		return
	if mb.button_index == MOUSE_BUTTON_LEFT:
		select_row(row_at_slot(n))
		(_slots[n][0] as Control).accept_event()
		return
	_wheel(e)

## A key-down while the tab is up (0x5fb460). Returns whether it was taken.
func take_key(keycode: int) -> bool:
	if selected < 0 or not KeyNames.accepts(keycode):
		return false
	for i in ROWS:
		if not _flags[i] and int(keys[i]) == keycode:
			keys[i] = KEY_NONE
	keys[selected] = keycode
	show_values()
	changed.emit()
	return true

## Whether a key-down belongs to this page now: the tab up, a row selected,
## and not Esc (whose WM_CHAR closes the window).
func wants_key(keycode: int) -> bool:
	return tab_shown and selected >= 0 and keycode != KEY_ESCAPE

func flag(row: int) -> bool:
	return row >= 0 and row < ROWS and _flags[row]

# --- the radios and Default -------------------------------------------------------

func set_mouse_mode(m: int) -> void:
	mouse_mode = clampi(m, 0, 1)
	for i in _radios.size():
		_set_check(_radios[i] as BaseButton, i == mouse_mode)
	changed.emit()

## 0x5fcda0: the defaults into the rows, radio 110. The mode goes live at once
## (the caller applies it).
func press_default() -> void:
	keys = KeyMap.default_keys()
	set_mouse_mode(0)
	show_values()

# --- drawing ----------------------------------------------------------------------

func show_values() -> void:
	for n in _slots.size():
		var s: Array = _slots[n]
		var slot := s[0] as Control
		var row := row_at_slot(n)
		if slot == null:
			continue
		slot.visible = row >= 0
		if row < 0:
			continue
		var box := s[1] as Control
		var mark := s[2] as CanvasItem
		var label := s[3] as Control
		if box != null and _twodt != null:
			_twodt.set_text(box, KeyNames.name_of(int(keys[row])))
		if label != null and _twodt != null:
			_twodt.set_text(label, _row_text(row))
		if mark != null:
			mark.visible = _flags[row]
	for i in _radios.size():
		_set_check(_radios[i] as BaseButton, i == mouse_mode)
	_place_thumb()

func key_text_at_slot(n: int) -> String:
	return TwoDtBuilder.text_of(_slots[n][1]) if n < _slots.size() and _slots[n][1] != null else ""

func label_text_at_slot(n: int) -> String:
	return TwoDtBuilder.text_of(_slots[n][3]) if n < _slots.size() and _slots[n][3] != null else ""

func select_shown_at_slot(n: int) -> bool:
	return n < _slots.size() and (_slots[n][2] as CanvasItem).visible

func slot_node(n: int) -> Control:
	return _slots[n][0] as Control if n < _slots.size() else null

func radio(m: int) -> BaseButton:
	return _radios[m] as BaseButton if m < _radios.size() else null

func _row_text(row: int) -> String:
	var key := String(KeyMap.SLOTS[row]["row"])
	var table := _builder.text_table() if _builder != null else null
	if table != null and table.has(key):
		return table.get_text(key)
	return key

static func _set_check(b: BaseButton, on: bool) -> void:
	if b == null:
		return
	b.set_pressed_no_signal(on)
	var mark := b.get_node_or_null(TwoDtBuilder.MARK_NODE) as CanvasItem
	if mark != null:
		mark.visible = on

# --- the scroll bar (as OptionVideoPage's) ----------------------------------------

func _build_scroll(host: Control, pane: Control) -> void:
	if host == null:
		return
	host.mouse_filter = Control.MOUSE_FILTER_STOP
	var w := host.size.x
	var track := TextureRect.new()
	track.name = "Track"
	track.texture = _builder.load_texture(SCROLL_BAR_DDJ) if _builder != null else null
	track.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	track.stretch_mode = TextureRect.STRETCH_SCALE
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.position = Vector2(0, w)
	track.size = Vector2(w, maxf(host.size.y - 2.0 * w, 0.0))
	host.add_child(track)
	_scroll_track = track
	var up := _scroll_button(SCROLL_UP_DDJ, Vector2.ZERO, Vector2(w, w))
	up.name = "Up"
	up.pressed.connect(func() -> void: scroll_to(_line - 1))
	host.add_child(up)
	var down := _scroll_button(SCROLL_DOWN_DDJ, Vector2(0, host.size.y - w), Vector2(w, w))
	down.name = "Down"
	down.pressed.connect(func() -> void: scroll_to(_line + 1))
	host.add_child(down)
	var thumb := TextureRect.new()
	thumb.name = "Thumb"
	thumb.texture = _builder.load_texture(SCROLL_THUMB_DDJ) if _builder != null else null
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_SCALE
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb.size = Vector2(w, w)
	host.add_child(thumb)
	_scroll_thumb = thumb
	host.gui_input.connect(func(e: InputEvent) -> void: _scroll_input(e, host))
	if pane != null:
		pane.gui_input.connect(func(e: InputEvent) -> void: _wheel(e))

func _scroll_button(ddj: String, pos: Vector2, sz: Vector2) -> TextureButton:
	var b := TextureButton.new()
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_SCALE
	b.focus_mode = Control.FOCUS_NONE
	if _builder != null:
		b.texture_normal = _builder.load_texture(ddj)
		var base := ddj.substr(0, ddj.length() - 4)
		b.texture_hover = _builder.load_texture(base + "_focus.ddj")
		b.texture_pressed = _builder.load_texture(base + "_press.ddj")
	b.position = pos
	b.size = sz
	return b

func _scroll_input(e: InputEvent, host: Control) -> void:
	var mb := e as InputEventMouseButton
	if mb == null or not mb.pressed:
		_wheel(e)
		return
	if mb.button_index == MOUSE_BUTTON_LEFT and _scroll_track != null:
		var y := mb.position.y - _scroll_track.position.y
		var f := clampf(y / maxf(_scroll_track.size.y, 1.0), 0.0, 1.0)
		scroll_to(roundi(f * float(max_line())))
		host.accept_event()
		return
	_wheel(e)

func _wheel(e: InputEvent) -> void:
	var mb := e as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		scroll_to(_line - 1)
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		scroll_to(_line + 1)

func _place_thumb() -> void:
	if _scroll_thumb == null or _scroll_track == null:
		return
	var span := maxf(_scroll_track.size.y - _scroll_thumb.size.y, 0.0)
	var f := float(_line) / float(maxi(max_line(), 1))
	_scroll_thumb.position = Vector2(0, _scroll_track.position.y + span * f)
