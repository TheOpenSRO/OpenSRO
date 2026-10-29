extends SceneTree

## Round 834: the exchange window against the real Media.pk2 -- the retail
## layout (GDR_EXCHANGE, ifexchange.txt) driven by the server's messages
## through ExchangeController, and the three boxes (exchange_boxes.md).
##   godot4 --headless --path client --script res://scripts/ui/hud/exchange834_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"

var _failures := 0

class FakeFriend extends RefCounted:
	var friend_name := ""

class FakeNet extends RefCounted:
	var sent: Array = []
	var last_friend_list: Array = []
	var guild_data = null
	func exchange_confirm() -> void: sent.append("confirm")
	func exchange_approve() -> void: sent.append("approve")
	func exchange_cancel() -> void: sent.append("cancel")
	func exchange_remove(i: int) -> void: sent.append("remove %d" % i)

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

func _offered(index: int, slot: int, ref: int, count: int) -> ExchangeNet.Offered:
	var o := ExchangeNet.Offered.new()
	o.index = index
	o.bag_slot = slot
	var it := ItemInstance.new()
	it.ref_item_id = ref
	it.count = count
	it.is_equipment = false
	o.item = it
	return o

func _run() -> void:
	if not FileAccess.file_exists(MEDIA):
		print("SKIP (no %s)" % MEDIA)
		return
	# Retail's compact layout first; the portraits and log (round 836) at the end.
	var saved_full = ClientSettings.get_value(ClientSettings.SECTION_EXTRA, ClientSettings.KEY_EXCHANGE_PORTRAITS, null)
	ClientSettings.set_value(ClientSettings.SECTION_EXTRA, ClientSettings.KEY_EXCHANGE_PORTRAITS, false)
	await _run_both()
	ClientSettings.set_value(ClientSettings.SECTION_EXTRA, ClientSettings.KEY_EXCHANGE_PORTRAITS, saved_full if saved_full != null else true)

func _rect_of(c: Control) -> Rect2:
	var r = c.get_meta(UiBuilder.AUTHORED_RECT_META, null) if c != null else null
	return r if r is Rect2 else (Rect2(c.position, c.size) if c != null else Rect2())

