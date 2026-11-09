extends RefCounted
class_name AcademyState

## Round 865: the client's academy store -- the camp record and up to eight
## members keyed by CharID -- and what each academy message does to it, as
## sro_client.exe's handlers do (CharacterDependentData at 0xeeebd8, the camp
## at +0x268, the member map at camp+0x70; academy.md sections 4-7 and 13).
## READ unless a line says otherwise. NetClient routes every AcademyNet
## message here; World3D (AcademyFlow) and the HUD draw what the signals say.
##
## How each line reaches the screen (READ, c:0x8a2110 and the reply handlers):
## - `line`: the system message window, type 0 (0x778210 / 0x7781b0 with 0);
## - `banner`: GDR_WARNING_WND (ginterface id 0x23), the blue centre banner
##   (0x77b580 -> 0x7b3eb0);
## - `refused`: the error dispatcher, category 0x1d (0x778190(0x1d, code));
##   a code with no row prints nothing (AcademyNet.error_key).

## The store changed: every academy window redraws (the client's refresh
## 0x798d00 -> 0x6a1eb0 and the matching window's 0x76f7b0).
signal changed
## A system line: a text key and its values (%s in order).
signal line(key: String, args: Array)
## A GDR_WARNING_WND banner.
signal banner(key: String, args: Array)
## A refusal through category 0x1d.
signal refused(code: int)
## 0x3C80 0a 01: the academy window opens (c:0x79af70, the L key's path).
signal window_wanted
## The store was cleared (disbanded, left, banned, graduated): the academy's
## windows close (the judge window, the notice writer in academy mode).
signal store_cleared
## 0x3080 kind 9: the "Join request sent" box (c:0x88aba8).
signal invitation(inviter_uid: int, inviter_name: String)
## 0x3C80 0a 02 / 0xB472: the box the invitation opened closes.
signal invitation_closed
## 0xB478 success: the honor ranking opens with these rows (c:0x79d180(1)).
signal honor_rows(rows: Array)
## Round 866: a board join request put to this guardian (0x747E down;
## AcademyNet.decode_join_ask's keys).
signal join_asked(ask: Dictionary)
## The matching board's replies (MentorMatch): op, ok, the decoded body.
signal match_reply(op: int, ok: bool, body: Dictionary)
## A buff message (academy.md 7.11): op and its decoded fields.
signal buff_message(op: int, body: Dictionary)
## Any reply, for the QA log.
signal result(op: int, ok: bool, code: int)
## A member's location group changed (0x3C80 0d, or a whole camp): the map
## marks follow.
signal positions_changed

var camp: AcademyNet.Camp = null
## CharID -> AcademyNet.Member.
var members := {}
## The order members arrived in (wire order, then joins): the slot fill
## order (assistants from SLOT_0, apprentices from SLOT_2, in join order).
var order: Array = []
## GInterface+0x509 (c:0x777bd0): set by Invite's send, cleared by a
## refused 0xB472 and by a member joining (READ c:0x8a2409, edi 0).
var invite_pending := false
## The inviter whose box is open (0 when none).
var pending_inviter := 0
## The guardian's log-on line is said once (CIFApprenticeShip +0x560,
## cleared when the guardian goes offline; c:0x6e92fd).
var guardian_announced := false
## The own cumulated buff's points (store +0x300, c:0x987160).
var own_buff_points := 0

## The player's own character name (the "is it me" compare, c:0x4e9530).
var own_name: Callable

func _me() -> String:
	return String(own_name.call()) if own_name.is_valid() else ""

## c:0x987140: the camp record's +0x20 valid flag.
func in_academy() -> bool:
	return camp != null

func member(char_id: int) -> AcademyNet.Member:
	return members.get(char_id) as AcademyNet.Member

## The member record whose name is the player's own, or null.
func own_member() -> AcademyNet.Member:
	var me := _me()
	for id in order:
		var m: AcademyNet.Member = members[id]
		if m.name == me:
			return m
	return null

## c:0x989d20: is the player the camp's guardian (by name).
func am_guardian() -> bool:
	var g := guardian()
	return g != null and g.name == _me() and _me() != ""

func guardian() -> AcademyNet.Member:
	for id in order:
		var m: AcademyNet.Member = members[id]
		if m.member_class == AcademyNet.CLASS_GUARDIAN:
			return m
	return null

