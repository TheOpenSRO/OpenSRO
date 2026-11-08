extends SceneTree

## Round 865: the academy's windows and boxes against the client's rules
## (docs/protocol/academy.md sections 7, 10 and 11): the academy pane per
## viewer (guardian, member, someone else), the slot order, the row buttons
## and their boxes, the evaluation window, the notice writer's academy mode,
## the talk lines, the Honor Point line, the map marks' rule, the buff icons,
## the character select's delete refusal and the chat gate. It reads the
## player's own Media.pk2 on the render box for the layouts and texts (SKIP
## without it); nothing from the archive is committed. The messages are the
## MEASURED fixtures (test names) fed through NetClient's decode path.
##   godot4 --headless --path client --script res://scripts/ui/hud/academy_window_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const FIX := "res://scripts/net/fixtures/academy/"
## Scripts that name the NetClient autoload are loaded at run time (a
## --script run compiles its own dependencies before the autoloads exist).
var CharacterSelectScript: GDScript
var PanelsScript: GDScript
var FlowScript: GDScript

var _failures := 0
var _builder: UiBuilder
var _me := "Guardian1"

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _fx(name: String) -> PackedByteArray:
	var f := FileAccess.open(FIX + name + ".hex", FileAccess.READ)
	var out := PackedByteArray()
	if f == null:
		_check(false, "fixture %s is readable" % name)
		return out
	for tok in f.get_as_text().split(" ", false):
		if tok.strip_edges() != "":
			out.append(tok.strip_edges().hex_to_int())
	return out

func _initialize() -> void:
	await _run()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

## The world AcademyFlow talks to: its text, its windows and the talk NPC.
class FakeWorld extends Node:
	var table: UiTextTable
	var logged: Array = []
	var banners: Array = []
	var target := 0
	var target_name := ""
	var _last_known_gold := 500000
	func _resolve_any_text(key: String, fallback: String) -> String:
		var t := table.get_text(key, "") if table != null else ""
		return t if t != "" else fallback
	func _log_system(text: String, _type: int = 0) -> void:
		logged.append(text)
	func _show_banner(_kind: String, text: String) -> void:
		banners.append(text)
	func _talk_npc_uid() -> int:
		return 0x2001
	func _academy_selected_target() -> int:
		return target
	func _academy_name_of(_uid: int) -> String:
		return target_name
	func _academy_open_matching() -> void:
		pass

func _text(key: String) -> String:
	var t := _builder.resolve_text(key)
	return t if t != "" else key

func _shown(n: Node) -> String:
	if n == null:
		return "(null)"
	return AcademyWindow.text_of(n as Control)

## A button's or static's text colour as drawn (its override, else the
## label's theme colour).
func _font_color(n: Node) -> Color:
	var l := HudPartyPane._label_of(n as Control)
	if l == null:
		return Color(0, 0, 0, 0)
	return l.get_theme_color("font_color")

## The pane as HudMainPopup builds it: the Create section with the two extra
## sections inside it.
func _pane(st: AcademyState) -> AcademyWindow:
	var pane := Control.new()
	pane.name = "GDR_APPRENTICESHIP"
	pane.size = Vector2(365, 355)
	root.add_child(pane)
	var layout := _builder.load_layout("resinfo\\ifapprenticeship.txt")
	var built := _builder.build_section(layout, "Create")
	pane.add_child(built)
	for extra in ["NotifySubBox", "NotifyContents"]:
		var e := _builder.build_section(layout, extra)
		if e != null:
			built.add_child(e)
	return AcademyWindow.new(_builder, pane, st)

func _state(me: String) -> AcademyState:
	var st := AcademyState.new()
	st.own_name = func() -> String: return me
	return st

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
	root.size = Vector2i(1280, 1024)
	await process_frame
	CharacterSelectScript = load("res://scripts/CharacterSelect.gd")
	PanelsScript = load("res://scripts/ui/hud/hud_panels.gd")
	FlowScript = load("res://scripts/world/academy_flow.gd")
	_builder = UiBuilder.new(pk2, table)
	await _test_window_guardian()
	await _test_window_member()
	_test_window_reset()
	_test_boxes()
	await _test_judge()
	_test_notice_write()
	_test_talk_lines()
	_test_honor_point()
	_test_map_rule()
	_test_buff_board()
	_test_char_select()
	_test_honor_refusal()
	await _test_flow(table)

