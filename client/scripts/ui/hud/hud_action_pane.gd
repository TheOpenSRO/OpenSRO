extends RefCounted
class_name HudActionPane

## The main popup's action pane (GDR_ACTION, CIFAction, round 781), filled
## the way CIFAction::Create (0x6a4870) fills it: every slot of
## resinfo\ifaction.txt hidden, then each actionwnddata.txt row's icon,
## tooltip and action id put on its section's slot, and the slot shown
## (ActionWndData has the reading).
##
## READ, besides Create:
##   - The tooltips of four buttons are then rewritten with the key bound to
##     them (IFAction::FUN_006a4320, run at the end of Create): 1000
##     UIIT_STT_TOGGLE_CONTENTS_MENU_SITDOWN ("Sit ( %s )"), 1008 _PICKUP,
##     1014 _TRAININGCAMP, 1016 _PARTYMATCH, the %s from the live key table
##     (0x778c00's 33 slots: N, G, L, E by default).
##   - The player's own motion swaps two buttons (IFAction::FUN_006a3fb0,
##     called from the 0x30bf handler 0x8a8201 with the new value): 0 shows
##     icon_cha_sit + UIIT_CTL_SIT on 1000, 4 icon_cha_stand + UIIT_CTL_STAND;
##     2 (now walking) icon_cha_run + UIIT_CTL_RUN on 1001, 3 icon_cha_walk +
##     UIIT_CTL_WALK. 0x54 / 0x55 (free PvP on / off) swap 1017; OpenSRO has
##     no free PvP, so they never come.
##   - A right click uses a filled slot (CIFSlotWithHelp vslot 33 -> 0x682040,
##     kind 0x4a -> 0x793b00(owner, id)); a left click picks its icon up
##     (the held icon, round 652), and the quick slot bar takes it (kind 0x4a
##     in CIFUnderBar::vslot_028, 0x68dd10).
##
## The tooltip is the slot's tooltip_text, shown in the help bubble by
## HelpTips (round 848; a CIFSlotWithHelp's help, 0x686db0). OURS: 1015's
## tooltip is its text key although Create gives it 0x652d60(0x80) instead
## (what that draws is not read).

## A filled slot was right-clicked: run its action (ActionCommands).
signal use_requested(action_id: int)
## A filled slot was left-clicked: its icon goes onto the cursor
## (HudPanels.pick_up_icon). `what` is the held payload, kind "action".
signal pick_requested(what: Dictionary, icon: Texture2D, source: Control, at: Vector2)

const LAYOUT := "resinfo\\ifaction.txt"

## The motion swaps (READ, FUN_006a3fb0): value -> [action id, icon, text key].
const MOTION_SWAPS := {
	0: [1000, "icon\\action\\icon_cha_sit.ddj", "UIIT_CTL_SIT"],
	4: [1000, "icon\\action\\icon_cha_stand.ddj", "UIIT_CTL_STAND"],
	2: [1001, "icon\\action\\icon_cha_run.ddj", "UIIT_CTL_RUN"],
	3: [1001, "icon\\action\\icon_cha_walk.ddj", "UIIT_CTL_WALK"],
}

## The key tooltips (READ, FUN_006a4320): action id -> [format key, KeyMap action].
const KEY_TOOLTIPS := {
	1000: ["UIIT_STT_TOGGLE_CONTENTS_MENU_SITDOWN", "sit"],
	1008: ["UIIT_STT_TOGGLE_CONTENTS_MENU_PICKUP", "pickup"],
	1014: ["UIIT_STT_TOGGLE_CONTENTS_MENU_TRAININGCAMP", "panel:academy"],
	1016: ["UIIT_STT_TOGGLE_CONTENTS_MENU_PARTYMATCH", "panel:partymatch"],
}

var _builder: UiBuilder
var pane: Control
## action id -> the slot Control showing it.
var slots := {}
## action id -> the icon path it shows now (MOTION_SWAPS change two).
var icon_paths := {}
## The rows the pane was filled from.
var entries: Array = []

