extends HudWindow
class_name MallConfirmBuy

## Round 837: the item mall's buy box, CNewItemMallConfirmBuy (class
## 0xeec708, ID 1200; docs/protocol/item_mall.md §6 and item_mall_verify.md
## §6). c: client addresses in sro_client.exe, READ unless a line says
## otherwise.
##
## **Opening (0x7ddb90, the cell menu's Buy; the bundle box's Buy 0x7d9d00).**
## Refused while a mall box is up (+0x7c8) or purchases are out (+0x7dc).
## The factory makes the box straight from code (0xba20b0): parent the mall,
## rect (0, 0, 0x152, 0xd4) = 338 x 212, ID 0x4b0; centred (0x798b70), bound
## to the cell's item (0x7e91c0), busy set. No layout section names it, so
## CIFMainFrame's caption static stays empty; the title is layout control 5.
## (ifnewitemmallshopitemslot.txt's section ConfirmBuy has the same class
## and size but this path does not load it.)
##
## **Create (0x7e72d0).** CIFMainFrame's OnCreate (0x816f80: caption, drag
## strip, close button), then resinfo\ifnewitemmallconfirmbuy.txt "Create"
## and the frame interface\frame\mall_ms_wnd_.
##
## **Bind (0x7e91c0).** Control 42 (the quantity edit) gets style 3, minimum
## 0 (0x634ff0(0)); a bundle (0x8bf0d0) maximum 5; otherwise for each of
## the package's items: a 3/3 item (packed TID & 0x1c = 0xc, & 0x60 = 0x60)
## that is not bionic (TID & 2 clear) and whose scrap Data (+0x18) is 0 takes its
## MaxStack (ref +0x1c0), anything else 5. The price rows (0x7e7c30), then
## the text "%u" 1 and focus; the item's name on control 40 (NameStrID,
## 0x8c9bb0), its "icon64" icon on control 11; centred again at its final
## size (0x798b70 at 0x7e9635).
##
## **The price rows (0x7e7c30).** A CIFNewItemMallConfirmSlot (class
## 0xeec608, resinfo\ifnewitemmallconfirmslot.txt "Create" + "PointButton",
## 0x7d9880) per payment-device bit, from rect (0, 0x6e, 0x147, 0x16) moved
## down 0x1e before each, so the first at y 140, 30 apart, 327 x 22, IDs
## 100 + n. Each row grows the box, its background (4), control 1002 and
## frame 1001 by 30. Order and labels (0x7d9420, jump table 0x7d9860):
##   bit 1  row 0  UIIT_CTL_WARENETWORK_RESULT_PRICE / UIIT_STT_GOLD     price x count
##   bit 2  row 1  UIIT_STT_SILKMALL_SILK / UIIT_STT_ROLL_OF_CLOTH        price x count - points
##   bit 4  row 2  UIIT_CTL_SILK_INQUIRY_GIFT_SILK / UIIT_STT_ROLL_OF_CLOTH
##   bit 8  row 3  UIIT_STT_GUILD_POINT / UIIT_STT_GUILD_POINT_GP
##   always row 700 UIIT_STT_SILKMALL_INVENTORY_MOD / _INVENTORY_SPACE   free bag slots
##   bit 16 row 4  UIIT_CTL_SILK_INQUIRY_POINT / UIIT_STT_SILKMALL_P_POINT points used;
##                 its label moved 15 left, its point button (10) shown
##   bit 32 row 5  UIIT_STT_TC_HONOR_POINT / UIIT_STT_SILKMALL_P_POINT
## The values are "%d" (row 0: 0x64db50 without grouping). Buy (61) and
## Cancel (62) then go to (62, h - 40) and (185, h - 40).
##
## **The points.** +0x7f8 (points used) starts at the package's bit-16 Cost
## (0x7e812f) and is what the request carries (0x7e874a). The point button
## opens MallUsePoint; its Use (0x7d9a20 -> 0x7e8900) sets points = min(typed,
## silk price x count), redraws the silk and point rows and disables the edit
## and both spin buttons (0xb8f540(0)).
##
## **Quantity.** Spin up (50, 0x7e8ab0): the edit's number + 1 with the cap
## above; spin down (51, 0x7e7010): - 1 while above 0; a typed change (42
## notify 2, 0x7e8d10): capped, every row redrawn; an empty edit is 0.
##
## **Buy (61 / Enter, 0x7e8320).** Free bag slots (0x6b6230): a bundle needs
## count, each item needs count -- one when it is the 3/3 MaxStack kind; too
## few: 0x1807 shown (0x778190), the box STAYS. Silk + gift + point (0x778e20
## + 0x778e30 + 0x778e40) below the bit-2 price x count: 0x1880 shown, the box
## closes. A count of 0 closes it, nothing sent. Else the dealing counter is
## the count (0x7d6d80) and 0x7034 goes out (ItemMallController.send_buy),
## then the box closes. **Cancel (62), Esc, the X (vslot 43, 0x7e69f0)**: busy
## cleared, the box destroyed.
##
## OPEN: a gold row's tax (0x703fc0() -> 0x6fc910(price, 1)); a package with
## no item rows (the edit gets no maximum then: u16 here). OURS: the row
## values are read-only (CIFEdit style 0x80 drops only Backspace); the typed
## quantity is held to the cap as it is typed.

