extends HudWindow
class_name StallNetworkWindow

## Round 840 (lane N): the stall network window, `CNIFStallNetwork`, built
## from `res_ui\stallnetwork.2dt` (docs/protocol/stall_network.md §3, READ
## from sro_client.exe unless marked). The window draws and keeps its pages;
## StallNetworkController sends and answers.
##
## - The file (MEASURED, 148 records): root 150, 662 x 561, `mframe_wnd_`,
##   UIIT_STT_WARENETWORK_TITLE; the combos 6 Class, 7 Type, 8 Degree;
##   Search 4; the Seller caption 13 and box 14; the page manager 16;
##   Whisper 17, Purchase 18; the gold 22; the column buttons 1397 Number,
##   1398 Level, 1393 Name, 1394 Quantity, 1395 Price; fifteen
##   CNIFStallNetworkSlot rows 120..234 with 121 the bar, 122 Number, 123
##   Level, 124 the icon, 125 Name, 126 Quantity, 127 Price.
## - OnCreate (c:0x6c5140): Class "Choose" + the tree's classes; Type and
##   Degree "None"; Search's tooltip UIIT_MSG_WARENETWORK_SCAN_TOOLTIP;
##   Whisper off; Purchase off while this player's own stall window exists;
##   the Seller caption hidden; the page manager hidden; the gold
##   (c:0x6becb0: "%s %s", the gold with ',' groups and UIIT_STT_GOLD).
## - Class changed (0x6c4830 -> 0x6c43f0): Type "Choose" + the class's types
##   (or "None" with no class), Degree "None". Type changed (0x6c2050 ->
##   0x6c1ed0): Degree "Choose" + "%d %s" (n, UIIT_STT_CLASS) for each degree,
##   or "None".
## - Search (0x6c9d70): a type, and a degree when it has degrees; then Search
##   off for 10000 ms (timer 1, vslot_005), the caches cleared, page 0, mode 1
##   the first time (the process flag 0xeea828) else 2 (0x6c4870).
## - A row (0x6c20d0 / 0x6cb110): a filled row is selected on
##   `com_bar01select_left.ddj`, Whisper on, the Seller caption shown and
##   the box set to the seller; an empty row selects nothing.
## - A page (0x6c70d0): ignored while an answer is awaited (+0x84c); a page
##   never asked for and empty asks mode 3, else its cache is shown.
## - A column button (0x6c71f0 -> 0x6c6f70(1..5)): the page shown in that
##   column's order (INFERRED ascending: the page is re-read through a tree
##   insert, 0x6c6310, and no direction flag was found).
## - A row's name is white, or 0xffff4a4a when 0x8bd0e0 says no (0x6cad2b) --
##   round 829 read that test as "can the item be repaired" (RepairQuote:
##   not with MATTR_NOT_REPARABLE or MATTR_REPAIR at 1 or less); the price
##   ',' grouped and coloured by its amount (0x5d3df0).

signal search_requested(mode: int, page: int, group: int, degree: int)
signal buy_requested(record: StallNetworkNet.Record)
signal whisper_requested(seller: String)

const FILE_2DT := "res_ui\\stallnetwork.2dt"
const ID_SEARCH := 4
const ID_CLASS := 6
const ID_TYPE := 7
const ID_DEGREE := 8
const ID_SELLER_CAPTION := 13
const ID_SELLER_BOX := 14
const ID_PAGES := 16
const ID_WHISPER := 17
const ID_BUY := 18
const ID_GOLD := 22
const ROW_IDS := [120, 129, 137, 145, 154, 162, 170, 178, 186, 194, 202, 210, 218, 226, 234]
const ROW_BAR := 121
const ROW_NUMBER := 122
const ROW_LEVEL := 123
const ROW_ICON := 124
const ROW_NAME := 125
const ROW_COUNT := 126
const ROW_PRICE := 127
## The column buttons in 0x6c71f0's order (1..5; the message map's ids).
const SORT_BUTTONS := [1397, 1393, 1394, 1398, 1395]
const SORT_NUMBER := 1
const SORT_NAME := 2
const SORT_COUNT := 3
const SORT_LEVEL := 4
const SORT_PRICE := 5
const BAR_BASE := "interface\\ifcommon\\com_bar01_"
const BAR_SELECTED_BASE := "interface\\ifcommon\\com_bar01select_"
const SEARCH_COOLDOWN_S := 10.0
const UNUSABLE_COLOUR := Color8(0xff, 0x4a, 0x4a)

