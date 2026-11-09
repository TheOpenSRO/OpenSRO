extends SceneTree

## Round 869 (lane C1): the instance NPCs' talk lines -- the exit (0x29) and
## the party recall (0x27) -- against sro_client.exe's rules (RecallFlow,
## SummonPartyWindow, InstanceTalkNet; docs/protocol/forgotten_world.md 8):
## the talk lines and what they send, 0xB519's rows in the summon window
## (built from the player's own `res_ui\nifsummonpartyuserwnd.2dt`), the
## row's selection and the Summon button's rule, the 20 s wait, the member's
## question and its 20 s timer, 0x751C's bytes, and the refusal tables of
## categories 1, 0xd and 0x23. Reads Media.pk2 on the render box (the window
## part SKIPs without it); nothing from the archive is committed. Ids and
## names are synthetic.
##   godot4 --headless --path client --script res://scripts/world/recall_flow_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const ErrorText = preload("res://scripts/net/error_text.gd")

var FlowScript: GDScript
var _failures := 0
var _builder: UiBuilder
var _table: UiTextTable

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

class FakeWorld extends Node:
	var _ui_text_table: UiTextTable
	var logged: Array = []
	func _resolve_any_text(key: String, fallback: String) -> String:
		var t := _ui_text_table.get_text(key, "") if _ui_text_table != null else ""
		return t if t != "" and t != key else fallback
	func _log_system(text: String, _type: int = 0) -> void:
		logged.append(text)
	func _talk_npc_uid() -> int:
		return 0x01020304

