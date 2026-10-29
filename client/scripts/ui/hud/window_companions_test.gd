extends SceneTree

## Round 841: the windows that open alongside an operation, against the real
## Media.pk2 -- every trigger the census (docs/protocol/window_companions.md)
## found that this client has, opening and closing:
## - the stall window's show, the owner's 0xB0B1 {1} and a visitor's 0xB0B3
##   {1} (CIFStall::vslot_023, c:0x6b9730): the alchemy window destroyed, the
##   inventory raised over the stall; its close leaves the inventory;
## - the NPC store under lock 1 (the inventory beside it) and under the
##   specialty lock 0xc (c:0x79dbd0 -> 0x811130(1) / 0x7a0980(0)): the bag
##   hidden and the transport's window TOGGLED onto its Inventory page; no
##   transport, nothing; a pet current, the transport made current;
## - the storage, the exchange (its end leaves the inventory), the grant
##   window (0x79af20's open sound), the alchemy window, Gori's exchange;
## - Escape: the stall's X before the inventory, the COS window after it;
## - the player's own state: the tab, a dragged y, the keyboard focus.
##   godot4 --headless --path client --script res://scripts/ui/hud/window_companions_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"
const WORLD_PATH := "res://scripts/World3D.gd"

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
	func stall_update(body: PackedByteArray) -> void: sent.append("update %d" % body[0])
	func send_chat(t: int, _i: int, _n: String, text: String) -> void: sent.append("chat %d %s" % [t, text])

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(120.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the checks never reported (a script error stopped them)")
		quit(1))
	_source_checks()
	await _run()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

## Gori's line (c:0x7020c0 case 0x28, c:0x703330..0x70333b): 0x79af20, then
## 0x7119 -- the order in World3D's own source.
func _source_checks() -> void:
	var src := FileAccess.get_file_as_string(WORLD_PATH)
	var at := src.find("func _gacha_exchange()")
	var end := src.find("\nfunc ", at + 1)
	var body := src.substr(at, end - at) if at >= 0 else ""
	var inv := body.find("inventory_companion(")
	var send := body.find("NetClient.gacha_exchange(")
	_check(at >= 0 and inv >= 0 and send > inv, "Gori's exchange raises the inventory before it sends 0x7119 (c:0x703336)")
	var job := src.find("_specialty_flow = SpecialtyFlow.new(")
	_check(job >= 0 and src.find("_hud_panels.hud_cos = _hud_cos", job) > job, "World3D hands HudPanels the COS manager")

func _row(id: int, code: String, type4: int) -> CosTable.Row:
	var r := CosTable.Row.new()
	r.id = id
	r.code = code
	r.type4 = type4
	r.level = 1
	r.max_hp = 1000
	r.icon = "icon\\cos\\" + code.to_lower() + ".ddj"
	r.name_key = "SN_" + code
	return r

func _data(uid: int, ref_id: int, type4: int) -> CosNet.Data:
	var d := CosNet.Data.new()
	d.uid = uid
	d.ref_id = ref_id
	d.kind = type4
	d.hp = 500
	d.inv_size = 1
	return d

