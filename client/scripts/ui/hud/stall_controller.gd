extends RefCounted
class_name StallController

## Round 839 (lane S): CIFStall, the one stall window the owner and the
## visitors share, over HudPanels' "stall" window (GDR_STALL, ID 33,
## `resinfo\ifstall.txt` framed by ginterface's IFStall section). READ from
## sro_client.exe and the archive unless a line says otherwise;
## docs/protocol/stall.md has every address.
##
## - The window (c:0x79be20(1), CIFStall::Create c:0x6bb5a0): 467x490,
##   centred and then moved (0, -60), created hidden and shown only by
##   0xB0B1 {1} or 0xB0B3 {1}; the owner when +0x7fc is this player
##   (c:0x6b97e0).
## - Its ten slots (CIFStallSlot, `resinfo\ifstallslot.txt`, 208x44 on
##   `interface\stall\stl_slot_02.ddj`) in GDR_STALL_DISPLAY two columns by
##   five rows at (6 + 206 c, 6 + 41 r) (CIFScrollManager c:0x812970). An
##   occupied slot shows its icon, name (centred), "%d Unit" and the price
##   with ',' every three digits and " Gold", coloured by its amount
##   (c:0x5d3df0); an empty one hides them on `stl_slot_05.ddj`.
## - The one tab, "Items to sell" (UIIT_STT_SELL_GOODS), built in code at
##   (28, 86) 80x24 on `ifcommon\com_long_tab_on.ddj` (c:0x6bb9c9..).
## - The state (c:0x6bab20): open -- `stl_condition_icon_01.ddj`,
##   UIIT_STT_TRADING_NOW, the button UIIT_STT_END_STALL, the title button
##   off, an occupied slot's modify button off; modifying -- `_02`,
##   UIIT_STT_STALL_MODIFYING, UIIT_STT_START_STALL, and for the owner the
##   title and modify buttons on; a visitor's slot icons at alpha 0x80.
## - The owner (c:0x6baeb0): buttons 4, 5, 6 on; a visitor: off.
## - Buttons: 4 the state (0x70BA type 5), 5 the title box (type 7 once
##   shown), 6 the greeting box (type 6), a slot's modify button the price
##   box (type 1); X: the owner 0x70B2, a visitor 0x70B5 (vslot_043
##   c:0x6b96a0). The window goes on the answer (0xB0B2 / 0xB0B5 / 0x30B9).
## - A bag item put down on an empty slot by the owner while modifying
##   (c:0x6b9be0): CanTrade (0x183a) and the awakened spirit (0x18fa) before
##   the box; the item's group from `fmntidgroupmapdata.txt` (c:0x938370;
##   none: category 10 0x3c42, nothing sent), then the register box, whose
##   OK sends type 2. An own slot put down on the bag: type 3 (c:0x6b5eff).
##   A visitor's slot put down on the bag: the buy box, whose OK sends
##   0x70B4 (c:0x6b2070).
## - 0x30B7 kind 3: "[buyer]bought item [item]." in the window's chat, the
##   list again; the owner's bag slot unmarked and, when no slot is left,
##   0x70B2 sent by the client itself (c:0x87a6f0).
## - The chat module (`resinfo\ifchatmodule.txt`, chat type 9): its lines
##   from 0x3026 type 9; its input sends type 9; its user list the owner, the
##   visitors, then this player (c:0x873ff0).
##
## OURS, disclosed: after a sale this client asks the server for its bag list
## (as the exchange does) where the original moves the stack in its own copy
## (0xB0B4 -> c:0x6bc0c0; 0x30B7 kind 3 for the owner). The name filter the
## title passes (c:0x8c3f10's two word lists, 0x3c38) is not run: OpenSRO's
## server takes any 1..64 bytes. The 0x3c42 refusal is the original's own for
## an item its group table does not name.

