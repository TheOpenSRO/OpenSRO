extends Control
class_name StoreMessageBox

## The original's confirm boxes for the NPC store and the warehouse (round 726,
## lane B of the NPC GUI epic; docs/protocol/npc_gui.md §4 and
## docs/protocol/message_box.md). Each box is built from the client's own
## layouts in Media.pk2, not drawn by this client. READ from sro_client.exe
## unless a line says otherwise.
##
## **Buy** is `CItemMallConfirmBuy` (`ifinventory.txt` "ConfirmBuy", ID 400,
## frame `msgbox2_window_`, `Rect 95,111,327,155`), whose controls come from
## `resinfo\ifitemmallconfirmbuy.txt` "Create" (RENEWAL branch). Its price
## row is a `CIFItemMallConfirmSlot` (`resinfo\ifitemmallconfirmslot.txt`
## "Create", the path at 0xdc92f8, loaded by 0x7c1f30) that
## `FUN_007c3f70` adds for each price kind the good carries:
## - the row's rect starts at {0, 80, 327, 22}; the gold kind (flag 1) moves
##   it +20 (0x14) to y 100 and grows the window and its background (ID 4)
##   by 22 (0x16), so 327x177 with the background 295x128;
## - the row's label is `UIIT_CTL_WARENETWORK_RESULT_PRICE`, its unit
##   `UIIT_STT_GOLD`, its edit the count times the unit price as "%I64d"
##   (0x7c1a80 case 0 and its tail): no thousands separators;
## - Buy (61) and Cancel (62) are moved to (x+82, y+h-40) and (x+170, y+h-40)
##   (0x7c47ef..0x7c4871), so (82, 137) and (170, 137) in the box.
##
## **Sell, buy back, deposit, withdraw** are `CIFMessageBox` mode 6,
## `MsgBoxStoreConfirm` in `resinfo\ifmessagebox.txt` (RENEWAL only). The
## purpose (0x63ea80, jump table 0x63ff38 indexed by purpose - 1) sets:
## - the size 327x175 (`push 0xaf; push 0x147` before slot 0x54, 0x63eb94 and
##   its three twins) and the title `UIIT_STT_CONFIRM_BOX`;
## - OK's caption: `UIIT_STT_SELL` (2), `UIIT_STT_RE_BUY_OBJECT` (0x14),
##   `UIIT_STT_DEPOSIT` (5, 0x10 guild), `UIIT_STT_WITHDRAW` (6, 0x11);
##   Cancel's `UIIT_CTL_CANCEL` (0xd9b83c) in every purpose;
## - the spin buttons (IDs 81 / 82) hidden for buy back, deposit and withdraw
##   (`push 1; push 0x51 / 0x52` GetControl, then slot 0x5c with ebx = 0),
##   kept for sell;
## - for withdraw only, the "Price" label (ID 86, +0x898) and the item name
##   (ID 79, +0x818) hidden (0x63ee85..0x63ee9f). The member map is 0x640300
##   (73 +0x814 icon, 83 +0x800 OK, 84 +0x804 Cancel, 79 +0x818 name, 85 +0x880
##   price, 80 +0x888 count, 78 +0x88c "Quantity", 75 +0x890, 77 +0x894,
##   86 +0x898 "Price", 87 +0x89c "Gold"). That the original shows a withdraw
##   box without the item's name is what the code says; no screenshot of it
##   was available to confirm it.
##
## **Warehouse gold** is mode 3, `MsgBoxStoreMoney`, in the box the inventory
## creates at 308x148 (`FUN_006af530`: 0x134 x 0x94). Purpose 3 deposits
## (OK `UIIT_STT_DEPOSIT`), 4 withdraws (`UIIT_STT_WITHDRAW`); the purpose
## puts `interface\icon\moneyicon.ddj` on the icon, captions NAME1
## `UIIT_STT_DEPOSITMONEY` / `UIIT_STT_WITHDRAWMONEY`, strips the amount
## edit's art, moves it to (0x79, 0x42) in the box and sizes it 121x24, and
## hides IDs 8, 9 and 2 (0x63ef90..0x63f00a; message_box.md).
##
## A CIFMessageBox also builds its file's "Create" first (GDR_MSGBOX_BG at
## 16,40), which its resize (0x63b420) sizes to (width - 32, height - 56);
## its title static sits at (10, 11), the width less 21 wide, 12 high
## (round 711's review, PartyInvitePopup).
##
## OURS (not read): where a box appears -- centred on the screen; that a box
## is not modal; the price a deposit or withdraw shows (OpenSRO's warehouse
## charges nothing, so 0 -- the original computes a fee from the item's
## reference +0xcc times the count, 0x6b1002, a field not mapped to an
## itemdata column); the bounds a typed count is held to (1 to the box's
## maximum).