const ID := 1200
const BOX_SIZE := Vector2(338, 212)
const FRAME := "interface\\frame\\mall_ms_wnd_"
const LAYOUT := "resinfo\\ifnewitemmallconfirmbuy.txt"
const ROW_LAYOUT := "resinfo\\ifnewitemmallconfirmslot.txt"
const ROW_ORIGIN_Y := 0x6e
const ROW_PITCH := 0x1e
const ROW_SIZE := Vector2(0x147, 0x16)
const SPACE_ROW := 700
## [bit, row index] in build order (0x7e7c30).
const ROW_ORDER := [[1, 0], [2, 1], [4, 2], [8, 3], [0, SPACE_ROW], [16, 4], [32, 5]]
const ROW_TEXT := {
	0: ["UIIT_CTL_WARENETWORK_RESULT_PRICE", "UIIT_STT_GOLD"],
	1: ["UIIT_STT_SILKMALL_SILK", "UIIT_STT_ROLL_OF_CLOTH"],
	2: ["UIIT_CTL_SILK_INQUIRY_GIFT_SILK", "UIIT_STT_ROLL_OF_CLOTH"],
	3: ["UIIT_STT_GUILD_POINT", "UIIT_STT_GUILD_POINT_GP"],
	4: ["UIIT_CTL_SILK_INQUIRY_POINT", "UIIT_STT_SILKMALL_P_POINT"],
	5: ["UIIT_STT_TC_HONOR_POINT", "UIIT_STT_SILKMALL_P_POINT"],
	SPACE_ROW: ["UIIT_STT_SILKMALL_INVENTORY_MOD", "UIIT_STT_SILKMALL_INVENTORY_SPACE"],
}
const POINT_LABEL_SHIFT := -15.0
const GROWN := ["GDR_ITEMMALL_CONFIRM_BUY_BG", "GDR_ITEMMALL_CONFIRM_BUY_FRAME_BG", "GDR_ITEMMALL_CONFIRM_BUY_FRAME"]
const BUY_X := 0x3e
const CANCEL_X := 0xb9
const BUTTONS_FROM_BOTTOM := 0x28
const CAP_OTHER := 5
const CAP_NONE := 0xffff
const ERR_INVENTORY_FULL := 0x1807
const ERR_SILK := 0x1880

const C_EDIT := "GDR_ITEMMALL_CONFIRM_EDIT_COUNT"
const C_UP := "GDR_ITEMMALL_CONFIRM_SPINBTN_UP"
const C_DOWN := "GDR_ITEMMALL_CONFIRM_SPINBTN_DOWN"
const C_BUY := "GDR_ITEMMALL_CONFIRM_BTN_BUY"
const C_CANCEL := "GDR_ITEMMALL_CONFIRM_BTN_CANCEL"
const C_NAME := "GDR_ITEMMALL_CONFIRM_EDIT_ITEM_NAME"
const C_ICON := "GDR_ITEMMALL_CONFIRM_BUY_ITEM_ICON"
const R_LABEL := "GDR_ITEMMALL_CONFIRM_STA_1"
const R_UNIT := "GDR_ITEMMALL_CONFIRM_STA_2"
const R_VALUE := "GDR_ITEMMALL_CONFIRM_EDIT"
const R_POINT := "GDR_ITEMMALL_CONFIRM_BTN_CONFIRM_POINT"

