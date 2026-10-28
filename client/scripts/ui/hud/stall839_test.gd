extends SceneTree

## Round 839 (lane S): the stall window against the real Media.pk2 -- GDR_STALL
## (ifstall.txt, ifstallslot.txt, ifchatmodule.txt) driven by the server's
## messages through StallController, owner and visitor, and its boxes.
##   godot4 --headless --path client --script res://scripts/ui/hud/stall839_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"

var _failures := 0

class FakeNet extends RefCounted:
	var sent: Array = []
	var own_character_id := 1
	var current_character_name := "Aria"
	var stalls := {}
	var buff_items := {}
	func stall_open(t: String) -> void: sent.append("open " + t)
	func stall_close() -> void: sent.append("close")
	func stall_leave() -> void: sent.append("leave")
	func stall_buy(slot: int) -> void: sent.append("buy %d" % slot)
	func stall_enter(uid: int) -> void: sent.append("enter %d" % uid)
	func stall_update(body: PackedByteArray) -> void: sent.append("update %d" % body[0])
	func stall_avatar(key: int, deco: int) -> void: sent.append("avatar %d %d" % [key, deco])
	func send_chat(t: int, _i: int, _n: String, text: String) -> void: sent.append("chat %d %s" % [t, text])

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await _run()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

func _label(n: Node) -> String:
	if n == null:
		return "<none>"
	if n is Label:
		return (n as Label).text
	for c in n.find_children("*", "Label", true, false):
		return (c as Label).text
	return "<none>"

func _entry(slot: int, ref: int, count: int, price: int, bag: int) -> StallNet.Entry:
	var e := StallNet.Entry.new()
	e.slot = slot
	var it := ItemInstance.new()
	it.ref_item_id = ref
	it.count = count
	it.is_equipment = false
	e.item = it
	e.count = count
	e.price = price
	e.bag_slot = bag
	return e