## Round 865 stage 3: the honor store's refusal (the server's
## session.HonorLackReason on OpShopBuyResult) shows the client's own text,
## as 0x18d4 does in the original's 0xB034 switch (c:0x7b9506).
func _test_honor_refusal() -> void:
	var reasons: Dictionary = (load("res://scripts/World3D.gd") as GDScript).get_script_constant_map().get("GUILD_GOODS_REASONS", {})
	_check(reasons.get("Selected item cannot be purchased due to insufficient amount of honor points.", "") == "UIIT_MSG_TC_LACK_HONOR_POINT",
		"the honor refusal maps to UIIT_MSG_TC_LACK_HONOR_POINT")

# --- 3 / 4: the academy window -------------------------------------------------------

func _test_window_guardian() -> void:
	var st := _state("Guardian1")
	var w := _pane(st)
	st.handle(AcademyNet.OP_OPEN_RESULT, _fx("b470_founded"))
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_05_online"))
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_02_joined"))
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_02_joined_asst"))
	await process_frame
	_check(_shown(w.node("GDR_APPRENTICESHIP_STATIC_NAME")) == "Guardian1", "the guardian's name")
	_check(_shown(w.node("GDR_APPRENTICESHIP_STATIC_LEVEL_DATA")) == "70(70)", "Lv %d(%d): 70(70)")
	_check(_shown(w.node("GDR_APPRENTICESHIP_STATIC_RANK_NAME")) == _text("UIIT_STT_TC_GUARDIAN"), "grade 7: Guardian")
	_check(AcademyWindow.art_of(w.node("GDR_APPRENTICESHIP_LEADER_RANK_MARK")) == "interface\\ifcommon\\com_honor_level_5.ddj",
		"the camp's rank mark com_honor_level_5")
	_check(AcademyNoticeContents.set_subject(w.node("GDR_APPRENTICESHIP_NOTIFY_SUBJECT"), "x", null) != null, "the notice line takes text")
	w.refresh()
	_check(_shown(w.node("GDR_APPRENTICESHIP_NOTIFY_SUBJECT").get_node("Text")) == _text("UIIT_MSG_GUILD_COMMON_NOTEXIST"),
		"no title: You have no notes.")
	for n in ["GDR_APPRENTICESHIP_DISSOLVE_APPRENTICESHIP_BTN", "GDR_APPRENTICESHIP_BTN_INVITE", "GDR_APPRENTICESHIP_NOTIFY_EDIT_BTN"]:
		_check(not (w.node(n) as BaseButton).disabled, "the guardian's %s is enabled" % n)
	_check(_shown(w.node("GDR_APPRENTICESHIP_DISSOLVE_APPRENTICESHIP_BTN")) == _text("UIIT_STT_PARTY_DISSOLVE"), "Dismiss's text")
	# The slots: the assistant in SLOT_0, the apprentice in SLOT_2.
	_check(w.row_member(0) != null and w.row_member(0).name == "Assist40", "an assistant fills SLOT_0")
	_check(w.row_member(1) == null and w.row_member(2) != null and w.row_member(2).name == "Novice001", "an apprentice fills SLOT_2")
	_check(_shown(w.row_node(2, "GDR_APPRENTICESHIPSLOT_STATIC_RANK_NAME")) == _text("UIIT_STT_TC_FIRST_STUDENT"),
		"level 1 apprentice: New apprentice")
	_check(_shown(w.row_node(0, "GDR_APPRENTICESHIPSLOT_STATIC_RANK_NAME")) == _text("UIIT_STT_TC_FIRST_GUARDIAN"),
		"level 40 assistant: Novice guardian")
	_check(_shown(w.row_node(2, "GDR_APPRENTICESHIPSLOT_BTN_EXITFROMAPPRENTICESHIP")) == _text("UIIT_CTL_BAN_PARTY")
		and _shown(w.row_node(0, "GDR_APPRENTICESHIPSLOT_BTN_EXITFROMAPPRENTICESHIP")) == _text("UIIT_CTL_BAN_PARTY"),
		"the guardian sees Banish on both (MEASURED)")
	_check(AcademyWindow.art_of(w.row_node(2, "GDR_APPRENTICESHIP_STATUS")) == AcademyWindow.NO_FACE, "an offline member's face: pt_no_face")
	var acts: Array = []
	w.row_pressed.connect(func(a: String, n: String) -> void: acts.append([a, n]))
	(w.row_node(2, "GDR_APPRENTICESHIPSLOT_BTN_EXITFROMAPPRENTICESHIP") as BaseButton).pressed.emit()
	_check(acts == [[AcademyWindow.ACT_BAN, "Novice001"]], "Banish asks the ban box for the name")
	# Max level 41: the guardian's Graduate (forced).
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([5, 0x02, 0x01, 0, 0, 2, 41]))
	_check(_shown(w.row_node(2, "GDR_APPRENTICESHIPSLOT_BTN_EXITFROMAPPRENTICESHIP")) == _text("UIIT_CTL_TC_GRADUATION"),
		"max level 41: Graduate")
	(w.row_node(2, "GDR_APPRENTICESHIPSLOT_BTN_EXITFROMAPPRENTICESHIP") as BaseButton).pressed.emit()
	_check(acts[-1] == [AcademyWindow.ACT_GRADUATE_MEMBER, "Novice001"], "... the forced graduation box")
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([5, 0x02, 0x01, 0, 0, 2, 40]))
	_check(_shown(w.row_node(2, "GDR_APPRENTICESHIPSLOT_BTN_EXITFROMAPPRENTICESHIP")) == _text("UIIT_CTL_BAN_PARTY"),
		"max level 40 is Banish for the guardian (> 40)")
	# The notice line toggles the contents panel only with a title.
	w.press_notice_line()
	_check(not w.notice_open, "no title: the line does nothing")
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_07_notice"))
	_check(_shown(w.node("GDR_APPRENTICESHIP_NOTIFY_SUBJECT").get_node("Text")) == "Hello Academy", "the title on the line")
	w.press_notice_line()
	_check(w.notice_open and w.node("GDR_APPRENTICESHIP_NOTIFY_CONTENTS").visible
		and AcademyNoticeContents.content_of(w.node("GDR_APPRENTICESHIP_NOTIFY_CONTENTS")) == "Test notice line",
		"a title: the contents panel opens with the content")
	w.press_notice_line()
	_check(not w.notice_open and not w.node("GDR_APPRENTICESHIP_NOTIFY_CONTENTS").visible, "... and closes again")
	var pressed := [0, 0, 0]
	w.dismiss_pressed.connect(func() -> void: pressed[0] += 1)
	w.invite_pressed.connect(func() -> void: pressed[1] += 1)
	w.notice_edit_pressed.connect(func() -> void: pressed[2] += 1)
	w.press_dismiss()
	w.press_invite()
	w.press_notice_edit()
	_check(pressed == [1, 1, 1], "the guardian's three buttons")
	(w._pane as Node).queue_free()

