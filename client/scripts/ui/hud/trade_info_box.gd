extends PartyMatchBox
class_name TradeInfoBox

## Round 801: "Trade Export Details" -- CIFTradeInfoWnd (GDR_TRADE_INFO_WND,
## registry id 159, ginterface "TradeInfo", 638 x 388 on
## `interface\frame\mframe_wnd_`, caption UIIT_PAG_SPECIAL_PRICE_CONDITION_INFO;
## resinfo\iftradeinfo.txt and iftradeinfoquotationslot.txt). READ in
## sro_client.exe (docs/protocol/jobs.md, "The trade-info window"):
## - opened by the talk line 0x39 with no request (c:0x79e510);
## - the store list: specialnpcdata.txt's NPC ids (c:0x946e20), each named
##   text(<the NPC's NameStrID> + "_T") (c:0x568440), an id whose name is
##   empty skipped; eleven store slots (ids 21..31), each holding its NPC id
##   (+0x374, c:0x567fe0); a click selects one (c:0x569430);
## - Refresh (41) sends 0x74D4 {the selected slot's NPC id}, empties the
##   quotation list and is disabled for 5000 ms (timer 10, c:0x569dd0; the
##   re-enable on the timer is INFERRED);
## - 0xB4D4's rows (c:0x88e210): each a quotation slot (51..61) with the
##   good's name (11), the trade centre that SELLS the good (12, the good's
##   origin NPC set by c:0x9413f0) and `%d%%` (13).
## OURS: the two lists scroll with HudChat's bar, sized to the authored
## scroll controls (35, 36); the frame is the shell's, its caption at the
## shell's place.

const SIZE := Vector2(638, 388)
const LAYOUT := "resinfo\\iftradeinfo.txt"
const SLOT_LAYOUT := "resinfo\\iftradeinfoquotationslot.txt"
const STORE_SLOTS := 11
const QUOTE_SLOTS := 11
const REFRESH_LOCK_MS := 5000
const SELECTED := Color(1.0, 0.85, 0.4)

signal refresh_requested(npc_ref: int)

var stores: Array = []   # [{ref, name}]
var rows: Array = []     # [{item, percent}]
var selected := -1
var store_scroll := 0
var quote_scroll := 0
var _item_name: Callable
var _origin_name: Callable
var _store_nodes: Array[Control] = []
var _quote_holders: Array = []
var _refresh_btn: BaseButton
var _store_bar: HudChat.ChatScroll
var _quote_bar: HudChat.ChatScroll

## npcs: specialnpcdata's ids; store_name(ref) the store's name ("" skips
## it); item_name(item) / origin(item) a quotation row's first two cells.
func build_info(builder: UiBuilder, npcs: Array, store_name: Callable, item_name: Callable, origin: Callable) -> bool:
	name = "TradeInfo"
	frame_ddj = "interface\\frame\\mframe_wnd_"
	_item_name = item_name
	_origin_name = origin
	stores = store_list(npcs, store_name)
	if not build_shell(builder, SIZE, "UIIT_PAG_SPECIAL_PRICE_CONDITION_INFO", "Trade Export Details", LAYOUT):
		return false
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(LAYOUT)
	_layout = layout
	if layout != null and layout.sections.has("SlotList"):
		var list := builder.build_section(layout, "SlotList")
		if list != null:
			root.add_child(list)
			UiBuilder.settle_authored_rects(list)
	# The column heads are CIFBarWnds on an 8-slice bar, which the builder
	# draws as a frame: their authored Text goes on as the static's caption
	# would (SetText's label in the ClientRect, the def's alignment).
	for head in ["GDR_TRADEINFO_STORE_NAME", "GDR_TRADEINFO_SPECIALTY_NAME", "GDR_TRADEINFO_STORE_NAME_SELL",
			"GDR_TRADEINFO_STORE_CONDITION"]:
		var d := _def(head)
		if d != null:
			_caption(head, text(d.text, d.text))
	# The two "L" statics over the scroll columns are the layout's
	# placeholders (gil_shape.ddj); their letter is not drawn (INFERRED: the
	# window sets no text on them and the original shows none).
	for dummy in ["GDR_TRADEINFO_SLOT_DUMMY", "GDR_TRADEINFO_STORE_NAME_DUMMY"]:
		var dn := _find(dummy)
		if dn != null:
			builder.set_static_text(dn, "")
	for i in STORE_SLOTS:
		var n := _find("GDR_TRADEINFO_STORE_NAME_SLOT_%02d" % i)
		_store_nodes.append(n)
		if n != null:
			n.mouse_filter = Control.MOUSE_FILTER_STOP
			var at := i
			n.gui_input.connect(func(ev: InputEvent) -> void: _on_store_input(ev, at))
	var slot_layout: UiLayoutParser.LayoutDef = builder.load_layout(SLOT_LAYOUT)
	for i in QUOTE_SLOTS:
		var n := _find("GDR_TRADEINFO_QUOTATION_SLOT_%02d" % i)
		var holder: Control = null
		if n != null:
			# The slot is authored 133 wide and its own layout 371 (the bar
			# GDR_TRADEINFO_SLOT and the three cells out to x 366): the row
			# draws past its rect, unclipped (MEASURED, the two files).
			n.clip_contents = false
		if n != null and slot_layout != null:
			holder = builder.build_section(slot_layout, "Create")
			if holder != null:
				holder.name = "QuoteSlot"
				n.add_child(holder)
				UiBuilder.settle_authored_rects(holder)
		_quote_holders.append(holder)
	_refresh_btn = _find("GDR_TRADEINFO_UPDATE_BTN") as BaseButton
	if _refresh_btn != null:
		_refresh_btn.pressed.connect(press_refresh)
	_store_bar = _build_bar("GDR_TRADEINFO_STORE_NAME_SCROLL", func(p: int) -> void:
		store_scroll = p
		_paint_stores())
	_quote_bar = _build_bar("GDR_TRADEINFO_QUOTATION_SCROLL", func(p: int) -> void:
		quote_scroll = p
		_paint_quotes())
	_paint_stores()
	_paint_quotes()
	return true

