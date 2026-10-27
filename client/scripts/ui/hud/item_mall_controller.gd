extends RefCounted
class_name ItemMallController

## Round 837: CIFNewItemMall over HudPanels' "itemmall" window (GDR_RENEWAL_
## ITEM_MALL, ID 167, 800x600, resinfo\ifnewitemmall.txt with its MyInfo
## section). The specs are docs/protocol/item_mall.md (the window), item_mall_
## wire.md (the messages) and item_mall_data.md (the tables), each with its
## verify file and a "Corrections from the review" section that wins over its
## body. c: client addresses, READ unless marked.
##
## The left menu and the goods are one control in retail (CIFNewItemMallShopSlot,
## ID 105 at 13,72, 551x513, holding a CIFVScrollColumnView ID 301 at 5,3,541,
## 507 with a 124-wide menu column and a 424-wide goods column; W9). It is
## code-built there, so it is code-built here; its numbers below are READ
## where the code gives them and MEASURED from the user's screenshots
## (IBcFopf / u0s3YNP, exactly 2x: window origin from MAIN PAGE's art at
## 18,45) where it does not:
##   - menu rows 116x32 (READ, ifnewitemmallshopmainslot.txt) from 18,76,
##     sub-tabs 116x23 (READ) under their row;
##   - goods: a section bar mall_menu_bar.ddj (420x20) at x 137, its cells
##     199x81 (READ, created 199x81 at 0x7e4f1d) two per row at x 142 / 341
##     (pitch 199) and y bar+20, pitch 81 (MEASURED);
##   - the scroll lane at x 545: up 16x20 at y 73, down at y 567, the thumb
##     12x28 between (MEASURED; the art READ at 0x7e5f53).
## Whether the scroll bar moves the menu too is OPEN; the screenshots show
## it beside the goods only, so only the goods scroll here.

const WINDOW := "itemmall"
const LAYOUT := "resinfo\\ifnewitemmall.txt"
## Font colour of a selected sub-tab (0x7e6140): yellow and bold.
const SUB_SELECTED := Color(1, 1, 0)
const SECTION_BAR := "interface\\mall\\mall_menu_bar.ddj"
const CELL_BG := "interface\\mall\\mall_item_wnd.ddj"
const CELL_BG_FOCUS := "interface\\mall\\mall_item_wnd_focus.ddj"
const ROW_ART_ON := "interface\\mall\\mall_item_tab_on.ddj"
const SCROLL_UP := "interface\\mall\\mall_scroll_up.ddj"
const SCROLL_DOWN := "interface\\mall\\mall_scroll_down.ddj"
const SCROLL_THUMB := "interface\\mall\\mall_scroll_bar.ddj"
## The badges by SaleTag bit (c:0x7dec60; the file names do not match the
## letters, the review's W8 has the space in the last name).
const BADGES := {1: "interface\\mall\\mall_icon_new.ddj", 2: "interface\\mall\\mall_icon_limited.ddj",
	4: "interface\\mall\\mall_icon_sale.ddj", 8: "interface\\mall\\mall_icon_popular.ddj",
	16: "interface\\mall\\mall_icon_recommendation .ddj", 32: "interface\\mall\\mall_icon_recommendation .ddj"}
## The HOT shop's sub-entries: the five lists with their hard-coded headings
## (c:0x7e5e13..0x7e5e5b), each made when its list has a good (0x7e38f0).
const HOT_LISTS := [[1, "UIIT_STT_SILKMALL_UPDATE_ITEM"], [2, "UIIT_STT_SILKMALL_BESTSELLER_ITEM"],
	[4, "UIIT_STT_SILKMALL_SALE_ITEM"], [8, "UILM_STT_DIVISION_RECOMMENDATION"],
	[16, "UIIT_STT_SILKMALL_POPUP_ADVERTISING"]]
const HOT_KEY := "UIIT_STT_SILKMALL_HOT_STORE"
const RESERVE_KEY := "UIIT_STT_SILKMALL_SHOPPING_BASKET_LIST"

# Layout (window-local; see the class comment).
const MENU_ORIGIN := Vector2(18, 76)
const ROW_SIZE := Vector2(116, 32)
const SUB_SIZE := Vector2(116, 23)
const GOODS_CLIP := Rect2(137, 75, 408, 507)
const CELL_X := [5.0, 204.0]
const CELL_SIZE := Vector2(199, 81)
const BAR_HEIGHT := 20.0
const SCROLL_X := 545.0
const SCROLL_UP_Y := 73.0
const SCROLL_DOWN_Y := 567.0
const SCROLL_ARROW := Vector2(16, 20)
const SCROLL_THUMB_SIZE := Vector2(12, 28)
## The cell menu opens at the cell's position + (132, 56) (0x7deb80).
const POPUP_OFFSET := Vector2(132, 56)

var panels
var net = null
var data: MallData
var preview = null                  # MallPreview, when World3D gives one
var active := false
## +0x7c8, a mall box is up; +0x7dc, purchases waiting for a reply.
var busy := false
var dealing := 0
## The reserve list (player +0x4b8, kept by the client: Good objects).
var reserve: Array = []
## The try-on's buy list (+0x81c): goods, one per first-item packed TID.
var buy_list: Array = []
## A lump buy in progress (+0x7e8): the goods still to send.
var lump: Array = []

var _window: HudWindow
var _menu: Control
var _goods_clip: Control
var _goods: Control
var _scroll_y := 0.0
var _thumb: TextureRect
var _rows: Array = []               # {"row": MenuRow, "node", "subs": [{"node", "kind", ...}], "open"}
var _view := {}                     # the shown view: {"kind", "goods" or "sections"}
var _popup: Control
var _popup_cell: Control
var _cells: Array = []
var _name_cache := {}

