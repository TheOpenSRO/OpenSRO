extends Control
class_name HudCosCommand

## One summoned COS's command strip above the bottom bar (round 795): the
## client's CIFCOSCommand, one per COS, created in code by the COS manager
## (`0x810df0`); only the current COS's strip is shown. READ from
## sro_client.exe unless a line says otherwise (client_ui.md sections 1h and
## 3, and this round's reading of the class at 0x7a1da0..0x7a2d90 on the box,
## /var/tmp/r795/clientui/cmd/cmdwnd.asm).
##
## - Buttons per kind, as (index, command, piece) -- the calls to 0x7a25c0:
##   ride / transport (0, 1): info, ride, terminate; ability pet (2): info,
##   ride, unsummon, follow; growth pet (3): info, ride, unsummon, follow,
##   attack, AI; guild soldier (4): terminate. Commands are FUN_007a0980's:
##   0 info, 1 ride, 2 attack, 3 follow, 4 unsummon, 5 terminate, 6 AI.
## - Each button is a background piece (class 0xee9808) and a 28x28 slot of
##   type 0x25 (0xee9b18). Piece 0 (the first): `am_ctrl_window_end.ddj`
##   36x36, the slot at (4, 5); piece 1: `am_ctrl_window_middle.ddj` 32x36,
##   the slot at (2, 5); piece 2 (the last): `am_ctrl_window_middle.ddj`
##   34x36 (the 32-wide art stretched, READ as written), the slot at (2, 5).
## - Layout (0x7a20c0): x = bar x + 653 - 31 n (n buttons), y = bar y - 28;
##   each piece at x, its slot at x + 4 (piece 0) or x + 2, both 5 down; x
##   advances 33 after piece 0, 31 after piece 1 and 34 after piece 2. The
##   bar is the bottom bar's window (0x7994e0 -> 0xb8f460).
## - `resinfo\ifcoscommand.txt`'s two controls, GDR_COSCMD_BOARD (id 2) and
##   GDR_COSCMD_OPENCLOSE (id 3), are hidden by the layout pass and never
##   shown again (INFERRED dead, client_ui.md 3).
## - The icon (0x7a0210) and the tooltip (0x7a0f90) per command and state:
##   icon_path / tooltip_key.
## - Slot type 0x25 can be carried to the quick bar; using one (a right
##   release, CIFSlotWithHelp vslot_033) runs the command on the current COS.

const LAYOUT := "resinfo\\ifcoscommand.txt"

const CMD_INFO := 0
const CMD_RIDE := 1
const CMD_ATTACK := 2
const CMD_FOLLOW := 3
const CMD_UNSUMMON := 4
const CMD_TERMINATE := 5
const CMD_AI := 6

## kind -> [[command, piece], ...] in strip order (0x7a25c0's calls, READ).
const BUTTONS := {
	0: [[CMD_INFO, 0], [CMD_RIDE, 1], [CMD_TERMINATE, 2]],
	1: [[CMD_INFO, 0], [CMD_RIDE, 1], [CMD_TERMINATE, 2]],
	2: [[CMD_INFO, 0], [CMD_RIDE, 1], [CMD_UNSUMMON, 1], [CMD_FOLLOW, 2]],
	3: [[CMD_INFO, 0], [CMD_RIDE, 1], [CMD_UNSUMMON, 1], [CMD_FOLLOW, 1], [CMD_ATTACK, 1], [CMD_AI, 2]],
	4: [[CMD_TERMINATE, 2]],
}

const PIECE_END := "interface\\animal\\am_ctrl_window_end.ddj"
const PIECE_MIDDLE := "interface\\animal\\am_ctrl_window_middle.ddj"
## piece -> [art, size, slot x, advance] (0x7a25c0 and 0x7a20c0, READ).
const PIECES := {
	0: [PIECE_END, Vector2(36, 36), 4, 33],
	1: [PIECE_MIDDLE, Vector2(32, 36), 2, 31],
	2: [PIECE_MIDDLE, Vector2(34, 36), 2, 34],
}
const SLOT_SIZE := Vector2(28, 28)
const SLOT_Y := 5
## x = bar x + 653 - 31 n, y = bar y - 28 (0x7a20e3 `add esi,0x28d`, the
## `add ebx,0xffffffe4`).
const BAR_X_OFFSET := 653
const BAR_PITCH := 31
const BAR_Y_OFFSET := -28