enum Kind { BUY, SELL, BUY_BACK, DEPOSIT, WITHDRAW, GOLD_DEPOSIT, GOLD_WITHDRAW }

const MSGBOX_LAYOUT := "resinfo\\ifmessagebox.txt"
const CONFIRM_BUY_LAYOUT := "resinfo\\ifitemmallconfirmbuy.txt"
const CONFIRM_SLOT_LAYOUT := "resinfo\\ifitemmallconfirmslot.txt"
const FRAME := "interface\\messagebox\\msgbox2_window_"
const MONEY_ICON := "interface\\icon\\moneyicon.ddj"
## The names `config\define.txt` defines that these layouts test (READ, the
## file in Media.pk2; npc_gui.md §0).
const DEFINES := ["RENEWAL_SHOP_SYSTEM", "RESTORE_SOLDITEM_INSHOP", "EUROPE_SYSTEM", "UI_UPDATE_2009_FIRST"]

const STORE_CONFIRM_SIZE := Vector2(327, 175)
const STORE_MONEY_SIZE := Vector2(308, 148)
const CONFIRM_BUY_BASE := Vector2(327, 155)
## The price row: {0, 80, 327, 22} moved +20 for the gold kind; the window
## and its background grow by 22.
const CONFIRM_ROW_Y := 100
const CONFIRM_ROW_GROWTH := 22
const CONFIRM_BUTTON_X := [82, 170]
const CONFIRM_BUTTON_FROM_BOTTOM := 40
## The gold box's amount edit, moved and sized by the purpose.
const MONEY_EDIT_RECT := Rect2(121, 66, 121, 24)

## OK pressed: the count (or the gold amount) the box held.
signal confirmed(count: int)
## Cancel pressed.
signal cancelled

var kind: int = Kind.BUY
var count := 1
var max_count := 1
## The unit price the price field multiplies (buy, sell); -1 shows no price.
var unit_price := -1
## A fixed price shown whatever the count (deposit, withdraw).
var fixed_price := -1

var _builder: UiBuilder
var _count_edit: LineEdit
var _price_edit: LineEdit
var _root: Control

## Builds the box. `opts`: "icon" (Texture2D), "name" (String), "count",
## "max" (ints), "unit_price", "fixed_price" (ints). False if a layout is
## missing.
func build(builder: UiBuilder, box_kind: int, opts: Dictionary = {}) -> bool:
	_builder = builder
	kind = box_kind
	max_count = maxi(1, int(opts.get("max", 1)))
	count = clampi(int(opts.get("count", 1)), 1, max_count)
	unit_price = int(opts.get("unit_price", -1))
	fixed_price = int(opts.get("fixed_price", -1))
	mouse_filter = Control.MOUSE_FILTER_STOP
	var ok := false
	match kind:
		Kind.BUY:
			ok = _build_confirm_buy(opts)
		Kind.SELL, Kind.BUY_BACK, Kind.DEPOSIT, Kind.WITHDRAW:
			ok = _build_store_confirm(opts)
		Kind.GOLD_DEPOSIT, Kind.GOLD_WITHDRAW:
			ok = _build_store_money(opts)
	_refresh_price()
	return ok

# --- CItemMallConfirmBuy ------------------------------------------------------

