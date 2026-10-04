extends Control
class_name HudQuickParty

## The party member boxes on the HUD (round 715, lane C3): retail's
## CIFQuickPartyWnd, `GDR_QUICKPARTYBOARD` in ginterface.txt, with one
## CIFQuickPartySlot (`resinfo\ifquickpartyslot.txt`) per member other than
## the player. docs/protocol/party_gui.md §7 has the record; the addresses
## below are sro_client.exe's. Labels: READ (the binary), MEASURED (the
## archives), INFERRED, OURS (this project's choice), OPEN.
##
## THE BOARD (READ, IFQuickPartyWnd::FUN_006dae90, the rebuild):
## - out of a party every slot is destroyed and the board hides
##   (0x6daa50);
## - in one, a slot per member in the party manager's order (0x992380(i)),
##   skipping the player by name (0x47ec20 against the player's name);
## - each slot is a 122x40 child (0x6da110: `mov [esp+0x48],0x7a`,
##   `mov [esp+0x4c],0x28`) drawn with `interface\ifcommon\window_all.ddj`,
##   the atlas slice u 0.723633..0.842773, v 0.138672..0.216797 (the floats
##   at 0xda5438 / 0xda973c and 0xda9740 / 0xda9738, read from the exe):
##   741..863 x 71..111 of the 1024x512 atlas, the round-faced box;
## - slot n sits at (board x + 13 + column x 133, board y + row), the row
##   stepping 73 when the game option byte +0x08 (0x4f9d00 -> settings
##   +0x543) is set and 56 when not (0x6db0e0 / 0x6db0e9);
## - before each slot, when (screen height - board y - row - 73) < 230, a new
##   column starts: column += 133, row = 0 (0x6db04b..0x6db058).
##
## THE LOCK (READ, CIFQuickPartyWnd::vslot_010 0x6db290, UI_QUICKPARTY::
## FUN_006da210, IFQuickPartyWnd::FUN_006da9d0, CIFQuickPartyWnd::
## vslot_028 0x6db5e0): a button moved to (0, -7) with
## `interface\ifcommon\quickparty_move_lock.ddj` -- `_unlock.ddj` while
## reordering is on -- and the tooltip UIIT_STT_QUICKPARTY_MOVE + "\n" +
## UIIT_STT_QUICKPARTY_MOVE_STATE + _LOCK / _UNLOCK. A click flips the state
## and makes every slot draggable; a drop swaps the two members' places in the
## party manager's list (0x992490(jid, jid)) and rebuilds. Shown only while
## the party has more than 2 members (0x6db3f9: `2 < count`). The 20x20 size
## and the screen position (0, 130) are the round-709 spec's (party_gui.md
## §7); the button's move is to (0, -7) of the board's 137.
##
## A SLOT (READ, CIFQuickPartySlot::Create 0x6d8890 and the fill
## IFQuickPartyWnd::FUN_006d9250):
## - the name (GDR_QPS_TXT_ID, SetText of the record's name);
## - the HP and MP gauges from the record's HP/max and MP/max;
## - the leader's red flag (GDR_QPS_PARTY_LEADER) iff the party's leader id
##   is this member's (0x6d7db0);
## - the two mastery icons, new 17x17 children at (-3, 39) and (15, 39), from
##   the record's two mastery ids (0x937010 each; an id with no record hides
##   its icon), with the mastery's name as the tooltip;
## - the 3D portrait (GDR_QPS_PICTURE through the qpt_face.ddj disc): a 64x64
##   BufRender (0x9edae0(0x40, 0x40)) of a model built from the record's
##   model id (+0x38) -- not the spawned body: 0x6d80d0 loads the id into the
##   slot's own animation object, plays ANI_POSE (0x3c) on it and turns it to
##   0.1 rad (the float at 0xe1b7fc) -- re-rendered only when the id changes
##   (the dirty byte +0x3dc, 0x6d7f20) and drawn from "Bip01 Head" with the
##   player mini info's camera (0x6d8bf0: +1.0 on y, yaw 0.2, distance 6.5,
##   30 degrees). So every member has a face whether spawned or not
##   (PlayerPortrait, BODY not dressed: the model id carries no equipment).
##   The user's screenshots 03, 04, 11 and 12 show every disc black --
##   including the player's own block, whose render is certain -- so those
##   frames were taken where the client's BufRender draws nothing (they test
##   under macOS CrossOver); the code, not the pictures, decides here.
##
## THE "FAR AWAY" OVERLAY (READ, CIFQuickPartyWnd::vslot_012 0x6db380 and
## 0x6d86e0), every frame, for each member:
## - the squared distance (0x9ed1e0, region-aware dx² + dy² + dz²) from the
##   player to the member's object when it is spawned in this client
##   (0x9c35e0: its +0x7c region, +0x80/+0x84/+0x88 position), else to the
##   record's last position (+0x5a region, +0x5c x, +0x64 z) at y = 0 -- the
##   record's y is not used (local_8 stays 0);
## - only in an exp-sharing party (the manager's +0x00 == 1) is it stepped:
##   level 5 from 1e6 (a double, 0xda9910), 4 from 810000 (a float,
##   0xda990c), 3 from 640000 (0xda9908), 2 from 490000 (a double, 0xda9900),
##   1 from 360000 (0xda98fc), 0 below; every comparison is `>=`. In any
##   other party the level is 0;
## - the level puts `interface\quickparty\qpt_face_faraway_60/70/80/90/100.ddj`
##   on GDR_QPS_STATUS (level 0 clears it). MEASURED (round 709): each is a
##   28x28 (14,96,255) disc at alpha 130/158/181/211/241 -- five steps, not a
##   fade.
##
## THE CAUTION EFFECTS (READ, CIFQuickPartySlot::vslot_012 0x6d90e0):
## GDR_QPS_EFFECT_HP shows while the HP gauge's ratio is below 0.3 (the float
## at 0xd82f00) and the record's byte +0x58 is 0, then only when the game
## option byte +0x12 is set; EFFECT_MP likewise with +0x13; at faraway level 5
## both are hidden. The effect is an 8-frame sprite (4 x 2 frames of 64x32 in
## a 256x64 sheet, Speed 100, loop -- the layout's own fields); one frame per
## 100 ms is INFERRED from "Speed".
##
## BUFFS (READ, 0x6d9250's tail and 0x6d9010): with game option +0x08 set and
## the member spawned in this client (0x9c35e0), the member's skill objects
## and abnormal-state bits fill GDR_QPS_PARTY_BUFF -- 6 per row
## (0x7fabb0(6)), a 15x15 pitch (0x7fabc0(0xf,0xf)), 12x12 icons
## (0x7fabe0(0xc,0xc)), the target window's viewer calls read in round 638 --
## and a 1000 ms timer (0xb93320(1, 0x3e8)) keeps it live; otherwise the
## viewer is cleared (0x7fbcf0) and the timer killed (0xb93170(1)).
## 0x7fab90(1, 1) is also called; what it sets is OPEN.
##
## SELECTION (READ): the world's SetTarget hands the selected id to the board
## (0x6d9610 -> +0x37c); every frame (0x6db1a0) the slot whose member's
## object is the selected object shows GDR_QPS_SELECT
## (`qpt_grope_select.ddj`, 132x48 at -3,-4, MEASURED teal) and the others
## hide it; a selected object that no longer exists clears them all
## (0x6dac10). A left click on a slot (CIFQuickPartySlot::vslot_030
## 0x6d8500) finds the member's object by the slot's name (0x9c3640), selects
## it when found (0x78f5f0) and plays `prim\snd\ui\uiwinopen.wav` either way.
##
## GAME OPTIONS (OPEN): bytes +0x08 (INFERRED: "Quick Party View Buff Status",
## UIIT_MSG_QUICK_PARTY_CHARACTER_BUFF), +0x12 and +0x13 live in
## Setting\SROptionSet.dat; their defaults with no file are not read and
## OpenSRO has no Game options page for them. OURS: all three on -- the buff
## row and the 73-px step are what the user's screenshots 03 and 04 show.

