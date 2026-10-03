extends Control
class_name ComboList

## The Option combos' open list (round 700): retail's CNIFPopupListCtrl drawn
## by this client in the game's own canvas, replacing round 697's Godot
## PopupMenu. Labels: **READ** (sro_client.exe), **MEASURED**, **INFERRED**,
## **OURS**.
##
## **Why not PopupMenu.** A PopupMenu is a Window. Its viewport is not
## transparent (Godot 4.2.2 sets no FLAG_TRANSPARENT / transparent_bg on a
## Popup: scene/gui/popup.cpp, popup_menu.cpp), so the 0xb4000000 fill was
## drawn over the viewport's opaque clear colour -- the user's "solid grey in
## the middle when it should be a transparent black" (2026-10-03, v0.1.483 on
## Windows) -- and it cannot centre its items or set its own line pitch.
## This list is a Control on a CanvasLayer above the game, so the rows below
## show through the fill as they do in retail.
##
## **What is READ / MEASURED** (docs/protocol/OPTION_VIDEO.md, "The open
## list"; the reference is the user's 2x screenshot of the original,
## Graphic Quality open, 664 x 382):
##   - y: the combo's top + 20 (READ `0x486fd3`; MEASURED: the list's top
##     frame row 40 px = 20 x 2 below the field's top row).
##   - x and width: the value field's, W - 20 (MEASURED: the list's left and
##     right frame columns are the field's, 348 and 606 at 2x, and the arrow's
##     column shows the row art undimmed beside it). Round 697 read the rect as
##     {0, 20, W, 0}, the combo's full width; the picture says the field's.
##   - fill 0xb4000000 (READ `0x487050`, `0x6f7200`; MEASURED: row art of 0x27
##     under it reads 0x0b, 0x27 x 75 / 255 = 0x0b).
##   - frame: the six com_blacksquare_ pieces, as the value field (READ).
##   - the inner list 4 in (READ `0x49b820`), so the box is rows x line + 8
##     (READ `0x48707f`).
##   - line = the font's size + 4 (READ `0x49b88b..0x49b896`: `[font+4] + 4`,
##     where +4 is the size GNFontChar was registered with, `0x4927f9`
##     `0xbaa110` `param_1[1]`), and font index 0 is **9 points**
##     (FUN_00469350, UiBuilder.FONT_POINT_SIZES): **13 units** (MEASURED:
##     the five baselines 26 px apart at 2x, the box 146 = 73 x 2 = 5 x 13 + 8).
##     Round 697 added 4 to Godot's own line height for a 12 px font (~14-15),
##     18 units a line: the user's "visibly taller" rows.
##   - text: drawn from the line's top with the font's cell (GDI draws text by
##     its cell top; MEASURED: cap tops 3 below each line top, baselines 12),
##     **centred** (READ `CNIFListCtrl::vslot_013 0x483460`: alignment +0x88 ==
##     1 puts the text at (width - text width) / 2; MEASURED: every item of
##     the Graphic Quality list is centred on the field's centre, 478 at 2x --
##     and the user, 2026-10-03: "make all of the text in the dropdowns
##     centered like the original screenshot").
##   - colours: text 0xffffffff, hover text 0xffffff80, hover bar 0xff8080ff
##     (READ `0x49b820`), the bar the item text's height from the line's top
##     (READ vslot_013: the bar's height is the text extent's +0x50 high word
##     unless +0x360 is set, which the list never sets).
## **OURS:** a click outside closes the list and is eaten (Godot's popup did
## the same; retail's CNIFPopup outside click was not read); Up / Down /
## the wheel move the bar a row, Enter / Space choose it, Escape closes (retail
## reads no keys here that this round found); a list that would run off the
## bottom of the screen is moved up to fit; no pressed colour (0xff8080ff while
## the button is held).