## Buy went out: the good, the count and the points.
signal bought(count: int, points: int)

var controller
var panels
var good: MallData.Good
var count := 1
## The edit's maximum (see Bind).
var cap := CAP_OTHER
## +0x7f8: the points used.
var points := 0
## +0x810: the free bag slots, read once at setup (0x7e804b).
var space := 0
## Row index -> the row's root control, in build order.
var rows := {}
var row_order: Array = []
var edit: LineEdit
var use_point: MallUsePoint
var _free_slots: Callable
var _balances: Callable
var _message: Callable
var _item_of: Callable
var _closing := false

## Opens the box over the mall for `good` (null when refused or without the
## layout). `opts` (tests and hooks): "host" (the parent node; the mall
## window by default), "free_slots" (Callable -> int), "balances" (Callable
## -> [silk, gift, point]), "message" (Callable(code), the 0x778190 line),
## "item" (Callable(code_name) -> ItemTableReader.Item).
static func open(hud_panels, mall, what: MallData.Good, opts: Dictionary = {}) -> MallConfirmBuy:
	if hud_panels == null or mall == null or what == null or what.package == null:
		return null
	if bool(mall.busy) or int(mall.dealing) > 0:
		return null
	var builder: UiBuilder = hud_panels._builder
	if builder == null:
		return null
	var box := MallConfirmBuy.new()
	box.name = "MallConfirmBuy"
	if not box.build_box(builder, hud_panels, mall, what, opts):
		box.free()
		return null
	var host: Node = opts.get("host", null)
	if host == null:
		host = MallConfirmBuy.default_host(hud_panels, mall)
	host.add_child(box)
	mall.busy = true
	box.place()
	return box

## The mall window when it is up, else the HUD.
static func default_host(hud_panels, mall) -> Node:
	var w = mall.get("_window") if mall is Object else null
	if w is Node and is_instance_valid(w):
		return w
	return hud_panels

func build_box(builder: UiBuilder, hud_panels, mall, what: MallData.Good, opts: Dictionary) -> bool:
	panels = hud_panels
	controller = mall
	good = what
	_free_slots = opts.get("free_slots", Callable())
	_balances = opts.get("balances", Callable())
	_message = opts.get("message", Callable())
	_item_of = opts.get("item", Callable())
	top_level = true
	close_hides = false
	var def := UiLayoutParser.ControlDef.new()
	def.name = "GDR_RENEWAL_ITEM_MALL_CONFIRM_BUY"
	def.type = "CNewItemMallConfirmBuy"
	def.id = ID
	def.ddj = FRAME
	def.rect = Rect2i(Vector2i.ZERO, Vector2i(BOX_SIZE))
	if not build(builder, LAYOUT, "", PackedStringArray(), PackedStringArray(), false, {"def": def, "caption": false}):
		return false
	closed.connect(cancel)
	cap = quantity_cap()
	# +0x7f8 starts at the bit-16 Cost (0x7e812f), else 0 (the ctor).
	points = int(good.package.costs.get(MallData.PAY_POINT, 0)) if (good.package.devices & MallData.PAY_POINT) != 0 else 0
	space = free_slots()
	_build_rows(builder)
	edit = node(C_EDIT) as LineEdit
	if edit != null:
		edit.text = "1"
		edit.text_changed.connect(_on_typed)
		edit.text_submitted.connect(func(_t: String) -> void: press_buy())
		edit.call_deferred("grab_focus")
	_wire(C_UP, func() -> void: spin(1))
	_wire(C_DOWN, func() -> void: spin(-1))
	_wire(C_BUY, press_buy)
	_wire(C_CANCEL, cancel)
	var name_node := node(C_NAME) as Control
	if name_node != null:
		builder.set_static_text(name_node, String(controller.package_name(good.package)))
	_icon(node(C_ICON) as Control, controller.package_icon(good.package))
	count = 1
	refresh_rows()
	return true

