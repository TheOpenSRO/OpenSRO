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

enum Kind { INVITE = 0x0F, CREATE = 0x12, DISBAND = 0x13, LEAVE = 0x14,
	CREST = 0x15, CREST_DELETE = 0x16, UNION_CREST = 0x18, UNION_CREST_DELETE = 0x19,
	CREST_DONE = 0x1a, UNION_CREST_DONE = 0x1b }

## Round 824: the crest items' boxes (UI_SILKMALL::FUN_00644c90, READ; the
## items open them from IFSlotWithHelp::FUN_00676570, 0x676dcb..0x676efe, and
## the item result opens 0x1a / 0x1b, Item_OnUseItemResult 0x87b198 /
## 0x87b275). All titled UIIT_STT_CONFIRM_BOX.
## - 0x15 / 0x18 (case 0x646df5 / 0x647069): 0x1cc x 0xd2 (460 x 210); +0x840,
##   +0x844, +0x848, +0x84c at (0x32, 0x33 / 0x44 / 0x55 / 0x7a), each sized
##   0x167 x 0xf; OK and Cancel moved (+0x50, +0x3c); +0x808 hidden. The
##   guild's lines: UIIT_MSG_GUILD_USER_CREST, _USER_CREST_FILE,
##   _USER_CREST_FOLDER, UIIT_MSG_GUILD_CREST_REGISTER; the union's:
##   UIIT_MSG_UNION_USER_CREST, _USER_CREST_FOLDER, UIIT_CTL_UNION_CREST_
##   REGISTER, UIIT_MSG_UNION_CREST_REGISTER.
## - 0x16 / 0x19 (case 0x647031 / 0x647292, into 0x13's tail): the 308 x 148
##   box, +0x840 UIIT_MSG_GUILD_CREST_DELETE / UIIT_MSG_UNION_CREST_DELETE.
## - 0x1a / 0x1b (case 0x6472ca / 0x647584): 460 x 210; +0x840..+0x850 at
##   (0x32, 0x37 / 0x5a / 0x6b / 0x7c / 0x8d), 0x167 x 0xf: UIIT_MSG_GUILD_
##   (UNION_)CREST_REGISTER_COMPLETE and UIIT_MSG_CREST_REGISTER_INFORMATION_
##   01..04; OK moved (+0x78, +0x3c) with UIIT_CTL_CONFIRM; Cancel and +0x808
##   hidden.
## +0x840..+0x850 as MESSAGE1..MESSAGE5 is INFERRED (as above).
const CREST_SIZE := Vector2(0x1cc, 0xd2)
const CREST_LINE_SIZE := Vector2(0x167, 0xf)
const CREST_LINE_X := 0x32
const CREST_ASK_YS := [0x33, 0x44, 0x55, 0x7a]
const CREST_DONE_YS := [0x37, 0x5a, 0x6b, 0x7c, 0x8d]
const CREST_ASK_BUTTON_SHIFT := Vector2(0x50, 0x3c)
const CREST_DONE_BUTTON_SHIFT := Vector2(0x78, 0x3c)
const MESSAGES := ["GDR_MBIN_STATIC_MESSAGE1", "GDR_MBIN_STATIC_MESSAGE2", "GDR_MBIN_STATIC_MESSAGE3",
	"GDR_MBIN_STATIC_MESSAGE4", "GDR_MBIN_STATIC_MESSAGE5"]

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

