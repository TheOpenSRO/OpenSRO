extends HudWindow
class_name StallNetworkBox

## Round 840 (lane N): the stall network's buy box, `CNIFStallNetworkMsgBox`,
## built from `res_ui\nifstallnetworkmsgbox.2dt` (window 300, loaded by the
## network window's OnCreate c:0x6c5140 and kept hidden). READ unless marked.
##
## - The file (MEASURED, 18 records): root 300, 454 x 192,
##   `interface\messagebox\msgbox2_window_`, UIIT_STT_CONFIRM_BOX; the item
##   window 50 (`msgbox_itemwindow.ddj`) and the icon 27; the name 20 (275
##   wide, centred); the count 21 and its caption 12 (UIIT_STT_AMOUNT); the
##   price 22 (right) and its caption 13 (UIIT_STT_GOLD); Buy 4
##   (UIIT_STT_BUY) and Cancel 7 (UIIT_CTL_CANCEL).
## - Shown by Purchase with the selected row (c:0x6c83b0 -> 0x6bf370): the
##   icon, the name, the count `%d`, the price `%I64d` (no ',' groups).
## - Buy (4) -> c:0x6c7c20: 0x7463 with the row's record; Cancel (7) hides it.
## - The box is centred over the screen (0x798b70(box, 0), INFERRED centred).

signal confirmed(record: StallNetworkNet.Record)
signal cancelled

const FILE_2DT := "res_ui\\nifstallnetworkmsgbox.2dt"
const ID_BUY := 4
const ID_CANCEL := 7
const ID_NAME := 20
const ID_COUNT := 21
const ID_PRICE := 22
const ID_ICON := 27

var record: StallNetworkNet.Record
var _file: TwoDtReader.TwoDtFile
var _twodt: TwoDtBuilder

func _init(builder: UiBuilder = null) -> void:
	super._init()
	_builder = builder

func build_box() -> bool:
	if _builder == null:
		return false
	_file = _builder.load_2dt(FILE_2DT)
	if _file == null or _file.records.is_empty():
		return false
	_twodt = TwoDtBuilder.new(_builder)
	panel_root = _twodt.build(_file, FILE_2DT)
	size = Vector2(_file.root().rect.size)
	custom_minimum_size = size
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel_root)
	var root_text := panel_root.get_node_or_null(TwoDtBuilder.TEXT_NODE)
	if root_text != null:
		root_text.queue_free()
	_add_title_bar(_builder.resolve_text(_file.root().text_id))
	var b := control([ID_BUY]) as BaseButton
	if b != null:
		b.pressed.connect(press_buy)
	b = control([ID_CANCEL]) as BaseButton
	if b != null:
		b.pressed.connect(press_cancel)
	_settle()
	return true

## 0x6bf370.
func show_record(r: StallNetworkNet.Record, icon: Texture2D, item_name: String) -> void:
	record = r
	_put([ID_NAME], item_name)
	_put([ID_COUNT], "%d" % r.count)
	_put([ID_PRICE], "%d" % r.price)
	var host := control([ID_ICON])
	if host != null:
		var tr := host.get_node_or_null("Icon") as TextureRect
		if tr == null:
			tr = TextureRect.new()
			tr.name = "Icon"
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_SCALE
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			tr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			host.add_child(tr)
		tr.texture = icon
	show()
	move_to_front()

func press_buy() -> void:
	var r := record
	hide()
	if r != null:
		confirmed.emit(r)

func press_cancel() -> void:
	hide()
	cancelled.emit()

func _on_close_pressed() -> void:
	press_cancel()

func _put(path: Array, text: String) -> void:
	var c := control(path)
	if c != null and _twodt != null:
		_twodt.set_text(c, text)

func text_at(path: Array) -> String:
	return TwoDtBuilder.text_of(control(path))

func control(path: Array) -> Control:
	return TwoDtBuilder.find_path(panel_root, path) if panel_root != null else null

func place_centred() -> void:
	var view := get_viewport_rect().size
	position = ((view - size) / 2.0).round()

func _place_title_bar(bar: Control) -> void:
	var rect := Rect2(Vector2(MAINFRAME_CAPTION_X, MAINFRAME_CAPTION_Y),
		Vector2(size.x - MAINFRAME_STRIP_WIDTH_LESS, MAINFRAME_CAPTION_HEIGHT))
	bar.set_meta(UiBuilder.AUTHORED_RECT_META, rect)
	bar.position = rect.position
	bar.size = rect.size

func _close_position() -> Vector2:
	return Vector2(size.x - MAINFRAME_CLOSE_INSET, MAINFRAME_CLOSE_Y)

func in_drag_strip(local: Vector2) -> bool:
	return Rect2(MAINFRAME_CAPTION_X, 0.0, size.x - MAINFRAME_STRIP_WIDTH_LESS,
		MAINFRAME_DRAG_HEIGHT).has_point(local)
