extends SceneTree

## Round 822: the guild's message boxes (GuildMsgBox) against UI_SILKMALL::
## FUN_00644c90's purposes 0x0F, 0x12, 0x13, 0x14 and the guild window's ban
## question (0x5b63e0 index 2). The layout is synthetic but carries
## ifmessagebox.txt's MsgBoxINIF / MsgBoxSimple names, IDs and rects (as
## hud_party_pane_test.gd does); the texts are each key in brackets. No game
## data.
##   godot4 --headless --path client --script res://scripts/ui/hud/guild822_ui_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _c(control_name: String, type: String, rect: String, id: int, text: String = "",
		ddj: String = "", halign: int = 0, style: int = 0) -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tHAlign=INTEGER,\"%d\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tStyle=INTEGER,\"%d\"\n\t\tText=STRING,\"%s\"\n\t}\n" % [
		control_name, type, ddj, halign, id, rect, style, text]

func _section(section: String, body: String) -> String:
	return "Section = %s,\"0,0,0,0\",\"0\"\n{\n%s}\n" % [section, body]

func _ifmessagebox() -> String:
	var inif := ""
	inif += _c("GDR_MBIN_BTN_CERTIFY", "CIFButton", "112,99,76,24", 202, "UIIT_CTL_CONFIRM", "", 1)
	inif += _c("GDR_MBIN_BTN_CANCEL", "CIFButton", "152,99,76,24", 201, "UIIT_CTL_NO", "", 1)
	inif += _c("GDR_MBIN_BTN_OK", "CIFButton", "72,99,76,24", 200, "UIIT_CTL_YES", "", 1)
	inif += _c("GDR_MBIN_STATIC_MESSAGE5", "CIFStatic", "6,154,294,12", 8, "", "", 1)
	inif += _c("GDR_MBIN_STATIC_MESSAGE4", "CIFStatic", "6,66,288,12", 4, "", "", 1)
	inif += _c("GDR_MBIN_STATIC_MESSAGE3", "CIFStatic", "6,66,288,12", 3, "", "", 1)
	inif += _c("GDR_MBIN_STATIC_MESSAGE2", "CIFStatic", "6,70,300,12", 2, "", "", 1)
	inif += _c("GDR_MBIN_STATIC_MESSAGE1", "CIFStatic", "0,52,300,12", 1, "", "", 1)
	var simple := ""
	simple += _c("GDR_MBSIMPLE_TEXT", "CIFTextBox", "0,52,240,14", 251)
	simple += _c("GDR_MBSIMPLE_BTN_OK", "CIFButton", "72,99,76,24", 252, "UIIT_CTL_YES", "", 1)
	simple += _c("GDR_MBSIMPLE_BTN_CANCEL", "CIFButton", "152,99,76,24", 253, "UIIT_CTL_NO", "", 1)
	return "Interface Text\n\n" + _section("MsgBoxINIF", inif) + _section("MsgBoxSimple", simple)

func _builder() -> UiBuilder:
	var rows := PackedStringArray()
	for k in ["UIIT_STT_AGREEMENT_BOX", "UIIT_STT_CONFIRM_BOX", "UIIT_MSG_GUILD_QUESTION_CREATE_CONFIRM",
			"UIIT_MSG_GUILD_BREAK_CONFIRM", "UIIT_MSG_GUILD_SECESSION_CONFIRM", "UIIT_CTL_YES", "UIIT_CTL_NO",
			"UIIT_MSG_GUILD_USER_CREST", "UIIT_MSG_GUILD_USER_CREST_FILE", "UIIT_MSG_GUILD_USER_CREST_FOLDER",
			"UIIT_MSG_GUILD_CREST_REGISTER", "UIIT_MSG_UNION_USER_CREST", "UIIT_MSG_UNION_USER_CREST_FOLDER",
			"UIIT_CTL_UNION_CREST_REGISTER", "UIIT_MSG_UNION_CREST_REGISTER", "UIIT_MSG_GUILD_CREST_DELETE",
			"UIIT_MSG_GUILD_CREST_REGISTER_COMPLETE", "UIIT_MSG_CREST_REGISTER_INFORMATION_01",
			"UIIT_MSG_CREST_REGISTER_INFORMATION_04", "UIIT_CTL_CONFIRM", "UIIT_MSG_GUILD_CREST_DELETE_COMPLETE"]:
		rows.append("1\t%s\t\t\t\t\t\t\t<%s>" % [k, k])
	rows.append("1\tUIIT_MSG_GUILD_JOIN_REQUEST\t\t\t\t\t\t\t[%s]has applied for your guild.")
	rows.append("1\tUIIT_MSG_GUILD_QUESTION_JOIN\t\t\t\t\t\t\tDo you want to join [%s]guild?")
	rows.append("1\tUIIT_MSG_GUILD_QUESTION_CREATE\t\t\t\t\t\t\tIf you pay 0.5 million gold, [%s]guild will be created")
	rows.append("1\tUIIT_MSG_GUILD_QUESTION_EXPULSION_ANYONE\t\t\t\t\t\t\tWill you ban [%s]from the guild?")
	var builder := UiBuilder.new(null, UiTextTable.parse(("\n".join(rows)).to_utf16_buffer()))
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\ifmessagebox.txt"] = UiLayoutParser.parse(_ifmessagebox())
	return builder

