extends HudCosBox
class_name GuildMsgBox

## Round 822: the guild membership's message boxes, built from the client's
## own `resinfo\ifmessagebox.txt` in the shell the COS and party boxes share
## (HudCosBox / PartyMatchBox). READ from sro_client.exe unless a line says
## otherwise.
##
## Four are CMessageBoxManager boxes (0x6ec5d0: section MsgBoxINIF, mode 1,
## 0x134 x 0x94 unless the purpose resizes it, placed at screen w / 2 - 0x9a,
## h / 2 - 0x4a), their text set by UI_SILKMALL::FUN_00644c90's purpose
## (jump table 0x648758, index purpose - 1):
## - **0x0F, the invitation** (0x3080 kind 5, c:0x88aeb7; case 0x6468de):
##   title UIIT_STT_AGREEMENT_BOX; +0x840 UIIT_MSG_GUILD_JOIN_REQUEST with the
##   inviter's name (entity +0x110 of the uid at +0x854); +0x844
##   UIIT_MSG_GUILD_QUESTION_JOIN with the guild's name (+0x820); then
##   0x6458ac: +0x808 hidden and the box's timer armed (0x644650; 30 s is
##   PartyInvitePopup's reading of it, INFERRED). Yes sends {1, 1}, No
##   {2, 0x4c16} (0x797d90 case 0x79819c).
## - **0x12, the founding's question** (case 0x646a27): title
##   UIIT_STT_CONFIRM_BOX; resized to 0x1b8 x 0x90 (440x144); +0x840, +0x844,
##   +0x800 and +0x804 moved 0x42 to the right; +0x840
##   UIIT_MSG_GUILD_QUESTION_CREATE with the name (+0x820), +0x844
##   UIIT_MSG_GUILD_QUESTION_CREATE_CONFIRM. OK sends 0x70F0 (0x797d90 case
##   0x12, 0x7982eb). Where the box is opened from, and so where it is
##   placed, was not traced (OPEN): it is centred here.
## - **0x13, disband** (case 0x646be0): title UIIT_STT_AGREEMENT_BOX, +0x840
##   UIIT_MSG_GUILD_BREAK_CONFIRM. OK sends 0x70F1 (0x798309). The NPC's
##   line 0x14 opens it (CIF_NPCTalk::FUN_007020c0).
## - **0x14, leave** (case 0x646c40, which joins 0x13's tail at 0x646c13):
##   title UIIT_STT_CONFIRM_BOX, +0x840 UIIT_MSG_GUILD_SECESSION_CONFIRM. OK
##   sends 0x70F2 (0x798326). The NPC's line 0x1c opens it.
## +0x840 / +0x844 as MESSAGE1 / MESSAGE2 and +0x800 / +0x804 / +0x808 as
## OK / CANCEL / CERTIFY is INFERRED, as PartyInvitePopup and HudCosBox take
## them. A purpose without a resize keeps the 308x148 box (0x6ec5d0).
##
## The fifth is the guild window's ban question (CNIFGuildWnd's dispatcher
## 0x5b63e0, index 2): a MsgBoxSimple box (0x643c20(9)) created at
## 0x118 x 0x90 and set up by 0x643e50 with UIIT_STT_CONFIRM_BOX, the text
## UIIT_MSG_GUILD_QUESTION_EXPULSION_ANYONE with the member's name, style 1
## (Yes / No) and that size (pushes at 0x5b65f3..0x5b65fd), then centred
## (0x798b70). Its Yes runs 0x5b45b0 -> 0x824190, the 0x70F4 sender.

enum Kind { INVITE = 0x0F, CREATE = 0x12, DISBAND = 0x13, LEAVE = 0x14 }

const INIF_SIZE := Vector2(0x134, 0x94)
const CREATE_SIZE := Vector2(0x1b8, 0x90)
const CREATE_SHIFT := 0x42
const INVITE_TIMEOUT_SEC := 30.0

## The box's own timer closed it, unanswered (box 0x0F only).
signal expired

var kind := 0
var _timer: SceneTreeTimer

