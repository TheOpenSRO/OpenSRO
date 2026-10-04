extends SceneTree

## Round 711 (lane C1): the client's party codecs and party state against the
## shared golden fixtures (client/scripts/net/fixtures/party/, written by
## round 710 straight from docs/protocol/party_protocol.md, independently of
## either codec). Every party message the client sends is encoded byte for
## byte; every one it receives is decoded, checked field by field, and
## encoded back to the same bytes. Then PartyState is driven through the
## flows (form, join, leave, kick, dissolve, leader change, the invitation
## rules) on those same payloads.
##
##   godot4 --headless --path client --script res://scripts/net/party_test.gd

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

# --- Client -> server --------------------------------------------------------

func _test_senders() -> void:
	_same(PartyNet.encode_create(201, 0x03), "7060_create_exp_item")
	_same(PartyNet.encode_create(201, 0x07), "7060_create_all")
	_same(PartyNet.encode_create(201, 0x00), "7060_create_ffa")
	_same(PartyNet.encode_leave(), "7061_leave")
	_same(PartyNet.encode_invite(301), "7062_invite")
	_same(PartyNet.encode_kick(201), "7063_kick")
	_same(PartyNet.encode_answer(PartyNet.REQUEST_FORM, true), "3080_answer_yes")
	_same(PartyNet.encode_answer(PartyNet.REQUEST_JOIN, true), "3080_answer_yes")
	_same(PartyNet.encode_answer(PartyNet.REQUEST_FORM, false), "3080_answer_no_form")
	_same(PartyNet.encode_answer(PartyNet.REQUEST_JOIN, false), "3080_answer_no_join")
	# The settings block's type byte (c:0x81c7f0..0x81c82e).
	var st := PartyState.new()
	st.set_preferences(1, 1, 1)
	_check(st.flags_byte() == 0x07, "exp | item << 1 | anyone << 2 = 0x07")
	st.set_preferences(1, 0, 0)
	_check(st.flags_byte() == 0x01, "exp share alone = 0x01")
	st.set_preferences(0, 0, 0)
	_check(st.flags_byte() == 0x00 and st.cap() == 4, "free-for-all: 0x00, a 4-member party")
	# The decoders the server side mirrors.
	var c := PartyNet.decode_create(_fx("7060_create_all"))
	_check(c.size() == 2 and c[0] == 201 and c[1] == 7, "7060 decodes target 201, flags 7")
	_check(PartyNet.decode_u32_only(_fx("7063_kick")) == 201, "7063 decodes JID 201")
	var a := PartyNet.decode_answer(_fx("3080_answer_no_join"))
	_check(a != null and not a.accept and a.code == 0x2c17, "3080 no-to-join decodes 0x2c17")

# --- Server -> client --------------------------------------------------------

func _ack(name: String, ok: bool, jid: int, code: int) -> void:
	var a := PartyNet.decode_ack(_fx(name))
	_check(a != null and a.ok == ok and a.jid == jid and a.code == code,
		"%s: ok %s jid %d code 0x%x" % [name, ok, jid, code])
	_same(PartyNet.encode_ack_ok(jid) if ok else PartyNet.encode_ack_error(code), name)

func _test_acks() -> void:
	_ack("b060_ok", true, 101, 0)
	_ack("b060_err_too_far", false, 0, 4)
	_ack("b060_err_low_level", false, 0, 0x2c0a)
	_ack("b060_err_post_failed", false, 0, 2)
	_ack("b060_err_timeout", false, 0, 0x2c10)
	_ack("b062_err_full_exp", false, 0, 0x2c13)
	_ack("b062_err_full_ffa", false, 0, 0x2c14)
	_ack("b062_err_declined", false, 0, 0x2c17)
	_ack("b067_ok", true, 201, 0)
	_ack("b067_err_timeout", false, 0, 0x2c10)
	_ack("b067_err_mismatch", false, 0, 0x2c23)

func _aria_ok(m: PartyNet.Member, label: String) -> void:
	_check(m != null and m.mask == 0xff and m.jid == 101 and m.member_name == "Aria"
		and m.ref_obj_id == 1907 and m.level == 10 and m.hp_tenths == 10 and m.mp_tenths == 5
		and m.region == 0x61a8 and m.x == 1002 and m.y == 30 and m.z == 1020 and m.world_id == 1
		and m.guild == "" and m.job == 4 and m.mastery1 == 257 and m.mastery2 == 258,
		"%s: Aria's full record, every field" % label)

