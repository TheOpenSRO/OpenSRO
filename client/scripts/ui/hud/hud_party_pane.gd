extends RefCounted
class_name HudPartyPane

## The party window's pane (round 711, lane C1): CIFParty, `resinfo\ifparty.txt`,
## the GDR_PARTY pane of the main popup (HudMainPopup builds the layout). This
## fills it from the client's party state (PartyState) the way the client's
## two refreshes do, and turns its buttons into party requests.
##
## Every rule below is READ from sro_client.exe unless it says otherwise; the
## addresses and the evidence are in docs/protocol/party_gui.md §1:
##
## - in a party, IFParty::FUN_006d6640: the leader row (name, `Lv`, level,
##   race from the model, guild, HP/MP), the seven member rows
##   (FUN_006d7680), the type line in (240,217,165), Dismiss for the leader;
## - out of one, UI_NO::FUN_006d6d00: `<No party leader>` centred, `<No
##   guild>`, full disabled gauges, the type line in (167,155,122), Dismiss
##   off, every row cleared (FUN_006d7520);
## - the caption: UIIT_STT_PARTY_INFO, plus " (" UIIT_STT_PARTY_JOIN_ANYONE ")"
##   when "anyone may invite" is set (0x6d5ef0);
## - the buttons (message map 0xeb91f8): Invite 0x6d5970, Set 0x6d6620, Party
##   match 0x6d59f0, Dismiss 0x6d5a00 (= leave), row buttons 0x6d5a40.
##
## The member rows are CIFPartySlots that load `resinfo\ifpartyslot.txt` into
## themselves (CIFPartySlot::Create 0x6d7be0); this builds that layout into
## each GDR_PTY_PARTYSLOT_n.

const PANE := "GDR_PARTY"
const SLOT_LAYOUT := "resinfo\\ifpartyslot.txt"
const ROWS := 7

## The client's colours (ARGB constants in the two refreshes).
const COLOR_TYPE_IN := Color8(240, 217, 165)       ## 0xfff0d9a5
const COLOR_TYPE_OUT := Color8(167, 155, 122)      ## 0xffa79b7a
const COLOR_NAME_IN := Color8(255, 225, 148)       ## 0xffffe194 (leader name, guild)
const COLOR_GREY := Color8(153, 153, 153)          ## 0xff999999 (<No guild>, disabled button text)
const COLOR_BUTTON := Color8(255, 245, 218)        ## 0xfffff5da (enabled Dismiss / Banish)
const COLOR_ROW_NAME := Color8(255, 255, 255)      ## the row's name, white (0x6d782e)
const COLOR_ROW_GUILD := Color8(255, 255, 255)     ## a row's guild, white (0x6d7a0c / 0x6d7a5b)

const HP_ART := "interface\\party\\pt_hp.ddj"
const MP_ART := "interface\\party\\pt_mp.ddj"
const HP_ART_OFF := "interface\\party\\pt_hp_disable.ddj"
const MP_ART_OFF := "interface\\party\\pt_mp_disable.ddj"
## The race mark's art by the model's race byte (+0x9c): 0x98caa0(.., race, 1).
const RACE_ART := ["interface\\ifcommon\\com_kindred_china16.ddj", "interface\\ifcommon\\com_kindred_europe16.ddj"]
## The portrait's round mask (CIFStaticWithPictureClip, `pt_face.ddj`).
const FACE_MASK := "interface\\party\\pt_face.ddj"

signal create_requested(target_world_id: int)
signal invite_requested(target_world_id: int)
signal leave_requested
signal kick_requested(member_jid: int)
signal match_requested
## Set pressed out of a party: open the settings dialog (child 70, 0x6d61e0).
signal settings_requested

var state: PartyState
var _builder: UiBuilder
var _pane: Control
var _rows: Array[Control] = []
var _views := {}