func _run() -> void:
	if not FileAccess.file_exists(MEDIA):
		print("SKIP (no %s)" % MEDIA)
		return
	var pk2 := Pk2Reader.open(MEDIA)
	_check(pk2 != null, "Media.pk2 opens")
	if pk2 == null:
		return
	var entry := ObjectLoader.find_file(pk2, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	var table := UiTextTable.parse(pk2.read_file(entry)) if entry != null else null
	root.size = Vector2i(1280, 720)
	await process_frame
	var builder := UiBuilder.new(pk2, table)
	var panels: Control = (load(PANELS_PATH) as GDScript).new(builder)
	root.add_child(panels)
	await process_frame
	var c: StallController = panels.call("_stall")
	var net := FakeNet.new()
	c.net = net
	var lines: Array = []
	panels.stall_system_line.connect(func(t: String, ty: int) -> void: lines.append([t, ty]))
	# The action's start: no grant, so the title box with the default title.
	_check(c.start() == "title box", "Stall opens the title box (no BFI1 grant)")
	await process_frame
	var tbox := panels.get_node_or_null("StallTitleInput") as HudCosBox
	_check(tbox != null and tbox.size == Vector2(280, 144) and tbox.typed() == "[Aria]'s stall."
		and tbox.edit.max_length == 40, "the title box: 280x144, \"[Aria]'s stall.\", 40 characters (got %s)" % (tbox.typed() if tbox != null else "none"))
	tbox.edit.text = "Cheap pots"
	tbox.press_ok()
	_check(net.sent == ["open Cheap pots", "update 6"], "OK sends 0x70B1 and the greeting at once (got %s)" % str(net.sent))
	# 0xB0B1 {1}: the window, modifying.
	c.on_open_result(1)
	await process_frame
	var w: HudWindow = panels.get("_windows").get("stall")
	_check(w != null and w.visible and panels.call("stall_window_shown"), "0xB0B1 {1} shows the window")
	if w == null:
		return
	_check(w.size == Vector2(467, 490), "GDR_STALL's 467 x 490 (got %s)" % str(w.size))
	var vp := w.get_viewport_rect().size
	_check(w.position == ((vp - w.size) / 2.0).round() + Vector2(0, -60), "centred, then moved (0, -60) (got %s)" % str(w.position))
	# The texts as this client's table resolves them (round 725: the stock
	# rows of the joined textuisystem).
	var t := func(key: String) -> String: return String(panels.call("_resolve_ui", key, key))
	var display := w.node("GDR_STALL_DISPLAY") as Control
	_check(display != null and display.get_node_or_null("StallSlot9") != null
		and (display.get_node("StallSlot3") as Control).position == Vector2(212, 47),
		"ten slots, 2 x 5 at (6 + 206 c, 6 + 41 r)")
	_check(_label(w.node("GDR_BTN_TRADINGSTATE")) == t.call("UIIT_STT_START_STALL") and _label(w.node("GDR_STALL_OWNERSTATE_MSG")) == t.call("UIIT_STT_STALL_MODIFYING"),
		"modifying: START_STALL, STALL_MODIFYING (got %s / %s)" % [_label(w.node("GDR_BTN_TRADINGSTATE")), _label(w.node("GDR_STALL_OWNERSTATE_MSG"))])
	_check(_label(w.node("GDR_STALL_STALLTITLE")) == "[Cheap pots]", "the title \"[Cheap pots]\"")
	_check(w.find_child("StallTabSell", true, false) != null and _label(w.find_child("StallTabSell", true, false)) == "Items to sell",
		"the one tab, \"Items to sell\"")
	# 0xB0BA type 2: the list.
	c.on_updated({"code": 1, "type": 2, "entries": {0: _entry(0, 9, 5, 1234567, 2)}})
	var slot0 := display.get_node("StallSlot0") as Control
	_check(_label(slot0.get_node("Body/GDR_STALLSLOT_AMOUNT")) == "5 Unit" and _label(slot0.get_node("Body/GDR_STALLSLOT_PRICE")) == "1,234,567 Gold",
		"slot 0: \"5 Unit\", \"1,234,567 Gold\" (got %s / %s)" % [_label(slot0.get_node("Body/GDR_STALLSLOT_AMOUNT")), _label(slot0.get_node("Body/GDR_STALLSLOT_PRICE"))])
	_check(c.listed_bag_slot(2) and panels.call("exchange_offered", 2), "bag slot 2 marked in the stall")
	var modify := slot0.get_node("Body/GDR_STALLSLOT_MODIFY") as BaseButton
	_check(modify.visible and not modify.disabled and not (display.get_node("StallSlot1/Body/GDR_STALLSLOT_MODIFY") as CanvasItem).visible,
		"the owner modifying: an occupied slot's modify button on, an empty one's hidden")
	# The state button: 0x70BA type 5.
	net.sent.clear()
	(w.node("GDR_BTN_TRADINGSTATE") as BaseButton).pressed.emit()
	_check(net.sent == ["update 5"], "Open Stall sends 0x70BA type 5")
	c.on_updated({"code": 1, "type": 5, "open": true})
	_check(_label(w.node("GDR_BTN_TRADINGSTATE")) == t.call("UIIT_STT_END_STALL") and _label(w.node("GDR_STALL_OWNERSTATE_MSG")) == t.call("UIIT_STT_TRADING_NOW")
		and modify.disabled and (w.node("GDR_BTN_CHANGETITLE") as BaseButton).disabled,
		"open: END_STALL, TRADING_NOW, the modify and title buttons off (got %s / %s)" % [_label(w.node("GDR_BTN_TRADINGSTATE")), _label(w.node("GDR_STALL_OWNERSTATE_MSG"))])
	var chat := w.find_child("Lines", true, false) as RichTextLabel
	_check(chat != null and chat.get_parsed_text().contains(t.call("UIIT_STT_STALL_CONDITION_START")),
		"the state line in the window's chat (got %s)" % (chat.get_parsed_text() if chat != null else "none"))
	# A sale: the line, the list, and the owner closes an empty stall itself.
	net.sent.clear()
	c.on_event({"kind": 3, "slot": 0, "buyer": "Bram", "entries": {}})
	_check(chat.get_parsed_text().contains("[Bram]bought item"), "0x30B7 kind 3: \"[Bram]bought item [..].\"")
	_check(net.sent == ["close"] and not c.listed_bag_slot(2), "every slot sold: the owner sends 0x70B2 (c:0x87a6f0)")
	c.on_close_result(1)
	_check(not w.visible and not panels.call("stall_window_shown"), "0xB0B2: the window goes")
	# A visitor: 0xB0B3.
	net.stalls[5] = {"owner": 5, "name": "Bram's", "decoration": 0}
	c.on_entered({"code": 1, "owner": 5, "greeting": "hello", "open": false, "value4": 0,
		"entries": {4: _entry(4, 9, 1, 50, 7)}, "visitors": [8]})
	await process_frame
	_check(w.visible and not c.own and _label(w.node("GDR_STALL_GREETING")) == "hello" and _label(w.node("GDR_STALL_STALLTITLE")) == "[Bram's]",
		"0xB0B3: the visitor's window, its greeting and title")
	_check((w.node("GDR_BTN_TRADINGSTATE") as BaseButton).disabled and (w.node("GDR_BTN_OWNERMSG") as BaseButton).disabled,
		"a visitor's buttons off")
	var icon4 := display.get_node("StallSlot4/Body/GDR_STALLSLOT_ICON/ItemIcon") as TextureRect
	_check(icon4 != null and is_equal_approx(icon4.modulate.a, 128.0 / 255.0), "modifying: a visitor's icons at alpha 0x80")
	_check(c.users.size() == 3 and c.users[2] == "Aria", "the user list: owner, visitor, self")
	_check(c.slot_to_bag(4) == "buy box for slot 4", "a visitor's slot put on the bag: the buy box")
	await process_frame
	var buy := w.find_child("StallBox", true, false) as StoreMessageBox
	_check(buy != null and buy.kind == StoreMessageBox.Kind.STALL_BUY and buy.price_value == 50, "the buy box with the price")
	net.sent.clear()
	if buy != null:
		buy._on_ok()
	_check(net.sent == ["buy 4"], "Buy sends 0x70B4 {4}")
	net.sent.clear()
	c.press_close()
	_check(net.sent == ["leave"], "a visitor's X sends 0x70B5")
	c.on_gone({"owner": 5, "reason": 0x3c17})
	_check(not w.visible, "0x30B9 for the stall shown closes it")
	_check(lines.size() >= 1 and String(lines[-1][0]) == "The shop is closed.", "0x3c17's line (got %s)" % str(lines))
	panels.queue_free()