var _layout: UiLayoutParser.LayoutDef

## A control anywhere under the window (the SlotList section's rows sit one
## level down).
func _find(control_name: String) -> Control:
	return root.find_child(control_name, true, false) as Control if root != null else null

func _def(control_name: String) -> UiLayoutParser.ControlDef:
	if _layout == null:
		return null
	for sec_name in _layout.sections:
		var sec: UiLayoutParser.SectionDef = _layout.sections[sec_name]
		if sec.control_by_name.has(control_name):
			return sec.control_by_name[control_name]
	return null

## Text on a control the builder drew as art only (a slice-base bar or a
## slot): a caption label made from its own def, as a static's.
func _caption(control_name: String, value: String) -> void:
	var n := _find(control_name)
	if n == null or _builder == null:
		return
	var label := n.get_node_or_null("Text") as Label
	if label == null:
		var d := _def(control_name)
		if d == null:
			return
		label = _builder._make_text_label(d)
		label.name = "Text"
		n.add_child(label)
		_builder._lay_caption(n, label)
	label.text = value

## The store list from the NPC ids: the named ones, in the file's order.
static func store_list(npcs: Array, store_name: Callable) -> Array:
	var out: Array = []
	for ref in npcs:
		var n := String(store_name.call(int(ref))) if store_name.is_valid() else ""
		if n != "":
			out.append({"ref": int(ref), "name": n})
	return out

func _build_bar(host_name: String, on_move: Callable) -> HudChat.ChatScroll:
	var host := _find(host_name)
	if host == null:
		return null
	var bar := HudChat.ChatScroll.new()
	if _builder != null:
		bar.up_texture = _builder.load_texture(HudChat.ARROW_UP_DDJ)
		bar.down_texture = _builder.load_texture(HudChat.ARROW_DOWN_DDJ)
		bar.bar_texture = _builder.load_texture(HudChat.SCROLL_BAR_DDJ)
		bar.thumb_texture = _builder.load_texture(HudChat.SCROLL_THUMB_DDJ)
	bar.length = maxf(16.0, host.size.y - 48.0)
	bar.size = Vector2(16, host.size.y)
	bar.moved.connect(on_move)
	host.add_child(bar)
	return bar

func _on_store_input(ev: InputEvent, i: int) -> void:
	var mb := ev as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		store_scroll = clampi(store_scroll + (-1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1), 0,
			maxi(0, stores.size() - STORE_SLOTS))
		_paint_stores()
		return
	if mb.button_index == MOUSE_BUTTON_LEFT:
		select(store_scroll + i)

func select(index: int) -> void:
	if index < 0 or index >= stores.size():
		return
	selected = index
	_paint_stores()

## Refresh: the selected store's quotations asked for (0x74D4), the list
## emptied, the button locked 5 s.
func press_refresh() -> void:
	if selected < 0 or selected >= stores.size():
		return
	rows = []
	quote_scroll = 0
	_paint_quotes()
	refresh_requested.emit(int(stores[selected]["ref"]))
	if _refresh_btn != null:
		_refresh_btn.disabled = true
		if is_inside_tree():
			get_tree().create_timer(REFRESH_LOCK_MS / 1000.0).timeout.connect(func() -> void:
				if is_instance_valid(_refresh_btn):
					_refresh_btn.disabled = false)

## 0xB4D4's rows.
func set_rows(r: Array) -> void:
	rows = r
	quote_scroll = 0
	_paint_quotes()

func _paint_stores() -> void:
	for i in _store_nodes.size():
		var n := _store_nodes[i]
		if n == null:
			continue
		var idx := store_scroll + i
		_caption(n.name, String(stores[idx]["name"]) if idx < stores.size() else "")
		n.modulate = SELECTED if idx == selected else Color.WHITE
	if _store_bar != null:
		_store_bar.set_range(maxi(0, stores.size() - STORE_SLOTS), store_scroll)

func _paint_quotes() -> void:
	for i in _quote_holders.size():
		var holder: Control = _quote_holders[i]
		if holder == null:
			continue
		var cells := quote_cells(rows[quote_scroll + i] if quote_scroll + i < rows.size() else {}, _item_name, _origin_name)
		for k in cells:
			var n := holder.get_node_or_null(String(k))
			if n != null and _builder != null:
				_builder.set_static_text(n, String(cells[k]))
	if _quote_bar != null:
		_quote_bar.set_range(maxi(0, rows.size() - QUOTE_SLOTS), quote_scroll)

## One quotation row's cells (c:0x568080): "" everywhere for an empty row.
static func quote_cells(row: Dictionary, item_name: Callable, origin: Callable) -> Dictionary:
	var out := {"GDR_TRADEINFO_SLOT_SPECIALTY_NAME": "", "GDR_TRADEINFO_SLOT_STORE_NAME_SELL": "",
		"GDR_TRADEINFO_SLOT_STORE_CONDITION": ""}
	if row.is_empty():
		return out
	var item := int(row.get("item", 0))
	out["GDR_TRADEINFO_SLOT_SPECIALTY_NAME"] = String(item_name.call(item)) if item_name.is_valid() else str(item)
	out["GDR_TRADEINFO_SLOT_STORE_NAME_SELL"] = String(origin.call(item)) if origin.is_valid() else ""
	out["GDR_TRADEINFO_SLOT_STORE_CONDITION"] = "%d%%" % int(row.get("percent", 0))
	return out
