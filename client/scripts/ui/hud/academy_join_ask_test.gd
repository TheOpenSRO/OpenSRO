extends SceneTree

## Round 866: the academy's matching join on the client -- the guardian's
## question box (AcademyJoinAskBox, CMessageBoxManager kind 0xe), 0x747E
## down's decoding and 0x347F's encoding, AcademyState's routing, and the
## joiner's joining window in the academy's mode (PartyJoinProgress, kind 2).
## The layout is synthetic but carries ifmessagebox.txt's MsgBoxINIF names,
## IDs and rects (as guild822_ui_test.gd); the texts are each key in
## brackets, or a short synthetic line. Identifiers are synthetic. No game
## data.
##   godot4 --headless --path client --script res://scripts/ui/hud/academy_join_ask_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _c(control_name: String, type: String, rect: String, id: int, text: String = "",
		ddj: String = "", halign: int = 0) -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tHAlign=INTEGER,\"%d\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tStyle=INTEGER,\"0\"\n\t\tText=STRING,\"%s\"\n\t}\n" % [
		control_name, type, ddj, halign, id, rect, text]

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
	var progress := ""
	progress += _c("GDR_PARTY_JOIN_PROGRESS_DESC_PML", "CIFPML", "20,40,325,40", 1, "", "", 1)
	progress += _c("GDR_PARTY_JOIN_PROGRESS_BAR", "CIFGauge", "20,90,325,14", 2)
	return "Interface Text\n\n" + _section("MsgBoxINIF", inif) + "\n" + _section("Create", progress)

func _builder() -> UiBuilder:
	var rows := PackedStringArray()
	for k in ["UIIT_PAG_PARTYMATCH_JOINREQUEST", "UIIT_CTL_YES", "UIIT_CTL_NO", "UIIT_CTL_WARENETWORK_RESULT_LEVEL",
			"UIIT_CTL_PARTYMATCH_PSEARCH_LIST_RACE", "UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_CH", "UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_EU",
			"UIIT_PAG_PARTYMATCH_JOINPROGRESS", "UIIT_MSG_TC_JOIN_ERROR_DUPLE", "UIIT_STT_PARTYMATCH_JOIN_PROGRESS"]:
		rows.append("1\t%s\t\t\t\t\t\t\t<%s>" % [k, k])
	rows.append("1\tUIIT_STT_TC_JOIN_REQUEST\t\t\t\t\t\t\t[%s] asks.")
	var builder := UiBuilder.new(null, UiTextTable.parse(("\n".join(rows)).to_utf16_buffer()))
	var cache: Dictionary = builder.get("_layout_cache")
	var parsed := UiLayoutParser.parse(_ifmessagebox())
	cache["resinfo\\ifmessagebox.txt"] = parsed
	cache["resinfo\\ifpartyjoinprogress.txt"] = parsed
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

## The question as the server writes it (synthetic values: job 0x123,
## requester key 0x101, entry 2, a level-30 requester of body 0x773).
func _ask_bytes() -> PackedByteArray:
	var b := PackedByteArray()
	for v in [0x123, 0x101, 2, 0x101]:
		var w := PackedByteArray()
		w.resize(4)
		w.encode_u32(0, v)
		b.append_array(w)
	b.append(30)
	b.append(30)
	var r := PackedByteArray()
	r.resize(4)
	r.encode_u32(0, 0x773)
	b.append_array(r)
	b.append_array(PackedByteArray([2, 0]))
	b.append_array("Ab".to_ascii_buffer())
	return b

func _net() -> void:
	var d := AcademyNet.decode_join_ask(_ask_bytes())
	_check(d.get("job_id") == 0x123 and d.get("requester") == 0x101 and d.get("entry_id") == 2 and d.get("requester2") == 0x101
		and d.get("level") == 30 and d.get("max_level") == 30 and d.get("ref_obj_id") == 0x773 and d.get("name") == "Ab",
		"747E down decodes: job, requester, entry, requester, levels, body, name (got %s)" % [d])
	_check(AcademyNet.decode_join_ask(_ask_bytes().slice(0, 10)).is_empty(), "a short 747E down decodes to {}")
	_check(AcademyNet.encode_join_answer(0x123, 0x101, true) == PackedByteArray([0x23, 1, 0, 0, 1, 1, 0, 0, 1]),
		"347F yes: job, requester, 01")
	_check(AcademyNet.encode_join_answer(0x123, 0x101, false) == PackedByteArray([0x23, 1, 0, 0, 1, 1, 0, 0, 0]),
		"347F no: job, requester, 00")
	_check(AcademyNet.SERVER_OPCODES.has(AcademyNet.OP_MATCH_JOIN), "747E down is registered")
	var st := AcademyState.new()
	var asked := []
	st.join_asked.connect(func(a: Dictionary) -> void: asked.append(a))
	_check(st.handle(AcademyNet.OP_MATCH_JOIN, _ask_bytes()) and asked.size() == 1 and asked[0]["name"] == "Ab",
		"AcademyState routes 747E down to join_asked")