func _init(hud_panels) -> void:
	panels = hud_panels

## A box is up (+0x7c8): one of the mall's, or the Buying list, which sets
## the same byte while it is open (W13, item_mall_verify "The rest").
func blocked() -> bool:
	return busy or (panels.has_method("silk_history_open") and panels.silk_history_open())

func _net():
	if net != null:
		return net
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("/root/NetClient") if tree != null else null

# --- opening -----------------------------------------------------------------

## 0x79b580(1): the window built afresh (retail loads and unloads its section
## on each open and close, so the try-on and the views start new).
func open() -> HudWindow:
	if active:
		return _window
	if data == null:
		data = load_data()
	panels.drop_item_mall_window()
	_window = panels.open(WINDOW)
	if _window == null:
		return null
	active = true
	busy = false
	dealing = 0
	buy_list = []
	lump = []
	_install()
	return _window

## The X / Esc / F10 (when open: not in retail, F10 never closes, the review)
## -> 0x79b580(0). Refused while a box is up or a purchase is out (vslot_043
## 0x7d7020); a pending history inquiry is cancelled ({1, 0xff}).
func close(forced := false) -> bool:
	if not active:
		return true
	if not forced and (blocked() or dealing > 0):
		return false
	active = false
	if panels.has_method("close_silk_history"):
		panels.close_silk_history()
	panels.drop_item_mall_window()
	_window = null
	preview = null
	return true

func load_data() -> MallData:
	var archive = panels._builder.media_archive() if panels._builder != null else null
	var d := MallData.new()
	if archive == null:
		return d
	return d.load(func(path: String) -> PackedByteArray:
		var e = ObjectLoader.find_file(archive, path)
		return archive.read_file(e) if e != null else PackedByteArray())

func _install() -> void:
	var w := _window
	w.close_hides = false
	if not w.closed.is_connected(_on_x):
		w.closed.connect(_on_x)
	_wire_buttons()
	_install_myinfo()
	_install_popup()
	_build_shop_slot()
	_install_preview()
	_event_popup()
	show_main_page()

func _on_x() -> void:
	close()

func node(control_name: String) -> Control:
	return _window.node(control_name) as Control if _window != null else null

func _wire_buttons() -> void:
	var wiring := {
		"GDR_RENEWAL_ITEM_MALL_MAIN_BTN": func() -> void: show_main_page(),
		"GDR_RENEWAL_ITEM_MALL_SEARCH_BTN": func() -> void: search(_search_text()),
		"GDR_RENEWAL_ITEM_MALL_RIGHT_BTN02": func() -> void: press_original(),
		"GDR_RENEWAL_ITEM_MALL_RIGHT_BTN01": func() -> void: press_buy_worn(),
		"GDR_RENEWAL_ITEM_MALL_RIGHT_SILKBUYLIST_BTN03": func() -> void: press_buying_list(),
		"GDR_RENEWAL_ITEM_MALL_RIGHT_EVENT_POPUP_BTN": func() -> void: _event_off(),
	}
	for n in wiring:
		var b := node(n) as BaseButton
		if b != null:
			b.pressed.connect(wiring[n])
	# 0x7d6f50(0): the Obtained list is not loaded and its button disabled.
	var recv := node("GDR_RENEWAL_ITEM_MALL_RIGHT_SILKRECIEVELIST_BTN04") as BaseButton
	if recv != null:
		recv.disabled = true
	var edit := node("GDR_RENEWAL_ITEM_MALL_SEARCH") as LineEdit
	if edit != null:
		# 0x7d7650: Enter in the edit searches.
		edit.text_submitted.connect(func(t: String) -> void: search(t))
		edit.placeholder_text = panels._resolve_ui("UIIT_STT_SILKMALL_SEARCH_DEFAULT", "Write Item name")
		if edit.text == edit.placeholder_text:
			edit.text = ""

func _search_text() -> String:
	var edit := node("GDR_RENEWAL_ITEM_MALL_SEARCH") as LineEdit
	return edit.text if edit != null else ""

# --- the info block (CIFNewItemMallMyInfo, Create 0x7dd710) ------------------

var _myinfo: Control

func _install_myinfo() -> void:
	var holder := node("GDR_ITEM_MALL_MYINFO")
	if holder == null or panels._builder == null:
		return
	var layout = panels._builder.load_layout("resinfo\\ifnewitemmallmyinfo.txt")
	if layout == null:
		return
	_myinfo = panels._builder.build_section(layout, "Create")
	if _myinfo == null:
		return
	_myinfo.name = "MyInfo"
	holder.add_child(_myinfo)
	UiBuilder.settle_authored_rects(_myinfo)
	var money := _myinfo.find_child("GDR_ITEM_MALL_MYINFO_MONEY_SIGN", true, false) as CanvasItem
	if money != null:
		money.visible = false   # 213 always hidden
	for pair in [["GDR_ITEM_MALL_MYINFO_BUY_SILK_BTN", "UIIT_STT_SILKMALL_BUY_SILK_LINK"],
			["GDR_ITEM_MALL_MYINFO_COUPON_EXCHANGE_BTN", "UIIT_STT_SILKMALL_COUPON_EXCHANGE_LINK"]]:
		var b := _myinfo.find_child(pair[0], true, false) as BaseButton
		if b == null:
			continue
		var link: String = panels._resolve_ui(pair[1], "")
		# 0x7dd89d / 0x7dd8bd: a link shorter than 5 characters disables it.
		b.disabled = link.length() < 5
		b.pressed.connect(func() -> void: _open_link(link))
	refresh_info()

