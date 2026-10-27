extends SceneTree

## Round 834: the friend pane and the friend boxes against the real
## Media.pk2 (docs/protocol/friends.md 7.3, 7.4; FriendMsgBox, HudCosBox,
## GuildWindow).
##   godot4 --headless --path client --script res://scripts/ui/hud/friend834_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"

var _failures := 0

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

func _entry(id: int, n: String, ref: int, state: int) -> FriendNet.FriendEntry:
	var e := FriendNet.FriendEntry.new()
	e.character_id = id
	e.friend_name = n
	e.ref_obj_id = ref
	e.state = state
	return e

func _text(node: Node) -> String:
	if node is Label:
		return (node as Label).text
	var l := node.get_node_or_null(TwoDtBuilder.TEXT_NODE) as Label if node != null else null
	return l.text if l != null else "<none>"

func _button_text(b: Node) -> String:
	for c in b.find_children("*", "Label", true, false):
		return (c as Label).text
	return "<none>"

func _run() -> void:
	if not FileAccess.file_exists(MEDIA):
		print("SKIP (no %s)" % MEDIA)
		return
	var pk2 := Pk2Reader.open(MEDIA)
	_check(pk2 != null, "Media.pk2 opens")
	if pk2 == null:
		return
	root.size = Vector2i(1280, 720)
	await process_frame
	var builder := UiBuilder.new(pk2, null)
	var panels: Control = (load(PANELS_PATH) as GDScript).new(builder)
	root.add_child(panels)
	await process_frame
	panels.call("toggle", "community")
	await process_frame
	var window := panels.get("_windows").get("guild") as GuildWindow
	_check(window != null and window.visible and window.is_community_view(), "the community view opens")
	if window == null:
		return
	# Fifteen friends: rows 0..10 show the first eleven, the scroll reaches 4.
	var list: Array = []
	for i in 15:
		list.append(_entry(100 + i, "Friend%02d" % i, 1907 if i % 2 == 0 else 14875, 1 if i % 3 == 0 else 0))
	window.fill_friends(list)
	var rows := window.friend_rows()
	_check(rows.size() == 11, "eleven CNIFFriendSlot rows (got %d)" % rows.size())
	_check(_text(TwoDtBuilder.child(rows[0], GuildWindow.FRIEND_NAME)) == "Friend00"
		and _text(TwoDtBuilder.child(rows[10], GuildWindow.FRIEND_NAME)) == "Friend10", "rows 0..10 show the first eleven")
	var count := TwoDtBuilder.find_path(window.community_root, [GuildWindow.ID_FRIEND, GuildWindow.FRIEND_COUNT])
	_check(_text(count) == ": 15 / 20", "the count ': 15 / 20' (no leading space, c:0xd8d998; got '%s')" % _text(count))
	var lamp0 := TwoDtBuilder.child(rows[0], GuildWindow.FRIEND_LAMP) as TextureRect
	var lamp1 := TwoDtBuilder.child(rows[1], GuildWindow.FRIEND_LAMP) as TextureRect
	_check(lamp0 != null and lamp1 != null and lamp0.texture == builder.load_texture(GuildWindow.FRIEND_LAMP_OFF)
		and lamp1.texture == builder.load_texture(GuildWindow.FRIEND_LAMP_ON), "state 1 lamp off, state 0 lamp on")
	var race0 := TwoDtBuilder.child(rows[0], GuildWindow.FRIEND_RACE) as TextureRect
	_check(race0 != null and race0.visible, "the race icon is shown")
	window.friend_scroll_to(99)
	_check(window.friend_scroll_line() == 4 and _text(TwoDtBuilder.child(rows[0], GuildWindow.FRIEND_NAME)) == "Friend04"
		and _text(TwoDtBuilder.child(rows[10], GuildWindow.FRIEND_NAME)) == "Friend14", "scrolled to the end: line 4, rows show 4..14")
	window.friend_scroll_to(0)
	# Selection and the three buttons.
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	rows[2].gui_input.emit(press)
	_check(window.selected_friend == 102, "a press on row 2 selects Friend02")
	var whispers: Array = []
	var deletes: Array = []
	var adds: Array = []
	window.friend_whisper_requested.connect(func(n: String) -> void: whispers.append(n))
	window.friend_delete_requested.connect(func(id: int, n: String) -> void: deletes.append([id, n]))
	window.friend_add_requested.connect(func() -> void: adds.append(1))
	var pane := TwoDtBuilder.child(window.community_root, GuildWindow.ID_FRIEND)
	(TwoDtBuilder.child(pane, GuildWindow.FRIEND_WHISPER) as BaseButton).pressed.emit()
	(TwoDtBuilder.child(pane, GuildWindow.FRIEND_DELETE) as BaseButton).pressed.emit()
	(TwoDtBuilder.child(pane, GuildWindow.FRIEND_ADD) as BaseButton).pressed.emit()
	_check(whispers == ["Friend02"] and deletes == [[102, "Friend02"]] and adds.size() == 1, "Whisper, Delete and Add report the selection")
	# A push removing the selected friend drops the selection.
	var shorter := list.duplicate()
	shorter.remove_at(2)
	window.fill_friends(shorter)
	_check(window.selected_friend == 0, "a removed friend takes the selection with them")
	# The boxes (adds above opened the Add box through HudPanels).
	await process_frame
	var add_box := panels.get("_friend_add_box") as HudCosBox
	_check(add_box != null and add_box.size == Vector2(306, 151) and add_box.edit != null
		and add_box.edit.position == Vector2(19, 73) and add_box.edit.size == Vector2(266, 20),
		"the Add box: 306 x 151, the edit at (19, 73) 266 x 20 (0x64274d)")
	var req := FriendNet.Request.new()
	req.job = 3
	req.asker_jid = 9
	req.asker_name = "Asker"
	var answers: Array = []
	panels.friend_answer_requested.connect(func(r: FriendNet.Request, ok: bool) -> void: answers.append(ok))
	panels.call("show_friend_request", req)
	panels.call("show_friend_request", req)
	await process_frame
	var box := panels.call("friend_request_box") as FriendMsgBox
	_check(box != null and box.size == Vector2(360, 151), "box 0x23: 360 x 151")
	if box != null:
		var ok := box.node("GDR_MBIN_BTN_OK")
		var no := box.node("GDR_MBIN_BTN_CANCEL")
		var cert := box.node("GDR_MBIN_BTN_CERTIFY")
		_check(ok.position == Vector2(98, 114) and no.position == Vector2(186, 114) and not cert.visible,
			"Accept at (98, 114), the right button at (186, 114), CERTIFY hidden")
		_check(_button_text(ok) == "UIIT_STT_ACCEPT" and _button_text(no) == "UIIT_CTL_NO",
			"captions UIIT_STT_ACCEPT and the layout's UIIT_CTL_NO (got '%s' / '%s')" % [_button_text(ok), _button_text(no)])
		_check(_text(box.node("GDR_MBIN_STATIC_MESSAGE1")) == "'Asker'", "the asker's name in quotes")
		(no as BaseButton).pressed.emit()
		await process_frame
		await process_frame
		_check(answers == [false], "No answers 0")
		var second := panels.call("friend_request_box") as FriendMsgBox
		_check(second != null and second != box, "the queued request opens next")
		panels.call("close_friend_request")
		await process_frame
	var added := panels.call("show_friend_added", "Bo", "Me") as FriendMsgBox
	_check(added != null and added.node("GDR_MBIN_BTN_OK").position == Vector2(141, 114)
		and not added.node("GDR_MBIN_BTN_CANCEL").visible, "box 0x22: one button at (141, 114)")
	var del := panels.call("open_friend_delete", 102, "Friend02") as PartyMatchConfirm
	_check(del != null and del.size == Vector2(360, 151), "the delete question: 360 x 151, Yes / No")
	panels.queue_free()
