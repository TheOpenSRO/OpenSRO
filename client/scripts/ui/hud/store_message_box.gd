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
## hides IDs 8, 9 and 2 (0x63ef90..0x63f00a; message_box.md). The openers
## (deposit 0x6b2800, withdraw 0x6b29f0) then put `icon\mini_gold_icon.ddj`
## on the icon over the purpose's (which is not in Media.pk2), hide "Unit"
## (ID 4), prefill the amount "0", enforce no minimum, cap it at min(the
## balance, 1,000,000,000) and focus it (round 726 review).
##
## A CIFMessageBox also builds its file's "Create" first (GDR_MSGBOX_BG at
## 16,40), which its resize (0x63b420) sizes to (width - 32, height - 56);
## its title static sits at (10, 11), the width less 21 wide, 12 high
## (round 711's review, PartyInvitePopup).
##
## **Where a box appears** (READ). Every inventory box is a new one: each
## open destroys the last (`FUN_006aef20` -> 0xba0e40) and creates it again
## at 308x148 (`FUN_006af530`), which `FUN_00798b70` (0x6af59a) moves to (screen width
## / 2 - 308 / 2, screen height / 2 - 148 / 2) -- integer halves of the
## rect's (x, y, w, h) at +0x40, the size SetSize 0xb91a40 writes to
## +0x48/+0x4c. The purpose's resize to 327x175 (vslot 21 -> 0x652970)
## keeps that corner, so a store/warehouse box sits off-centre by the
## difference. CItemMallConfirmBuy's Create (0x7c5650) adds its rows
## (0x7c3f70) and then centres itself (0x798b70 at 0x7c5d3c, after 0x7c3f70 at 0x7c5c63) at its own
## final size. `screen_position` computes both.
##
## The deposit fee is the item reference's +0xcc times the count (0x6b1002,
## READ), which round 728 takes from itemdata's KeepingFee, column 30
## (INFERRED from the schema's name).
##
## OURS (not read): that a box is not modal; an item count typed below 1 is
## held to 1.

enum Kind { BUY, SELL, BUY_BACK, DEPOSIT, WITHDRAW, GOLD_DEPOSIT, GOLD_WITHDRAW, DIVIDE }

const MSGBOX_LAYOUT := "resinfo\\ifmessagebox.txt"
const CONFIRM_BUY_LAYOUT := "resinfo\\ifitemmallconfirmbuy.txt"
const CONFIRM_SLOT_LAYOUT := "resinfo\\ifitemmallconfirmslot.txt"
const FRAME := "interface\\messagebox\\msgbox2_window_"
## The icon the gold purposes set (0x63eedd), which both gold openers then
## replace with the gold coin (0x6b299c..0x6b29d5 / 0x6b2b68, `push 0xda76f8`,
## the icon's vslot 0x34): only the second is ever seen (round 726 review).
const MONEY_ICON := "interface\\icon\\moneyicon.ddj"
const GOLD_ICON := "icon\\mini_gold_icon.ddj"
## The gold boxes' cap (0x3b9aca00): an amount is at most min(the balance,
## this), deposit 0x6b295b..0x6b298a, withdraw 0x6b2bb6..0x6b2bf5 (READ).
const GOLD_CAP := 1000000000
## The names `config\define.txt` defines that these layouts test (READ, the
## file in Media.pk2; npc_gui.md §0).
const DEFINES := ["RENEWAL_SHOP_SYSTEM", "RESTORE_SOLDITEM_INSHOP", "EUROPE_SYSTEM", "UI_UPDATE_2009_FIRST"]