## Injected by the world (each optional; unset means "none"):
## the world id of the selected character to invite -- its owner's for a
## pet or a horse (c:0x81c741..0x81c782) -- or 0 when nothing is selected;
var selected_target: Callable
## a model's race byte (0 China, 1 Europe, -1 unknown -> no mark);
var race_of_model: Callable
## the player's own [hp, hp_max, mp, mp_max] (the leader row and the own
## row draw live values, +0x458/+0x454/+0x45c);
var own_vitals: Callable
## the player's own guild name (0x9870d0 + 0x18), "" for none;
var own_guild: Callable
## the player's portrait texture (the PMI's render, 0x7b5410), or null.
var own_portrait: Callable
## a member's portrait texture by JID -- the member's quick party slot render
## (0x6dab10 -> 0x6d7f30; HudQuickParty.portrait_of, round 715) -- or null.
var member_portrait: Callable

func _init(builder: UiBuilder, pane: Control, party: PartyState) -> void:
	_builder = builder
	_pane = pane
	state = party
	_build_rows()
	_wire_buttons()
	state.changed.connect(refresh)
	state.member_updated.connect(_on_member_updated)
	if _pane != null:
		_pane.visibility_changed.connect(_on_pane_visibility)
	refresh()

## A member's record changed in place (PartyState.member_updated): redrawn
## now while the window shows; a hidden window redraws when it next shows
## (OURS: the client redraws its rows each frame while shown, 0x6d72f0).
var _stale := false

func _on_member_updated(_jid: int) -> void:
	if _pane != null and not _pane.is_visible_in_tree():
		_stale = true
		return
	refresh()

func _on_pane_visibility() -> void:
	if _stale and _pane != null and _pane.is_visible_in_tree():
		_stale = false
		refresh()

## The node `control_name` directly in the pane's own layout (not inside a
## row: ifparty's Dismiss and ifpartyslot's row button share the name
## GDR_PTYSLOT_BTN_EXITFROMPARTY).
func node(control_name: String) -> Control:
	if _pane == null:
		return null
	for root in _pane.get_children():
		var n := root.get_node_or_null(control_name) as Control
		if n != null:
			return n
	return null

func row(i: int) -> Control:
	return _rows[i] if i >= 0 and i < _rows.size() else null

func row_node(i: int, control_name: String) -> Control:
	var r := row(i)
	if r == null:
		return null
	var holder := r.get_node_or_null("PartySlot")
	return holder.get_node_or_null(control_name) as Control if holder != null else null

func _build_rows() -> void:
	var layout: UiLayoutParser.LayoutDef = _builder.load_layout(SLOT_LAYOUT) if _builder != null else null
	for i in ROWS:
		var slot := node("GDR_PTY_PARTYSLOT_%d" % i)
		_rows.append(slot)
		if slot == null or layout == null:
			continue
		var built := _builder.build_section(layout, "Create")
		if built == null:
			continue
		built.name = "PartySlot"
		slot.add_child(built)
		UiBuilder.settle_authored_rects(built)
		var btn := built.get_node_or_null("GDR_PTYSLOT_BTN_EXITFROMPARTY") as BaseButton
		if btn != null:
			btn.pressed.connect(_on_row_button.bind(i))
		_add_face(built.get_node_or_null("GDR_PTYSLOT_PICTURE") as Control, "row%d" % i)
	_add_face(node("GDR_PTY_PICTURE"), "leader")

func _wire_buttons() -> void:
	var invite := node("GDR_PTY_BTN_INVITE") as BaseButton
	if invite != null:
		invite.pressed.connect(press_invite)
	var setb := node("GDR_PTY_BTN_SETTING") as BaseButton
	if setb != null:
		setb.pressed.connect(press_set)
	var match_b := node("GDR_PTY_BTN_MATCH") as BaseButton
	if match_b != null:
		match_b.pressed.connect(func() -> void: match_requested.emit())
	var dismiss := node("GDR_PTYSLOT_BTN_EXITFROMPARTY") as BaseButton
	if dismiss != null:
		dismiss.pressed.connect(press_dismiss)
		# Create sets its text once (UIIT_STT_PARTY_DISSOLVE, 0x6d70e0..).
		_set_button_text(dismiss, _text("UIIT_STT_PARTY_DISSOLVE", "Dismiss"))

# --- The buttons -------------------------------------------------------------

