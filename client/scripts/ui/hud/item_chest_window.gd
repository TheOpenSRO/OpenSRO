extends HudWindow
class_name ItemChestWindow

## Round 837 (OURS): the item chest -- mall goods that did not fit the bag
## wait here until the player takes them. **Not retail**: no window, layout,
## text key or message for it exists in sro_client.exe or in vSRO 1.188's
## server (docs/protocol/item_mall.md "The Chest window", item_mall_wire.md
## §4). It is a private-server add-on (vPlus / MaxiGuard art and text keys are
## in the player's Media.pk2), offered here as our own part. Labels: READ,
## MEASURED, INFERRED, OURS.
##
## **The look is the user's reference picture** (refs/LShp7DJ.png, round 837,
## 1416 x 720). MEASURED: it is the game drawn at 2x, every pixel doubled (one
## column and one row tripled, so a native coordinate is within 1 of the
## picture's / 2); every rect below is in native units (= UI units), relative
## to the window's top-left, and each piece of art was matched pixel for pixel
## against the archive's own file:
##   window 704 x 357, `interface\frame\mframe_wnd_` (its left_side columns
##     16,20,16 / 148,142,140 / 58 / 132,121,90 at the window's left edge);
##     caption centred, close button at (w - 26, 10) -- CNIFMainFrame's chrome
##     (HudWindow.MAINFRAME_*), which the picture's caption and X sit on;
##   the body tile `interface\ifcommon\bg_tile\com_bg_tile_b.ddj` (8 x 8
##     patches of the picture match it exactly; its tiling origin is OURS);
##   the inner frame `interface\frame\frameg_wnd_` at (8, 60) 689 x 291 (grey
##     line, gold line 189,170,115, black line);
##   two tabs, the 3-slice `interface\ifcommon\com_new_tab_on_` / `_off_`
##     (12 + 48 + 12) at (18, 39) and (92, 39), 72 x 24, white captions,
##     the checked one semi-bold (TwoDtBuilder's checked-tab look);
##   the list box, the six-piece `interface\ifcommon\com_square_` at (23, 71)
##     660 x 241 over a 16,16,16 fill;
##   the column heads, 3-slice `interface\ifcommon\com_bar02_` bars 24 tall at
##     y 74: No. x 26 w 27, Item Name 53 w 304, Quantity 357 w 82, From 439
##     w 150, Date 589 w 92, captions white and centred;
##   **10 rows a page**, 21 apart from y 97, a 1-pixel 49,52,49 line between
##     them from x 27 to 680;
##   "Inventory Remaining" at (26, 321), left; its count in a
##     `interface\ifcommon\com_blacksquare_` box at (146, 321) 37 x 20 over
##     black, right-aligned 4 in;
##   the page control: `com_left_arrow` at (329, 322), a black 16 x 16 box
##     with the page number, `com_right_arrow` at (361, 322);
##   Take All and Take, `interface\ifcommon\com_button.ddj` (76 x 24) at
##     (532, 317) and (610, 317); Take is drawn with `_disable` (nothing
##     selected), Take All enabled with the list empty.
## The rows' contents, the selection bar (com_bar01select_), the Take Log
## page, the dates' format and the 7-day note's place are not in the picture:
## **OURS**.
##
## **Text:** the archive's keys where one says what the picture says
## (VPLUS_UI_CHEST_CAPTION_TEXT "Chest", VPLUS_UI_ITEM_STORAGE_BOX_TAB_LOGS
## "Take Log", UIIT_STT_BOX_NUM "No.", VPLUS_UI_CHEST_LIST_COLUMN_QUANTITY_TEXT
## "Quantity", UIIT_STT_SILK_INQUIRY_DATE "Date", ..._ITEMS_BUTTON_TAKE(_ALL),
## ..._ITEMS_INV_SLOTS "Inventory Remaining", ..._LOGS_DATE_INFO, the
## messages VPLUS_MSG_CHEST_ITEM_RECEIVED / _INVENTORY_FULL_ERROR); "Item
## Name" and "From" have no key with that wording and are the picture's.
##
## **The wire (OURS, MallNet):** 0x00D0 list -> 0x00D1; 0x00D2 {entry} take
## one, {0} take all -> 0x00D3 {ok, value}; 0x00D4 the take log -> 0x00D5;
## 0x00D6 an item went into the chest.

