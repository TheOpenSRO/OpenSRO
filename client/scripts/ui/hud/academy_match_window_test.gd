extends SceneTree

## Round 865: the academy's matching board ("Guardian Matching", AcademyMatchWindow)
## and its register box against what the client does (docs/protocol/academy.md
## 7.10 / 10.5; the window's header has the addresses). The layouts are
## synthetic but carry the authored names, types, IDs and rects of resinfo\
## ifmentormatch.txt, ifmentormatchslot.txt and ifmessagebox.txt's
## MentorMatchRegister (MEASURED from the archive; no textures, no archive
## text: never real game data). The replies run on the golden fixtures in
## scripts/net/fixtures/academy/ and on pages built to AcademyNet's layout.
##
##   godot4 --headless --path client --script res://scripts/ui/hud/academy_match_window_test.gd

const FIX := "res://scripts/net/fixtures/academy/"

var _failures := 0

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

func _c(control_name: String, type: String, rect: String, id: int, text: String = "", ddj: String = "", halign: int = 0) -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tHAlign=INTEGER,\"%d\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tStyle=INTEGER,\"0\"\n\t\tText=STRING,\"%s\"\n\t}\n" % [
		control_name, type, ddj, halign, id, rect, text]

func _sec(section: String, body: String) -> String:
	return "Section = %s,\"0,0,0,0\",\"0\"\n{\n%s}\n" % [section, body]

func _ifmentormatch() -> String:
	var create := ""
	create += _c("GDR_MENTORMATCH_SCROLL", "CIFVerticalScroll", "743,159,15,232", 26)
	create += _c("GDR_MENTORMATCH_SPIN_PAGE", "CIFSpinButtonCtrl", "360,437,50,16", 25)
	for spec in [["GDR_MENTORMATCH_DELETE_BTN", "654,434,0,0", 20], ["GDR_MENTORMATCH_MODIFY_BTN", "553,434,0,0", 19],
			["GDR_MENTORMATCH_REGISTER_BTN", "452,434,0,0", 18], ["GDR_MENTORMATCH_WHISPER_BTN", "130,434,0,0", 16],
			["GDR_MENTORMATCH_JOIN_BTN", "29,434,0,0", 15]]:
		create += _c(spec[0], "CIFButton", spec[1], spec[2])
	create += _c("GDR_MENTORMATCH_SLOTLIST_BLACKSQUARE", "CIFStretchWnd", "25,119,735,305", 6)
	var search := ""
	search += _c("GDR_MENTORMATCH_UPDATE_BTN", "CIFButton", "635,73,0,0", 56)
	search += _c("GDR_MENTORMATCH_SEARCH_BTN", "CIFButton", "525,73,0,0", 55)
	search += _c("GDR_MENTORMATCH_SEARCH_NAME_EDIT", "CIFEdit", "103,79,81,11", 47, "", "", 2)
	search += _c("GDR_MENTORMATCH_SEARCH_COMBOBOX2", "CIFComboBox", "400,75,106,20", 46)
	search += _c("GDR_MENTORMATCH_SEARCH_COMBOBOX1", "CIFComboBox", "253,75,74,20", 45)
	var buttons := ""
	buttons += _c("GDR_MENTORMATCH_SLOTLIST_SUBJECT", "CIFBarWnd", "261,122,326,24", 64, "UIIT_STT_LETTER_TITLE")
	buttons += _c("GDR_MENTORMATCH_SLOTLIST_DUMY", "CIFStatic", "744,122,15,24", 68, "L")
	var slots := ""
	for i in range(11, -1, -1):
		slots += _c("GDR_MENTORMATCH_SLOTLIST_SLOT_%02d" % i, "CIFMentorMatchSlot", "28,%d,715,24" % (144 + 23 * i), 70 + i)
	return "Interface Text\n\n" + _sec("Create", create) + _sec("SearchInfo", search) \
		+ _sec("SlotListButton", buttons) + _sec("SlotList", slots)