## Invite (0x6d5970): needs a selected target (0x778120 != 0). Out of a party
## it is create-and-invite (0x7060); in one, the leader -- or anyone when the
## party lets anyone invite -- invites (0x7062).
func press_invite() -> void:
	var target: int = int(selected_target.call()) if selected_target.is_valid() else 0
	if target == 0:
		return
	if not state.in_party:
		create_requested.emit(target)
	elif state.is_leader() or state.anyone_invite == 1:
		invite_requested.emit(target)

## Set (0x6d6620): opens the settings dialog only out of a party.
func press_set() -> void:
	if not state.in_party:
		settings_requested.emit()

## Dismiss (0x6d5a00 -> jmp 0x81cad0): leave, in a party.
func press_dismiss() -> void:
	if state.in_party:
		leave_requested.emit()

## A row's button (0x6d5a40): the leader banishes that row's member (list
## index row + 1, its JID), anyone else leaves.
func _on_row_button(i: int) -> void:
	if not state.in_party:
		return
	if state.is_leader():
		var m := state.member_for_row(i)
		if m != null:
			kick_requested.emit(m.jid)
	else:
		leave_requested.emit()

# --- The refresh -------------------------------------------------------------

func refresh() -> void:
	if _pane == null:
		return
	_stale = false
	_refresh_caption()
	if state.in_party:
		_refresh_in_party()
	else:
		_refresh_out_of_party()

## The caption and the type line (0x6d5ef0): the type texts come from the
## settings block, so a player out of a party sees their own preferences.
func _refresh_caption() -> void:
	var frame := node("GDR_PARTY_FRAMEL")
	var cap := UiBuilder.subframe_caption(frame)
	if cap != null:
		var text := _text("UIIT_STT_PARTY_INFO", "Party information")
		if state.anyone_invite == 1:
			text += " (" + _text("UIIT_STT_PARTY_JOIN_ANYONE", "Invitation of party member available") + ")"
		cap.text = text
	_set_text(node("GDR_PTY_OPTION_EXP"),
		_text("UIIT_STT_PARTY_EXP_SHARE" if state.exp_share == 1 else "UIIT_STT_PARTY_EXP_SELF",
			"Exp Auto Share" if state.exp_share == 1 else "Exp Free-For-All"))
	_set_text(node("GDR_PTY_OPTION_ITEM"),
		_text("UIIT_STT_PARTY_ITEM_SHARE" if state.item_share == 1 else "UIIT_STT_PARTY_ITEM_SELF",
			"Item Auto Share" if state.item_share == 1 else "Item Free-For-All"))

func _refresh_out_of_party() -> void:
	var type_color := COLOR_TYPE_OUT
	for n in ["GDR_PTY_OPTION_EXP", "GDR_PTY_OPTION_ITEM"]:
		_color(node(n), type_color)
	for n in ["GDR_PTY_OPTION_EXP_DECO", "GDR_PTY_OPTION_ITEM_DECO"]:
		var deco := node(n) as CanvasItem
		if deco != null:
			deco.modulate = type_color
	_enable(node("GDR_PTY_BTN_SETTING"), true)
	_enable(node("GDR_PTY_BTN_INVITE"), true)
	_shown(node("GDR_PTY_PARTY_LEADER"), false)
	_shown(node("GDR_PTY_PARTY_LEADER_RACE_MARK"), false)
	_shown(node("GDR_PTY_STATIC_LEVEL"), false)
	_shown(node("GDR_PTY_STATIC_LEVEL_DATA"), false)
	var name_l := node("GDR_PTY_STATIC_NAME") as Label
	if name_l != null:
		name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_set_text(name_l, _text("UIIT_STT_NO_PARTY_LEADER", "<Party leader doesn't exist>"))
	_color(name_l, COLOR_TYPE_OUT)
	_set_text(node("GDR_PTY_STATIC_GUILD"), _text("UIIT_STT_NO_GUILD", "<No guild>"))
	_color(node("GDR_PTY_STATIC_GUILD"), COLOR_TYPE_OUT)
	_shown(node("GDR_PTY_PICTURE"), false)
	_gauge(node("GDR_PTY_GAUGE_HPGAUGE"), 1.0, HP_ART_OFF)
	_gauge(node("GDR_PTY_GAUGE_MPGAUGE"), 1.0, MP_ART_OFF)
	var dismiss := node("GDR_PTYSLOT_BTN_EXITFROMPARTY")
	_button_color(dismiss, COLOR_GREY)
	_enable(dismiss, false)
	for i in ROWS:
		_clear_row(i)

