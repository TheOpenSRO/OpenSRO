extends SceneTree

## Round 844 (lane U): the union's client side against the real Media.pk2 --
## UnionOps (0x70FB..0x70FD, 0x3080 kind 6 and its answer, the replies),
## the guild window's union pane (CNIFAllianceGuild: the lead guild, the rows
## and their colours, the selected guild, the three buttons by role, the two
## questions, the sort headers), box 0x1d (its size, title and shifts), the
## union line's guild prefix (0x7ada5a) and the union crest's cache entry.
## READ addresses are in union_ops.gd, union_pane.gd and guild_msg_box.gd.
##   client/tools/remote_godot.sh script '--script res://scripts/ui/hud/union844_test.gd'

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
	var watchdog := create_timer(120.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	_test_ops()
	_test_crest_cache()
	await _run()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

func _str(t: String) -> PackedByteArray:
	var raw := t.to_utf8_buffer()
	var b := PackedByteArray([raw.size() & 0xff, raw.size() >> 8])
	b.append_array(raw)
	return b

func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

func _entry(id: int, n: String, level: int, master: String, model: int, members: int) -> PackedByteArray:
	var b := _u32(id)
	b.append_array(_str(n))
	b.append(level)
	b.append_array(_str(master))
	b.append_array(_u32(model))
	b.append(members)
	return b

## 0x3102 as the server's guild.EncodeUnionInfo writes it.
func _info(uid: int, leader: int, entries: Array) -> PackedByteArray:
	var b := _u32(uid)
	b.append_array(_u32(0))
	b.append_array(_u32(leader))
	b.append(entries.size())
	for e in entries:
		b.append_array(e)
	return b

func _test_ops() -> void:
	var ops := UnionOps.new()
	var sent: Array = []
	ops.send = func(op: int, p: PackedByteArray) -> void: sent.append([op, p])
	ops.player_name = func(uid: int) -> String: return {77: "Bram", 78: "Loner"}.get(uid, "")
	ops.player_guild = func(uid: int) -> String: return {77: "Beta"}.get(uid, "")
	var boxes: Array = []
	var notices: Array = []
	ops.request_box.connect(func(u: int, g: String) -> void: boxes.append([u, g]))
	ops.notice.connect(func(k: String, _a: Array, c: int) -> void: notices.append([k, c]))
	_check(not ops.request(0, 5) and not ops.request(5, 5) and sent.is_empty(), "Apply sends nothing without a target or for the player")
	_check(ops.request(77, 5) and sent[-1][0] == 0x70FB and sent[-1][1] == PackedByteArray([77, 0, 0, 0]), "0x70FB {u32 target}")
	ops.leave()
	_check(sent[-1][0] == 0x70FC and sent[-1][1].is_empty(), "0x70FC: no body")
	ops.expel(0x01020304)
	_check(sent[-1][0] == 0x70FD and sent[-1][1] == PackedByteArray([4, 3, 2, 1]), "0x70FD {u32 guild id}")
	_check(UnionOps.encode_answer(true) == PackedByteArray([1, 1]) and UnionOps.encode_answer(false) == PackedByteArray([2, 0, 0]),
		"box 0x1d's answer: {1, 1} / {2, u16 0} (c:0x798667)")
	_check(not ops.handle(0x3080, PackedByteArray([5, 77, 0, 0, 0])), "0x3080 kind 5 is not the union's")
	ops.handle(0x3080, PackedByteArray([6, 78, 0, 0, 0]))
	_check(boxes.is_empty() and ops.pending_requester == 0, "a requester with no guild line: dropped")
	ops.handle(0x3080, PackedByteArray([6, 77, 0, 0, 0]))
	_check(boxes.size() == 1 and boxes[0] == [77, "Beta"] and ops.pending_requester == 77, "kind 6: box 0x1d with the requester's guild")
	var n := sent.size()
	ops.answer(false)
	_check(sent.size() == n + 1 and sent[-1] == [0x3080, PackedByteArray([2, 0, 0])] and ops.pending_requester == 0, "No answers {2, 0, 0}")
	ops.answer(true)
	_check(sent.size() == n + 1, "no box, no answer")
	ops.handle(0xB0FB, PackedByteArray([2, 0x2b, 0x4c]))
	_check(notices[-1] == ["UIIT_MSG_GUILDERR_TOO_LOW_JOINER_ALLIANCE", 0x4c2b], "B0FB 0x4c2b: the joiner's level line")
	ops.handle(0xB0FB, PackedByteArray([2, 0x2e, 0x4c]))
	_check(notices[-1] == ["", 0x4c2e], "B0FB 0x4c2e (the target's no): no text")
	ops.handle(0xB0FD, PackedByteArray([2, 0x1e, 0x4c]))
	_check(notices[-1][0] == "UIIT_MSG_GUILDERR_PERMISSION_DENIED", "B0FD 0x4c1e")
	var m := notices.size()
	ops.handle(0xB0FC, PackedByteArray([1]))
	_check(notices.size() == m, "B0FC {1}: nothing shown")

func _test_crest_cache() -> void:
	var c := CrestCache.new()
	# A kept file from an earlier run would answer without asking.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CrestCache.DISK_DIR.path_join("A9.rd")))
	var asked: Array = []
	c.send = func(op: int, p: PackedByteArray) -> void: asked.append([op, p])
	c.palette.resize(768)
	var changed: Array = []
	c.changed.connect(func(g: String) -> void: changed.append(g))
	c.note_union("Alpha", 9, 0)
	_check(changed.is_empty() and c.union_texture_for("Alpha") == null and asked.is_empty(), "no union crest: nothing asked")
	var up := PackedByteArray([2, 9, 0, 0, 0, 2])
	up.append_array(_str("Alpha"))
	up.append_array(_str("Beta"))
	up.append_array(_u32(3))
	var u := c.handle_update(up)
	_check(u != null and u.kind == 2 and changed == ["Alpha", "Beta"], "0x3257 type 2: both guilds' entries changed")
	_check(c.union_texture_for("Beta") == null and asked.size() == 1 and asked[0][1] == CrestNet.encode_get(2, 9, 3),
		"the union crest is asked for (kind 2, union 9, rev 3)")
	var data := PackedByteArray([2, 9, 0, 0, 0, 3, 0, 0, 0, 1])
	var px := PackedByteArray()
	px.resize(256)
	data.append_array(px)
	changed.clear()
	c.handle_data(data)
	_check(changed.has("Alpha") and changed.has("Beta") and c.union_texture_for("Alpha") != null, "its bytes: the lines remade, the picture there")

func _text(node: Node) -> String:
	if node is Label:
		return (node as Label).text
	var l := node.get_node_or_null(TwoDtBuilder.TEXT_NODE) as Label if node != null else null
	return l.text if l != null else "<none>"

func _colour(node: Node) -> Color:
	var l := node.get_node_or_null(TwoDtBuilder.TEXT_NODE) as Label if node != null else null
	return l.get_theme_color("font_color") if l != null else Color.BLACK

func _member(id: int, n: String, cls: int) -> GuildData.Member:
	var m := GuildData.Member.new()
	m.character_id = id
	m.member_name = n
	m.member_class = cls
	return m

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
	_check(table != null, "textuisystem.txt reads")
	root.size = Vector2i(1280, 720)
	await process_frame
	var builder := UiBuilder.new(pk2, table)
	# The player masters Alpha (level 3), the union's first guild.
	var nc: Node = root.get_node_or_null("NetClient")
	_check(nc != null, "the NetClient autoload")
	if nc == null:
		return
	var d: GuildData = nc.get("guild_data")
	d.in_guild = true
	d.guild_id = 1
	d.guild_name = "Alpha"
	d.level = 3
	d.own_name = "Aria"
	d.members = [_member(11, "Aria", GuildData.CLASS_MASTER)] as Array[GuildData.Member]
	var panels: Control = (load(PANELS_PATH) as GDScript).new(builder)
	root.add_child(panels)
	await process_frame
	panels.call("toggle", "guild")
	await process_frame
	var window := panels.get("_windows").get("guild") as GuildWindow
	_check(window != null and window.visible and window.union_pane != null, "the guild window opens with its union pane")
	if window == null or window.union_pane == null:
		return
	var up := window.union_pane
	# The Relations tab (73) shows 164 with the union sub-tab (87) checked.
	var tab := window.control([73]) as BaseButton
	_check(tab != null, "the Relations tab")
	if tab != null:
		tab.pressed.emit()
	await process_frame
	_check(up.pane() != null and up.pane().is_visible_in_tree(), "the union pane (86) shows under Relations")
	# No union: 137 shown, the upper parts hidden; the master's Apply only.
	up.on_union_changed()
	_check(up._part(UnionPane.NO_UNION).visible and not up._part(UnionPane.LEAD_NAME).visible, "no union: 'Not in the alliance' (137)")
	_check(up._part(UnionPane.NO_SELECTION).visible, "no selection: 'No guild is selected.' (136)")
	_check(not (up._part(UnionPane.APPLY) as BaseButton).disabled and (up._part(UnionPane.SECEDE) as BaseButton).disabled
		and (up._part(UnionPane.EXPEL) as BaseButton).disabled, "a master in no union: Apply on, Secede and Expel off")
	# The union: Alpha (lead, 11 members, Lv3), Beta (Lv2, 4), Gamma (Lv5, 30).
	d.union.parse_info(_info(9, 1, [_entry(3, "Gamma", 5, "Gil", 14875, 30), _entry(1, "Alpha", 3, "Aria", 1907, 11),
		_entry(2, "Beta", 2, "Bram", 14875, 4)]))
	await process_frame
	_check(not up._part(UnionPane.NO_UNION).visible and _text(up._part(UnionPane.LEAD_NAME)) == "Alpha"
		and _text(up._part(UnionPane.LEAD_MASTER)) == "Aria" and _text(up._part(UnionPane.COUNT)) == "3/8",
		"the lead guild Alpha, its master Aria, '3/8'")
	var rows := up.rows()
	_check(rows.size() == 10, "ten CNIFAllianceSlot rows, 271..307 (got %d)" % rows.size())
	_check(_text(TwoDtBuilder.child(rows[0], UnionPane.ROW_NAME)) == "Alpha" and _text(TwoDtBuilder.child(rows[1], UnionPane.ROW_NAME)) == "Beta"
		and _text(TwoDtBuilder.child(rows[2], UnionPane.ROW_NAME)) == "Gamma", "the map's order: ascending ids")
	_check(not TwoDtBuilder.child(rows[3], UnionPane.ROW_NAME).visible, "an empty row hides its name")
	_check(_colour(TwoDtBuilder.child(rows[0], UnionPane.ROW_NAME)) == TwoDtBuilder.argb(0xffffb451)
		and _colour(TwoDtBuilder.child(rows[1], UnionPane.ROW_NAME)) == TwoDtBuilder.argb(0xffffffff),
		"the lead guild's row 0xffffb451, the rest white")
	_check(_text(TwoDtBuilder.child(rows[2], UnionPane.ROW_LEVEL)) == "Lv 5", "the level column (UIIT_STT_LV_LEVEL): '%s'" % _text(TwoDtBuilder.child(rows[2], UnionPane.ROW_LEVEL)))
	_check(not (up._part(UnionPane.APPLY) as BaseButton).disabled and not (up._part(UnionPane.SECEDE) as BaseButton).disabled
		and not (up._part(UnionPane.EXPEL) as BaseButton).disabled, "the lead guild's master: all three on")
	# Select Gamma's row: the lower parts with its members over Lv5's cap.
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	rows[2].gui_input.emit(press)
	_check(up.selected == 3 and _text(up._part(UnionPane.SEL_NAME)) == "Gamma" and _text(up._part(UnionPane.SEL_MASTER)) == "Gil"
		and _text(up._part(UnionPane.SEL_MEMBERS)) == "30/50" and not up._part(UnionPane.NO_SELECTION).visible,
		"Gamma selected: name, master, '30/50'")
	# Round 844 (merge): the row's own art is swapped to com_bar01select_
	# (GuildWindow._mark_row, lane G), as 0x5b7090 does.
	_check(GuildWindow.row_selected(rows[2]) and not GuildWindow.row_selected(rows[0]), "its row's selected bar")
	# The sort headers: by name; by level (highest first).
	up.set_sort(UnionPane.SORT_LEVEL)
	_check(_text(TwoDtBuilder.child(rows[0], UnionPane.ROW_NAME)) == "Gamma" and _text(TwoDtBuilder.child(rows[2], UnionPane.ROW_NAME)) == "Beta", "Lv: 5, 3, 2")
	up.set_sort(UnionPane.SORT_NAME)
	_check(_text(TwoDtBuilder.child(rows[0], UnionPane.ROW_NAME)) == "Alpha" and _text(TwoDtBuilder.child(rows[2], UnionPane.ROW_NAME)) == "Gamma", "Name: A, B, G")
	# Expel's question: Gamma's name; Yes emits the guild.
	var expelled: Array = []
	up.expel_confirmed.connect(func(id: int) -> void: expelled.append(id))
	(up._part(UnionPane.EXPEL) as BaseButton).pressed.emit()
	await process_frame
	var q := panels.get_node_or_null("UnionExpelConfirm") as PartyMatchConfirm
	_check(q != null and q.size == Vector2(360, 151), "Expel opens a 360 x 151 question (GInterface 0x788270)")
	if q != null:
		var msg := q.get_node_or_null("Message") as Label
		_check(msg != null and msg.text == "Will you ban [Gamma]guild from the guild alliance?", "its text names Gamma: '%s'" % (msg.text if msg != null else ""))
		var cap := q.get_node_or_null("Caption") as Label
		_check(cap != null and cap.text == "Expel", "its caption UIIT_STT_GUILD_RESPECT_ALLY_EXPULSION: '%s'" % (cap.text if cap != null else ""))
		q._find_button(true).pressed.emit()
		_check(expelled == [3], "Yes: 0x70FD for Gamma")
	await process_frame
	var left: Array = []
	up.leave_confirmed.connect(func() -> void: left.append(1))
	(up._part(UnionPane.SECEDE) as BaseButton).pressed.emit()
	await process_frame
	var lq := panels.get_node_or_null("UnionLeaveConfirm") as PartyMatchConfirm
	_check(lq != null, "Secede opens its question")
	if lq != null:
		lq._find_button(true).pressed.emit()
		_check(left == [1], "Yes: 0x70FC")
	# Another union guild's master: Apply off, Secede on, Expel off.
	d.own_name = "Bram"
	d.members = [_member(12, "Bram", GuildData.CLASS_MASTER)] as Array[GuildData.Member]
	up.on_shown()
	_check((up._part(UnionPane.APPLY) as BaseButton).disabled and not (up._part(UnionPane.SECEDE) as BaseButton).disabled
		and (up._part(UnionPane.EXPEL) as BaseButton).disabled, "a member guild's master: Secede only")
	# A plain member: all off.
	d.members = [_member(11, "Aria", GuildData.CLASS_MASTER), _member(12, "Bram", GuildData.CLASS_MEMBER)] as Array[GuildData.Member]
	up.on_shown()
	_check((up._part(UnionPane.APPLY) as BaseButton).disabled and (up._part(UnionPane.SECEDE) as BaseButton).disabled,
		"a plain member: all off")
	# 0x38F5 0x12 {3}: the union gone, the pane back to 'Not in the alliance'.
	var r := GuildData._Reader.new(PackedByteArray([3]))
	d.union.apply_out(r, "Alpha")
	await process_frame
	_check(up._part(UnionPane.NO_UNION).visible and not TwoDtBuilder.child(rows[0], UnionPane.ROW_NAME).visible, "broken: no rows, 137")
	# Box 0x1d with the real layout.
	var box := GuildMsgBox.new()
	_check(box.build_guild_box(builder, GuildMsgBox.Kind.UNION_REQUEST, "", "Beta"), "box 0x1d builds")
	_check(box.size == Vector2(470, 144) and box.name == "UnionRequest", "0x1d6 x 0x90 (got %s)" % box.size)
	var m1 := box.node("GDR_MBIN_STATIC_MESSAGE1")
	_check(m1 != null and _text(m1) == "The leader of [Beta] guild proposed an alliance with you. Do you accept?",
		"its line names the requester's guild: '%s'" % _text(m1))
	var ok := box.node("GDR_MBIN_BTN_OK")
	var ref := GuildMsgBox.new()
	ref.build_guild_box(builder, GuildMsgBox.Kind.LEAVE)
	var ok0 := ref.node("GDR_MBIN_BTN_OK")
	var m0 := ref.node("GDR_MBIN_STATIC_MESSAGE1")
	_check(ok != null and ok0 != null and is_equal_approx(ok.position.x - ok0.position.x, 0x51), "OK 0x51 right of the plain box's")
	_check(m1 != null and m0 != null and is_equal_approx(m1.position.x - m0.position.x, 0x4c), "the line 0x4c right")
	_check(not box.node("GDR_MBIN_BTN_CERTIFY").visible, "CERTIFY hidden")
	box.free()
	ref.free()
	# The union line's prefix (0x7ada5a).
	var chat := HudChat.new(builder)
	chat.union_guild = func() -> String: return "Alpha"
	var req := chat.request_for("%hello")
	_check(int(req.get("type", 0)) == HudChat.TYPE_UNION and String(req.get("message", "")) == "-Alpha): hello", "'%hello' goes out as '-Alpha): hello'")
	_check(chat.format_line(HudChat.TYPE_UNION, "Bram", "-Beta): yo")["text"].ends_with("-Beta): yo"), "a heard union line: name(Union-Beta): yo")
	chat.free()
	panels.queue_free()
	d.clear()
	await process_frame
