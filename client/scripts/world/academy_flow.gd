extends RefCounted
class_name AcademyFlow

## Round 865: the academy on the client, between the store (AcademyState),
## the HUD (HudPanels' AcademyWindow, the boxes, the evaluation and ranking
## windows, the notice writer) and the world (the talk box, the selection,
## the text tables, the system and banner windows). docs/protocol/
## academy.md sections 6, 7, 10 and 11. World3D owns one. READ unless a line
## says otherwise:
##
## - the lines: AcademyState.line -> the system message window, type 0
##   (0x778210 / 0x7781b0(0, text)); AcademyState.banner -> GDR_WARNING_WND
##   (0x77b580); AcademyState.refused -> category 0x1d of the error
##   dispatcher (0x778190(0x1d, code)), nothing for a code without a row;
## - the talk lines (CIF_NPCTalk 0x7020c0, tables c:0x703d2c / c:0x703c6c):
##   0x2d "Academy Establishment" opens UIIT_MSG_TC_TRAININGCAMP_OPEN (box 6,
##   c:0x6f8cb0); its OK (c:0x6f79c0, c:0x6f7b21) refuses locally with
##   UIIT_MSG_TC_ERROR_OPEN_GOLD below 100,000 gold (64-bit, inventory
##   +0x378) and sends nothing, else 0x7470 {talk NPC} (c:0x704080). 0x2e
##   "Honor Rank" sends 0x7478 {talk NPC} at once;
## - Invite (c:0x6e89b0 -> c:0x821f00): the selected object must exist and not
##   be the player; a COS resolves to its owner (c:0x9ce910); the line
##   UIIT_STT_TC_PROPOSAL_PENDING with the target's name (obj+0x114), then
##   GInterface+0x509 set (0x777bd0(1)) and 0x7472 {uid};
## - Dismiss (c:0x6e8da0, callback c:0x6e8830, type 100): UIIT_STT_TC_
##   DISSOLUTION, Yes -> 0x7471;
## - a row's button (c:0x6eb0f0, callback c:0x6ea6f0, types 100..103):
##   force graduation UIIT_MSG_TC_GRADUATION_COMPULSION(name) -> 0x7476 {name};
##   ban UIIT_STT_TC_BAN_TRAININGCAMP(name) -> 0x7473 {name}; leave
##   UIIT_STT_TC_OUT_TRAININGCAMP -> 0x7474; an assistant's graduation
##   UIIT_STT_TC_GRADUATION -> 0x7475 {0}; an apprentice's: the evaluation
##   window (c:0x79d290(1)) -> 0x7475 {byte};
## - the pencil: the notice writer in mode 2 (c:0x79b380(1, 2)), 0x7477;
## - 0x3080 kind 9: "Join request sent" (UIIT_PAG_PARTYMATCH_JOINREQUEST)
##   with UIIT_STT_TC_JOIN_REQUEST(inviter); Yes {1, 1}, No / closed {2, 0, 0};
## - 0xB478's rows open the ranking window (c:0x79d180(1)).

const FEE := 100000

var world: Node
var hud: HudPanels
var state: AcademyState
var _invite_box: AcademyMsgBox = null
var _judge_wired := false

func _init(w: Node, h: HudPanels) -> void:
	world = w
	hud = h
	state = NetClient.academy
	state.line.connect(_on_line)
	state.banner.connect(_on_banner)
	state.refused.connect(refusal)
	state.window_wanted.connect(func() -> void: hud.open("academy"))
	state.store_cleared.connect(func() -> void: hud.close_academy_windows())
	state.invitation.connect(_on_invitation)
	state.invitation_closed.connect(_close_invitation)
	state.honor_rows.connect(func(rows: Array) -> void: hud.open_academy_honor(rows))
	state.result.connect(func(op: int, ok: bool, code: int) -> void:
		print("ACADEMY result 0x%04X ok=%s code=0x%x" % [op, ok, code]))
	# The character window's Honor Point follows the store.
	state.changed.connect(hud.apply_academy_honor)
	hud.academy_pane_built.connect(_wire_pane)
	if hud.academy_pane != null:
		_wire_pane(hud.academy_pane)
	hud.academy_notice_submitted.connect(func(t: String, b: String) -> void:
		NetClient.academy_send(AcademyNet.OP_NOTICE, AcademyNet.encode_notice(t, b)))
	hud.academy_local_refused.connect(refusal)
	hud.academy_line.connect(func(type: int, t: String) -> void: world.call("_log_system", t, type))