func _build_confirm_buy(opts: Dictionary) -> bool:
	var box_size := CONFIRM_BUY_BASE + Vector2(0, CONFIRM_ROW_GROWTH)
	_set_box_size(box_size)
	_add_frame(box_size)
	var layout := _builder.load_layout(CONFIRM_BUY_LAYOUT, PackedStringArray(DEFINES), true) if _builder != null else null
	if layout == null:
		return false
	_root = _builder.build_section(layout, "Create")
	if _root == null:
		return false
	add_child(_root)
	var bg := _root.get_node_or_null("GDR_ITEMMALL_CONFIRM_BUY_BG") as Control
	if bg != null:
		var r := _authored(bg)
		_place(bg, Rect2(r.position, r.size + Vector2(0, CONFIRM_ROW_GROWTH)))
	var slot_layout := _builder.load_layout(CONFIRM_SLOT_LAYOUT, PackedStringArray(DEFINES), true)
	if slot_layout != null:
		var row := _builder.build_section(slot_layout, "Create")
		if row != null:
			row.name = "PriceRow"
			row.position = Vector2(0, CONFIRM_ROW_Y)
			row.size = Vector2(box_size.x, CONFIRM_ROW_GROWTH)
			add_child(row)
			_static_text(row.get_node_or_null("GDR_ITEMMALL_CONFIRM_STA_1"), _text("UIIT_CTL_WARENETWORK_RESULT_PRICE", "Price"))
			_static_text(row.get_node_or_null("GDR_ITEMMALL_CONFIRM_STA_2"), _text("UIIT_STT_GOLD", "Gold"))
			_price_edit = _readonly(row.get_node_or_null("GDR_ITEMMALL_CONFIRM_EDIT"))
			UiBuilder.settle_authored_rects(row)
	_icon(_root.get_node_or_null("GDR_ITEMMALL_CONFIRM_BUY_ITEM_ICON"), opts.get("icon"))
	var name_edit := _readonly(_root.get_node_or_null("GDR_ITEMMALL_CONFIRM_EDIT_ITEM_NAME"))
	if name_edit != null:
		name_edit.text = String(opts.get("name", ""))
	_count_edit = _root.get_node_or_null("GDR_ITEMMALL_CONFIRM_EDIT_COUNT") as LineEdit
	_wire_count(_count_edit)
	var stackable := max_count > 1
	_wire_spin(_root.get_node_or_null("GDR_ITEMMALL_CONFIRM_SPINBTN_UP"), 1, stackable)
	_wire_spin(_root.get_node_or_null("GDR_ITEMMALL_CONFIRM_SPINBTN_DOWN"), -1, stackable)
	var y := box_size.y - CONFIRM_BUTTON_FROM_BOTTOM
	_wire_ok(_root.get_node_or_null("GDR_ITEMMALL_CONFIRM_BTN_BUY"), Vector2(CONFIRM_BUTTON_X[0], y), _text("UIIT_STT_BUY", "Buy"))
	_wire_cancel(_root.get_node_or_null("GDR_ITEMMALL_CONFIRM_BTN_CANCEL"), Vector2(CONFIRM_BUTTON_X[1], y), _text("UIIS_CTL_CANCEL", "Cancel"))
	UiBuilder.settle_authored_rects(_root)
	return true

# --- CIFMessageBox mode 6, MsgBoxStoreConfirm ---------------------------------

func _build_store_confirm(opts: Dictionary) -> bool:
	_set_box_size(STORE_CONFIRM_SIZE)
	_add_frame(STORE_CONFIRM_SIZE)
	var layout := _message_box_base(STORE_CONFIRM_SIZE)
	if layout == null:
		return false
	_root = _builder.build_section(layout, "MsgBoxStoreConfirm")
	if _root == null:
		return false
	add_child(_root)
	_icon(_root.get_node_or_null("GDR_MBS_CONFIRM_BUY_ITEM_ICON"), opts.get("icon"))
	var name_edit := _readonly(_root.get_node_or_null("GDR_MBS_CONFIRM_EDIT_ITEM_NAME"))
	if name_edit != null:
		name_edit.text = String(opts.get("name", ""))
	_price_edit = _readonly(_root.get_node_or_null("GDR_MBS_CONFIRM_EDIT_PRICE"))
	_count_edit = _root.get_node_or_null("GDR_MBS_CONFIRM_EDIT_COUNT") as LineEdit
	_wire_count(_count_edit)
	var spins := kind == Kind.SELL
	_wire_spin(_root.get_node_or_null("GDR_MBS_CONFIRM_SPINBTN_UP"), 1, spins)
	_wire_spin(_root.get_node_or_null("GDR_MBS_CONFIRM_SPINBTN_DOWN"), -1, spins)
	if kind == Kind.WITHDRAW:
		for hidden in ["GDR_MBS_CONFIRM_STA_PRICE", "GDR_MBS_CONFIRM_EDIT_ITEM_NAME"]:
			var n := _root.get_node_or_null(hidden) as CanvasItem
			if n != null:
				n.visible = false
	var ok_key := "UIIT_STT_SELL"
	var ok_fallback := "Sell"
	match kind:
		Kind.BUY_BACK:
			ok_key = "UIIT_STT_RE_BUY_OBJECT"
			ok_fallback = "Buy back"
		Kind.DEPOSIT:
			ok_key = "UIIT_STT_DEPOSIT"
			ok_fallback = "Deposit"
		Kind.WITHDRAW:
			ok_key = "UIIT_STT_WITHDRAW"
			ok_fallback = "Take"
	_wire_ok(_root.get_node_or_null("GDR_MBS_CONFIRM_BTN_SELL"), Vector2(-1, -1), _text(ok_key, ok_fallback))
	_wire_cancel(_root.get_node_or_null("GDR_MBS_CONFIRM_BTN_CANCEL"), Vector2(-1, -1), _text("UIIT_CTL_CANCEL", "Cancel"))
	UiBuilder.settle_authored_rects(_root)
	return true