## Buy Silk / Coupon: ShellExecuteW("open", "IEXPLORE.EXE", "http://" + text)
## (READ); here the system's own browser (OURS: no Internet Explorer).
func _open_link(link: String) -> void:
	if link.length() >= 5:
		OS.shell_open("http://" + link)

## 0x7dd3a0, polled each tick in retail (vslot_012); here on 0x3153 and open.
func refresh_info() -> void:
	if _myinfo == null:
		return
	var n = _net()
	var silk: Array = n.silk_balances if n != null and "silk_balances" in n else [0, 0, 0]
	_set_text("GDR_ITEM_MALL_MYINFO_NAME", String(panels.mall_player_name()))
	_set_text("GDR_ITEM_MALL_MYINFO_LEVEL", "Lv %d" % int(panels.mall_player_level()))
	_set_text("GDR_ITEM_MALL_MYINFO_SILK", "%d" % int(silk[0]))
	_set_text("GDR_ITEM_MALL_MYINFO_GIFT_SILK", "%d" % int(silk[1]))
	_set_text("GDR_ITEM_MALL_MYINFO_POINT", "%d" % int(silk[2]))

func _set_text(control_name: String, text: String) -> void:
	var c := _myinfo.find_child(control_name, true, false) as Control if _myinfo != null else null
	if c != null and panels._builder != null:
		panels._builder.set_static_text(c, text)

# --- the event picture (0x7d76e0) --------------------------------------------

func _event_popup() -> void:
	var pic := node("GDR_RENEWAL_ITEM_MALL_RIGHT_EVENT_POPUP")
	var off := node("GDR_RENEWAL_ITEM_MALL_RIGHT_EVENT_POPUP_BTN")
	var ev := read_notify()
	var on := bool(ev.get("open", false))
	if pic != null:
		pic.visible = on
		if on and pic is TextureRect and panels._builder != null:
			(pic as TextureRect).texture = panels._builder.load_texture(String(ev.get("front", "")))
	if off != null:
		off.visible = on
	_set_preview_visible(not on)

func _event_off() -> void:
	var pic := node("GDR_RENEWAL_ITEM_MALL_RIGHT_EVENT_POPUP")
	var off := node("GDR_RENEWAL_ITEM_MALL_RIGHT_EVENT_POPUP_BTN")
	if pic != null:
		pic.visible = false
	if off != null:
		off.visible = false
	_set_preview_visible(true)

## event\mall_notify.txt: Mall_Open, Mall_BeginTime, Mall_EndTime,
## Mall_FrontImg (READ 0x7d76e0). The dates' format is not read; an open
## event with dates this client cannot read is shown (INFERRED).
func read_notify() -> Dictionary:
	var archive = panels._builder.media_archive() if panels._builder != null else null
	if archive == null:
		return {}
	var e = ObjectLoader.find_file(archive, "event\\mall_notify.txt")
	if e == null:
		return {}
	var raw: PackedByteArray = archive.read_file(e)
	var text := TextDecode.utf16(raw.slice(2)) if raw.size() >= 2 and raw[0] == 0xff and raw[1] == 0xfe else raw.get_string_from_utf8()
	var out := {}
	for line in text.replace("\r", "").split("\n"):
		var parts := line.strip_edges().split(" ", false, 1)
		if parts.size() < 2:
			continue
		var v := parts[1].strip_edges().trim_prefix("\"").trim_suffix("\"")
		match parts[0]:
			"Mall_Open":
				out["open"] = v == "1"
			"Mall_FrontImg":
				out["front"] = v
	return out

# --- the cell menu (CIFNewItemSlotPopupWnd, control 100) ---------------------

func _install_popup() -> void:
	_popup = node("GDR_RENEWAL_ITEM_MALL_POPUP_MENU")
	if _popup == null or panels._builder == null:
		return
	var layout = panels._builder.load_layout("resinfo\\ifnewitemslotpopupwnd.txt")
	if layout != null:
		var root: Control = panels._builder.build_section(layout, "Create")
		if root != null:
			root.name = "PopupItems"
			_popup.add_child(root)
			UiBuilder.settle_authored_rects(root)
	var map := {"GDR_RENEWAL_BTN01": func() -> void: _menu_wear(),
		"GDR_RENEWAL_BTN02": func() -> void: _menu_buy(),
		"GDR_RENEWAL_BTN03": func() -> void: _menu_detail(),
		"GDR_RENEWAL_BTN04": func() -> void: _menu_reserve()}
	for n in map:
		var b := _popup.find_child(n, true, false) as BaseButton
		if b != null:
			b.pressed.connect(map[n])
	_popup.visible = false
	_popup.mouse_filter = Control.MOUSE_FILTER_STOP

## 0x7deb80: the menu opens for a hovered cell when no list window is up
## (+0x7c4, W13).
func _hover_cell(cell: Control) -> void:
	if _popup == null or not active:
		return
	if panels.has_method("silk_history_open") and panels.silk_history_open():
		return
	if _popup_cell != null and is_instance_valid(_popup_cell) and _popup_cell != cell:
		_cell_focus(_popup_cell, false)
	_popup_cell = cell
	var at: Vector2 = cell.get_global_rect().position - _window.get_global_rect().position
	_popup.position = (at + POPUP_OFFSET) / _window_scale()
	_popup.visible = true
	_popup.move_to_front()
	_cell_focus(cell, true)
	var good: MallData.Good = cell.get_meta("good")
	var pkg := good.package
	var in_reserve: bool = _view.get("kind", "") == "reserve"
	_menu_enable("GDR_RENEWAL_BTN01", can_wear_good(good) and not pkg.is_bundle())
	_menu_enable("GDR_RENEWAL_BTN02", true)
	_menu_enable("GDR_RENEWAL_BTN03", pkg.is_bundle())
	_menu_enable("GDR_RENEWAL_BTN04", true)
	var b4 := _popup.find_child("GDR_RENEWAL_BTN04", true, false) as Control
	if b4 != null and panels._builder != null:
		panels._builder.set_button_text(b4, panels._resolve_ui(
			"UIIT_STT_SILKMALL_DEL" if in_reserve else "UIIT_STT_SILKMALL_DO_ZZIM", "Delete" if in_reserve else "Pre-select"))