const REGISTRY_NAME := "GDR_QUICKPARTYBOARD"
## OURS: where the board goes with no ginterface entry (the entry's own 4,137).
const FALLBACK_POSITION := Vector2(4, 137)
const SLOT_LAYOUT := "resinfo\\ifquickpartyslot.txt"
const SLOT_ART := "interface\\ifcommon\\window_all.ddj"
const SLOT_UV_LT := Vector2(0.723633, 0.138672)
const SLOT_UV_RB := Vector2(0.842773, 0.216797)
const SLOT_SIZE := Vector2(122, 40)
const SLOT_X := 13
const COLUMN_STEP := 133
const ROW_STEP_BUFFS := 73
const ROW_STEP := 56
## The wrap test's slot height (always 0x49) and its room (0xe6).
const WRAP_SLOT := 73
const WRAP_ROOM := 230

const LOCK_ART := "interface\\ifcommon\\quickparty_move_lock.ddj"
const UNLOCK_ART := "interface\\ifcommon\\quickparty_move_unlock.ddj"
const LOCK_SIZE := Vector2(20, 20)
const LOCK_OFFSET := Vector2(0, -7)

const FACE_MASK := "interface\\quickparty\\qpt_face.ddj"
const FARAWAY_ART := [
	"",
	"interface\\quickparty\\qpt_face_faraway_60.ddj",
	"interface\\quickparty\\qpt_face_faraway_70.ddj",
	"interface\\quickparty\\qpt_face_faraway_80.ddj",
	"interface\\quickparty\\qpt_face_faraway_90.ddj",
	"interface\\quickparty\\qpt_face_faraway_100.ddj",
]
## The squared thresholds, level 1..5 (READ, see the header).
const FARAWAY_SQ := [360000.0, 490000.0, 640000.0, 810000.0, 1000000.0]
const CAUTION_RATIO := 0.3
const CAUTION_FRAMES := 8
const CAUTION_COLUMNS := 4
const CAUTION_FRAME_MS := 100
const PORTRAIT_BUFFER := 64
const MASTERY_SIZE := Vector2(17, 17)
const MASTERY_POSITIONS := [Vector2(-3, 39), Vector2(15, 39)]
const BUFF_COLUMNS := 6
const BUFF_PITCH := Vector2(15, 15)
const BUFF_ICON := Vector2(12, 12)
const BUFF_REFRESH_MS := 1000
const SELECT_SOUND := "prim\\snd\\ui\\uiwinopen.wav"