## The icons (0x7a0210's string table, READ).
const ICON_DIR := "icon\\action\\"
const ICON_INFO := "cos_cmd_coswindow"
const ICON_EMBARK := "cos_cmd_embark"
const ICON_DISEMBARK := "cos_cmd_disembark"
const ICON_ATTACK := "cos_cmd_skill_page"
const ICON_FOLLOW := "cos_cmd_follower"
const ICON_UNSUMMON := "cos_cmd_unsummon"
const ICON_TERMINATE := "cos_cmd_ai_destruction"
const ICON_AGGRESSIVE := "cos_cmd_aggressive"
const ICON_DEFENSIVE := "cos_cmd_defensive"

## The tooltip keys (0x7a0f90's, READ). Cmd 4 really reads "UNSOMMON" and
## cmd 5 "UNSUMMON".
const TIP_KEYS := {
	CMD_INFO: "UIIT_STT_TOGGLE_CONTENTS_MENU_COS_INFO",
	CMD_ATTACK: "UIIT_STT_TOGGLE_CONTENTS_MENU_COS_ATTACK",
	CMD_FOLLOW: "UIIT_STT_TOGGLE_CONTENTS_MENU_COS_FOLLOW",
	CMD_UNSUMMON: "UIIT_STT_TOGGLE_CONTENTS_MENU_COS_UNSOMMON",
	CMD_TERMINATE: "UIIT_STT_TOGGLE_CONTENTS_MENU_COS_UNSUMMON",
}
const TIP_MOUNT := "UIIT_STT_TOGGLE_CONTENTS_MENU_COS_MOUNT"
const TIP_DISMOUNT := "UIIT_STT_TOGGLE_CONTENTS_MENU_COS_DISMOUNT"
const TIP_AI_ATTACKER := "UIIT_STT_TOGGLE_CONTENTS_MENU_COS_AI_ATTACKER"
const TIP_AI_DEFENDER := "UIIT_STT_TOGGLE_CONTENTS_MENU_COS_AI_DEFENDER"
## The AI tooltip with no mode to name (0x7a144e): this key, no key name.
const TIP_AI_NONE := "UIIT_STT_COS_AGGRESSIVE"

## The KeyMap actions bound to each command (keymap.gd slots 14..19). PgUp
## runs 4 or 5 by kind (0x811350), so both name it.
const KEY_ACTIONS := {
	CMD_INFO: "pet_info", CMD_RIDE: "pet_ride", CMD_ATTACK: "pet_attack",
	CMD_FOLLOW: "pet_follow", CMD_UNSUMMON: "pet_unsummon", CMD_TERMINATE: "pet_unsummon",
	CMD_AI: "pet_ai",
}

## A right release on a button's slot: run its command on the current COS.
signal command_used(cmd: int)
## A left release on a button's slot: pick its icon up (slot type 0x25 goes
## onto the quick bar). `at` is the global cursor position.
signal command_picked(cmd: int, icon: Texture2D, source: Control, at: Vector2)

var _builder: UiBuilder
var kind := -1
## Per button: {"cmd", "piece", "bg": TextureRect, "slot": Control, "icon": TextureRect}.
var buttons: Array = []
var _layout_root: Control
var _text: Callable

func _init(builder: UiBuilder = null, text: Callable = Callable()) -> void:
	_builder = builder
	_text = text
	name = "COSCommand"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

## The commands a kind's strip holds, in order.
static func commands_for(client_kind: int) -> Array:
	var out: Array = []
	for b in BUTTONS.get(client_kind, []):
		out.append(int(b[0]))
	return out

