extends Control
class_name HudCosStatus

## One summoned COS's status slot in the top-right corner (round 795): the
## client's CIFCOSStatus, one per COS, created in code by the COS manager
## (`0x810c90`) and laid out from `resinfo\ifcosstatus.txt` "Create". The
## research is client_ui.md section 1a; READ from sro_client.exe unless a line
## says otherwise.
##
## - Create (0x7a8c60): id 12 the HP gauge (+0x37c), id 13 the HGP gauge
##   (+0x380), id 11 the icon (a CIFSlotWithHelp of slot type 0x27), id 7 the
##   frame (+0x384), id 5 the selection outline (+0x388), shown while this is
##   the current COS (+0x370).
## - Per kind (FUN_007a8d70): a growth pet (kind 3) gets the 44x68
##   `am_cos_window.ddj` frame, the 68x86 `cos_outline_1.ddj` outline and its
##   HGP gauge; a soldier (4) the 44x56 `am_window.ddj` with no gauge at all;
##   every other kind the 44x56 frame, the 65x75 `cos_outline_2.ddj` outline
##   and the HP gauge only.
## - The icon is characterdata column 54 under `icon\` (CosTable.Row.icon).
## - Each frame (vslot_012 0x7a8900) the HP gauge is the record's HP over the
##   row's MaxHP (column 59) and, for kind 3, the HGP gauge HGP / 10000.0.
## - Placement (the manager's 0x810660): slot i in summon order at
##   (screen width - 172 - 48 i, 2) -- slot_position.
## - A left press makes the COS current and targets it (vslot_029 0x7a8b50);
##   a right release does the same and then runs command 0 (vslot_033
##   0x7a8af0). The manager acts on the two signals.
##
## OPEN (client_ui.md section 6): the icon's own tooltip (slot type 0x27) and
## control 0xd7 of the message map (the 0x70C7 sell request) are not built.

const LAYOUT := "resinfo\\ifcosstatus.txt"

const ID_SELECT := 5
const ID_FRAME := 7
const ID_ICON := 11
const ID_HP := 12
const ID_HGP := 13

## The per-kind art and sizes (FUN_007a8d70, READ): [frame ddj, frame size,
## outline ddj, outline size, HGP shown, HP shown]. Kind 4's outline is
## resized 65x75 while its art is 65x77 (READ as written).
const FRAME_SMALL := "interface\\animal\\am_window.ddj"
const FRAME_GROWTH := "interface\\animal\\am_cos_window.ddj"
const OUTLINE_SMALL := "icon\\etc\\cos_outline_2.ddj"
const OUTLINE_GROWTH := "icon\\etc\\cos_outline_1.ddj"
const KIND_LOOK := {
	0: [FRAME_SMALL, Vector2(44, 56), OUTLINE_SMALL, Vector2(65, 75), false, true],
	1: [FRAME_SMALL, Vector2(44, 56), OUTLINE_SMALL, Vector2(65, 75), false, true],
	2: [FRAME_SMALL, Vector2(44, 56), OUTLINE_SMALL, Vector2(65, 75), false, true],
	3: [FRAME_GROWTH, Vector2(44, 68), OUTLINE_GROWTH, Vector2(68, 86), true, true],
	4: [FRAME_SMALL, Vector2(44, 56), OUTLINE_SMALL, Vector2(65, 75), false, false],
}

## The slot's create size (0x810c90: 44x56), before the kind resizes it.
const CREATE_SIZE := Vector2(44, 56)
## Placement constants (0x810660): x = screen width - 172 - 48 i, y = 2.
const RIGHT_INSET := 172
const PITCH := 48
const TOP := 2

## A left press on the slot (make current, target it).
signal pressed_left
## A right release on the slot (make current, target it, command 0).
signal released_right

var _builder: UiBuilder
var root: Control
var kind := -1
var hp_gauge: TextureProgressBar
var hgp_gauge: TextureProgressBar
var icon: TextureRect
var frame_art: TextureRect
var select_art: TextureRect
var _select_node: Control
var _frame_node: Control
var _current := false

func _init(builder: UiBuilder = null) -> void:
	_builder = builder
	name = "COSStatus"
	size = CREATE_SIZE
	custom_minimum_size = CREATE_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP

