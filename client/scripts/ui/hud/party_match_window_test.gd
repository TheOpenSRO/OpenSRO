extends SceneTree

## Round 714 (lane C2): the Party Matching window and its boxes against what
## the client does (docs/protocol/party_gui.md §3-§5). The layouts are
## synthetic but carry the authored names, types and rects of resinfo\
## ifpartymatch.txt, ifpartymatchslot.txt, ifpartymatchregister.txt,
## ifpartymatchreqjoin.txt and ifpartyjoinprogress.txt (MEASURED from the
## archive, round 714; no textures, no archive text: never real game data).
## The list and the requests run on round 710's golden fixtures.
##
##   godot4 --headless --path client --script res://scripts/ui/hud/party_match_window_test.gd

const FIX := "res://scripts/net/fixtures/party/"

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

func _c(control_name: String, type: String, rect: String, id: int, text: String = "", ddj: String = "") -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tHAlign=INTEGER,\"0\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tStyle=INTEGER,\"0\"\n\t\tText=STRING,\"%s\"\n\t}\n" % [
		control_name, type, ddj, id, rect, text]

func _sec(section: String, body: String) -> String:
	return "Section = %s,\"0,0,0,0\",\"0\"\n{\n%s}\n" % [section, body]

func _ifpartymatch() -> String:
	var create := ""
	create += _c("GDR_PARTYMATCH_SPIN_PAGE", "CIFSpinButtonCtrl", "360,437,50,16", 25)
	for spec in [["GDR_PARTYMATCH_DELETE_BTN", "654,434,0,0", 20], ["GDR_PARTYMATCH_MODIFY_BTN", "553,434,0,0", 19],
			["GDR_PARTYMATCH_REGISTER_BTN", "452,434,0,0", 18], ["GDR_PARTYMATCH_AUTO_MATCH_BTN", "231,434,0,0", 17],
			["GDR_PARTYMATCH_WHISPER_BTN", "130,434,0,0", 16], ["GDR_PARTYMATCH_PARTY_JOIN_BTN", "29,434,0,0", 15]]:
		create += _c(spec[0], "CIFButton", spec[1], spec[2])
	create += _c("GDR_PARTYMATCH_SLOTLIST_BLACKSQUARE", "CIFStretchWnd", "25,119,735,305", 6)
	var search := ""
	search += _c("GDR_PARTYMATCH_UPDATE_BTN", "CIFButton", "635,73,0,0", 56)
	search += _c("GDR_PARTYMATCH_SEARCH_SEARCH_BTN", "CIFButton", "525,73,0,0", 55)
	search += _c("GDR_PARTYMATCH_SEARCH_MAX_LEVEL_EDIT", "CIFEdit", "446,78,29,15", 50)
	search += _c("GDR_PARTYMATCH_SEARCH_MIN_LEVEL_EDIT", "CIFEdit", "396,78,29,15", 49)
	search += _c("GDR_PARTYMATCH_SEARCH_NAME_EDIT", "CIFEdit", "103,79,81,11", 47)
	search += _c("GDR_PARTYMATCH_SEARCH_COMBOBOX", "CIFComboBox", "253,75,74,20", 45)
	var slots := ""
	for i in range(11, -1, -1):
		slots += _c("GDR_PARTYMATCH_SLOTLIST_SLOT_%02d" % i, "CIFPartyMatchSlot", "28,%d,715,24" % (144 + 23 * i), 70 + i)
	return "Interface Text\n\n" + _sec("Create", create) + _sec("SearchInfo", search) + _sec("SlotList", slots)

func _ifpartymatchslot() -> String:
	var b := ""
	for spec in [["GDR_PARTYMATCH_SLOT_LEVEL", "659,7,51,11", 17], ["GDR_PARTYMATCH_SLOT_NUMBER", "619,7,24,11", 16],
			["GDR_PARTYMATCH_SLOT_OBJECT", "566,7,37,11", 15], ["GDR_PARTYMATCH_SLOT_SUBJECT", "248,7,306,11", 14],
			["GDR_PARTYMATCH_SLOT_NAME", "150,7,78,11", 13], ["GDR_PARTYMATCH_SLOT_RACE", "101,7,31,11", 12],
			["GDR_PARTYMATCH_SLOT_MARK", "60,5,16,16", 11], ["GDR_PARTYMATCH_SLOT_ID", "10,7,36,11", 10]]:
		b += _c(spec[0], "CIFStatic", spec[1], spec[2])
	return "Interface Text\n\n" + _sec("Create", b)

