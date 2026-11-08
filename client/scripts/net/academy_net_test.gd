extends SceneTree

## Round 865: AcademyNet against the academy's wire (docs/protocol/
## academy.md sections 4-7). The fixtures in res://scripts/net/fixtures/
## academy/ are MEASURED messages with the characters' names swapped for test
## names of the same length; server/internal/academy/wire.go writes the same
## bytes. No game data.
##   godot4 --headless --path client --script res://scripts/net/academy_net_test.gd

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

func _init() -> void:
	_requests()
	_camp()
	_pushes()
	_results()
	_lists()
	_buffs()
	_grades()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _requests() -> void:
	_check(AcademyNet.encode_npc(0x2001) == _fx("7470_open"), "0x7470: u32 NPC")
	_check(AcademyNet.encode_invite(0x1002) == _fx("7472_invite"), "0x7472: u32 target")
	_check(AcademyNet.encode_name("Novice001") == _fx("7473_ban"), "0x7473: str name")
	_check(AcademyNet.encode_notice("Hello Academy", "Test notice line") == _fx("7477_notice"), "0x7477: str title, str content")
	_check(AcademyNet.encode_match(0, 0x65, 1, "Join us") == _fx("747a_register"), "0x747A: u32, u32 camp, u8 flags, str title")
	_check(AcademyNet.encode_entry(1) == _fx("747c_delete"), "0x747C: u32 entry")
	_check(AcademyNet.encode_page(0) == _fx("747d_page"), "0x747D: u8 page")
	_check(AcademyNet.encode_answer(true) == _fx("3080_yes"), "0x3080 yes: 01 01")
	_check(AcademyNet.encode_answer(false) == PackedByteArray([2, 0, 0]), "0x3080 no: 02 00 00")
	_check(AcademyNet.encode_graduate(3) == PackedByteArray([3]), "0x7475: u8 evaluation")
	_check(AcademyNet.encode_empty().is_empty(), "0x7471 / 0x7474 / 0x7483: empty")

func _camp() -> void:
	# 0xB470 {01, CampInfo}: the founder alone, offline (1), its job alias as
	# the display name.
	var b470 := _fx("b470_founded")
	var c := AcademyNet.decode_camp(b470, 1)
	_check(c != null, "B470's camp decodes")
	if c == null:
		return
	_check(c.camp_id == 0x65 and c.rank == 5 and c.notice_title == "" and c.notice_content == "", "camp id, rank 5, no notice")
	_check(c.creation_date == [2026, 1, 1, 0, 0, 0, 0], "CreationDate minute-rounded (got %s)" % [c.creation_date])
	_check(c.members.size() == 1, "one member")
	var g: AcademyNet.Member = c.members[0]
	_check(g.char_id == 0x101 and g.ref_obj_id == 0x700 and g.name == "Guardian1", "member key, body, name")
	_check(g.member_class == 0 and g.joined_level == 70 and g.cur_level == 70 and g.max_level == 70 and g.honor == 0,
		"class 0, levels 70 / 70 / 70, honor 0")
	_check(g.play_state == 1 and g.world_id == 0x10001 and g.region == 0x61a8, "play state 1, world 0x00010001, region 25000")
	_check(g.x == 100 and g.y == 0 and g.z == 100 and g.display_name == "Trader7", "x, y, z, display name")
	_check(g.grade == 7, "guardian at 70 is grade 7")
	# Round trip: the encoder writes the same bytes.
	_check(AcademyNet.encode_camp(c) == b470.slice(1), "CampInfo round trip")
	# 0x3C81 with a notice and two members, the second's display name empty.
	var w := AcademyNet.decode_camp(_fx("3c81_world"))
	_check(w != null and w.notice_title == "Hello Academy" and w.notice_content == "Test notice line", "0x3C81 notice")
	_check(w != null and w.members.size() == 2 and (w.members[1] as AcademyNet.Member).name == "Novice001"
		and (w.members[1] as AcademyNet.Member).member_class == 2 and (w.members[1] as AcademyNet.Member).display_name == "",
		"0x3C81 apprentice, display name empty")
	_check(AcademyNet.decode_camp(_fx("3c81_world").slice(0, 40)) == null, "a short camp is dropped")

