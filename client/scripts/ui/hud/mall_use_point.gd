extends Control
class_name MallUsePoint

## Round 837: CItemMallUsePoint (ID 400, class 0xeec368), the item mall's
## "Point Use" dialog that the honour-point price row of the confirm box
## (MallConfirmBuy) and the point button of the lump boxes (MallMessageBox)
## open. c: client addresses, READ unless a line says otherwise.
##
## - **Who makes it.** Its owner loads its own layout's section
##   `ConfirmPoint` and takes control 400 from it: the confirm box's price row
##   (CIFNewItemMallConfirmSlot 0x7d9980(1), from resinfo\ifnewitemmallconfirm
##   slot.txt: 244 x 177, frame interface\frame\mall_ms_wnd_), the lump box
##   (CIFNewItemMallMessageBox 0x7da210(1), resinfo\ifnewitemmallmessagebox.txt:
##   244 x 177, mall_ms_wnd_). Both unload the section again once the points
##   are used (0x7d9a20 -> 0x7d9980(0); 0x7da2a0 -> 0x7da210(0)).
## - **Create (0x7c6560).** It loads resinfo\ifitemmallusepoint.txt
##   "Create", adds a drag area (CIFDragableArea, 10, 0, width - 21, 0x22, ID
##   100), writes the player's point balance (0x778e40, player +0x4b4) as "%u"
##   into control 40 (REMAIN_POINT) and calls 0x635070(0x80) on it; control
##   41 (EDIT_USE_POINT) 0x635070(1) (INFERRED: digits only, as CIFEdit's
##   style bit 1), its maximum the balance (0x634f20), "%u" 0; then centres
##   itself on the screen (0x798b70 at 0x7c66ca).
## - **Use (control 50 -> 0x7c63e0).** Control 41 read with _wtoi and handed
##   to the parent by the parent's class: the old confirm (0xeec308 ->
##   0x7c20d0), CIFMessageBox (0x63e6e0), CIFNewItemMallMessageBox
##   (0x7da2a0) or CIFNewItemMallConfirmSlot (0x7d9a20). The message map has
##   that one entry (0xebf9f0): there is no Cancel and no close button.
##
## INFERRED: resinfo\ifitemmallusepoint.txt declares every control twice --
## a set in the mall's art (mall_button, mall_box_02, the background at
## 32,44,180,109) and a set in the common art (com_button,
## com_blacksquare_, com_bg_tile_b at 16,40,201,121). Which one the client's
## parser keeps for a name it has seen was not read; the first set is built
## here, the one whose art matches the mall_ms_wnd_ frame it sits in (OPEN).
## OURS: the edit's text is held to digits and to 0..the balance as it is
## typed (CIFEdit's style 1 and maximum, whose WM_CHAR handling was not read).

const LAYOUT := "resinfo\\ifitemmallusepoint.txt"
const ID := 400
const EDIT_REMAIN := "GDR_ITEMMALL_USE_POINT_REMAIN_POINT"
const EDIT_USE := "GDR_ITEMMALL_USE_POINT_EDIT_USE_POINT"
const BTN_USE := "GDR_ITEMMALL_USE_POINT_BTN_USE"
## The drag area Create adds: (10, 0, width - 21, 0x22).
const DRAG_X := 10.0
const DRAG_LESS := 21.0
const DRAG_HEIGHT := 34.0

## Use pressed: the points typed (0..the balance).
signal used(points: int)

var balance := 0
var root: Control
var edit: LineEdit
var _builder: UiBuilder
var _dragging := false
var _drag_offset := Vector2.ZERO

## Builds the dialog from its owner's `ConfirmPoint` def (control 400) for a
## point balance. False without the layout.
func build(builder: UiBuilder, def: UiLayoutParser.ControlDef, point_balance: int) -> bool:
	_builder = builder
	name = "MallUsePoint"
	balance = maxi(point_balance, 0)
	var box := Vector2(def.rect.size) if def != null else Vector2(244, 177)
	size = box
	custom_minimum_size = box
	mouse_filter = Control.MOUSE_FILTER_STOP
	top_level = true
	if builder == null:
		return false
	if def != null and UiBuilder.is_slice_base(def.ddj):
		var frame_def := def.with_rect(Rect2i(Vector2i.ZERO, Vector2i(box)))
		frame_def.text = ""
		var frame := builder.build_control(frame_def)
		if frame != null:
			frame.name = "Frame"
			frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(frame)
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(LAYOUT)
	var sec := layout.get_section("Create") if layout != null else null
	if sec == null:
		return false
	root = Control.new()
	root.name = "Create"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var seen := {}
	var defs: Array = []
	for d in sec.controls:
		if seen.has(d.name):
			continue
		seen[d.name] = true
		defs.append(d)
	# Back to front, as UiBuilder.build_section lays a section.
	for i in range(defs.size() - 1, -1, -1):
		var n := builder.build_control(defs[i])
		if n != null:
			root.add_child(n)
	add_child(root)
	UiBuilder.settle_authored_rects(root)
	var remain := root.get_node_or_null(EDIT_REMAIN) as LineEdit
	if remain != null:
		remain.text = str(balance)
		remain.editable = false
		remain.focus_mode = Control.FOCUS_NONE
		remain.add_theme_color_override("font_uneditable_color", remain.get_theme_color("font_color"))
	edit = root.get_node_or_null(EDIT_USE) as LineEdit
	if edit != null:
		edit.text = "0"
		edit.text_changed.connect(_on_typed)
		edit.text_submitted.connect(func(_t: String) -> void: press_use())
		edit.call_deferred("grab_focus")
	var use := root.get_node_or_null(BTN_USE) as BaseButton
	if use != null:
		use.pressed.connect(press_use)
	return true

## Centred on the screen (0x798b70: integer halves of the view and the size).
func place() -> void:
	if not is_inside_tree():
		return
	var view := get_viewport_rect().size
	global_position = Vector2(int(view.x) / 2 - int(size.x) / 2, int(view.y) / 2 - int(size.y) / 2)

## The points the edit holds, 0..the balance.
func typed_points() -> int:
	if edit == null or not edit.text.is_valid_int():
		return 0
	return clampi(int(edit.text), 0, balance)

func press_use() -> void:
	used.emit(typed_points())

func _on_typed(text: String) -> void:
	var digits := ""
	for ch in text:
		if ch >= "0" and ch <= "9":
			digits += ch
	if digits != "" and int(digits) > balance:
		digits = str(balance)
	if digits != text:
		edit.text = digits
		edit.caret_column = digits.length()

func close() -> void:
	if is_queued_for_deletion():
		return
	name = "MallUsePoint_closing"
	hide()
	queue_free()

func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed and Rect2(DRAG_X, 0.0, size.x - DRAG_LESS, DRAG_HEIGHT).has_point(mb.position):
			_dragging = true
			_drag_offset = mb.position
			accept_event()
		elif not mb.pressed:
			_dragging = false
		return
	var mm := event as InputEventMouseMotion
	if mm != null and _dragging:
		position += mm.position - _drag_offset
		accept_event()