const WINDOW := "stall"
const LAYOUT := "resinfo\\ifstall.txt"
const SLOT_LAYOUT := "resinfo\\ifstallslot.txt"
const CHAT_LAYOUT := "resinfo\\ifchatmodule.txt"
const SLOT_ART := "interface\\stall\\stl_slot_02.ddj"
const SLOT_EMPTY_ART := "interface\\stall\\stl_slot_05.ddj"
const ICON_OPEN := "interface\\stall\\stl_condition_icon_01.ddj"
const ICON_MODIFY := "interface\\stall\\stl_condition_icon_02.ddj"
const TAB_ON := "interface\\ifcommon\\com_long_tab_on.ddj"
const TID_GROUP_TABLE := "server_dep\\silkroad\\textdata\\fmntidgroupmapdata.txt"
const SLOT_SIZE := Vector2(208, 44)
const SLOT_ORIGIN := Vector2(6, 6)
const SLOT_PITCH := Vector2(206, 41)
const TAB_RECT := Rect2(28, 86, 80, 24)
## The window's move after its centring (c:0x79be96).
const OPEN_SHIFT := Vector2(0, -60)
## The chat module's lines (0x778a10's colour for the state lines, 0xffdbc99b).
const STATE_LINE_COLOUR := Color8(0xdb, 0xc9, 0x9b)
const DIM_ALPHA := 128.0 / 255.0
## The send's net u16 (c:0x6b9940 and the others): 0 outside the stall
## network.
const NET := 0

## The HudPanels this drives.
var panels
## NetClient, or a stand-in a test gives.
var net = null

## The window is in use (shown or waiting for its answer).
var active := false
var owner_id := -1
var own := false
var open := false
var value4 := 0
var title := ""
var greeting := ""
## slot -> StallNet.Entry.
var entries := {}
## The participants' names in the user list: the owner, the visitors, then
## this player.
var users: Array = []
var user_ids: Array = []
## The last greeting this player set (+0x82c / +0x830), kept for the next
## stall.
var saved_greeting := ""
## A box is up (+0x7bc).
var box_open := false
## The packed TID -> group table, read once.
var _tid_groups = null

func _init(hud_panels) -> void:
	panels = hud_panels

func _net():
	if net != null:
		return net
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("/root/NetClient") if tree != null else null

func window():
	return panels._windows.get(WINDOW) if panels != null else null

func node(control_name: String) -> Control:
	var w = window()
	return w.node(control_name) as Control if w != null else null

func shown() -> bool:
	var w = window()
	return w != null and is_instance_valid(w) and w.is_visible_in_tree()

func _own_uid() -> int:
	var n = _net()
	return int(n.own_character_id) & 0xffffffff if n != null and int(n.own_character_id) >= 0 else -1

func _own_name() -> String:
	var n = _net()
	return String(n.current_character_name) if n != null else ""

func _text(key: String, fallback: String) -> String:
	return String(panels._resolve_ui(key, fallback)) if panels != null else fallback

# --- starting a stall -----------------------------------------------------------

## The action window's Stall (1009, c:0x793b00 -> 0x793ea6) after its gates
## (World3D: the job suit, the alchemy window): the avatar stall's question
## first when a BFI1 decoration is held (c:0x793fac: "Establish as an avatar
## stall?"; Yes sends 0x7160 for each, c:0x803e00), then the title box.
func start() -> String:
	if active or box_open:
		return "busy"
	var n = _net()
	var grants: Dictionary = n.buff_items if n != null and n.get("buff_items") is Dictionary else {}
	if not grants.is_empty() and panels != null and panels.has_method("open_stall_avatar_question"):
		box_open = true
		var answered := func(yes: bool) -> void:
			box_open = false
			if yes:
				for g in grants.values():
					n.stall_avatar(int((g as Dictionary).get("key", 0)), int((g as Dictionary).get("decoration", 0)))
			_reset_for_new()
			open_title_box()
		panels.open_stall_avatar_question(answered)
		return "avatar question"
	_reset_for_new()
	open_title_box()
	return "title box"

## c:0x6bafb0 then 0x6baeb0(self): a fresh window for this player's stall.
func _reset_for_new() -> void:
	owner_id = _own_uid()
	own = true
	open = false
	value4 = 0
	title = ""
	greeting = ""
	entries = {}
	users = []
	user_ids = []