func _pushes() -> void:
	var p := AcademyNet.decode_push(_fx("3c80_05_online"))
	_check(p.sub == 5 and p.char_id == 0x101 and p.field == 1 and p.value == 0 and not p.bad, "05 key 01 00: online")
	p = AcademyNet.decode_push(_fx("3c80_05_offline"))
	_check(p.field == 1 and p.value == 1, "05 .. 01 01: offline")
	p = AcademyNet.decode_push(_fx("3c80_02_joined"))
	_check(p.sub == 2 and p.member != null and p.member.name == "Novice001" and p.member.member_class == 2
		and p.member.play_state == 1 and p.member.world_id == 0 and p.member.display_name == "",
		"02: the joiner for the others -- play state 1, no location (MEASURED)")
	p = AcademyNet.decode_push(_fx("3c80_0a_joined"))
	_check(p.sub == 0x0a and p.ok and p.camp != null and p.camp.members.size() == 2, "0a 01 + CampInfo")
	var own: AcademyNet.Member = p.camp.members[1]
	_check(own.play_state == 1 and own.region == 0x61a8 and own.display_name == "Novice001", "the joiner's own copy: 1, its place")
	p = AcademyNet.decode_push(_fx("3c80_0a_timeout"))
	_check(p.sub == 0x0a and not p.ok and p.code == 0x000e, "0a 02 0e 00: the timeout")
	p = AcademyNet.decode_push(_fx("3c80_0d_pos"))
	_check(p.sub == 0x0d and p.char_id == 0x102 and p.display_name == "Novice001" and p.world_id == 0x10001
		and p.region == 0x61a8 and p.x == 100 and p.y == 0 and p.z == 100, "0d: key, name, world, region, x, y, z")
	p = AcademyNet.decode_push(_fx("3c80_07_notice"))
	_check(p.sub == 7 and p.title == "Hello Academy" and p.content == "Test notice line", "07: title, content")
	p = AcademyNet.decode_push(PackedByteArray([3, 0x02, 0x01, 0, 0, 2]))
	_check(p.sub == 3 and p.char_id == 0x102 and p.reason == 2, "03: key, reason")
	p = AcademyNet.decode_push(PackedByteArray([4, 0x02, 0x01, 0, 0, 1]))
	_check(p.sub == 4 and p.kind == 1, "04: key, kind")
	p = AcademyNet.decode_push(PackedByteArray([5, 0x02, 0x01, 0, 0, 3, 0x10, 0, 0, 0]))
	_check(p.field == 3 and p.value == 16, "05 field 3: u32 honor")
	p = AcademyNet.decode_push(PackedByteArray([5, 0x02, 0x01, 0, 0, 7, 0x74, 7, 0, 0]))
	_check(p.field == 7 and p.value == 0x774, "05 field 7: u32 model")
	p = AcademyNet.decode_push(PackedByteArray([5, 0x02, 0x01, 0, 0, 5, 2, 0, 0x41, 0x42]))
	_check(p.field == 5 and not p.bad, "05 field 5: the client reads nothing after it (c:0x6e9674)")
	p = AcademyNet.decode_push(PackedByteArray([0x0c, 3]))
	_check(p.sub == 0x0c and p.rank == 3, "0c: rank")
	p = AcademyNet.decode_push(PackedByteArray([0x0d, 0x02, 0x01]))
	_check(p.bad, "a short 0d is marked bad")
	_check(AcademyNet.decode_invitation(_fx("3080_invite")) == [0x1001, "Guardian1"], "3080 kind 9: uid, name")
	_check(AcademyNet.decode_invitation(PackedByteArray([5, 1, 0, 0, 0])).is_empty(), "3080 kind 5 is not the academy's")

