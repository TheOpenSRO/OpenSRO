extends SceneTree

## Round 841 (lane K): the stall network's key, F (KeyMap slot 33, OURS),
## against the real Media.pk2. Every key goes through Viewport.push_input
## into a real KeyInput, whose host runs "stall_network" the way World3D's
## _run_key_action does (StallNetworkController.toggle on HudPanels' own
## controller): F opens the window (item 120's 0x799020(1), the town rule
## and its refusal), F again closes it (0x799020(0), 0x7462 after a search),
## F typed into a focused text line opens nothing, and a rebind moves it.
##   godot4 --headless --path client --script res://scripts/ui/hud/stall_network_key841_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"

var _failures := 0

class FakeNet extends RefCounted:
	var sent: Array = []
	var own_character_id := 1
	var current_character_name := "Aria"
	func stall_net_search(mode: int, page: int, group: int, degree: int) -> void:
		sent.append("search %d %d %d %d" % [mode, page, group, degree])
	func stall_net_leave() -> void: sent.append("leave")
	func stall_net_buy(_r) -> void: sent.append("buy")

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await _run()
	KeyMap.reset_to_defaults_unsaved()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

## A key as the OS delivers it, with its character for a letter.
func _tap(code: Key) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.key_label = code
		ev.pressed = pressed
		var name := OS.get_keycode_string(code)
		if pressed and name.length() == 1:
			ev.unicode = name.to_lower().unicode_at(0)
		root.push_input(ev)
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
	KeyMap.reset_to_defaults_unsaved()
	var builder := UiBuilder.new(pk2, table)
	var ui := Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(ui)
	var panels: Control = (load(PANELS_PATH) as GDScript).new(builder)
	ui.add_child(panels)
	var line := LineEdit.new()
	line.name = "ChatLine"
	line.position = Vector2(10, 690)
	line.size = Vector2(300, 24)
	ui.add_child(line)
	await process_frame
	var t := func(key: String) -> String: return String(panels.call("_resolve_ui", key, key))
	var c: StallNetworkController = panels.call("_stall_network")
	var net := FakeNet.new()
	c.net = net
	var in_town := [true]
	var results: Array = []
	# World3D's host: "is_typing" is HudPanels.is_typing (a focused, visible
	# LineEdit), "run" sends "stall_network" to the controller's toggle.
	var keys := KeyInput.new({
		"is_typing": func() -> bool: return bool(panels.call("is_typing")),
		"run": func(action: String, _arg: int) -> String:
			var r := String(c.toggle(in_town[0], false)) if action == "stall_network" else "other: " + action
			results.append(r)
			return r,
	})
	root.add_child(keys)
	await process_frame

	# F opens it: the real window, centred.
	await _tap(KEY_F)
	_check(results == ["opened"] and c.is_open() and c.window.visible,
		"F opens the stall network window (got %s)" % [results])
	var bar := c.window.get_node_or_null("TitleBar") as Label if c.is_open() else null
	_check(bar != null and bar.text == t.call("UIIT_STT_WARENETWORK_TITLE"), "it is CNIFStallNetwork (\"%s\")" % t.call("UIIT_STT_WARENETWORK_TITLE"))
	# F again closes it; no search went out, so no 0x7462.
	await _tap(KEY_F)
	await process_frame
	_check(results.back() == "closed" and not c.is_open() and panels.get_node_or_null("Window_stallnetwork") == null,
		"F again closes it (got %s)" % [results.back()])
	_check(net.sent.is_empty(), "without a search nothing is sent (sent %s)" % [net.sent])
	# After a search the close sends 0x7462, as the window's X does.
	await _tap(KEY_F)
	_check(c.is_open(), "F opens it once more")
	if c.is_open():
		c.window.entered = true
	await _tap(KEY_F)
	_check(not c.is_open() and net.sent == ["leave"], "after a search F's close sends 0x7462 (sent %s)" % [net.sent])

	# Outside a town: item 120's refusal, 0x3c49's USE_CITY box, no window.
	in_town[0] = false
	await _tap(KEY_F)
	await process_frame
	var notice := panels.get_node_or_null("StallNetworkNotice") as PartyMatchConfirm
	_check(results.back() == "refused: not in a town" and not c.is_open() and notice != null
		and (notice.get_node("Message") as Label).text == t.call("UIIT_MSG_WARENETWORK_USE_CITY"),
		"outside a town F is refused with the USE_CITY box, as item 120 (got %s)" % [results.back()])
	if notice != null:
		notice.queue_free()
	in_town[0] = true

	# F typed into a text line is the line's.
	line.grab_focus()
	await process_frame
	var runs := results.size()
	await _tap(KEY_F)
	_check(results.size() == runs and not c.is_open() and line.text == "f",
		"F typed into a focused line opens nothing and is typed (ran %s, line '%s')" % [results.slice(runs), line.text])
	line.release_focus()
	line.text = ""
	await process_frame
	await _tap(KEY_F)
	_check(c.is_open(), "the line let go: F opens it")
	line.grab_focus()
	await process_frame
	await _tap(KEY_F)
	_check(c.is_open() and line.text == "f", "with the window up, F typed into the line does not close it")
	line.release_focus()
	line.text = ""
	await process_frame
	await _tap(KEY_F)
	_check(not c.is_open(), "and F closes it once the line lets go")

	# Rebound to K (the Key Map tab's Apply): K toggles it, F does nothing.
	var bound := KeyMap.default_keys()
	bound[33] = KEY_K
	KeyMap.set_keys(bound, false)
	runs = results.size()
	await _tap(KEY_F)
	_check(results.size() == runs and not c.is_open(), "rebound to K: F does nothing (ran %s)" % [results.slice(runs)])
	await _tap(KEY_K)
	_check(c.is_open(), "K opens it")
	await _tap(KEY_K)
	_check(not c.is_open(), "K closes it")
	KeyMap.reset_to_defaults_unsaved()

	# Escape closes it too: 0x79d620's list runs 0x799020(0) when window 0x96
	# is up (0x778a40), here through HudPanels' Escape.
	await _tap(KEY_F)
	_check(c.is_open(), "F opens it for the Escape check")
	net.sent.clear()
	if c.is_open():
		c.window.entered = true
	await _tap(KEY_ESCAPE)
	await process_frame
	_check(not c.is_open() and net.sent == ["leave"] and not bool(panels.call("is_open", "system")),
		"Escape closes it (0x7462 sent) and does not raise the System menu (sent %s)" % [net.sent])
	keys.queue_free()
	ui.queue_free()
	await process_frame