## Builds a crest box (Kind.CREST..UNION_CREST_DONE). False without the
## layout or for another kind.
func build_crest_box(builder: UiBuilder, box_kind: int) -> bool:
	kind = box_kind
	var union := box_kind == Kind.UNION_CREST or box_kind == Kind.UNION_CREST_DELETE or box_kind == Kind.UNION_CREST_DONE
	var keys: Array = []
	var ys: Array = []
	var box := CREST_SIZE
	var shift := Vector2.ZERO
	match box_kind:
		Kind.CREST, Kind.UNION_CREST:
			keys = ["UIIT_MSG_UNION_USER_CREST", "UIIT_MSG_UNION_USER_CREST_FOLDER", "UIIT_CTL_UNION_CREST_REGISTER",
				"UIIT_MSG_UNION_CREST_REGISTER"] if union else ["UIIT_MSG_GUILD_USER_CREST", "UIIT_MSG_GUILD_USER_CREST_FILE",
				"UIIT_MSG_GUILD_USER_CREST_FOLDER", "UIIT_MSG_GUILD_CREST_REGISTER"]
			ys = CREST_ASK_YS
			shift = CREST_ASK_BUTTON_SHIFT
		Kind.CREST_DELETE, Kind.UNION_CREST_DELETE:
			keys = ["UIIT_MSG_UNION_CREST_DELETE" if union else "UIIT_MSG_GUILD_CREST_DELETE"]
			box = INIF_SIZE
		Kind.CREST_DONE, Kind.UNION_CREST_DONE:
			keys = ["UIIT_MSG_UNION_CREST_REGISTER_COMPLETE" if union else "UIIT_MSG_GUILD_CREST_REGISTER_COMPLETE",
				"UIIT_MSG_CREST_REGISTER_INFORMATION_01", "UIIT_MSG_CREST_REGISTER_INFORMATION_02",
				"UIIT_MSG_CREST_REGISTER_INFORMATION_03", "UIIT_MSG_CREST_REGISTER_INFORMATION_04"]
			ys = CREST_DONE_YS
			shift = CREST_DONE_BUTTON_SHIFT
		_:
			return false
	name = "CrestBox%x" % box_kind
	if not build_shell(builder, box, "UIIT_STT_CONFIRM_BOX", "UIIT_STT_CONFIRM_BOX", LAYOUT, "MsgBoxINIF"):
		return false
	_add_background(builder, box)
	for i in MESSAGES.size():
		var n := node(MESSAGES[i])
		if n == null:
			continue
		if i >= keys.size():
			builder.set_static_text(n, "")
			continue
		builder.set_static_text(n, text(keys[i], keys[i]))
		if not ys.is_empty():
			# A Label keeps its font's line height as its least height, so
			# the 15 rows are the line's place, not a clip.
			_place(n, Rect2(Vector2(CREST_LINE_X, float(ys[i])), CREST_LINE_SIZE))
	var ok := node("GDR_MBIN_BTN_OK")
	var cancel := node("GDR_MBIN_BTN_CANCEL")
	for b in [ok, cancel]:
		if b != null and shift != Vector2.ZERO:
			var r: Rect2 = b.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(b.position, b.size))
			_place(b, Rect2(r.position + shift, r.size))
	if ok is BaseButton:
		(ok as BaseButton).pressed.connect(press_ok)
	if cancel is BaseButton:
		(cancel as BaseButton).pressed.connect(press_cancel)
	if box_kind == Kind.CREST_DONE or box_kind == Kind.UNION_CREST_DONE:
		if cancel != null:
			cancel.visible = false
		if ok is BaseButton:
			builder.set_button_text(ok as BaseButton, text("UIIT_CTL_CONFIRM", "UIIT_CTL_CONFIRM"))
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

## Round 824: GInterface::FUN_00788270's notice (the crest deletes' result,
## 0x87b1ed / 0x87b2ce: UIIT_STT_CONFIRM_BOX and the text, the style byte 0):
## MsgBoxSimple at 360 x 151 with style 0 -- OK centred (x + w/2 - 38) as
## UIIT_CTL_CONFIRM, Cancel hidden (docs/protocol/message_box.md).
static func notice_box(builder: UiBuilder, key: String) -> PartyMatchConfirm:
	var box := PartyMatchConfirm.new()
	var t := builder.resolve_text(key) if builder != null else ""
	if not box.build(builder, t if t != "" else key):
		box.free()
		return null
	box.name = "CrestNotice"
	var buttons: Array[BaseButton] = []
	for n in box.root.get_children():
		if n is BaseButton:
			buttons.append(n)
	buttons.sort_custom(func(a: BaseButton, b: BaseButton) -> bool: return a.position.x < b.position.x)
	if buttons.size() >= 2:
		buttons[1].visible = false
	if not buttons.is_empty():
		var ok := buttons[0]
		var at := Vector2(PartyMatchConfirm.SIZE.x / 2.0 - 38.0, ok.position.y)
		ok.position = at
		ok.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(at, ok.size))
		var cap := builder.resolve_text("UIIT_CTL_CONFIRM") if builder != null else ""
		builder.set_button_text(ok, cap if cap != "" else "UIIT_CTL_CONFIRM")
	return box

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
