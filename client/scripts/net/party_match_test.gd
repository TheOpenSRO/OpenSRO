extends SceneTree

## Round 714 (lane C2): the party-matching codecs and PartyMatchState against
## the shared golden fixtures (client/scripts/net/fixtures/party/, written by
## round 710 from docs/protocol/party_protocol.md, independently of either
## codec). Every matching message the client sends is encoded byte for byte;
## every one it receives is decoded field by field and, where the client has
## an encoder for the test side, encoded back to the same bytes. Then the
## state is driven through the page, registration, delete, join and auto-match
## flows on those payloads.
##
##   godot4 --headless --path client --script res://scripts/net/party_match_test.gd

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
	if f == null:
		_check(false, "fixture %s is readable" % name)
		return PackedByteArray()
	var out := PackedByteArray()
	for tok in f.get_as_text().split(" ", false):
		var t := tok.strip_edges()
		if t != "":
			out.append(t.hex_to_int())
	return out

func _same(got: PackedByteArray, name: String) -> void:
	var want := _fx(name)
	_check(got == want, "%s byte for byte (%s vs %s)" % [name, got.hex_encode(), want.hex_encode()])

func _entry(number: int, flags: int, purpose: int, lo: int, hi: int, title: String) -> PartyMatchNet.Entry:
	var e := PartyMatchNet.Entry.new()
	e.number = number
	e.flags = flags
	e.purpose = purpose
	e.min_level = lo
	e.max_level = hi
	e.title = title
	return e

# --- Client -> server --------------------------------------------------------

func _test_senders() -> void:
	_same(PartyMatchNet.encode_entry(_entry(0, 0x03, 0, 1, 110, "For open hunting")), "7069_register")
	_same(PartyMatchNet.encode_entry(_entry(12, 0x03, 1, 5, 20, "Quests")), "706a_change")
	_same(PartyMatchNet.encode_delete(12), "706b_delete")
	_same(PartyMatchNet.encode_page(0), "706c_page")
	_same(PartyMatchNet.encode_join(12), "706d_request")
	_same(PartyMatchNet.encode_answer(0x41, 201, PartyMatchNet.ANSWER_CONFIRM), "306e_confirm")
	_same(PartyMatchNet.encode_answer(0x41, 201, PartyMatchNet.ANSWER_CLOSED), "306e_closed")

# --- Server -> client --------------------------------------------------------

func _test_replies() -> void:
	var reg := PartyMatchNet.decode_entry_result(_fx("b069_ok"))
	_check(reg != null and reg.ok and reg.entry.number == 12 and reg.entry.party_id == 7 and reg.entry.flags == 0x03
		and reg.entry.purpose == 0 and reg.entry.min_level == 1 and reg.entry.max_level == 110
		and reg.entry.title == "For open hunting", "0xb069 [1] echoes the entry with its number 12 and party 7")
	var del := PartyMatchNet.decode_delete_result(_fx("b06b_ok"))
	_check(del != null and del.ok and del.number == 12, "0xb06b [1][12]")
	var p := PartyMatchNet.decode_page(_fx("b06c_page"))
	_check(p != null and p.ok and p.page_count == 3 and p.page_index == 0 and p.rows.size() == 2,
		"0xb06c: 3 pages, index 0, 2 rows")
	if p != null and p.rows.size() == 2:
		var a := p.rows[0]
		var b := p.rows[1]
		_check(a.number == 12 and a.time == 1759500000 and a.leader_name == "Aria" and a.race == 0 and a.members == 2
			and a.flags == 0x03 and a.purpose == 0 and a.min_level == 1 and a.max_level == 110 and a.title == "For open hunting",
			"row 1: entry 12 Aria CHN 2 members flags 3 hunting 1~110")
		_check(b.number == 15 and b.leader_name == "Bram" and b.race == 1 and b.members == 1 and b.flags == 0
			and b.purpose == 2 and b.min_level == 20 and b.max_level == 40 and b.title == "Traders",
			"row 2: entry 15 Bram EUR 1 member flags 0 trade 20~40")
		_check(a.cap() == 8 and b.cap() == 4, "the Member column's cap by bit 0: 2/8 and 1/4")
		_check(PartyMatchNet.shown_name(a) == "Aria" and PartyMatchNet.shown_name(b) == "*Bram",
			"a Trade / Thief party's name is drawn *%s")
		_same(PartyMatchNet.encode_page_ack(p), "b06c_page")
	var empty := PartyMatchNet.decode_page(_fx("b06c_empty"))
	_check(empty != null and empty.ok and empty.page_count == 0 and empty.rows.is_empty(), "0xb06c [1][0][0][0]")
	var q := PartyMatchNet.decode_join_request(_fx("706d_to_leader"))
	_check(q != null and q.job_id == 0x41 and q.requester_jid == 201 and q.entry == 12 and q.mastery1 == 257
		and q.mastery2 == 258 and q.job_state == 4, "S->C 0x706d: job 0x41, requester 201, entry 12, masteries 257/258, job 4")
	_check(q != null and q.member != null and q.member.member_name == "Bram" and q.member.level == 7
		and q.member.guild == "Wolves" and q.member.region == 0x61a8, "the requester's record: Bram, Lv 7, Wolves, region 25000")
	if q != null:
		_same(PartyMatchNet.encode_join_request(q), "706d_to_leader")
	for pair in [["b06d_joined", true, 1], ["b06d_refused", true, 0], ["b06d_noreply", true, 2]]:
		var r := PartyMatchNet.decode_join_result(_fx(pair[0]))
		_check(r != null and r.ok == pair[1] and r.outcome == pair[2], "%s -> outcome %d" % [pair[0], pair[2]])
	var err := PartyMatchNet.decode_join_result(_fx("b06d_err_level"))
	_check(err != null and not err.ok and err.code == 0x2c1e, "0xb06d [2][0x2c1e]")
	var short := _fx("b06c_page")
	_check(PartyMatchNet.decode_page(short.slice(0, short.size() - 2)) == null, "a short page is refused")
	_check(PartyMatchNet.decode_join_request(_fx("706d_to_leader").slice(0, 20)) == null, "a short join request is refused")