var _file: TwoDtReader.TwoDtFile
var _twodt: TwoDtBuilder
var _class_combo: OptionButton
var _type_combo: OptionButton
var _degree_combo: OptionButton
var pager: NifPageManager
var _cooldown: Timer

## The tree (StallNetworkNet.parse_tree) and the shown class's types.
var classes: Array = []
var types: Array = []
## The page caches (+0x7dc, one Array of records a page), the pages asked
## for (+0x7e8), the shown page (+0x844), the page count (+0x846), an answer
## awaited (+0x84c), the last search's group (+0x848) and degree.
var cache: Array = []
var asked: Array[int] = []
var page := 0
var pages := 0
var awaiting := false
var last_group := 0
var last_degree := 0
## The process flag 0xeea828 (mode 1 sent; 0x7462 due at the close).
var entered := false
## The rows' records as shown (sorted when a column was pressed), and the
## selected row (+0x808), -1 none.
var shown_records: Array = []
var selected := -1
var sort_key := 0
## World/HudPanels callbacks: an item's icon, name, and 0x8bd0e0.
var item_icon := Callable()
var item_name := Callable()
var repairable := Callable()

func _init(builder: UiBuilder = null) -> void:
	super._init()
	_builder = builder

func build_window() -> bool:
	if _builder == null:
		return false
	_file = _builder.load_2dt(FILE_2DT)
	if _file == null or _file.records.is_empty():
		return false
	_twodt = TwoDtBuilder.new(_builder)
	panel_root = _twodt.build(_file, FILE_2DT)
	var window_size := Vector2(_file.root().rect.size)
	custom_minimum_size = window_size
	size = window_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel_root)
	var root_text := panel_root.get_node_or_null(TwoDtBuilder.TEXT_NODE)
	if root_text != null:
		root_text.queue_free()
	_add_title_bar(_builder.resolve_text(_file.root().text_id))
	var bar := get_node_or_null("TitleBar") as Label
	if bar != null:
		bar.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_class_combo = OptionVideoPage.make_combo(_builder, control([ID_CLASS]))
	_type_combo = OptionVideoPage.make_combo(_builder, control([ID_TYPE]))
	_degree_combo = OptionVideoPage.make_combo(_builder, control([ID_DEGREE]))
	if _class_combo != null:
		_class_combo.item_selected.connect(func(_i: int) -> void: class_changed())
	if _type_combo != null:
		_type_combo.item_selected.connect(func(_i: int) -> void: type_changed())
	var host := control([ID_PAGES])
	pager = NifPageManager.new(_builder)
	pager.name = "PageManager"
	if host != null:
		pager.size = host.size
		host.mouse_filter = Control.MOUSE_FILTER_PASS
		host.add_child(pager)
	pager.page_changed.connect(page_changed)
	pager.visible = false
	_cooldown = Timer.new()
	_cooldown.one_shot = true
	_cooldown.wait_time = SEARCH_COOLDOWN_S
	_cooldown.timeout.connect(func() -> void: _enable(ID_SEARCH, true))
	add_child(_cooldown)
	_wire()
	_settle()
	return true

func _wire() -> void:
	var b := control([ID_SEARCH]) as BaseButton
	if b != null:
		b.pressed.connect(press_search)
		b.tooltip_text = _text("UIIT_MSG_WARENETWORK_SCAN_TOOLTIP")
	b = control([ID_BUY]) as BaseButton
	if b != null:
		b.pressed.connect(press_buy)
	b = control([ID_WHISPER]) as BaseButton
	if b != null:
		b.pressed.connect(press_whisper)
	for k in SORT_BUTTONS.size():
		b = control([int(SORT_BUTTONS[k])]) as BaseButton
		if b != null:
			b.pressed.connect(press_sort.bind(k + 1))
	for i in ROW_IDS.size():
		var row := control([int(ROW_IDS[i])])
		if row != null:
			row.mouse_filter = Control.MOUSE_FILTER_STOP
			row.gui_input.connect(_row_input.bind(i))