func _bram_ok(m: PartyNet.Member, label: String) -> void:
	_check(m != null and m.jid == 201 and m.member_name == "Bram" and m.ref_obj_id == 1908
		and m.level == 7 and m.hp_tenths == 10 and m.mp_tenths == 10 and m.x == 990 and m.y == 31
		and m.z == 1011 and m.guild == "Wolves" and m.job == 4 and m.mastery1 == 0 and m.mastery2 == 0,
		"%s: Bram's full record, every field" % label)

func _test_records() -> void:
	for name in ["record_full_aria", "record_full_bram", "record_full_dungeon"]:
		var r := PartyNet.Reader.new(_fx(name))
		var m := PartyNet.read_member(r)
		_check(m != null and r.done(), "%s reads to its last byte" % name)
		if m == null:
			continue
		var w := PartyNet.Writer.new()
		PartyNet.write_member(w, m)
		_same(w.data, name)
		if name == "record_full_aria":
			_aria_ok(m, name)
		elif name == "record_full_bram":
			_bram_ok(m, name)
		else:
			_check(m.region == 0x8001 and m.x == 70000 and m.y == -5 and m.z == 12,
				"the dungeon record's u32 coordinates (y = -5, signed)")

func _test_party_info() -> void:
	var p := PartyNet.decode_party_info(_fx("3065_two_members"))
	_check(p != null and p.mask == 0xff and p.party_id == 7 and p.leader_jid == 101
		and p.flags == 0x03 and p.members.size() == 2, "3065: party 7, leader 101, flags 3, two members")
	if p != null and p.members.size() == 2:
		_aria_ok(p.members[0], "3065 member 0")
		_bram_ok(p.members[1], "3065 member 1")
		_same(PartyNet.encode_party_info(p), "3065_two_members")
	var one := PartyNet.decode_party_info(_fx("3065_one_member"))
	_check(one != null and one.members.size() == 1, "3065 with the inviter alone")
	if one != null:
		_same(PartyNet.encode_party_info(one), "3065_one_member")

func _event(name: String) -> PartyNet.Event:
	var e := PartyNet.decode_event(_fx(name))
	_check(e != null, "%s decodes" % name)
	if e != null:
		_same(PartyNet.encode_event(e), name)
	return e

func _test_events() -> void:
	var e := _event("3864_k1_dissolved")
	_check(e != null and e.kind == 1 and e.code == 0x2c0b, "kind 1 carries 0x2c0b")
	e = _event("3864_k2_joined")
	_check(e != null and e.kind == 2 and e.member != null, "kind 2 carries a record")
	if e != null:
		_bram_ok(e.member, "kind 2")
	e = _event("3864_k3_logout")
	_check(e != null and e.kind == 3 and e.jid == 201 and e.reason == 1, "kind 3 logout: 201, reason 1")
	e = _event("3864_k3_left")
	_check(e != null and e.reason == 2, "kind 3 secede: reason 2")
	e = _event("3864_k3_kicked")
	_check(e != null and e.reason == 4, "kind 3 booted: reason 4")
	e = _event("3864_k6_hpmp")
	_check(e != null and e.kind == 6 and e.jid == 101 and e.member.mask == 0x04
		and e.member.hp_tenths == 11 and e.member.mp_tenths == 5, "kind 6 HP/MP byte 0x5b: HP nibble 11, MP 5")
	e = _event("3864_k6_level")
	_check(e != null and e.member.mask == 0x02 and e.member.level == 11, "kind 6 level 11")
	e = _event("3864_k6_position")
	_check(e != null and e.member.mask == 0x20 and e.member.region == 0x61a8 and e.member.x == 1100
		and e.member.y == 30 and e.member.z == 900 and e.member.world_id == 1, "kind 6 position")
	e = _event("3864_k6_position_dungeon")
	_check(e != null and e.member.region == 0x8001 and e.member.x == 70000 and e.member.y == -5,
		"kind 6 dungeon position, u32")
	e = _event("3864_k6_guild")
	_check(e != null and e.member.mask == 0x40 and e.member.guild == "Wolves", "kind 6 guild")
	e = _event("3864_k6_masteries")
	_check(e != null and e.member.mask == 0x08 and e.member.mastery1 == 257 and e.member.mastery2 == 259,
		"kind 6 masteries")
	e = _event("3864_k6_name_model")
	_check(e != null and e.member.mask == 0x01 and e.member.member_name == "Aria" and e.member.ref_obj_id == 1910,
		"kind 6 name and model")
	e = _event("3864_k6_hpmp_level")
	_check(e != null and e.member.mask == 0x06 and e.member.level == 11 and e.member.hp_tenths == 11
		and e.member.mp_tenths == 10, "kind 6 level then HP/MP in mask order")
	e = _event("3864_k9_leader")
	_check(e != null and e.kind == 9 and e.jid == 201, "kind 9: new leader 201")