func _wire_pane(pane: AcademyWindow) -> void:
	pane.dismiss_pressed.connect(ask_disband)
	pane.invite_pressed.connect(invite_selected)
	pane.notice_edit_pressed.connect(func() -> void: hud.open_academy_notice_write())
	pane.row_pressed.connect(on_row)
	pane.match_pressed.connect(func() -> void: world.call("_academy_open_matching"))

## 0x7ad400's academy gate for a chat line (0x987140, the camp record's
## valid flag): an "&" line goes only from inside an academy (choice 3).
static func chat_allowed(st: AcademyState) -> bool:
	return st != null and st.in_academy()

# --- Text -----------------------------------------------------------------------

func _text(key: String, fallback: String = "") -> String:
	return String(world.call("_resolve_any_text", key, fallback if fallback != "" else key))

## A key's text with its values; a value that is itself a text key (the
## class titles of the log-on lines) is resolved first. "" when the archive
## lacks the key.
func format(key: String, args: Array) -> String:
	var t := _text(key, "")
	if t == "" or t == key:
		return ""
	var vals: Array = []
	for a in args:
		var s := String(a)
		vals.append(_text(s, s) if s.begins_with("UIIT_") else s)
	var wanted := t.count("%s") + t.count("%d")
	if wanted == vals.size() and wanted > 0:
		return t % vals
	return t

func _on_line(key: String, args: Array) -> void:
	var t := format(key, args)
	print("ACADEMY line %s %s" % [key, args])
	if t != "":
		world.call("_log_system", t, HudSystemMessage.TYPE_ALWAYS)

func _on_banner(key: String, args: Array) -> void:
	var t := format(key, args)
	print("ACADEMY banner %s %s" % [key, args])
	if t != "":
		world.call("_show_banner", "system", t)

## Category 0x1d (0x778190): the code's text in the system window, nothing
## for a code without a row.
func refusal(code: int) -> void:
	var key := AcademyNet.error_key(code)
	print("ACADEMY refused 0x%x (%s)" % [code, key if key != "" else "no message in the client"])
	if key == "":
		return
	var t := _text(key, "")
	if t != "" and t != key:
		world.call("_log_system", t, HudSystemMessage.TYPE_ALWAYS)

# --- The talk lines ---------------------------------------------------------------

## A talk line's action; false when the key is not the academy's.
func handle_service(key: String) -> bool:
	match key:
		"academy_open":
			ask_found(int(world.call("_talk_npc_uid")))
			return true
		"honor_rank":
			NetClient.academy_send(AcademyNet.OP_HONOR_RANK, AcademyNet.encode_npc(int(world.call("_talk_npc_uid"))))
			return true
	return false

## Line 0x2d: the fee box; its Yes checks the gold first (c:0x6f7b21).
func ask_found(npc: int) -> AcademyMsgBox:
	var box := hud.open_academy_box(_text("UIIT_MSG_TC_TRAININGCAMP_OPEN"), "UIIT_STT_CONFIRM_BOX", "found")
	if box != null:
		box.yes.connect(func() -> void: found(npc))
	return box

func found(npc: int) -> void:
	var gold := int(world.get("_last_known_gold"))
	if gold >= 0 and gold < FEE:
		var t := _text("UIIT_MSG_TC_ERROR_OPEN_GOLD", "")
		print("ACADEMY found: %d gold is below the fee, nothing sent" % gold)
		if t != "":
			world.call("_log_system", t, HudSystemMessage.TYPE_ALWAYS)
		return
	NetClient.academy_send(AcademyNet.OP_OPEN, AcademyNet.encode_npc(npc))

# --- The window's buttons ------------------------------------------------------------

func ask_disband() -> AcademyMsgBox:
	var box := hud.open_academy_box(_text("UIIT_STT_TC_DISSOLUTION"), "UIIT_STT_CONFIRM_BOX", "disband")
	if box != null:
		box.yes.connect(func() -> void: NetClient.academy_send(AcademyNet.OP_DISBAND, AcademyNet.encode_empty()))
	return box

## [uid, name] of the object Invite would ask, [] when there is none.
func invite_target() -> Array:
	var uid := int(world.call("_academy_selected_target"))
	if uid == 0:
		return []
	return [uid, String(world.call("_academy_name_of", uid))]