func _row_input(event: InputEvent, i: int) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		select_row(i)
		accept_event()

## OnCreate's state (c:0x6c5140), after the tree is given.
func on_create(tree: Array, own_stall_open: bool, gold: int) -> void:
	classes = tree
	if _class_combo != null:
		_class_combo.clear()
		_class_combo.add_item(_text("UIIT_CTL_WARENETWORK_SCAN_SELECT"))
		for c in classes:
			_class_combo.add_item(_text((c as StallNetworkNet.Category).text_key))
		_class_combo.select(0)
	_fill_types()
	_enable(ID_WHISPER, false)
	_enable(ID_BUY, not own_stall_open)
	_set_shown([ID_SELLER_CAPTION], false)
	_set_shown([ID_SELLER_BOX], true)
	_set_text([ID_SELLER_BOX], "")
	set_gold(gold)
	_clear_rows()

# --- the combos ---------------------------------------------------------------------

func class_changed() -> void:
	_fill_types()

func _fill_types() -> void:
	types = []
	var ci := _class_combo.selected if _class_combo != null else -1
	if _type_combo != null:
		_type_combo.clear()
		if ci < 1 or ci - 1 >= classes.size():
			_type_combo.add_item(_text("UIIT_CTL_WARENETWORK_SCAN_END"))
		else:
			types = (classes[ci - 1] as StallNetworkNet.Category).types
			_type_combo.add_item(_text("UIIT_CTL_WARENETWORK_SCAN_SELECT"))
			for t in types:
				_type_combo.add_item(_text((t as StallNetworkNet.Category).text_key))
		_type_combo.select(0)
	_fill_degrees(null)

func type_changed() -> void:
	_fill_degrees(selected_type())

func _fill_degrees(t: StallNetworkNet.Category) -> void:
	if _degree_combo == null:
		return
	_degree_combo.clear()
	if t != null and t.degrees > 0:
		_degree_combo.add_item(_text("UIIT_CTL_WARENETWORK_SCAN_SELECT"))
		var word := _text("UIIT_STT_CLASS")
		for n in range(1, t.degrees + 1):
			_degree_combo.add_item("%d %s" % [n, word])
	else:
		_degree_combo.add_item(_text("UIIT_CTL_WARENETWORK_SCAN_END"))
	_degree_combo.select(0)

func selected_type() -> StallNetworkNet.Category:
	var ti := _type_combo.selected if _type_combo != null else -1
	if ti < 1 or ti - 1 >= types.size():
		return null
	return types[ti - 1]

## Tests / QA: choose by index (fires the change as a click does).
func choose(combo_id: int, index: int) -> void:
	var c := combo(combo_id)
	if c == null or index < 0 or index >= c.item_count:
		return
	c.select(index)
	match combo_id:
		ID_CLASS:
			class_changed()
		ID_TYPE:
			type_changed()

func combo(combo_id: int) -> OptionButton:
	match combo_id:
		ID_CLASS:
			return _class_combo
		ID_TYPE:
			return _type_combo
		ID_DEGREE:
			return _degree_combo
	return null

# --- search and pages ---------------------------------------------------------------

## Search (c:0x6c9d70).
func press_search() -> String:
	var t := selected_type()
	if t == null:
		return "no type"
	var degree := 0
	if t.degrees > 0:
		degree = _degree_combo.selected if _degree_combo != null else 0
		if degree < 1:
			return "no degree"
	_enable(ID_SEARCH, false)
	if _cooldown != null and _cooldown.is_inside_tree():
		_cooldown.start()
	cache = []
	asked = []
	page = 0
	pages = 0
	select_row(-1)
	_clear_rows()
	last_group = t.group
	last_degree = degree
	var mode := StallNetworkNet.MODE_SEARCH if entered else StallNetworkNet.MODE_FIRST
	entered = true
	_ask(mode)
	return "search mode %d group %d degree %d" % [mode, t.group, degree]