## Centred on the screen at the box's final size (0x798b70: integer halves).
func place() -> void:
	if not is_inside_tree():
		return
	var view := get_viewport_rect().size
	global_position = Vector2(int(view.x) / 2 - int(size.x) / 2, int(view.y) / 2 - int(size.y) / 2)

func _wire(control_name: String, handler: Callable) -> void:
	var b := node(control_name) as BaseButton
	if b != null:
		b.pressed.connect(handler)

func _icon(holder: Control, tex: Texture2D) -> void:
	if holder == null or tex == null:
		return
	var rect := TextureRect.new()
	rect.name = "Icon"
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(rect)

# --- the rows -----------------------------------------------------------------

## The row indices the package gets, in build order.
static func row_indices(pkg: MallData.Package) -> Array:
	var out: Array = []
	for pair in ROW_ORDER:
		var bit: int = pair[0]
		if bit == 0 or (pkg.devices & bit) != 0:
			out.append(pair[1])
	return out

## The box's size for `n` rows.
static func size_for_rows(n: int) -> Vector2:
	return BOX_SIZE + Vector2(0, ROW_PITCH * n)

func _build_rows(builder: UiBuilder) -> void:
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(ROW_LAYOUT)
	row_order = row_indices(good.package)
	var y := ROW_ORIGIN_Y
	for index in row_order:
		y += ROW_PITCH
		var row := Control.new()
		row.name = "PriceRow%d" % int(index)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.position = Vector2(0, y)
		row.size = ROW_SIZE
		row.set_meta("row_index", index)
		panel_root.add_child(row)
		if layout != null:
			for sec_name in ["Create", "PointButton"]:
				var part := builder.build_section(layout, sec_name)
				if part != null:
					row.add_child(part)
					UiBuilder.settle_authored_rects(part)
		_fill_row(builder, row, int(index))
		rows[index] = row
	var grow := float(ROW_PITCH * row_order.size())
	for control_name in GROWN:
		_grow(builder, control_name, grow)
	set_registry_size(size_for_rows(row_order.size()))
	var h := size.y
	for pair in [[C_BUY, BUY_X], [C_CANCEL, CANCEL_X]]:
		var b := node(pair[0]) as Control
		if b != null:
			var r: Rect2 = b.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(b.position, b.size))
			HudCosBox._place(b, Rect2(Vector2(float(pair[1]), h - BUTTONS_FROM_BOTTOM), r.size))

## 0x7d9420 for row `index`: label, unit, shown; the point row's label 15 to
## the left and its button shown. The value is set by refresh_rows.
func _fill_row(builder: UiBuilder, row: Control, index: int) -> void:
	var texts: Array = ROW_TEXT.get(index, ["", ""])
	var label := row.find_child(R_LABEL, true, false) as Control
	var unit := row.find_child(R_UNIT, true, false) as Control
	if label != null:
		builder.set_static_text(label, _t(String(texts[0])))
		if index == 4:
			var r: Rect2 = label.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(label.position, label.size))
			HudCosBox._place(label, Rect2(r.position + Vector2(POINT_LABEL_SHIFT, 0), r.size))
	if unit != null:
		builder.set_static_text(unit, _t(String(texts[1])))
	var value := row.find_child(R_VALUE, true, false) as LineEdit
	if value != null:
		value.editable = false
		value.focus_mode = Control.FOCUS_NONE
		value.mouse_filter = Control.MOUSE_FILTER_IGNORE
		value.add_theme_color_override("font_uneditable_color", value.get_theme_color("font_color"))
	var point := row.find_child(R_POINT, true, false) as BaseButton
	if point != null:
		point.visible = index == 4
		if index == 4:
			point.pressed.connect(open_use_point)