func _ifmentormatchslot() -> String:
	var b := ""
	for spec in [["GDR_MENTORMATCH_SLOT_GRADE_NUM", "690,7,20,11", 18], ["GDR_MENTORMATCH_SLOT_GRADE", "674,5,16,16", 17],
			["GDR_MENTORMATCH_SLOT_NUMBER", "619,7,24,11", 16], ["GDR_MENTORMATCH_SLOT_STUDENT", "566,7,37,11", 15],
			["GDR_MENTORMATCH_SLOT_SUBJECT", "248,7,306,11", 14], ["GDR_MENTORMATCH_SLOT_NAME", "150,7,78,11", 13],
			["GDR_MENTORMATCH_SLOT_RACE", "101,7,31,11", 12], ["GDR_MENTORMATCH_SLOT_LEVEL", "50,7,32,11", 11],
			["GDR_MENTORMATCH_SLOT_ID", "10,7,36,11", 10]]:
		b += _c(spec[0], "CIFStatic", spec[1], spec[2])
	b += _c("GDR_MENTORMATCH_SLOT_SELECT", "CIFBarWnd", "0,0,715,24", 5)
	return "Interface Text\n\n" + _sec("Create", b)

func _ifmessagebox() -> String:
	var create := _c("GDR_MSGBOX_BG", "CIFNormalTile", "16,40,284,122", 0)
	var reg := ""
	reg += _c("GDR_MB_MENTOR_MATCH_STA_2", "CIFStatic", "9,151,41,16", 512, "UIIT_STT_LETTER_TITLE", "", 2)
	reg += _c("GDR_MB_MENTOR_MATCH_STA_1", "CIFStatic", "8,85,41,16", 511, "UIIT_STT_TC_INVITATION", "", 2)
	reg += _c("GDR_MB_MENTOR_MATCH_CHK_STA_2", "CIFStatic", "217,84,108,16", 510, "UIIT_STT_TC_SECOND_GUARDIAN_INVITATION", "", 1)
	reg += _c("GDR_MB_MENTOR_MATCH_CHK_STA_1", "CIFStatic", "96,84,94,16", 509, "UIIT_STT_TC_STUDENT_INVITATION", "", 1)
	reg += _c("GDR_MB_MENTOR_MATCH_CHBTN2", "CIFCheckBox", "197,81,16,16", 508)
	reg += _c("GDR_MB_MENTOR_MATCH_CHBTN1", "CIFCheckBox", "74,81,16,16", 507)
	reg += _c("GDR_MB_MENTOR_MATCH_EDIT", "CIFEdit", "61,149,265,17", 513)
	reg += _c("GDR_MB_MENTOR_MATCH_BTN_CONFIRM", "CIFButton", "100,174,0,0", 502, "UIIS_CTL_CONFIRM", "", 1)
	reg += _c("GDR_MB_MENTOR_MATCH_BTN_CANCLE", "CIFButton", "188,174,0,0", 501, "UIIS_CTL_CANCEL", "", 1)
	return "Interface Text\n\n" + _sec("Create", create) + _sec("MentorMatchRegister", reg)

func _ifpartyjoinprogress() -> String:
	var b := _c("GDR_PARTY_JOIN_PROGRESS_BAR", "CIFGauge", "35,104,296,12", 11)
	b += _c("GDR_PARTY_JOIN_PROGRESS_DESC_PML", "CIFPML", "16,50,335,29", 5, "", "", 1)
	return "Interface Text\n\n" + _sec("Create", b)

func _builder() -> UiBuilder:
	var rows := PackedStringArray()
	for k in ["UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_CH", "UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_EU",
			"UIIT_CTL_PARTYMATCH_PSEARCH_OBJECTALL", "UIIT_STT_TC_STUDENT", "UIIT_STT_TC_ASSISTANT_GUARDIAN",
			"UIIT_CTL_TC_MACHING_ENTER", "UIIT_STT_LETTER_TITLE", "UIIT_PAG_PARTYMATCH_JOINPROGRESS"]:
		rows.append("1\t%s\t\t\t\t\t\t\t<%s>" % [k, k])
	var builder := UiBuilder.new(null, UiTextTable.parse(("\n".join(rows)).to_utf16_buffer()))
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\ifmentormatch.txt"] = UiLayoutParser.parse(_ifmentormatch())
	cache["resinfo\\ifmentormatchslot.txt"] = UiLayoutParser.parse(_ifmentormatchslot())
	cache["resinfo\\ifmessagebox.txt"] = UiLayoutParser.parse(_ifmessagebox())
	cache["resinfo\\ifpartyjoinprogress.txt"] = UiLayoutParser.parse(_ifpartyjoinprogress())
	return builder