func _refresh_in_party() -> void:
	_shown(node("GDR_PTY_PARTY_LEADER"), true)
	_shown(node("GDR_PTY_PARTY_LEADER_RACE_MARK"), true)
	for n in ["GDR_PTY_OPTION_EXP", "GDR_PTY_OPTION_ITEM"]:
		_color(node(n), COLOR_TYPE_IN)
	for n in ["GDR_PTY_OPTION_EXP_DECO", "GDR_PTY_OPTION_ITEM_DECO"]:
		var deco := node(n) as CanvasItem
		if deco != null:
			deco.modulate = COLOR_TYPE_IN
	var dismiss := node("GDR_PTYSLOT_BTN_EXITFROMPARTY")
	if state.is_leader():
		_enable(dismiss, true)
		_button_color(dismiss, COLOR_BUTTON)
		_enable(node("GDR_PTY_BTN_INVITE"), true)
	else:
		_enable(dismiss, false)
		_enable(node("GDR_PTY_BTN_INVITE"), state.anyone_invite == 1)
	_enable(node("GDR_PTY_BTN_SETTING"), false)
	var lead := state.leader()
	if lead == null:
		# 0x6d67c6: no leader record -- the rest of the refresh is skipped.
		return
	_set_text(node("GDR_PTY_STATIC_LEVEL_DATA"), "%d" % lead.level)
	_race_mark(node("GDR_PTY_PARTY_LEADER_RACE_MARK"), lead.ref_obj_id)
	var name_l := node("GDR_PTY_STATIC_NAME") as Label
	if name_l != null:
		name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_color(name_l, COLOR_NAME_IN)
	_set_text(name_l, ("*%s" if state.job_party else "%s") % lead.member_name)
	_shown(node("GDR_PTY_PICTURE"), true)
	_shown(node("GDR_PTY_STATIC_LEVEL"), true)
	_shown(node("GDR_PTY_STATIC_LEVEL_DATA"), true)
	_guild(node("GDR_PTY_STATIC_GUILD"), lead, COLOR_NAME_IN)
	if lead.jid == state.own_jid:
		var v := _own_vitals()
		_gauge(node("GDR_PTY_GAUGE_HPGAUGE"), v[0], HP_ART)
		_gauge(node("GDR_PTY_GAUGE_MPGAUGE"), v[1], MP_ART)
	else:
		_gauge(node("GDR_PTY_GAUGE_HPGAUGE"), lead.hp_ratio(), HP_ART)
		_gauge(node("GDR_PTY_GAUGE_MPGAUGE"), lead.mp_ratio(), MP_ART)
	_face("leader", lead.jid == state.own_jid, lead.jid)
	var others := state.row_members()
	for i in ROWS:
		if i < others.size():
			_fill_row(i, others[i])
		else:
			_clear_row(i)