## The title box (purpose 0): the old title without its brackets, else
## UIIT_STT_STALL_DEFAULT_TITLE with the name ("[%s]'s stall.").
func open_title_box() -> void:
	var prefill := title
	if prefill == "":
		var fmt := _text("UIIT_STT_STALL_DEFAULT_TITLE", "[%s]'s stall.")
		prefill = fmt.replace("%s", _own_name()) if fmt.count("%s") == 1 else fmt
	box_open = true
	var on_ok := func(t: String) -> void:
		box_open = false
		title_entered(t)
	var on_cancel := func() -> void:
		box_open = false
		# Cancel before the window is shown ends the stall (0x79be20(0)).
		if not shown():
			active = false
	panels.open_stall_text_box(false, prefill, on_ok, on_cancel)

## The title box's OK (c:0x6bb0d0 kind 1): before the window is shown, 0x70B1
## and at once the greeting (type 6, the saved one or
## UIIT_STT_STALL_DEFAULT_OWNERMSG); once shown, type 7.
func title_entered(t: String) -> void:
	t = t.strip_edges()
	if t == "":
		return
	var n = _net()
	if not shown():
		active = true
		title = t
		n.stall_open(t)
		var g := saved_greeting
		if g == "":
			var fmt := _text("UIIT_STT_STALL_DEFAULT_OWNERMSG", "Welcome to [%s]'s stall.")
			g = fmt.replace("%s", _own_name()) if fmt.count("%s") == 1 else fmt
		n.stall_update(StallNet.encode_greeting(g))
	else:
		n.stall_update(StallNet.encode_rename(t))

func open_greeting_box() -> void:
	if not own or box_open:
		return
	box_open = true
	var on_ok := func(t: String) -> void:
		box_open = false
		saved_greeting = t
		_net().stall_update(StallNet.encode_greeting(t))
	var on_cancel := func() -> void:
		box_open = false
	panels.open_stall_text_box(true, greeting, on_ok, on_cancel)

# --- the server's answers ---------------------------------------------------------

## 0xB0B1 (c:0x872040): {1} the own name in the list, modifying, the window
## shown; else the code.
func on_open_result(code: int) -> void:
	if code != 1:
		active = false
		panels.stall_code_message(code)
		panels.close_stall_window()
		return
	active = true
	owner_id = _own_uid()
	own = true
	users = [_own_name()]
	user_ids = [owner_id]
	panels.open_stall_window()
	_draw_all()

## 0xB0B2 (c:0x8720f0): the window goes whatever the answer.
func on_close_result(code: int) -> void:
	if code != 1:
		panels.stall_code_message(code)
	_closed()

## 0xB0B5 (c:0x872450).
func on_leave_result(code: int) -> void:
	if code != 1:
		panels.stall_code_message(code)
	_closed()

func _closed() -> void:
	active = false
	open = false
	entries = {}
	panels.close_stall_window()
	panels.redraw_bag()

## 0xB0B3 (c:0x873ff0): a visitor's window filled and shown.
func on_entered(d: Dictionary) -> void:
	if int(d.get("code", -1)) != 1:
		panels.stall_code_message(int(d.get("code", 0)))
		return
	active = true
	owner_id = int(d["owner"])
	own = owner_id == _own_uid()
	greeting = String(d["greeting"])
	open = bool(d["open"])
	value4 = int(d["value4"])
	entries = d["entries"]
	var n = _net()
	var st: Dictionary = n.stalls.get(owner_id, {}) if n != null else {}
	title = String(st.get("name", ""))
	users = [panels.stall_player_name(owner_id)]
	user_ids = [owner_id]
	for v in d["visitors"]:
		users.append(panels.stall_player_name(int(v)))
		user_ids.append(int(v))
	users.append(_own_name())
	user_ids.append(_own_uid())
	panels.open_stall_window()
	_draw_all()

## 0xB0BA (c:0x878230).
func on_updated(d: Dictionary) -> void:
	if int(d.get("code", -1)) != 1:
		panels.stall_code_message(int(d.get("code", 0)))
		return
	if not active:
		return
	match int(d["type"]):
		StallNet.UPDATE_PRICE:
			var e: StallNet.Entry = entries.get(int(d["slot"]))
			if e != null:
				e.count = int(d["count"])
				e.price = int(d["price"])
		StallNet.UPDATE_ADD, StallNet.UPDATE_REMOVE:
			entries = d["entries"]
			panels.redraw_bag()
		StallNet.UPDATE_VALUE4:
			value4 = int(d["value"])
		StallNet.UPDATE_OPEN:
			open = bool(d["open"])
			# The state line in the window's own chat (c:0x878486..0x8784e0).
			chat_line("", _text("UIIT_STT_STALL_CONDITION_START" if open else "UIIT_STT_STALL_CONDITION_END", ""),
				STATE_LINE_COLOUR)
		StallNet.UPDATE_GREETING:
			greeting = String(d["greeting"])
		StallNet.UPDATE_RENAME:
			pass
	_draw_all()