func _label_color(n: Node) -> Color:
	var l: Label = n as Label if n is Label else (n.get_node_or_null("Text") as Label if n != null else null)
	return l.get_theme_color("font_color") if l != null else Color.TRANSPARENT

## The window as HudPanels builds it (its four sections into one Control),
## the state and the controller.
func _make(builder: UiBuilder, me: String, level: int) -> Dictionary:
	var host := Control.new()
	host.name = "Host"
	host.size = Vector2(1280, 1024)
	root.add_child(host)
	var win := Control.new()
	win.name = "Window_academy_match"
	win.size = Vector2(785, 480)
	host.add_child(win)
	var layout := builder.load_layout("resinfo\\ifmentormatch.txt")
	for s in ["Create", "SearchInfo", "SlotListButton", "SlotList"]:
		var built := builder.build_section(layout, s)
		win.add_child(built)
		UiBuilder.apply_authored_rects(built)
	var st := AcademyState.new()
	st.own_name = func() -> String: return me
	var w := AcademyMatchWindow.new(builder, st, host)
	var out := {"w": w, "st": st, "sent": [], "banners": [], "notices": [], "whispers": [], "host": host}
	w.send.connect(func(op: int, p: PackedByteArray) -> void: (out["sent"] as Array).append([op, p]))
	w.banner.connect(func(k: String) -> void: (out["banners"] as Array).append(k))
	w.notice.connect(func(k: String, t: int) -> void: (out["notices"] as Array).append([k, t]))
	w.whisper_requested.connect(func(n: String) -> void: (out["whispers"] as Array).append(n))
	w.own_name = func() -> String: return me
	w.own_level = func() -> int: return level
	w.own_race = func() -> int: return 0
	w.race_of_model = func(ref: int) -> int: return 1 if ref == 2000 else (0 if ref == 1907 else -1)
	w.view_size = func() -> Vector2: return Vector2(1280, 1024)
	w.attach(win)
	return out

## A member record for a synthetic camp.
func _member(id: int, name: String, cls: int, level: int) -> AcademyNet.Member:
	var m := AcademyNet.Member.new()
	m.camp_id = 0x65
	m.char_id = id
	m.ref_obj_id = 1907
	m.name = name
	m.member_class = cls
	m.joined_level = level
	m.join_date = [2026, 1, 1, 0, 0, 0, 0]
	m.cur_level = level
	m.max_level = level
	m.play_state = 0
	m.display_name = name
	return m

## A whole camp (0x3C81) with the guardian and `assistants` / `apprentices`.
func _camp_msg(assistants: int, apprentices: int) -> PackedByteArray:
	var c := AcademyNet.Camp.new()
	c.camp_id = 0x65
	c.creation_date = [2026, 1, 1, 0, 0, 0, 0]
	c.rank = 5
	c.members.append(_member(100, "Guardian1", AcademyNet.CLASS_GUARDIAN, 70))
	for i in assistants:
		c.members.append(_member(200 + i, "Assist%d" % i, AcademyNet.CLASS_ASSISTANT, 45))
	for i in apprentices:
		c.members.append(_member(300 + i, "Novice%d" % i, AcademyNet.CLASS_APPRENTICE, 5))
	return AcademyNet.encode_camp(c)

func _str(s: String) -> PackedByteArray:
	var raw := s.to_utf8_buffer()
	var b := PackedByteArray([raw.size() & 0xff, raw.size() >> 8])
	b.append_array(raw)
	return b

func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