func _ifpartymatchregister() -> String:
	var b := ""
	b += _c("GDR_PARTYMATCH_REGISTER_CANCEL_BTN", "CIFButton", "167,329,0,0", 61)
	b += _c("GDR_PARTYMATCH_REGISTER_OK_BTN", "CIFButton", "72,329,0,0", 60)
	b += _c("GDR_PARTYMATCH_REGISTER_MSG_EDIT", "CIFEdit", "19,288,273,15", 49)
	b += _c("GDR_PARTYMATCH_REGISTER_ITEM_STA", "CIFStatic", "177,226,120,11", 47)
	b += _c("GDR_PARTYMATCH_REGISTER_EXP_STA", "CIFStatic", "40,226,120,11", 45)
	b += _c("GDR_PARTYMATCH_REGISTER_LEVEL_MAX_EDIT", "CIFEdit", "218,152,66,15", 43)
	b += _c("GDR_PARTYMATCH_REGISTER_LEVEL_MIN_EDIT", "CIFEdit", "80,152,66,15", 42)
	b += _c("GDR_PARTYMATCH_REGISTER_OBJECT_RBTN", "CIFRadioButton", "30,77,272,16", 40)
	return "Interface Text\n\n" + _sec("Create", b)

func _ifpartymatchreqjoin() -> String:
	var b := ""
	b += _c("GDR_PARTYMATCH_REQ_JOIN_CANCEL_BTN", "CIFButton", "191,266,0,0", 46)
	b += _c("GDR_PARTYMATCH_REQ_JOIN_OK_BTN", "CIFButton", "103,266,0,0", 45)
	b += _c("GDR_PARTYMATCH_REQ_JOIN_MASTERY_02", "CIFStatic", "130,121,32,32", 35)
	b += _c("GDR_PARTYMATCH_REQ_JOIN_MASTERY_01", "CIFStatic", "88,121,32,32", 34)
	b += _c("GDR_PARTYMATCH_REQ_JOIN_GUILD", "CIFStatic", "98,227,229,11", 33)
	b += _c("GDR_PARTYMATCH_REQ_JOIN_POS", "CIFStatic", "98,191,231,11", 32)
	b += _c("GDR_PARTYMATCH_REQ_JOIN_RACE", "CIFStatic", "270,152,58,11", 31)
	b += _c("GDR_PARTYMATCH_REQ_JOIN_LEVEL", "CIFStatic", "269,124,58,11", 30)
	b += _c("GDR_PARTYMATCH_REQ_JOIN_DESC_PML", "CIFPML", "20,59,322,35", 21)
	return "Interface Text\n\n" + _sec("Create", b)

func _ifpartyjoinprogress() -> String:
	var b := ""
	b += _c("GDR_PARTY_JOIN_PROGRESS_BAR", "CIFGauge", "35,104,296,12", 11)
	b += _c("GDR_PARTY_JOIN_PROGRESS_DESC_PML", "CIFPML", "16,50,335,29", 5)
	return "Interface Text\n\n" + _sec("Create", b)