const ErrorText = preload("res://scripts/net/error_text.gd")

const WINDOW_SIZE := Vector2(704, 357)
const FRAME := "interface\\frame\\mframe_wnd_"
const BODY_TILE := "interface\\ifcommon\\bg_tile\\com_bg_tile_b.ddj"
const BODY_RECT := Rect2(6, 26, 692, 326)
const INNER_FRAME := "interface\\frame\\frameg_wnd_"
const INNER_RECT := Rect2(8, 60, 689, 291)
const TAB_ON := "interface\\ifcommon\\com_new_tab_on_"
const TAB_OFF := "interface\\ifcommon\\com_new_tab_off_"
const TAB_RECTS := [Rect2(18, 39, 72, 24), Rect2(92, 39, 72, 24)]
const LIST_FRAME := "interface\\ifcommon\\com_square_"
const LIST_RECT := Rect2(23, 71, 660, 241)
const LIST_FILL := Color8(16, 16, 16)
const HEAD_BAR := "interface\\ifcommon\\com_bar02_"
const HEAD_Y := 74.0
const HEAD_H := 24.0
## [x, width] of each column's head (and its cells).
const COLUMNS := [[26, 27], [53, 304], [357, 82], [439, 150], [589, 92]]
const ROWS_PER_PAGE := 10
const ROW_Y0 := 97.0
const ROW_PITCH := 21.0
const ROW_H := 20.0
const LINE_COLOUR := Color8(49, 52, 49)
const LINE_X := 27.0
const LINE_W := 654.0
const SELECT_BAR := "interface\\ifcommon\\com_bar01select_"
const REMAIN_RECT := Rect2(26, 321, 118, 20)
const COUNT_FRAME := "interface\\ifcommon\\com_blacksquare_"
const COUNT_RECT := Rect2(146, 321, 37, 20)
const COUNT_TEXT_INSET := 4.0
const NOTE_RECT := Rect2(26, 321, 300, 20)
const PAGE_LEFT := "interface\\ifcommon\\com_left_arrow.ddj"
const PAGE_RIGHT := "interface\\ifcommon\\com_right_arrow.ddj"
const PAGE_LEFT_RECT := Rect2(329, 322, 16, 16)
const PAGE_BOX_RECT := Rect2(345, 322, 16, 16)
const PAGE_RIGHT_RECT := Rect2(361, 322, 16, 16)
const BUTTON := "interface\\ifcommon\\com_button.ddj"
const TAKE_ALL_RECT := Rect2(532, 317, 76, 24)
const TAKE_RECT := Rect2(610, 317, 76, 24)
const TEXT_COLOUR := Color(1, 1, 1)

const TAB_CHEST := 0
const TAB_LOG := 1

## [key, fallback]: the key's English where the archive has the key.
const T_CAPTION := ["VPLUS_UI_CHEST_CAPTION_TEXT", "Chest"]
const T_TAB_LOG := ["VPLUS_UI_ITEM_STORAGE_BOX_TAB_LOGS", "Take Log"]
const T_HEADS := [["UIIT_STT_BOX_NUM", "No."], ["", "Item Name"],
	["VPLUS_UI_CHEST_LIST_COLUMN_QUANTITY_TEXT", "Quantity"], ["", "From"],
	["UIIT_STT_SILK_INQUIRY_DATE", "Date"]]
const T_TAKE := ["VPLUS_UI_ITEM_STORAGE_BOX_ITEMS_BUTTON_TAKE", "Take"]
const T_TAKE_ALL := ["VPLUS_UI_ITEM_STORAGE_BOX_ITEMS_BUTTON_TAKE_ALL", "Take All"]
const T_REMAIN := ["VPLUS_UI_ITEM_STORAGE_BOX_ITEMS_INV_SLOTS", "Inventory Remaining"]
const T_NOTE := ["VPLUS_UI_ITEM_STORAGE_BOX_LOGS_DATE_INFO", "*Only logs from the last 7 days will appear."]
const T_RECEIVED := ["VPLUS_MSG_CHEST_ITEM_RECEIVED", "You have recieved item [%s] into your chest."]
const T_FULL := ["VPLUS_MSG_CHEST_INVENTORY_FULL_ERROR", "Inventory is full, cannot claim anymore items."]