## 0x30B7 (c:0x87a260).
func on_event(d: Dictionary) -> void:
	if not active:
		return
	match int(d.get("kind", 0)):
		StallNet.EVENT_LEFT:
			var i := user_ids.find(int(d["uid"]))
			if i > 0:
				user_ids.remove_at(i)
				users.remove_at(i)
		StallNet.EVENT_CAME:
			var at := maxi(1, user_ids.size() - (0 if own else 1))
			user_ids.insert(at, int(d["uid"]))
			users.insert(at, panels.stall_player_name(int(d["uid"])))
		StallNet.EVENT_SOLD, 4:
			var e: StallNet.Entry = entries.get(int(d["slot"]))
			var item_name := ""
			if e != null:
				item_name = panels.item_name(e.item.ref_item_id)
			var fmt := _text("UIIT_MSG_STREET_STORE_SELL_COMMODITY", "[%s]bought item [%s].")
			var line := fmt
			if fmt.count("%s") == 2:
				line = fmt % [String(d["buyer"]), item_name]
			chat_line("", line, Color.WHITE)
			entries = d["entries"]
			if own:
				panels.refresh_bag_after_exchange()
				panels.redraw_bag()
				# Every slot sold: the owner's client closes the stall itself
				# (c:0x87a6f0..).
				if entries.is_empty():
					_net().stall_close()
	_draw_all()

## 0x30B9 for the stall this window shows (c:0x8721b0): modifying, closed.
func on_gone(d: Dictionary) -> void:
	if active and int(d.get("owner", -1)) == owner_id:
		var reason := int(d.get("reason", 0))
		if not own and reason != 0:
			panels.stall_code_message(reason)
		_closed()

## 0x30BB: the window's title when it is this stall.
func on_renamed(d: Dictionary) -> void:
	if active and int(d.get("owner", -1)) == owner_id:
		title = String(d["name"])
		_draw_all()

## 0xB0B4 (c:0x872500): {1, slot} -- the item is the buyer's now (OURS: the
## bag list asked again); else the code.
func on_buy_result(d: Dictionary) -> void:
	if int(d.get("code", -1)) != 1:
		panels.stall_code_message(int(d.get("code", 0)))
		return
	panels.refresh_bag_after_exchange()

# --- the player's actions ---------------------------------------------------------

## X (vslot_043 c:0x6b96a0): the owner 0x70B2, a visitor 0x70B5.
func press_close() -> void:
	if not active:
		panels.close_stall_window()
		return
	if own:
		_net().stall_close()
	else:
		_net().stall_leave()

## Button 4 (c:0x6b9940).
func press_state() -> void:
	if active and own:
		_net().stall_update(StallNet.encode_open_state(not open, NET))

## Button 5 (c:0x6ba8f0).
func press_title() -> void:
	if active and own and not open and not box_open:
		open_title_box()

## Button 6 (c:0x6ba910).
func press_greeting() -> void:
	if active and own:
		open_greeting_box()

## A slot's modify button (c:0x6ba930): the owner, modifying, no box, an
## occupied slot -- the price box.
func press_modify(slot: int) -> void:
	if not active or not own or open or box_open or not entries.has(slot):
		return
	var e: StallNet.Entry = entries[slot]
	box_open = true
	var on_ok := func(count: int, price: int) -> void:
		box_open = false
		_net().stall_update(StallNet.encode_price(slot, count, price, NET))
	var box = panels.open_stall_box(StoreMessageBox.Kind.STALL_PRICE, e.item.ref_item_id, e.count, e.price, on_ok)
	if box == null:
		box_open = false
	else:
		box.cancelled.connect(func() -> void: box_open = false)

