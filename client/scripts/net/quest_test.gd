extends SceneTree

## Round 785: the quest messages (QuestNet) against golden bytes in the
## layout of server/internal/quest/wire.go, and the client's quest log
## (QuestState) fed by them.
##
##   godot4 --headless --path client --script res://scripts/net/quest_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _hex(b: PackedByteArray) -> String:
	return " ".join(Array(b).map(func(x): return "%02x" % x))

func _view(status: int, count: int, open: bool) -> QuestNet.View:
	var v := QuestNet.View.new()
	v.counter = 0x10
	v.state = 1
	v.status = status
	var m := QuestNet.Mission.new()
	m.index = 0
	m.open = open
	m.text = "SN_CON_X"
	m.values = PackedInt64Array([count])
	v.missions = [m]
	v.npcs = PackedInt64Array([1234])
	return v

## The golden 0x30D5 add: kind 1, quest 5, counter 0x10, state 1, flags 0x58,
## status 1, one mission (index 0, open, "SN_CON_X", one value 3), one NPC
## 1234.
const GOLDEN_ADD := "01 05 00 00 00 10 01 58 01 01 00 01 08 00 53 4e 5f 43 4f 4e 5f 58 01 03 00 00 00 01 d2 04 00 00"

func _test_update() -> void:
	var b := QuestNet.encode_update(QuestNet.UPDATE_ADD, 5, _view(1, 3, true))
	_check(_hex(b) == GOLDEN_ADD, "0x30d5 add encodes as wire.go writes it (got %s)" % _hex(b))
	var u := QuestNet.decode_update(b)
	_check(u.error == "" and u.kind == 1 and u.quest_id == 5, "0x30d5 header decodes")
	_check(u.view != null and u.view.status == 1 and u.view.counter == 0x10 and u.view.flags == 0x58, "the body's bytes")
	var m := u.view.missions[0] as QuestNet.Mission
	_check(m.open and m.text == "SN_CON_X" and Array(m.values) == [3], "the mission line")
	_check(Array(u.view.npcs) == [1234], "the NPC list")
	var rm := QuestNet.decode_update(QuestNet.encode_update(QuestNet.UPDATE_DROPPED, 7))
	_check(rm.error == "" and rm.kind == 4 and rm.quest_id == 7 and rm.view == null, "a removal has no body")
	_check(QuestNet.decode_update(b.slice(0, b.size() - 2)).error != "", "a truncated body is an error")
	# The time-limit flag (4): a u32 before the status; -1 is none.
	var t := PackedByteArray([2, 9, 0, 0, 0, 0, 1, 0x0c, 0xff, 0xff, 0xff, 0xff, 2])
	var tu := QuestNet.decode_update(t)
	_check(tu.error == "" and tu.view.time_limit == -1 and tu.view.status == 2, "flags 4|8: time limit then status")

func _test_log() -> void:
	var b := PackedByteArray([2, 0])
	b.append_array(QuestNet._u32(3))
	b.append_array(QuestNet._u32(4))
	b.append(1)
	b.append_array(QuestNet._u32(5))
	b.append_array(QuestNet.encode_view(_view(2, 14, false)))
	b.append(0)
	var l := QuestNet.decode_log(b)
	_check(l.error == "" and Array(l.completed) == [3, 4] and l.active.size() == 1, "the log section")
	_check(int(l.active[0][0]) == 5 and (l.active[0][1] as QuestNet.View).status == 2, "the log's active quest")

func _test_talk_and_misc() -> void:
	var page := QuestNet.encode_talk_page(QuestNet.PAGE_LIST, "SN_NPC_A_QS", PackedStringArray(["SN_QNO_A", "SN_QNO_B"]))
	_check(_hex(page) == "04 0b 00 53 4e 5f 4e 50 43 5f 41 5f 51 53 02 08 00 53 4e 5f 51 4e 4f 5f 41 08 00 53 4e 5f 51 4e 4f 5f 42", "0x30d4 list page bytes")
	var p := QuestNet.decode_talk_page(page)
	_check(p.error == "" and p.type == 4 and p.text == "SN_NPC_A_QS" and Array(p.lines) == ["SN_QNO_A", "SN_QNO_B"], "0x30d4 list decodes")
	var yn := QuestNet.decode_talk_page(QuestNet.encode_talk_page(QuestNet.PAGE_YES_NO, "SN_TALK_Q_01"))
	_check(yn.type == 3 and yn.text == "SN_TALK_Q_01" and yn.lines.is_empty(), "0x30d4 yes/no has no lines")
	_check(_hex(QuestNet.encode_talk_answer(6)) == "06", "0x70d4 {u8 response}")
	_check(_hex(QuestNet.encode_take_reward(5)) == "05 00 00 00 00", "0x7515 with nothing chosen")
	_check(_hex(QuestNet.encode_take_reward(5, [9])) == "05 00 00 00 01 09 00 00 00", "0x7515 with one item chosen")
	_check(_hex(QuestNet.encode_quest_id(0x102)) == "02 01 00 00", "0x70d8 / 0x70d9 {u32 quest}")
	var rw := QuestNet.decode_reward_window(PackedByteArray([5, 0, 0, 0, 0, 2, 0, 0x41, 0x42]))
	_check(int(rw.get("quest_id", -1)) == 5 and str(rw.get("text", "")) == "AB", "0x3514 decodes")
	_check(bool(QuestNet.decode_take_reward_result(PackedByteArray([1]))["ok"]), "0xb515 ok")
	_check(int(QuestNet.decode_take_reward_result(PackedByteArray([2, 2]))["error"]) == 2, "0xb515 error 2")
	_check(int(QuestNet.decode_id_result(PackedByteArray([1, 5, 0, 0, 0]), false)["quest_id"]) == 5, "0xb0d9 ok names the quest")
	_check(int(QuestNet.decode_id_result(PackedByteArray([2, 4]), false)["error"]) == 4, "0xb0d9 refusal u8")
	_check(int(QuestNet.decode_id_result(PackedByteArray([2, 0x34, 0x12]), true)["error"]) == 0x1234, "0xb0d8 refusal u16")
	var mk := PackedByteArray()
	mk.append_array(QuestNet._u32(77))
	mk.append_array(PackedByteArray([0, 3, 0x61, 0xa8]))
	var f := PackedByteArray()
	f.resize(12)
	f.encode_float(0, 1.5)
	f.encode_float(4, 2.0)
	f.encode_float(8, -3.0)
	mk.append_array(f)
	var m := QuestNet.decode_mark(mk)
	_check(m != null and m.object_id == 77 and m.mark_type == 3 and m.region == 0xa861 and m.position == Vector3(1.5, 2.0, -3.0), "0x30d6 decodes")
	_check(QuestNet.decode_unmark(QuestNet._u32(77)) == 77, "0x30d7 decodes")
	_check(QuestNet.format_objective("Hunt 14 Weasel (%d)", PackedInt64Array([3])) == "Hunt 14 Weasel (3)", "an objective text takes its count")
	_check(QuestNet.format_objective("Talk to him", PackedInt64Array([1])) == "Talk to him", "a text with no %d is unchanged")