# --- Rules -------------------------------------------------------------------

func _row(number: int, leader: String, purpose: int, lo: int, hi: int, flags: int = 0, race: int = 0) -> PartyMatchNet.Row:
	var r := PartyMatchNet.Row.new()
	r.number = number
	r.leader_name = leader
	r.purpose = purpose
	r.min_level = lo
	r.max_level = hi
	r.flags = flags
	r.race = race
	return r

func _test_rules() -> void:
	var r := _row(5, "Tobi", 0, 10, 30)
	_check(PartyMatchNet.row_matches(r, "", 4, 1, 110), "All, no name, 1~110 lists it")
	_check(PartyMatchNet.row_matches(r, "Tobi", 0, 1, 110), "the exact name matches")
	_check(not PartyMatchNet.row_matches(r, "tobi", 4, 1, 110), "the name match is case-sensitive (0x47ec20)")
	_check(not PartyMatchNet.row_matches(r, "Tob", 4, 1, 110), "the name match is whole, not a prefix")
	_check(not PartyMatchNet.row_matches(r, "", 1, 1, 110), "another purpose is filtered out")
	_check(PartyMatchNet.row_matches(r, "", 4, 30, 50) and not PartyMatchNet.row_matches(r, "", 4, 31, 50),
		"the level ranges must overlap (30 touches 10~30, 31 does not)")
	_check(PartyMatchNet.allowed_purposes(1) == [2] and PartyMatchNet.allowed_purposes(3) == [2],
		"a trader or hunter may only list Trade")
	_check(PartyMatchNet.allowed_purposes(2) == [3], "a thief may only list Thief")
	_check(PartyMatchNet.allowed_purposes(4) == [0, 1], "no job: Hunting or Quest")
	var c := _row(9, "Eone", 0, 1, 100, 0x05, 1)
	_check(PartyMatchNet.auto_candidate(c, 0, 1, 0x05, 50), "auto: purpose, race, flags and level all fit")
	_check(PartyMatchNet.auto_candidate(c, 0, 2, 0x05, 50), "auto: race Open takes either race")
	_check(not PartyMatchNet.auto_candidate(c, 0, 0, 0x05, 50), "auto: a CHN choice skips a EUR party")
	_check(not PartyMatchNet.auto_candidate(c, 0, 2, 0x01, 50), "auto: the flags must be equal, anyone bit included")
	_check(not PartyMatchNet.auto_candidate(c, 0, 2, 0x05, 101), "auto: the player's level must be inside the range")

# --- State -------------------------------------------------------------------