## The empty slot under `at` (global), or the first free one when `at` is
## over the display but not over a slot; -1 when it is not over the display.
func slot_at(at: Vector2) -> int:
	var display := node("GDR_STALL_DISPLAY")
	if display == null or not display.get_global_rect().has_point(at):
		return -1
	for i in StallNet.SLOTS:
		var s := display.get_node_or_null("StallSlot%d" % i) as Control
		if s != null and s.get_global_rect().has_point(at):
			return i
	return -2

## A bag item put down on the window (vslot_028 c:0x6b9ec0 -> 0x6b9be0).
func drop_from_bag(bag_slot: int, item_id: int, qty: int, at: Vector2) -> String:
	if not active or not own or open:
		return "not modifying"
	var slot := slot_at(at)
	if slot < 0 or entries.has(slot):
		return "not an empty slot"
	var refusal: int = panels.exchange_item_refusal(bag_slot, item_id)
	if refusal != 0:
		panels.exchange_code_message(refusal)
		return "refused 0x%x" % refusal
	var group := tid_group(item_id)
	if group == 0:
		panels.stall_code_message(0x3c42)
		return "no group"
	box_open = true
	var on_ok := func(count: int, price: int) -> void:
		box_open = false
		_net().stall_update(StallNet.encode_add(slot, bag_slot, count, price, group, NET))
	var box = panels.open_stall_box(StoreMessageBox.Kind.STALL_REGISTER, item_id, qty, 1, on_ok)
	if box == null:
		box_open = false
		return "no box"
	box.cancelled.connect(func() -> void: box_open = false)
	return "register box for slot %d" % slot

## A stall slot put down on the bag: the owner takes it back (type 3), a
## visitor gets the buy box.
func slot_to_bag(slot: int) -> String:
	if not active or not entries.has(slot):
		return "no item"
	if own:
		if open:
			return "open"
		_net().stall_update(StallNet.encode_remove(slot, NET))
		return "remove"
	return open_buy_box(slot)

func open_buy_box(slot: int) -> String:
	if not active or own or not entries.has(slot) or box_open:
		return "no"
	var e: StallNet.Entry = entries[slot]
	box_open = true
	var on_ok := func(_count: int, _price: int) -> void:
		box_open = false
		_net().stall_buy(slot)
	var box = panels.open_stall_box(StoreMessageBox.Kind.STALL_BUY, e.item.ref_item_id, e.count, e.price, on_ok)
	if box == null:
		box_open = false
		return "no box"
	box.cancelled.connect(func() -> void: box_open = false)
	return "buy box for slot %d" % slot

## The chat module's input (type 9).
func send_chat(text: String) -> void:
	text = text.strip_edges()
	if text == "" or not active:
		return
	_net().send_chat(StallNet.CHAT_TYPE, 0, "", text)

## A line in the window's chat module.
func chat_line(sender: String, text: String, colour: Color = Color.WHITE) -> void:
	if text == "":
		return
	panels.stall_chat_add(("%s: %s" % [sender, text]) if sender != "" else text, colour)

# --- the group table --------------------------------------------------------------

## The item's group (c:0x938370: fmntidgroupmapdata's TidGroupID for its
## packed TID with the low two bits cleared), 0 when the table has none.
func tid_group(item_id: int) -> int:
	if _tid_groups == null:
		_tid_groups = panels.stall_tid_groups() if panels != null and panels.has_method("stall_tid_groups") else {}
	var types: Array = panels.item_type_ids(item_id) if panels != null else []
	return int((_tid_groups as Dictionary).get(StallNet.packed_tid(types), 0))

## The bag slots in this player's own stall (0x6b3f00(slot, 1)).
func listed_bag_slot(slot: int) -> bool:
	if not active or not own:
		return false
	for e in entries.values():
		if (e as StallNet.Entry).bag_slot == slot:
			return true
	return false

## The item a slot shows (tooltips), or null.
func instance_at(slot: int) -> Object:
	return (entries[slot] as StallNet.Entry).item if entries.has(slot) else null

# --- drawing ------------------------------------------------------------------------

func _draw_all() -> void:
	if panels != null and panels.has_method("stall_draw"):
		panels.stall_draw(self)
