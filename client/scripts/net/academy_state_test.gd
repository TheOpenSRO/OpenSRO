extends SceneTree

## Round 865: AcademyState -- what every academy message does to the store
## and which lines, banners and refusals it raises, against the client's
## handlers (c:0x8a2110, c:0x6e8ed0, c:0x899630..0x899940; docs/protocol/
## academy.md sections 6 and 7). Driven with the MEASURED fixtures (names
## swapped for test names) and built pushes. No game data.
##   godot4 --headless --path client --script res://scripts/net/academy_state_test.gd

const FIX := "res://scripts/net/fixtures/academy/"

var _failures := 0
var lines: Array = []
var banners: Array = []
var refusals: Array = []
var opened := [0]
var cleared := [0]
var invites: Array = []
var me := "Novice001"

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

func _state() -> AcademyState:
	var st := AcademyState.new()
	st.own_name = func() -> String: return me
	st.line.connect(func(k: String, a: Array) -> void: lines.append([k, a]))
	st.banner.connect(func(k: String, a: Array) -> void: banners.append([k, a]))
	st.refused.connect(func(c: int) -> void: refusals.append(c))
	st.window_wanted.connect(func() -> void: opened[0] += 1)
	st.store_cleared.connect(func() -> void: cleared[0] += 1)
	st.invitation.connect(func(u: int, n: String) -> void: invites.append([u, n]))
	return st

func _init() -> void:
	_founding()
	_invitation_and_join()
	_fields()
	_removals()
	_graduation()
	_disband_and_rank()
	_replies()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## The founding as MEASURED: 0xB470 {01, camp} then 05 field 1 = 0.
func _founding() -> void:
	me = "Guardian1"
	var st := _state()
	lines.clear()
	st.handle(AcademyNet.OP_OPEN_RESULT, _fx("b470_founded"))
	_check(st.in_academy() and st.am_guardian() and st.members.size() == 1, "B470 01: the camp, the player its guardian")
	_check(lines.size() == 1 and lines[0][0] == "UIIT_MSG_TC_OPEN_SUCCESS", "B470 01: An Academy has been established.")
	lines.clear()
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_05_online"))
	_check(st.guardian().online(), "05 01 00: the guardian online")
	_check(lines.is_empty(), "the player's own log-on with no notice title says nothing (c:0x6e9223)")
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_07_notice"))
	_check(st.camp.notice_title == "Hello Academy" and banners[-1][0] == "UIIT_MSG_TC_COMMON_KNOW_REMIND_UPDATE", "07: the notice and its banner")
	lines.clear()
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_05_online"))
	_check(lines.size() == 1 and lines[0] == ["UIIT_STT_TC_COMMON_KNOW", ["Hello Academy"]], "own log-on with a title: Academy Notice “%s”")
	refusals.clear()
	st.handle(AcademyNet.OP_OPEN_RESULT, PackedByteArray([2, 0x0a, 0x68]))
	_check(refusals == [0x680a], "B470 02: category 0x1d")

