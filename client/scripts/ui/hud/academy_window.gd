extends RefCounted
class_name AcademyWindow

## Round 865: the academy window's pane -- CIFApprenticeShip, resinfo\
## ifapprenticeship.txt, the GDR_APPRENTICESHIP pane of the main popup
## (HudMainPopup builds the layout, key L) -- filled from AcademyState the
## way the client's refresh does, its buttons and member rows turned into
## the academy's requests. docs/protocol/academy.md section 10.1 / 10.2.
## READ from sro_client.exe unless a line says otherwise:
##
## - Create (c:0x6e9770): the Dismiss button's text UIIT_STT_PARTY_DISSOLVE;
##   the picture (41) hidden; NOTIFY_CONTENTS (140) hidden; seven
##   CIFApprenticeShipSlots, each loading ifapprenticeshipslot.txt.
## - Refresh (c:0x6e9b00): the seven slots cleared (0x6eaa10); no academy ->
##   the reset c:0x6e8c30: Matching enabled, Invite and the pencil disabled,
##   the pencil and Dismiss drawn 0xff999999 (Invite keeps its colour: see
##   _reset), the guardian's name, Lv, level,
##   rank mark and title hidden, the notice line "", the picture hidden,
##   LEADER_STATUS cleared. In an academy:
##   - the player is the guardian (c:0x989d20): Dismiss, Invite and the
##     pencil shown, enabled, text 0xfffff5da; the picture is the player's
##     own (0x7b5410);
##   - the notice line: the title, or UIIT_MSG_GUILD_COMMON_NOTEXIST; the
##     contents panel (140) gets the content (0x70b050);
##   - the guardian's record (0x993120): the name in 0xffffe194, the rank
##     mark com_honor_level_<camp rank>.ddj shown, the title
##     UIIT_STT_TC_GUARDIAN when its grade is 7, Lv and "%d(%d)" (current,
##     max), the picture shown, LEADER_STATUS pt_no_face.ddj when the
##     record's play state is 1 (offline), else no image;
##   - the slots: assistants from SLOT_0 (at most 2, "SubMentor is Over than
##     2"), apprentices from SLOT_2 (at most 5, "ApprenticeShip is Over than
##     5"), each in join order (MEASURED).
## - The slot (fill c:0x6eab30, click c:0x6eb0f0): the face, pt_no_face.ddj
##   offline, the grade's mark com_icon_level_<grade>.ddj, the name, Lv,
##   "%d(%d)", the grade's title, and the button (c:0x6ead69):
##   - the viewer is the guardian: "Graduate" (UIIT_CTL_TC_GRADUATION) for
##     an apprentice whose max level > 40 or an assistant > 60, else "Banish"
##     (UIIT_CTL_BAN_PARTY); enabled;
##   - the viewer is this member: "Graduate" at >= 40 / >= 60, else "Leave"
##     (UIIT_CTL_LEAVE_PARTY); enabled;
##   - anyone else: hidden (ShowWindow(0); round 865 stage 3, MEASURED).
## - The clicks (message map c:0xeb9af0): 0x30 Dismiss (c:0x6e8da0), 0x14
##   Invite (c:0x6e89b0), 0x16 Matching (c:0x6e8770), 0x3d the notice line
##   (notification 1, c:0x6e9690: toggles the contents panel when a title
##   exists), 0x3e the pencil (c:0x6e8a90).

const PANE := "GDR_APPRENTICESHIP"
const SLOT_LAYOUT := "resinfo\\ifapprenticeshipslot.txt"
const SLOTS := 7
## The first apprentice slot (+0x37c).
const APPRENTICE_FIRST := 2

const COLOR_BUTTON := Color8(0xff, 0xf5, 0xda)   ## 0xfffff5da
const COLOR_GREY := Color8(0x99, 0x99, 0x99)     ## 0xff999999
const COLOR_GUARDIAN := Color8(0xff, 0xe1, 0x94) ## 0xffffe194
const NO_FACE := "interface\\party\\pt_no_face.ddj"
const HONOR_ART := "interface\\ifcommon\\com_honor_level_%d.ddj"
const GRADE_ART := "interface\\ifcommon\\com_icon_level_%d.ddj"