func _window_scale() -> float:
	return _window.get_global_transform().get_scale().x if _window != null else 1.0

func _menu_enable(control_name: String, on: bool) -> void:
	var b := _popup.find_child(control_name, true, false) as BaseButton
	if b != null:
		b.disabled = not on

## CIFNewItemSlotPopupWnd::vslot_012 (0x7e6790): closes once the pointer is
## outside both the menu and its cell.
func tick() -> void:
	if _popup == null or not _popup.visible:
		return
	var mouse := _popup.get_global_mouse_position()
	var inside := _popup.get_global_rect().has_point(mouse)
	if _popup_cell != null and is_instance_valid(_popup_cell):
		inside = inside or _popup_cell.get_global_rect().has_point(mouse)
	if not inside:
		hide_popup()

func hide_popup() -> void:
	if _popup != null:
		_popup.visible = false
	if _popup_cell != null and is_instance_valid(_popup_cell):
		_cell_focus(_popup_cell, false)
	_popup_cell = null

func _cell_focus(cell: Control, on: bool) -> void:
	var bg := cell.get_node_or_null("Bg") as TextureRect
	if bg != null and panels._builder != null:
		bg.texture = panels._builder.load_texture(CELL_BG_FOCUS if on else CELL_BG)

func _popup_good() -> MallData.Good:
	return _popup_cell.get_meta("good") if _popup_cell != null and is_instance_valid(_popup_cell) else null

func _menu_wear() -> void:
	var g := _popup_good()
	hide_popup()
	if g != null:
		wear(g)

func _menu_buy() -> void:
	var g := _popup_good()
	hide_popup()
	if g != null:
		open_buy_box(g)

func _menu_detail() -> void:
	hide_popup()

func _menu_reserve() -> void:
	var g := _popup_good()
	var in_reserve: bool = _view.get("kind", "") == "reserve"
	hide_popup()
	if g == null or blocked():
		return
	panels.open_mall_reserve_box(g, not in_reserve)

# --- the menu column and the goods views --------------------------------------

func _build_shop_slot() -> void:
	var root := _window.panel_root
	_menu = Control.new()
	_menu.name = "MallMenu"
	_menu.position = MENU_ORIGIN
	_menu.size = Vector2(ROW_SIZE.x, 507)
	_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_menu)
	_goods_clip = Control.new()
	_goods_clip.name = "MallGoods"
	_goods_clip.position = GOODS_CLIP.position
	_goods_clip.size = GOODS_CLIP.size
	_goods_clip.clip_contents = true
	_goods_clip.mouse_filter = Control.MOUSE_FILTER_PASS
	_goods_clip.gui_input.connect(_on_goods_input)
	root.add_child(_goods_clip)
	_goods = Control.new()
	_goods.name = "Content"
	_goods.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_goods_clip.add_child(_goods)
	_build_scroll(root)
	_build_rows()
	var popup := node("GDR_RENEWAL_ITEM_MALL_POPUP_MENU")
	if popup != null:
		popup.move_to_front()

func _build_scroll(root: Control) -> void:
	var b = panels._builder
	var up := TextureButton.new()
	up.name = "MallScrollUp"
	up.texture_normal = b.load_texture(SCROLL_UP) if b != null else null
	up.ignore_texture_size = true
	up.stretch_mode = TextureButton.STRETCH_SCALE
	up.position = Vector2(SCROLL_X, SCROLL_UP_Y)
	up.size = SCROLL_ARROW
	up.pressed.connect(func() -> void: scroll_by(-CELL_SIZE.y))
	root.add_child(up)
	var down := TextureButton.new()
	down.name = "MallScrollDown"
	down.texture_normal = b.load_texture(SCROLL_DOWN) if b != null else null
	down.ignore_texture_size = true
	down.stretch_mode = TextureButton.STRETCH_SCALE
	down.position = Vector2(SCROLL_X, SCROLL_DOWN_Y)
	down.size = SCROLL_ARROW
	down.pressed.connect(func() -> void: scroll_by(CELL_SIZE.y))
	root.add_child(down)
	_thumb = TextureRect.new()
	_thumb.name = "MallScrollThumb"
	_thumb.texture = b.load_texture(SCROLL_THUMB) if b != null else null
	_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_thumb.size = SCROLL_THUMB_SIZE
	_thumb.mouse_filter = Control.MOUSE_FILTER_STOP
	_thumb.gui_input.connect(_on_thumb_input)
	root.add_child(_thumb)
	_place_thumb()

func _content_height() -> float:
	return _goods.size.y if _goods != null else 0.0

func _max_scroll() -> float:
	return maxf(_content_height() - GOODS_CLIP.size.y, 0.0)

func scroll_by(dy: float) -> void:
	scroll_to(_scroll_y + dy)