func _state(key: String) -> Array:
	var st := PartyMatchState.new()
	var sent: Array = []
	st.send = func(op: int, payload: PackedByteArray) -> void: sent.append([op, payload])
	st.registration_key = func() -> String: return key
	return [st, sent]

func _page_of(rows: Array) -> PackedByteArray:
	var p := PartyMatchNet.Page.new()
	p.ok = true
	p.page_count = 1
	p.page_index = 0
	for r in rows:
		p.rows.append(r)
	return PartyMatchNet.encode_page_ack(p)

func _test_state_page() -> void:
	var made := _state("Aria")
	var st: PartyMatchState = made[0]
	var pages := [0]
	st.paged.connect(func() -> void: pages[0] += 1)
	st.handle(_fx("b06c_page"), PartyMatchNet.OP_PAGE_ACK)
	_check(st.registration != null and st.registration.number == 12, "row 0 named as the key is the player's own registration")
	_check(st.rows.size() == 1 and st.rows[0].number == 15, "the other rows are listed")
	_check(st.page_count == 3 and pages[0] == 1, "the page count is kept and the page signalled")
	# The server sends the own entry again in its numbered place (round 713).
	st.handle(_page_of([_row(12, "Aria", 0, 1, 110), _row(4, "Sonila", 0, 1, 100), _row(12, "Aria", 0, 1, 110)]), PartyMatchNet.OP_PAGE_ACK)
	_check(st.rows.size() == 1 and st.rows[0].leader_name == "Sonila", "the own entry's second copy is skipped")
	var other: PartyMatchState = _state("Zed")[0]
	other.handle(_fx("b06c_page"), PartyMatchNet.OP_PAGE_ACK)
	_check(other.registration == null and other.rows.size() == 2, "with another key both rows are records")
	var lines: Array = []
	other.notice.connect(func(k: String, c: int, t: int) -> void: lines.append([k, c, t]))
	other.handle(PackedByteArray([2, 0x1c, 0x2c]), PartyMatchNet.OP_PAGE_ACK)
	_check(lines.size() == 1 and lines[0][1] == 0x2c1c and lines[0][2] == 0, "a page error is a coded line (0x778190)")

func _test_state_registration() -> void:
	var made := _state("Aria")
	var st: PartyMatchState = made[0]
	var sent: Array = made[1]
	var done := [0]
	var banners: Array = []
	st.register_done.connect(func() -> void: done[0] += 1)
	st.banner.connect(func(k: String) -> void: banners.append(k))
	st.own_race = func() -> int: return 1
	st.party_size = func() -> int: return 3
	st.register(_entry(0, 0x03, 0, 1, 110, "For open hunting"))
	_check(sent.size() == 1 and sent[0][0] == 0x7069 and sent[0][1] == _fx("7069_register"), "Form party sends 0x7069")
	st.handle(_fx("b069_ok"), PartyMatchNet.OP_REGISTER_ACK)
	_check(st.registration != null and st.registration.number == 12 and st.registration.leader_name == "Aria",
		"0xb069 OK makes the registration (entry 12)")
	_check(st.registration.race == 1 and st.registration.members == 3 and st.registration.time == 0,
		"the echo's row takes the player's race and the party's count (0x97c530; review B3)")
	# A page with no rows clears the registration (0x97ddf0 -> 0x97c3b0; review B4).
	st.handle(_fx("b06c_empty"), PartyMatchNet.OP_PAGE_ACK)
	_check(st.registration == null and st.registration_entry == null, "an empty page unpins the registration")
	st.handle(_fx("b069_ok"), PartyMatchNet.OP_REGISTER_ACK)
	_check(done[0] == 2 and banners == ["UIIT_MSG_PARTYMATCH_RECORD_COMPLETE", "UIIT_MSG_PARTYMATCH_RECORD_COMPLETE"], "each echo signals and shows RECORD_COMPLETE")
	st.delete_entry(12)
	_check(sent.size() == 2 and sent[1][1] == _fx("706b_delete"), "Delete entry sends 0x706b")
	st.handle(_fx("b06b_ok"), PartyMatchNet.OP_DELETE_ACK)
	_check(st.registration == null and banners.back() == "UIIT_MSG_PARTYMATCH_DELETE_COMPLETE", "0xb06b with the own number clears it")
	st.delete_entry(12, true)
	st.handle(_fx("b06b_ok"), PartyMatchNet.OP_DELETE_ACK)
	_check(banners.back() == "UIIT_MSG_PARTYMATCH_DELETE_COMPLETE2", "a delete for a full party says DELETE_COMPLETE2")