## The size the inventory creates its message box at (0x134 x 0x94), which
## places it (see above).
const INVENTORY_BOX_CREATE_SIZE := Vector2i(308, 148)
const STORE_CONFIRM_SIZE := Vector2(327, 175)
const STORE_MONEY_SIZE := Vector2(308, 148)
## Mode 5's own size (0x6400c8: push 0xb7, push 0x12c, slot 0x54; READ).
const DIVIDE_SIZE := Vector2(300, 183)
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
## The least the count may be: 1, except the gold boxes', whose edit enforces
## no minimum (`0x634ff0(0)`, 0x6b2b31) and opens at "0" (READ).
var min_count := 1
var max_count := 1
## The store's tax rate the sell box's price takes off (0x63bd60:
## P - ftol(P * rate), rate = the tax line's short / 100.0, set by the sell
## fill at 0x6b0871..0x6b0896 when 0x703fc0() holds). 0 until the store's
## tax data reaches the client (OPEN, lane C: npc_gui.md OPEN 1).
var tax_rate := 0.0
## The unit price the price field multiplies (buy, sell); -1 shows no price.
var unit_price := -1
## A fixed price shown whatever the count (deposit, withdraw).
var fixed_price := -1

var _builder: UiBuilder
var _count_edit: LineEdit
var _price_edit: LineEdit
var _root: Control

## Builds the box. `opts`: "icon" (Texture2D), "name" (String), "count",
## "min", "max" (ints), "unit_price", "fixed_price" (ints), "stackable"
## (bool, deposit/withdraw), "tax_rate" (float, sell). False if a layout is
## missing.
func build(builder: UiBuilder, box_kind: int, opts: Dictionary = {}) -> bool:
	_builder = builder
	kind = box_kind
	min_count = int(opts.get("min", 1))
	max_count = maxi(min_count, int(opts.get("max", 1)))
	count = clampi(int(opts.get("count", 1)), min_count, max_count)
	tax_rate = float(opts.get("tax_rate", 0.0))
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
		Kind.DIVIDE:
			ok = _build_divide(opts)
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
	# An item that does not stack: the deposit and withdraw fills (0x6b0e90,
	# 0x6b15b0) call 0x63bc80(3), which hides the count (80, +0x888), its
	# "Quantity" (78, +0x88c), its black square (75, +0x890) and tile (77,
	# +0x894) -- map 0x640300. The sell fill does not (READ, round 726 review).
	if (kind == Kind.DEPOSIT or kind == Kind.WITHDRAW) and not bool(opts.get("stackable", true)):
		for hidden in ["GDR_MBS_CONFIRM_EDIT_COUNT", "GDR_MBS_CONFIRM_STA_COUNT",
				"GDR_MBS_CONFIRM_BUY_BLACKSQUARE_6", "GDR_MBS_CONFIRM_EDIT_BG6"]:
			var g := _root.get_node_or_null(hidden) as CanvasItem
			if g != null:
				g.visible = false
	# Buy back, deposit and withdraw OR style 0x81 into the count edit
	# (0x635150(0x81): 0x63ed10, 0x63ed90, 0x63ee1b): 0x01 lets only the
	# digits through, 0x80 drops Backspace (CIFEdit WM_CHAR 0x637290,
	# 0x63748c). Sell and withdraw focus it (0x635030(1)); deposit leaves it
	# unfocused (0x635030(0)). READ; whether the deposit count can be changed
	# at all is not settled.
	if kind == Kind.BUY_BACK or kind == Kind.DEPOSIT or kind == Kind.WITHDRAW:
		_drop_backspace(_count_edit)
	if kind == Kind.SELL or kind == Kind.WITHDRAW:
		_focus_later(_count_edit)
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
	var icon_tex: Texture2D = _builder.load_texture(GOLD_ICON) if _builder != null else null
	_icon(_root.get_node_or_null("GDR_MBS_STATIC_ICON"), icon_tex)
	_static_text(_root.get_node_or_null("GDR_MBS_STATIC_NAME1"),
		_text("UIIT_STT_DEPOSITMONEY", "Deposit") if deposit else _text("UIIT_STT_WITHDRAWMONEY", "Taken"))
	# 8, 9 and 2 by the purpose; 4, "Unit" (+0x88c), by both openers right
	# after 0x63bc80(2) (0x6b28a8..0x6b28b3, READ round 726 review).
	for hidden in ["GDR_MBS_STATIC_PRICET1", "GDR_MBS_STATIC_NAME2", "GDR_MBS_STATIC_PRICE", "GDR_MBS_STATIC_AMOUNT"]:
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
				sb.content_margin_right = old.content_margin_right
			# The ClientRect's 5 + 5 vertical insets plus Godot's line height
			# would hold the edit above the 24 the purpose sizes it to; with
			# them dropped Godot centres the line in the 24, where the
			# insets put it (INFERRED: CIFEdit draws at the inset's top).
			_count_edit.add_theme_stylebox_override(style, sb)
		_place(_count_edit, MONEY_EDIT_RECT)
	_wire_count(_count_edit)
	# Both openers focus the amount (0x635030(1), 0x6b2afa).
	_focus_later(_count_edit)
	_wire_ok(_root.get_node_or_null("GDR_MBS_BTN_OK"), Vector2(-1, -1),
		_text("UIIT_STT_DEPOSIT", "Deposit") if deposit else _text("UIIT_STT_WITHDRAW", "Take"))
	_wire_cancel(_root.get_node_or_null("GDR_MBS_BTN_CANCEL"), Vector2(-1, -1), _text("UIIT_CTL_CANCEL", "Cancel"))
	UiBuilder.settle_authored_rects(_root)
	return true