func scroll_to(y: float) -> void:
	_scroll_y = clampf(y, 0.0, _max_scroll())
	if _goods != null:
		_goods.position.y = -_scroll_y
	_place_thumb()
	if _popup != null and _popup.visible:
		hide_popup()

func _place_thumb() -> void:
	if _thumb == null:
		return
	var top := SCROLL_UP_Y + SCROLL_ARROW.y
	var span := SCROLL_DOWN_Y - top - SCROLL_THUMB_SIZE.y
	var f := _scroll_y / _max_scroll() if _max_scroll() > 0.0 else 0.0
	_thumb.position = Vector2(SCROLL_X, top + span * f)

var _thumb_drag := false

func _on_thumb_input(e: InputEvent) -> void:
	var mb := e as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		_thumb_drag = mb.pressed
		return
	var mm := e as InputEventMouseMotion
	if mm != null and _thumb_drag:
		var top := SCROLL_UP_Y + SCROLL_ARROW.y
		var span := SCROLL_DOWN_Y - top - SCROLL_THUMB_SIZE.y
		if span > 0.0:
			scroll_by(mm.relative.y / _window_scale() / span * _max_scroll())

func _on_goods_input(e: InputEvent) -> void:
	var mb := e as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		scroll_by(-CELL_SIZE.y)
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		scroll_by(CELL_SIZE.y)

## The rows (ShopSlot 0x7e5160): every row MallData.visible_menu keeps; a shop
## row's sub-tabs are its first tab group's tabs that show a good (2b); the
## HOT shop's are its lists (0x7e38f0); Reserved's are Buy All and Empty
## (0x7e13b0).
func _build_rows() -> void:
	_rows = []
	for m in data.visible_menu():
		var row: MallData.MenuRow = m
		var r := {"row": row, "subs": [], "open": false}
		r["node"] = _make_row(row, r)
		if row.text_key == HOT_KEY:
			for pair in HOT_LISTS:
				var list := data.goods_with_tag(int(pair[0]))
				if not list.is_empty():
					r["subs"].append({"kind": "list", "title": pair[1], "goods": list})
		elif row.text_key == RESERVE_KEY:
			r["subs"].append({"kind": "lump", "title": "UIIT_STT_SILKMALL_ZZIM_LUMP_BUY"})
			r["subs"].append({"kind": "empty", "title": "UIIT_CTL_SILKMALL_DELETE_BASKET_ALL"})
		elif data.shops.has(row.code):
			for t in (data.shops[row.code] as MallData.Shop).tabs:
				var tab: MallData.Tab = t
				if not tab.goods.is_empty():
					r["subs"].append({"kind": "tab", "title": tab.name_strid, "goods": tab.goods})
		for s in r["subs"]:
			s["node"] = _make_sub(s, r)
		_rows.append(r)
	_layout_rows()

func _make_row(row: MallData.MenuRow, r: Dictionary) -> Control:
	var b = panels._builder
	var c := Control.new()
	c.name = "Row%d" % row.key
	c.size = ROW_SIZE
	c.mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := TextureRect.new()
	bg.name = "Bg"
	bg.texture = b.load_texture(row.art) if b != null and row.art != "" else null
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.size = ROW_SIZE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(bg)
	if b != null:
		var layout = b.load_layout("resinfo\\ifnewitemmallshopmainslot.txt")
		var inner: Control = b.build_section(layout, "Create") if layout != null else null
		if inner != null:
			c.add_child(inner)
			UiBuilder.settle_authored_rects(inner)
			var icon := inner.find_child("GDR_RENEWAL_ITEM_MALL_SHOP_SLOT_ICON", true, false) as Control
			if icon is TextureRect:
				(icon as TextureRect).texture = b.load_texture(row.icon)
			elif icon != null and row.icon != "":
				var t := TextureRect.new()
				t.texture = b.load_texture(row.icon)
				t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				t.size = Vector2(20, 20)
				t.mouse_filter = Control.MOUSE_FILTER_IGNORE
				icon.add_child(t)
			var title := inner.find_child("GDR_RENEWAL_ITEM_MALL_SHOP_SLOT_TITLE", true, false) as Control
			b.set_static_text(title, panels._resolve_ui(row.text_key, row.text_key))
	c.gui_input.connect(func(e: InputEvent) -> void:
		var mb := e as InputEventMouseButton
		# 0x7df8d0: the row acts on the left release.
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			click_row(r))
	_menu.add_child(c)
	return c

func _make_sub(s: Dictionary, r: Dictionary) -> Control:
	var b = panels._builder
	var c := Control.new()
	c.size = SUB_SIZE
	c.visible = false
	c.mouse_filter = Control.MOUSE_FILTER_STOP
	var label := Label.new()
	label.name = "Title"
	label.position = Vector2(43, 5)
	label.size = Vector2(93, 15)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if b != null:
		label.add_theme_font_override("font", b.font_at(0))
		label.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	# A tab's name key is the UI table's (UIIT_STT_SILKMALL_*) or the
	# object table's (SN_TAB_*), as the client's single text map holds both.
	label.text = _title(String(s["title"]))
	c.add_child(label)
	s["label"] = label
	c.gui_input.connect(func(e: InputEvent) -> void:
		var mb := e as InputEventMouseButton
		# 0x7e6260: a sub-tab acts on the left press.
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			click_sub(s, r))
	_menu.add_child(c)
	return c