## Round 718, the user's report: a leader lists, the party dissolves (the
## server drops the entry), someone else lists -- and the old entry stayed
## pinned beside the new one, undeletable ("doesn't exist") and immune to
## Refresh, because nothing cleared the client's own registration on a
## 0x3864 event. UI_PARTY::FUN_00886b10 clears it (0x97c960(0)).
func _test_state_party_events() -> void:
	var made := _state("Aria")
	var st: PartyMatchState = made[0]
	var removed: Array = []
	st.removed.connect(func(n: int) -> void: removed.append(n))
	st.handle(_fx("b069_ok"), PartyMatchNet.OP_REGISTER_ACK)
	_check(st.registration != null and st.registration.number == 12, "the leader's registration (entry 12)")
	# The party dissolves; the server dropped entry 12; Bram then lists entry 13.
	st.on_party_event(PartyNet.EVENT_DISSOLVED, false, false, 0)
	_check(st.registration == null and st.registration_entry == null and removed == [12],
		"kind 1 clears the registration and drops its number from the list (0x8871a7, 0x73a700)")
	st.handle(_page_of([_row(13, "Bram", 0, 1, 110)]), PartyMatchNet.OP_PAGE_ACK)
	_check(st.registration == null and st.rows.size() == 1 and st.rows[0].number == 13,
		"the next page shows only the new entry: no stale own row beside it")
	# Before the fix: the pinned entry survived a page whose row 0 is someone else's.
	var old: PartyMatchState = _state("Aria")[0]
	old.handle(_fx("b069_ok"), PartyMatchNet.OP_REGISTER_ACK)
	old.handle(_page_of([_row(13, "Bram", 0, 1, 110)]), PartyMatchNet.OP_PAGE_ACK)
	_check(old.registration != null and old.registration.number == 12,
		"(the bug's mechanism) without a party event a page of someone else's rows leaves the pin -- so the event must clear it")
	# Kind 3, the player left: cleared (0x886eaa).
	st.handle(_fx("b069_ok"), PartyMatchNet.OP_REGISTER_ACK)
	st.on_party_event(PartyNet.EVENT_LEFT, true, false, 0)
	_check(st.registration == null, "kind 3 naming the player clears it (0x886eaa)")
	# Kind 3, someone else left, the player still in a party: the count follows.
	st.handle(_fx("b069_ok"), PartyMatchNet.OP_REGISTER_ACK)
	st.on_party_event(PartyNet.EVENT_LEFT, false, true, 2)
	_check(st.registration != null and st.registration.members == 2, "another member leaving updates the count (0x986f50()+0x10)")
	st.on_party_event(PartyNet.EVENT_JOINED, false, true, 3)
	_check(st.registration != null and st.registration.members == 3, "a member joining updates the count")
	# Kind 3, someone else left and the player is out of a party: cleared (0x886f76).
	st.on_party_event(PartyNet.EVENT_LEFT, false, false, 0)
	_check(st.registration == null, "another member leaving with the player out of a party clears it (0x886f76)")
	# A leader change leaves the registration alone.
	st.handle(_fx("b069_ok"), PartyMatchNet.OP_REGISTER_ACK)
	st.on_party_event(PartyNet.EVENT_LEADER, false, true, 3)
	_check(st.registration != null, "kind 9 does not clear it")

func _test_party_state_signals_events() -> void:
	var ps := PartyState.new()
	var seen: Array = []
	ps.party_event.connect(func(k: int, j: int) -> void: seen.append([k, j]))
	var e := PartyNet.Event.new()
	e.kind = PartyNet.EVENT_DISSOLVED
	ps._on_event(e)
	_check(seen == [[PartyNet.EVENT_DISSOLVED, 0]] and not ps.in_party, "PartyState signals kind 1 after applying it")