func _run() -> void:
	_test_codecs()
	_test_talk_lines()
	_test_tables_keys()
	if not FileAccess.file_exists(MEDIA):
		print("SKIP the window and the flow (no %s)" % MEDIA)
		return
	var pk2 := Pk2Reader.open(MEDIA)
	_check(pk2 != null, "Media.pk2 opens")
	if pk2 == null:
		return
	var entry := ObjectLoader.find_file(pk2, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	_table = UiTextTable.parse(pk2.read_file(entry)) if entry != null else null
	root.size = Vector2i(1280, 1024)
	await process_frame
	_builder = UiBuilder.new(pk2, _table)
	FlowScript = load("res://scripts/world/recall_flow.gd")
	_test_texts()
	await _test_window()
	await _test_flow()

# --- bytes ------------------------------------------------------------------------

func _test_codecs() -> void:
	_check(InstanceTalkNet.encode_npc(0x01020304).hex_encode() == "04030201", "0x751D / 0x7519: u32 npc")
	_check(InstanceTalkNet.encode_summon(0x11).hex_encode() == "11000000", "0x751A: u32 char id")
	_check(InstanceTalkNet.encode_answer(0x22, 0x33, true).hex_encode() == "220000003300000001", "0x751C: requester, own, 1")
	_check(InstanceTalkNet.encode_answer(0x22, 0x33, false).hex_encode() == "220000003300000000", "... and 0 for No")
	var list := InstanceTalkNet.decode_list(("0102" + "1100000002290f00" + "12000000031e0000").hex_decode())
	_check(bool(list.get("ok", false)) and (list["entries"] as Array).size() == 2, "0xB519 1: two rows")
	var e0: InstanceTalkNet.Entry = list["entries"][0]
	var e1: InstanceTalkNet.Entry = list["entries"][1]
	_check(e0.char_id == 0x11 and e0.state == 2 and e0.level == 41 and e0.minutes == 15, "row 0: id, state 2, 41, 15 minutes")
	_check(e1.char_id == 0x12 and e1.state == 3 and e1.level == 30 and e1.minutes == 0, "row 1: id, state 3, 30, 0")
	var refused := InstanceTalkNet.decode_list("02331c".hex_decode())
	_check(not bool(refused["ok"]) and int(refused["code"]) == 0x1c33, "0xB519 2: the code")
	_check(InstanceTalkNet.decode_list("010211000000".hex_decode()).is_empty(), "a short 0xB519 is dropped")
	var push := InstanceTalkNet.decode_push(("21000000" + "22000000" + "23000000" + "0700" + "Leader1".to_ascii_buffer().hex_encode()).hex_decode())
	_check(int(push.get("requester", 0)) == 0x21 and int(push["second"]) == 0x22 and String(push["name"]) == "Leader1",
		"0x751A push: requester, u32, u32, the name")
	_check(InstanceTalkNet.refusal_code("01".hex_decode()) == -1, "{1}: no refusal")
	_check(InstanceTalkNet.refusal_code("02361c".hex_decode()) == 0x1c36, "{2, code}: the code")
	_check(InstanceTalkNet.refusal_code("03361c".hex_decode()) == 0x1c36, "B51D / B51A: any result but 1 reads the code")
	_check(InstanceTalkNet.refusal_code("03361c".hex_decode(), true) == -1, "B51C: only 2 reads it")

func _test_talk_lines() -> void:
	var s := NpcServiceReader.services_from_ids(PackedByteArray([0x29, 0x27]))
	var keys := s.map(func(v) -> String: return (v as NpcServiceReader.Service).key)
	_check(keys == ["party_summon", "dungeon_exit"], "0x27 then 0x29 in the builder's order: %s" % [keys])
	var strids := s.map(func(v) -> String: return (v as NpcServiceReader.Service).strid)
	_check(strids == ["UIIT_PAG_PARTY_SUMMON", "UIIT_STT_DUNGEON_EXIT"], "their tokens")

func _test_tables_keys() -> void:
	_check(ErrorText.SUMMON_UIIT_BY_CODE.size() == 9, "category 0x23: nine rows")
	_check(ErrorText.INTERACTION_UIIT_BY_CODE[0x1c28] == "UIIT_MSG_EGYPT_TOMB_ENTRANCE_CONDITION_ERROR_02", "category 0xd 0x1c28")
	_check(not ErrorText.INTERACTION_UIIT_BY_CODE.has(2) and not ErrorText.INTERACTION_UIIT_BY_CODE.has(3), "2 / 3: no text")
	_check(ErrorText.exit_line(0x1c36, null) == "" and ErrorText.exit_line(0x1c10, null) == "" and ErrorText.exit_line(2, null) == "",
		"category 1: the exit's refusals show nothing")

func _text(key: String) -> String:
	return _table.get_text(key, "") if _table != null else ""

func _test_texts() -> void:
	_check(ErrorText.interaction_line(0x1c33, _table) == _text("UIIT_MGS_ERR_GOD_TELEPORT_HOLE_NOT_PARTY") and _text("UIIT_MGS_ERR_GOD_TELEPORT_HOLE_NOT_PARTY") != "",
		"0xd 0x1c33 -> %s" % ErrorText.interaction_line(0x1c33, _table))
	_check(ErrorText.interaction_line(0x1c34, _table) != "", "0xd 0x1c34 -> %s" % ErrorText.interaction_line(0x1c34, _table))
	_check(ErrorText.interaction_line(2, _table) == "", "0xd 2 -> nothing")
	for code in ErrorText.SUMMON_UIIT_BY_CODE:
		_check(ErrorText.summon_line(int(code), _table) != "", "0x23 0x%x -> %s" % [code, ErrorText.summon_line(int(code), _table)])
	_check(ErrorText.summon_line(0x1c38, _table) == "", "0x23 0x1c38 -> nothing")
	_check(ErrorText.exit_line(3, _table) == _text("UIIT_MSG_STRGERR_INVALID_TARGET"), "category 1, 3 -> INVALID_TARGET")

# --- the window -----------------------------------------------------------------------

func _entries(spec: Array) -> Array:
	var out: Array = []
	for s in spec:
		var e := InstanceTalkNet.Entry.new()
		e.char_id = int(s[0])
		e.state = int(s[1])
		e.level = int(s[2])
		e.minutes = int(s[3])
		out.append(e)
	return out

func _test_window() -> void:
	var w := SummonPartyWindow.new()
	_check(w.build_window(_builder), "the window builds from nifsummonpartyuserwnd.2dt")
	root.add_child(w)
	_check(w.rows.size() == 8 and w.size == Vector2(496, 320), "eight rows, 496 x 320")
	_check(w.position == Vector2(362, 176), "at its authored rect (no OnCreate move)")
	_check(not w.visible and w.summon_button().disabled, "loaded hidden, Summon disabled (OnCreate)")
	var clock := [1000]
	w.now_ms = func() -> int: return clock[0]
	w.name_of = func(id: int) -> String: return {0x11: "MemberA1", 0x12: "MemberB2", 0x13: "MemberC3"}.get(id, "")
	w.fill(_entries([[0x11, 2, 41, 15], [0x12, 3, 30, 0], [0x13, 1, 52, 9]]))
	var rep := w.report()
	_check(w.visible and w.summon_button().disabled, "0xB519: shown, Summon still disabled (vslot_023)")
	_check(rep[0] == ["MemberA1", _text("UIIT_CTL_PARTY_SUMMON_POSSILBE"), "41", "15 %s" % _text("UIIT_STT_MINUTE")], "row 0: %s" % [rep[0]])
	_check(rep[1][1] == _text("UIIT_CTL_PARTY_SUMMON_IMPOSSILBE") and rep[1][2] == "30", "row 1: %s" % [rep[1]])
	_check(rep[2][1] == _text("UIIT_STT_FORT_SMITH_COMPLETE"), "row 2: %s" % [rep[2]])
	_check(rep[3] == ["", "", "", ""], "row 3 empty")
	var st1 := w.row_text(1, SummonPartyWindow.ID_STATE)
	_check(st1.tooltip_text == _text("UIIT_STT_PARTY_SUMMON_IMPOSSILBE"), "state 3's tooltip")
	var lbl := st1.get_node_or_null("Text") as Label
	_check(lbl != null and lbl.get_theme_color("font_color") == TwoDtBuilder.argb(0xffd40000), "state 3 in 0xffd40000")
	var lbl0 := w.row_text(0, SummonPartyWindow.ID_STATE).get_node_or_null("Text") as Label
	_check(lbl0 != null and lbl0.get_theme_color("font_color") == TwoDtBuilder.argb(0xff02da11), "state 2 in 0xff02da11")
	w.select_row(3)
	_check(w.selected == -1, "an empty row does not select")
	w.select_row(1)
	_check(w.selected == 1 and w.summon_button().disabled, "state 3 selected: Summon disabled")
	w.select_row(0)
	_check(w.selected == 0 and not w.summon_button().disabled, "state 2 selected: Summon enabled")
	_check(w.rows[0].get_node("SelectArt").visible and not w.rows[1].get_node("SelectArt").visible, "the selected row's art")
	var asked: Array = []
	w.summon_requested.connect(func(id: int) -> void: asked.append(id))
	w.summon_button().pressed.emit()
	_check(asked == [0x11] and w.waiting(0) and w.summon_button().disabled, "Summon: 0x751A for 0x11, the row waits, disabled")
	w.select_row(2)
	w.select_row(0)
	_check(w.summon_button().disabled, "a waiting row re-selected: still disabled")
	clock[0] += 19999
	w.tick()
	_check(w.waiting(0), "19,999 ms: still waiting")
	clock[0] += 1
	w.tick()
	_check(not w.waiting(0) and not w.summon_button().disabled, "20,000 ms: the wait ends, Summon enabled again")
	w.fill(_entries([[0x12, 3, 30, 0]]))
	_check(w.report()[0][0] == "MemberB2" and w.report()[1] == ["", "", "", ""], "a refill replaces the rows")
	w.queue_free()
	await process_frame

# --- the flow through NetClient -------------------------------------------------

func _test_flow() -> void:
	var net := root.get_node_or_null("NetClient")
	_check(net != null, "the NetClient autoload is there")
	if net == null:
		return
	var world := FakeWorld.new()
	world._ui_text_table = _table
	root.add_child(world)
	var hud = load("res://scripts/ui/hud/hud_panels.gd").new(_builder)
	root.add_child(hud)
	var flow = FlowScript.new(world, hud)
	var sent: Array = []
	flow.send = func(op: int, p: PackedByteArray) -> void: sent.append([op, p.hex_encode()])
	_check(flow.handle_service("dungeon_exit") and sent[-1] == [0x751D, "04030201"], "Exit Dungeon: 0x751D {talk NPC}")
	_check(flow.handle_service("party_summon") and sent[-1] == [0x7519, "04030201"], "Summon Party member: 0x7519 {talk NPC}")
	_check(not flow.handle_service("talk"), "other lines are not its")
	net.qa_receive(0xB51D, "01".hex_decode())
	net.qa_receive(0xB51D, "02361c".hex_decode())
	_check(world.logged.is_empty(), "0xB51D {1} and {2, 0x1c36}: nothing shown (category 1)")
	var party: PartyState = net.get("party")
	var m := PartyNet.Member.new()
	m.jid = 0x11
	m.member_name = "MemberA1"
	party.members.append(m)
	party.own_jid = 0x44
	net.qa_receive(0xB519, "0101110000000229 0f00".replace(" ", "").hex_decode())
	_check(flow.window != null and flow.window.visible and flow.window.report()[0][0] == "MemberA1", "0xB519: the window with the party's name")
	flow.window.select_row(0)
	flow.window.summon_button().pressed.emit()
	_check(sent[-1] == [0x751A, "11000000"], "Summon through the flow: 0x751A {0x11}")
	net.qa_receive(0xB51A, "023a1c".hex_decode())
	_check(world.logged[-1] == _text("UIIT_STT_PARTY_SUMMON_WAIT_ERR"), "0xB51A 0x1c3a: %s" % world.logged[-1])
	net.qa_receive(0xB519, "02331c".hex_decode())
	_check(world.logged[-1] == _text("UIIT_MGS_ERR_GOD_TELEPORT_HOLE_NOT_PARTY") and flow.window.report()[0][0] == "",
		"0xB519 2: the list cleared, category 0xd's line")
	# The member's question.
	net.qa_receive(0x751A, ("21000000" + "22000000" + "00000000" + "0700" + "Leader1".to_ascii_buffer().hex_encode()).hex_decode())
	var q: PartyMatchConfirm = flow.box
	var expect := _text("UIIT_STT_GNGWC_PARTY_MEMBER_CALL").replace("%s", "Leader1")
	_check(q != null and q.visible and q.size == Vector2(360, 151), "0x751A push: the 360 x 151 question")
	_check(q != null and (q.get_node("Message") as Label).text == expect, "... '%s'" % expect)
	_check(flow.requester == 0x21, "+0x7c8 the requester")
	q._find_button(true).pressed.emit()
	_check(sent[-1] == [0x751C, "210000004400000001"], "Yes: 0x751C {requester, own JID, 1}")
	net.qa_receive(0x751A, ("21000000" + "22000000" + "00000000" + "0700" + "Leader1".to_ascii_buffer().hex_encode()).hex_decode())
	var n_sent := sent.size()
	flow.expire_box()
	_check(sent.size() == n_sent and flow.requester == 0 and (flow.box == null), "20 s with no answer: closed, nothing sent")
	net.qa_receive(0x751A, ("21000000" + "22000000" + "00000000" + "0700" + "Leader1".to_ascii_buffer().hex_encode()).hex_decode())
	flow.box._find_button(false).pressed.emit()
	_check(sent[-1] == [0x751C, "210000004400000000"], "No: 0x751C {.., 0}")
	net.qa_receive(0xB51C, "022a1c".hex_decode())
	_check(world.logged[-1] == _text("UIIT_MSG_EGYPT_TOMB_ENTRANCE_CONDITION_ERROR_05"), "0xB51C 2: category 0xd")
	_check(ANSWER_WAIT_OK(), "the question's timer is 20 s (READ 0x4e20)")
	flow.detach()
	party.members.clear()
	party.own_jid = 0
	hud.queue_free()
	world.queue_free()
	await process_frame

func ANSWER_WAIT_OK() -> bool:
	return is_equal_approx(float(FlowScript.ANSWER_WAIT_SEC), 20.0) and SummonPartyWindow.SUMMON_WAIT_MS == 20000