## A slot was clicked (0x6d8500): the world selects the member by name when
## they are spawned. The sound is the board's.
signal member_clicked(jid: int, member_name: String)
## The slots were rebuilt (the party window's rows borrow their renders).
signal rebuilt

var state: PartyState
var _builder: UiBuilder
var _layout: UiLayoutParser.LayoutDef
var _slots: Array[QuickSlot] = []
var _lock: TextureButton
## +0x384: reordering unlocked.
var unlocked := false
var _mastery_table: Dictionary = {}
var _mastery_loaded := false
var _last_buff_ms := -BUFF_REFRESH_MS

## The game option bytes (OPEN defaults, OURS on; see the header).
var show_buffs := true
var hp_caution := true
var mp_caution := true

## Injected by the world (each optional):
## the player's name (the rebuild skips the member who has it);
var own_name: Callable
## the player's world position (Vector3);
var player_position: Callable
## the player's region and region-local position: {region: Vector2i(x, y),
## local: Vector3}, or {} when unknown;
var player_region_local: Callable
## a member's spawned body (Node3D) by JID, or null;
var member_body: Callable
## the JID of the selected object when it is a spawned player, else 0;
var selected_jid: Callable
## a bare body for a model id: [Skeleton3D, BanReader.ParsedAnimation or
## null], or [] when it cannot be built;
var portrait_body: Callable
## a member's buffs as viewer entries ({skill_id, token, level}) by JID;
var buffs_of: Callable
## the skill catalog the buff viewers read (the buff bar's).
var buff_catalog: SkillBuffCatalog
## the screen height the wrap test uses (0x4f9cd0 + 0x28); the parent's
## height when unset.
var screen_height: Callable
## Played on a slot click; tests replace it.
var play_sound: Callable = func(path: String) -> void: SoundTable.play_file(path)

