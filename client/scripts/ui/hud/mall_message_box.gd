extends HudWindow
class_name MallMessageBox

## Round 837: the item mall's CIFNewItemMallMessageBox (class 0xeec628,
## vtable 0xdcc454; docs/protocol/item_mall.md §2b, §3c, §4d). c: client
## addresses in sro_client.exe, READ unless a line says otherwise.
##
## Every kind is made straight from code by the factory (0xba20b0) with the
## mall as parent, centred on the screen at that size (0x798b70), filled, and
## the mall's busy byte +0x7c8 set:
##   ID 122  (0x7a)  368 x 348  the try-on's Buy, "Buy Item Worn" (0x7d7080, fill 0x7db490)
##   ID 306  (0x132) 376 x 272  Reserved's Buy All (0x7e4961, fill 0x7da950)
##   ID 1202 (0x4b2) 396 x 252  Pre-select (0x7ddd00, fill 0x7da4b0(item, 1))
##   ID 1203 (0x4b3) 396 x 252  Delete in the reserve view (0x7dddb0, fill 0x7da4b0(item, 0))
## Create (0x7da170): CIFMainFrame's OnCreate (caption static +0x7b0, drag
## strip, close button), resinfo\ifnewitemmallmessagebox.txt "Create", the
## frame interface\frame\mall_ms_wnd_. The message map (0xd72cc0):
## 1609/1608 Zzim OK/Cancel, 1818/1817 AllBuy Buy/Cancel, 2017/2016 AllBuyZzim
## Buy/Cancel, 1804 the point button, 1800 the slider, WM_CHAR Esc = close.
## The close (vslot 43, 0x7d9dc0) is refused while a reserved lump is being
## sent (+0xa00 > 0, or +0x7bd with purchases out); otherwise busy cleared and
## the box destroyed.
##
## **AllBuy (ID 122, 0x7db490).** Caption UIIT_STT_SILKMALL_PUT_ON_CLOSE_BUY;
## the slider 1800 built from section AllBuyItemListSlider (1822, 1821 and
## 1820 bound by 0x659620; 0x659840(0x25); 0x6599e0(0, n - 3, 1, 1), INFERRED
## the range 0..n - 3); the list 1801 with three columns (0x80eed0(x, width):
## 27/147, 174/80, 258/15 -- READ that the column's rect takes them),
## 0x80e4d0(3) and 0x80e530(0x1c) on every column (INFERRED: 3 rows shown,
## 28 high), 0x80e390(0, 2) and (1, 2) (INFERRED: columns 0 and 1 aligned
## right, as a layout's HAlign 2); per good its name, its
## bit-2 Cost "%d" and UIIT_STT_ROLL_OF_CLOTH, the Costs summed; 1810 the sum,
## 1809 the free bag slots, 1808 the LAST good's bit-16 Cost. Buy (1818 ->
## 0x7d9d70): the mall's 0x7d7d80(n, sum), then the box closes. 0x7d7d80:
## silk + gift + point below the sum, or free slots below n, feeds a local
## 0xB034 {2, 0x1880 / 0x1807} to the reply handler; else the lump starts.
##
## **AllBuyZzim (ID 306, 0x7da950).** Caption UIIT_STT_SILKMALL_ZZIM_LUMP_BUY;
## 2011 the reserve count, 2013 the sum of the bit-2 Costs, 2012 the free
## slots, 2010 the last good's bit-16 Cost. Buy (2017 -> 0x7db450): nothing
## while sending; else +0x7bd set and 0x7dabc0: silk + gift + point below the
## sum -> local {2, 0x1880}; free slots below the FIRST good's item count ->
## {2, 0x1807}; else the lump starts. The box stays up while the lump runs.
##
## **Zzim (IDs 1202 / 1203, 0x7da4b0).** Section Zzim; 1603 the name, 1601
## the bit-2 Cost (0x64db50, no grouping), 1604 the icon64 icon. Add: caption
## UIIT_STT_SILKMALL_DO_ZZIM, 1607 (PML) UIIT_MSG_SILKMALL_ZZIM_CONFIRM. Delete:
## 1609 captioned UIIT_STT_SILKMALL_DEL, caption UIIT_CTL_SILKMALL_DELETE_
## BASKET_ITEM, a new CIFStatic (ID 0x9c4) at (9, 0x76, 0x181, 0x50) with
## UIIT_MSG_SILKMALL_ZZIM_DELITE. OK (1609 -> 0x7d9c10): add appends to the
## reserve list (0x783b70, no duplicate test); delete removes the first entry
## of that package (0x784f70) and redraws the reserve view (0x7e4590); then
## the box closes. Cancel (1608) closes it.
##
## INFERRED / OURS: the lump's points -- the point button opens MallUsePoint
## and, for a last good with bit 16, sets points = min(typed, the sum) and
## redraws 1810 / 1808 (0x7da2a0, READ); retail then spends them good by good
## (0x7d7d80 / 0x7db160) but ItemMallController.start_lump takes no points,
## so they stop here (OPEN for the controller; no package of this archive has
## bit 16). A reserved lump's box closes once the controller's lump is empty
## and nothing is out (INFERRED: the reply path that closes it was not
## read). The list's text alignment for column 2, the delete text's
## alignment (centred here) and the list rows' vertical placement are OURS.
## The bundle contents box (ID 1201 / 1204, 0x7dcb10) is not built: every
## package of this archive's mall holds one item (OPEN).