## One MatchRow to AcademyNet.decode_match_page's layout.
func _row(id: int, flags: int, title: String, level: int, max_level: int, ref: int, name: String,
		graduates: int, rank: int, assistants: int, apprentices: int) -> PackedByteArray:
	var b := _u32(id)
	b.append_array(_u32(0))
	b.append(flags)
	b.append_array(_str(title))
	b.append_array(_u32(0))
	b.append(level)
	b.append(max_level)
	b.append_array(_u32(ref))
	b.append_array(_str(name))
	b.append_array(_u32(graduates))
	b.append(rank)
	b.append_array(_u32(assistants))
	b.append_array(_u32(apprentices))
	return b

## 0xB47D {1, page count, page, n, rows}.
func _page(count: int, pg: int, rows: Array) -> PackedByteArray:
	var b := PackedByteArray([1, count, pg, rows.size()])
	for r in rows:
		b.append_array(r)
	return b

func _init() -> void:
	var builder := _builder()
	_test_owner(builder)
	_test_board(builder)
	_test_full_roles(builder)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## The guardian: open, register (the box's checks), the own row, delete.
func _test_owner(builder: UiBuilder) -> void:
	var m := _make(builder, "Guardian1", 70)
	var w: AcademyMatchWindow = m["w"]
	var st: AcademyState = m["st"]
	var sent: Array = m["sent"]
	st.handle(AcademyNet.OP_CAMP, _camp_msg(1, 1))
	_check(st.in_academy() and st.am_guardian(), "the camp is held, the player its guardian")
	w.on_shown()
	_check(sent.size() == 1 and sent[0][0] == AcademyNet.OP_MATCH_PAGE and sent[0][1] == _fx("747d_page"),
		"opening asks for page 0: 747D 00 (MEASURED)")
	st.handle(AcademyNet.OP_MATCH_PAGE_RESULT, _fx("b47d_empty"))
	_check(w.shown.is_empty() and w.page == 0 and w.page_count == 0 and w.slot_text(0, "GDR_MENTORMATCH_SLOT_ID") == "",
		"B47D 01 00 00 00: an empty page, every row blank")
	_check(w.enabled(AcademyMatchWindow.BTN_REGISTER), "Registration: the guardian, level 70, no own entry")
	_check(not w.enabled(AcademyMatchWindow.BTN_JOIN) and not w.enabled(AcademyMatchWindow.BTN_WHISPER),
		"Join and Whisper off with nothing shown")
	_check(not w.enabled(AcademyMatchWindow.BTN_MODIFY) and not w.enabled(AcademyMatchWindow.BTN_DELETE),
		"Change / Delete entry off without an own entry")
	var reg_btn := w.node(AcademyMatchWindow.BTN_REGISTER) as BaseButton
	_check(reg_btn != null and not reg_btn.disabled, "the Registration button is drawn enabled")
	# The register box.
	w.press_register()
	var box := w.register_box
	_check(box != null and box.size == Vector2(360, 215), "Registration opens the 360 x 215 box (0x168 x 0xd7)")
	_check(box != null and box.caption.text == "<UIIT_CTL_TC_MACHING_ENTER>", "its caption is UIIT_CTL_TC_MACHING_ENTER")
	_check(box != null and box.kind() == 1, "Apprentice Recruitment is checked at open (507 on, 508 off)")
	box.choose_kind(2)
	_check(box.kind() == 2 and not box.check_apprentice.button_pressed, "checking Asst. Guardian Recruitment unchecks the other")
	box.choose_kind(1)
	var n := sent.size()
	box.press_ok()
	_check(sent.size() == n and (m["notices"] as Array)[-1] == ["UIIT_STT_TC_MACHING_TITLE_ERROR", 0],
		"an empty title: UIIT_STT_TC_MACHING_TITLE_ERROR (type 0), nothing sent")
	_check(w.register_box != null and is_instance_valid(w.register_box) and not w.register_box.is_queued_for_deletion(),
		"the box stays open after the empty title")
	(box.node(AcademyMatchWindow.AcademyMatchRegister.EDIT) as LineEdit).text = "Join us"
	box.press_ok()
	_check(sent[-1][0] == AcademyNet.OP_MATCH_REGISTER and sent[-1][1] == _fx("747a_register"),
		"OK sends 747A {0, camp, 01, \"Join us\"} (MEASURED bytes)")
	# B47A: the own entry, pinned in row 0, every column in (135, 233, 255).
	st.handle(AcademyNet.OP_MATCH_REGISTER_RESULT, _fx("b47a_ok"))
	_check((m["banners"] as Array)[-1] == "UIIT_STT_TC_MACHING_ENTRY", "B47A 01: banner UIIT_STT_TC_MACHING_ENTRY")
	_check(w.has_own() and w.own.entry_id == 1, "the own entry is entry 1")
	_check(w.slot_text(0, "GDR_MENTORMATCH_SLOT_ID") == "1" and w.slot_text(0, "GDR_MENTORMATCH_SLOT_LEVEL") == "70"
		and w.slot_text(0, "GDR_MENTORMATCH_SLOT_RACE") == "<UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_CH>"
		and w.slot_text(0, "GDR_MENTORMATCH_SLOT_NAME") == "Guardian1" and w.slot_text(0, "GDR_MENTORMATCH_SLOT_SUBJECT") == "Join us"
		and w.slot_text(0, "GDR_MENTORMATCH_SLOT_STUDENT") == "0" and w.slot_text(0, "GDR_MENTORMATCH_SLOT_NUMBER") == "3/8"
		and w.slot_text(0, "GDR_MENTORMATCH_SLOT_GRADE_NUM") == "(5)",
		"row 0: 1, 70, CHN, Guardian1, Join us, 0, 3/8, (5) (as MEASURED)")
	var col := _label_color(w._slots[0].get_node_or_null("MatchSlot/GDR_MENTORMATCH_SLOT_NAME"))
	_check(col.is_equal_approx(AcademyMatchWindow.OWN_ROW_COLOR), "the own row is drawn (135, 233, 255) (got %s)" % col)
	var icon := w._slots[0].get_node_or_null("MatchSlot/GDR_MENTORMATCH_SLOT_GRADE/GradeIcon")
	_check(icon != null and String(icon.get_meta("ddj", "")) == "interface\\ifcommon\\com_honor_level_5.ddj",
		"the grade icon is com_honor_level_5.ddj")
	_check(not w.enabled(AcademyMatchWindow.BTN_REGISTER) and not w.enabled(AcademyMatchWindow.BTN_JOIN)
		and not w.enabled(AcademyMatchWindow.BTN_WHISPER), "with an own entry: Registration, Join, Whisper off (MEASURED greyed)")
	_check(w.enabled(AcademyMatchWindow.BTN_MODIFY) and w.enabled(AcademyMatchWindow.BTN_DELETE), "Change / Delete entry on")
	# Change entry: 747B with the own id.
	w.press_modify()
	(w.register_box.node(AcademyMatchWindow.AcademyMatchRegister.EDIT) as LineEdit).text = "New"
	w.register_box.choose_kind(2)
	w.register_box.press_ok()
	_check(sent[-1][0] == AcademyNet.OP_MATCH_MODIFY and sent[-1][1] == AcademyNet.encode_match(1, 0x65, 2, "New"),
		"Change entry sends 747B {own id 1, camp, 02, title}")
	var modified := PackedByteArray([1])
	modified.append_array(_u32(1))
	modified.append_array(_u32(0x65))
	modified.append(2)
	modified.append_array(_str("New"))
	st.handle(AcademyNet.OP_MATCH_MODIFY_RESULT, modified)
	_check((m["banners"] as Array)[-1] == "UIIT_STT_TC_MACHING_CORRECT" and w.slot_text(0, "GDR_MENTORMATCH_SLOT_SUBJECT") == "New",
		"B47B 01: the own row's new title, banner UIIT_STT_TC_MACHING_CORRECT")
	# Delete entry: at once, then B47C.
	w.press_delete()
	_check(sent[-1][0] == AcademyNet.OP_MATCH_DELETE and sent[-1][1] == _fx("747c_delete"),
		"Delete entry sends 747C {own id} at once (MEASURED bytes)")
	st.handle(AcademyNet.OP_MATCH_DELETE_RESULT, _fx("b47c_ok"))
	_check(not w.has_own() and (m["banners"] as Array)[-1] == "UIIT_STT_TC_MACHING_DELETE" and w.slot_text(0, "GDR_MENTORMATCH_SLOT_ID") == "",
		"B47C 01 1: the own entry gone, banner UIIT_STT_TC_MACHING_DELETE")
	# A page whose row 0 is the player's own: it becomes the own entry.
	st.handle(AcademyNet.OP_MATCH_PAGE_RESULT, _page(1, 0, [
		_row(4, 1, "Mine", 70, 70, 1907, "Guardian1", 2, 5, 1, 1),
		_row(5, 1, "Other", 60, 61, 2000, "Mentor9", 0, 4, 0, 2)]))
	_check(w.has_own() and w.own.entry_id == 4 and w.shown.size() == 1, "B47D: row 0 of the player's name is the own entry")
	_check(w.slot_text(0, "GDR_MENTORMATCH_SLOT_ID") == "4" and w.slot_text(1, "GDR_MENTORMATCH_SLOT_NAME") == "Mentor9",
		"the own entry pinned in row 0, the other row below it")
	# The joining member makes no own delete while the roles have room.
	n = sent.size()
	w.on_member_joined()
	_check(sent.size() == n and w.pull_flag == 0, "a member joined with room left: nothing deleted")
	m["host"].queue_free()