## Every key reads as itself in angle brackets, so a check can tell which key
## a control shows; the two PML strings carry their sml2 markup.
func _text_table() -> UiTextTable:
	var rows := PackedStringArray()
	for k in PartyMatchNet.PURPOSE_KEYS + PartyMatchNet.RACE_KEYS + PartyMatchNet.DEFAULT_TITLE_KEYS + [
			"UIIT_PAG_PARTYMATCH_RECORD", "UIIT_PAG_PARTYMATCH_MODIFY", "UIIT_PAG_PARTYMATCH_JOINREQUEST",
			"UIIT_PAG_PARTYMATCH_JOINPROGRESS", "UIIT_STT_PARTY_EXP_SHARE", "UIIT_STT_PARTY_ITEM_SELF"]:
		rows.append("1\t%s\t\t\t\t\t\t\t<%s>" % [k, k])
	rows.append("1\tUIIT_STT_PARTYMATCH_JOIN_REQUEST\t\t\t\t\t\t\t<sml2><font color=\"255,239,218,164\">[%s]</font>has requested to join this party.<br> Confirm?</sml2>")
	rows.append("1\tUIIT_STT_PARTYMATCH_JOIN_PROGRESS\t\t\t\t\t\t\t<sml2><font color=\"255,239,218,164\">[%s]</font>You <font color=\"255,239,218,164\">[%s]</font> has requested to join this party. </sml2>")
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, _text_table())
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\ifpartymatch.txt"] = UiLayoutParser.parse(_ifpartymatch())
	cache["resinfo\\ifpartymatchslot.txt"] = UiLayoutParser.parse(_ifpartymatchslot())
	cache["resinfo\\ifpartymatchregister.txt"] = UiLayoutParser.parse(_ifpartymatchregister())
	cache["resinfo\\ifpartymatchreqjoin.txt"] = UiLayoutParser.parse(_ifpartymatchreqjoin())
	cache["resinfo\\ifpartyjoinprogress.txt"] = UiLayoutParser.parse(_ifpartyjoinprogress())
	return builder

func _label_text(n: Node) -> String:
	if n == null:
		return "(null)"
	if n is Label:
		return (n as Label).text
	var l := n.get_node_or_null("Text") as Label
	return l.text if l != null else "(no text)"

func _label_color(n: Node) -> Color:
	var l: Label = n as Label if n is Label else (n.get_node_or_null("Text") as Label if n != null else null)
	return l.get_theme_color("font_color") if l != null else Color.TRANSPARENT

## The window as HudPanels builds it (its three sections into one Control)
## and the controller over it.
func _make(builder: UiBuilder, key: String, level: int, party: PartyState = null) -> Array:
	var host := Control.new()
	host.name = "Host"
	host.size = Vector2(1280, 720)
	root.add_child(host)
	var win := Control.new()
	win.name = "Window_partymatch"
	host.add_child(win)
	var layout := builder.load_layout("resinfo\\ifpartymatch.txt")
	for s in ["Create", "SearchInfo", "SlotList"]:
		var built := builder.build_section(layout, s)
		win.add_child(built)
		UiBuilder.apply_authored_rects(built)
	var st := PartyMatchState.new()
	var sent: Array = []
	st.send = func(op: int, payload: PackedByteArray) -> void: sent.append([op, payload])
	st.registration_key = func() -> String: return key
	var w := PartyMatchWindow.new(builder, st, party if party != null else PartyState.new(), host)
	w.own_level = func() -> int: return level
	w.own_name = func() -> String: return key
	w.view_size = func() -> Vector2: return Vector2(1280, 720)
	w.attach(win)
	return [w, st, sent, host]

func _slot_text(w: PartyMatchWindow, i: int, col: String) -> String:
	var slot := w.node("GDR_PARTYMATCH_SLOTLIST_SLOT_%02d" % i)
	return _label_text(slot.get_node_or_null("MatchSlot/" + col)) if slot != null else "(no slot)"

