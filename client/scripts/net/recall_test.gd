extends SceneTree

## RecallNet (round 686): the designate request and reply as the server
## writes them (server/internal/session/recall.go, 0x0111 / 0x0112 and
## retail's 0xb059 shape), the box's current-position line, and the box
## itself on a live talk window -- OK sends once, Cancel sends nothing.
## Methods are reached through has_method/call, so a build without them
## FAILS here rather than failing to parse.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var net_script := load("res://scripts/net/recall.gd") as GDScript
	var have_net := net_script != null and net_script.can_instantiate()
	_check(have_net, "RecallNet compiles")
	if have_net:
		_check(net_script.get("OP_DESIGNATE") == 0x0111 and net_script.get("OP_DESIGNATE_RESULT") == 0x0112,
			"the pair is 0x0111 / 0x0112, the server's")
		var enc: PackedByteArray = net_script.call("encode_designate", 20)
		_check(enc.size() == 2 and enc.decode_u16(0) == 20, "the request is the gate's teleportdata id, one u16 LE")
		var ok_r = net_script.call("decode_result", PackedByteArray([1]))
		_check(ok_r != null and ok_r.ok, "{1} decodes as a success")
		var no_r = net_script.call("decode_result", PackedByteArray([2, 4, 0]))
		_check(no_r != null and not no_r.ok and no_r.code == 4, "{2, 04 00} decodes as a refusal with code 4")
		_check(net_script.call("decode_result", PackedByteArray([2, 4])) == null, "a truncated refusal decodes to null")
		_check(net_script.call("decode_result", PackedByteArray([1, 0])) == null, "a success with a tail decodes to null")
		_check(net_script.call("current_position_line", "The current position : [%s]", "Donwhang") == "The current position : [Donwhang]",
			"the archive's template is filled with the zone name")
		_check(net_script.call("current_position_line", "UIIT_MSG_MSGBOX_SETREBIRTH_CURPOS", "Jangan") == "The current position : [Jangan]",
			"an unresolved key falls back to the table's English")
		_check(net_script.call("current_position_line", "%s and %d", "Jangan") == "The current position : [Jangan]",
			"a template the operator cannot fill safely falls back")

	# The box on a live talk window: it needs the running tree.
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the box check never reported (a script error stopped it)")
		quit(1))
	await process_frame
	var panels_script := load("res://scripts/ui/hud/hud_panels.gd") as GDScript
	var compiled := panels_script != null and panels_script.can_instantiate()
	_check(compiled, "HudPanels compiles")
	if compiled:
		var live: Node = panels_script.new()
		# Round 848: the box is the original's (MsgBoxInif kind 5), built from
		# MsgBoxFixture's synthetic message box layout, over the HUD.
		live.set("_builder", MsgBoxFixture.builder())
		root.add_child(live)
		var talk := HudWindow.new()
		talk.name = "Window_npctalk"
		live.add_child(talk)
		(live.get("_windows") as Dictionary)["npctalk"] = talk
		var has := live.has_method("open_recall_designate_prompt") and live.has_signal("recall_designate_requested")
		_check(has, "HudPanels has open_recall_designate_prompt and recall_designate_requested")
		var sent: Array = []
		if has:
			live.connect("recall_designate_requested", func() -> void: sent.append(1))
			live.call("open_recall_designate_prompt", "STORE_WC_GATE", "Donwhang")
		var box := live.get_node_or_null("RecallDesignatePrompt") as MsgBoxInif
		_check(box != null and talk.get_node_or_null("RecallDesignatePrompt") == null,
			"the designate line opens the original's box over the HUD, the talk box staying open")
		_check(box != null and box.line(0) == "The current position : [Donwhang]",
			"the box names the zone the player stands in (got '%s')" % [box.line(0) if box != null else "<none>"])
		_check(box != null and box.line(1) == "<UIIT_MSG_MSGBOX_SETREBIRTH_ASKCERTIFY>", "the box asks retail's question")
		_check(sent.is_empty(), "opening the box sends nothing")
		var cancel: BaseButton = box.button("GDR_MBIN_BTN_CANCEL") if box != null else null
		_check(cancel != null, "the box has Cancel")
		if cancel != null:
			cancel.pressed.emit()
		_check(sent.is_empty(), "Cancel sends nothing (got %d)" % sent.size())
		if has:
			live.call("open_recall_designate_prompt", "STORE_WC_GATE", "Donwhang")
		var again := live.get_node_or_null("RecallDesignatePrompt") as MsgBoxInif
		var ok_btn: BaseButton = again.button("GDR_MBIN_BTN_OK") if again != null else null
		_check(ok_btn != null, "the box has OK")
		if ok_btn != null:
			ok_btn.pressed.emit()
		_check(sent.size() == 1, "OK sends the request once (got %d)" % sent.size())
		live.queue_free()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