# --- CIFMessageBox mode 3, MsgBoxStoreMoney -----------------------------------

func _build_store_money(opts: Dictionary) -> bool:
	_set_box_size(STORE_MONEY_SIZE)
	_add_frame(STORE_MONEY_SIZE)
	var layout := _message_box_base(STORE_MONEY_SIZE)
	if layout == null:
		return false
	_root = _builder.build_section(layout, "MsgBoxStoreMoney")
	if _root == null:
		return false
	add_child(_root)
	var deposit := kind == Kind.GOLD_DEPOSIT
	var icon_tex: Texture2D = _builder.load_texture(MONEY_ICON) if _builder != null else null
	_icon(_root.get_node_or_null("GDR_MBS_STATIC_ICON"), icon_tex)
	_static_text(_root.get_node_or_null("GDR_MBS_STATIC_NAME1"),
		_text("UIIT_STT_DEPOSITMONEY", "Deposit") if deposit else _text("UIIT_STT_WITHDRAWMONEY", "Taken"))
	for hidden in ["GDR_MBS_STATIC_PRICET1", "GDR_MBS_STATIC_NAME2", "GDR_MBS_STATIC_PRICE"]:
		var n := _root.get_node_or_null(hidden) as CanvasItem
		if n != null:
			n.visible = false
	_count_edit = _root.get_node_or_null("GDR_MBS_EDIT_AMOUNT") as LineEdit
	if _count_edit != null:
		# The purpose strips the edit's own art (message_box.md): the ClientRect
		# insets stay, the picture goes.
		for style in ["normal", "focus", "read_only"]:
			var old := _count_edit.get_theme_stylebox(style)
			var sb := StyleBoxEmpty.new()
			if old != null:
				sb.content_margin_left = old.content_margin_left
				sb.content_margin_top = old.content_margin_top
				sb.content_margin_right = old.content_margin_right
				sb.content_margin_bottom = old.content_margin_bottom
			_count_edit.add_theme_stylebox_override(style, sb)
		_place(_count_edit, MONEY_EDIT_RECT)
	_wire_count(_count_edit)
	_wire_ok(_root.get_node_or_null("GDR_MBS_BTN_OK"), Vector2(-1, -1),
		_text("UIIT_STT_DEPOSIT", "Deposit") if deposit else _text("UIIT_STT_WITHDRAW", "Take"))
	_wire_cancel(_root.get_node_or_null("GDR_MBS_BTN_CANCEL"), Vector2(-1, -1), _text("UIIT_CTL_CANCEL", "Cancel"))
	UiBuilder.settle_authored_rects(_root)
	return true

# --- Shared parts -------------------------------------------------------------

func _set_box_size(s: Vector2) -> void:
	size = s
	custom_minimum_size = s

func _add_frame(s: Vector2) -> void:
	if _builder == null:
		return
	var def := UiLayoutParser.ControlDef.new()
	def.name = "Frame"
	def.type = "CIFFrame"
	def.ddj = FRAME
	def.rect = Rect2i(Vector2i.ZERO, Vector2i(s))
	var frame := _builder.build_control(def)
	if frame != null:
		frame.mouse_filter = Control.MOUSE_FILTER_PASS
		add_child(frame)

## ifmessagebox's "Create" (the background tile, sized by the resize) and the
## title static; the parsed layout, or null.
func _message_box_base(s: Vector2) -> UiLayoutParser.LayoutDef:
	if _builder == null:
		return null
	var layout := _builder.load_layout(MSGBOX_LAYOUT, PackedStringArray(DEFINES), true)
	if layout == null:
		return null
	if layout.sections.has("Create"):
		var base := _builder.build_section(layout, "Create")
		if base != null:
			base.name = "MsgBoxBase"
			add_child(base)
			var tile := base.get_node_or_null("GDR_MSGBOX_BG") as Control
			if tile != null:
				_place(tile, Rect2(_authored(tile).position, Vector2(s.x - 32, s.y - 56)))
			UiBuilder.settle_authored_rects(base)
	var def := UiLayoutParser.ControlDef.new()
	def.name = "Title"
	def.type = "CIFStatic"
	def.halign = 1
	def.rect = Rect2i(10, 11, int(s.x) - 21, 12)
	def.text = "UIIT_STT_CONFIRM_BOX"
	var title := _builder.build_control(def)
	if title != null:
		title.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(title)
		_builder.set_static_text(title, _text("UIIT_STT_CONFIRM_BOX", "Confirmation window"))
	return layout

