extends RefCounted
class_name GuildOpsState

## Round 822: the client's side of the guild membership requests -- the
## replies B0F0..B0F4 and B0F8, and 0x3080 kind 5, the invitation box 0x0F
## -- as sro_client.exe handles them (GuildOpsNet has the layouts; READ
## unless a line says otherwise). NetClient routes the messages here; World3D
## and HudPanels draw what the signals say.

## A line for the system message window: a text key and its values. A refusal
## goes through the error path 0x778190(0x10, code): key "" for a code that
## category 0x10 has no text for (nothing is shown).
signal notice(key: String, args: Array, code: int)
## A line for a centre banner as well ("notice" = GDR_NOTICE, 0x777bf0).
signal banner(where: String, key: String, args: Array)
## 0x3080 kind 5 for a spawned player with a guild line: box 0x0F.
signal invitation(inviter_uid: int, inviter_name: String, guild_name: String)
## B0F8's 0x4c10 closes box 0x0F (c:0x881890 -> 0x6ec7f0(0xf)).
signal invitation_closed
## B0F0's success: the guild block that follows it (FUN_009965e0).
signal created(block: PackedByteArray)
## Any reply, for the talk box's refresh and the QA log.
signal result(op: int, ok: bool, code: int)

## The inviter whose box is open (0 when none).
var pending_inviter := 0
## GInterface+0x509, the "request outstanding" lock the invite sender sets
## (c:0x81fc2c) and a refused B0F3 clears (c:0x777bd0(0)). What else reads
## it was not traced (OPEN); it is kept for the QA log only.
var invite_lock := false

## uid -> the player's name, "" when no player with that uid is spawned.
var player_name: Callable
## uid -> the player's guild name from its plate record, "" for none
## (entity+0x7c4, FUN_009db0f0).
var player_guild: Callable

func handle(op: int, data: PackedByteArray) -> bool:
	if op == GuildOpsNet.OP_REQUEST:
		var inviter := GuildOpsNet.invitation_inviter(data)
		if inviter < 0:
			return false
		_on_invitation(inviter)
		return true
	if not GuildOpsNet.RESULT_OPCODES.has(op):
		return false
	var r := GuildOpsNet.decode_result(op, data)
	if r == null:
		return true
	match op:
		GuildOpsNet.OP_CREATE_RESULT:
			if r.ok:
				created.emit(r.block)
			elif r.code == GuildOpsNet.CODE_CREATE_PENALTY:
				# c:0x8852c0 intercepts 0x4c3c: SECESSION_PENALTY with the
				# days, hours and minutes left.
				notice.emit("UIIT_MSG_GUILD_SECESSION_PENALTY", GuildOpsNet.penalty_parts(r.seconds), r.code)
			else:
				_refused(r.code)
		GuildOpsNet.OP_INVITE_RESULT:
			if not r.ok:
				invite_lock = false
				_refused(r.code)
		GuildOpsNet.OP_JOIN_RESULT:
			if not r.ok:
				if r.code == GuildOpsNet.CODE_INVITE_TIMEOUT:
					# No text: the open box 0x0F is closed.
					_close_invitation()
				else:
					_close_invitation()
					_refused(r.code)
		_:
			# B0F1 / B0F2 / B0F4: the success shows nothing (the NPC page's
			# refresh); a refusal goes through category 0x10.
			if not r.ok:
				_refused(r.code)
	result.emit(op, r.ok, r.code)
	return true

func _refused(code: int) -> void:
	notice.emit(GuildOpsNet.error_key(code), [], code)

## c:0x88aeb7: the inviter must be a spawned player with a guild record, or
## the message is dropped unanswered (the server's 30 s wait then answers).
func _on_invitation(inviter: int) -> void:
	var who: String = String(player_name.call(inviter)) if player_name.is_valid() else ""
	var gname: String = String(player_guild.call(inviter)) if player_guild.is_valid() else ""
	if who == "" or gname == "":
		print("GuildOps: invitation from %d dropped (no spawned player with a guild)" % inviter)
		return
	pending_inviter = inviter
	invitation.emit(inviter, who, gname)

func _close_invitation() -> void:
	if pending_inviter != 0:
		pending_inviter = 0
		invitation_closed.emit()

## The box's answer: the 0x3080 payload to send, empty with no box open.
func answer(accept: bool) -> PackedByteArray:
	if pending_inviter == 0:
		return PackedByteArray()
	pending_inviter = 0
	return GuildOpsNet.encode_answer(accept)

## The box's own timer closed it (0x644650): forget it, unanswered.
func forget_invitation() -> void:
	pending_inviter = 0

func reset_connection() -> void:
	pending_inviter = 0
	invite_lock = false