## A line for the system window (HudPanels relays it to system_notice).
signal message(text: String)
## The chest has something new the player has not looked at (the icon blinks).
signal alert_changed(on: bool)
signal opened

## NetClient, or a stand-in a test gives.
var net = null
## Free bag slots, `func() -> int` (-1 unknown). Default: HudPanels' bag.
var free_slots: Callable = Callable()
## An item's display name, `func(ref_id: int) -> String`. Default: HudPanels.
var item_name: Callable = Callable()

var tab := TAB_CHEST
var page := 0
## The chest as 0x00D1 gave it: [{"entry", "item", "count", "from", "date"}].
var entries: Array = []
## The take log as 0x00D5 gave it: [{"item", "count", "from", "date", "taken"}].
var log_entries: Array = []
## The selected chest entry's id, 0 for none.
var selected_entry := 0
var alert := false

var _panels = null
var _tabs: Array = []
var _rows: Array = []
var _row_marks: Array = []
var _remain_label: Label
var _count_label: Label
var _note_label: Label
var _page_label: Label
var _take: TextureButton
var _take_all: TextureButton
var _page_left: TextureButton
var _page_right: TextureButton
var _built := false

func _init(builder: UiBuilder = null) -> void:
	super._init()
	_builder = builder
	visible = false
	name = "Window_item_chest"

func _net():
	if net != null:
		return net
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("/root/NetClient") if tree != null else null

## Connects the chest's four replies (once). Call it when the HUD is made, so
## a 0x00D6 is heard while the window is closed.
func attach_net(n = null) -> void:
	if n != null:
		net = n
	var src = _net()
	if src == null:
		return
	var wiring := {"chest_list": on_list, "chest_take_result": on_take_result,
		"chest_log": on_log, "chest_received": on_received}
	for sig in wiring:
		if src.has_signal(sig) and not src.is_connected(sig, wiring[sig]):
			src.connect(sig, wiring[sig])

# --- opening and closing -----------------------------------------------------------

## Opens the window under `parent` (HudPanels): built on first use, centred
## and in front (OURS), the Chest tab, the list asked for, the alert cleared.
func open(parent: Node) -> bool:
	if parent != null:
		_panels = parent
	if not _built:
		if _builder == null and parent != null:
			_builder = parent.get("_builder") as UiBuilder
		if not build_window():
			return false
	if parent != null and get_parent() != parent:
		if get_parent() != null:
			get_parent().remove_child(self)
		parent.add_child(self)
	attach_net()
	show()
	place_centred()
	move_to_front()
	set_alert(false)
	select_tab(TAB_CHEST)
	opened.emit()
	return true

func close() -> void:
	if not visible:
		return
	hide()
	closed.emit()

func toggle(parent: Node) -> void:
	if is_open():
		close()
	else:
		open(parent)

func is_open() -> bool:
	return _built and visible

func _on_close_pressed() -> void:
	close()

func place_centred() -> void:
	var view := get_viewport_rect().size
	position = Vector2(maxi(0, (int(view.x) >> 1) - (int(size.x) >> 1)),
		maxi(0, (int(view.y) >> 1) - (int(size.y) >> 1)))

# --- building ----------------------------------------------------------------------