## The members of a class in join order (the slot fill, c:0x6e9b00).
func of_class(member_class: int) -> Array:
	var out: Array = []
	for id in order:
		var m: AcademyNet.Member = members[id]
		if m.member_class == member_class:
			out.append(m)
	return out

## c:0x993040(class): is that role full (2 assistants, 5 apprentices).
func role_full(member_class: int) -> bool:
	if member_class == AcademyNet.CLASS_ASSISTANT:
		return of_class(member_class).size() >= 2
	if member_class == AcademyNet.CLASS_APPRENTICE:
		return of_class(member_class).size() >= 5
	return false

func clear() -> void:
	camp = null
	members.clear()
	order.clear()
	guardian_announced = false

func _fill(c: AcademyNet.Camp) -> void:
	clear()
	camp = c
	for m in c.members:
		_add(m)
	positions_changed.emit()

func _add(m: AcademyNet.Member) -> void:
	if not members.has(m.char_id):
		order.append(m.char_id)
	members[m.char_id] = m

func _remove(char_id: int) -> void:
	members.erase(char_id)
	order.erase(char_id)
	positions_changed.emit()

# --- The messages ----------------------------------------------------------------

func handle(op: int, data: PackedByteArray) -> bool:
	match op:
		AcademyNet.OP_REQUEST:
			var inv := AcademyNet.decode_invitation(data)
			if inv.is_empty():
				return false
			pending_inviter = int(inv[0])
			invitation.emit(int(inv[0]), String(inv[1]))
			return true
		AcademyNet.OP_MATCH_JOIN:
			# Round 866: 0x747E down (c:0x890fa0) -- the guardian's question
			# box, CMessageBoxManager kind 0xe (AcademyFlow opens it).
			var ask := AcademyNet.decode_join_ask(data)
			if not ask.is_empty():
				join_asked.emit(ask)
			return true
		AcademyNet.OP_CAMP:
			# 0x3C81 (c:0x8986c0): clear, read, refresh.
			var c := AcademyNet.decode_camp(data)
			if c != null:
				_fill(c)
				changed.emit()
			return true
		AcademyNet.OP_PUSH:
			_on_push(data)
			return true
		AcademyNet.OP_HONOR_RANK_RESULT:
			var r := AcademyNet.decode_result(op, data)
			if r == null:
				return true
			if r.ok:
				honor_rows.emit(AcademyNet.decode_honor_rows(data))
			else:
				refused.emit(r.code)
			result.emit(op, r.ok, r.code)
			return true
		AcademyNet.OP_MATCH_REGISTER_RESULT, AcademyNet.OP_MATCH_MODIFY_RESULT, \
				AcademyNet.OP_MATCH_DELETE_RESULT, AcademyNet.OP_MATCH_PAGE_RESULT, \
				AcademyNet.OP_MATCH_JOIN_RESULT:
			var r := AcademyNet.decode_result(op, data)
			if r == null:
				return true
			if not r.ok:
				refused.emit(r.code)
				match_reply.emit(op, false, {"code": r.code})
			else:
				match_reply.emit(op, true, _match_body(op, data))
			result.emit(op, r.ok, r.code)
			return true
		AcademyNet.OP_OWN_BUFF:
			var d := AcademyNet.decode_own_buff(data)
			if not d.is_empty():
				var sub := int(d["sub"])
				if sub in [0, 1, 7]:
					own_buff_points = int(d["points"])
				elif sub in [5, 8, 9]:
					own_buff_points = 0
				buff_message.emit(op, d)
			return true
		AcademyNet.OP_OWN_BUFF_MINUTES:
			if data.size() >= 4:
				buff_message.emit(op, {"minutes": data.decode_u32(0)})
			return true
		AcademyNet.OP_RESERVE_BUFF_MINUTES:
			if data.size() >= 8:
				buff_message.emit(op, {"minutes": data.decode_u32(0), "donor": data.decode_u32(4)})
			return true
		AcademyNet.OP_BUFF_LIST:
			var d := AcademyNet.decode_buff_list(data)
			if not d.is_empty():
				buff_message.emit(op, d)
			return true
	if not AcademyNet.SERVER_OPCODES.has(op):
		return false
	var r := AcademyNet.decode_result(op, data)
	if r == null:
		return true
	match op:
		AcademyNet.OP_OPEN_RESULT:
			# c:0x899630: the camp, a refresh, the hint hidden (0x777a00(1)),
			# UIIT_MSG_TC_OPEN_SUCCESS.
			if r.ok:
				var c := AcademyNet.decode_camp(data, 1)
				if c != null:
					_fill(c)
					changed.emit()
				line.emit("UIIT_MSG_TC_OPEN_SUCCESS", [])
			else:
				refused.emit(r.code)
		AcademyNet.OP_INVITE_RESULT:
			# c:0x8997a0: a refusal clears GInterface+0x509 first.
			if not r.ok:
				invite_pending = false
				refused.emit(r.code)
		AcademyNet.OP_NOTICE_RESULT:
			if r.ok:
				banner.emit("UIIT_MSG_TC_COMMON_KNOW_REMIND_UPDATE", [])
			else:
				refused.emit(r.code)
		_:
			# 0xB471 / 0xB473..0xB476: the success shows nothing (the push
			# that follows does); a refusal goes through category 0x1d.
			if not r.ok:
				refused.emit(r.code)
	result.emit(op, r.ok, r.code)
	return true