func _test_window_member() -> void:
	var st := _state("Novice001")
	var w := _pane(st)
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_0a_joined"))
	await process_frame
	for n in ["GDR_APPRENTICESHIP_DISSOLVE_APPRENTICESHIP_BTN", "GDR_APPRENTICESHIP_BTN_INVITE", "GDR_APPRENTICESHIP_NOTIFY_EDIT_BTN"]:
		_check((w.node(n) as BaseButton).disabled, "a member's %s is disabled (MEASURED greyed)" % n)
	# Round 865 stage 3: the reset greys Dismiss and the pencil, not Invite
	# (c:0x6e8c70 colours the pencil twice); MEASURED 230,230,230 on Invite.
	_check(_font_color(w.node("GDR_APPRENTICESHIP_DISSOLVE_APPRENTICESHIP_BTN")) == AcademyWindow.COLOR_GREY,
		"a member's Dismiss is drawn 0xff999999")
	_check(_font_color(w.node("GDR_APPRENTICESHIP_BTN_INVITE")) != AcademyWindow.COLOR_GREY,
		"a member's Invite keeps its layout colour (c:0x6e8c30 never colours it)")
	_check(not (w.node("GDR_APPRENTICESHIP_BTN_MATCH") as BaseButton).disabled, "Matching stays enabled")
	_check(_shown(w.row_node(2, "GDR_APPRENTICESHIPSLOT_BTN_EXITFROMAPPRENTICESHIP")) == _text("UIIT_CTL_LEAVE_PARTY"),
		"the member's own row: Leave (MEASURED)")
	var acts: Array = []
	w.row_pressed.connect(func(a: String, n: String) -> void: acts.append([a, n]))
	w.press_row(2)
	_check(acts == [[AcademyWindow.ACT_LEAVE, "Novice001"]], "Leave asks the leave box")
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([5, 0x02, 0x01, 0, 0, 2, 40]))
	_check(_shown(w.row_node(2, "GDR_APPRENTICESHIPSLOT_BTN_EXITFROMAPPRENTICESHIP")) == _text("UIIT_CTL_TC_GRADUATION"),
		"max level 40: the member's Graduate (>= 40)")
	w.press_row(2)
	_check(acts[-1] == [AcademyWindow.ACT_JUDGE, "Novice001"], "an apprentice's Graduate opens the evaluation")
	# Someone else's row has no button on a member's view (c:0x6eaee7:
	# ShowWindow(0); round 865 stage 3, MEASURED hidden).
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_02_joined_asst"))
	var b0 := w.row_node(0, "GDR_APPRENTICESHIPSLOT_BTN_EXITFROMAPPRENTICESHIP") as BaseButton
	_check(b0 != null and b0.disabled and not b0.visible, "another member's button is hidden")
	_check(w.row_node(2, "GDR_APPRENTICESHIPSLOT_BTN_EXITFROMAPPRENTICESHIP").visible, "... the member's own is shown")
	var n := acts.size()
	w.press_row(0)
	_check(acts.size() == n, "... and does nothing")
	# The assistant's own Graduate at 60.
	var sa := _state("Assist40")
	var wa := _pane(sa)
	sa.handle(AcademyNet.OP_PUSH, _fx("3c80_0a_joined_asst"))
	_check(_shown(wa.row_node(0, "GDR_APPRENTICESHIPSLOT_BTN_EXITFROMAPPRENTICESHIP")) == _text("UIIT_CTL_LEAVE_PARTY"), "an assistant at 40: Leave")
	sa.handle(AcademyNet.OP_PUSH, PackedByteArray([5, 0x03, 0x01, 0, 0, 2, 60]))
	var a2: Array = []
	wa.row_pressed.connect(func(a: String, nn: String) -> void: a2.append(a))
	wa.press_row(0)
	_check(a2 == [AcademyWindow.ACT_GRADUATE_ASSISTANT], "an assistant at 60: Graduate from Academy?")
	# A pane built after the join (the popup first opened in an academy) still
	# starts from the reset: the member's Dismiss is grey (round 865 stage 3).
	var sl := _state("Novice001")
	sl.handle(AcademyNet.OP_PUSH, _fx("3c80_0a_joined"))
	var wl := _pane(sl)
	_check(_font_color(wl.node("GDR_APPRENTICESHIP_DISSOLVE_APPRENTICESHIP_BTN")) == AcademyWindow.COLOR_GREY
		and (wl.node("GDR_APPRENTICESHIP_DISSOLVE_APPRENTICESHIP_BTN") as BaseButton).disabled,
		"a pane built inside an academy: the member's Dismiss disabled and grey")
	(wl._pane as Node).queue_free()
	(w._pane as Node).queue_free()
	(wa._pane as Node).queue_free()