const TOP := 20
const ARROW_W := 20
const INSET := 4
const LINE_EXTRA := 4
## Font index 0's registered size in points (READ, FUN_00469350).
const FONT_POINTS := 9
const FILL := Color8(0, 0, 0, 0xb4)
const TEXT := Color8(255, 255, 255)
const TEXT_HOVER := Color8(255, 255, 128)
const BAR := Color8(128, 128, 255)
const TEXT_DISABLED := Color(0.55, 0.55, 0.55)
## The CanvasLayer the list lives on: above every HUD layer (OURS).
const LAYER := 120

signal chosen(index: int)
signal closed

var items: PackedStringArray = PackedStringArray()
var disabled_items: Array = []
var hover := -1
var font: Font
var font_size := 12
## The frame and fill (OptionVideoPage.popup_panel), drawn over the list rect.
var panel: StyleBox
## The list's rect in the combo's own units, and the combo -> canvas transform.
var list_rect := Rect2()
var to_canvas := Transform2D.IDENTITY
var _combo: OptionButton
var _layer: CanvasLayer
var _text: Control
var _last_xf := Transform2D()
var _watch := Callable()
var _gone := Callable()
## Set by close(): the combo is done with this list.
var _closed := false
## The mouse button whose release still belongs to this list (0: none).
var _await_button := 0

static var _open: ComboList = null
## For the suite: the view height place() fits the list into (the headless
## window is 64 x 64). 0 = the viewport's own.
static var view_height_for_test := 0.0

## The line pitch in UI units: 13 (READ + MEASURED, see the header).
static func line_height() -> int:
	return FONT_POINTS + LINE_EXTRA

## The open list's rect in the coordinates of a combo of `combo_size`.
static func rect_for(combo_size: Vector2, rows: int) -> Rect2:
	return Rect2(0, TOP, maxf(combo_size.x - ARROW_W, 0.0), maxi(rows, 0) * line_height() + 2 * INSET)

## Row i's line box inside a list of `list_size`.
static func row_rect(list_size: Vector2, i: int) -> Rect2:
	return Rect2(INSET, INSET + i * line_height(), maxf(list_size.x - 2 * INSET, 0.0), line_height())

## The row under `p` (list coordinates), or -1.
static func row_at(list_size: Vector2, rows: int, p: Vector2) -> int:
	if p.x < INSET or p.x >= list_size.x - INSET or p.y < INSET:
		return -1
	var i := floori((p.y - INSET) / line_height())
	return i if i >= 0 and i < rows else -1

## Where a text of `text_w` starts: centred in the row (READ / MEASURED).
static func text_x(list_w: float, text_w: float) -> float:
	return INSET + floorf((list_w - 2 * INSET - text_w) / 2.0)

## The list moved up when it would run off a view `view_h` tall: the y (in
## canvas units) to draw it at, given where retail puts it.
static func fit_y(top: float, height: float, view_h: float) -> float:
	if top + height <= view_h:
		return top
	return maxf(view_h - height, 0.0)

static func current() -> ComboList:
	return _open if _open != null and is_instance_valid(_open) else null

static func close_current() -> void:
	var c := current()
	if c != null:
		c.close()