func _match_body(op: int, data: PackedByteArray) -> Dictionary:
	match op:
		AcademyNet.OP_MATCH_REGISTER_RESULT, AcademyNet.OP_MATCH_MODIFY_RESULT:
			return AcademyNet.decode_match_entry(op, data)
		AcademyNet.OP_MATCH_DELETE_RESULT:
			return {"entry_id": data.decode_u32(1)} if data.size() >= 5 else {}
		AcademyNet.OP_MATCH_PAGE_RESULT:
			return AcademyNet.decode_match_page(data)
		AcademyNet.OP_MATCH_JOIN_RESULT:
			return {"state": int(data[1])} if data.size() >= 2 else {}
	return {}

func _on_push(data: PackedByteArray) -> void:
	var p := AcademyNet.decode_push(data)
	if p.bad:
		print("AcademyState: short 0x3C80 sub %d (%d bytes) dropped" % [p.sub, data.size()])
		return
	match p.sub:
		AcademyNet.PUSH_DISBANDED:
			banner.emit("UIIT_STT_TC_DISSOLUTION_SUCCESS", [])
			_cleared()
		AcademyNet.PUSH_JOINED:
			# c:0x8a2169..0x8a242b: added, the line, +0x509 cleared, refresh.
			_add(p.member)
			invite_pending = false
			line.emit("UIIT_MSG_TC_MACHING_JOINING_MEMBER", [p.member.name])
			positions_changed.emit()
			changed.emit()
		AcademyNet.PUSH_REMOVED:
			_on_removed(p.char_id, p.reason)
		AcademyNet.PUSH_GRADUATED:
			# Kind 0 and 1 both (OPEN which is which); others nothing.
			if p.kind != 0 and p.kind != 1:
				return
			var m := member(p.char_id)
			if m == null:
				return
			if m.name == _me():
				banner.emit("UIIT_STT_TC_GRADUATION_CONGRATULATIONS", [])
				_cleared()
			else:
				line.emit("UIIT_STT_TC_GRADUATION_ANNOUNCE", [m.name])
				_remove(p.char_id)
				changed.emit()
		AcademyNet.PUSH_FIELD:
			_on_field(p)
		AcademyNet.PUSH_NOTICE:
			# c:0x8a2e53..0x8a2ee3: the first string is the title, the
			# second the content; then the banner.
			if camp != null:
				camp.notice_title = p.title
				camp.notice_content = p.content
			banner.emit("UIIT_MSG_TC_COMMON_KNOW_REMIND_UPDATE", [])
			changed.emit()
		AcademyNet.PUSH_ENTERED:
			if p.ok and p.camp != null:
				# c:0x8a2f60..0x8a2fcb: fill, the academy window opens
				# (0x79af70), refresh, "Joined Academy." on the banner.
				_fill(p.camp)
				pending_inviter = 0
				invitation_closed.emit()
				window_wanted.emit()
				changed.emit()
				banner.emit("UIIT_STT_TC_JOIN_ANNOUNCE", [])
			elif not p.ok:
				# c:0x8a2fd5: only the code's text (0x000E has none); the
				# invitation box is left to its own timer.
				refused.emit(p.code)
		AcademyNet.PUSH_RANK:
			if camp != null:
				camp.rank = p.rank
			changed.emit()
		AcademyNet.PUSH_POSITION:
			var m := member(p.char_id)
			if m != null:
				m.display_name = p.display_name
				m.world_id = p.world_id
				m.region = p.region
				m.x = p.x
				m.y = p.y
				m.z = p.z
				positions_changed.emit()
		_:
			pass