func _test_window_reset() -> void:
	var st := _state("Guardian1")
	var w := _pane(st)
	_check((w.node("GDR_APPRENTICESHIP_BTN_INVITE") as BaseButton).disabled
		and (w.node("GDR_APPRENTICESHIP_DISSOLVE_APPRENTICESHIP_BTN") as BaseButton).disabled
		and not (w.node("GDR_APPRENTICESHIP_BTN_MATCH") as BaseButton).disabled, "no academy: Invite, Dismiss off; Matching on")
	_check(not w.node("GDR_APPRENTICESHIP_STATIC_NAME").visible and not w.node("GDR_APPRENTICESHIP_STATIC_LEVEL").visible,
		"no academy: the guardian's line hidden")
	st.handle(AcademyNet.OP_OPEN_RESULT, _fx("b470_founded"))
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([1]))
	_check(not w.node("GDR_APPRENTICESHIP_STATIC_NAME").visible and w.row_member(0) == null, "disbanded: reset")
	(w._pane as Node).queue_free()

# --- 4 / 6: the boxes ------------------------------------------------------------------------

func _test_boxes() -> void:
	var box := AcademyMsgBox.new()
	root.add_child(box)
	_check(box.build_academy(_builder, "short", "UIIT_STT_CONFIRM_BOX", "t"), "a box builds")
	_check(box.size == Vector2(360, 151), "a short line: the 360 x 151 floor (0x6413a0)")
	var yes := [0]
	var no := [0]
	box.yes.connect(func() -> void: yes[0] += 1)
	box.no.connect(func() -> void: no[0] += 1)
	_check(box.yes_button().position.x < box.no_button().position.x, "Yes left of No")
	_check(box.yes_button().position.x == 180 - 0x51 and box.no_button().position.x == 180 + 5, "at the centre - 0x51 and + 5")
	box.press(false)
	_check(no[0] == 1 and yes[0] == 0, "No answers no")
	var two := AcademyMsgBox.new()
	root.add_child(two)
	two.build_academy(_builder, _text("UIIT_STT_TC_DISSOLUTION"), "UIIT_STT_CONFIRM_BOX", "disband")
	_check(two.size.y == 151 + 23 - 6 and two.size.x > 360, "two lines: 168 high (MEASURED), wider than 360 (got %s)" % two.size)
	_check(two.yes_button().position.x == two.size.x / 2.0 - 0x51 and two.yes_button().position.y > box.yes_button().position.y,
		"the buttons follow the size")
	var y2 := [0]
	two.yes.connect(func() -> void: y2[0] += 1)
	two.yes_button().pressed.emit()
	_check(y2[0] == 1, "Yes answers yes")
	box.queue_free()