func _box(builder: UiBuilder) -> void:
	var box := AcademyJoinAskBox.new()
	var ask := AcademyNet.decode_join_ask(_ask_bytes())
	_check(box.build_join_ask(builder, ask, 0), "box kind 0xe builds")
	_check(box.size == Vector2(360, 215), "0x168 x 0xd7 (got %s)" % [box.size])
	_check(box.caption.text == "<UIIT_PAG_PARTYMATCH_JOINREQUEST>", "titled UIIT_PAG_PARTYMATCH_JOINREQUEST")
	_check(box.node("GDR_MBIN_BTN_OK").position == Vector2(0x65, 0xae) and box.node("GDR_MBIN_BTN_CANCEL").position == Vector2(0xbd, 0xae),
		"OK at (0x65, 0xae), Cancel at (0xbd, 0xae)")
	_check(not box.node("GDR_MBIN_BTN_CERTIFY").visible, "+0x808 hidden")
	_check(_text(box.node("GDR_MBIN_STATIC_MESSAGE2")) == "<UIIT_CTL_WARENETWORK_RESULT_LEVEL>"
		and box.node("GDR_MBIN_STATIC_MESSAGE2").position == Vector2(0xf, 0x79), "Level at (0xf, 0x79)")
	_check(_text(box.node("GDR_MBIN_STATIC_MESSAGE3")) == "<UIIT_CTL_PARTYMATCH_PSEARCH_LIST_RACE>"
		and box.node("GDR_MBIN_STATIC_MESSAGE3").position == Vector2(0xb5, 0x79), "Race at (0xb5, 0x79)")
	var lbg := box.node("GDR_MBIN_STATIC_MESSAGE4_Blackbox")
	_check(_text(box.node("GDR_MBIN_STATIC_MESSAGE4")) == "30(30)" and lbg != null and lbg.position == Vector2(0x62, 0x79)
		and lbg.size == Vector2(0x3a, 0x14), "level box: \"30(30)\" on the blackbox at (0x62, 0x79), 0x3a x 0x14")
	var rbg := box.node("GDR_MBIN_STATIC_MESSAGE5_Blackbox")
	_check(rbg != null and rbg.position == Vector2(0x108, 0x79), "race box's blackbox at (0x108, 0x79)")
	_check(_text(box.node("GDR_MBIN_STATIC_MESSAGE5")) == "<UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_CH>"
		and box.node("GDR_MBIN_STATIC_MESSAGE5").position.x == 0x108, "race box: race 0 -> RACE_CH at x 0x108")
	var holder := box.get_node_or_null("JoinRequestText") as Control
	_check(holder != null and holder.position == Vector2(0xe, 0x3b) and holder.size == Vector2(0x140, 0x10) and holder.clip_contents,
		"the text control: 0x140 x 0x10 at (0xe, 0x3b), one line")
	box.place_on(Vector2(1280, 1024))
	_check(box.position == Vector2(640 - 0x9a, 512 - 0x4a), "placed as CMessageBoxManager places (w/2 - 0x9a, h/2 - 0x4a)")
	var answers := []
	box.answered.connect(func(a: bool) -> void: answers.append(a))
	(box.node("GDR_MBIN_BTN_OK") as BaseButton).pressed.emit()
	_check(answers == [true], "Yes answers 1")
	box.free()
	var no := AcademyJoinAskBox.new()
	no.build_join_ask(builder, ask, 1)
	_check(_text(no.node("GDR_MBIN_STATIC_MESSAGE5")) == "<UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_EU>", "race 1 -> RACE_EU")
	var a2 := []
	no.answered.connect(func(a: bool) -> void: a2.append(a))
	(no.node("GDR_MBIN_BTN_CANCEL") as BaseButton).pressed.emit()
	_check(a2 == [false], "No answers 0")
	no.free()
	var timed := AcademyJoinAskBox.new()
	timed.build_join_ask(builder, ask, -1)
	_check(_text(timed.node("GDR_MBIN_STATIC_MESSAGE5")) == "", "no race for an unknown body")
	var a3 := []
	timed.answered.connect(func(a: bool) -> void: a3.append(a))
	timed.advance(14.9)
	_check(a3.is_empty(), "nothing before 15 s")
	timed.advance(0.2)
	timed.advance(5.0)
	_check(a3 == [false], "the 15 s timer answers 0, once")
	timed.free()

func _progress(builder: UiBuilder) -> void:
	var p := PartyJoinProgress.new()
	_check(p.build_academy(builder), "the academy's joining window builds")
	_check(p.duration_ms == 15000.0 and p.caption.text == "<UIIT_PAG_PARTYMATCH_JOINPROGRESS>", "15 s, the party's caption")
	_check(p.node("GDR_PARTY_JOIN_PROGRESS_DESC_PML") != null, "its text control exists")
	p.advance(14800)
	_check(p.ratio() < 1.0, "still running at 14.8 s")
	p.advance(400)
	_check(p.ratio() == 1.0, "closed at 15 s")
	p.free()
	var party := PartyJoinProgress.new()
	party.build(builder, "a", "b")
	_check(party.duration_ms == 10000.0, "the party's stays 10 s")
	party.free()

func _init() -> void:
	_net()
	var builder := _builder()
	_box(builder)
	_progress(builder)
	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