## Where slot `index` (summon order) goes on a screen `screen_width` wide.
static func slot_position(screen_width: int, index: int) -> Vector2:
	return Vector2(screen_width - RIGHT_INSET - PITCH * index, TOP)

## Builds the slot from ifcosstatus.txt. False without the layout (the slot
## then still takes its kind's size and its clicks, with nothing drawn).
func build() -> bool:
	if _builder == null:
		return false
	var layout := _builder.load_layout(LAYOUT)
	if layout == null:
		return false
	root = _builder.build_section(layout, "Create")
	if root == null:
		return false
	add_child(root)
	var sec := layout.get_section("Create")
	for def in sec.controls:
		var n := root.get_node_or_null(NodePath(def.name)) as Control
		if n == null:
			continue
		match def.id:
			ID_HP:
				hp_gauge = n as TextureProgressBar
			ID_HGP:
				hgp_gauge = n as TextureProgressBar
			ID_ICON:
				icon = n.get_node_or_null("ItemIcon") as TextureRect
			ID_FRAME:
				_frame_node = n
				frame_art = _art_child(n, def.ddj)
			ID_SELECT:
				_select_node = n
				select_art = _art_child(n, def.ddj)
	for g in [hp_gauge, hgp_gauge]:
		if g != null:
			(g as TextureProgressBar).max_value = 1.0
			(g as TextureProgressBar).step = 0.0
			(g as TextureProgressBar).value = 0.0
	UiBuilder.settle_authored_rects(root)
	set_current(_current)
	return true

## A CIFWnd with art is built by the builder as a plain control (it draws
## nothing); its art goes on a child here, at the control's size.
func _art_child(n: Control, ddj: String) -> TextureRect:
	var tr := TextureRect.new()
	tr.name = "Art"
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.texture = _builder.load_texture(ddj) if _builder != null and ddj != "" else null
	tr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	n.add_child(tr)
	n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr

## The kind's frame, outline and gauges (FUN_007a8d70) and the COS's icon.
func setup_kind(client_kind: int, icon_path: String) -> void:
	kind = client_kind
	var look: Array = KIND_LOOK.get(client_kind, KIND_LOOK[0])
	var frame_size: Vector2 = look[1]
	size = frame_size
	custom_minimum_size = frame_size
	_resize_art(_frame_node, frame_art, String(look[0]), frame_size)
	_resize_art(_select_node, select_art, String(look[2]), look[3])
	if hgp_gauge != null:
		hgp_gauge.visible = bool(look[4])
	if hp_gauge != null:
		hp_gauge.visible = bool(look[5])
	if icon != null:
		icon.texture = _builder.load_texture(icon_path) if _builder != null and icon_path != "" else null
		icon.modulate = Color(1, 1, 1, 1)   # alpha 0xff (READ)

func _resize_art(n: Control, art: TextureRect, ddj: String, s: Vector2) -> void:
	if n == null:
		return
	var r: Rect2 = n.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(n.position, n.size))
	r.size = s
	n.set_meta(UiBuilder.AUTHORED_RECT_META, r)
	n.custom_minimum_size = Vector2.ZERO
	n.size = s
	if art != null and _builder != null:
		art.texture = _builder.load_texture(ddj)

## Whether the HGP and HP gauges are shown (for tests and the QA log).
func gauges_shown() -> Array:
	return [hgp_gauge != null and hgp_gauge.visible, hp_gauge != null and hp_gauge.visible]

## The selection outline: on for the current COS (+0x370).
func set_current(on: bool) -> void:
	_current = on
	if _select_node != null:
		_select_node.visible = on

func is_current() -> bool:
	return _current

## The two gauges' fills, 0..1 (vslot_012's ratios).
func set_ratios(hp_ratio: float, hgp_ratio: float) -> void:
	if hp_gauge != null:
		hp_gauge.value = clampf(hp_ratio, 0.0, 1.0)
	if hgp_gauge != null:
		hgp_gauge.value = clampf(hgp_ratio, 0.0, 1.0)

func hp_value() -> float:
	return hp_gauge.value if hp_gauge != null else -1.0

func hgp_value() -> float:
	return hgp_gauge.value if hgp_gauge != null else -1.0

func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
		accept_event()
		pressed_left.emit()
	elif mb.button_index == MOUSE_BUTTON_RIGHT and not mb.pressed:
		accept_event()
		released_right.emit()