## A non-member's view of a page: the rows, selection, Join, Whisper, Search.
func _test_board(builder: UiBuilder) -> void:
	var m := _make(builder, "Novice001", 1)
	var w: AcademyMatchWindow = m["w"]
	var st: AcademyState = m["st"]
	var sent: Array = m["sent"]
	w.on_shown()
	_check(not w.enabled(AcademyMatchWindow.BTN_REGISTER), "Registration off outside an academy")
	var rows := []
	for i in 14:
		rows.append(_row(10 + i, 1 if i % 2 == 0 else 2, "Title %d" % i, 60 + i, 60 + i + (1 if i == 1 else 0),
			2000 if i == 2 else 1907, "Mentor%d" % i, i, 1 + i % 5, i % 3, i % 6))
	st.handle(AcademyNet.OP_MATCH_PAGE_RESULT, _page(3, 1, rows))
	_check(w.page_count == 3 and w.page == 1, "B47D's header: page count first, then the page (c:0x7008c0)")
	var spin := w.node(AcademyMatchWindow.SPIN)
	_check(spin != null and int(spin.get_meta("max", -1)) == 2, "the spin's top is the page count less one")
	_check(w.shown.size() == 14 and w.scroll_max() == 2, "14 rows shown, the scroll range is 14 - 12")
	_check(w.slot_text(0, "GDR_MENTORMATCH_SLOT_ID") == "10" and w.slot_text(0, "GDR_MENTORMATCH_SLOT_LEVEL") == "60",
		"row 0: No. 10, Level \"60\" (level == max)")
	_check(w.slot_text(1, "GDR_MENTORMATCH_SLOT_LEVEL") == "61(62)", "row 1: Level \"61(62)\" (level, max)")
	_check(w.slot_text(2, "GDR_MENTORMATCH_SLOT_RACE") == "<UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_EU>", "row 2: race EUR from the model")
	_check(w.slot_text(3, "GDR_MENTORMATCH_SLOT_NUMBER") == "%d/8" % (3 % 3 + 3 % 6 + 1), "Member = assistants + apprentices + 1 / 8")
	_check(w.slot_text(4, "GDR_MENTORMATCH_SLOT_STUDENT") == "4" and w.slot_text(4, "GDR_MENTORMATCH_SLOT_GRADE_NUM") == "(5)",
		"Graduate and the grade's number")
	var col := _label_color(w._slots[0].get_node_or_null("MatchSlot/GDR_MENTORMATCH_SLOT_NAME"))
	_check(col.is_equal_approx(Color.WHITE), "another row is white")
	_check(w.enabled(AcademyMatchWindow.BTN_JOIN) and w.enabled(AcademyMatchWindow.BTN_WHISPER),
		"Join (level 1, no own entry, rows shown) and Whisper on")
	w.scroll_by(5)
	_check(w.slot_text(0, "GDR_MENTORMATCH_SLOT_ID") == "12", "the scroll stops at 2 (row 0 is entry 12)")
	w.scroll_by(-5)
	# Selection, Join, Whisper.
	w.select_slot(3)
	_check(w.selected_row() != null and w.selected_row().entry_id == 13, "a click selects entry 13")
	var sel := w._slots[3].get_node_or_null("MatchSlot/SelectBar")
	_check(sel == null or (sel as CanvasItem).visible, "the selected row's bar is shown")
	w.press_join()
	_check(sent[-1][0] == AcademyNet.OP_MATCH_JOIN and sent[-1][1] == AcademyNet.encode_entry(13), "Join sends 747E {13}")
	_check(w.progress_box != null, "the joining window opens")
	# Round 866: in the academy's mode (kind 2): 15 s, not the party's 10 s.
	_check(w.progress_box != null and w.progress_box.duration_ms == PartyJoinProgress.ACADEMY_DURATION_MS
		and w.progress_box.name == "AcademyJoinProgress", "the joining window is the academy's (15 s)")
	w.press_whisper()
	_check((m["whispers"] as Array) == ["Mentor3"], "Whisper names the selected guardian")
	w.select_slot(13)
	_check(w.selected_row() == null, "a click on an empty row selects nothing")
	# B47E: the outcomes. Round 866: the window only closes its joining
	# window; the texts are AcademyFlow's (c:0x892c50 needs no window).
	var banners_before := (m["banners"] as Array).size()
	var notices_before := (m["notices"] as Array).size()
	st.handle(AcademyNet.OP_MATCH_JOIN_RESULT, PackedByteArray([1, 1]))
	_check(w.progress_box == null, "B47E 01 01: the joining window closed")
	st.handle(AcademyNet.OP_MATCH_JOIN_RESULT, PackedByteArray([1, 0]))
	st.handle(AcademyNet.OP_MATCH_JOIN_RESULT, PackedByteArray([1, 2]))
	_check((m["banners"] as Array).size() == banners_before and (m["notices"] as Array).size() == notices_before,
		"B47E's texts are not the window's (no second copy)")
	var refused := []
	st.refused.connect(func(c: int) -> void: refused.append(c))
	st.handle(AcademyNet.OP_MATCH_JOIN_RESULT, PackedByteArray([2, 0x2a, 0x68]))
	_check(refused == [0x682a], "B47E 02: the code goes to category 0x1d (AcademyState.refused)")
	# Search: name, grade, condition.
	(w.node(AcademyMatchWindow.NAME_EDIT) as LineEdit).text = "Mentor7"
	w.press_search()
	_check(w.shown.size() == 1 and w.slot_text(0, "GDR_MENTORMATCH_SLOT_NAME") == "Mentor7", "Search by name keeps one row")
	(w.node(AcademyMatchWindow.NAME_EDIT) as LineEdit).text = ""
	w._grade_combo.select(1)
	w.press_search()
	var all_grade_2 := true
	for r in w.shown:
		all_grade_2 = all_grade_2 and (r as AcademyNet.MatchRow).rank == 2
	_check(not w.shown.is_empty() and all_grade_2, "honor grade index 1 keeps rank 2 only")
	w._grade_combo.select(5)
	w._condition_combo.select(1)
	w.press_search()
	var all_asst := true
	for r in w.shown:
		all_asst = all_asst and (r as AcademyNet.MatchRow).flags == 2
	_check(w.shown.size() == 7 and all_asst, "condition index 1 (Asst. guardian) keeps flags 2 only")
	(w.node(AcademyMatchWindow.NAME_EDIT) as LineEdit).text = "Nobody"
	w.press_search()
	_check(w.shown.is_empty() and (m["notices"] as Array)[-1] == ["UIIT_STT_TC_MACHING_REFERENCE_ERROR", 4],
		"no match: UIIT_STT_TC_MACHING_REFERENCE_ERROR (type 4) and an empty list")
	# Refresh: the spin's page, then 2 s off.
	spin.set_meta("value", 2)
	w.press_refresh()
	_check(sent[-1][1] == AcademyNet.encode_page(2) and not w.enabled(AcademyMatchWindow.BTN_REFRESH),
		"Refresh asks for the spin's page and locks itself")
	w.advance(2000)
	_check(w.enabled(AcademyMatchWindow.BTN_REFRESH), "Refresh is back after 2000 ms")
	# B47C of a row the page holds: removed from it; with no page held, asked again.
	st.handle(AcademyNet.OP_MATCH_PAGE_RESULT, _page(3, 1, rows))
	var del := PackedByteArray([1])
	del.append_array(_u32(11))
	st.handle(AcademyNet.OP_MATCH_DELETE_RESULT, del)
	_check(w.shown.size() == 13 and (w.pages[1] as Array).size() == 13, "B47C of entry 11: gone from the page and the list")
	w.pages.clear()
	var n := sent.size()
	st.handle(AcademyNet.OP_MATCH_DELETE_RESULT, del)
	_check(sent.size() == n + 1 and sent[-1][1] == AcademyNet.encode_page(1), "with no page held, the page is asked for again")
	m["host"].queue_free()