enum Kind { WORN = 122, RESERVED = 306, ADD = 1202, DELETE = 1203 }

const LAYOUT := "resinfo\\ifnewitemmallmessagebox.txt"
const FRAME := "interface\\frame\\mall_ms_wnd_"
const SIZES := {
	Kind.WORN: Vector2(0x170, 0x15c),
	Kind.RESERVED: Vector2(0x178, 0x110),
	Kind.ADD: Vector2(0x18c, 0xfc),
	Kind.DELETE: Vector2(0x18c, 0xfc),
}
const SECTIONS := {Kind.WORN: "AllBuy", Kind.RESERVED: "AllBuyZzim", Kind.ADD: "Zzim", Kind.DELETE: "Zzim"}
const CAPTIONS := {
	Kind.WORN: "UIIT_STT_SILKMALL_PUT_ON_CLOSE_BUY",
	Kind.RESERVED: "UIIT_STT_SILKMALL_ZZIM_LUMP_BUY",
	Kind.ADD: "UIIT_STT_SILKMALL_DO_ZZIM",
	Kind.DELETE: "UIIT_CTL_SILKMALL_DELETE_BASKET_ITEM",
}
const ERR_INVENTORY_FULL := 0x1807
const ERR_SILK := 0x1880

# AllBuy (ID 122).
const A_LIST := "GDR_ITEMMALL_ALL_BUY_ITEM_LIST"
const A_SLIDER := "GDR_ITEMMALL_ALL_BUY_SLI"
const A_TOTAL := "GDR_ITEMMALL_ALL_BUY_BOX_TOTAL_AMOUNT"
const A_SPACE := "GDR_ITEMMALL_ALL_BUY_BOX_REMAIN_INVENTORY_AMOUNT"
const A_POINT := "GDR_ITEMMALL_ALL_BUY_BOX_USE_POINT"
const A_POINT_BTN := "GDR_ITEMMALL_ALL_BUY_BTN_USE_POINT"
const A_BUY := "GDR_ITEMMALL_ALL_BUY_BTN_BUY"
const A_CANCEL := "GDR_ITEMMALL_ALL_BUY_BTN_CANCEL"
const SLIDER_SECTION := "AllBuyItemListSlider"
const S_PREV := "GDR_BTN_PREV"
const S_NEXT := "GDR_BTN_NEXT"
const S_THUMB := "GDR_BTN_THUMB"
## 0x80eed0(x, width) per column, 0x80e4d0(3), 0x80e530(0x1c).
const LIST_COLUMNS := [[27, 147], [174, 80], [258, 15]]
const LIST_VISIBLE := 3
const LIST_ROW_HEIGHT := 28
# AllBuyZzim (ID 306).
const Z_COUNT := "GDR_ITEMMALL_CONFIRM_ZZIM_LUMP_BUY_EDIT_ITEM_AMOUNT"
const Z_TOTAL := "GDR_ITEMMALL_CONFIRM_ZZIM_LUMP_BUY_EDIT_TOTAL_AMOUNT"
const Z_SPACE := "GDR_ITEMMALL_CONFIRM_ZZIM_LUMP_BUY_EDIT_REMAIN_INVENTORY_AMOUNT"
const Z_POINT := "GDR_ITEMMALL_CONFIRM_ZZIM_LUMP_BUY_EDIT_USE_POINT"
const Z_POINT_BTN := "GDR_ITEMMALL_CONFIRM_ZZIM_LUMP_BUY_BTN_POINT"
const Z_BUY := "GDR_ITEMMALL_CONFIRM_ZZIM_LUMP_BUY_BTN_BUY"
const Z_CANCEL := "GDR_ITEMMALL_CONFIRM_ZZIM_LUMP_BUY_BTN_CANCEL"
# Zzim (IDs 1202 / 1203).
const R_NAME := "GDR_ITEMMALL_ZZIM_STA_ITEM_NAME"
const R_PRICE := "GDR_ITEMMALL_ZZIM_STA_PRICE_MALL_BOX"
const R_ICON := "GDR_ITEMMALL_ZZIM_ITEM_ICON"
const R_PML := "GDR_ITEMMALL_ZZIM_STATIC_MESSAGE_PML"
const R_OK := "GDR_ITEMMALL_ZZIM_BTN_BUY"
const R_CANCEL := "GDR_ITEMMALL_ZZIM_BTN_CANCEL"
const DELETE_TEXT_RECT := Rect2i(9, 0x76, 0x181, 0x50)
const DELETE_TEXT_ID := 0x9c4