func _authored(n: Control) -> Rect2:
	return n.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(n.position, n.size))

## Moves and sizes a built control, keeping the settling pass's record in step.
func _place(n: Control, r: Rect2) -> void:
	n.set_meta(UiBuilder.AUTHORED_RECT_META, r)
	n.custom_minimum_size = Vector2.ZERO
	n.position = r.position
	n.size = r.size

func _static_text(n: Node, text: String) -> void:
	if n is Control and _builder != null:
		_builder.set_static_text(n as Control, text)

## An edit the box fills itself: shown, not typed in.
func _readonly(n: Node) -> LineEdit:
	var e := n as LineEdit
	if e != null:
		e.editable = false
		# An uneditable LineEdit draws in Godot's grey; the box's fields keep
		# their layout colour.
		e.add_theme_color_override("font_uneditable_color", e.get_theme_color("font_color"))
		e.focus_mode = Control.FOCUS_NONE
		e.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return e

## The item's (or the gold's) icon drawn in the icon static's rect.
func _icon(holder: Node, tex) -> void:
	var c := holder as Control
	if c == null or not (tex is Texture2D):
		return
	var rect := TextureRect.new()
	rect.name = "Icon"
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.add_child(rect)

func _wire_count(edit: LineEdit) -> void:
	if edit == null:
		return
	edit.text = str(count)
	edit.text_changed.connect(_on_count_typed)

func _wire_spin(n: Node, step: int, shown: bool) -> void:
	var b := n as BaseButton
	if b == null:
		return
	b.visible = shown
	b.pressed.connect(func() -> void: set_count(count + step))

func _wire_ok(n: Node, at: Vector2, caption: String) -> void:
	var b := n as BaseButton
	if b == null:
		return
	if at.x >= 0:
		_place(b, Rect2(at, _authored(b).size))
	if caption != "" and _builder != null:
		_builder.set_button_text(b, caption)
	b.pressed.connect(_on_ok)

func _wire_cancel(n: Node, at: Vector2, caption: String) -> void:
	var b := n as BaseButton
	if b == null:
		return
	if at.x >= 0:
		_place(b, Rect2(at, _authored(b).size))
	if caption != "" and _builder != null:
		_builder.set_button_text(b, caption)
	b.pressed.connect(_on_cancel)

## Sets the count, held to 1..max, and redraws the count and the price.
func set_count(n: int) -> void:
	count = clampi(n, 1, max_count)
	if _count_edit != null and _count_edit.text != str(count):
		_count_edit.text = str(count)
		_count_edit.caret_column = _count_edit.text.length()
	_refresh_price()

func _on_count_typed(text: String) -> void:
	var digits := ""
	for ch in text:
		if ch >= "0" and ch <= "9":
			digits += ch
	if digits != text:
		_count_edit.text = digits
		_count_edit.caret_column = digits.length()
	if digits == "":
		return
	set_count(int(digits))

## The price the box shows: the unit times the count, or a fixed amount, as a
## plain number ("%I64d", 0x7c1ecd for buy and 0x6b096f for sell).
func price_text() -> String:
	if fixed_price >= 0:
		return str(fixed_price)
	if unit_price >= 0:
		return str(unit_price * count)
	return ""

func _refresh_price() -> void:
	if _price_edit != null:
		_price_edit.text = price_text()

func _on_ok() -> void:
	# The count as typed when it is still being edited.
	if _count_edit != null and _count_edit.text.is_valid_int():
		count = clampi(int(_count_edit.text), 1, max_count)
	confirmed.emit(count)
	close()

func _on_cancel() -> void:
	cancelled.emit()
	close()

## Hidden now, freed at the end of the frame: the box is an ancestor of the
## pressed button (round 631).
func close() -> void:
	if is_queued_for_deletion():
		return
	# Out of the name lookups at once, so a box opened again at once keeps
	# its plain name (HudPanels._close_confirm_box does the same).
	name = "%s_closing" % name
	visible = false
	queue_free()

## The button carrying `caption` (its ButtonLabel), for the QA hooks and tests.
func button(caption: String) -> BaseButton:
	for b in find_children("*", "BaseButton", true, false):
		var l := (b as Node).get_node_or_null("ButtonLabel") as Label
		if l != null and l.text == caption and (b as CanvasItem).is_visible_in_tree():
			return b as BaseButton
	return null

func _text(key: String, fallback: String) -> String:
	if _builder == null:
		return fallback
	var t := _builder.resolve_text(key)
	return fallback if t == "" or t == key else t