func _test_list(builder: UiBuilder) -> void:
	var made := _make(builder, "Aria", 10)
	var w: PartyMatchWindow = made[0]
	var st: PartyMatchState = made[1]
	var sent: Array = made[2]
	w.on_shown()
	_check(sent.size() == 1 and sent[0][1] == _fx("706c_page"), "opening asks for page 0 (0x73b1ff)")
	st.handle(_fx("b06c_page"), PartyMatchNet.OP_PAGE_ACK)
	_check(_slot_text(w, 0, "GDR_PARTYMATCH_SLOT_ID") == "12" and _slot_text(w, 0, "GDR_PARTYMATCH_SLOT_NAME") == "Aria",
		"row 0 is the player's own registration (entry 12)")
	var own_col := _label_color(w.node("GDR_PARTYMATCH_SLOTLIST_SLOT_00").get_node_or_null("MatchSlot/GDR_PARTYMATCH_SLOT_NAME"))
	_check(own_col.is_equal_approx(Color8(135, 233, 255)), "the own row is drawn (135,233,255) (got %s)" % own_col)
	_check(_slot_text(w, 1, "GDR_PARTYMATCH_SLOT_NAME") == "*Bram" and _slot_text(w, 1, "GDR_PARTYMATCH_SLOT_RACE") == "<UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_EU>"
		and _slot_text(w, 1, "GDR_PARTYMATCH_SLOT_OBJECT") == "<UIIT_CTL_PARTYMATCH_PSEARCH_FIND_OBJECTTRADER>",
		"row 1: *Bram, race EUR and purpose Trade as text")
	_check(_slot_text(w, 1, "GDR_PARTYMATCH_SLOT_NUMBER") == "1/4" and _slot_text(w, 1, "GDR_PARTYMATCH_SLOT_LEVEL") == "20~40",
		"row 1: 1/4 members, 20~40")
	_check(_slot_text(w, 0, "GDR_PARTYMATCH_SLOT_NUMBER") == "2/8", "row 0: 2/8 (exp share)")
	_check(_slot_text(w, 2, "GDR_PARTYMATCH_SLOT_ID") == "", "empty rows are blank")
	# Selection: a row with data takes the gold bar; an empty row does not.
	w.select_slot(1)
	var sel1 := w.node("GDR_PARTYMATCH_SLOTLIST_SLOT_01").get_node_or_null("SelectBar") as CanvasItem
	_check(w.selected_number == 15, "a click selects entry 15")
	w.select_slot(5)
	_check(w.selected_number == 15, "a click on an empty row changes nothing")
	# The owner holds a registration: Join and Auto off, Change / Delete on.
	_check(not w.enabled(PartyMatchWindow.BTN_JOIN) and not w.enabled(PartyMatchWindow.BTN_AUTO),
		"Join party and Auto match are off while the player holds a registration")
	_check(w.enabled(PartyMatchWindow.BTN_CHANGE) and w.enabled(PartyMatchWindow.BTN_DELETE), "Change / Delete entry for the owner")
	_check(not w.enabled(PartyMatchWindow.BTN_FORM), "Form party is off with a registration")
	# Refresh: the spin's page, then disabled for 2 s.
	w.press_refresh()
	_check(sent.back()[0] == 0x706c and not w.enabled(PartyMatchWindow.BTN_REFRESH), "Refresh asks for the page and disables itself")
	w.advance(1990)
	_check(not w.enabled(PartyMatchWindow.BTN_REFRESH), "still off at 1.99 s")
	w.advance(20)
	_check(w.enabled(PartyMatchWindow.BTN_REFRESH), "back after 2 s (timer 10, 0x73ab60)")
	(made[3] as Control).queue_free()

func _test_join(builder: UiBuilder) -> void:
	var made := _make(builder, "Dasha", 1)
	var w: PartyMatchWindow = made[0]
	var st: PartyMatchState = made[1]
	var sent: Array = made[2]
	st.handle(_fx("b06c_page"), PartyMatchNet.OP_PAGE_ACK)
	_check(w.enabled(PartyMatchWindow.BTN_JOIN) and w.enabled(PartyMatchWindow.BTN_WHISPER), "no registration, no party, records: Join on")
	_check(not w.enabled(PartyMatchWindow.BTN_FORM), "Form party needs level 5 out of a party")
	_check(not w.enabled(PartyMatchWindow.BTN_CHANGE), "Change entry needs the player's own registration")
	w.select_slot(0)
	w.press_join()
	_check(sent.back()[0] == 0x706d and sent.back()[1] == _fx("706d_request"), "Join party sends 0x706d for the selected entry 12")
	var prog := w.progress_box
	_check(prog != null and is_instance_valid(prog), "the joining window opens")
	if prog != null:
		var rt := prog.node("GDR_PARTY_JOIN_PROGRESS_DESC_PML").get_node_or_null("PmlText") as RichTextLabel
		_check(rt != null and rt.text.contains("Dasha") and rt.text.contains("Aria") and rt.text.find("Dasha") < rt.text.find("Aria"),
			"its text names the player, then the party (got %s)" % (rt.text if rt != null else "none"))
		_check(prog.position == Vector2(floorf(640 - 182.5), floorf(360 - 74.5)), "centred on the screen (0x798b70) (got %s)" % prog.position)
		_check(not w.enabled(PartyMatchWindow.BTN_JOIN) and not w.enabled(PartyMatchWindow.BTN_SEARCH),
			"Join and Search are off while it is up (0x738890)")
		prog.advance(5000)
		_check(is_equal_approx(prog.ratio(), 0.5), "the bar is half full at 5 s")
		prog.advance(5000)
		_check(not is_instance_valid(prog) or prog.is_queued_for_deletion(), "it closes itself at 10 s")
	_check(w.enabled(PartyMatchWindow.BTN_JOIN), "Join is back once it has closed")
	(made[3] as Control).queue_free()