## OK on a Zzim box, or a lump started: what went to the controller.
signal done(kind: int)

var kind := 0
var controller
var panels
var goods: Array = []
var good: MallData.Good
## The sum of the goods' bit-2 Costs (+0x7c0).
var total := 0
## The points the box shows (+0x9e8 / +0x9f8).
var points := 0
## A reserved lump is being sent (+0x7bd).
var buying := false
var list_first := 0
var use_point: MallUsePoint
var _free_slots: Callable
var _balances: Callable
var _message: Callable
var _list_rows: Control
var _closing := false

## The lump box: ID 122 for the try-on's goods, ID 306 for the reserve list
## (`reserved`). Null when refused (a box up, purchases out, no goods) or
## without the layout. `opts` as MallConfirmBuy.open.
static func open_lump(hud_panels, mall, what: Array, reserved: bool, opts: Dictionary = {}) -> MallMessageBox:
	if what.is_empty():
		return null
	return _open(hud_panels, mall, Kind.RESERVED if reserved else Kind.WORN, what, null, opts)

## The reserve box: ID 1202 to add `what` (`add`), 1203 to delete it.
static func open_reserve(hud_panels, mall, what: MallData.Good, add: bool, opts: Dictionary = {}) -> MallMessageBox:
	if what == null or what.package == null:
		return null
	return _open(hud_panels, mall, Kind.ADD if add else Kind.DELETE, [what], what, opts)

static func _open(hud_panels, mall, box_kind: int, what: Array, one: MallData.Good, opts: Dictionary) -> MallMessageBox:
	if hud_panels == null or mall == null:
		return null
	if bool(mall.busy) or int(mall.dealing) > 0:
		return null
	var builder: UiBuilder = hud_panels._builder
	if builder == null:
		return null
	var box := MallMessageBox.new()
	box.name = "MallMessageBox%d" % box_kind
	if not box.build_box(builder, hud_panels, mall, box_kind, what, one, opts):
		box.free()
		return null
	var host: Node = opts.get("host", null)
	if host == null:
		host = MallConfirmBuy.default_host(hud_panels, mall)
	host.add_child(box)
	mall.busy = true
	box.place()
	return box

func build_box(builder: UiBuilder, hud_panels, mall, box_kind: int, what: Array, one: MallData.Good, opts: Dictionary) -> bool:
	panels = hud_panels
	controller = mall
	kind = box_kind
	goods = what.duplicate()
	good = one
	_free_slots = opts.get("free_slots", Callable())
	_balances = opts.get("balances", Callable())
	_message = opts.get("message", Callable())
	top_level = true
	close_hides = false
	var def := UiLayoutParser.ControlDef.new()
	def.name = "GDR_RENEWAL_ITEM_MALL_MSB"
	def.type = "CIFNewItemMallMessageBox"
	def.id = box_kind
	def.ddj = FRAME
	def.rect = Rect2i(Vector2i.ZERO, Vector2i(SIZES[box_kind]))
	if not build(builder, LAYOUT, "", PackedStringArray([SECTIONS[box_kind]]), PackedStringArray(), false,
			{"def": def, "caption": false}):
		return false
	closed.connect(request_close)
	set_title(_t(CAPTIONS[box_kind]))
	total = 0
	for g in goods:
		total += (g as MallData.Good).package.silk_price()
	var last: MallData.Package = (goods[-1] as MallData.Good).package if not goods.is_empty() else null
	points = int(last.costs.get(MallData.PAY_POINT, 0)) if last != null else 0
	match box_kind:
		Kind.WORN:
			_fill_all_buy(builder)
		Kind.RESERVED:
			_fill_all_buy_zzim()
		_:
			_fill_zzim(builder)
	return true