func _test_invitations() -> void:
	var inv := PartyNet.decode_invitation(_fx("3080_invite_new"))
	_check(inv != null and inv.kind == 2 and inv.inviter_id == 101 and inv.flags == 3, "3080 kind 2 from 101, flags 3")
	_same(PartyNet.encode_invitation(inv.kind, inv.inviter_id, inv.flags), "3080_invite_new")
	inv = PartyNet.decode_invitation(_fx("3080_invite_existing"))
	_check(inv != null and inv.kind == 3 and inv.inviter_id == 101 and inv.flags == 7, "3080 kind 3 from 101, flags 7")
	_same(PartyNet.encode_invitation(inv.kind, inv.inviter_id, inv.flags), "3080_invite_existing")

# --- PartyState: the flows ---------------------------------------------------

func _test_state_form() -> void:
	var st := PartyState.new()
	var notices: Array = []
	st.notice.connect(func(k: String, a: String, c: int) -> void: notices.append([k, a, c]))
	# The inviter (Aria) is acked, then sees the party with herself alone,
	# then Bram joins.
	st.handle(PartyNet.OP_CREATE_ACK, _fx("b060_ok"))
	_check(st.own_jid == 101 and not st.in_party, "0xb060 OK gives the own JID, not yet a party")
	st.handle(PartyNet.OP_PARTY_INFO, _fx("3065_one_member"))
	_check(st.in_party and st.party_id == 7 and st.leader_jid == 101 and st.is_leader(), "3065: in party 7, leading")
	_check(st.exp_share == 1 and st.item_share == 1 and st.anyone_invite == 0, "the party's flags become the block")
	st.handle(PartyNet.OP_EVENT, _fx("3864_k2_joined"))
	_check(st.members.size() == 2 and st.members[1].member_name == "Bram", "kind 2 appends Bram")
	_check(notices.size() > 0 and notices[-1][0] == "UIIT_MSG_PARTY_JOIN" and notices[-1][1] == "Bram",
		"the join line names Bram (type 4)")
	_check(st.row_members().size() == 1 and st.row_members()[0].jid == 201, "the window's rows: Bram alone")
	_check(st.member_for_row(0) != null and st.member_for_row(0).jid == 201, "row 0's button acts on list index 1 (Bram)")
	_check(not st.is_full(), "2 of 8: not full")
	# Updates.
	st.handle(PartyNet.OP_EVENT, _fx("3864_k6_hpmp"))
	_check(st.member(101).hp_tenths == 11 and st.member(101).mp_tenths == 5 and st.member(101).level == 10,
		"kind 6 changes HP/MP only")
	st.handle(PartyNet.OP_EVENT, _fx("3864_k6_guild"))
	_check(st.member(101).guild == "Wolves", "kind 6 guild")
	# The leader leaves: kind 3 for Aria then kind 9 -- but Aria is us, so the
	# party is cleared on the kind 3.
	st.handle(PartyNet.OP_EVENT, _fx("3864_k9_leader"))
	_check(st.leader_jid == 201 and st.members[0].jid == 201 and not st.is_leader(), "kind 9: Bram leads, kept at index 0")