func _layout_rows() -> void:
	var y := 0.0
	for r in _rows:
		var c: Control = r["node"]
		c.position = Vector2(0, y)
		y += ROW_SIZE.y
		var bg := c.get_node_or_null("Bg") as TextureRect
		if bg != null and panels._builder != null:
			bg.texture = panels._builder.load_texture(ROW_ART_ON if r["open"] else (r["row"] as MallData.MenuRow).art)
		for s in r["subs"]:
			var sc: Control = s["node"]
			sc.visible = r["open"]
			if r["open"]:
				sc.position = Vector2(0, y)
				y += SUB_SIZE.y

func _title(key: String) -> String:
	var t: String = panels._resolve_ui(key, "")
	if t == "":
		t = panels.mall_text(key)
	return t if t != "" else key

## 0x7e4660: open a closed row (the others close); a click on an open row
## collapses it. The goods column stays as it was, except Reserved, whose
## reserve view shows. Refused while a purchase is out (0x7df90a).
func click_row(r: Dictionary) -> void:
	if dealing > 0:
		return
	var was: bool = r["open"]
	for o in _rows:
		o["open"] = false
	r["open"] = not was
	_layout_rows()
	if r["open"] and (r["row"] as MallData.MenuRow).text_key == RESERVE_KEY:
		show_reserve()

## 0x7e4840: a sub-tab shows its view, yellow and bold; the others white.
func click_sub(s: Dictionary, r: Dictionary) -> void:
	if dealing > 0:
		return
	match String(s["kind"]):
		"lump":
			press_buy_all_reserved()
			return
		"empty":
			reserve = []
			if _view.get("kind", "") == "reserve":
				show_reserve()
			return
	for o in _rows:
		for os in o["subs"]:
			_sub_style(os, os == s)
	show_goods(s["goods"], "tab")

## Bold is the face's weight 600 drawn as the round 833 tabs and the notice
## banner draw it (HudNotice.bold_file, else one pixel to the right).
func _sub_style(s: Dictionary, selected: bool) -> void:
	var label := s.get("label") as Label
	if label == null or panels._builder == null:
		return
	var base: Font = panels._builder.font_at(0)
	label.remove_theme_color_override("font_shadow_color")
	label.remove_theme_constant_override("shadow_offset_x")
	label.remove_theme_constant_override("shadow_offset_y")
	label.add_theme_font_override("font", base)
	if not selected:
		label.remove_theme_color_override("font_color")
		return
	label.add_theme_color_override("font_color", SUB_SELECTED)
	var bold := HudNotice.bold_file(base)
	if bold != null:
		label.add_theme_font_override("font", bold)
		return
	label.add_theme_color_override("font_shadow_color", SUB_SELECTED)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 0)
	label.add_theme_constant_override("shadow_outline_size", 0)

## 0x7e3660 (MAIN PAGE, also the opening view): the menu collapses and the
## main page shows: one section per hot row in key order, each with its
## goods not shown in an earlier section (0x7e3c00, the +0x91c set).
func show_main_page() -> void:
	for o in _rows:
		o["open"] = false
		for os in o["subs"]:
			_sub_style(os, false)
	_layout_rows()
	var shown := {}
	var sections: Array = []
	for h in data.hot:
		var row: MallData.HotRow = h
		var list: Array = []
		for g in data.goods_with_tag(row.bit):
			var pid := (g as MallData.Good).package.id
			if shown.has(pid):
				continue
			shown[pid] = true
			list.append(g)
		if not list.is_empty():
			sections.append({"title": row.text_key, "goods": list})
	_show_sections(sections, "main")

func show_goods(goods: Array, kind: String) -> void:
	_show_sections([{"title": "", "goods": goods}], kind)

## The reserve view (0x7e3220).
func show_reserve() -> void:
	show_goods(reserve, "reserve")

## 0x7e32d0: non-empty text, every built good whose name contains it.
func search(text: String) -> void:
	if text.strip_edges() == "" or text == panels._resolve_ui("UIIT_STT_SILKMALL_SEARCH_DEFAULT", "Write Item name"):
		return
	for o in _rows:
		o["open"] = false
	_layout_rows()
	show_goods(data.search(text, func(p: MallData.Package) -> String: return package_name(p)), "search")

func _show_sections(sections: Array, kind: String) -> void:
	hide_popup()
	for c in _goods.get_children():
		_goods.remove_child(c)
		c.queue_free()
	_cells = []
	var y := 0.0
	for sec in sections:
		var title := String(sec["title"])
		if title != "":
			var bar := TextureRect.new()
			bar.texture = panels._builder.load_texture(SECTION_BAR) if panels._builder != null else null
			bar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			bar.position = Vector2(0, y)
			bar.size = Vector2(420, BAR_HEIGHT)
			bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var label := Label.new()
			label.text = _title(title)
			label.position = Vector2(14, 2)
			label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			if panels._builder != null:
				label.add_theme_font_override("font", panels._builder.font_at(0))
				label.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
			bar.add_child(label)
			_goods.add_child(bar)
			y += BAR_HEIGHT
		var goods: Array = sec["goods"]
		for i in goods.size():
			var cell := make_cell(goods[i])
			cell.position = Vector2(CELL_X[i % 2], y + floorf(i / 2.0) * CELL_SIZE.y)
			_goods.add_child(cell)
			_cells.append(cell)
		y += ceilf(goods.size() / 2.0) * CELL_SIZE.y
	_goods.size = Vector2(GOODS_CLIP.size.x, y)
	_view = {"kind": kind, "sections": sections}
	scroll_to(0.0)

# --- a goods cell (CIFNewItemMallShopItemSlot, 199x81) ------------------------