func build_window() -> bool:
	if _builder == null:
		return false
	custom_minimum_size = WINDOW_SIZE
	size = WINDOW_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	panel_root = Control.new()
	panel_root.name = "ChestRoot"
	panel_root.mouse_filter = Control.MOUSE_FILTER_PASS
	_place(panel_root, Rect2(Vector2.ZERO, WINDOW_SIZE))
	add_child(panel_root)
	var tile := _builder._build_tile(_def(BODY_TILE, BODY_RECT))
	tile.name = "Body"
	_place(tile, BODY_RECT)
	panel_root.add_child(tile)
	_frame(FRAME, Rect2(Vector2.ZERO, WINDOW_SIZE), "Frame")
	_frame(INNER_FRAME, INNER_RECT, "InnerFrame")
	var fill := ColorRect.new()
	fill.name = "ListFill"
	fill.color = LIST_FILL
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(fill, LIST_RECT.grow(-2.0))
	panel_root.add_child(fill)
	_frame(LIST_FRAME, LIST_RECT, "ListFrame")
	for i in COLUMNS.size():
		var r := Rect2(float(COLUMNS[i][0]), HEAD_Y, float(COLUMNS[i][1]), HEAD_H)
		var head := Control.new()
		head.name = "Head%d" % i
		head.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_place(head, r)
		_builder._add_row_bar_from(head, HEAD_BAR, r.size)
		panel_root.add_child(head)
		# The caption on the bar's 20 drawn rows (the last 3 are its black
		# under-line; MEASURED: the text is centred on rows 74..94).
		head.add_child(_label(_text(T_HEADS[i]), Rect2(0, 0, r.size.x, HEAD_H - 3.0), HORIZONTAL_ALIGNMENT_CENTER, "Text"))
	for k in ROWS_PER_PAGE - 1:
		var line := ColorRect.new()
		line.name = "Line%d" % k
		line.color = LINE_COLOUR
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_place(line, Rect2(LINE_X, ROW_Y0 + ROW_PITCH * (k + 1), LINE_W, 1))
		panel_root.add_child(line)
	_rows.clear()
	_row_marks.clear()
	for k in ROWS_PER_PAGE:
		_rows.append(_make_row(k))
	for t in 2:
		_tabs.append(_make_tab(t))
	_remain_label = _label(_text(T_REMAIN), REMAIN_RECT, HORIZONTAL_ALIGNMENT_LEFT, "Remaining")
	panel_root.add_child(_remain_label)
	var count_fill := ColorRect.new()
	count_fill.name = "CountFill"
	count_fill.color = Color(0, 0, 0)
	count_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(count_fill, COUNT_RECT)
	panel_root.add_child(count_fill)
	_frame(COUNT_FRAME, COUNT_RECT, "CountFrame")
	_count_label = _label("", Rect2(COUNT_RECT.position, COUNT_RECT.size - Vector2(COUNT_TEXT_INSET, 0)),
		HORIZONTAL_ALIGNMENT_RIGHT, "Count")
	panel_root.add_child(_count_label)
	_note_label = _label(_text(T_NOTE), NOTE_RECT, HORIZONTAL_ALIGNMENT_LEFT, "Note")
	_note_label.visible = false
	panel_root.add_child(_note_label)
	var box := ColorRect.new()
	box.name = "PageBox"
	box.color = Color(0, 0, 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(box, PAGE_BOX_RECT)
	panel_root.add_child(box)
	_page_label = _label("1", PAGE_BOX_RECT, HORIZONTAL_ALIGNMENT_CENTER, "Page")
	panel_root.add_child(_page_label)
	_page_left = _button(PAGE_LEFT, PAGE_LEFT_RECT, "", "PageLeft")
	_page_left.pressed.connect(func() -> void: set_page(page - 1))
	_page_right = _button(PAGE_RIGHT, PAGE_RIGHT_RECT, "", "PageRight")
	_page_right.pressed.connect(func() -> void: set_page(page + 1))
	_take_all = _button(BUTTON, TAKE_ALL_RECT, _text(T_TAKE_ALL), "TakeAll")
	_take_all.pressed.connect(press_take_all)
	_take = _button(BUTTON, TAKE_RECT, _text(T_TAKE), "Take")
	_take.pressed.connect(press_take)
	_add_title_bar(_text(T_CAPTION))
	var bar := get_node_or_null("TitleBar") as Label
	if bar != null:
		bar.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		# MEASURED: the picture's caption is white (251,251,251), as a
		# registry window's CTextBoard default (HudWindow.MAINFRAME_CAPTION_COLOUR).
		bar.add_theme_color_override("font_color", MAINFRAME_CAPTION_COLOUR)
	_settle()
	_built = true
	_show_tab()
	return true

static func _def(ddj: String, r: Rect2) -> UiLayoutParser.ControlDef:
	var def := UiLayoutParser.ControlDef.new()
	def.ddj = ddj
	def.rect = Rect2i(Vector2i(r.position), Vector2i(r.size))
	return def

## A control on `r`, kept there by the settling pass (UiBuilder).
static func _place(c: Control, r: Rect2) -> void:
	c.position = r.position
	c.size = r.size
	c.set_meta(UiBuilder.AUTHORED_RECT_META, r)

func _frame(base: String, r: Rect2, node_name: String) -> Control:
	var f := _builder._build_frame(_def(base, Rect2(Vector2.ZERO, r.size)))
	f.name = node_name
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(f, r)
	panel_root.add_child(f)
	return f

func _label(text: String, r: Rect2, align: HorizontalAlignment, node_name: String) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.clip_text = false
	var font := _builder.font_at(0) if _builder != null else null
	if font != null:
		l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	l.add_theme_color_override("font_color", TEXT_COLOUR)
	UiBuilder.crisp_text(l)
	_place(l, r)
	return l

func _button(ddj: String, r: Rect2, caption: String, node_name: String) -> TextureButton:
	var b := TextureButton.new()
	b.name = node_name
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_SCALE
	b.focus_mode = Control.FOCUS_NONE
	b.texture_normal = _builder.load_texture(ddj)
	b.texture_hover = _builder.load_texture(_builder._insert_suffix(ddj, "_focus"))
	b.texture_pressed = _builder.load_texture(_builder._insert_suffix(ddj, "_press"))
	b.texture_disabled = _builder.load_texture(_builder._insert_suffix(ddj, "_disable"))
	_place(b, r)
	if caption != "":
		b.add_child(_label(caption, Rect2(Vector2.ZERO, r.size), HORIZONTAL_ALIGNMENT_CENTER, "Text"))
	panel_root.add_child(b)
	return b

## A tab: the 3-slice bar (on / off) under a centred caption.
func _make_tab(t: int) -> TextureButton:
	var r: Rect2 = TAB_RECTS[t]
	var b := TextureButton.new()
	b.name = "Tab%d" % t
	b.ignore_texture_size = true
	b.focus_mode = Control.FOCUS_NONE
	_place(b, r)
	for state in ["on", "off"]:
		var holder := Control.new()
		holder.name = "Art_" + state
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_place(holder, Rect2(Vector2.ZERO, r.size))
		_builder._add_row_bar_from(holder, TAB_ON if state == "on" else TAB_OFF, r.size)
		b.add_child(holder)
	var caption := _text(T_CAPTION) if t == TAB_CHEST else _text(T_TAB_LOG)
	b.add_child(_label(caption, Rect2(Vector2.ZERO, r.size), HORIZONTAL_ALIGNMENT_CENTER, TwoDtBuilder.TEXT_NODE))
	b.pressed.connect(func() -> void: select_tab(t))
	panel_root.add_child(b)
	return b

## A row: the selection bar (hidden) and one cell per column.
func _make_row(k: int) -> Control:
	var r := Rect2(float(COLUMNS[0][0]), ROW_Y0 + ROW_PITCH * k, float(COLUMNS[4][0] + COLUMNS[4][1] - COLUMNS[0][0]), ROW_H)
	var row := Control.new()
	row.name = "Row%d" % k
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	_place(row, r)
	var mark := Control.new()
	mark.name = "Select"
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark.visible = false
	_place(mark, Rect2(Vector2(0, 0), r.size))
	_builder._add_row_bar_from(mark, SELECT_BAR, r.size)
	row.add_child(mark)
	_row_marks.append(mark)
	for c in COLUMNS.size():
		var cell := _label("", Rect2(float(COLUMNS[c][0]) - r.position.x, 0, float(COLUMNS[c][1]), ROW_H),
			HORIZONTAL_ALIGNMENT_CENTER, "Cell%d" % c)
		cell.clip_text = true
		row.add_child(cell)
	row.gui_input.connect(func(e: InputEvent) -> void: _on_row_input(e, k))
	panel_root.add_child(row)
	return row

func _text(pair: Array) -> String:
	var key: String = pair[0]
	var table := _builder.text_table() if _builder != null else null
	if key == "" or table == null or not table.has(key):
		return pair[1]
	var t := table.get_text(key)
	return t if t != "" and t != "0" else pair[1]

# --- the tabs and the pages ----------------------------------------------------------

func select_tab(t: int) -> void:
	tab = t
	page = 0
	selected_entry = 0
	_show_tab()
	var n = _net()
	if n == null:
		return
	if t == TAB_CHEST and n.has_method("chest_list_request"):
		n.chest_list_request()
	elif t == TAB_LOG and n.has_method("chest_log_request"):
		n.chest_log_request()

func _show_tab() -> void:
	if not _built:
		return
	for t in _tabs.size():
		var b := _tabs[t] as Control
		var on := t == tab
		b.get_node("Art_on").visible = on
		b.get_node("Art_off").visible = not on
		TwoDtBuilder._caption_weight(b, on)
	var chest := tab == TAB_CHEST
	_remain_label.visible = chest
	_count_label.visible = chest
	panel_root.get_node("CountFrame").visible = chest
	panel_root.get_node("CountFill").visible = chest
	_take.visible = chest
	_take_all.visible = chest
	_note_label.visible = not chest
	refresh_inventory()
	redraw()

func current_list() -> Array:
	return entries if tab == TAB_CHEST else log_entries

func pages() -> int:
	return maxi(1, ceili(float(current_list().size()) / float(ROWS_PER_PAGE)))

func set_page(p: int) -> void:
	var next := clampi(p, 0, pages() - 1)
	if next == page:
		return
	page = next
	redraw()

func redraw() -> void:
	if not _built:
		return
	var list := current_list()
	page = clampi(page, 0, pages() - 1)
	for k in ROWS_PER_PAGE:
		var i := page * ROWS_PER_PAGE + k
		var row := _rows[k] as Control
		var cells: Array = ["", "", "", "", ""]
		var tip := ""
		var entry_id := 0
		if i < list.size():
			var e: Dictionary = list[i]
			var when := int(e.get("date", 0)) if tab == TAB_CHEST else int(e.get("taken", 0))
			cells = [str(i + 1), _name_of(int(e.get("item", 0))), str(int(e.get("count", 0))),
				str(e.get("from", "")), format_day(when)]
			tip = format_stamp(when)
			entry_id = int(e.get("entry", 0)) if tab == TAB_CHEST else 0
		for c in cells.size():
			(row.get_node("Cell%d" % c) as Label).text = cells[c]
		(row.get_node("Cell4") as Label).tooltip_text = tip
		row.tooltip_text = tip
		row.set_meta("entry", entry_id)
		(_row_marks[k] as Control).visible = entry_id != 0 and entry_id == selected_entry
	_page_label.text = str(page + 1)
	_take.disabled = selected_entry == 0 or _index_of(selected_entry) < 0
	_take_all.disabled = false

func _name_of(ref_id: int) -> String:
	var n := ""
	if item_name.is_valid():
		n = str(item_name.call(ref_id))
	elif _panels != null and _panels.has_method("item_name"):
		n = str(_panels.item_name(ref_id))
	return n if n != "" else "#%d" % ref_id

func _index_of(entry_id: int) -> int:
	for i in entries.size():
		if int((entries[i] as Dictionary).get("entry", 0)) == entry_id:
			return i
	return -1

func _on_row_input(e: InputEvent, k: int) -> void:
	var mb := e as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	select_row(k)
	(_rows[k] as Control).accept_event()

## A press on row `k` of the page: selects its chest entry (Chest tab only).
func select_row(k: int) -> void:
	if tab != TAB_CHEST or k < 0 or k >= ROWS_PER_PAGE:
		return
	var id := int((_rows[k] as Control).get_meta("entry", 0))
	if id == 0:
		return
	selected_entry = id
	redraw()

## The free bag slots in the count box.
func refresh_inventory() -> void:
	if _count_label == null:
		return
	var n := _free_slots()
	_count_label.text = str(n) if n >= 0 else ""

func _free_slots() -> int:
	if free_slots.is_valid():
		return int(free_slots.call())
	var p = _panels
	if p == null:
		return -1
	if p.has_method("free_bag_slots"):
		return int(p.free_bag_slots())
	# HudPanels' own bag (first_empty_bag_slot's reading of it).
	if not p.has_method("_bag_size_shown"):
		return -1
	var taken := {}
	var bag = p.get("_bag_slots")
	if bag is Array:
		for entry in bag:
			var s = p._first_field(entry, ["slot", "slot_index", "index"]) if p.has_method("_first_field") else null
			if s != null:
				taken[int(s)] = true
	return maxi(int(p._bag_size_shown()) - taken.size(), 0)

# --- requests and replies ------------------------------------------------------------

func press_take() -> void:
	if selected_entry == 0 or _index_of(selected_entry) < 0:
		return
	var n = _net()
	if n != null and n.has_method("chest_take"):
		n.chest_take(selected_entry)

func press_take_all() -> void:
	var n = _net()
	if n != null and n.has_method("chest_take"):
		n.chest_take(0)

## 0x00D1.
func on_list(list: Array) -> void:
	entries = list.duplicate()
	if selected_entry != 0 and _index_of(selected_entry) < 0:
		selected_entry = 0
	refresh_inventory()
	redraw()

## 0x00D5.
func on_log(list: Array) -> void:
	log_entries = list.duplicate()
	redraw()

## 0x00D3 (server internal/mall/chest.go): {1, items taken} or {2, code}, and
## the server sends a fresh 0x00D1 after either, so nothing is asked here.
## 0x1807 (the bag is full; a take-all that took some answers 1) prints
## VPLUS_MSG_CHEST_INVENTORY_FULL_ERROR; any other code the client's own line
## for it where it has one (ErrorText: 0x1834 STORAGE_OPERATION_BLOCKED,
## during an exchange), else nothing (OURS).
const CODE_BAG_FULL := 0x1807

func on_take_result(result: Dictionary) -> void:
	if result.is_empty():
		return
	if bool(result.get("ok", false)):
		refresh_inventory()
		return
	var code := int(result.get("value", 0))
	if code == CODE_BAG_FULL:
		message.emit(_text(T_FULL))
		return
	var table := _builder.text_table() if _builder != null else null
	var line: String = ErrorText.resolve(code, table, "")
	if line == "" and code == 0x1834 and table != null and table.has("UIIT_MSG_STRGERR_STORAGE_OPERATION_BLOCKED"):
		line = table.get_text("UIIT_MSG_STRGERR_STORAGE_OPERATION_BLOCKED")
	if line != "":
		message.emit(line)

## 0x00D6: the system line, and the icon blinks until the window is opened;
## an open window asks for its list again.
func on_received(entry: Dictionary) -> void:
	if entry.is_empty():
		return
	var line := _text(T_RECEIVED)
	message.emit(line.replace("%s", _name_of(int(entry.get("item", 0)))) if line.contains("%s") else line)
	if is_open():
		if tab == TAB_CHEST:
			var n = _net()
			if n != null and n.has_method("chest_list_request"):
				n.chest_list_request()
	else:
		set_alert(true)

func set_alert(on: bool) -> void:
	if alert == on:
		return
	alert = on
	alert_changed.emit(on)

# --- tests and tools -----------------------------------------------------------------

func row_texts(k: int) -> Array:
	var row := _rows[k] as Control if k >= 0 and k < _rows.size() else null
	if row == null:
		return []
	var out: Array = []
	for c in COLUMNS.size():
		out.append((row.get_node("Cell%d" % c) as Label).text)
	return out

func row_control(k: int) -> Control:
	return _rows[k] as Control if k >= 0 and k < _rows.size() else null

func take_button() -> TextureButton:
	return _take

func take_all_button() -> TextureButton:
	return _take_all

func tab_button(t: int) -> TextureButton:
	return _tabs[t] as TextureButton if t >= 0 and t < _tabs.size() else null

func count_text() -> String:
	return _count_label.text if _count_label != null else ""

func page_text() -> String:
	return _page_label.text if _page_label != null else ""

func note_visible() -> bool:
	return _note_label != null and _note_label.visible

func page_buttons() -> Array:
	return [_page_left, _page_right]

## CNIFMainFrame's chrome, as OptionWindow places it.
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

# --- dates (OURS: unix seconds, the player's local time) -------------------------------

static func _local(unix: int) -> Dictionary:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0))
	return Time.get_datetime_dict_from_unix_time(unix + bias * 60)

## The cell's text: "2026/10/27" (the column is 92 wide; the time is in the
## tooltip).
static func format_day(unix: int) -> String:
	if unix <= 0:
		return ""
	var d := _local(unix)
	return "%4d/%02d/%02d" % [d.year, d.month, d.day]

## The silk list's own format (SilkHistoryWindow.format_date, READ there).
static func format_stamp(unix: int) -> String:
	if unix <= 0:
		return ""
	var d := _local(unix)
	return "%4d/%02d/%02d %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]