## Centred on the screen at its size (0x798b70: integer halves).
func place() -> void:
	if not is_inside_tree():
		return
	var view := get_viewport_rect().size
	global_position = Vector2(int(view.x) / 2 - int(size.x) / 2, int(view.y) / 2 - int(size.y) / 2)

func _wire(control_name: String, handler: Callable) -> void:
	var b := node(control_name) as BaseButton
	if b != null:
		b.pressed.connect(handler)

func _put(control_name: String, text: String) -> void:
	var n := node(control_name) as Control
	if n is LineEdit:
		var e := n as LineEdit
		e.text = text
		e.editable = false
		e.focus_mode = Control.FOCUS_NONE
		e.add_theme_color_override("font_uneditable_color", e.get_theme_color("font_color"))
	elif n != null and _builder != null:
		_builder.set_static_text(n, text)

## The text a named control shows.
func text_of(control_name: String) -> String:
	var n := node(control_name)
	if n is LineEdit:
		return (n as LineEdit).text
	if n is Label:
		return (n as Label).text
	for c in (n.find_children("*", "Label", true, false) if n != null else []):
		return (c as Label).text
	return ""

# --- AllBuy (ID 122) -------------------------------------------------------------

func _fill_all_buy(builder: UiBuilder) -> void:
	var holder := node(A_LIST) as Control
	if holder != null:
		holder.clip_contents = true
		_list_rows = Control.new()
		_list_rows.name = "Rows"
		_list_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(_list_rows)
		for i in goods.size():
			_list_rows.add_child(_list_row(builder, goods[i], i))
	var slider := node(A_SLIDER) as Control
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(LAYOUT)
	if slider != null and layout != null:
		var part := builder.build_section(layout, SLIDER_SECTION)
		if part != null:
			slider.add_child(part)
			UiBuilder.settle_authored_rects(part)
			var prev := part.get_node_or_null(S_PREV) as BaseButton
			var next := part.get_node_or_null(S_NEXT) as BaseButton
			if prev != null:
				prev.pressed.connect(func() -> void: scroll_list(list_first - 1))
			if next != null:
				next.pressed.connect(func() -> void: scroll_list(list_first + 1))
	_put(A_TOTAL, "%d" % total)
	_put(A_SPACE, "%d" % free_slots())
	_put(A_POINT, "%d" % points)
	_wire(A_BUY, press_buy)
	_wire(A_CANCEL, request_close)
	_wire(A_POINT_BTN, open_use_point)
	scroll_list(0)

func _list_row(builder: UiBuilder, g: MallData.Good, i: int) -> Control:
	var row := Control.new()
	row.name = "Row%d" % i
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.size = Vector2(330, LIST_ROW_HEIGHT)
	var texts := [String(controller.package_name(g.package)), "%d" % g.package.silk_price(), _t("UIIT_STT_ROLL_OF_CLOTH")]
	var aligns := [HORIZONTAL_ALIGNMENT_RIGHT, HORIZONTAL_ALIGNMENT_RIGHT, HORIZONTAL_ALIGNMENT_LEFT]
	for c in LIST_COLUMNS.size():
		var l := Label.new()
		l.name = "Column%d" % c
		l.text = texts[c]
		l.position = Vector2(float(LIST_COLUMNS[c][0]), 0)
		l.size = Vector2(float(LIST_COLUMNS[c][1]), LIST_ROW_HEIGHT)
		l.horizontal_alignment = aligns[c]
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.clip_text = true
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if builder != null and builder.font_at(0) != null:
			l.add_theme_font_override("font", builder.font_at(0))
		l.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		row.add_child(l)
	return row