func _test_search(builder: UiBuilder) -> void:
	var made := _make(builder, "Zed", 30)
	var w: PartyMatchWindow = made[0]
	var st: PartyMatchState = made[1]
	st.handle(_fx("b06c_page"), PartyMatchNet.OP_PAGE_ACK)
	_check(w.records().size() == 2, "both records listed")
	(w.node("GDR_PARTYMATCH_SEARCH_NAME_EDIT") as LineEdit).text = "Bram"
	w.press_search()
	_check(w.records().size() == 1 and w.records()[0].leader_name == "Bram", "Search by the exact name keeps Bram")
	var lines: Array = []
	w.notice.connect(func(k: String, c: int, t: int) -> void: lines.append([k, t]))
	(w.node("GDR_PARTYMATCH_SEARCH_NAME_EDIT") as LineEdit).text = "bram"
	w.press_search()
	_check(w.records().is_empty() and lines.back() == ["UIIT_MSG_PARTYMATCH_PSEARCH_NORESULT", 4], "nothing left: PSEARCH_NORESULT, type 4")
	st.handle(_fx("b06c_page"), PartyMatchNet.OP_PAGE_ACK)
	_check(w.records().size() == 2, "a new page clears the filter (OURS)")
	(made[3] as Control).queue_free()

func _test_register(builder: UiBuilder) -> void:
	# The fixture's type byte is 0x03 (exp and item share, no "anyone").
	var party := PartyState.new()
	party.set_preferences(1, 1, 0)
	var made := _make(builder, "Aria", 10, party)
	var w: PartyMatchWindow = made[0]
	var st: PartyMatchState = made[1]
	var sent: Array = made[2]
	st.handle(_fx("b06c_empty"), PartyMatchNet.OP_PAGE_ACK)
	_check(w.enabled(PartyMatchWindow.BTN_FORM), "Form party on: level 10, no party, no registration")
	w.press_form()
	var box := w.register_box
	_check(box != null and is_instance_valid(box), "the register dialog opens")
	if box == null:
		return
	_check(box.caption.text == "<UIIT_PAG_PARTYMATCH_RECORD>", "its caption is UIIT_PAG_PARTYMATCH_RECORD")
	_check(not box.radio_enabled("object", 2) and not box.radio_enabled("object", 3) and box.choice("object") == 0,
		"no job: Trade and Thief are off, Hunting chosen")
	var title := box.node("GDR_PARTYMATCH_REGISTER_MSG_EDIT") as LineEdit
	_check(title.text == "<UIIT_MSG_PARTYMATCH_RECORD_DEFAULT1>", "Hunting's default title (DEFAULT1)")
	box.choose("object", 1)
	_check(title.text == "<UIIT_MSG_PARTYMATCH_RECORD_DEFAULT3>", "Quest's default title (DEFAULT3) replaces a default")
	title.text = "For open hunting"
	box.choose("object", 0)
	_check(title.text == "For open hunting", "a title of the player's own stays")
	var lines: Array = []
	w.notice.connect(func(k: String, c: int, t: int) -> void: lines.append(k))
	(box.node("GDR_PARTYMATCH_REGISTER_LEVEL_MIN_EDIT") as LineEdit).text = "50"
	(box.node("GDR_PARTYMATCH_REGISTER_LEVEL_MAX_EDIT") as LineEdit).text = "40"
	box.press_ok()
	_check(lines.back() == "UIIT_MSG_PARTYMATCH_RECORD_ERROR_LEVEL", "min above max: RECORD_ERROR_LEVEL")
	(box.node("GDR_PARTYMATCH_REGISTER_LEVEL_MIN_EDIT") as LineEdit).text = "1"
	(box.node("GDR_PARTYMATCH_REGISTER_LEVEL_MAX_EDIT") as LineEdit).text = "110"
	box.press_ok()
	_check(sent.back()[0] == 0x7069 and sent.back()[1] == _fx("7069_register"), "OK sends the register request (fixture 7069)")
	st.handle(_fx("b069_ok"), PartyMatchNet.OP_REGISTER_ACK)
	_check(w.register_box == null and st.registration != null and _slot_text(w, 0, "GDR_PARTYMATCH_SLOT_ID") == "12",
		"0xb069 closes the dialog and pins entry 12")
	(made[3] as Control).queue_free()

