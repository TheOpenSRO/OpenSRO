extends SceneTree

## Round 842 (lane T): the stall window's log (its CIFChatModule, STALL_CHAT)
## lives as long as the window. Every close is 0x79be20(0), which deletes the
## IFStall section's controls (c:0x79bec3..0x79bf09 -> 0x8b59f0), the log
## with them: the owner's 0xB0B2 whatever its answer (c:0x8720f0, the jmp at
## 0x87215c / 0x87219f), a visitor's 0xB0B5 likewise (c:0x872450, 0x8724b3 /
## 0x8724f6), 0x30B9 for the window's stall (c:0x8721b0 -> 0x872228). A
## modify (0xB0BA type 5) only adds its state line (c:0x878486). Against the
## real Media.pk2's ifstall.txt / ifchatmodule.txt.
##   godot4 --headless --path client --script res://scripts/ui/hud/stall_log842_test.gd

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

## The owner's start, its title box OK and 0xB0B1 {1}.
func _open_own(panels: Control, c: StallController, title: String) -> void:
	c.start()
	await process_frame
	var tbox := panels.get_node_or_null("StallTitleInput") as HudCosBox
	if tbox != null:
		tbox.edit.text = title
		tbox.press_ok()
	c.on_open_result(1)
	await process_frame

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
	var t := func(key: String) -> String: return String(panels.call("_resolve_ui", key, key))
	var log := func() -> String:
		return StallWindowView.chat_text(panels.get("_windows").get("stall"))

	# 1. Sold out: two sales, the last one empties the stall, the owner's
	# client sends 0x70B2 (c:0x87a6f0), 0xB0B2 {1} -- then a new stall's log
	# is empty.
	await _open_own(panels, c, "First stall")
	var w: HudWindow = panels.get("_windows").get("stall")
	_check(w != null and w.visible, "the first stall's window")
	if w == null:
		return
	c.on_updated({"code": 1, "type": 2, "entries": {0: _entry(0, 9, 5, 100, 2), 1: _entry(1, 9, 3, 50, 3)}})
	c.on_updated({"code": 1, "type": 5, "open": true})
	c.chat_line("Bram", "how much?")
	var input := w.find_child("GDR_CHAT_INPUTBOX", true, false) as LineEdit
	if input != null:
		input.text = "half typed"
	net.sent.clear()
	c.on_event({"kind": 3, "slot": 0, "buyer": "Bram", "entries": {1: _entry(1, 9, 3, 50, 3)}})
	c.on_event({"kind": 3, "slot": 1, "buyer": "Cara", "entries": {}})
	var before: String = log.call()
	_check(before.contains(t.call("UIIT_STT_STALL_CONDITION_START")) and before.contains("Bram: how much?")
		and before.contains("[Bram]bought item") and before.contains("[Cara]bought item"),
		"the log holds the state line, the chat and both sales (%s)" % before.replace("\n", " | "))
	_check(net.sent == ["close"], "sold out: the owner's client sends 0x70B2 itself (got %s)" % str(net.sent))
	c.on_close_result(1)
	_check(not w.visible and String(log.call()) == "" and (input == null or input.text == ""),
		"0xB0B2 {1}: the window goes and its log and input with it")
	await _open_own(panels, c, "Second stall")
	_check(w.visible and String(log.call()) == "", "a new stall after the sell-out: an empty log (got %s)" % String(log.call()).replace("\n", " | "))

	# 2. Close and reopen: the log is the new stall's only.
	c.chat_line("Bram", "hello again")
	c.on_updated({"code": 1, "type": 5, "open": true})
	# A modify (open -> modify -> open) keeps the log and adds its state lines.
	c.on_updated({"code": 1, "type": 5, "open": false})
	var mod: String = log.call()
	_check(mod.contains("Bram: hello again") and mod.contains(t.call("UIIT_STT_STALL_CONDITION_END")),
		"a modify keeps the log and adds the state line (c:0x878486)")
	c.press_close()
	c.on_close_result(1)
	_check(String(log.call()) == "", "the X, 0xB0B2 {1}: the log goes")
	await _open_own(panels, c, "Third stall")
	_check(String(log.call()) == "", "reopened: empty")
	# A refusal of 0x70B2 closes the window too (the jmp after the code, c:0x87219f).
	c.chat_line("Bram", "bye")
	c.on_close_result(0x3c0f)
	_check(not w.visible and String(log.call()) == "", "0xB0B2 {2, code}: the window and its log go as well")

	# 3. A visitor: enter, chat, leave (0xB0B5), enter again -- empty; and
	# 0x30B9 for the stall shown.
	net.stalls[5] = {"owner": 5, "name": "Bram's", "decoration": 0}
	var enter := {"code": 1, "owner": 5, "greeting": "hi", "open": true, "value4": 0,
		"entries": {4: _entry(4, 9, 1, 50, 7)}, "visitors": []}
	c.on_entered(enter)
	await process_frame
	c.chat_line("Bram", "welcome")
	c.on_event({"kind": 3, "slot": 4, "buyer": "Dora", "entries": {}})
	_check(String(log.call()).contains("Bram: welcome") and String(log.call()).contains("[Dora]bought item"), "the visitor's log")
	c.press_close()
	c.on_leave_result(1)
	_check(not w.visible and String(log.call()) == "", "0xB0B5 {1}: the visitor's window and log go")
	c.on_entered(enter)
	await process_frame
	_check(w.visible and String(log.call()) == "", "entered again: an empty log")
	c.chat_line("Bram", "closing soon")
	c.on_gone({"owner": 5, "reason": 0x3c17})
	_check(not w.visible and String(log.call()) == "", "0x30B9 for the stall shown: the window and its log go")
	c.on_entered(enter)
	await process_frame
	_check(String(log.call()) == "", "entered after the close: empty")
	# 0x30B9 for another stall changes nothing.
	c.chat_line("Bram", "still here")
	c.on_gone({"owner": 77, "reason": 0x3c17})
	_check(w.visible and String(log.call()).contains("Bram: still here"), "0x30B9 for another stall: the log stays")
	panels.queue_free()