## What a row's button asks for (c:0x6eb0f0's five outcomes).
const ACT_GRADUATE_MEMBER := "graduate_member"   ## box type 100 -> 0x7476
const ACT_BAN := "ban"                           ## box type 101 -> 0x7473
const ACT_LEAVE := "leave"                       ## box type 102 -> 0x7474
const ACT_GRADUATE_ASSISTANT := "graduate_self"  ## box type 103 -> 0x7475 {0}
const ACT_JUDGE := "judge"                       ## the evaluation window

signal dismiss_pressed
signal invite_pressed
signal match_pressed
signal notice_edit_pressed
## A row's button: the action and the member's name.
signal row_pressed(action: String, member_name: String)

var state: AcademyState
var _builder: UiBuilder
var _pane: Control
var _rows: Array[Control] = []
## Row index -> the member shown there (null when empty).
var _row_members: Array = []
var _views := {}
## The contents panel (140) is open.
var notice_open := false

## Injected by the world (each optional):
## a member's face (Texture2D) by its record, or null;
var portrait_of: Callable
## the player's own face (0x7b5410), or null.
var own_portrait: Callable

func _init(builder: UiBuilder, pane: Control, academy: AcademyState) -> void:
	_builder = builder
	_pane = pane
	state = academy
	_row_members.resize(SLOTS)
	_build_rows()
	_wire_buttons()
	state.changed.connect(refresh)
	# Round 865 stage 3: the original builds this pane with the interface at
	# world entry, before any camp is known, so its first refresh is the
	# reset (c:0x6e8c30) -- Dismiss and the pencil drawn 0xff999999 -- and a
	# member's refreshes never touch them again (MEASURED: a member's Dismiss
	# grey). This pane is built when the popup first opens, perhaps already in
	# an academy, so the reset runs here first.
	_reset()
	refresh()

## A control of the pane's own layout (its sections), not inside a row.
func node(control_name: String) -> Control:
	if _pane == null:
		return null
	# The pane holds the Create section; the extra sections (NotifySubBox,
	# NotifyContents) are built inside it (HudMainPopup.build).
	for root in _pane.get_children():
		var n := root.get_node_or_null(control_name) as Control
		if n != null:
			return n
		for sub in root.get_children():
			if sub.name == "NotifySubBox" or sub.name == "NotifyContents":
				n = sub.get_node_or_null(control_name) as Control
				if n != null:
					return n
	return null

func row(i: int) -> Control:
	return _rows[i] if i >= 0 and i < _rows.size() else null

func row_node(i: int, control_name: String) -> Control:
	var r := row(i)
	if r == null:
		return null
	var holder := r.get_node_or_null("AcademySlot")
	return holder.get_node_or_null(control_name) as Control if holder != null else null

## The member shown on row i, or null.
func row_member(i: int) -> AcademyNet.Member:
	return _row_members[i] as AcademyNet.Member if i >= 0 and i < SLOTS else null

func _build_rows() -> void:
	var layout: UiLayoutParser.LayoutDef = _builder.load_layout(SLOT_LAYOUT) if _builder != null else null
	for i in SLOTS:
		var slot := node("GDR_APPRENTICESHIP_SLOT_%d" % i)
		_rows.append(slot)
		if slot == null or layout == null:
			continue
		var built := _builder.build_section(layout, "Create")
		if built == null:
			continue
		built.name = "AcademySlot"
		slot.add_child(built)
		UiBuilder.settle_authored_rects(built)
		var btn := built.get_node_or_null("GDR_APPRENTICESHIPSLOT_BTN_EXITFROMAPPRENTICESHIP") as BaseButton
		if btn != null:
			btn.pressed.connect(press_row.bind(i))
		_add_face(built.get_node_or_null("GDR_APPRENTICESHIPSLOT_PICTURE") as Control, "row%d" % i)
		built.visible = false
	_add_face(node("GDR_APPRENTICESHIP_PICTURE"), "leader")