# --- CIFMessageBox mode 5, MsgBoxDivideCount (round 728) ---------------------
## Splitting a stack, opened by Shift+click on a bag stack (0x681903 ->
## 0x6b3fa0, READ). Mode 5 (0x640020) builds the section at 300x183, titles
## the box `UIIT_STT_INPUT_BOX` ("Input window") and maps 11 +0x814 the icon,
## 12 +0x818 the name board, 15 +0x904 the retained count, 17 +0x900 the
## edit, 220 +0x800 OK, 221 +0x804 Cancel. The fill (0x6b3fa0), only for a
## stackable item (0x538410) of more than one: the icon, the retained count
## (+0x904, the slot's whole stack), the edit's style 3 (0x635150), its text
## "1" (0xd87bdc), focus (0x635030(1)), no minimum (0x634ff0(0)), its maximum
## the stack - 1 (0x634f20), the name on the board. OK (0x63d920) reads the
## edit as a 64-bit number and posts 0x8076 flagged 0 when it is empty or 0
## (READ); the owner then sends nothing (c:0x6b62d0 sends only on 1, READ).
## `opts`: "icon", "name", "stack" (the slot's count).
func _build_divide(opts: Dictionary) -> bool:
	_set_box_size(DIVIDE_SIZE)
	_add_frame(DIVIDE_SIZE)
	var layout := _message_box_base(DIVIDE_SIZE, "UIIT_STT_INPUT_BOX", "Input window")
	if layout == null:
		return false
	_root = _builder.build_section(layout, "MsgBoxDivideCount")
	if _root == null:
		return false
	add_child(_root)
	_icon(_root.get_node_or_null("GDR_MBDC_STATIC_ICON"), opts.get("icon"))
	_static_text(_root.get_node_or_null("GDR_MBDC_STATIC_NAMEBOARD"), String(opts.get("name", "")))
	_static_text(_root.get_node_or_null("GDR_MBDC_STATIC_CURRENT_AMOUNT"), str(int(opts.get("stack", 0))))
	_count_edit = _root.get_node_or_null("GDR_MBDC_STATIC_DIVIDE_AMOUNT_EDIT") as LineEdit
	if _count_edit != null:
		# Held to its authored 42 px (223,102,42,24): Godot's LineEdit grows to
		# its theme's minimum_character_width, which drew it ~53 wide against
		# split_z4uFWIL.png's 38 between borders (round 728 review F8).
		_count_edit.add_theme_constant_override("minimum_character_width", 0)
		_place(_count_edit, _authored(_count_edit))
		_count_edit.custom_minimum_size = _authored(_count_edit).size
	_wire_count(_count_edit)
	_focus_later(_count_edit)
	_wire_ok(_root.get_node_or_null("GDR_MBDC_BTN_OK"), Vector2(-1, -1), "")
	_wire_cancel(_root.get_node_or_null("GDR_MBDC_BTN_CANCEL"), Vector2(-1, -1), "")
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
func _message_box_base(s: Vector2, title_key: String = "UIIT_STT_CONFIRM_BOX",
		title_fallback: String = "Confirmation window") -> UiLayoutParser.LayoutDef:
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
	def.text = title_key
	var title := _builder.build_control(def)
	if title != null:
		title.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(title)
		_builder.set_static_text(title, _text(title_key, title_fallback))
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