func _test_req_join(builder: UiBuilder) -> void:
	var made := _make(builder, "Aria", 10)
	var w: PartyMatchWindow = made[0]
	var st: PartyMatchState = made[1]
	var sent: Array = made[2]
	w.race_of_model = func(ref_id: int) -> int: return 1 if ref_id == 1908 else -1
	w.zone_name = func(region: int) -> String: return "Jangan" if region == 25000 else ""
	st.handle(_fx("706d_to_leader"), PartyMatchNet.OP_JOIN)
	var box := w.req_join_box
	_check(box != null and is_instance_valid(box), "S->C 0x706d opens the leader's popup")
	if box == null:
		return
	_check(box.caption.text == "<UIIT_PAG_PARTYMATCH_JOINREQUEST>", "its caption is UIIT_PAG_PARTYMATCH_JOINREQUEST")
	_check(_label_text(box.node("GDR_PARTYMATCH_REQ_JOIN_LEVEL")) == "7", "Level 7")
	_check(_label_text(box.node("GDR_PARTYMATCH_REQ_JOIN_RACE")) == "<UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_EU>", "Race EUR from the model")
	_check(_label_text(box.node("GDR_PARTYMATCH_REQ_JOIN_POS")) == "Jangan", "Position: region 25000's zone name")
	_check(_label_text(box.node("GDR_PARTYMATCH_REQ_JOIN_GUILD")) == "Wolves", "Guild shown with job state 4")
	var rt := box.node("GDR_PARTYMATCH_REQ_JOIN_DESC_PML").get_node_or_null("PmlText") as RichTextLabel
	_check(rt != null and rt.text.contains("Bram") and rt.text.contains("[color=#ffefda]"), "the PML names Bram in (255,239,218)")
	box.advance(9990)
	_check(sent.is_empty(), "nothing sent before 10 s")
	box.advance(20)
	_check(sent.size() == 1 and sent[0][0] == 0x306e and sent[0][1] == _fx("306e_closed"), "10 s unanswered sends 0x306e answer 2")
	st.handle(_fx("706d_to_leader"), PartyMatchNet.OP_JOIN)
	w.req_join_box.press_confirm()
	_check(sent.size() == 2 and sent[1][1] == _fx("306e_confirm"), "Confirm sends answer 1")
	(made[3] as Control).queue_free()

func _test_full_party_delete(builder: UiBuilder) -> void:
	var party := PartyState.new()
	var made := _make(builder, "Aria", 10, party)
	var w: PartyMatchWindow = made[0]
	var st: PartyMatchState = made[1]
	var sent: Array = made[2]
	st.handle(_fx("b06c_page"), PartyMatchNet.OP_PAGE_ACK)
	party.handle(PartyNet.OP_CREATE_ACK, _fx("b060_ok"))
	party.handle(PartyNet.OP_PARTY_INFO, _fx("3065_two_members"))
	var before := sent.size()
	_check(party.in_party and not party.is_full(), "a party of two is not full")
	_check(sent.size() == before, "nothing deleted while there is room")
	_check(w != null, "window alive")
	(made[3] as Control).queue_free()

func _initialize() -> void:
	var builder := _builder()
	_test_list(builder)
	_test_join(builder)
	_test_search(builder)
	_test_register(builder)
	_test_req_join(builder)
	_test_full_party_delete(builder)
	if _failures == 0:
		print("party_match_window_test: all checks passed")
		quit(0)
	else:
		print("party_match_window_test: %d check(s) FAILED" % _failures)
		quit(1)