func _wire_buttons() -> void:
	var dismiss := node("GDR_APPRENTICESHIP_DISSOLVE_APPRENTICESHIP_BTN") as BaseButton
	if dismiss != null:
		dismiss.pressed.connect(press_dismiss)
		# Create sets its text (UIIT_STT_PARTY_DISSOLVE).
		_set_button_text(dismiss, _text("UIIT_STT_PARTY_DISSOLVE", "Dismiss"))
	var invite := node("GDR_APPRENTICESHIP_BTN_INVITE") as BaseButton
	if invite != null:
		invite.pressed.connect(press_invite)
	# Create disables Dismiss and Invite (c:0x6e997a / 0x6e9986, `push ebx`
	# 0 into 0x655ec0), their text colour left as the layout has it.
	_enable(dismiss, false)
	_enable(invite, false)
	var match_b := node("GDR_APPRENTICESHIP_BTN_MATCH") as BaseButton
	if match_b != null:
		match_b.pressed.connect(func() -> void: match_pressed.emit())
	var edit := node("GDR_APPRENTICESHIP_NOTIFY_EDIT_BTN") as BaseButton
	if edit != null:
		edit.pressed.connect(press_notice_edit)
	var subject := node("GDR_APPRENTICESHIP_NOTIFY_SUBJECT")
	if subject != null:
		subject.mouse_filter = Control.MOUSE_FILTER_STOP
		# Round 867: the guild notice bar's art, orange under the pointer.
		AcademyNoticeContents.dress_subject(subject, _builder)
		subject.gui_input.connect(func(ev: InputEvent) -> void:
			var mb := ev as InputEventMouseButton
			if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				press_notice_line())
	var contents := node("GDR_APPRENTICESHIP_NOTIFY_CONTENTS")
	if contents != null:
		contents.visible = false
		var ok := AcademyNoticeContents.build_into(contents, _builder)
		if ok != null:
			ok.pressed.connect(func() -> void: set_notice_open(false))

# --- The buttons ------------------------------------------------------------

## c:0x6e8da0: the guardian's Dismiss opens UIIT_STT_TC_DISSOLUTION.
func press_dismiss() -> void:
	if state.in_academy() and state.am_guardian():
		dismiss_pressed.emit()

## c:0x6e89b0: a selected target and the player the guardian (the flow
## checks the target and sends 0x7472).
func press_invite() -> void:
	if state.in_academy() and state.am_guardian():
		invite_pressed.emit()

## c:0x6e8a90: the guardian's pencil opens the notice writer in academy mode.
func press_notice_edit() -> void:
	if state.in_academy() and state.am_guardian():
		notice_edit_pressed.emit()

## c:0x6e9690: the notice line toggles the contents panel when a title
## exists. Round 867: the original makes the panel anew on each opening
## (0x8b5580 on the NotifyContents section, then 0x70b050), so it opens at its
## first line; the line itself is never drawn selected (its orange is the
## pointer's, AcademyNoticeContents).
func press_notice_line() -> void:
	if state.camp == null or state.camp.notice_title == "":
		return
	set_notice_open(not notice_open)

func set_notice_open(on: bool) -> void:
	notice_open = on
	var contents := node("GDR_APPRENTICESHIP_NOTIFY_CONTENTS")
	if contents != null:
		contents.visible = on
		if on:
			AcademyNoticeContents.scroll_to_top(contents)

## c:0x6eb0f0: a row's button by the viewer and the member's eligibility.
func press_row(i: int) -> void:
	var m := row_member(i)
	if m == null or not state.in_academy():
		return
	var act := row_action(m)
	if act != "":
		row_pressed.emit(act, m.name)

## The row button's action for `m` as the player sees it, "" when the button
## is disabled.
func row_action(m: AcademyNet.Member) -> String:
	if state.am_guardian():
		if m.member_class == AcademyNet.CLASS_GUARDIAN:
			return ""
		return ACT_GRADUATE_MEMBER if forced_graduation_ok(m) else ACT_BAN
	if m.name != state._me():
		return ""
	if m.member_class == AcademyNet.CLASS_APPRENTICE and m.max_level >= 40:
		return ACT_JUDGE
	if m.member_class == AcademyNet.CLASS_ASSISTANT and m.max_level >= 60:
		return ACT_GRADUATE_ASSISTANT
	return ACT_LEAVE

