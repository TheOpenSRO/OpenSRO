extends SceneTree

## Round 822: GuildOpsNet / GuildOpsState against the original's layouts
## (c:0x8852c0, 0x881950, 0x881890, 0x88aeb7; server/internal/guild/
## wire.go writes the same bytes). No game data.
## `godot4 --headless --path client --script res://scripts/net/guild_ops_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	# Requests.
	_check(GuildOpsNet.encode_create(0x01020304, "Ab") == PackedByteArray([4, 3, 2, 1, 2, 0, 0x41, 0x62]), "0x70F0: u32 NPC, str name")
	_check(GuildOpsNet.encode_npc(9) == PackedByteArray([9, 0, 0, 0]), "0x70F1 / 0x70F2: u32 NPC")
	_check(GuildOpsNet.encode_expel("bo") == PackedByteArray([2, 0, 0x62, 0x6f]), "0x70F4: str name")
	_check(GuildOpsNet.encode_answer(true) == PackedByteArray([1, 1]), "yes: 01 01")
	_check(GuildOpsNet.encode_answer(false) == PackedByteArray([2, 0x16, 0x4c]), "no: 02 16 4C")
	_check(GuildOpsNet.penalty_parts(259200) == [3, 0, 0] and GuildOpsNet.penalty_parts(90061) == [1, 1, 1], "penalty days/hours/minutes")
	_check(GuildOpsNet.error_key(0x4c3d) == "UIIT_MSG_GUILD_PENALTY" and GuildOpsNet.error_key(0x4c10) == "", "category 0x10 rows; 0x4c10 has none")

	var st := GuildOpsState.new()
	var notices: Array = []
	var created: Array = []
	var invites: Array = []
	var closed := [0]
	st.notice.connect(func(k: String, a: Array, c: int) -> void: notices.append([k, a, c]))
	st.created.connect(func(b: PackedByteArray) -> void: created.append(b))
	st.invitation.connect(func(u: int, w: String, g: String) -> void: invites.append([u, w, g]))
	st.invitation_closed.connect(func() -> void: closed[0] += 1)
	st.player_name = func(uid: int) -> String: return {77: "Aria", 78: "Loner"}.get(uid, "")
	st.player_guild = func(uid: int) -> String: return {77: "Verizon"}.get(uid, "")

	# B0F0 success hands on the block; the penalty refusal carries seconds.
	st.handle(GuildOpsNet.OP_CREATE_RESULT, PackedByteArray([1, 7, 0, 0, 0]))
	_check(created.size() == 1 and created[0] == PackedByteArray([7, 0, 0, 0]), "B0F0 {1, block}")
	var pen := PackedByteArray([2, 0x3c, 0x4c, 0, 0, 0, 0])
	pen.encode_u32(3, 90061)
	st.handle(GuildOpsNet.OP_CREATE_RESULT, pen)
	_check(notices[-1][0] == "UIIT_MSG_GUILD_SECESSION_PENALTY" and notices[-1][1] == [1, 1, 1], "B0F0 0x4c3c: the penalty line")
	st.handle(GuildOpsNet.OP_CREATE_RESULT, PackedByteArray([2, 0x1a, 0x4c]))
	_check(notices[-1][0] == "UIIT_MSG_GUILDERR_SAME_GUILDNAME_EXIST", "B0F0 other code: category 0x10")
	# A result byte other than 1 or 2 is dropped (== 2 tests).
	var n := notices.size()
	st.handle(GuildOpsNet.OP_DISBAND_RESULT, PackedByteArray([3, 0x1e, 0x4c]))
	_check(notices.size() == n, "result byte 3 is ignored")
	# B0F3: a refusal clears the lock, then the text.
	st.invite_lock = true
	st.handle(GuildOpsNet.OP_INVITE_RESULT, PackedByteArray([2, 0x3d, 0x4c]))
	_check(not st.invite_lock and notices[-1][0] == "UIIT_MSG_GUILD_PENALTY", "B0F3 refusal: lock cleared, penalty text")
	st.invite_lock = true
	st.handle(GuildOpsNet.OP_INVITE_RESULT, PackedByteArray([1]))
	_check(st.invite_lock, "B0F3 success leaves the lock")

	# 0x3080 kind 5: a spawned player with a guild opens the box.
	_check(not st.handle(GuildOpsNet.OP_REQUEST, PackedByteArray([2, 77, 0, 0, 0, 1])), "0x3080 kind 2 is not the guild's")
	st.handle(GuildOpsNet.OP_REQUEST, PackedByteArray([5, 78, 0, 0, 0]))
	_check(invites.is_empty() and st.pending_inviter == 0, "an inviter without a guild line is dropped")
	st.handle(GuildOpsNet.OP_REQUEST, PackedByteArray([5, 77, 0, 0, 0]))
	_check(invites.size() == 1 and invites[0] == [77, "Aria", "Verizon"] and st.pending_inviter == 77, "kind 5 opens box 0x0F")
	_check(st.answer(false) == PackedByteArray([2, 0x16, 0x4c]) and st.pending_inviter == 0, "the answer, once")
	_check(st.answer(true).is_empty(), "no box, no answer")
	# B0F8 0x4c10 closes the box without a line; another code shows its text.
	st.handle(GuildOpsNet.OP_REQUEST, PackedByteArray([5, 77, 0, 0, 0]))
	n = notices.size()
	st.handle(GuildOpsNet.OP_JOIN_RESULT, PackedByteArray([2, 0x10, 0x4c]))
	_check(closed[0] == 1 and st.pending_inviter == 0 and notices.size() == n, "B0F8 0x4c10: box closed, no text")
	st.handle(GuildOpsNet.OP_JOIN_RESULT, PackedByteArray([2, 0x16, 0x4c]))
	_check(notices[-1][0] == "UIIT_MSG_GUILDERR_JOIN_GUILD_REFUSED", "B0F8 refused: its text")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