func make_cell(good: MallData.Good) -> Control:
	var b = panels._builder
	var pkg := good.package
	var cell := Control.new()
	cell.size = CELL_SIZE
	cell.set_meta("good", good)
	cell.mouse_filter = Control.MOUSE_FILTER_PASS
	var bg := TextureRect.new()
	bg.name = "Bg"
	bg.texture = b.load_texture(CELL_BG) if b != null else null
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.size = Vector2(200, 84)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(bg)
	if b != null:
		var layout = b.load_layout("resinfo\\ifnewitemmallshopitemslot.txt")
		if layout != null:
			var icon_root: Control = b.build_section(layout, "NewShopSlotIconForPackage")
			if icon_root != null:
				icon_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
				cell.add_child(icon_root)
				UiBuilder.settle_authored_rects(icon_root)
				var slot := icon_root.find_child("GDR_RENEWAL_SHOP_SLOT_ICON", true, false) as Control
				var icon := slot.get_node_or_null("ItemIcon") as TextureRect if slot != null else null
				if icon != null:
					icon.texture = package_icon(pkg)
					icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
				if slot != null:
					slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var root: Control = b.build_section(layout, "Create")
			if root != null:
				root.mouse_filter = Control.MOUSE_FILTER_IGNORE
				cell.add_child(root)
				UiBuilder.settle_authored_rects(root)
				_fill_cell(root, good)
	_badges(cell, pkg)
	cell.mouse_entered.connect(func() -> void: _hover_cell(cell))
	return cell

## 0x7df6c0 -> 0x7de530 / 0x7de0d0 / 0x7df1f0 / 0x7dec60.
func _fill_cell(root: Control, good: MallData.Good) -> void:
	var b = panels._builder
	var pkg := good.package
	var name_box := root.find_child("GDR_RENEWAL_ITEM_MALL_ITEM_NAME", true, false) as Control
	if name_box != null:
		var label := Label.new()
		label.name = "Text"
		label.text = package_name(pkg)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size = Vector2(130, 45)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_font_override("font", b.font_at(0))
		label.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		label.add_theme_constant_override("line_spacing", 0)
		name_box.add_child(label)
	var price := root.find_child("GDR_RENEWAL_ITEM_MALL_ITEM_SILK", true, false) as Control
	b.set_static_text(price, "%d" % pkg.silk_price())
	var sale := (pkg.sale_tag & MallData.TAG_SALE) != 0
	var arrow := root.find_child("GDR_RENEWAL_ITEM_MALL_ITEM_ARROW", true, false) as CanvasItem
	if arrow != null:
		arrow.visible = sale
	var old := root.find_child("GDR_RENEWAL_ITEM_MALL_ITEM_RE_SILK", true, false) as Control
	if old != null:
		old.visible = sale
		if sale:
			b.set_static_text(old, "%d" % int(pkg.previous.get(MallData.PAY_SILK, 0)))
	var count := root.find_child("GDR_RENEWAL_ITEM_MALL_ITEM_COUT", true, false) as Control
	b.set_static_text(count, unit_text(pkg))

## 0x7df1f0: " %d" + "Unit" -- the first scrap row's Data, 1 when 0 or a
## bundle (0x7df35e).
func unit_text(pkg: MallData.Package) -> String:
	var n := 1
	if not pkg.is_bundle() and not pkg.scraps.is_empty():
		n = maxi((pkg.scraps[0] as MallData.Scrap).data, 1)
	return " %d%s" % [n, panels._resolve_ui("UIIT_STT_UNIT", "Unit")]

## 0x7dec60: a badge per SaleTag bit, left to right, x 9 + 13n, y 60, 12x12.
func _badges(cell: Control, pkg: MallData.Package) -> void:
	var n := 0
	for bit in [1, 2, 4, 8, 16, 32]:
		if pkg.sale_tag & bit:
			var t := TextureRect.new()
			t.texture = panels._builder.load_texture(BADGES[bit]) if panels._builder != null else null
			t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			t.position = Vector2(9 + 13 * n, 60)
			t.size = Vector2(12, 12)
			t.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cell.add_child(t)
			n += 1

## The package's name: NameStrID through the object text tables (0x7de530).
func package_name(pkg: MallData.Package) -> String:
	if _name_cache.has(pkg.code):
		return _name_cache[pkg.code]
	var n: String = panels.mall_text(pkg.name_strid)
	_name_cache[pkg.code] = n
	return n

## The cell's icon: "icon64" + the icon path's tail (W14 / settled: the
## 64-px set), the plain icon when the archive has no 64-px one.
func package_icon(pkg: MallData.Package) -> Texture2D:
	if pkg.icon == "" or panels._builder == null:
		return null
	var t: Texture2D = panels._builder.load_texture("icon64\\" + pkg.icon)
	return t if t != null else panels._builder.load_texture("icon\\" + pkg.icon)

# --- the preview and the try-on (item_mall.md §4, MallPreview) ---------------

var _preview_view: TextureRect

func _install_preview() -> void:
	var area := node("GDR_RENEWAL_ITEM_MALL_RIGHT")
	if area == null:
		return
	preview = panels.make_mall_preview() if panels.has_method("make_mall_preview") else null
	if preview == null:
		return
	_preview_view = TextureRect.new()
	_preview_view.name = "MallPreviewView"
	_preview_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_view.stretch_mode = TextureRect.STRETCH_SCALE
	_preview_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_preview_view.mouse_filter = Control.MOUSE_FILTER_STOP
	area.add_child(_preview_view)
	area.mouse_filter = Control.MOUSE_FILTER_PASS
	_preview_view.add_child(preview)
	ViewportPixels.attach(_preview_view, preview)
	_preview_view.texture = preview.get_texture()
	_preview_view.gui_input.connect(func(e: InputEvent) -> void:
		if preview != null and preview.has_method("handle_input"):
			preview.handle_input(e, _preview_view.size)
			_preview_view.accept_event())
	if preview.has_method("build"):
		preview.build()