## FUN_006d7680: one member's row.
func _fill_row(i: int, m: PartyNet.Member) -> void:
	var r := row(i)
	if r == null:
		return
	var holder := r.get_node_or_null("PartySlot") as Control
	if holder != null:
		holder.visible = true
	var name_l := row_node(i, "GDR_PTYSLOT_STATIC_NAME")
	_set_text(name_l, ("*%s" if state.job_party else "%s") % m.member_name)
	_color(name_l, COLOR_ROW_NAME)
	_shown(row_node(i, "GDR_PTYSLOT_STATIC_LEVEL"), true)
	_set_text(row_node(i, "GDR_PTYSLOT_STATIC_LEVEL_DATA"), "%d" % m.level)
	_shown(row_node(i, "GDR_PTYSLOT_STATIC_LEVEL_DATA"), true)
	_race_mark(row_node(i, "GDR_PTYSLOT_RACE"), m.ref_obj_id)
	_guild(row_node(i, "GDR_PTYSLOT_STATIC_GUILD"), m, COLOR_ROW_GUILD)
	_shown(row_node(i, "GDR_PTYSLOT_STATIC_GUILD_STATIC"), true)
	var own := m.jid == state.own_jid
	if own:
		var v := _own_vitals()
		_gauge(row_node(i, "GDR_PTYSLOT_GAUGE_HPGAUGE"), v[0], HP_ART)
		_gauge(row_node(i, "GDR_PTYSLOT_GAUGE_MPGAUGE"), v[1], MP_ART)
	else:
		_gauge(row_node(i, "GDR_PTYSLOT_GAUGE_HPGAUGE"), m.hp_ratio(), HP_ART)
		_gauge(row_node(i, "GDR_PTYSLOT_GAUGE_MPGAUGE"), m.mp_ratio(), MP_ART)
	# The button: Banish on every row for the leader, Leave on the player's
	# own row otherwise, hidden elsewhere.
	var btn := row_node(i, "GDR_PTYSLOT_BTN_EXITFROMPARTY")
	if state.is_leader():
		_shown(btn, true)
		_set_button_text(btn, _text("UIIT_CTL_BAN_PARTY", "Banish"))
		_button_color(btn, COLOR_BUTTON)
	elif own:
		# 0x6d78a7 jumps into Banish's path (0x6d7881): the same colour.
		_shown(btn, true)
		_set_button_text(btn, _text("UIIT_CTL_LEAVE_PARTY", "Leave"))
		_button_color(btn, COLOR_BUTTON)
	else:
		_shown(btn, false)
	_shown(row_node(i, "GDR_PTYSLOT_PICTURE"), true)
	_face("row%d" % i, own, m.jid)

## FUN_006d7520: an empty row.
func _clear_row(i: int) -> void:
	var r := row(i)
	if r == null:
		return
	var holder := r.get_node_or_null("PartySlot") as Control
	if holder != null:
		holder.visible = false

## A member's guild (0x6d6640 / 0x6d7680): a job-mode party hides every guild
## (grey <No guild>); the player's own row shows the player's own guild;
## otherwise the member's guild string, or a grey <No guild> when empty. A
## guild is (255,225,148) on the leader row and white on a member row.
func _guild(n: Control, m: PartyNet.Member, color: Color) -> void:
	var guild := m.guild
	if m.jid == state.own_jid and own_guild.is_valid():
		guild = String(own_guild.call())
	if state.job_party or guild == "":
		_set_text(n, _text("UIIT_STT_NO_GUILD", "<No guild>"))
		_color(n, COLOR_GREY)
	else:
		_set_text(n, guild)
		_color(n, color)

func _race_mark(n: Control, ref_obj_id: int) -> void:
	var mark := n as TextureRect
	var race: int = int(race_of_model.call(ref_obj_id)) if race_of_model.is_valid() else -1
	if race < 0 or race >= RACE_ART.size():
		# The table has no row for the model: no mark rather than a guessed one.
		_shown(n, false)
		return
	_shown(n, true)
	if mark != null and _builder != null:
		mark.texture = _builder.load_texture(RACE_ART[race])
	elif n != null and _builder != null:
		# GDR_PTYSLOT_RACE is authored without art: give it a picture child.
		var pic := n.get_node_or_null("RaceArt") as TextureRect
		if pic == null:
			pic = TextureRect.new()
			pic.name = "RaceArt"
			pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
			pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			pic.size = Vector2(16, 16)
			n.add_child(pic)
		pic.texture = _builder.load_texture(RACE_ART[race])