func _test_state() -> void:
	var s := QuestState.new()
	var sent: Array = []
	s.send = func(op: int, payload: PackedByteArray) -> void: sent.append([op, _hex(payload)])
	var got := {"progress": [], "updates": 0, "bag": 0}
	s.mission_progress.connect(func(id: int, m: QuestNet.Mission) -> void: got["progress"].append([id, Array(m.values), m.open]))
	s.quest_updated.connect(func(_u) -> void: got["updates"] += 1)
	s.bag_may_have_changed.connect(func() -> void: got["bag"] += 1)
	s.handle(QuestNet.encode_update(QuestNet.UPDATE_ADD, 5, _view(1, 0, true)), QuestNet.OP_UPDATE)
	_check(s.active.has(5) and s.entries().size() == 1 and got["bag"] == 1, "an add enters the log and asks for the bag")
	s.handle(QuestNet.encode_update(QuestNet.UPDATE_CHANGE, 5, _view(1, 1, true)), QuestNet.OP_UPDATE)
	_check(got["progress"] == [[5, [1], true]], "a count change is a progress notice (got %s)" % [got["progress"]])
	s.handle(QuestNet.encode_update(QuestNet.UPDATE_CHANGE, 5, _view(1, 1, true)), QuestNet.OP_UPDATE)
	_check((got["progress"] as Array).size() == 1, "the same count is no notice")
	s.handle(QuestNet.encode_update(QuestNet.UPDATE_CHANGE, 5, _view(2, 14, false)), QuestNet.OP_UPDATE)
	_check((got["progress"] as Array).size() == 2 and s.view_of(5).status == 2, "a mission finishing is a notice")
	s.set_tracked(5)
	_check(Array(s.tracked_npcs()) == [1234], "the tracked quest's NPCs")
	s.handle(QuestNet.encode_update(QuestNet.UPDATE_DROPPED, 5), QuestNet.OP_UPDATE)
	_check(not s.active.has(5) and s.completed.has(5) and s.tracked == 0, "a completion leaves the log for the finished list")
	s.answer(6)
	s.take_reward(5)
	s.abandon(5)
	s.claim(5)
	_check(sent == [[0x70d4, "06"], [0x7515, "05 00 00 00 00"], [0x70d9, "05 00 00 00"], [0x70d8, "05 00 00 00"]], "the requests (got %s)" % [sent])
	var pages: Array = []
	s.talk_page.connect(func(p: QuestNet.TalkPage) -> void: pages.append(p.text))
	s.handle(QuestNet.encode_talk_page(QuestNet.PAGE_CONFIRM, "SN_TALK_Q_02"), QuestNet.OP_TALK_PAGE)
	_check(pages == ["SN_TALK_Q_02"], "a talk page is passed on")
	# Round 819: 0x30EC, a u16-length key (s:0x4ed4a0 -> FUN_00426040).
	var notices: Array = []
	s.event_message.connect(func(key: String) -> void: notices.append(key))
	var b := PackedByteArray([18, 0])
	b.append_array("SN_TALK_COMMON_END".to_ascii_buffer())
	s.handle(b, QuestNet.OP_EVENT_MESSAGE)
	s.handle(PackedByteArray([40, 0, 65]), QuestNet.OP_EVENT_MESSAGE)
	_check(notices == [QuestNet.NOTICE_END], "a quest notice is passed on, a short one dropped (got %s)" % [notices])
	_check(QuestNet.OP_EVENT_MESSAGE in QuestNet.SERVER_OPCODES, "0x30EC is registered")

func _init() -> void:
	_test_update()
	_test_log()
	_test_talk_and_misc()
	_test_state()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