# --- 5: the evaluation window -----------------------------------------------------------------

func _test_judge() -> void:
	var w := HudWindow.new()
	root.add_child(w)
	var built := w.build(_builder, AcademyJudgeWindow.LAYOUT, "Guardian Evaluation", PackedStringArray(), PackedStringArray(), false,
		{"name": AcademyJudgeWindow.REGISTRY})
	_check(built, "ifapprenticeshipjudge builds in its registry frame")
	_check(w.size == Vector2(420, 174), "420 x 174 (ginterface GDR_APPRENTICESHIP_JUDGE)")
	var j := AcademyJudgeWindow.compose(w, _builder)
	await process_frame
	_check(j.index == 1 and j.evaluation == 3, "Satisfied is chosen at open: 3")
	var got: Array = []
	j.evaluated.connect(func(v: int) -> void: got.append(v))
	var labels: Array = []
	for i in 5:
		labels.append((w.node(AcademyJudgeWindow.RADIO).get_node("Label%d" % i) as Label).text)
	_check(labels == [_text("UIIT_STT_TC_APPRAISAL_VERY_SATISFACTION"), _text("UIIT_STT_TC_APPRAISAL_SATISFACTION"),
		_text("UIIT_STT_TC_APPRAISAL_NORMAL"), _text("UIIT_STT_TC_APPRAISAL_DESPAIR"), _text("UIIT_STT_TC_APPRAISAL_VERY_DESPAIR")],
		"the five items in a row")
	_check((w.node(AcademyJudgeWindow.RADIO).get_node("Item1") as Control).position == Vector2(70, 0), "pitch 0x46")
	j.choose(0)
	(w.node(AcademyJudgeWindow.BTN_CONFIRM) as BaseButton).pressed.emit()
	_check(got == [4] and not w.visible, "Very satisfied: 0x7475 {4}, the window closes")
	j.reset()
	j.choose(4)
	j.press_evaluate()
	_check(got == [4, 0], "Very disappointed: 0")
	w.queue_free()