## Sub 3 (c:0x8a2512..0x8a2a1e): "me" by name; reason 1 left, 2 banned,
## 3 silent (not me: removed without a line; me: nothing).
func _on_removed(char_id: int, reason: int) -> void:
	var m := member(char_id)
	if m == null:
		return
	var me := m.name == _me()
	match reason:
		AcademyNet.REMOVED_LEFT:
			if me:
				banner.emit("UIIT_STT_TC_OUT_TRAININGCAMP_ANNOUNCE", [])
				_cleared()
				return
			line.emit("UIIT_STT_TC_OUT_TRAININGCAMP_OTHER_USER", [m.name])
		AcademyNet.REMOVED_BANNED:
			if me:
				banner.emit("UIIT_MSG_TC_EXPULSION_RESULT_ANNOUNCE", [])
				_cleared()
				return
			line.emit("UIIT_MSG_TC_EXPULSION_RESULT", [m.name])
		AcademyNet.REMOVED_SILENT:
			if me:
				return
		_:
			return
	_remove(char_id)
	changed.emit()

## Sub 5 (c:0x6e8ed0): one field of one member.
func _on_field(p: AcademyNet.Push) -> void:
	var m := member(p.char_id)
	if m == null:
		return
	match p.field:
		AcademyNet.FIELD_PLAY_STATE:
			var was := m.play_state
			m.play_state = p.value
			_announce_state(m, was)
			positions_changed.emit()
		AcademyNet.FIELD_MAX_LEVEL:
			m.max_level = p.value
			m.grade = AcademyNet.grade_of(m.member_class, m.max_level, m.grade)
		AcademyNet.FIELD_HONOR:
			m.honor = p.value
		AcademyNet.FIELD_CUR_LEVEL:
			m.cur_level = p.value
		AcademyNet.FIELD_MODEL:
			m.ref_obj_id = p.value
		_:
			return
	changed.emit()

## c:0x6e8f66..0x6e95da: the play-state lines.
## - offline (1): "%s [%s] has logged out of the game." with the class title
##   and the name, for anyone; the guardian's flag is cleared;
## - online (0), the member itself: "Academy Notice “%s”" with the notice
##   title, only when there is a title (c:0x6e9223 `cmp [eax+0x4c],esi; je`);
## - online, another: the guardian's line once (+0x560), an assistant's or
##   apprentice's only when its slot showed it offline (+0x540 == 0).
func _announce_state(m: AcademyNet.Member, was: int) -> void:
	var title_key: String = AcademyNet.CLASS_TITLES.get(m.member_class, "")
	if m.play_state == AcademyNet.OFFLINE:
		if title_key != "":
			line.emit("UIIT_MSG_TC_DISCONNECT2", [title_key, m.name])
		if m.member_class == AcademyNet.CLASS_GUARDIAN:
			guardian_announced = false
		return
	if m.play_state != AcademyNet.ONLINE:
		return
	if m.name == _me():
		if camp != null and camp.notice_title != "":
			line.emit("UIIT_STT_TC_COMMON_KNOW", [camp.notice_title])
		return
	if m.member_class == AcademyNet.CLASS_GUARDIAN:
		if guardian_announced:
			return
		guardian_announced = true
	elif was == AcademyNet.ONLINE:
		return
	if title_key != "":
		line.emit("UIIT_MSG_TC_CONNECT2", [title_key, m.name])

## The store cleared and the academy's windows closed (subs 1, 3 and 4 for
## the player itself: c:0x992fe0, then the window resets).
func _cleared() -> void:
	clear()
	own_buff_points = 0
	positions_changed.emit()
	store_cleared.emit()
	changed.emit()

func _close_invitation() -> void:
	if pending_inviter != 0:
		pending_inviter = 0
		invitation_closed.emit()

## The box's answer: the 0x3080 payload, empty with no box open.
func answer(accept: bool) -> PackedByteArray:
	if pending_inviter == 0:
		return PackedByteArray()
	pending_inviter = 0
	return AcademyNet.encode_answer(accept)

## The box's own timer closed it: forget it, unanswered.
func forget_invitation() -> void:
	pending_inviter = 0

## A new connection starts with an empty store (the client's store is
## per character; CharacterDependentData).
func reset_connection() -> void:
	clear()
	pending_inviter = 0
	invite_pending = false
	own_buff_points = 0
	changed.emit()