func invite_selected() -> void:
	var t := invite_target()
	if t.is_empty():
		print("ACADEMY invite: nothing selected")
		return
	var line := format("UIIT_STT_TC_PROPOSAL_PENDING", [String(t[1])])
	if line != "":
		world.call("_log_system", line, HudSystemMessage.TYPE_ALWAYS)
	NetClient.academy_send(AcademyNet.OP_INVITE, AcademyNet.encode_invite(int(t[0])))

func on_row(action: String, member_name: String) -> AcademyMsgBox:
	var box: AcademyMsgBox = null
	match action:
		AcademyWindow.ACT_GRADUATE_MEMBER:
			box = _box_named("UIIT_MSG_TC_GRADUATION_COMPULSION", member_name, action)
			if box != null:
				box.yes.connect(func() -> void:
					NetClient.academy_send(AcademyNet.OP_GRADUATE_MEMBER, AcademyNet.encode_name(member_name)))
		AcademyWindow.ACT_BAN:
			box = _box_named("UIIT_STT_TC_BAN_TRAININGCAMP", member_name, action)
			if box != null:
				box.yes.connect(func() -> void:
					NetClient.academy_send(AcademyNet.OP_BAN, AcademyNet.encode_name(member_name)))
		AcademyWindow.ACT_LEAVE:
			box = hud.open_academy_box(_text("UIIT_STT_TC_OUT_TRAININGCAMP"), "UIIT_STT_CONFIRM_BOX", action)
			if box != null:
				box.yes.connect(func() -> void: NetClient.academy_send(AcademyNet.OP_LEAVE, AcademyNet.encode_empty()))
		AcademyWindow.ACT_GRADUATE_ASSISTANT:
			box = hud.open_academy_box(_text("UIIT_STT_TC_GRADUATION"), "UIIT_STT_CONFIRM_BOX", action)
			if box != null:
				box.yes.connect(func() -> void: NetClient.academy_send(AcademyNet.OP_GRADUATE, AcademyNet.encode_graduate(0)))
		AcademyWindow.ACT_JUDGE:
			open_judge()
	return box

func _box_named(key: String, member_name: String, kind: String) -> AcademyMsgBox:
	var t := _text(key)
	if t.count("%s") == 1:
		t = t % member_name
	return hud.open_academy_box(t, "UIIT_STT_CONFIRM_BOX", kind)

func open_judge() -> AcademyJudgeWindow:
	var j := hud.open_academy_judge()
	if j != null and not j.evaluated.is_connected(_on_evaluated):
		j.evaluated.connect(_on_evaluated)
	return j

func _on_evaluated(value: int) -> void:
	NetClient.academy_send(AcademyNet.OP_GRADUATE, AcademyNet.encode_graduate(value))

# --- The invitation --------------------------------------------------------------------

func _on_invitation(_uid: int, inviter: String) -> void:
	_close_invitation()
	var t := _text("UIIT_STT_TC_JOIN_REQUEST")
	if t.count("%s") == 1:
		t = t % inviter
	_invite_box = hud.open_academy_box(t, "UIIT_PAG_PARTYMATCH_JOINREQUEST", "invitation")
	if _invite_box == null:
		return
	_invite_box.arm_timer()
	_invite_box.yes.connect(func() -> void:
		_invite_box = null
		NetClient.academy_answer(true))
	_invite_box.no.connect(func() -> void:
		_invite_box = null
		NetClient.academy_answer(false))
	_invite_box.expired.connect(func() -> void:
		_invite_box = null
		state.forget_invitation())

func _close_invitation() -> void:
	if _invite_box != null and is_instance_valid(_invite_box):
		_invite_box.close()
	_invite_box = null

func invitation_box() -> AcademyMsgBox:
	return _invite_box if _invite_box != null and is_instance_valid(_invite_box) else null

# --- The exp buffs (academy.md 7.11) -----------------------------------------------

## The board's tokens for the academy's icons (OURS: the board keys entries by
## a token; the client keys them by kind and member).
const BUFF_TOKEN_SAVE := 0x7f650000
const BUFF_TOKEN_RESERVE := 0x7f660000
## READ s:0x4eb860: a buff lasts 1,440 minutes.
const BUFF_MINUTES := 1440
## READ c:0x800520..0x80063d: the transfer box wants 0x36ee80 ms or more.
const TRANSFER_MIN_MS := 3600000

var board: HudBuffBoard = null
## Donor CharID -> points, for the type-8 tooltips.
var _reserve_points := {}
var _own_minutes := 0