## The invitation and the join, both sides.
func _invitation_and_join() -> void:
	# The invitee.
	me = "Novice001"
	var st := _state()
	invites.clear()
	_check(st.handle(AcademyNet.OP_REQUEST, _fx("3080_invite")), "3080 kind 9 is the academy's")
	_check(invites == [[0x1001, "Guardian1"]] and st.pending_inviter == 0x1001, "the Join request box")
	_check(st.answer(true) == PackedByteArray([1, 1]) and st.answer(true).is_empty(), "Yes answers 01 01, once")
	_check(not st.handle(AcademyNet.OP_REQUEST, PackedByteArray([5, 1, 0, 0, 0])), "3080 kind 5 is not the academy's")
	opened[0] = 0
	banners.clear()
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_0a_joined"))
	_check(st.in_academy() and not st.am_guardian() and st.members.size() == 2, "0a 01: the camp")
	_check(opened[0] == 1 and banners[-1][0] == "UIIT_STT_TC_JOIN_ANNOUNCE", "0a 01: the window opens, Joined Academy.")
	_check(st.own_member() != null and st.own_member().char_id == 0x102, "the own record by name")
	# The timeout: the code has no text; the box keeps its own timer.
	var st2 := _state()
	st2.handle(AcademyNet.OP_REQUEST, _fx("3080_invite"))
	refusals.clear()
	st2.handle(AcademyNet.OP_PUSH, _fx("3c80_0a_timeout"))
	_check(refusals == [0x000e] and AcademyNet.error_key(0x000e) == "" and not st2.in_academy(), "0a 02 0e00: no text, no camp")
	# The guardian's side: 02 adds the joiner, then 0d and 05.
	me = "Guardian1"
	var g := _state()
	g.handle(AcademyNet.OP_OPEN_RESULT, _fx("b470_founded"))
	g.invite_pending = true
	lines.clear()
	g.handle(AcademyNet.OP_PUSH, _fx("3c80_02_joined"))
	_check(g.members.size() == 2 and not g.invite_pending, "02: the member added, +0x509 cleared")
	_check(lines == [["UIIT_MSG_TC_MACHING_JOINING_MEMBER", ["Novice001"]]], "02: [%s] has been added to the Academy.")
	g.handle(AcademyNet.OP_PUSH, _fx("3c80_0d_pos"))
	var n := g.member(0x102)
	_check(n.world_id == 0x10001 and n.region == 0x61a8 and n.display_name == "Novice001", "0d: the location group")
	lines.clear()
	g.handle(AcademyNet.OP_PUSH, _fx("3c80_05_offline").slice(0, 6) + PackedByteArray([0]))
	_check(lines == [["UIIT_MSG_TC_CONNECT2", ["UIIT_STT_TC_STUDENT", "Novice001"]]], "05 01 00 for an offline member: the log-on line")
	lines.clear()
	g.handle(AcademyNet.OP_PUSH, _fx("3c80_05_offline").slice(0, 6) + PackedByteArray([0]))
	_check(lines.is_empty(), "a member already online is not announced again (+0x540)")
	g.handle(AcademyNet.OP_PUSH, _fx("3c80_05_offline"))
	_check(lines == [["UIIT_MSG_TC_DISCONNECT2", ["UIIT_STT_TC_STUDENT", "Novice001"]]], "05 01 01: logged out")
	# The assistant (class 1).
	g.handle(AcademyNet.OP_PUSH, _fx("3c80_02_joined_asst"))
	lines.clear()
	g.handle(AcademyNet.OP_PUSH, PackedByteArray([5, 0x03, 0x01, 0, 0, 1, 0]))
	_check(lines == [["UIIT_MSG_TC_CONNECT2", ["UIIT_STT_TC_ASSISTANT_GUARDIAN", "Assist40"]]], "Asst. guardian [%s] has logged on")
	_check(g.of_class(1).size() == 1 and g.of_class(2).size() == 1, "the classes")

func _fields() -> void:
	me = "Guardian1"
	var st := _state()
	st.handle(AcademyNet.OP_OPEN_RESULT, _fx("b470_founded"))
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_02_joined"))
	var m := st.member(0x102)
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([5, 0x02, 0x01, 0, 0, 6, 15]))
	_check(m.cur_level == 15 and m.grade == 1, "field 6: current level, no grade change")
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([5, 0x02, 0x01, 0, 0, 2, 15]))
	_check(m.max_level == 15 and m.grade == 2, "field 2: max level, the grade recomputed")
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([5, 0x02, 0x01, 0, 0, 3, 0x2c, 1, 0, 0]))
	_check(m.honor == 300, "field 3: honor")
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([5, 0x02, 0x01, 0, 0, 7, 0x74, 7, 0, 0]))
	_check(m.ref_obj_id == 0x774, "field 7: the model")
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([5, 0x99, 0, 0, 0, 6, 9]))
	_check(m.cur_level == 15, "an unknown key changes nothing")

func _removals() -> void:
	me = "Guardian1"
	var st := _state()
	st.handle(AcademyNet.OP_OPEN_RESULT, _fx("b470_founded"))
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_02_joined"))
	lines.clear()
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([3, 0x02, 0x01, 0, 0, 2]))
	_check(st.members.size() == 1 and lines == [["UIIT_MSG_TC_EXPULSION_RESULT", ["Novice001"]]], "03 reason 2 for another: banned line, removed")
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_02_joined"))
	lines.clear()
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([3, 0x02, 0x01, 0, 0, 1]))
	_check(st.members.size() == 1 and lines == [["UIIT_STT_TC_OUT_TRAININGCAMP_OTHER_USER", ["Novice001"]]], "03 reason 1: left line")
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_02_joined"))
	lines.clear()
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([3, 0x02, 0x01, 0, 0, 3]))
	_check(st.members.size() == 1 and lines.is_empty(), "03 reason 3: removed silently")
	# The member itself.
	me = "Novice001"
	var s2 := _state()
	s2.handle(AcademyNet.OP_PUSH, _fx("3c80_0a_joined"))
	cleared[0] = 0
	banners.clear()
	s2.handle(AcademyNet.OP_PUSH, PackedByteArray([3, 0x02, 0x01, 0, 0, 1]))
	_check(not s2.in_academy() and cleared[0] == 1 and banners[-1][0] == "UIIT_STT_TC_OUT_TRAININGCAMP_ANNOUNCE", "03 reason 1 for me: cleared, banner")
	s2.handle(AcademyNet.OP_PUSH, _fx("3c80_0a_joined"))
	s2.handle(AcademyNet.OP_PUSH, PackedByteArray([3, 0x02, 0x01, 0, 0, 2]))
	_check(not s2.in_academy() and banners[-1][0] == "UIIT_MSG_TC_EXPULSION_RESULT_ANNOUNCE", "03 reason 2 for me: You have been banned")