## The guardian's Graduate: an apprentice's stored max level > 40, an
## assistant's > 60 (c:0x6ead69).
static func forced_graduation_ok(m: AcademyNet.Member) -> bool:
	return (m.member_class == AcademyNet.CLASS_APPRENTICE and m.max_level > 40) \
		or (m.member_class == AcademyNet.CLASS_ASSISTANT and m.max_level > 60)

## The member's own Graduate: >= 40 / >= 60 (c:0x6ead69).
static func self_graduation_ok(m: AcademyNet.Member) -> bool:
	return (m.member_class == AcademyNet.CLASS_APPRENTICE and m.max_level >= 40) \
		or (m.member_class == AcademyNet.CLASS_ASSISTANT and m.max_level >= 60)

# --- The refresh --------------------------------------------------------------

func refresh() -> void:
	if _pane == null:
		return
	for i in SLOTS:
		_clear_row(i)
	if not state.in_academy():
		_reset()
		return
	var guardian_view := state.am_guardian()
	# c:0x6e9bf8..0x6e9c90: only the guardian's refresh touches Dismiss,
	# Invite and the pencil (each shown, enabled and drawn 0xfffff5da); a
	# member's leaves them as Create and the reset left them (round 865 stage
	# 3: a member's Invite kept the layout's text colour, MEASURED 230,230,230,
	# where this drew it 0xff999999).
	if guardian_view:
		for n in ["GDR_APPRENTICESHIP_DISSOLVE_APPRENTICESHIP_BTN", "GDR_APPRENTICESHIP_BTN_INVITE",
				"GDR_APPRENTICESHIP_NOTIFY_EDIT_BTN"]:
			var b := node(n)
			_shown(b, true)
			_enable(b, true)
			_color(b, COLOR_BUTTON)
	# The notice line and the contents panel.
	var title := state.camp.notice_title
	AcademyNoticeContents.set_subject(node("GDR_APPRENTICESHIP_NOTIFY_SUBJECT"),
		title if title != "" else _text("UIIT_MSG_GUILD_COMMON_NOTEXIST", "You have no notes."), _builder)
	AcademyNoticeContents.set_content(node("GDR_APPRENTICESHIP_NOTIFY_CONTENTS"), state.camp.notice_content)
	if title == "" and notice_open:
		set_notice_open(false)
	var g := state.guardian()
	if g != null:
		var name_l := node("GDR_APPRENTICESHIP_STATIC_NAME")
		_set_text(name_l, g.name)
		_color(name_l, COLOR_GUARDIAN)
		_shown(name_l, true)
		var mark := node("GDR_APPRENTICESHIP_LEADER_RANK_MARK")
		_texture(mark, HONOR_ART % state.camp.rank)
		_shown(mark, true)
		var rank_l := node("GDR_APPRENTICESHIP_STATIC_RANK_NAME")
		if g.grade == 7:
			_set_text(rank_l, _text("UIIT_STT_TC_GUARDIAN", "Guardian"))
			_shown(rank_l, true)
		_shown(node("GDR_APPRENTICESHIP_STATIC_LEVEL"), true)
		_set_text(node("GDR_APPRENTICESHIP_STATIC_LEVEL_DATA"), "%d(%d)" % [g.cur_level, g.max_level])
		_shown(node("GDR_APPRENTICESHIP_STATIC_LEVEL_DATA"), true)
		_shown(node("GDR_APPRENTICESHIP_PICTURE"), true)
		_face("leader", g)
		_texture(node("GDR_APPRENTICESHIP_LEADER_STATUS"), NO_FACE if g.play_state == AcademyNet.OFFLINE else "")
	var asst := state.of_class(AcademyNet.CLASS_ASSISTANT)
	for i in mini(asst.size(), APPRENTICE_FIRST):
		_fill_row(i, asst[i])
	var appr := state.of_class(AcademyNet.CLASS_APPRENTICE)
	for i in mini(appr.size(), SLOTS - APPRENTICE_FIRST):
		_fill_row(APPRENTICE_FIRST + i, appr[i])