func attach_board(b: HudBuffBoard) -> void:
	board = b
	if board == null:
		return
	board.academy_buff_clicked.connect(_on_buff_clicked)
	state.buff_message.connect(on_buff_message)
	state.store_cleared.connect(func() -> void:
		for t in board.academy_buff_tokens():
			if int(t) >= BUFF_TOKEN_RESERVE:
				board.remove_academy_buff(int(t))
		_reserve_points.clear())

func _save_tooltip() -> String:
	var t := _text("UIIT_CTL_TC_SAVE_BUFF")
	var line := "%s: %d %s" % [_text("UIIT_CTL_TC_SAVE_BUFF_POINT"), state.own_buff_points, _text("UIIT_STT_SILKMALL_P_POINT")]
	return t + "\n" + line

func _reserve_tooltip(donor: int) -> String:
	var lines := PackedStringArray([_text("UIIT_CTL_TC_RESERVE_BUFF")])
	var m := state.member(donor)
	var g := state.guardian()
	if m != null and (g == null or g.char_id != donor):
		lines.append("%s: %s" % [_text("UIIT_STT_LETTER_SENDER"), m.name])
	lines.append("%s: %d %s" % [_text("UIIT_CTL_TC_RESERVE_BUFF_POINT"), int(_reserve_points.get(donor, 0)),
		_text("UIIT_STT_SILKMALL_P_POINT")])
	return "\n".join(lines)

func _put_save(minutes: int) -> void:
	_own_minutes = minutes
	if board != null:
		board.add_academy_buff(HudBuffBoard.KIND_ACADEMY_SAVE, BUFF_TOKEN_SAVE, BUFF_MINUTES * 60000,
			minutes * 60000 + 1, _save_tooltip())

func _put_reserve(minutes: int, donor: int) -> void:
	if board != null:
		board.add_academy_buff(HudBuffBoard.KIND_ACADEMY_RESERVE, BUFF_TOKEN_RESERVE + (donor & 0xffff), -1,
			minutes * 60000 + 1, _reserve_tooltip(donor))

func on_buff_message(op: int, d: Dictionary) -> void:
	print("ACADEMY buff 0x%04X %s" % [op, d])
	match op:
		AcademyNet.OP_OWN_BUFF:
			var sub := int(d["sub"])
			if sub in [0, 1, 7]:
				_put_save(int(d["minutes"]))
				if sub == 7:
					world.call("_log_system", _text("UIIT_CTL_TC_SAVE_BUFF_TIME_OVER"), HudSystemMessage.TYPE_ALWAYS)
			elif sub in [5, 8, 9] and board != null:
				board.remove_academy_buff(BUFF_TOKEN_SAVE)
		AcademyNet.OP_OWN_BUFF_MINUTES:
			_put_save(int(d["minutes"]))
		AcademyNet.OP_RESERVE_BUFF_MINUTES:
			_put_reserve(int(d["minutes"]), int(d["donor"]))
		AcademyNet.OP_BUFF_LIST:
			var sub := int(d["sub"])
			if sub == 2:
				world.call("_log_system", _text("UIIT_MSG_TC_PASS_ERROR"), HudSystemMessage.TYPE_ALWAYS)
				return
			for r in d["rows"]:
				var row: Dictionary = r
				var donor := int(row["donor"])
				if sub in [5, 8, 9]:
					_reserve_points.erase(donor)
					if board != null:
						board.remove_academy_buff(BUFF_TOKEN_RESERVE + (donor & 0xffff))
					continue
				if sub == 1 and int(row["minutes"]) == 0:
					continue
				_reserve_points[donor] = int(row["points"])
				_put_reserve(int(row["minutes"]), donor)
				var m := state.member(donor)
				if sub == 0 and m != null and m.name != NetClient.current_character_name:
					var t := format("UIIT_MSG_TC_RECIEVE_BUFF", [m.name])
					if t != "":
						world.call("_log_system", t, HudSystemMessage.TYPE_ALWAYS)

## The own cumulated buff's click: with an hour or more on it, the transfer
## question (UIIT_CTL_TC_PASS_BUFF, simple_msgbox_type 9); its Yes sends
## 0x7483 with no payload (c:0x788840 case 9).
func _on_buff_clicked(_token: int, remaining_ms: int) -> void:
	if remaining_ms < TRANSFER_MIN_MS:
		return
	var box := hud.open_academy_box(_text("UIIT_CTL_TC_PASS_BUFF"), "UIIT_STT_CONFIRM_BOX", "transfer")
	if box != null:
		box.yes.connect(func() -> void: NetClient.academy_send(AcademyNet.OP_BUFF_TRANSFER, AcademyNet.encode_empty()))