## Opens the list under `combo` (an OptionButton drawing the value): its
## items, the frame and fill `panel`, the font. Picking a row selects it on
## the combo and emits item_selected as OptionButton's own list does (not
## for the shown row unless allow_reselect). Returns the list, or null.
static func open_for(combo: OptionButton, panel_box: StyleBox, list_font: Font, size_px: int) -> ComboList:
	close_current()
	if combo == null or not combo.is_inside_tree() or combo.item_count == 0:
		return null
	var list := ComboList.new()
	list.name = "ComboList"
	for i in combo.item_count:
		list.items.append(combo.get_item_text(i))
		list.disabled_items.append(combo.is_item_disabled(i))
	list.panel = panel_box
	list.font = list_font if list_font != null else combo.get_theme_font("font")
	list.font_size = size_px
	list._combo = combo
	list.list_rect = rect_for(combo.size, combo.item_count)
	list.chosen.connect(func(i: int) -> void:
		if i == combo.selected and not combo.allow_reselect:
			return
		combo.select(i)
		combo.item_selected.emit(i))
	var layer := CanvasLayer.new()
	layer.name = "ComboListLayer"
	layer.layer = LAYER
	list._layer = layer
	layer.add_child(list)
	combo.get_tree().root.add_child(layer)
	list.place()
	# One line per open, in window pixels (the QA drivers measure against it).
	var k := combo.get_window().content_scale_factor if combo.get_window() != null else 1.0
	var top_left := list.to_canvas * list.list_rect.position * k
	var bottom_right := list.to_canvas * list.list_rect.end * k
	print("COMBOLIST open %d item(s) at %d,%d size %dx%d (window px), line %d" % [list.items.size(),
		roundi(top_left.x), roundi(top_left.y), roundi(bottom_right.x - top_left.x), roundi(bottom_right.y - top_left.y), line_height()])
	# Disconnected again in close(): the combo outlives many lists.
	list._watch = list._on_combo_gone
	list._gone = list.close
	combo.tree_exiting.connect(list._gone)
	combo.visibility_changed.connect(list._watch)
	_open = list
	return list

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_text = Control.new()
	_text.name = "Text"
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The text keeps round 672's crisp sampling; the frame keeps the UI art's.
	UiBuilder.crisp_text(_text)
	_text.draw.connect(_draw_text)
	add_child(_text)

## Follows the combo: its canvas transform (UI scale, window position).
func place() -> void:
	if _combo == null or not is_instance_valid(_combo) or not _combo.is_inside_tree():
		return
	var xf := _combo.get_global_transform_with_canvas()
	var view_h := get_viewport_rect().size.y if is_inside_tree() else 1e9
	if view_height_for_test > 0.0:
		view_h = view_height_for_test
	var top := (xf * list_rect.position).y
	var y := fit_y(top, list_rect.size.y * xf.get_scale().y, view_h)
	to_canvas = xf
	to_canvas.origin.y += y - top
	queue_redraw()
	if _text != null:
		_text.queue_redraw()

func _process(_dt: float) -> void:
	if _closed:
		# Waiting for the closing press's release: if the button is already
		# up (its release went elsewhere), nothing is left to eat.
		if _await_button != 0 and not Input.is_mouse_button_pressed(_await_button):
			_await_button = 0
			_free_layer()
		return
	if _combo == null or not is_instance_valid(_combo) or not _combo.is_visible_in_tree():
		close()
		return
	var xf := _combo.get_global_transform_with_canvas()
	if not xf.is_equal_approx(_last_xf):
		_last_xf = xf
		place()

## A canvas point in the list's own coordinates.
func to_list(canvas_p: Vector2) -> Vector2:
	return (to_canvas.affine_inverse() * canvas_p) - list_rect.position

func _draw() -> void:
	if _closed:
		return
	draw_set_transform_matrix(to_canvas)
	var r := list_rect
	if panel != null:
		draw_style_box(panel, r)
	else:
		draw_rect(r, FILL)
	if hover >= 0 and hover < items.size() and not disabled_items[hover]:
		var row := row_rect(r.size, hover)
		var h := _text_height()
		draw_rect(Rect2(r.position + row.position, Vector2(row.size.x, h)), BAR)

func _text_height() -> float:
	if font == null:
		return line_height()
	return font.get_height(font_size)