## One member's box.
class QuickSlot extends Control:
	var board: HudQuickParty
	var jid := 0
	var member_name := ""
	var model_id := 0
	var faraway := 0
	var built: Control
	var portrait: PlayerPortrait
	var face: TextureRect
	var status: TextureRect
	var select_glow: Control
	var leader_flag: Control
	var hp_gauge: TextureProgressBar
	var mp_gauge: TextureProgressBar
	var hp_effect: TextureRect
	var mp_effect: TextureRect
	var name_label: Label
	var masteries: Array[TextureRect] = []
	var buffs: HudTargetBuffs
	## +0x58 of the record (OPEN meaning; OpenSRO never sets it).
	var record_58 := 0
	var hp_ratio := 0.0
	var mp_ratio := 0.0

	func _gui_input(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			accept_event()
			board.click_slot(self)

	func _get_drag_data(_at: Vector2) -> Variant:
		if board == null or not board.unlocked:
			return null
		return {"quick_party_jid": jid}

	func _can_drop_data(_at: Vector2, data: Variant) -> bool:
		return board != null and board.unlocked and data is Dictionary \
			and (data as Dictionary).has("quick_party_jid") and int(data["quick_party_jid"]) != jid

	func _drop_data(_at: Vector2, data: Variant) -> void:
		board.swap_members(int(data["quick_party_jid"]), jid)

func _init(builder: UiBuilder = null, party: PartyState = null) -> void:
	_builder = builder
	state = party
	name = "HudQuickParty"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

## Places the board by its ginterface entry, builds the lock, and follows the
## party. Safe without an archive (no slots then).
func setup() -> void:
	var at := FALLBACK_POSITION
	if _builder != null:
		var reg := _builder.window_def(REGISTRY_NAME)
		if reg != null:
			at = Vector2(reg.rect.position)
		_layout = _builder.load_layout(SLOT_LAYOUT)
	position = at
	_build_lock()
	if state != null and not state.changed.is_connected(rebuild):
		state.changed.connect(rebuild)
	rebuild()

func _build_lock() -> void:
	_lock = TextureButton.new()
	_lock.name = "QuickPartyLock"
	_lock.ignore_texture_size = true
	_lock.stretch_mode = TextureButton.STRETCH_SCALE
	_lock.size = LOCK_SIZE
	_lock.custom_minimum_size = LOCK_SIZE
	_lock.position = Vector2(-position.x, 0.0) + LOCK_OFFSET
	_lock.visible = false
	_lock.pressed.connect(toggle_lock)
	add_child(_lock)
	_lock_art()

func _lock_art() -> void:
	if _lock == null:
		return
	var art := UNLOCK_ART if unlocked else LOCK_ART
	if _builder != null:
		_lock.texture_normal = _builder.load_texture(art)
		_lock.texture_hover = _builder.load_texture(art.replace(".ddj", "_focus.ddj"))
		_lock.texture_pressed = _builder.load_texture(art.replace(".ddj", "_press.ddj"))
		_lock.texture_disabled = _builder.load_texture(art.replace(".ddj", "_disable.ddj"))
	_lock.tooltip_text = "%s\n%s%s" % [_text("UIIT_STT_QUICKPARTY_MOVE", "Move"),
		_text("UIIT_STT_QUICKPARTY_MOVE_STATE", ""),
		_text("UIIT_STT_QUICKPARTY_MOVE_UNLOCK" if unlocked else "UIIT_STT_QUICKPARTY_MOVE_LOCK", "")]

## The lock's click (0x6da9d0): flip, re-art, and every slot drags or not.
func toggle_lock() -> void:
	unlocked = not unlocked
	_lock_art()
	for s in _slots:
		s.mouse_default_cursor_shape = Control.CURSOR_MOVE if unlocked else Control.CURSOR_ARROW

## The drop (vslot_028): the two members trade places in the manager's list,
## then the board is rebuilt.
func swap_members(a_jid: int, b_jid: int) -> void:
	if state == null or a_jid == b_jid:
		return
	var ia := -1
	var ib := -1
	for i in state.members.size():
		if state.members[i].jid == a_jid:
			ia = i
		elif state.members[i].jid == b_jid:
			ib = i
	if ia < 0 or ib < 0:
		return
	var t := state.members[ia]
	state.members[ia] = state.members[ib]
	state.members[ib] = t
	rebuild()

## The members shown, in order: the manager's list less the player -- by
## name, as 0x47ec20 compares (`own_name`), and by JID as well, so a name not
## yet known cannot put the player in a box.
func shown_members() -> Array[PartyNet.Member]:
	var out: Array[PartyNet.Member] = []
	if state == null or not state.in_party:
		return out
	var me: String = String(own_name.call()) if own_name.is_valid() else ""
	for m in state.members:
		if m.jid == state.own_jid and state.own_jid != 0:
			continue
		if me != "" and m.member_name == me:
			continue
		out.append(m)
	return out

## The row step (option +0x08).
func row_step() -> int:
	return ROW_STEP_BUFFS if show_buffs else ROW_STEP

## Slot i's position relative to the board, for `count` slots under a screen
## `height` tall, board at `board_y` (0x6db04b..0x6db07c).
static func slot_positions(count: int, height: float, board_y: float, step: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var column := 0
	var row := 0
	for i in count:
		if (height - board_y - row - WRAP_SLOT) < WRAP_ROOM:
			column += COLUMN_STEP
			row = 0
		out.append(Vector2(SLOT_X + column, row))
		row += step
	return out

func _screen_height() -> float:
	if screen_height.is_valid():
		return float(screen_height.call())
	var p := get_parent() as Control
	if p != null and p.size.y > 0.0:
		return p.size.y
	return get_viewport_rect().size.y if is_inside_tree() else 768.0

## FUN_006dae90: every slot rebuilt for the party as it stands.
func rebuild() -> void:
	var members := shown_members()
	visible = state != null and state.in_party
	# Slots are reused in order (the portrait survives a rebuild while the
	# model id is the same, as retail's slot keeps its +0x3d0).
	while _slots.size() > members.size():
		var s: QuickSlot = _slots.pop_back()
		remove_child(s)
		s.queue_free()
	while _slots.size() < members.size():
		_slots.append(_make_slot())
	var at := slot_positions(members.size(), _screen_height(), position.y, row_step())
	for i in members.size():
		var s := _slots[i]
		s.position = at[i]
		_fill(s, members[i])
	if _lock != null:
		_lock.visible = state != null and state.in_party and state.members.size() > 2
		if not _lock.visible:
			unlocked = false
			_lock_art()
	_last_buff_ms = -BUFF_REFRESH_MS
	_refresh_buffs()
	rebuilt.emit()

func _make_slot() -> QuickSlot:
	var s := QuickSlot.new()
	s.board = self
	s.name = "QuickPartySlot%d" % _slots.size()
	s.size = SLOT_SIZE
	s.custom_minimum_size = SLOT_SIZE
	s.mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := TextureRect.new()
	bg.name = "Background"
	bg.size = SLOT_SIZE
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _builder != null:
		bg.texture = _builder.load_texture_region(SLOT_ART, SLOT_UV_LT, SLOT_UV_RB)
	s.add_child(bg)
	if _builder != null and _layout != null:
		s.built = _builder.build_section(_layout, "Create")
	if s.built == null:
		s.built = Control.new()
	s.built.name = "Slot"
	s.built.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.add_child(s.built)
	UiBuilder.settle_authored_rects(s.built)
	_ignore_mouse(s.built)
	s.name_label = _label(s.built.get_node_or_null("GDR_QPS_TXT_ID"))
	s.hp_gauge = s.built.get_node_or_null("GDR_QPS_GAUGE_HP") as TextureProgressBar
	s.mp_gauge = s.built.get_node_or_null("GDR_QPS_GAUGE_MP") as TextureProgressBar
	s.leader_flag = s.built.get_node_or_null("GDR_QPS_PARTY_LEADER") as Control
	s.select_glow = s.built.get_node_or_null("GDR_QPS_SELECT") as Control
	s.hp_effect = s.built.get_node_or_null("GDR_QPS_EFFECT_HP") as TextureRect
	s.mp_effect = s.built.get_node_or_null("GDR_QPS_EFFECT_MP") as TextureRect
	# The race mark is never taken by Create: it keeps its Style 64, hidden.
	var race := s.built.get_node_or_null("GDR_QPS_PARTY_RACE_MARK") as Control
	if race != null:
		race.visible = false
	for g in [s.hp_gauge, s.mp_gauge]:
		if g != null:
			g.min_value = 0.0
			g.max_value = 1000.0
	for fx in [s.hp_effect, s.mp_effect]:
		if fx != null:
			fx.visible = false
	if s.select_glow != null:
		s.select_glow.visible = false
	_add_face(s)
	_add_status(s)
	_add_masteries(s)
	_add_buffs(s)
	add_child(s)
	return s

static func _ignore_mouse(n: Node) -> void:
	for c in n.get_children():
		if c is Control:
			(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ignore_mouse(c)

static func _label(n: Node) -> Label:
	if n is Label:
		return n as Label
	return n.get_node_or_null("Text") as Label if n != null else null

const FACE_SHADER := """
shader_type canvas_item;
uniform sampler2D mask_tex;
void fragment() {
	COLOR = vec4(texture(TEXTURE, UV).rgb, texture(mask_tex, UV).a);
}
"""

func _add_face(s: QuickSlot) -> void:
	var pic := s.built.get_node_or_null("GDR_QPS_PICTURE") as Control
	if pic == null:
		return
	s.face = TextureRect.new()
	s.face.name = "FaceView"
	s.face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	s.face.stretch_mode = TextureRect.STRETCH_SCALE
	s.face.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	s.face.position = Vector2.ZERO
	s.face.size = pic.size if pic.size != Vector2.ZERO else Vector2(28, 28)
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = FACE_SHADER
	mat.shader = sh
	if _builder != null:
		mat.set_shader_parameter("mask_tex", _builder.load_texture(FACE_MASK))
	s.face.material = mat
	s.face.visible = false
	pic.add_child(s.face)

## GDR_QPS_STATUS is authored without art (a text static here); the overlay
## is a picture on it.
func _add_status(s: QuickSlot) -> void:
	var holder := s.built.get_node_or_null("GDR_QPS_STATUS") as Control
	if holder == null:
		return
	s.status = TextureRect.new()
	s.status.name = "FarawayArt"
	s.status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.status.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	s.status.stretch_mode = TextureRect.STRETCH_SCALE
	s.status.size = holder.size if holder.size != Vector2.ZERO else Vector2(28, 28)
	s.status.visible = false
	holder.add_child(s.status)

func _add_masteries(s: QuickSlot) -> void:
	for i in 2:
		var icon := TextureRect.new()
		icon.name = "Mastery%d" % (i + 1)
		icon.position = MASTERY_POSITIONS[i]
		icon.size = MASTERY_SIZE
		icon.custom_minimum_size = MASTERY_SIZE
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_SCALE
		# The tooltip flag 0x80 (Create): the icon takes the mouse for it.
		icon.mouse_filter = Control.MOUSE_FILTER_PASS
		icon.visible = false
		s.built.add_child(icon)
		s.masteries.append(icon)

func _add_buffs(s: QuickSlot) -> void:
	s.buffs = HudTargetBuffs.new(_builder, buff_catalog)
	s.buffs.name = "QuickPartyBuffs"
	s.buffs.set_grid(BUFF_COLUMNS, BUFF_PITCH, BUFF_ICON)
	var holder := s.built.get_node_or_null("GDR_QPS_PARTY_BUFF") as Control
	s.buffs.position = holder.position if holder != null else Vector2(32, 39)
	s.buffs.visible = false
	s.built.add_child(s.buffs)

## FUN_006d9250 + FUN_006d7db0: a slot from its member's record.
func _fill(s: QuickSlot, m: PartyNet.Member) -> void:
	s.jid = m.jid
	s.member_name = m.member_name
	if s.name_label != null:
		if _builder != null:
			_builder.set_static_text(s.name_label, m.member_name)
		else:
			s.name_label.text = m.member_name
	s.hp_ratio = m.hp_ratio()
	s.mp_ratio = m.mp_ratio()
	if s.hp_gauge != null:
		s.hp_gauge.value = s.hp_ratio * s.hp_gauge.max_value
	if s.mp_gauge != null:
		s.mp_gauge.value = s.mp_ratio * s.mp_gauge.max_value
	if s.leader_flag != null:
		s.leader_flag.visible = state != null and state.leader_jid == m.jid
	_fill_masteries(s, [m.mastery1, m.mastery2])
	if m.ref_obj_id != s.model_id:
		s.model_id = m.ref_obj_id
		_build_portrait(s)

func _fill_masteries(s: QuickSlot, ids: Array) -> void:
	_load_masteries()
	for i in 2:
		var icon := s.masteries[i] if i < s.masteries.size() else null
		if icon == null:
			continue
		var rec: MasteryReader.Mastery = _mastery_table.get(int(ids[i]))
		icon.visible = rec != null
		if rec == null:
			continue
		if _builder != null and rec.icon_path != "":
			icon.texture = _builder.load_texture(rec.icon_path)
		icon.tooltip_text = _text(rec.name_code, rec.name_code)

func _load_masteries() -> void:
	if _mastery_loaded:
		return
	_mastery_loaded = true
	var archive := _builder.media_archive() if _builder != null else null
	if archive == null:
		return
	var entry := ObjectLoader.find_file(archive, MasteryReader.TABLE_PATH)
	if entry == null:
		return
	for rec in MasteryReader.parse_all(archive.read_file(entry)):
		_mastery_table[(rec as MasteryReader.Mastery).id] = rec

## Test hook: a mastery table without an archive.
func set_mastery_table(records: Array) -> void:
	_mastery_loaded = true
	_mastery_table.clear()
	for rec in records:
		_mastery_table[(rec as MasteryReader.Mastery).id] = rec

## 0x6d80d0: the slot's own model from the record's model id, posed and
## rendered once (PlayerPortrait), at the slot's 64x64 buffer.
func _build_portrait(s: QuickSlot) -> void:
	if s.face == null:
		return
	if s.model_id <= 0 or not portrait_body.is_valid():
		s.face.visible = false
		return
	var got: Array = portrait_body.call(s.model_id)
	if got.is_empty() or got[0] == null:
		s.face.visible = false
		return
	if s.portrait == null:
		s.portrait = PlayerPortrait.new()
		s.portrait.name = "Portrait"
		s.portrait.size = Vector2i(PORTRAIT_BUFFER, PORTRAIT_BUFFER)
		s.add_child(s.portrait)
		ViewportPixels.attach(s.face, s.portrait, portrait_buffer_for)
	s.portrait.set_character(got[0] as Skeleton3D, got[1] if got.size() > 1 else null)
	s.face.texture = s.portrait.get_texture()
	s.face.visible = true

## The buffer for a face covering `physical` screen pixels: retail's 64x64,
## larger only when the picture is (as PlayerPortrait.buffer_for).
static func portrait_buffer_for(physical: Vector2i) -> Vector2i:
	var side := maxi(PORTRAIT_BUFFER, maxi(physical.x, physical.y))
	return Vector2i(side, side)

## A member's portrait texture (the party window's rows borrow it,
## 0x6dab10 -> 0x6d7f30), or null.
func portrait_of(jid: int) -> Texture2D:
	for s in _slots:
		if s.jid == jid and s.portrait != null and s.face != null and s.face.visible:
			return s.portrait.get_texture()
	return null

## The faraway level for a squared distance in an exp-sharing party or not.
static func faraway_level(d2: float, exp_share: bool) -> int:
	if not exp_share:
		return 0
	if d2 >= FARAWAY_SQ[4]:
		return 5
	if d2 >= FARAWAY_SQ[3]:
		return 4
	if d2 >= FARAWAY_SQ[2]:
		return 3
	if d2 >= FARAWAY_SQ[1]:
		return 2
	if d2 >= FARAWAY_SQ[0]:
		return 1
	return 0

## The squared distance from the player at (region, local) to a record's
## (region, x, z) at y = 0 (0x9ed1e0 with the record's position): region y
## steps world X and region x world Z, 1920 a region (the axes AGENTS.md
## records); the record's y is not used.
static func record_distance_sq(player_region: Vector2i, player_local: Vector3, region: int, x: float, z: float) -> float:
	var rx := (region >> 8) & 0xFF
	var ry := region & 0xFF
	var dx := float(ry - player_region.y) * RegionGridState.REGION_SPAN + (x - player_local.x)
	var dz := float(rx - player_region.x) * RegionGridState.REGION_SPAN + (z - player_local.z)
	var dy := 0.0 - player_local.y
	return dx * dx + dy * dy + dz * dz

## The member's squared distance from the player now, or INF when nothing is
## known of the player's position.
func member_distance_sq(m: PartyNet.Member) -> float:
	var body: Node3D = member_body.call(m.jid) if member_body.is_valid() else null
	if body != null and is_instance_valid(body) and body.is_inside_tree() and player_position.is_valid():
		var p: Vector3 = player_position.call()
		return p.distance_squared_to(body.global_position)
	if not player_region_local.is_valid():
		return INF
	var pl: Dictionary = player_region_local.call()
	if pl.is_empty():
		return INF
	return record_distance_sq(pl["region"], pl["local"], m.region, float(m.x), float(m.z))

func set_faraway(s: QuickSlot, level: int) -> void:
	# 0x6d86e0 sets the art on every call; here only a change re-arts the
	# picture (the same picture, without a redraw a frame).
	if level == s.faraway and s.status != null and s.status.visible == (level > 0):
		return
	s.faraway = level
	if s.status == null:
		return
	if level <= 0:
		s.status.texture = null
		s.status.visible = false
		return
	if _builder != null:
		s.status.texture = _builder.load_texture(FARAWAY_ART[level])
	s.status.visible = true

func _process(_delta: float) -> void:
	if not visible or state == null:
		return
	tick(Time.get_ticks_msec())

## One frame of vslot_012 (the board's and each slot's): selection, the
## faraway overlay, the caution effects, and the buffs' second timer.
func tick(now_ms: int) -> void:
	var sel: int = int(selected_jid.call()) if selected_jid.is_valid() else 0
	var members := shown_members()
	for i in mini(members.size(), _slots.size()):
		var s := _slots[i]
		var m := members[i]
		if s.select_glow != null:
			var glow := sel != 0 and sel == s.jid
			if glow != s.select_glow.visible:
				s.select_glow.visible = glow
				print("HudQuickParty: %s's box %s" % [s.member_name, "selected (glow on)" if glow else "deselected"])
		set_faraway(s, faraway_level(member_distance_sq(m), state.exp_share == 1))
		_caution(s, now_ms)
	if now_ms - _last_buff_ms >= BUFF_REFRESH_MS:
		_last_buff_ms = now_ms
		_refresh_buffs()

func _caution(s: QuickSlot, now_ms: int) -> void:
	var hp_on := s.hp_ratio < CAUTION_RATIO and s.record_58 == 0
	var mp_on := s.mp_ratio < CAUTION_RATIO and s.record_58 == 0
	if s.faraway == 5:
		hp_on = false
		mp_on = false
	var frame := (now_ms / CAUTION_FRAME_MS) % CAUTION_FRAMES
	for pair in [[s.hp_effect, hp_on and hp_caution], [s.mp_effect, mp_on and mp_caution]]:
		var fx := pair[0] as TextureRect
		if fx == null:
			continue
		fx.visible = bool(pair[1])
		if fx.visible:
			_caution_frame(fx, frame)

static func _caution_frame(fx: TextureRect, frame: int) -> void:
	var atlas := fx.texture as AtlasTexture
	if atlas == null or atlas.atlas == null:
		return
	var full := atlas.atlas.get_size()
	var w := full.x / CAUTION_COLUMNS
	var h := full.y / (CAUTION_FRAMES / CAUTION_COLUMNS)
	atlas.region = Rect2((frame % CAUTION_COLUMNS) * w, (frame / CAUTION_COLUMNS) * h, w, h)

## The buff rows (0x6d9250's tail / the 1 s timer): live for spawned members
## while the option is on, cleared otherwise.
func _refresh_buffs() -> void:
	for s in _slots:
		if s.buffs == null:
			continue
		var body: Node3D = member_body.call(s.jid) if member_body.is_valid() else null
		var spawned := body != null and is_instance_valid(body)
		if not show_buffs or not spawned:
			if s.buffs.visible or s.buffs.count(true) + s.buffs.count(false) > 0:
				s.buffs.clear_all()
			s.buffs.visible = false
			continue
		var list: Array = buffs_of.call(s.jid) if buffs_of.is_valid() else []
		if s.buffs.catalog == null and buff_catalog != null:
			s.buffs.catalog = buff_catalog
		if s.buffs.ready_to_fill():
			s.buffs.sync(list)
		s.buffs.visible = true

## A slot's click (0x6d8500): the member by name, then the sound.
func click_slot(s: QuickSlot) -> void:
	print("HudQuickParty: %s's box clicked" % s.member_name)
	member_clicked.emit(s.jid, s.member_name)
	if play_sound.is_valid():
		play_sound.call(SELECT_SOUND)

## Ctrl+2..8 (0x77f230 -> 0x6da850(n)): slot n's member, or 0 for none.
func member_at(n: int) -> int:
	return _slots[n].jid if n >= 0 and n < _slots.size() else 0

func member_name_at(n: int) -> String:
	return _slots[n].member_name if n >= 0 and n < _slots.size() else ""

# --- Read-outs for tests and QA ------------------------------------------------

func slot_count() -> int:
	return _slots.size()

func slot(i: int) -> QuickSlot:
	return _slots[i] if i >= 0 and i < _slots.size() else null

func slot_for(jid: int) -> QuickSlot:
	for s in _slots:
		if s.jid == jid:
			return s
	return null

func lock_button() -> TextureButton:
	return _lock

## One log line: each slot's member, screen rect, faraway level and glow.
func describe() -> String:
	var parts := PackedStringArray()
	for s in _slots:
		parts.append("%s jid=%d at %s far=%d glow=%s leader=%s buffs=%d" % [s.member_name, s.jid,
			str(s.get_global_rect()), s.faraway, s.select_glow != null and s.select_glow.visible,
			s.leader_flag != null and s.leader_flag.visible,
			s.buffs.count(true) + s.buffs.count(false) if s.buffs != null else 0])
	return "%d slot(s), lock %s: %s" % [_slots.size(), _lock != null and _lock.visible, "; ".join(parts)]

func _text(key: String, fallback: String) -> String:
	if _builder == null:
		return fallback
	var t := _builder.resolve_text(key)
	return fallback if t == "" or t == key else t