func _test_state_leave() -> void:
	var st := PartyState.new()
	var notices: Array = []
	st.notice.connect(func(k: String, a: String, c: int) -> void: notices.append([k, a, c]))
	st.own_jid = 101
	st.handle(PartyNet.OP_PARTY_INFO, _fx("3065_two_members"))
	st.handle(PartyNet.OP_EVENT, _fx("3864_k3_kicked"))
	_check(st.in_party and st.members.size() == 1, "kind 3 removes Bram")
	_check(notices[-1][0] == "UIIT_MSG_PARTY_BOOTED" and notices[-1][1] == "Bram", "booted line names Bram")
	st.handle(PartyNet.OP_PARTY_INFO, _fx("3065_two_members"))
	st.handle(PartyNet.OP_EVENT, _fx("3864_k3_logout"))
	_check(notices[-1][0] == "UIIT_MSG_PARTY_LOGOUT", "reason 1: the logout line")
	st.handle(PartyNet.OP_PARTY_INFO, _fx("3065_two_members"))
	st.handle(PartyNet.OP_EVENT, _fx("3864_k1_dissolved"))
	_check(not st.in_party and st.members.is_empty() and notices[-1][0] == "UIIT_MSG_PARTY_BROKEN",
		"kind 1 clears the party: PARTY_BROKEN")
	# Bram's own client: kind 3 with his own JID clears his party.
	var bram := PartyState.new()
	bram.own_jid = 201
	bram.handle(PartyNet.OP_PARTY_INFO, _fx("3065_two_members"))
	bram.handle(PartyNet.OP_EVENT, _fx("3864_k3_left"))
	_check(not bram.in_party, "kind 3 naming the player clears the player's party")
	_check(bram.exp_share == 1 and bram.item_share == 1, "the block keeps the last party's values (READ: the clear 0x998be0 leaves them)")

func _test_state_refusals() -> void:
	var st := PartyState.new()
	var notices: Array = []
	st.notice.connect(func(k: String, a: String, c: int) -> void: notices.append([k, a, c]))
	st.handle(PartyNet.OP_INVITE_ACK, _fx("b062_err_full_exp"))
	_check(notices[-1][0] == "UIIT_MSG_PARTYERR_MEMBER_FULL_EXP_SHARED_PARTY" and notices[-1][2] == 0x2c13,
		"0xb062 0x2c13: the exp-shared full message, as an error")
	st.handle(PartyNet.OP_CREATE_ACK, _fx("b060_err_too_far"))
	_check(notices[-1][0] == "UIIT_STT_ERR_COMMON_TOO_FAR" and notices[-1][2] == 4,
		"code 4: the client's 'too far' (category 2, c:0x7bb7cc)")
	st.handle(PartyNet.OP_CREATE_ACK, _fx("b060_err_post_failed"))
	_check(notices[-1][0] == "UIIT_MSG_PARTYERR_UNKNOWN_ERROR", "code 2: UNKNOWN_ERROR")
	var before := notices.size()
	st.handle(PartyNet.OP_JOIN_ACK, _fx("b067_err_timeout"))
	_check(notices.size() == before, "the invitee's 0xb067 0x2c10 shows no line (c:0x880120 returns first)")
	st.handle(PartyNet.OP_CREATE_ACK, _fx("b060_err_timeout"))
	_check(notices.size() == before + 1 and notices[-1][0] == "UIIT_MSG_PARTYERR_TIMEOUT", "the inviter's 0xb060 0x2c10 does")
	var fresh := PartyState.new()
	_check(fresh.exp_share == 1 and fresh.item_share == 0 and fresh.anyone_invite == 1,
		"the block starts exp 1, item 0, anyone 1 (c:0x99ba00)")
	# The client's HP decode (c:0x991f60 for kind 6; n over 10 for a full record).
	var hp := PartyState.new()
	hp.own_jid = 201
	hp.handle(PartyNet.OP_PARTY_INFO, _fx("3065_two_members"))
	var aria := hp.member(101)
	_check(aria.hp_cur == 10 and aria.hp_max == 10 and aria.mp_cur == 5 and aria.mp_max == 10, "a full record: HP 10/10, MP 5/10")
	hp.handle(PartyNet.OP_EVENT, _fx("3864_k6_hpmp"))
	_check(aria.hp_cur == 10 and aria.hp_max == 9 and not aria.dead and aria.hp_ratio() == 1.0,
		"kind 6 nibble 11: HP 10 over 9 (n - 1 over 9), drawn full")
	var ev := PartyNet.Event.new()
	ev.kind = PartyNet.EVENT_UPDATE
	ev.jid = 101
	ev.member = PartyNet.Member.new()
	ev.member.mask = PartyNet.MASK_HPMP
	ev.member.hp_tenths = 0
	ev.member.mp_tenths = 3
	hp.handle(PartyNet.OP_EVENT, PartyNet.encode_event(ev))
	_check(aria.dead and aria.hp_cur == 0 and aria.hp_ratio() == 0.0 and aria.mp_cur == 3, "kind 6 nibble 0: dead, HP 0")
	ev.member.hp_tenths = 6
	hp.handle(PartyNet.OP_EVENT, PartyNet.encode_event(ev))
	_check(not aria.dead and aria.hp_cur == 5 and aria.hp_max == 9, "kind 6 nibble 6: HP 5 over 9")