func _text(n: Node) -> String:
	if n == null:
		return "(null)"
	if n is Label:
		return (n as Label).text
	for child_name in ["Text", "ButtonLabel"]:
		var l := n.get_node_or_null(child_name) as Label
		if l != null:
			return l.text
	return "(no text)"

## Round 824: the crest items' boxes (GuildMsgBox.build_crest_box, notice_box)
## and the HUD's crest flow.
func _crest_boxes(builder: UiBuilder, live: Node) -> void:
	var ask := GuildMsgBox.new()
	_check(ask.build_crest_box(builder, GuildMsgBox.Kind.CREST), "box 0x15 builds")
	_check(ask.size == Vector2(460, 210), "0x15 is 0x1cc x 0xd2 (got %s)" % [ask.size])
	var lines := []
	for i in 4:
		var n := ask.node(GuildMsgBox.MESSAGES[i])
		lines.append([_text(n), n.position, n.size])
	_check(lines[0][0] == "<UIIT_MSG_GUILD_USER_CREST>" and lines[1][0] == "<UIIT_MSG_GUILD_USER_CREST_FILE>"
		and lines[2][0] == "<UIIT_MSG_GUILD_USER_CREST_FOLDER>" and lines[3][0] == "<UIIT_MSG_GUILD_CREST_REGISTER>",
		"0x15's four lines, in order")
	_check(lines[0][1] == Vector2(50, 51) and lines[1][1] == Vector2(50, 68) and lines[2][1] == Vector2(50, 85)
		and lines[3][1] == Vector2(50, 122) and lines[0][2].x == 359.0, "at (0x32, 0x33 / 0x44 / 0x55 / 0x7a), 0x167 wide (got %s)" % [lines])
	_check(ask.node("GDR_MBIN_BTN_OK").position == Vector2(152, 159) and ask.node("GDR_MBIN_BTN_CANCEL").position == Vector2(232, 159),
		"OK and Cancel moved (+0x50, +0x3c)")
	_check(_text(ask.node("GDR_MBIN_STATIC_MESSAGE5")) == "", "the fifth line empty")
	ask.free()
	var uni := GuildMsgBox.new()
	uni.build_crest_box(builder, GuildMsgBox.Kind.UNION_CREST)
	_check(_text(uni.node("GDR_MBIN_STATIC_MESSAGE3")) == "<UIIT_CTL_UNION_CREST_REGISTER>", "0x18's third line is the CTL key")
	uni.free()
	var del := GuildMsgBox.new()
	del.build_crest_box(builder, GuildMsgBox.Kind.CREST_DELETE)
	_check(del.size == Vector2(308, 148) and _text(del.node("GDR_MBIN_STATIC_MESSAGE1")) == "<UIIT_MSG_GUILD_CREST_DELETE>",
		"0x16: the 308 x 148 box, GUILD_CREST_DELETE")
	del.free()
	var done := GuildMsgBox.new()
	done.build_crest_box(builder, GuildMsgBox.Kind.CREST_DONE)
	_check(done.node("GDR_MBIN_STATIC_MESSAGE1").position == Vector2(50, 55) and done.node("GDR_MBIN_STATIC_MESSAGE5").position == Vector2(50, 141)
		and _text(done.node("GDR_MBIN_STATIC_MESSAGE5")) == "<UIIT_MSG_CREST_REGISTER_INFORMATION_04>", "0x1a's five lines")
	_check(done.node("GDR_MBIN_BTN_OK").position == Vector2(192, 159) and _text(done.node("GDR_MBIN_BTN_OK")) == "<UIIT_CTL_CONFIRM>"
		and not done.node("GDR_MBIN_BTN_CANCEL").visible, "0x1a: one Confirm, moved (+0x78, +0x3c)")
	done.free()
	var note := GuildMsgBox.notice_box(builder, "UIIT_MSG_GUILD_CREST_DELETE_COMPLETE")
	var msg := note.get_node_or_null("Message") as Label if note != null else null
	_check(msg != null and msg.text == "<UIIT_MSG_GUILD_CREST_DELETE_COMPLETE>", "the delete's notice")
	if note != null:
		note.free()
	# The HUD: the box's OK goes out as crest_confirmed(slot, kind).
	var confirmed: Array = []
	live.connect("crest_confirmed", func(sl: int, k: int) -> void: confirmed.append([sl, k]))
	var box: GuildMsgBox = live.call("open_crest_box", 12, GuildMsgBox.Kind.CREST)
	_check(box != null and box.position == Vector2(512 - 0x9a, 384 - 0x4a), "placed as 0x6ec5d0 places it, before the resize")
	(box.node("GDR_MBIN_BTN_OK") as BaseButton).pressed.emit()
	_check(confirmed == [[12, GuildMsgBox.Kind.CREST]], "OK: crest_confirmed(12, 0x15)")
	live.call("crest_used", "ITEM_ETC_GUILD_CREST_USER")
	var shown := (live.get("_guild_boxes") as Dictionary).get(GuildMsgBox.Kind.CREST_DONE) as GuildMsgBox
	_check(shown != null and shown.get_parent() == live, "a register's success opens box 0x1a")