## 0x6c4870: +0x84c set, 0x7461, the page recorded as asked.
func _ask(mode: int) -> void:
	awaiting = true
	search_requested.emit(mode, page, last_group, last_degree)
	asked.append(page)

## 0xB461 {1, n, pages, records} (c:0x88dca0).
func on_result(d: Dictionary) -> void:
	var p := int(d.get("pages", 0))
	if p <= 0:
		return
	pages = p
	while cache.size() < pages:
		cache.append([])
	if cache.size() > pages:
		cache.resize(pages)
	if pager != null:
		pager.set_page(page, pages)
		pager.visible = true
	if page < cache.size():
		cache[page] = (d.get("records", []) as Array).duplicate()
	show_page()
	awaiting = false

## The page manager's 0x8071 (c:0x6c70d0).
func page_changed(p: int) -> void:
	if awaiting or p == page or pages <= 0:
		return
	page = p
	select_row(-1)
	var empty := page >= cache.size() or (cache[page] as Array).is_empty()
	if empty and not asked.has(page):
		_ask(StallNetworkNet.MODE_PAGE)
		return
	show_page()

## 0x6c6f70: the shown page's records into the rows, in the column order
## pressed last.
func show_page() -> void:
	select_row(-1)
	shown_records = (cache[page] as Array).duplicate() if page < cache.size() else []
	if sort_key != 0:
		shown_records.sort_custom(_less)
	_clear_rows()
	for i in mini(shown_records.size(), ROW_IDS.size()):
		_fill_row(i, shown_records[i])

func press_sort(key: int) -> void:
	sort_key = key
	select_row(-1)
	show_page()

func _less(a: StallNetworkNet.Record, b: StallNetworkNet.Record) -> bool:
	match sort_key:
		SORT_NUMBER:
			return a.number < b.number
		SORT_NAME:
			return _name_of(a) < _name_of(b)
		SORT_COUNT:
			return a.count < b.count
		SORT_LEVEL:
			return a.level < b.level
		SORT_PRICE:
			return a.price < b.price
	return false

func _name_of(r: StallNetworkNet.Record) -> String:
	return String(item_name.call(r.item.ref_item_id)) if item_name.is_valid() and r.item != null else ""

func _clear_rows() -> void:
	for i in ROW_IDS.size():
		var row := control([int(ROW_IDS[i])])
		if row == null:
			continue
		row.set_meta("filled", false)
		for id in [ROW_NUMBER, ROW_LEVEL, ROW_NAME, ROW_COUNT, ROW_PRICE]:
			_set_text([int(ROW_IDS[i]), id], "")
		var icon := _icon_rect(i)
		if icon != null:
			icon.texture = null
		_set_bar(i, false)

func _fill_row(i: int, r: StallNetworkNet.Record) -> void:
	var rid := int(ROW_IDS[i])
	var row := control([rid])
	if row == null:
		return
	row.set_meta("filled", true)
	_set_text([rid, ROW_NUMBER], "%d" % r.number)
	_set_text([rid, ROW_LEVEL], "%d" % r.level)
	_set_text([rid, ROW_NAME], _name_of(r))
	_set_text([rid, ROW_COUNT], "%d" % r.count)
	_set_text([rid, ROW_PRICE], StallNet.group_digits(r.price))
	var usable: bool = repairable.call(r.item) if repairable.is_valid() else true
	_colour([rid, ROW_NAME], Color.WHITE if usable else UNUSABLE_COLOUR)
	_colour([rid, ROW_PRICE], StallNet.price_colour(r.price))
	var icon := _icon_rect(i)
	if icon != null and item_icon.is_valid() and r.item != null:
		icon.texture = item_icon.call(r.item.ref_item_id)

func _icon_rect(i: int) -> TextureRect:
	var host := control([int(ROW_IDS[i]), ROW_ICON])
	if host == null:
		return null
	var icon := host.get_node_or_null("Icon") as TextureRect
	if icon == null:
		icon = TextureRect.new()
		icon.name = "Icon"
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_SCALE
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		host.add_child(icon)
	return icon