## The list's first shown row (the slider's value, 0..n - 3).
func scroll_list(first: int) -> void:
	list_first = clampi(first, 0, maxi(goods.size() - LIST_VISIBLE, 0))
	if _list_rows == null:
		return
	for i in _list_rows.get_child_count():
		var row := _list_rows.get_child(i) as Control
		row.position = Vector2(0, (i - list_first) * LIST_ROW_HEIGHT)
		row.visible = i >= list_first and i < list_first + LIST_VISIBLE
	var slider := node(A_SLIDER) as Control
	var thumb := slider.find_child(S_THUMB, true, false) as Control if slider != null else null
	if thumb != null:
		var r: Rect2 = thumb.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(thumb.position, thumb.size))
		var range_max := maxi(goods.size() - LIST_VISIBLE, 0)
		# OURS: the thumb between the arrows (20 .. 75 - its height).
		var span := 75.0 - 20.0 - r.size.y
		var y := 20.0 + (span * list_first / range_max if range_max > 0 else 0.0)
		HudCosBox._place(thumb, Rect2(Vector2(r.position.x, y), r.size))

## The names the list shows, top to bottom (all rows, shown or not).
func list_names() -> Array:
	var out: Array = []
	if _list_rows != null:
		for row in _list_rows.get_children():
			out.append(((row as Node).get_node("Column0") as Label).text)
	return out

# --- AllBuyZzim (ID 306) ---------------------------------------------------------

func _fill_all_buy_zzim() -> void:
	_put(Z_COUNT, "%d" % goods.size())
	_put(Z_TOTAL, "%d" % total)
	_put(Z_SPACE, "%d" % free_slots())
	_put(Z_POINT, "%d" % points)
	_wire(Z_BUY, press_buy)
	_wire(Z_CANCEL, request_close)
	_wire(Z_POINT_BTN, open_use_point)

# --- Zzim (IDs 1202 / 1203) ------------------------------------------------------

func _fill_zzim(builder: UiBuilder) -> void:
	var pkg := good.package
	_put(R_NAME, String(controller.package_name(pkg)))
	_put(R_PRICE, "%d" % pkg.silk_price())
	var icon := node(R_ICON) as Control
	var tex: Texture2D = controller.package_icon(pkg)
	if icon != null and tex != null:
		var rect := TextureRect.new()
		rect.name = "Icon"
		rect.texture = tex
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_SCALE
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon.add_child(rect)
	if kind == Kind.ADD:
		var pml := node(R_PML) as Control
		if pml != null:
			var rt := RichTextLabel.new()
			rt.name = "PmlText"
			rt.bbcode_enabled = true
			rt.scroll_active = false
			rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
			rt.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			if builder.font_at(0) != null:
				rt.add_theme_font_override("normal_font", builder.font_at(0))
			rt.add_theme_font_size_override("normal_font_size", UiBuilder.FONT_SIZES[0])
			# CIFPML's alignment is not read; centred as PartyMatchBox.fill_pml (INFERRED).
			rt.text = "[center]%s[/center]" % PartyMatchBox.sml2_to_bbcode(_t("UIIT_MSG_SILKMALL_ZZIM_CONFIRM"))
			pml.add_child(rt)
	else:
		var ok := node(R_OK) as Control
		if ok != null:
			builder.set_button_text(ok, _t("UIIT_STT_SILKMALL_DEL"))
		var d := UiLayoutParser.ControlDef.new()
		d.name = "GDR_ITEMMALL_ZZIM_DELETE_TEXT"
		d.type = "CIFStatic"
		d.id = DELETE_TEXT_ID
		d.rect = DELETE_TEXT_RECT
		d.halign = 1
		d.valign = 1
		var t := builder.build_control(d)
		if t != null:
			panel_root.add_child(t)
			builder.set_static_text(t, _t("UIIT_MSG_SILKMALL_ZZIM_DELITE"))
	_wire(R_OK, press_ok)
	_wire(R_CANCEL, request_close)

## OK on a Zzim box (0x7d9c10).
func press_ok() -> void:
	if _closing or good == null:
		return
	if kind == Kind.ADD:
		controller.reserve.append(good)
	elif kind == Kind.DELETE:
		var reserve: Array = controller.reserve
		for i in reserve.size():
			if (reserve[i] as MallData.Good).package.id == good.package.id:
				reserve.remove_at(i)
				break
		if controller.has_method("show_reserve"):
			controller.show_reserve()
	done.emit(kind)
	_close_now()

# --- the lumps -----------------------------------------------------------------

func free_slots() -> int:
	if _free_slots.is_valid():
		return int(_free_slots.call())
	if panels != null and panels.has_method("mall_free_bag_slots"):
		return int(panels.mall_free_bag_slots())
	return 0