func _test_state_invitations() -> void:
	var st := PartyState.new()
	var shown: Array = []
	var closed := [0]
	var sent: Array = []
	st.invitation.connect(func(id: int, who: String, kind: int, f: int) -> void: shown.append([id, who, kind, f]))
	st.invitation_closed.connect(func() -> void: closed[0] += 1)
	st.send_answer.connect(func(p: PackedByteArray) -> void: sent.append(p))
	# Nobody spawned: dropped unanswered (c:0x88ae1c / 0x88ae2b).
	st.handle(PartyNet.OP_REQUEST, _fx("3080_invite_new"))
	_check(shown.is_empty() and sent.is_empty() and st.pending_kind == 0, "an inviter not spawned here is dropped silently")
	# Spawned: the box shows; Accept gives [1][1].
	st.is_spawned_player = func(id: int) -> bool: return id == 101
	st.player_name = func(id: int) -> String: return "Aria" if id == 101 else ""
	st.handle(PartyNet.OP_REQUEST, _fx("3080_invite_new"))
	_check(shown.size() == 1 and shown[0][1] == "Aria" and shown[0][2] == 2 and shown[0][3] == 3, "kind 2 from Aria shows the box")
	_check(st.answer(true) == _fx("3080_answer_yes"), "Accept answers [1][1]")
	_check(st.answer(true).is_empty(), "nothing to answer twice")
	st.handle(PartyNet.OP_REQUEST, _fx("3080_invite_existing"))
	_check(st.answer(false) == _fx("3080_answer_no_join"), "Refuse on a kind 3 answers [2][0x2c17]")
	st.handle(PartyNet.OP_REQUEST, _fx("3080_invite_new"))
	_check(st.answer(false) == _fx("3080_answer_no_form"), "Refuse on a kind 2 answers [2][0x2c0c]")
	# The server timed it out: 0xb067 [2][0x2c10] closes the box.
	st.handle(PartyNet.OP_REQUEST, _fx("3080_invite_new"))
	st.handle(PartyNet.OP_JOIN_ACK, _fx("b067_err_timeout"))
	_check(closed[0] == 1 and st.pending_kind == 0, "0xb067 0x2c10 closes the box")
	# The option off: auto-decline with the kind's code.
	st.accept_invitations = false
	st.handle(PartyNet.OP_REQUEST, _fx("3080_invite_existing"))
	_check(sent.size() == 1 and sent[0] == _fx("3080_answer_no_join"), "option off: kind 3 auto-declined [2][0x2c17]")
	# 0xb067 OK: the invitee's own JID.
	st.handle(PartyNet.OP_JOIN_ACK, _fx("b067_ok"))
	_check(st.own_jid == 201, "0xb067 OK gives the invitee's JID")

func _test_truncated() -> void:
	var full := _fx("3065_two_members")
	_check(PartyNet.decode_party_info(full.slice(0, full.size() - 1)) == null, "a short 3065 is refused")
	var ev := _fx("3864_k2_joined")
	_check(PartyNet.decode_event(ev.slice(0, 10)) == null, "a short kind 2 is refused")
	_check(PartyNet.decode_ack(PackedByteArray([2, 0x10])) == null, "a short error ack is refused")

func _initialize() -> void:
	_test_senders()
	_test_acks()
	_test_records()
	_test_party_info()
	_test_events()
	_test_invitations()
	_test_state_form()
	_test_state_leave()
	_test_state_refusals()
	_test_state_invitations()
	_test_truncated()
	if _failures == 0:
		print("party_test: all checks passed")
		quit(0)
	else:
		print("party_test: %d check(s) FAILED" % _failures)
		quit(1)