func _initialize() -> void:
	var builder := _builder()
	var view := Vector2(1024, 768)

	var inv := GuildMsgBox.new()
	_check(inv.build_guild_box(builder, GuildMsgBox.Kind.INVITE, "Aria", "Verizon"), "box 0x0F builds")
	root.add_child(inv)
	_check(inv.size == Vector2(308, 148), "0x0F keeps 0x6ec5d0's 308x148 (got %s)" % [inv.size])
	_check(inv.caption.text == "<UIIT_STT_AGREEMENT_BOX>", "0x0F's title is the agreement box")
	_check(_text(inv.node("GDR_MBIN_STATIC_MESSAGE1")) == "[Aria]has applied for your guild."
		and _text(inv.node("GDR_MBIN_STATIC_MESSAGE2")) == "Do you want to join [Verizon]guild?", "0x0F's two lines (got %s / %s)" % [_text(inv.node("GDR_MBIN_STATIC_MESSAGE1")), _text(inv.node("GDR_MBIN_STATIC_MESSAGE2"))])
	_check(not inv.node("GDR_MBIN_BTN_CERTIFY").visible, "+0x808 hidden")
	inv.place_on(view)
	_check(inv.position == Vector2(512 - 0x9a, 384 - 0x4a), "placed as 0x6ec5d0 places it")
	var answers: Array = []
	inv.accepted.connect(func(_t: String) -> void: answers.append(true))
	inv.cancelled.connect(func() -> void: answers.append(false))
	(inv.node("GDR_MBIN_BTN_CANCEL") as BaseButton).pressed.emit()
	_check(answers == [false], "Cancel answers no")

	var cr := GuildMsgBox.new()
	_check(cr.build_guild_box(builder, GuildMsgBox.Kind.CREATE, "", "Verizon"), "box 0x12 builds")
	_check(cr.size == Vector2(440, 144), "0x12 is 0x1b8 x 0x90")
	_check(cr.caption.text == "<UIIT_STT_CONFIRM_BOX>", "0x12's title is the confirm box")
	var m1 := cr.node("GDR_MBIN_STATIC_MESSAGE1")
	_check(m1.position.x == 0x42 and cr.node("GDR_MBIN_BTN_OK").position.x == 72 + 0x42
		and cr.node("GDR_MBIN_BTN_CANCEL").position.x == 152 + 0x42, "0x12 moves the lines and buttons 0x42 right")
	_check(_text(m1) == "If you pay 0.5 million gold, [Verizon]guild will be created"
		and _text(cr.node("GDR_MBIN_STATIC_MESSAGE2")) == "<UIIT_MSG_GUILD_QUESTION_CREATE_CONFIRM>", "0x12's two lines")
	var oks := [0]
	cr.accepted.connect(func(_t: String) -> void: oks[0] += 1)
	root.add_child(cr)
	(cr.node("GDR_MBIN_BTN_OK") as BaseButton).pressed.emit()
	_check(oks[0] == 1, "0x12's OK accepts once")

	var dis := GuildMsgBox.new()
	_check(dis.build_guild_box(builder, GuildMsgBox.Kind.DISBAND), "box 0x13 builds")
	_check(dis.caption.text == "<UIIT_STT_AGREEMENT_BOX>" and _text(dis.node("GDR_MBIN_STATIC_MESSAGE1")) == "<UIIT_MSG_GUILD_BREAK_CONFIRM>"
		and _text(dis.node("GDR_MBIN_STATIC_MESSAGE2")) == "", "0x13: agreement, BREAK_CONFIRM (got %s / %s)" % [dis.caption.text, _text(dis.node("GDR_MBIN_STATIC_MESSAGE1"))])
	var lv := GuildMsgBox.new()
	_check(lv.build_guild_box(builder, GuildMsgBox.Kind.LEAVE), "box 0x14 builds")
	_check(lv.caption.text == "<UIIT_STT_CONFIRM_BOX>" and _text(lv.node("GDR_MBIN_STATIC_MESSAGE1")) == "<UIIT_MSG_GUILD_SECESSION_CONFIRM>", "0x14: confirm, SECESSION_CONFIRM")
	dis.free()
	lv.free()

	var ex := GuildMsgBox.expel_question(builder, "Rook")
	_check(ex != null and ex.size == Vector2(280, 144), "the ban question is 0x118 x 0x90")
	var msg := ex.get_node_or_null("Message") as Label if ex != null else null
	_check(msg != null and msg.text == "Will you ban [Rook]from the guild?", "the ban question's text")
	if ex != null:
		ex.free()

	# The HUD's leave line: box 0x14's OK emits guild_leave_requested once.
	var panels_script := load("res://scripts/ui/hud/hud_panels.gd") as GDScript
	var live: Node = panels_script.new()
	live.set("_builder", builder)
	root.add_child(live)
	var leaves := [0]
	live.connect("guild_leave_requested", func() -> void: leaves[0] += 1)
	live.call("open_guild_leave_prompt", "NPC_WC_GUILD")
	var box := (live.get("_guild_boxes") as Dictionary).get(GuildMsgBox.Kind.LEAVE) as GuildMsgBox
	_check(box != null and leaves[0] == 0, "the leave line opens box 0x14, sending nothing")
	if box != null:
		(box.node("GDR_MBIN_BTN_CANCEL") as BaseButton).pressed.emit()
	_check(leaves[0] == 0, "Cancel sends no leave")
	live.call("open_guild_leave_prompt", "NPC_WC_GUILD")
	box = (live.get("_guild_boxes") as Dictionary).get(GuildMsgBox.Kind.LEAVE) as GuildMsgBox
	if box != null:
		(box.node("GDR_MBIN_BTN_OK") as BaseButton).pressed.emit()
	_check(leaves[0] == 1, "OK sends the leave once")
	# The invitation: answer out, close by B0F8.
	var answered: Array = []
	live.connect("guild_invitation_answered", func(a: bool) -> void: answered.append(a))
	var ib: GuildMsgBox = live.call("show_guild_invitation", "Aria", "Verizon")
	_check(ib != null and ib.get_parent() == live, "the invitation box is up, on the HUD")
	(ib.node("GDR_MBIN_BTN_OK") as BaseButton).pressed.emit()
	_check(answered == [true], "yes goes out as guild_invitation_answered(true)")
	ib = live.call("show_guild_invitation", "Aria", "Verizon")
	live.call("close_guild_invitation")
	_check(ib.is_queued_for_deletion() and answered == [true], "close_guild_invitation closes it unanswered")

	_crest_boxes(builder, live)

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