# --- 7: the notice writer ------------------------------------------------------------------------

func _test_notice_write() -> void:
	var nw := GuildNoticeWrite.new()
	root.add_child(nw)
	_check(nw.build_write(_builder), "ifguildnotifywrite builds")
	nw.set_mode(GuildNoticeWrite.MODE_ACADEMY)
	var title := nw.node(GuildNoticeWrite.TITLE_STATIC)
	_check(_shown(title) == _text("UIIT_CTL_TC_COMMON"), "academy mode titles it Notice (c:0x70b720)")
	var refused: Array = []
	var got: Array = []
	nw.refused.connect(func(c: int) -> void: refused.append(c))
	nw.submitted.connect(func(t: String, b: String) -> void: got.append([t, b]))
	nw.set_texts("Hello Academy", "")
	nw.press_ok()
	_check(refused == [0x6817] and got.is_empty(), "an empty body: 0x6817 in category 0x1d, nothing sent")
	nw.set_texts("", "Body")
	nw.press_ok()
	_check(refused == [0x6817, 0x6817], "an empty title: the same")
	nw.set_texts("Hello Academy", "Test notice line")
	nw.press_ok()
	_check(got == [["Hello Academy", "Test notice line"]], "both: 0x7477 {title, content}")
	_check(AcademyNet.encode_notice(got[0][0], got[0][1]) == _fx("7477_notice"), "... the MEASURED bytes")

# --- 8: the talk lines ------------------------------------------------------------------------------

func _keys(list: Array) -> Array:
	var out: Array = []
	for s in list:
		out.append((s as NpcServiceReader.Service).key)
	return out

func _test_talk_lines() -> void:
	var out := NpcServiceReader.services_from_ids(PackedByteArray([3]), [], -1, false, 0, 60, true, false)
	_check(_keys(out) == ["storage", "academy_open", "honor_rank"], "level 60, no academy: Academy Establishment and Honor Rank")
	out = NpcServiceReader.services_from_ids(PackedByteArray([3]), [], -1, false, 0, 60, true, true)
	_check(_keys(out) == ["storage", "honor_rank"], "in an academy: no establishment line (+0x20)")
	out = NpcServiceReader.services_from_ids(PackedByteArray([3]), [], -1, false, 0, 59, true, false)
	_check(_keys(out) == ["storage", "honor_rank"], "level 59: none")

# --- 12, 13, 14, 15 ------------------------------------------------------------------------------------

func _test_honor_point() -> void:
	var st := _state("Guardian1")
	_check(PanelsScript.academy_honor_text(st, "N/A") == "N/A", "no academy: N/A")
	st.handle(AcademyNet.OP_OPEN_RESULT, _fx("b470_founded"))
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([5, 0x01, 0x01, 0, 0, 3, 0x12, 0, 0, 0]))
	_check(PanelsScript.academy_honor_text(st, "N/A") == "18", "the own record's honor (+0x5c)")

func _test_map_rule() -> void:
	var st := _state("Guardian1")
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_0a_joined"))
	var g := st.member(0x101)
	var n := st.member(0x102)
	_check(not PartyMapMarks.academy_draws(g, "Guardian1", 0x10001), "never the player")
	_check(not PartyMapMarks.academy_draws(n, "Guardian1", 0x10001), "an offline member (+0x74 == 1) is not drawn")
	n.play_state = AcademyNet.ONLINE
	_check(PartyMapMarks.academy_draws(n, "Guardian1", 0x10001), "online, the same world: drawn")
	_check(not PartyMapMarks.academy_draws(n, "Guardian1", 0x20001), "another world: not drawn")
	_check(PartyMapMarks.ACADEMY_ARROW_SIZE == Vector2(32, 32), "the arrow's corners +-16 (0xda0ef8 / 0xe1b8e0)")