## Builds box `box_kind` (Kind). `who` is the inviter's name (INVITE) and
## `what` the guild's name (INVITE, CREATE). False without the layout.
func build_guild_box(builder: UiBuilder, box_kind: int, who: String = "", what: String = "") -> bool:
	kind = box_kind
	var box := CREATE_SIZE if box_kind == Kind.CREATE else INIF_SIZE
	var title := "UIIT_STT_AGREEMENT_BOX" if box_kind == Kind.INVITE or box_kind == Kind.DISBAND else "UIIT_STT_CONFIRM_BOX"
	var names := {Kind.INVITE: "GuildInvitation", Kind.CREATE: "GuildCreateConfirm",
		Kind.DISBAND: "GuildDisbandConfirm", Kind.LEAVE: "GuildLeaveConfirm"}
	if not names.has(box_kind):
		return false
	name = names[box_kind]
	if not build_shell(builder, box, title, title, LAYOUT, "MsgBoxINIF"):
		return false
	# The texts resolve through the builder build_shell keeps.
	var lines: Array = []
	match box_kind:
		Kind.INVITE:
			lines = [_format("UIIT_MSG_GUILD_JOIN_REQUEST", who), _format("UIIT_MSG_GUILD_QUESTION_JOIN", what)]
		Kind.CREATE:
			lines = [_format("UIIT_MSG_GUILD_QUESTION_CREATE", what), text("UIIT_MSG_GUILD_QUESTION_CREATE_CONFIRM", "UIIT_MSG_GUILD_QUESTION_CREATE_CONFIRM")]
		Kind.DISBAND:
			lines = [text("UIIT_MSG_GUILD_BREAK_CONFIRM", "UIIT_MSG_GUILD_BREAK_CONFIRM")]
		Kind.LEAVE:
			lines = [text("UIIT_MSG_GUILD_SECESSION_CONFIRM", "UIIT_MSG_GUILD_SECESSION_CONFIRM")]
	_add_background(builder, box)
	var shift := float(CREATE_SHIFT) if box_kind == Kind.CREATE else 0.0
	var statics := ["GDR_MBIN_STATIC_MESSAGE1", "GDR_MBIN_STATIC_MESSAGE2"]
	for i in statics.size():
		var n := node(statics[i])
		if n == null:
			continue
		_move(n, shift)
		builder.set_static_text(n, str(lines[i]) if i < lines.size() else "")
	var ok := node("GDR_MBIN_BTN_OK")
	var cancel := node("GDR_MBIN_BTN_CANCEL")
	for b in [ok, cancel]:
		if b != null:
			_move(b, shift)
	if ok is BaseButton:
		(ok as BaseButton).pressed.connect(press_ok)
	if cancel is BaseButton:
		(cancel as BaseButton).pressed.connect(press_cancel)
	var certify := node("GDR_MBIN_BTN_CERTIFY")
	if certify != null:
		certify.visible = false
	return true

## Arms box 0x0F's timer (call once the box is in the tree).
func arm_timer() -> void:
	if kind != Kind.INVITE or not is_inside_tree():
		return
	_timer = get_tree().create_timer(INVITE_TIMEOUT_SEC)
	_timer.timeout.connect(func() -> void:
		if is_instance_valid(self) and not is_queued_for_deletion():
			expired.emit()
			close())

## CMessageBoxManager's placement (0x6ec5d0); the founding's box centred.
func place_on(view: Vector2) -> void:
	if kind == Kind.CREATE:
		centre_on(view)
	else:
		position = Vector2(floorf(view.x / 2.0) - 0x9a, floorf(view.y / 2.0) - 0x4a)

func _move(n: Control, dx: float) -> void:
	if dx == 0.0:
		return
	var r: Rect2 = n.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(n.position, n.size))
	r.position.x += dx
	_place(n, r)

## The archive's text for `key` with one %s filled (the key itself without
## the archive; no English is invented here).
func _format(key: String, value: String) -> String:
	var fmt := text(key, key)
	return fmt.replace("%s", value) if fmt.count("%s") == 1 else fmt

## The window's ban question (MsgBoxSimple, 280x144, Yes / No).
static func expel_question(builder: UiBuilder, member_name: String) -> PartyMatchConfirm:
	var box := PartyMatchConfirm.new()
	var fmt := builder.resolve_text("UIIT_MSG_GUILD_QUESTION_EXPULSION_ANYONE") if builder != null else ""
	if fmt == "":
		fmt = "UIIT_MSG_GUILD_QUESTION_EXPULSION_ANYONE"
	var msg := fmt.replace("%s", member_name) if fmt.count("%s") == 1 else fmt
	if not box.build(builder, msg, Vector2(0x118, 0x90)):
		box.free()
		return null
	box.name = "GuildExpelConfirm"
	return box