func _graduation() -> void:
	me = "Guardian1"
	var st := _state()
	st.handle(AcademyNet.OP_OPEN_RESULT, _fx("b470_founded"))
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_02_joined"))
	lines.clear()
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([4, 0x02, 0x01, 0, 0, 1]))
	_check(st.members.size() == 1 and lines == [["UIIT_STT_TC_GRADUATION_ANNOUNCE", ["Novice001"]]], "04 kind 1 for another: graduated line")
	st.handle(AcademyNet.OP_PUSH, _fx("3c80_02_joined"))
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([4, 0x02, 0x01, 0, 0, 2]))
	_check(st.members.size() == 2, "04 kind 2: nothing")
	me = "Novice001"
	var s2 := _state()
	s2.handle(AcademyNet.OP_PUSH, _fx("3c80_0a_joined"))
	s2.handle(AcademyNet.OP_PUSH, PackedByteArray([4, 0x02, 0x01, 0, 0, 0]))
	_check(not s2.in_academy() and banners[-1][0] == "UIIT_STT_TC_GRADUATION_CONGRATULATIONS", "04 for me: congratulations, cleared")

func _disband_and_rank() -> void:
	me = "Guardian1"
	var st := _state()
	st.handle(AcademyNet.OP_OPEN_RESULT, _fx("b470_founded"))
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([0x0c, 2]))
	_check(st.camp.rank == 2, "0c: the rank")
	cleared[0] = 0
	st.handle(AcademyNet.OP_PUSH, PackedByteArray([1]))
	_check(not st.in_academy() and cleared[0] == 1 and banners[-1][0] == "UIIT_STT_TC_DISSOLUTION_SUCCESS", "01: disbanded, cleared")
	st.handle(AcademyNet.OP_CAMP, _fx("3c81_world"))
	_check(st.in_academy() and st.members.size() == 2 and st.camp.notice_content == "Test notice line", "3C81: the whole camp again")

func _replies() -> void:
	me = "Guardian1"
	var st := _state()
	refusals.clear()
	for f in ["b473_ban_24h", "b473_leave_24h"]:
		st.handle(AcademyNet.OP_BAN_RESULT, _fx(f))
	st.handle(AcademyNet.OP_DISBAND_RESULT, _fx("b471_7d"))
	st.invite_pending = true
	st.handle(AcademyNet.OP_INVITE_RESULT, _fx("b472_invalid"))
	_check(refusals == [0x6820, 0x6821, 0x681d, 3] and not st.invite_pending, "refusals in order; B472 clears +0x509")
	banners.clear()
	st.handle(AcademyNet.OP_NOTICE_RESULT, _fx("b477_ok"))
	_check(banners == [["UIIT_MSG_TC_COMMON_KNOW_REMIND_UPDATE", []]], "B477 01: the notice banner")
	var rows: Array = []
	st.honor_rows.connect(func(r: Array) -> void: rows.append(r))
	st.handle(AcademyNet.OP_HONOR_RANK_RESULT, _fx("b478_empty"))
	_check(rows.size() == 1 and (rows[0] as Array).is_empty(), "B478 01 00: the ranking opens empty")
	var replies: Array = []
	st.match_reply.connect(func(op: int, ok: bool, body: Dictionary) -> void: replies.append([op, ok, body]))
	st.handle(AcademyNet.OP_MATCH_REGISTER_RESULT, _fx("b47a_ok"))
	st.handle(AcademyNet.OP_MATCH_DELETE_RESULT, _fx("b47c_ok"))
	_check(replies.size() == 2 and replies[0][1] and (replies[0][2] as Dictionary)["entry_id"] == 1 and (replies[1][2] as Dictionary)["entry_id"] == 1,
		"B47A / B47C reach the matching window")