## The strip's top-left for a bottom bar at `bar_origin` with `count` buttons.
static func strip_origin(bar_origin: Vector2, count: int) -> Vector2:
	return Vector2(bar_origin.x + BAR_X_OFFSET - BAR_PITCH * count, bar_origin.y + BAR_Y_OFFSET)

## Each button's piece and slot x, relative to the strip's x (0x7a20c0).
static func piece_offsets(client_kind: int) -> Array:
	var out: Array = []
	var x := 0
	for b in BUTTONS.get(client_kind, []):
		var piece: Array = PIECES[int(b[1])]
		out.append([x, x + int(piece[2])])
		x += int(piece[3])
	return out

## The icon 0x7a0210 picks for `cmd`. `state`: "has_record", "dead" (the
## owner, player+0x65c bit 1), "rideable" (refchar +0x1d4), "riding"
## (player+0x2a4), "kind" (the client kind), "settings" (the record's
## +0x163a8). Info does not look at death; every other command shows its
## `_disable` art while the owner is dead.
static func icon_path(cmd: int, state: Dictionary) -> String:
	var rec := bool(state.get("has_record", true))
	var dead := bool(state.get("dead", false))
	var k := int(state.get("kind", -1))
	var pet := k == 2 or k == 3
	var live := rec and not dead
	var base := ""
	var on := false
	match cmd:
		CMD_INFO:
			base = ICON_INFO
			on = rec
		CMD_RIDE:
			if live and bool(state.get("rideable", false)):
				return ICON_DIR + (ICON_EMBARK if not bool(state.get("riding", false)) else ICON_DISEMBARK) + ".ddj"
			base = ICON_EMBARK
		CMD_ATTACK:
			base = ICON_ATTACK
			on = live and k == 3
		CMD_FOLLOW:
			base = ICON_FOLLOW
			on = live and pet
		CMD_UNSUMMON:
			base = ICON_UNSUMMON
			on = live and pet
		CMD_TERMINATE:
			base = ICON_TERMINATE
			on = live and not pet
		CMD_AI:
			if live and k == 3:
				var s := int(state.get("settings", 0))
				if s == 1:
					return ICON_DIR + ICON_AGGRESSIVE + ".ddj"
				if s == 0:
					return ICON_DIR + ICON_DEFENSIVE + ".ddj"
			base = ICON_AGGRESSIVE
		_:
			return ""
	return ICON_DIR + base + ("" if on else "_disable") + ".ddj"

## Whether `cmd`'s icon is the live one (not `_disable`).
static func enabled(cmd: int, state: Dictionary) -> bool:
	var p := icon_path(cmd, state)
	return p != "" and not p.ends_with("_disable.ddj")

## The tooltip's text key for `cmd` (0x7a0f90) and whether it takes the key
## name: [key, takes_key_name].
static func tooltip_key(cmd: int, state: Dictionary) -> Array:
	var rec := bool(state.get("has_record", true))
	match cmd:
		CMD_RIDE:
			if rec and bool(state.get("rideable", false)) and bool(state.get("riding", false)):
				return [TIP_DISMOUNT, true]
			return [TIP_MOUNT, true]
		CMD_AI:
			if rec:
				var s := int(state.get("settings", -1))
				if s == 1:
					return [TIP_AI_ATTACKER, true]
				if s == 0:
					return [TIP_AI_DEFENDER, true]
			return [TIP_AI_NONE, false]
	return [String(TIP_KEYS.get(cmd, "")), true]

## The tooltip line: the key's text with `%s` the bound key's name
## (swprintf(buf, 0x80, text, key name), READ). `key_name` is that name.
static func tooltip_text(format: String, takes_key: bool, key_name: String) -> String:
	if takes_key and format.contains("%s"):
		return format.replace("%s", key_name)
	return format

## The bound key's name, as this client names keys (HudUnderbar.key_name's
## rule: Godot's name for the KeyMap binding; 0x60d020's own naming is not
## read). "" when unbound.
static func key_name(cmd: int) -> String:
	var action: String = KEY_ACTIONS.get(cmd, "")
	if action == "":
		return ""
	var key := KeyMap.key_for(action)
	if key == KEY_NONE:
		return ""
	return OS.get_keycode_string(key)