func _run_both() -> void:
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
	var x: ExchangeController = panels.call("_exchange")
	var net := FakeNet.new()
	x.net = net
	var banners: Array = []
	var lines: Array = []
	panels.exchange_banner.connect(func(t: String) -> void: banners.append(t))
	panels.exchange_system_line.connect(func(t: String, ty: int) -> void: lines.append([t, ty]))
	panels.call("open_exchange", {"id": 5, "name": "Pain", "guild": "Verizon", "normal": true},
		{"id": 1, "name": "Sarada", "guild": "", "normal": true})
	await process_frame
	var w: HudWindow = panels.get("_windows").get("exchange")
	_check(w != null and w.visible and panels.call("exchange_mode"), "the window opens, exchange mode on")
	if w == null:
		return
	_check(w.size == Vector2(254, 361), "retail's 254 x 361 (got %s)" % str(w.size))
	var user_name := w.node("GDR_EXCHANGE_USER_NAME") as CanvasItem
	_check(user_name != null and not user_name.is_visible_in_tree(),
		"USER_NAME (153, icon_effect1.ddj over the opponent's grid) hidden at Create (c:0x7b29dd)")
	_check(_label(w.node("GDR_EXCHANGE_OTHER_SUBFRAME")) == "[Pain - Verizon]'s item"
		and _label(w.node("GDR_EXCHANGE_MY_SUBFRAME")) == "[Sarada - Did not join any guild]'s item",
		"the headers: opponent on top, own below, 'Did not join any guild' (got '%s' / '%s')" % [
			_label(w.node("GDR_EXCHANGE_OTHER_SUBFRAME")), _label(w.node("GDR_EXCHANGE_MY_SUBFRAME"))])
	_check(lines.size() >= 2 and String(lines[0][0]) == "You started to exchange with [Pain]." and int(lines[0][1]) == 0,
		"the start line, type 0, the first row's wording (got %s)" % str(lines))
	_check(banners == ["Opponent user is not listed in your Guild/Union/Friend"],
		"not a friend or guild member: the warning banner, the first row's wording (got %s)" % str(banners))
	var button := w.node("GDR_EXCHANGE_BUTTON_EXCHANGE") as BaseButton
	_check(button != null and _label(button) == "Confirm" and not button.disabled, "the button reads Confirm")
	# Our offer: our list (with bag slots) fills our grid and dims the bag slot.
	x.on_offer({"owner": 1, "own": true, "items": [_offered(0, 2, 200, 5)]})
	var my_grid := w.node("GDR_EXCHANGE_LAT_MY") as Control
	var cell0 := my_grid.get_child(0) as Control
	_check((cell0.get_node("ItemIcon") as TextureRect).texture != null and x.offered_slots.has(2), "our item drawn, bag slot 2 offered")
	# Confirm: press, then 0xB082 {1}.
	button.pressed.emit()
	_check(net.sent == ["confirm"] and x.busy, "Confirm sends 0x7082")
	_check(banners.size() == 2 and String(banners[1]).begins_with("Please check opponet user's ID"), "the reaffirm warning on the banner")
	x.on_result(0x3082, 1)
	_check(x.mine_confirmed and _label(button) == "Approve" and button.disabled, "0xB082 {1}: Approve, disabled until the opponent confirms")
	_check((cell0.get_node("ExchangeTint") as Control).visible and not (w.node("GDR_EXCHANGE_LAT_OTHER").get_child(0).get_node("ExchangeTint") as Control).visible,
		"our grid blue, theirs not")
	_check(is_equal_approx((w.node("GDR_EXCHANGE_STATIC_MYMONEY") as Control).modulate.r, 127.0 / 255.0), "our gold greyed")
	# The opponent confirms: their list, their gold, 0x3086.
	x.on_offer({"owner": 5, "own": false, "items": [_offered(0, -1, 100, 1)]})
	x.on_partner_gold(100)
	x.on_partner_confirmed()
	_check(not button.disabled and (w.node("GDR_EXCHANGE_LAT_OTHER").get_child(0).get_node("ExchangeTint") as Control).visible,
		"0x3086: their grid blue, Approve enabled")
	button.pressed.emit()
	_check(net.sent == ["confirm", "approve"], "Approve sends 0x7083")
	x.on_result(0x3083, 1)
	_check(button.disabled, "0xB083 {1}: disabled")
	# Done: 0x3087.
	lines.clear()
	banners.clear()
	panels.call("exchange_closed", 1)
	_check(not w.visible and not panels.call("exchange_mode"), "0x3087: the window closed")
	_check(lines.size() == 1 and String(lines[0][0]) == "Exchanging with [Pain] is completed." and banners == ["Exchange of the selected item(s) succeeded."],
		"0x3087's line and banner (got %s / %s)" % [str(lines), str(banners)])
	# A cancel: X sends 0x7084 and the window waits; 0x3088 closes it.
	panels.call("open_exchange", {"id": 5, "name": "Pain", "guild": "", "normal": true}, {"id": 1, "name": "Sarada", "guild": "", "normal": true})
	net.sent.clear()
	w.call("_on_close_pressed")
	_check(net.sent == ["cancel"] and w.visible, "the X sends 0x7084, the window stays")
	lines.clear()
	panels.call("exchange_closed", 0x182c)
	_check(not w.visible and net.sent == ["cancel", "cancel"] and lines.size() == 1 and String(lines[0][0]) == "The trade has been cancelled.",
		"0x3088 {0x182c}: closed, 0x7084 sent back while in exchange mode, the line (got %s)" % str(lines))
	# The opponent confirms first (0x7b2670(1) with +0x7bd clear): their grid
	# blue, ours not, and the button left as it was -- "Confirm", enabled.
	panels.call("open_exchange", {"id": 5, "name": "Pain", "guild": "", "normal": true}, {"id": 1, "name": "Sarada", "guild": "", "normal": true})
	await process_frame
	var my_tint := w.node("GDR_EXCHANGE_LAT_MY").get_child(0).get_node("ExchangeTint") as Control
	var other_tint := w.node("GDR_EXCHANGE_LAT_OTHER").get_child(0).get_node("ExchangeTint") as Control
	_check(not my_tint.visible and not other_tint.visible, "a new exchange starts with neither grid blue")
	net.sent.clear()
	x.on_offer({"owner": 5, "own": false, "items": [_offered(0, -1, 100, 1)]})
	x.on_partner_gold(100)
	x.on_partner_confirmed()
	_check(other_tint.visible and not my_tint.visible, "0x3086 first: their grid blue, ours not")
	_check(_label(button) == "Confirm" and not button.disabled, "0x3086 first: the button stays Confirm and enabled (got '%s', disabled %s)" % [_label(button), str(button.disabled)])
	x.on_offer({"owner": 1, "own": true, "items": [_offered(0, 2, 200, 5)]})
	button.pressed.emit()
	_check(net.sent == ["confirm"], "we can still confirm (got %s)" % str(net.sent))
	x.on_result(0x3082, 1)
	_check(_label(button) == "Approve" and not button.disabled and my_tint.visible, "0xB082 {1} after theirs: Approve, enabled, our grid blue")
	button.pressed.emit()
	_check(net.sent == ["confirm", "approve"], "and approve")
	panels.call("exchange_closed", 0x182c)
	# The boxes.
	var req = panels.call("show_exchange_request", 5, "Pain")
	_check(req != null and req.size == Vector2(308, 148), "the request box: 308 x 148")
	if req != null:
		_check(_label(req.node("GDR_MBIN_STATIC_MESSAGE1")) == "[Pain] sent you  party invite."
			and _label(req.node("GDR_MBIN_STATIC_MESSAGE2")) == "Applied for the exchange. Will you accept it?",
			"its lines, the first rows (got '%s' / '%s')" % [_label(req.node("GDR_MBIN_STATIC_MESSAGE1")), _label(req.node("GDR_MBIN_STATIC_MESSAGE2"))])
		_check(_label(req.node("GDR_MBIN_BTN_OK")) == "Accept" and _label(req.node("GDR_MBIN_BTN_CANCEL")) == "Refuse"
			and not req.node("GDR_MBIN_BTN_CERTIFY").visible, "Accept / Refuse, CERTIFY hidden")
	panels.call("open", "inventory")
	await process_frame
	var item_box = panels.call("open_exchange_item_box", 0, 200, 5)
	_check(item_box != null and item_box.size == Vector2(308, 148), "the item box: 308 x 148 (MsgBoxStore)")
	var gold_box = panels.call("open_exchange_gold_box")
	_check(gold_box != null and gold_box.count == 1, "the gold box opens at 1 (c:0x6b2ce5)")
	# Round 836: the portraits and log (OURS layout, MEASURED from the user's
	# screenshots), built when the option is on.
	ClientSettings.set_value(ClientSettings.SECTION_EXTRA, ClientSettings.KEY_EXCHANGE_PORTRAITS, true)
	panels.set("exchange_canvas", Vector2(1280, 720))
	panels.call("_on_exchange_layout_option", {"exchange_portraits": true})
	_check(panels.get("_windows").get("exchange") == null, "the option drops the compact window to rebuild it")
	lines.clear()
	banners.clear()
	panels.call("open_exchange", {"id": 5, "name": "Pain", "guild": "Verizon", "normal": true},
		{"id": 1, "name": "Sarada", "guild": "", "normal": true})
	await process_frame
	await process_frame
	var f: HudWindow = panels.get("_windows").get("exchange")
	_check(f != null and f.size == Vector2(365, 500) and panels.call("exchange_window_full"), "the full window: 365 x 500 (got %s)" % str(f.size if f != null else null))
	if f != null:
		_check(_rect_of(f.node("GDR_EXCHANGE_BUTTON_EXCHANGE") as Control).position == Vector2(96, 450)
			and _rect_of(f.node("GDR_EXCHANGE_BUTTON_CANCEL") as Control).position == Vector2(194, 450), "the buttons below the log")
		_check(_rect_of(f.node("GDR_EXCHANGE_TEXT_BOX") as Control) == Rect2(14, 342, 337, 87), "the log box at 14,342 337 x 87")
		var ov: TextureRect = panels.call("exchange_portrait_view", false)
		var mv: TextureRect = panels.call("exchange_portrait_view", true)
		_check(ov != null and mv != null and _rect_of(ov) == Rect2(249, 72, 96, 100) and _rect_of(mv) == Rect2(249, 216, 96, 100),
			"the portraits inside their boxes, inset 2,2,4,4 (got %s / %s)" % [str(_rect_of(ov)) if ov != null else "-", str(_rect_of(mv)) if mv != null else "-"])
		# Round 841: both busts play their clip (CIFExchange::vslot_012).
		var op = panels.call("exchange_portrait", false)
		var mp = panels.call("exchange_portrait", true)
		_check(op != null and mp != null and op.animate and mp.animate, "both busts are animated pictures")
		var logged: Array = panels.call("exchange_log_lines")
		_check(logged.size() == 2 and String(logged[0]["text"]) == "You started to exchange with [Pain]."
			and (logged[0]["color"] as Color).is_equal_approx(ExchangeController.ORANGE)
			and String(logged[1]["text"]) == "Opponent user is not listed in your Guild/Union/Friend"
			and (logged[1]["color"] as Color).is_equal_approx(ExchangeController.RED),
			"the log: the start line orange, the warning red (got %s)" % str(logged))
		var red := f.node("GDR_EXCHANGE_USER_VISUAL_EFFECT") as Control
		var tip := f.node("GDR_EXCHANGE_USER_VISUAL_TOOLTIP") as Control
		_check(red != null and red.visible and int(panels.call("exchange_red_frame")) >= 0, "a stranger: the red pulse behind their portrait")
		_check(tip != null and tip.visible and String((panels.call("bubble_tip_lines", tip) as Array)[0]["text"]).begins_with("Opponent user"),
			"and the warning as its tooltip")
		var fbutton := f.node("GDR_EXCHANGE_BUTTON_EXCHANGE") as BaseButton
		x.on_offer({"owner": 1, "own": true, "items": [_offered(0, 2, 200, 5)]})
		fbutton.pressed.emit()
		logged = panels.call("exchange_log_lines")
		_check(logged.size() >= 3 and String(logged[2]["text"]).begins_with("Please check opponet user's ID"),
			"Confirm's reaffirm goes to the log, wrapped with no indent (got %s)" % str(logged))
		if logged.size() >= 4:
			_check(not String(logged[3]["text"]).begins_with(" "), "the continuation line starts at the margin")
		panels.call("exchange_closed", 0x182c)
		# A friend: no red, no tooltip, the log starts again.
		var fr := FakeFriend.new()
		fr.friend_name = "Pain"
		net.last_friend_list = [fr]
		panels.call("open_exchange", {"id": 5, "name": "Pain", "guild": "", "normal": true}, {"id": 1, "name": "Sarada", "guild": "", "normal": true})
		await process_frame
		_check(not red.visible and not tip.visible and (panels.call("exchange_log_lines") as Array).size() == 1,
			"a friend: no red, no tooltip, the log only the start line")
		panels.call("exchange_closed", 0x182c)
		net.last_friend_list = []
		# A canvas too small for it (a high UI scale on a small screen): the
		# compact window is built instead, and the full one again with room.
		panels.set("exchange_canvas", Vector2(1280, 480))
		panels.call("open_exchange", {"id": 5, "name": "Pain", "guild": "", "normal": true}, {"id": 1, "name": "Sarada", "guild": "", "normal": true})
		await process_frame
		var small: HudWindow = panels.get("_windows").get("exchange")
		_check(small != null and small.size == Vector2(254, 361) and not panels.call("exchange_window_full"),
			"a 480-tall canvas: the compact window (got %s)" % str(small.size if small != null else null))
		panels.call("exchange_closed", 0x182c)
		panels.set("exchange_canvas", Vector2(1280, 720))
		panels.call("open_exchange", {"id": 5, "name": "Pain", "guild": "", "normal": true}, {"id": 1, "name": "Sarada", "guild": "", "normal": true})
		await process_frame
		_check(panels.call("exchange_window_full"), "room again: the full window")
		panels.call("exchange_closed", 0x182c)
	panels.queue_free()