## The roles' checks: Registration with both roles full, the box's refusals,
## the full camp's own delete.
func _test_full_roles(builder: UiBuilder) -> void:
	var m := _make(builder, "Guardian1", 70)
	var w: AcademyMatchWindow = m["w"]
	var st: AcademyState = m["st"]
	var sent: Array = m["sent"]
	st.handle(AcademyNet.OP_CAMP, _camp_msg(2, 5))
	w.on_shown()
	st.handle(AcademyNet.OP_MATCH_PAGE_RESULT, _fx("b47d_empty"))
	_check(not w.enabled(AcademyMatchWindow.BTN_REGISTER), "Registration off when both roles are full")
	st.handle(AcademyNet.OP_CAMP, _camp_msg(2, 1))
	w.refresh()
	_check(w.enabled(AcademyMatchWindow.BTN_REGISTER), "Registration on with apprentices to recruit")
	w.press_register()
	(w.register_box.node(AcademyMatchWindow.AcademyMatchRegister.EDIT) as LineEdit).text = "Asst wanted"
	w.register_box.choose_kind(2)
	var n := sent.size()
	w.register_box.press_ok()
	_check(sent.size() == n and (m["banners"] as Array)[-1] == "UIIT_MSG_TC_ERROR_SECOND_GUARDIAN_COUNT_OVER"
		and w.register_box == null, "assistants full: the banner, nothing sent, the box closed")
	st.handle(AcademyNet.OP_CAMP, _camp_msg(1, 5))
	w.press_register()
	(w.register_box.node(AcademyMatchWindow.AcademyMatchRegister.EDIT) as LineEdit).text = "Novices"
	w.register_box.press_ok()
	_check(sent.size() == n and (m["banners"] as Array)[-1] == "UIIT_MSG_TC_ERROR_STUDENT_COUNT_OVER",
		"apprentices full: UIIT_MSG_TC_ERROR_STUDENT_COUNT_OVER, nothing sent")
	# The own entry recruits apprentices; the fifth apprentice joins: deleted.
	st.handle(AcademyNet.OP_CAMP, _camp_msg(1, 4))
	st.handle(AcademyNet.OP_MATCH_REGISTER_RESULT, _fx("b47a_ok"))
	var joined := PackedByteArray([AcademyNet.PUSH_JOINED])
	joined.append_array(AcademyNet.encode_member(_member(399, "Novice9", AcademyNet.CLASS_APPRENTICE, 1)))
	st.handle(AcademyNet.OP_PUSH, joined)
	_check(sent[-1][0] == AcademyNet.OP_MATCH_DELETE and sent[-1][1] == AcademyNet.encode_entry(1) and w.pull_flag == 2,
		"the fifth apprentice joined: the own entry deleted by the client (flag 2)")
	st.handle(AcademyNet.OP_MATCH_DELETE_RESULT, _fx("b47c_ok"))
	_check((m["banners"] as Array)[-1] == "UIIT_STT_TC_MACHING_PULL_DELETE" and w.pull_flag == 0,
		"its B47C says UIIT_STT_TC_MACHING_PULL_DELETE, the flag cleared")
	m["host"].queue_free()