## The player's own bars, live: CIFPartySlot's per-frame 0x6d72f0 redraws the
## player's own row from the player's HP/MP (0x6d7302..0x6d73c7), and
## CIFParty's 0x6d5ca0 the leader row when the player leads (0x6d5cdf ->
## 0x987080). Called on every change of the player block's bars (round 711's
## review) -- the same values, without a per-frame walk. Only the gauges.
func refresh_vitals() -> void:
	if _pane == null or not state.in_party or state.own_jid == 0:
		return
	var v := _own_vitals()
	if state.leader_jid == state.own_jid:
		_gauge(node("GDR_PTY_GAUGE_HPGAUGE"), v[0], HP_ART)
		_gauge(node("GDR_PTY_GAUGE_MPGAUGE"), v[1], MP_ART)
	var others := state.row_members()
	for i in mini(ROWS, others.size()):
		if others[i].jid == state.own_jid:
			_gauge(row_node(i, "GDR_PTYSLOT_GAUGE_HPGAUGE"), v[0], HP_ART)
			_gauge(row_node(i, "GDR_PTYSLOT_GAUGE_MPGAUGE"), v[1], MP_ART)

## [hp ratio, mp ratio] of the player's own live values.
func _own_vitals() -> Array:
	if not own_vitals.is_valid():
		return [0.0, 0.0]
	var v: Array = own_vitals.call()
	if v.size() < 4:
		return [0.0, 0.0]
	var hp := clampf(float(v[0]) / float(v[1]), 0.0, 1.0) if float(v[1]) > 0.0 else 0.0
	var mp := clampf(float(v[2]) / float(v[3]), 0.0, 1.0) if float(v[3]) > 0.0 else 0.0
	return [hp, mp]

# --- The portraits -----------------------------------------------------------
#
# The player's own row (and the leader row when the player leads) borrows the
# player block's render (0x7b5410); a member's row borrows that member's
# quick-party slot render (0x6dab10 -> 0x6d7f30) -- HudQuickParty's, through
# member_portrait (round 715). That render is made from the member's model id,
# spawned or not (0x6d80d0); a member with no model id has none and the
# square stays black. (The user's screenshot 12 shows every square black, the
# player's own included, so the picture is not evidence either way: see
# HudQuickParty's header.)

const FACE_SHADER := """
shader_type canvas_item;
// CIFStaticWithPictureClip: colour from the render, alpha from the mask.
uniform sampler2D mask_tex : filter_linear;
varying vec4 modulate;
void vertex() {
	modulate = COLOR;
}
void fragment() {
	COLOR = vec4(texture(TEXTURE, UV).rgb, texture(mask_tex, UV).a) * modulate;
}
"""

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
	sh.code = FACE_SHADER
	mat.shader = sh
	if _builder != null:
		mat.set_shader_parameter("mask_tex", _builder.load_texture(FACE_MASK))
	view.material = mat
	view.visible = false
	pic.add_child(view)
	_views[key] = view

func _face(key: String, own: bool, jid: int = 0) -> void:
	var view := _views.get(key) as TextureRect
	if view == null:
		return
	var tex: Texture2D = null
	if own:
		tex = own_portrait.call() if own_portrait.is_valid() else null
	elif member_portrait.is_valid():
		tex = member_portrait.call(jid)
	view.texture = tex
	view.visible = tex != null

# --- Small helpers -------------------------------------------------------------

func _text(key: String, fallback: String) -> String:
	if _builder == null:
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

static func _label_of(n: Control) -> Label:
	if n is Label:
		return n as Label
	if n == null:
		return null
	var l := n.get_node_or_null("Text") as Label
	return l if l != null else n.get_node_or_null("ButtonLabel") as Label

static func _color(n: Control, c: Color) -> void:
	var l := _label_of(n)
	if l != null:
		l.add_theme_color_override("font_color", c)

func _set_button_text(n: Control, text: String) -> void:
	if n == null:
		return
	if _builder != null:
		_builder.set_button_text(n, text)
		return
	var l := _label_of(n)
	if l != null:
		l.text = text

static func _button_color(n: Control, c: Color) -> void:
	_color(n, c)

static func _enable(n: Control, on: bool) -> void:
	if n is BaseButton:
		(n as BaseButton).disabled = not on

static func _shown(n: Control, on: bool) -> void:
	if n != null:
		n.visible = on

func _gauge(n: Control, ratio: float, art: String) -> void:
	var g := n as TextureProgressBar
	if g == null:
		return
	if _builder != null:
		var tex := _builder.load_texture(art)
		if tex != null:
			g.texture_progress = tex
	g.value = clampf(ratio, 0.0, 1.0) * (g.max_value - g.min_value) + g.min_value