func _results() -> void:
	var r := AcademyNet.decode_result(AcademyNet.OP_DISBAND_RESULT, _fx("b471_7d"))
	_check(r != null and not r.ok and r.code == 0x681d and r.seconds == 603589, "B471 02 1d68 + u32 seconds")
	r = AcademyNet.decode_result(AcademyNet.OP_BAN_RESULT, _fx("b473_leave_24h"))
	_check(r.code == 0x6821, "B473 02 2168: leave's refusal on ban's channel")
	r = AcademyNet.decode_result(AcademyNet.OP_INVITE_RESULT, _fx("b472_timeout"))
	_check(r.code == 0x000e and AcademyNet.error_key(r.code) == "", "B472 0e00: no text")
	r = AcademyNet.decode_result(AcademyNet.OP_OPEN_RESULT, PackedByteArray([2, 0x1c, 0x68, 1, 0, 0, 0]))
	_check(r.code == 0x681c and r.seconds == 1, "B470 0x681c + u32")
	_check(AcademyNet.decode_result(AcademyNet.OP_LEAVE_RESULT, PackedByteArray([3, 0, 0])) == null, "result byte 3 is dropped")
	_check(AcademyNet.decode_result(AcademyNet.OP_NOTICE_RESULT, _fx("b477_ok")).ok, "B477 01")
	_check(AcademyNet.error_key(3) == "UIIT_STT_ERR_COMMON_INVALID_TARGET" and AcademyNet.error_key(0x6816) == "UIIT_MSG_TC_ERROR_ORDER_WORK"
		and AcademyNet.error_key(0x6808) == "" and AcademyNet.error_key(0x6827) == "" and AcademyNet.error_key(0x682b) == "",
		"category 0x1d's rows")

func _lists() -> void:
	_check(AcademyNet.decode_honor_rows(_fx("b478_empty")).is_empty(), "B478 01 00: no rows")
	var b := PackedByteArray([1, 1, 1, 0, 0, 0, 4, 3, 0, 0x41, 0x42, 0x43, 70, 71, 5, 0, 0, 0, 0, 0])
	var rows := AcademyNet.decode_honor_rows(b)
	_check(rows.size() == 1 and (rows[0] as AcademyNet.HonorRow).guardian == "ABC" and (rows[0] as AcademyNet.HonorRow).max_level == 71
		and (rows[0] as AcademyNet.HonorRow).graduates == 5 and (rows[0] as AcademyNet.HonorRow).guild == "", "HonorRow")
	var page := AcademyNet.decode_match_page(_fx("b47d_empty"))
	_check(page.has("rows") and (page["rows"] as Array).is_empty(), "B47D 01 00 00 00: an empty page")
	var e := AcademyNet.decode_match_entry(AcademyNet.OP_MATCH_REGISTER_RESULT, _fx("b47a_ok"))
	_check(e.get("entry_id") == 1 and e.get("camp_id") == 0x65 and e.get("flags") == 1 and e.get("title") == "Join us" and e.get("tail") == 0,
		"B47A: entry, camp, flags, title, u32")

func _buffs() -> void:
	var d := AcademyNet.decode_own_buff(PackedByteArray([7, 60, 0, 0, 0, 9, 0, 0, 0]))
	_check(d.get("sub") == 7 and d.get("minutes") == 60 and d.get("points") == 9, "3C82 7: minutes, points")
	_check(AcademyNet.decode_own_buff(PackedByteArray([5])).get("sub") == 5, "3C82 5: nothing after")
	var l := AcademyNet.decode_buff_list(PackedByteArray([0, 1, 30, 0, 0, 0, 0x02, 0x01, 0, 0, 4, 0, 0, 0]))
	_check((l["rows"] as Array).size() == 1 and (l["rows"][0] as Dictionary)["donor"] == 0x102, "B483 0: n x {minutes, donor, points}")
	_check(AcademyNet.decode_buff_list(PackedByteArray([2])).get("sub") == 2, "B483 2: the guardian offline")

func _grades() -> void:
	var want := {[2, 1]: 1, [2, 10]: 1, [2, 11]: 2, [2, 20]: 2, [2, 21]: 3, [2, 30]: 3, [2, 31]: 4, [2, 39]: 4,
		[1, 40]: 5, [1, 49]: 5, [1, 50]: 6, [0, 60]: 7, [0, 110]: 7}
	var ok := true
	for k in want:
		if AcademyNet.grade_of(int(k[0]), int(k[1]), 0) != int(want[k]):
			ok = false
			print("  grade_of(%s) = %d, want %d" % [k, AcademyNet.grade_of(int(k[0]), int(k[1]), 0), want[k]])
	_check(ok, "the grade rule c:0x98e120")
	_check(AcademyNet.grade_of(1, 39, 9) == 9 and AcademyNet.grade_of(2, 0, 9) == 9 and AcademyNet.grade_of(0, 59, 9) == 9,
		"no rule keeps the old grade")