## CIFEdit style 0x80: Backspace does nothing in this edit.
func _drop_backspace(edit: LineEdit) -> void:
	if edit == null:
		return
	edit.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventKey and (ev as InputEventKey).keycode == KEY_BACKSPACE:
			edit.accept_event())

## Focus on the edit once the box is in the tree and shown (0x635030(1)),
## the caret after the text (OURS: where CIFEdit puts it is not read; Godot's
## would put typed digits in front of the "0" prefill -- live run 4 typed
## 1000 and got 10000).
func _focus_later(edit: LineEdit) -> void:
	if edit == null:
		return
	var grab := func() -> void:
		if is_instance_valid(edit) and edit.is_visible_in_tree() and edit.editable:
			edit.grab_focus()
			edit.caret_column = edit.text.length()
	edit.ready.connect(func() -> void: grab.call_deferred(), CONNECT_ONE_SHOT)

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

## Sets the count, held to min..max, and redraws the count and the price.
func set_count(n: int) -> void:
	count = clampi(n, min_count, max_count)
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

## The price the box shows, as plain digits (no grouping: 0x64db50 groups
## only on a non-zero fourth argument, and every store caller pushes 0):
## - buy: count x unit ("%I64d", CIFItemMallConfirmSlot 0x7c1a80);
## - sell: P = count x unit, less ftol(P x the tax rate) (CIFMessageBox
##   vslot_012 0x63d340 -> 0x63bd60 for purposes 1 and 2);
## - deposit: max(1, the fee x the count) (vslot_012 for purpose 5,
##   0x63d676..0x63d698; the fee a unit is +0xcc, 0x6b1002);
## - buy back: count x unit, the sell price (the fill's +0xb8, READ);
## - withdraw: the fill's "%d" 0.
func price_text() -> String:
	if fixed_price >= 0:
		return str(maxi(1, fixed_price)) if kind == Kind.DEPOSIT else str(fixed_price)
	if unit_price >= 0:
		var p := unit_price * count
		if kind == Kind.SELL:
			p -= int(p * tax_rate)
		elif kind == Kind.DEPOSIT:
			p = maxi(1, p)
		return str(p)
	return ""

func _refresh_price() -> void:
	if _price_edit != null:
		_price_edit.text = price_text()

func _on_ok() -> void:
	# The count as typed when it is still being edited.
	if _count_edit != null and _count_edit.text.is_valid_int():
		count = clampi(int(_count_edit.text), min_count, max_count)
	elif kind == Kind.DIVIDE and _count_edit != null:
		count = 0  # an empty edit posts the 0 flag (0x63d920, READ)
	confirmed.emit(count)
	close()

func _on_cancel() -> void:
	cancelled.emit()
	close()

## Where the original puts this box on a `screen`-sized display (READ, see
## the top): ConfirmBuy centred at its own size, every other box at the
## corner the inventory's 308x148 creation was centred to. C's integer
## halves, as 0x798b70 computes them.
func screen_position(screen: Vector2) -> Vector2:
	var sw := int(screen.x)
	var sh := int(screen.y)
	var placed := Vector2i(int(size.x), int(size.y)) if kind == Kind.BUY else INVENTORY_BOX_CREATE_SIZE
	return Vector2(sw / 2 - placed.x / 2, sh / 2 - placed.y / 2)

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