func _draw_text() -> void:
	if font == null:
		return
	_text.draw_set_transform_matrix(to_canvas)
	var r := list_rect
	var ascent := font.get_ascent(font_size)
	for i in items.size():
		var w := font.get_string_size(items[i], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var row := row_rect(r.size, i)
		var c := TEXT_DISABLED if disabled_items[i] else (TEXT_HOVER if i == hover else TEXT)
		var p := r.position + Vector2(text_x(r.size.x, w), row.position.y + ascent)
		_text.draw_string(font, p, items[i], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, c)

func _set_hover(i: int) -> void:
	if i != hover:
		hover = i
		queue_redraw()
		if _text != null:
			_text.queue_redraw()

func _gui_input(e: InputEvent) -> void:
	if _await_button != 0:
		# Closed by a press (round 700 review, H1): every event is eaten until
		# that button's release, which then frees the layer. Freed on the
		# press, the layer took Godot's mouse focus with it and the release
		# fell through to World3D._unhandled_input as a world click.
		accept_event()
		var rb := e as InputEventMouseButton
		if rb != null and not rb.pressed and rb.button_index == _await_button:
			_await_button = 0
			_free_layer()
		return
	if e is InputEventMouseMotion:
		var p := to_list((e as InputEventMouseMotion).position)
		_set_hover(row_at(list_rect.size, items.size(), p))
		accept_event()
	elif e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
		var mb := e as InputEventMouseButton
		accept_event()
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			step(-1)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			step(1)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			var p := to_list(mb.position)
			var inside := Rect2(Vector2.ZERO, list_rect.size).has_point(p)
			if not inside:
				close(MOUSE_BUTTON_LEFT)
				return
			var i := row_at(list_rect.size, items.size(), p)
			if i >= 0:
				choose(i, MOUSE_BUTTON_LEFT)
		elif mb.button_index != MOUSE_BUTTON_WHEEL_LEFT and mb.button_index != MOUSE_BUTTON_WHEEL_RIGHT:
			close(mb.button_index)
	elif e is InputEventMouseButton:
		accept_event()

## Escape and the keys, before the HUD sees them (input runs from the last
## node in the tree, and the layer is the root's last child).
func _input(e: InputEvent) -> void:
	if _closed or not (e is InputEventKey) or not (e as InputEventKey).pressed:
		return
	var k := (e as InputEventKey).keycode
	match k:
		KEY_ESCAPE:
			close()
		KEY_UP:
			step(-1)
		KEY_DOWN:
			step(1)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if hover >= 0:
				choose(hover)
		_:
			return
	get_viewport().set_input_as_handled()

## Moves the bar `d` rows, skipping greyed rows; from the combo's shown row
## when no row is lit.
func step(d: int) -> void:
	if items.is_empty():
		return
	var start := hover
	if start < 0:
		start = _combo.selected if _combo != null and is_instance_valid(_combo) else -1
		if start < 0:
			start = -1 if d > 0 else items.size()
	var i := start
	for _n in items.size():
		i += d
		if i < 0 or i >= items.size():
			return
		if not disabled_items[i]:
			_set_hover(i)
			return

## Picks row i. `await_button`: the mouse button whose press picked it --
## the list stays (drawn as nothing) eating input until that release.
func choose(i: int, await_button: int = 0) -> void:
	if i < 0 or i >= items.size() or disabled_items[i]:
		return
	close(await_button)
	chosen.emit(i)

func _on_combo_gone() -> void:
	if _combo == null or not is_instance_valid(_combo) or not _combo.is_visible_in_tree():
		close()

## Closes the list: at once for the combo (current() is null, `closed`
## emitted), and the layer goes now -- or, with `await_button`, when that
## mouse button is released (see _gui_input), so its release never reaches
## the world.
func close(await_button: int = 0) -> void:
	if _open == self:
		_open = null
	if _combo != null and is_instance_valid(_combo):
		if _gone.is_valid() and _combo.tree_exiting.is_connected(_gone):
			_combo.tree_exiting.disconnect(_gone)
		if _watch.is_valid() and _combo.visibility_changed.is_connected(_watch):
			_combo.visibility_changed.disconnect(_watch)
	_watch = Callable()
	_gone = Callable()
	if _closed:
		if await_button == 0 and _await_button != 0:
			_await_button = 0
			_free_layer()
		return
	_closed = true
	if await_button != 0 and _layer != null and is_instance_valid(_layer) and is_inside_tree():
		_await_button = await_button
		queue_redraw()
		if _text != null:
			_text.visible = false
		closed.emit()
		return
	_free_layer()
	closed.emit()

func _free_layer() -> void:
	if _layer != null and is_instance_valid(_layer):
		var layer := _layer
		_layer = null
		# Hidden now, freed at the frame's end: close() can run while the tree
		# is removing the combo's window (tree_exiting), when a remove_child
		# on the root could find it busy.
		layer.visible = false
		layer.queue_free()

func is_open() -> bool:
	return _layer != null and not _closed