## Grows a layout control's height by `dy`; an 8-slice frame is built again
## at its new size (its pieces are placed when it is built).
func _grow(builder: UiBuilder, control_name: String, dy: float) -> void:
	var old := node(control_name) as Control
	if old == null or dy == 0.0:
		return
	var r: Rect2 = old.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(old.position, old.size))
	var grown := Rect2(r.position, r.size + Vector2(0, dy))
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(LAYOUT)
	var sec := layout.get_section("Create") if layout != null else null
	var def: UiLayoutParser.ControlDef = sec.control_by_name.get(control_name) if sec != null else null
	if def != null and UiBuilder.is_slice_base(def.ddj):
		var fresh := builder.build_control(def.with_rect(Rect2i(grown)))
		if fresh != null:
			var parent := old.get_parent()
			var at := old.get_index()
			parent.remove_child(old)
			old.queue_free()
			parent.add_child(fresh)
			parent.move_child(fresh, at)
			return
	HudCosBox._place(old, grown)

## The value row `index` shows now (0x7e8d10's table).
func row_value(index: int) -> int:
	var pkg := good.package
	match index:
		0:
			return int(pkg.costs.get(1, 0)) * count
		1:
			return int(pkg.costs.get(2, 0)) * count - points
		2:
			return int(pkg.costs.get(4, 0)) * count
		3:
			return int(pkg.costs.get(8, 0)) * count
		4:
			return points
		5:
			return int(pkg.costs.get(32, 0)) * count
		SPACE_ROW:
			return space
	return 0

func refresh_rows() -> void:
	for index in rows:
		var row: Control = rows[index]
		var value := row.find_child(R_VALUE, true, false) as LineEdit
		if value != null:
			value.text = "%d" % row_value(int(index))

## The text a row's label (or unit) shows.
func row_text(index: int, unit: bool = false) -> String:
	var row: Control = rows.get(index)
	if row == null:
		return ""
	var n := row.find_child(R_UNIT if unit else R_LABEL, true, false)
	if n is Label:
		return (n as Label).text
	var l := n.get_node_or_null("Text") as Label if n != null else null
	return l.text if l != null else ""

# --- quantity -----------------------------------------------------------------

## The edit's maximum (0x7e91c0 / 0x7e8ab0 / 0x7e8d10).
func quantity_cap() -> int:
	var pkg := good.package
	if pkg.is_bundle():
		return CAP_OTHER
	if pkg.scraps.is_empty():
		return CAP_NONE
	var c := CAP_NONE
	for s in pkg.scraps:
		c = mini(c, _scrap_cap(s))
	return c

func _scrap_cap(s: MallData.Scrap) -> int:
	var item = _item(s.item_code)
	if _is_stack_kind(item, s):
		return maxi(int(item.max_stack), 0)
	return CAP_OTHER

## A 3/3 item, not bionic, its scrap Data 0 (0x7e94cd..0x7e94ec).
static func _is_stack_kind(item, s: MallData.Scrap) -> bool:
	if item == null or s.data != 0:
		return false
	var t: PackedInt32Array = item.type_ids
	return t.size() >= 2 and t[0] == 3 and t[1] == 3 and (int(item.bionic) & 1) == 0

func _item(code: String):
	if _item_of.is_valid():
		return _item_of.call(code)
	if panels == null:
		return null
	if panels.has_method("_load_items"):
		panels.call("_load_items")
	var by_code = panels.get("_items_by_code")
	return by_code.get(code) if by_code is Dictionary else null

func set_count(n: int) -> void:
	count = clampi(n, 0, cap)
	if edit != null and edit.text != str(count):
		edit.text = str(count)
		edit.caret_column = edit.text.length()
	refresh_rows()

## Spin up / down (0x7e8ab0 / 0x7e7010): from the edit's number.
func spin(step: int) -> void:
	if edit != null and not edit.editable:
		return
	var n := int(edit.text) if edit != null and edit.text.is_valid_int() else count
	if step < 0:
		set_count(n - 1 if n > 0 else 0)
	else:
		set_count(n + 1)