## Builds the strip's buttons for `client_kind`.
func build(client_kind: int) -> void:
	kind = client_kind
	for c in get_children():
		remove_child(c)
		c.queue_free()
	buttons.clear()
	# The layout's board and open/close toggle: built, then hidden by the
	# layout pass and never shown again (0x7a20c0 hides ids 3 and 2).
	if _builder != null:
		var layout := _builder.load_layout(LAYOUT)
		if layout != null:
			_layout_root = _builder.build_section(layout, "Create")
			if _layout_root != null:
				add_child(_layout_root)
				for c in _layout_root.get_children():
					(c as CanvasItem).visible = false
	var offsets := piece_offsets(client_kind)
	var list: Array = BUTTONS.get(client_kind, [])
	for i in list.size():
		var cmd := int(list[i][0])
		var piece: Array = PIECES[int(list[i][1])]
		var bg := TextureRect.new()
		bg.name = "Piece%d" % i
		bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg.stretch_mode = TextureRect.STRETCH_SCALE
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bg.texture = _builder.load_texture(String(piece[0])) if _builder != null else null
		bg.position = Vector2(offsets[i][0], 0)
		bg.size = piece[1]
		add_child(bg)
		var slot := Control.new()
		slot.name = "Slot%d" % i
		slot.position = Vector2(offsets[i][1], SLOT_Y)
		slot.size = SLOT_SIZE
		slot.custom_minimum_size = SLOT_SIZE
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		var ic := TextureRect.new()
		ic.name = "Icon"
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_SCALE   # 32x32 art in a 28 box (READ)
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		slot.add_child(ic)
		slot.gui_input.connect(_on_slot_input.bind(cmd, slot, ic))
		add_child(slot)
		buttons.append({"cmd": cmd, "piece": int(list[i][1]), "bg": bg, "slot": slot, "icon": ic,
			"path": "", "tip": ""})

## The strip's width: the last piece's right edge.
func strip_width() -> float:
	if buttons.is_empty():
		return 0.0
	var last: TextureRect = buttons[-1]["bg"]
	return last.position.x + last.size.x

## Places the strip for a bottom bar at `bar_origin` (0x7a20c0).
func place(bar_origin: Vector2) -> void:
	position = strip_origin(bar_origin, buttons.size())
	size = Vector2(strip_width(), PIECES[0][1].y)

## Re-reads every button's icon and tooltip for `state` (icon_path's keys).
func refresh(state: Dictionary) -> void:
	for b in buttons:
		var cmd := int(b["cmd"])
		var path := icon_path(cmd, state)
		b["path"] = path
		var ic: TextureRect = b["icon"]
		ic.texture = _builder.load_texture(path) if _builder != null and path != "" else null
		var tk := tooltip_key(cmd, state)
		var fmt := _resolve(String(tk[0]))
		b["tip"] = tooltip_text(fmt, bool(tk[1]), key_name(cmd))

## A button's current icon path and tooltip, by command ("" when absent).
func icon_of(cmd: int) -> String:
	for b in buttons:
		if int(b["cmd"]) == cmd:
			return String(b["path"])
	return ""

func tooltip_of(cmd: int) -> String:
	for b in buttons:
		if int(b["cmd"]) == cmd:
			return String(b["tip"])
	return ""

## The slot control of `cmd`'s button (the hover's anchor), or null.
func slot_of(cmd: int) -> Control:
	for b in buttons:
		if int(b["cmd"]) == cmd:
			return b["slot"]
	return null

func _resolve(key: String) -> String:
	if key == "":
		return ""
	if _text.is_valid():
		return String(_text.call(key, key))
	return key

func _on_slot_input(event: InputEvent, cmd: int, slot: Control, ic: TextureRect) -> void:
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	if mb.button_index == MOUSE_BUTTON_RIGHT and not mb.pressed:
		slot.accept_event()
		command_used.emit(cmd)
	elif HeldIcon.is_pick_click(event):
		slot.accept_event()
		command_picked.emit(cmd, ic.texture, slot, mb.global_position)