func _index(n: Node) -> int:
	return n.get_index() if n != null and n.get_parent() != null else -1

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
	# The headless window takes its own size at the first frame; ours after it.
	await process_frame
	root.size = Vector2i(1280, 720)
	root.content_scale_factor = 1.0
	await process_frame
	var builder := UiBuilder.new(pk2, table)
	var panels: Control = (load(PANELS_PATH) as GDScript).new(builder)
	root.add_child(panels)
	await process_frame
	var rows := {6001: _row(6001, "COS_T_DONKEY", CosNet.KIND_TRANSPORT), 6002: _row(6002, "COS_P_RABBIT", CosNet.KIND_ABILITY)}
	var cos := HudCos.new(builder)
	cos.setup({
		"cos_row": func(id: int) -> CosTable.Row: return rows.get(id),
		"item_row": func(_id: int) -> ItemTableReader.Item: return null,
		"text": func(k: String) -> String: return k,
		"exp_to_next": func(lv: int) -> int: return lv * 100,
		"screen_width": func() -> int: return 1280,
		"screen_height": func() -> int: return 720,
	})
	root.add_child(cos)
	panels.set("hud_cos", cos)
	await process_frame
	var view := Vector2(1280, 720)
	var c: StallController = panels.call("_stall")
	var net := FakeNet.new()
	c.net = net
	# --- the stall: the owner's 0xB0B1 {1} ------------------------------------
	panels.call("open_alchemy")
	_check(panels.call("alchemy_window") != null, "the alchemy window is open before the stall")
	var popup: HudWindow = panels.call("open", "skill")
	_check(popup != null and panels.call("is_open", "skill"), "the main popup is up on the skill tab")
	if popup == null:
		return
	# The player's own placement: a drag to y 140 (the popup's wanted y).
	popup.position = Vector2(30, 140)
	popup.dragged.emit()
	c.start()
	var tbox := panels.get_node_or_null("StallTitleInput") as HudCosBox
	if tbox != null:
		tbox.edit.text = "Pots"
		tbox.press_ok()
	await process_frame
	UiSounds.clear_fired()
	c.on_open_result(1)
	await process_frame
	var stall: HudWindow = panels.get("_windows").get("stall")
	_check(stall != null and stall.visible, "0xB0B1 {1}: the stall window is shown")
	_check(panels.call("is_open", "inventory") and panels.call("is_open", "equipment"), "the stall's show opens the inventory tab (0x79af20), from the skill tab")
	_check(panels.call("alchemy_window") == null, "and destroys the alchemy window first (0x799580 -> 0x798e20(0))")
	_check(_index(popup) > _index(stall), "the inventory is raised over the stall (0x79a7e0's raise; the stall's show raises nothing)")
	_check(popup.position == Vector2(view.x - popup.size.x - 80.0, 140.0),
		"the inventory at the tab's x (W - w - 0x50) and the dragged y 140 (got %s)" % popup.position)
	_check(UiSounds.count(UiSounds.KEY_WINDOW_OPEN) == 1, "one snd_window_open with it (0x79a7e0 on the popup; got %d)" % UiSounds.count(UiSounds.KEY_WINDOW_OPEN))
	# Its close (0xB0B2): the stall goes, the inventory stays (vslot_023(0)
	# re-enables the bag's cells and hides nothing else).
	c.on_close_result(1)
	await process_frame
	_check(not stall.visible and panels.call("is_open", "inventory"), "0xB0B2: the stall goes, the inventory stays")

	# --- a visitor's 0xB0B3 {1}, with the bag closed --------------------------
	panels.call("close", "inventory")
	net.stalls[5] = {"owner": 5, "name": "Bram's", "decoration": 0}
	c.on_entered({"code": 1, "owner": 5, "greeting": "hi", "open": true, "value4": 0, "entries": {}, "visitors": []})
	await process_frame
	_check(stall.visible and panels.call("is_open", "inventory"), "0xB0B3 {1}: a visitor's stall opens the inventory too")
	# Escape: the stall's X first (vslot_043: 0x70B5 for a visitor, the window
	# kept until the answer), then the inventory.
	net.sent.clear()
	_check(panels.call("_escape_close") and net.sent == ["leave"] and stall.visible,
		"Escape: the stall's X before the inventory -- 0x70B5 sent, the window kept (got %s)" % str(net.sent))
	c.on_leave_result(1)
	await process_frame
	_check(not stall.visible and panels.call("is_open", "inventory"), "0xB0B5: the stall goes, the inventory stays")
	_check(panels.call("_escape_close") and not popup.visible, "the next Escape closes the inventory")

	# --- the NPC store, lock 1 -------------------------------------------------
	panels.call("open_shop", "Smith", [], "NPC_CH_SMITH")
	await process_frame
	var store: HudWindow = panels.get("_windows").get("store")
	_check(store != null and store.visible and panels.call("is_open", "inventory"), "the store (lock 1) opens the inventory beside it")
	_check(store != null and _index(store) > _index(popup), "the store raised over it (0x79dcf0)")
	if store != null:
		store.hide()

	# --- the specialty store, lock 0xc ------------------------------------------
	panels.set("specialty_lock", func() -> bool: return true)
	cos.add_cos(_data(77, 6001, CosNet.KIND_TRANSPORT))
	cos.add_cos(_data(78, 6002, CosNet.KIND_ABILITY))
	_check(cos.current_uid() == 78, "the rabbit is the current COS (the last summoned)")
	panels.call("open", "inventory")
	panels.call("open_shop", "Trader", [], "NPC_CH_SPECIAL")
	await process_frame
	_check(store.visible and not popup.visible, "the specialty store hides the inventory (0x7992c0) and opens no bag")
	_check(cos.current_uid() == 77, "the transport made current (0x811130(1) -> 0x810fd0)")
	_check(cos.window.visible and cos.window.cos_uid == 77 and cos.window.page == HudCosWindow.PAGE_INVENTORY,
		"the transport's window on its Inventory page (0x7a0980(0) -> 0x79bcd0(1, cos, 1))")
	var beside := Vector2(view.x * 0.5 + 8.0, (view.y - cos.window.size.y) * 0.5).round()
	_check(cos.window.position == beside, "with no saved position, where the bag goes beside the store (OURS; got %s)" % cos.window.position)
	_check(_index(panels) > _index(cos), "the store's layer over the COS window's (the store raised last)")
	# Escape: the store first (the topmost window), then the COS window, after
	# the main popup (0x79d9c5).
	cos.window.position = Vector2(500, 200)
	store.hide()
	panels.call("open", "inventory")
	_check(panels.call("_escape_close") and not popup.visible and cos.window.visible, "Escape closes the inventory before the COS window")
	_check(panels.call("_escape_close") and not cos.window.visible, "then the COS window (0x799140(0x78) -> 0x79bcd0(0))")
	_check(cos.window.saved_position == Vector2(500, 200), "its position saved")
	# The store again: command 0 is a toggle -- closed, it opens at the saved place.
	panels.call("open_shop", "Trader", [], "NPC_CH_SPECIAL")
	await process_frame
	_check(cos.window.visible and cos.window.position == Vector2(500, 200), "reopened at its saved position")
	store.hide()
	# Open, the store's command 0 closes it (READ: 0x7a0a4b..0x7a0a5d).
	panels.call("open_shop", "Trader", [], "NPC_CH_SPECIAL")
	await process_frame
	_check(not cos.window.visible, "a store opened while the transport's window is up closes it (the toggle)")
	store.hide()
	# No transport: nothing opens, the bag stays hidden.
	cos.remove_cos(77)
	panels.call("open", "inventory")
	panels.call("open_shop", "Trader", [], "NPC_CH_SPECIAL")
	await process_frame
	_check(not cos.window.visible and not popup.visible, "no transport out: no window, and the bag hidden all the same")
	store.hide()
	panels.set("specialty_lock", func() -> bool: return false)

	# --- the storage, the exchange, the grant window -------------------------
	popup.hide()
	panels.call("open_storage", "Keeper")
	await process_frame
	_check(panels.call("is_open", "inventory"), "the storage opens the inventory (0x79dbd0(5, 1))")
	(panels.get("_windows").get("storage") as HudWindow).hide()
	popup.hide()
	panels.call("open_exchange_window")
	await process_frame
	var ex: HudWindow = panels.get("_windows").get("exchange")
	_check(ex != null and ex.visible and panels.call("is_open", "inventory") and _index(ex) > _index(popup),
		"the exchange opens the inventory, the exchange raised over it (0x79df10(1))")
	panels.call("close_exchange_window")
	_check(not ex.visible and panels.call("is_open", "inventory"), "the exchange's end leaves the inventory (0x79df10(0))")
	popup.hide()
	UiSounds.clear_fired()
	var g = panels.call("open_grant_window")
	await process_frame
	_check(g != null and panels.call("is_open", "inventory") and UiSounds.count(UiSounds.KEY_WINDOW_OPEN) == 1,
		"the grant window opens the inventory with 0x79a7e0's snd_window_open (got %d)" % UiSounds.count(UiSounds.KEY_WINDOW_OPEN))
	panels.call("close", "grant")
	popup.hide()
	panels.call("open_alchemy")
	_check(panels.call("is_open", "inventory"), "the alchemy window opens the inventory (0x592635)")
	panels.call("close_alchemy")
	_check(panels.call("is_open", "inventory"), "its close leaves the inventory")

	# --- a text line keeps the keyboard -----------------------------------------
	popup.hide()
	var edit := LineEdit.new()
	panels.add_child(edit)
	edit.grab_focus()
	await process_frame
	panels.call("inventory_companion", "focus check")
	await process_frame
	_check(popup.visible and root.gui_get_focus_owner() == edit, "the inventory opened alongside leaves the keyboard with a text line (got %s)" % root.gui_get_focus_owner())
	edit.queue_free()

	# --- the QA talk line point ----------------------------------------------
	panels.call("open_npc_talk", "Trader", "Hello.", [])
	await process_frame
	var pt: Vector2 = panels.call("qa_talk_line_point", 1)
	var talk: HudWindow = panels.get("_windows").get("npctalk")
	_check(talk != null and pt.x >= 0 and talk.get_global_rect().has_point(pt), "the talk box's line 1 is inside the window (got %s)" % pt)
	panels.queue_free()
	cos.queue_free()