## c:0x6e8c30, as its writes run (round 865 stage 3, READ in the
## disassembly): Matching (0x16) enabled; the pencil (+0x3b0) drawn
## 0xff999999; Invite (+0x3ac) disabled; the pencil drawn 0xff999999 again
## (0x6e8c70 colours +0x3b0 where Invite's colour would go, so Invite keeps
## its layout colour -- MEASURED 230,230,230 on a member's view); the pencil
## disabled; Dismiss (+0x3a8) drawn 0xff999999 and not disabled here (Create
## disabled it; after a guardian's refresh enabled it, it stays enabled,
## grey, and its click does nothing outside a guardian's academy).
func _reset() -> void:
	_enable(node("GDR_APPRENTICESHIP_BTN_MATCH"), true)
	_color(node("GDR_APPRENTICESHIP_NOTIFY_EDIT_BTN"), COLOR_GREY)
	_enable(node("GDR_APPRENTICESHIP_BTN_INVITE"), false)
	_enable(node("GDR_APPRENTICESHIP_NOTIFY_EDIT_BTN"), false)
	_color(node("GDR_APPRENTICESHIP_DISSOLVE_APPRENTICESHIP_BTN"), COLOR_GREY)
	for n in ["GDR_APPRENTICESHIP_STATIC_LEVEL", "GDR_APPRENTICESHIP_STATIC_LEVEL_DATA",
			"GDR_APPRENTICESHIP_LEADER_RANK_MARK", "GDR_APPRENTICESHIP_STATIC_RANK_NAME",
			"GDR_APPRENTICESHIP_STATIC_NAME", "GDR_APPRENTICESHIP_PICTURE"]:
		_shown(node(n), false)
	AcademyNoticeContents.set_subject(node("GDR_APPRENTICESHIP_NOTIFY_SUBJECT"), "", _builder)
	_texture(node("GDR_APPRENTICESHIP_LEADER_STATUS"), "")
	if notice_open:
		set_notice_open(false)
	_face("leader", null)

func _fill_row(i: int, m: AcademyNet.Member) -> void:
	var r := row(i)
	if r == null:
		return
	_row_members[i] = m
	var holder := r.get_node_or_null("AcademySlot") as Control
	if holder != null:
		holder.visible = true
	_set_text(row_node(i, "GDR_APPRENTICESHIPSLOT_STATIC_NAME"), m.name)
	_set_text(row_node(i, "GDR_APPRENTICESHIPSLOT_STATIC_LEVEL_DATA"), "%d(%d)" % [m.cur_level, m.max_level])
	var title_key: String = AcademyNet.GRADE_TITLES.get(m.grade, "")
	_set_text(row_node(i, "GDR_APPRENTICESHIPSLOT_STATIC_RANK_NAME"), _text(title_key, title_key) if title_key != "" else "")
	_texture(row_node(i, "GDR_APPRENTICESHIPSLOT_STATIC_RANK_MARK"), GRADE_ART % m.grade if m.grade > 0 else "")
	_texture(row_node(i, "GDR_APPRENTICESHIP_STATUS"), NO_FACE if m.play_state == AcademyNet.OFFLINE else "")
	var btn := row_node(i, "GDR_APPRENTICESHIPSLOT_BTN_EXITFROMAPPRENTICESHIP")
	var act := row_action(m)
	var label := ""
	match act:
		ACT_GRADUATE_MEMBER, ACT_JUDGE, ACT_GRADUATE_ASSISTANT:
			label = _text("UIIT_CTL_TC_GRADUATION", "Graduate")
		ACT_BAN:
			label = _text("UIIT_CTL_BAN_PARTY", "Banish")
		ACT_LEAVE:
			label = _text("UIIT_CTL_LEAVE_PARTY", "Leave")
	# c:0x6ead69..0x6eaeec: the guardian's view and the member's own row set
	# the text, draw it 0xfffff5da and show the button (+0x5c(1)); another
	# member's row on a member's view hides it (+0x5c(0) at 0x6eaee7 with 0).
	# Round 865 stage 3: it was drawn disabled; MEASURED hidden.
	_set_button_text(btn, label)
	_enable(btn, act != "")
	_color(btn, COLOR_BUTTON)
	_shown(btn, act != "")
	_face("row%d" % i, m)