func balances() -> Array:
	if _balances.is_valid():
		return _balances.call()
	var n = controller.call("_net") if controller != null and controller.has_method("_net") else null
	if n != null and "silk_balances" in n:
		return n.silk_balances
	return [0, 0, 0]

## A refusal the client makes itself: 0xB034 {2, code} fed to the reply
## handler (0x7d7e0a / 0x7dacd9), which resets the counter and shows the code.
func _refuse(code: int) -> void:
	if controller != null and controller.has_method("on_buy_result"):
		controller.on_buy_result({"ok": false, "code": code})
	elif _message.is_valid():
		_message.call(code)
	elif panels != null and panels.has_method("mall_code_message"):
		panels.mall_code_message(code)

## Buy on a lump box: 1818 (0x7d9d70 -> 0x7d7d80) or 2017 (0x7db450 -> 0x7dabc0).
func press_buy() -> void:
	if _closing:
		return
	var b := balances()
	var held := int(b[0]) + int(b[1]) + int(b[2])
	if kind == Kind.WORN:
		if held < total:
			_refuse(ERR_SILK)
		elif free_slots() < goods.size():
			_refuse(ERR_INVENTORY_FULL)
		else:
			controller.start_lump(goods)
			done.emit(kind)
		_close_now()
		return
	if kind != Kind.RESERVED or sending() or int(controller.dealing) > 0:
		return
	buying = true
	if held < total:
		_refuse(ERR_SILK)
		return
	var first: MallData.Good = goods[0]
	if free_slots() < first.package.scraps.size():
		_refuse(ERR_INVENTORY_FULL)
		return
	controller.start_lump(goods, true)
	_lump_seen = true
	done.emit(kind)

var _lump_seen := false

## Whether the reserved lump is still being sent (+0xa00 / +0x7bd).
func sending() -> bool:
	if not buying or controller == null:
		return false
	var lump = controller.get("lump")
	return int(controller.dealing) > 0 or (_lump_seen and lump is Array and not (lump as Array).is_empty())

func _process(_delta: float) -> void:
	# INFERRED: the reserved lump's box goes once everything is bought.
	if _lump_seen and not sending():
		_close_now()

## The close request (Cancel, Esc, the X; vslot 43, 0x7d9dc0).
func request_close() -> bool:
	if sending():
		return false
	_close_now()
	return true

func _close_now() -> void:
	if _closing:
		return
	_closing = true
	if controller != null:
		controller.busy = false
	if use_point != null and is_instance_valid(use_point):
		use_point.close()
	name = "MallMessageBox_closing"
	hide()
	queue_free()

# --- the points ------------------------------------------------------------------

## The point button (1804 -> 0x7da3b0 -> 0x7da210(1)).
func open_use_point() -> void:
	if use_point != null and is_instance_valid(use_point):
		return
	var layout: UiLayoutParser.LayoutDef = _builder.load_layout(LAYOUT) if _builder != null else null
	var sec := layout.get_section("ConfirmPoint") if layout != null else null
	var def: UiLayoutParser.ControlDef = sec.control_by_id.get(MallUsePoint.ID) if sec != null else null
	var dlg := MallUsePoint.new()
	if not dlg.build(_builder, def, int(balances()[2])):
		dlg.free()
		return
	add_child(dlg)
	dlg.place()
	dlg.used.connect(apply_points)
	use_point = dlg

## 0x7da2a0: only when the last good has bit 16 -- points = min(typed, the
## sum), the total shows the sum less them, the point box them, and the
## dialog closes. Otherwise nothing happens (the dialog stays; READ).
func apply_points(n: int) -> void:
	var last: MallData.Package = (goods[-1] as MallData.Good).package if not goods.is_empty() else null
	if last == null or (last.devices & MallData.PAY_POINT) == 0:
		return
	points = mini(maxi(n, 0), total)
	_put(A_TOTAL if kind == Kind.WORN else Z_TOTAL, "%d" % (total - points))
	_put(A_POINT if kind == Kind.WORN else Z_POINT, "%d" % points)
	if use_point != null and is_instance_valid(use_point):
		use_point.close()
	use_point = null

## WM_CHAR (0x7d9e20): Esc closes.
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or not is_visible_in_tree():
		return
	if key.keycode == KEY_ESCAPE:
		request_close()
		get_viewport().set_input_as_handled()

func _t(key: String) -> String:
	if key == "" or _builder == null:
		return key
	var t := _builder.resolve_text(key)
	return key if t == "" else t