func _test_buff_board() -> void:
	var b := HudBuffBoard.new(_builder)
	root.add_child(b)
	var e := b.add_academy_buff(HudBuffBoard.KIND_ACADEMY_SAVE, 77, 1440 * 60000, 120 * 60000 + 1, "Cumulated")
	_check(String(e.info["icon"]) == "icon\\skill\\etc\\tc_reserve_buff.ddj", "kind 7 draws tc_reserve_buff (c:0x7ff364)")
	var f := b.add_academy_buff(HudBuffBoard.KIND_ACADEMY_RESERVE, 78, -1, 30 * 60000 + 1, "Accumulated")
	_check(String(f.info["icon"]) == "icon\\skill\\etc\\tc_amends_buff.ddj", "kind 8 draws tc_amends_buff (c:0x7ff376)")
	var clicks: Array = []
	b.academy_buff_clicked.connect(func(t: int, ms: int) -> void: clicks.append([t, ms]))
	b.on_slot_left_click(77)
	b.on_slot_left_click(78)
	_check(clicks.size() == 1 and int(clicks[0][0]) == 77 and int(clicks[0][1]) >= 3600000, "a click on kind 7 only, with its time")
	_check(b.right_click_action(77) == HudBuffBoard.ACTION_NONE, "no cancel on a right-click")
	b.remove_academy_buff(78)
	_check(b.academy_buff_tokens() == [77], "kind 8 removed")
	b.queue_free()

func _test_char_select() -> void:
	_check(CharacterSelectScript.delete_refusal(0, 2)[0] == "UIO_MSG_CHAR_DEL_WANNING_CONFIRM_GUARDIAN", "academy byte 2: the guardian's refusal")
	_check(CharacterSelectScript.delete_refusal(0, 1)[0] == "UIO_MSG_CHAR_DEL_WANNING_CONFIRM_STUDENT", "academy byte 1: a member's")
	_check(CharacterSelectScript.delete_refusal(0, 0).is_empty(), "0: the delete box")
	_check(CharacterSelectScript.delete_refusal(1, 2)[0] == "UIO_MSG_CHAR_DEL_WANNING_CONFIRM_MEMBER", "the guild's refusal first")

# --- 6, 10, 11: through NetClient and AcademyFlow ----------------------------------------------------