## 0x6eaa10: an empty slot shows only its own art.
func _clear_row(i: int) -> void:
	_row_members[i] = null
	var r := row(i)
	if r == null:
		return
	var holder := r.get_node_or_null("AcademySlot") as Control
	if holder != null:
		holder.visible = false
	_face("row%d" % i, null)

# --- The faces (the 3D heads, CIFStaticWithPictureClip through pt_face.ddj) ----

func _add_face(pic: Control, key: String) -> void:
	if pic == null:
		return
	var view := TextureRect.new()
	view.name = "FaceView"
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_SCALE
	view.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = HudPartyPane.FACE_SHADER
	mat.shader = sh
	if _builder != null:
		mat.set_shader_parameter("mask_tex", _builder.load_texture(HudPartyPane.FACE_MASK))
	view.material = mat
	view.visible = false
	pic.add_child(view)
	_views[key] = view

func _face(key: String, m: AcademyNet.Member) -> void:
	var view := _views.get(key) as TextureRect
	if view == null:
		return
	var tex: Texture2D = null
	if m != null:
		if m.name == state._me() and own_portrait.is_valid():
			tex = own_portrait.call()
		elif portrait_of.is_valid():
			tex = portrait_of.call(m)
	view.texture = tex
	view.visible = tex != null

# --- Small helpers ---------------------------------------------------------------

func _text(key: String, fallback: String) -> String:
	if _builder == null or key == "":
		return fallback
	var t := _builder.resolve_text(key)
	return fallback if t == "" or t == key else t

func _set_text(n: Control, text: String) -> void:
	if n == null:
		return
	if _builder != null:
		_builder.set_static_text(n, text)
	elif n is Label:
		(n as Label).text = text

func _set_button_text(n: Control, text: String) -> void:
	if n == null:
		return
	if _builder != null:
		_builder.set_button_text(n, text)
		return
	var l := HudPartyPane._label_of(n)
	if l != null:
		l.text = text

## The text a control shows (tests).
static func text_of(n: Control) -> String:
	var l := HudPartyPane._label_of(n)
	return l.text if l != null else ""

static func _color(n: Control, c: Color) -> void:
	# A button's colour is the original's 0x8b2b70: every state, the disabled
	# one included (UiBuilder.set_caption_color).
	if n is BaseButton and n.get_node_or_null("ButtonLabel") != null:
		UiBuilder.set_caption_color(n as BaseButton, c)
		return
	HudPartyPane._color(n, c)

static func _enable(n: Control, on: bool) -> void:
	if n is BaseButton:
		(n as BaseButton).disabled = not on

static func _shown(n: Control, on: bool) -> void:
	if n != null:
		n.visible = on

## A static's picture (its own art or a child picture when it has none).
func _texture(n: Control, ddj: String) -> void:
	if n == null:
		return
	var tex: Texture2D = _builder.load_texture(ddj) if _builder != null and ddj != "" else null
	if n is TextureRect:
		(n as TextureRect).texture = tex
		return
	var pic := n.get_node_or_null("Art") as TextureRect
	if pic == null:
		pic = TextureRect.new()
		pic.name = "Art"
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP
		n.add_child(pic)
	pic.texture = tex
	pic.size = tex.get_size() if tex != null else Vector2.ZERO
	pic.set_meta("ddj", ddj)

## The art a static shows ("" for none; tests).
static func art_of(n: Control) -> String:
	if n == null:
		return ""
	var pic := n.get_node_or_null("Art")
	return String(pic.get_meta("ddj", "")) if pic != null else ""