func _set_bar(i: int, on: bool) -> void:
	var bar := control([int(ROW_IDS[i]), ROW_BAR])
	if bar == null or _builder == null or bool(bar.get_meta("selected", false)) == on:
		return
	bar.set_meta("selected", on)
	# 0x6cb110 sets the bar's texture; a CNIFBarWnd cuts it at its last '_'
	# (0x4733a0) and draws left / mid / right.
	var old := bar.get_node_or_null("RowBar")
	if old != null:
		bar.remove_child(old)
		old.queue_free()
	_builder._add_row_bar_from(bar, BAR_SELECTED_BASE if on else BAR_BASE, bar.size)
	var fresh := bar.get_node_or_null("RowBar")
	if fresh != null:
		bar.move_child(fresh, 0)

func row_selected(i: int) -> bool:
	var bar := control([int(ROW_IDS[i]), ROW_BAR]) if i >= 0 and i < ROW_IDS.size() else null
	return bar != null and bool(bar.get_meta("selected", false))

# --- a row, buy, whisper -------------------------------------------------------------

## 0x6c20d0 / 0x6cb110 / 0x6bf690.
func select_row(i: int) -> void:
	if selected >= 0:
		_set_bar(selected, false)
	selected = -1
	var filled := i >= 0 and i < shown_records.size()
	if filled:
		selected = i
		_set_bar(i, true)
	_enable(ID_WHISPER, filled)
	_set_shown([ID_SELLER_CAPTION], filled)
	_set_text([ID_SELLER_BOX], (shown_records[i] as StallNetworkNet.Record).seller if filled else "")

func selected_record() -> StallNetworkNet.Record:
	return shown_records[selected] if selected >= 0 and selected < shown_records.size() else null

func press_buy() -> String:
	var r := selected_record()
	if r == null:
		return "no row"
	buy_requested.emit(r)
	return "buy box"

func press_whisper() -> void:
	var r := selected_record()
	if r != null:
		whisper_requested.emit(r.seller)

## 0xB463 {1} (c:0x6c89f0): the bought record out of its page.
func remove_record(r: StallNetworkNet.Record) -> void:
	for p in cache.size():
		var list: Array = cache[p]
		for k in list.size():
			if (list[k] as StallNetworkNet.Record).same_as(r):
				list.remove_at(k)
				if p == page:
					select_row(-1)
					show_page()
				return

## c:0x6becb0: "%s %s" -- the gold grouped, UIIT_STT_GOLD.
func set_gold(gold: int) -> void:
	_set_text([ID_GOLD], "%s %s" % [StallNet.group_digits(gold), _text("UIIT_STT_GOLD")])

# --- helpers --------------------------------------------------------------------------

func _text(key: String) -> String:
	return _builder.resolve_text(key) if _builder != null else key

func _enable(id: int, on: bool) -> void:
	var b := control([id]) as BaseButton
	if b != null:
		b.disabled = not on

func is_enabled(id: int) -> bool:
	var b := control([id]) as BaseButton
	return b != null and not b.disabled

func _set_shown(path: Array, on: bool) -> void:
	var c := control(path)
	if c != null:
		c.visible = on

func _set_text(path: Array, text: String) -> void:
	var c := control(path)
	if c != null and _twodt != null:
		_twodt.set_text(c, text)

func _colour(path: Array, colour: Color) -> void:
	var c := control(path)
	if c == null:
		return
	var l := c if c is Label else c.get_node_or_null(TwoDtBuilder.TEXT_NODE)
	if l is Label:
		(l as Label).add_theme_color_override("font_color", colour)

func text_at(path: Array) -> String:
	return TwoDtBuilder.text_of(control(path))

func control(path: Array) -> Control:
	return TwoDtBuilder.find_path(panel_root, path) if panel_root != null else null

func row(i: int) -> Control:
	return control([int(ROW_IDS[i])]) if i >= 0 and i < ROW_IDS.size() else null

# --- the chrome (CNIFMainFrame, as OptionWindow) ----------------------------------------

## 0x798c50(0x96): centred.
func place_centred() -> void:
	var view := get_viewport_rect().size
	position = Vector2(maxi(0, (int(view.x) >> 1) - (int(size.x) >> 1)),
		maxi(0, (int(view.y) >> 1) - (int(size.y) >> 1)))

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