func _test_state_join() -> void:
	var made := _state("Bram")
	var st: PartyMatchState = made[0]
	var sent: Array = made[1]
	var lines: Array = []
	var banners: Array = []
	var finished := [0]
	st.notice.connect(func(k: String, c: int, t: int) -> void: lines.append([k, c, t]))
	st.banner.connect(func(k: String) -> void: banners.append(k))
	st.join_finished.connect(func() -> void: finished[0] += 1)
	st.join(12)
	_check(sent.size() == 1 and sent[0][1] == _fx("706d_request") and st.joining, "Join party sends 0x706d [12]")
	st.handle(_fx("b06d_noreply"), PartyMatchNet.OP_JOIN_ACK)
	_check(not st.joining and lines.back() == ["UIIT_MSG_PARTYMATCH_JOIN_NOREPLY", 0, 4] and finished[0] == 1,
		"no reply: JOIN_NOREPLY, type 4, and the progress window closes")
	st.handle(_fx("b06d_refused"), PartyMatchNet.OP_JOIN_ACK)
	_check(lines.back() == ["UIIT_MSG_PARTYERR_CREATE_PARTY_REFUSED", 0, 4], "refused: CREATE_PARTY_REFUSED")
	st.handle(_fx("b06d_err_level"), PartyMatchNet.OP_JOIN_ACK)
	_check(lines.back() == ["UIIT_MSG_PARTYMATCH_JOIN_ERROR_LEVEL", 0x2c1e, 0], "0x2c1e: JOIN_ERROR_LEVEL as a coded line")
	st.handle(_fx("b06d_joined"), PartyMatchNet.OP_JOIN_ACK)
	_check(banners.back() == "UIIT_MSG_PARTYMATCH_JOIN_COMPLETE_MASTER", "joined: the banner")
	var reqs: Array = []
	st.join_request.connect(func(q: PartyMatchNet.JoinRequest) -> void: reqs.append(q))
	st.handle(_fx("706d_to_leader"), PartyMatchNet.OP_JOIN)
	_check(reqs.size() == 1 and reqs[0].requester_jid == 201, "S->C 0x706d raises the leader's popup")
	st.answer(reqs[0], PartyMatchNet.ANSWER_CLOSED)
	_check(sent.back()[0] == 0x306e and sent.back()[1] == _fx("306e_closed"), "the answer echoes the job id and the requester")

func _test_unknown_result() -> void:
	_check(PartyMatchNet.decode_page(PackedByteArray([3, 0, 0, 0])) == null, "a page with result 3 is ignored (review M1)")
	_check(PartyMatchNet.decode_join_result(PackedByteArray([0, 1, 0])) == null, "a join result 0 is ignored")
	_check(PartyMatchNet.decode_delete_result(PackedByteArray([7, 0, 0, 0, 0])) == null, "a delete result 7 is ignored")

func _test_state_auto() -> void:
	var made := _state("Bram")
	var st: PartyMatchState = made[0]
	var sent: Array = made[1]
	var lines: Array = []
	st.notice.connect(func(k: String, c: int, t: int) -> void: lines.append(k))
	var picks: Array[int] = []
	for i in 12:
		picks.append(100 + i)
	_check(st.start_auto(picks) and st.auto_queue.size() == 9, "auto match queues 10 and sends the first")
	_check(sent.size() == 1 and sent[0][1] == PartyMatchNet.encode_join(100), "the first candidate is asked")
	st.handle(_fx("b06d_refused"), PartyMatchNet.OP_JOIN_ACK)
	_check(sent.size() == 2 and sent[1][1] == PartyMatchNet.encode_join(101) and lines.back() == "UIIT_MSG_PARTYMATCH_AUTO_PROGRESS",
		"a refusal moves on to the next candidate (AUTO_PROGRESS)")
	st.handle(_fx("b06d_joined"), PartyMatchNet.OP_JOIN_ACK)
	_check(not st.auto_running and st.auto_queue.is_empty(), "a join ends the run")
	var empty: Array[int] = []
	_check(not st.start_auto(empty), "no candidate, no run")
	var one: Array[int] = [7]
	st.start_auto(one)
	st.handle(_fx("b06d_noreply"), PartyMatchNet.OP_JOIN_ACK)
	_check(not st.auto_running and lines.back() == "UIIT_MSG_PARTYMATCH_AUTO_FAILURE", "a run that runs out says the auto-match failure line")

func _initialize() -> void:
	_test_senders()
	_test_replies()
	_test_rules()
	_test_state_page()
	_test_state_registration()
	_test_state_join()
	_test_state_auto()
	_test_unknown_result()
	_test_state_party_events()
	_test_party_state_signals_events()
	if _failures == 0:
		print("party_match_test: all checks passed")
		quit(0)
	else:
		print("party_match_test: %d check(s) FAILED" % _failures)
		quit(1)