func _on_typed(text: String) -> void:
	var digits := ""
	for ch in text:
		if ch >= "0" and ch <= "9":
			digits += ch
	if digits == "":
		if text != "":
			edit.text = ""
		# 0x7e908b: an empty edit is a count of 0; the rows stay as they were.
		count = 0
		return
	var n := mini(int(digits), cap) if digits.length() <= 6 else cap
	if str(n) != text:
		edit.text = str(n)
		edit.caret_column = edit.text.length()
	count = n
	refresh_rows()

# --- the points -----------------------------------------------------------------

func open_use_point() -> void:
	if use_point != null and is_instance_valid(use_point):
		return
	var builder: UiBuilder = _builder
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(ROW_LAYOUT) if builder != null else null
	var sec := layout.get_section("ConfirmPoint") if layout != null else null
	var def: UiLayoutParser.ControlDef = sec.control_by_id.get(MallUsePoint.ID) if sec != null else null
	var dlg := MallUsePoint.new()
	if not dlg.build(builder, def, int(balances()[2])):
		dlg.free()
		return
	var row: Control = rows.get(4)
	(row if row != null else self).add_child(dlg)
	dlg.place()
	dlg.used.connect(apply_points)
	use_point = dlg

## 0x7e8900 for a typed point count: min(it, the silk price x count) used.
func apply_points(n: int) -> void:
	if (good.package.devices & MallData.PAY_POINT) != 0:
		points = mini(maxi(n, 0), int(good.package.costs.get(2, 0)) * count)
		refresh_rows()
		if edit != null:
			edit.editable = false
		for control_name in [C_UP, C_DOWN]:
			var b := node(control_name) as BaseButton
			if b != null:
				b.disabled = true
	if use_point != null and is_instance_valid(use_point):
		use_point.close()
	use_point = null

# --- buying ---------------------------------------------------------------------

func free_slots() -> int:
	if _free_slots.is_valid():
		return int(_free_slots.call())
	if panels != null and panels.has_method("mall_free_bag_slots"):
		return int(panels.mall_free_bag_slots())
	return 0

## [silk, gift, point].
func balances() -> Array:
	if _balances.is_valid():
		return _balances.call()
	var n = controller.call("_net") if controller != null and controller.has_method("_net") else null
	if n != null and "silk_balances" in n:
		return n.silk_balances
	return [0, 0, 0]

func _show(code: int) -> void:
	if _message.is_valid():
		_message.call(code)
	elif panels != null and panels.has_method("mall_code_message"):
		panels.mall_code_message(code)

## The slot test (0x7e83cc..0x7e8505): true when the bag can take `count`.
func slots_ok() -> bool:
	var free := free_slots()
	var pkg := good.package
	if pkg.is_bundle():
		return free >= count
	for s in pkg.scraps:
		var need := 1 if _is_stack_kind(_item((s as MallData.Scrap).item_code), s) else count
		if free < need:
			return false
	return true

## Buy (61, Enter): 0x7e8320.
func press_buy() -> void:
	if _closing:
		return
	if edit != null and edit.text.is_valid_int():
		count = clampi(int(edit.text), 0, cap)
	if not slots_ok():
		_show(ERR_INVENTORY_FULL)
		return
	var b := balances()
	var held := int(b[0]) + int(b[1]) + int(b[2])
	if held < good.package.silk_price() * count:
		_show(ERR_SILK)
		close_box()
		return
	if count <= 0:
		close_box()
		return
	controller.send_buy(good, count, points)
	bought.emit(count, points)
	close_box()

## Cancel (62), Esc, the X: vslot 43 (0x7e69f0).
func cancel() -> void:
	close_box()

func close_box() -> void:
	if _closing:
		return
	_closing = true
	if controller != null:
		controller.busy = false
	if use_point != null and is_instance_valid(use_point):
		use_point.close()
	name = "MallConfirmBuy_closing"
	hide()
	queue_free()

## WM_CHAR (0x7e96b0): Enter buys, Esc cancels.
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or not is_visible_in_tree():
		return
	if key.keycode == KEY_ESCAPE:
		cancel()
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
		press_buy()
		get_viewport().set_input_as_handled()

func _t(key: String) -> String:
	if key == "" or _builder == null:
		return key
	var t := _builder.resolve_text(key)
	return key if t == "" else t