func _init(builder: UiBuilder, pane_control: Control, rows: Array) -> void:
	_builder = builder
	pane = pane_control
	entries = rows
	_fill()

## Layout id -> control name, read once from the layout's Create section (the
## parser's control_by_id is not filled).
var _names_by_id := {}

## The slot control with layout id `id`, or null.
func slot_by_control_id(id: int) -> Control:
	if _builder == null or pane == null:
		return null
	if _names_by_id.is_empty():
		var layout := _builder.load_layout(LAYOUT)
		var sec := layout.get_section("Create") if layout != null else null
		if sec == null:
			return null
		for def in sec.controls:
			_names_by_id[(def as UiLayoutParser.ControlDef).id] = (def as UiLayoutParser.ControlDef).name
	if not _names_by_id.has(id):
		return null
	return pane.find_child(String(_names_by_id[id]), true, false) as Control

func _fill() -> void:
	# Every slot hidden first (0xb9daf0(0) on all 52).
	for section in ActionWndData.SECTION_SLOTS:
		for i in int(ActionWndData.SECTION_SLOTS[section]):
			var s := slot_by_control_id(int(ActionWndData.SECTION_ID_BASE[section]) + i)
			if s != null:
				s.visible = false
	for e in entries:
		var entry: ActionWndData.Entry = e
		var cid := entry.control_id()
		if cid < 0:
			continue
		var slot := slot_by_control_id(cid)
		if slot == null:
			continue
		slots[entry.id] = slot
		slot.set_meta("action_id", entry.id)
		_set_icon(entry.id, entry.icon)
		slot.tooltip_text = _text(entry.text_key)
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		slot.visible = true
		var id := entry.id
		slot.gui_input.connect(func(ev: InputEvent) -> void: _on_slot_input(id, ev))
	_apply_key_tooltips()

func _apply_key_tooltips() -> void:
	for id in KEY_TOOLTIPS:
		if not slots.has(id):
			continue
		var spec: Array = KEY_TOOLTIPS[id]
		var key := KeyMap.key_for(String(spec[1]))
		var key_name := OS.get_keycode_string(key) if key != KEY_NONE else ""
		var fmt := _text(String(spec[0]))
		(slots[id] as Control).tooltip_text = fmt.replace("%s", key_name) if fmt.contains("%s") else fmt

func _text(key: String) -> String:
	if key == "":
		return ""
	return _builder.resolve_text(key) if _builder != null else key

func _set_icon(id: int, path: String) -> void:
	var slot: Control = slots.get(id)
	if slot == null:
		return
	icon_paths[id] = path
	var icon := slot.get_node_or_null("ItemIcon") as TextureRect
	if icon != null and _builder != null:
		icon.texture = _builder.load_texture(path)

## The icon an action shows now, or null.
func icon_of(id: int) -> Texture2D:
	var slot: Control = slots.get(id)
	if slot == null:
		return null
	var icon := slot.get_node_or_null("ItemIcon") as TextureRect
	return icon.texture if icon != null else null

## The player's own motion changed (0x30bf kind 1): swap the sit/stand or
## walk/run button (FUN_006a3fb0). Returns the action id that changed, or -1.
func set_motion(value: int) -> int:
	if not MOTION_SWAPS.has(value):
		return -1
	var spec: Array = MOTION_SWAPS[value]
	var id := int(spec[0])
	if not slots.has(id):
		return -1
	_set_icon(id, String(spec[1]))
	(slots[id] as Control).tooltip_text = _text(String(spec[2]))
	return id

func _on_slot_input(id: int, ev: InputEvent) -> void:
	var slot: Control = slots.get(id)
	if slot == null or not (ev is InputEventMouseButton):
		return
	var mb := ev as InputEventMouseButton
	if not slot.get_global_rect().has_point(mb.global_position):
		return
	if HeldIcon.is_pick_click(ev):
		var tex := icon_of(id)
		pick_requested.emit({"kind": "action", "action_id": id, "icon": tex}, tex, slot, mb.global_position)
	elif mb.button_index == MOUSE_BUTTON_RIGHT and not mb.pressed:
		use_requested.emit(id)