func _set_preview_visible(on: bool) -> void:
	if _preview_view != null:
		_preview_view.visible = on

## The cell's +0x551: the first item can go on the preview (3a, and the
## review: avatar hats, dresses and flags, the two pet kinds).
func can_wear_good(good: MallData.Good) -> bool:
	var ref := first_item_id(good)
	return ref > 0 and preview != null and preview.has_method("can_wear") and bool(preview.can_wear(ref))

func first_item_id(good: MallData.Good) -> int:
	if good.package.scraps.is_empty():
		return 0
	return int(panels.mall_item_id((good.package.scraps[0] as MallData.Scrap).item_code))

## Wear Item (0x7df560): nothing while a box is up, a purchase is out or the
## good is a bundle; a 3/1 item must pass the can-equip test, else the
## system line "Cannot equip the selected item"; then onto the preview and
## into the buy list (0x7d8bd0 = 0x7d88c0 + 0x7d8720).
func wear(good: MallData.Good) -> bool:
	if blocked() or dealing > 0 or good.package.is_bundle() or preview == null:
		return false
	var ref := first_item_id(good)
	if ref <= 0:
		return false
	var r: Dictionary = preview.wear(ref)
	if not bool(r.get("ok", false)):
		if String(r.get("reason", "")) == "equip":
			panels.mall_system_line(panels._resolve_ui("UIIT_MSG_STRGERR_EQUIPITEM", "Cannot equip the selected item"))
		return false
	# 0x7d8720: a good whose first item has the same 16-bit packed TID goes.
	var tid := int(panels.mall_item_tid(ref))
	for i in range(buy_list.size() - 1, -1, -1):
		if int(panels.mall_item_tid(first_item_id(buy_list[i]))) == tid:
			buy_list.remove_at(i)
			break
	buy_list.append(good)
	return true

## Original (0x7d8d30), with no box up: the try and buy lists cleared, the
## models rebuilt as equipped. It does not test the pending purchases.
func press_original() -> void:
	if blocked():
		return
	buy_list = []
	if preview != null and preview.has_method("original"):
		preview.original()

## Buy (0x7d7080): no purchase out, a non-empty buy list, no box: the "Buy
## Item Worn" box (ID 122).
func press_buy_worn() -> void:
	if dealing > 0 or buy_list.is_empty() or blocked():
		return
	panels.open_mall_lump_box(buy_list.duplicate(), false)

## Reserved's Buy All (0x7e4840 +0x890): a non-empty reserve list, no box.
func press_buy_all_reserved() -> void:
	if reserve.is_empty() or blocked():
		return
	panels.open_mall_lump_box(reserve.duplicate(), true)

## Buying list (0x7d7130).
func press_buying_list() -> void:
	if blocked() or dealing > 0:
		return
	if panels.has_method("open_silk_history"):
		panels.open_silk_history()

# --- buying (item_mall.md §6) ---------------------------------------------------

## The cell's Buy (0x7ddb90): the confirm box (ID 1200), with no box up and
## nothing being bought.
func open_buy_box(good: MallData.Good) -> void:
	if blocked() or dealing > 0:
		return
	panels.open_mall_confirm_box(good)

## The request for `good` x `count` with `points` (c:0x826460 / 0x7e8797).
func buy_request(good: MallData.Good, count: int, points: int) -> MallNet.Buy:
	var b := MallNet.Buy.new()
	b.group = data.group_id
	b.shop_index = good.shop_index
	b.tab = good.tab_index
	b.slot = good.slot
	b.package_code = good.package.code
	b.count = count
	b.points = points
	b.package_id = good.package.id
	return b

func send_buy(good: MallData.Good, count: int, points: int) -> void:
	dealing += count
	var n = _net()
	if n != null:
		n.mall_buy(buy_request(good, count, points))

## The lump buy (0x7d7d80): one good per message, the next on each success.
## `reserved`: Reserved's Buy All (+0x7c9), whose bought goods leave the
## reserve list ("the reserve list is refreshed", 0x87ba20).
var lump_reserved := false

func start_lump(goods: Array, reserved := false) -> void:
	lump = goods.duplicate()
	lump_reserved = reserved
	_send_next_lump()

func _send_next_lump() -> void:
	if lump.is_empty():
		return
	send_buy(lump[0], 1, 0)

## 0xB034 for a mall buy (0x87f370 -> 0x87ba20 case 0xa7): the goods are
## placed, the dealing counter drops, a lump buy continues and the bought
## good leaves the preview (0x87e2a3..0x87e2d5); a refusal shows its code
## and resets the counter (0x7d6de0(1)).
func on_buy_result(r: Dictionary) -> void:
	if not bool(r.get("ok", false)):
		dealing = 0
		lump = []
		panels.mall_code_message(int(r.get("code", 0)))
		return
	dealing = maxi(dealing - int(r.get("count", 1)), 0) if not lump.is_empty() else 0
	panels.mall_after_buy(r)
	if not lump.is_empty():
		var g: MallData.Good = lump.pop_front()
		if lump_reserved:
			reserve.erase(g)
			if _view.get("kind", "") == "reserve":
				show_reserve()
		else:
			for i in range(buy_list.size() - 1, -1, -1):
				if buy_list[i] == g:
					buy_list.remove_at(i)
			if preview != null and preview.has_method("take_off"):
				preview.take_off(first_item_id(g), true)
		dealing = 0
		_send_next_lump()