func _test_flow(table: UiTextTable) -> void:
	var net := root.get_node_or_null("NetClient")
	_check(net != null, "the NetClient autoload is there")
	if net == null:
		return
	net.set("current_character_name", "Novice001")
	var world := FakeWorld.new()
	world.table = table
	root.add_child(world)
	var hud = PanelsScript.new(_builder)
	root.add_child(hud)
	var flow = FlowScript.new(world, hud)
	var st: AcademyState = net.get("academy")
	st.reset_connection()
	# 11: the chat gate.
	_check(not FlowScript.chat_allowed(st), "no academy: '&' lines are refused by the client (choice 3)")
	# 6: the invitation box and its answer.
	net.qa_receive(AcademyNet.OP_REQUEST, _fx("3080_invite"))
	var box: AcademyMsgBox = flow.invitation_box()
	_check(box != null and box.caption.text == _text("UIIT_PAG_PARTYMATCH_JOINREQUEST"), "0x3080 kind 9: Join request sent")
	_check(box != null and box.sml.markup.contains("Guardian1"), "... naming the inviter")
	(net.get("academy_sent") as Array).clear()
	if box != null:
		box.yes_button().pressed.emit()
	var sent: Array = net.get("academy_sent")
	_check(sent.size() == 1 and int(sent[0][0]) == 0x3080 and sent[0][1] == _fx("3080_yes"), "Yes: 3080 01 01")
	world.banners.clear()
	net.qa_receive(AcademyNet.OP_PUSH, _fx("3c80_0a_joined"))
	_check(st.in_academy() and world.banners == [_text("UIIT_STT_TC_JOIN_ANNOUNCE")], "0a 01: Joined Academy. on the banner")
	_check(FlowScript.chat_allowed(st), "in an academy: '&' lines go")
	# 10: the lines and the refusals' texts.
	world.logged.clear()
	net.qa_receive(AcademyNet.OP_PUSH, _fx("3c80_05_online"))
	_check(world.logged == [_text("UIIT_MSG_TC_CONNECT2") % [_text("UIIT_STT_TC_GUARDIAN"), "Guardian1"]],
		"the guardian's log-on line (got %s)" % [world.logged])
	world.logged.clear()
	net.qa_receive(AcademyNet.OP_BAN_RESULT, _fx("b473_leave_24h"))
	_check(world.logged == [_text("UIIT_MSG_TC_ERROR_NOT_OUT_24T")], "B473 0x6821: Leaving the Academy is not allowed ...")
	world.logged.clear()
	net.qa_receive(AcademyNet.OP_INVITE_RESULT, _fx("b472_timeout"))
	_check(world.logged.is_empty(), "0x000E: nothing printed")
	net.qa_receive(AcademyNet.OP_INVITE_RESULT, _fx("b472_invalid"))
	_check(world.logged == [_text("UIIT_STT_ERR_COMMON_INVALID_TARGET")], "3: Invalid object (MEASURED)")
	# 4: the boxes' sends.
	(net.get("academy_sent") as Array).clear()
	var leave: AcademyMsgBox = flow.on_row(AcademyWindow.ACT_LEAVE, "Novice001")
	_check(leave != null and leave.sml.markup == _text("UIIT_STT_TC_OUT_TRAININGCAMP"), "the leave box's text")
	leave.yes_button().pressed.emit()
	_check(int((net.get("academy_sent") as Array)[-1][0]) == 0x7474, "Yes: 0x7474")
	net.set("current_character_name", "Guardian1")
	var ban: AcademyMsgBox = flow.on_row(AcademyWindow.ACT_BAN, "Novice001")
	_check(ban != null and ban.sml.markup.contains("Novice001"), "the ban box names the member")
	ban.yes_button().pressed.emit()
	_check((net.get("academy_sent") as Array)[-1] == [0x7473, _fx("7473_ban")], "Yes: 0x7473 {name}")
	var fg: AcademyMsgBox = flow.on_row(AcademyWindow.ACT_GRADUATE_MEMBER, "Novice001")
	fg.no_button().pressed.emit()
	_check(int((net.get("academy_sent") as Array)[-1][0]) == 0x7473, "No sends nothing")
	# 8: the fee box's gold check.
	world._last_known_gold = 99999
	var fee: AcademyMsgBox = flow.ask_found(0x2001)
	fee.yes_button().pressed.emit()
	_check(int((net.get("academy_sent") as Array)[-1][0]) == 0x7473 and world.logged[-1] == _text("UIIT_MSG_TC_ERROR_OPEN_GOLD"),
		"below 100,000 gold: OPEN_GOLD, nothing sent (MEASURED)")
	world._last_known_gold = 100000
	fee = flow.ask_found(0x2001)
	fee.yes_button().pressed.emit()
	_check((net.get("academy_sent") as Array)[-1] == [0x7470, _fx("7470_open")], "100,000: 0x7470 {npc}")
	# Invite: the selection and the pending line.
	world.target = 0x1002
	world.target_name = "Novice001"
	world.logged.clear()
	flow.invite_selected()
	_check((net.get("academy_sent") as Array)[-1] == [0x7472, _fx("7472_invite")]
		and world.logged == [_text("UIIT_STT_TC_PROPOSAL_PENDING") % "Novice001"], "Invite: the pending line, then 0x7472")
	# 14: the buffs through the flow.
	var board := HudBuffBoard.new(_builder)
	root.add_child(board)
	flow.attach_board(board)
	net.qa_receive(AcademyNet.OP_OWN_BUFF, PackedByteArray([0, 120, 0, 0, 0, 9, 0, 0, 0]))
	_check(board.academy_buff_tokens() == [FlowScript.BUFF_TOKEN_SAVE], "3C82 0: the own cumulated icon")
	net.qa_receive(AcademyNet.OP_BUFF_LIST, PackedByteArray([2]))
	_check(world.logged[-1] == _text("UIIT_MSG_TC_PASS_ERROR"), "B483 2: the guardian is offline")
	st.reset_connection()
	net.set("current_character_name", "")
	hud.queue_free()
	world.queue_free()
	board.queue_free()
