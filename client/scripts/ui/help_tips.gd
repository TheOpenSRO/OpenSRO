extends Node
class_name HelpTips

## Round 848 (lane T): every hover help in the original's own window, and no
## native text-input menu. Autoloaded as `NativeGuiGuard` (project.godot), so
## it runs on the login, select and world screens alike.
##
## **What the original shows (READ, sro_client.exe).** A control's hover text
## is not a Windows tooltip. Every CIFWnd / CNIFWnd carries a help string
## (CIFWnd +0x210, set through 0x653dc0; CNIFWnd +0x1d8 through 0x46d7d0) and
## style bit 0x80. Each frame CGFXMainFrame::vslot_011 (0xba5600) takes the
## window under the cursor (0xb91910 at the mouse, walking up to the first one
## whose slot 0x6c accepts) and hands it to 0xb9dbb0, which on a change sends
## 0x400a to the old window and 0x4009 to the new one -- at once, no timer.
## CIFWnd's message slot (0x652fb0) / CNIFWnd's (0x46cee0) answer 0x4009 with
## bit 0x80 set by calling the show slot (CIFWnd vslot 48, 0x6528c0; CNIFWnd
## 0xb0, 0x46cdf0), and 0x400a by hiding the bubble. The show slot takes the
## interface's single CIFHelperBubbleWindow (GInterface +0x730; the CNIF one is
## a lazily made global, 0x111a030), sets its text box 200 wide (slot 0x54,
## the resize: 0x777020 resizes the box and the window through the same slot),
## writes the help in colour 0xffffffff with the font argument 1 (0x7769a0 /
## 0x4972b0, the three name signs hidden), sizes the window to its widest line
## by 14 px for one line or 18 px a line for more (0x777020, as the CNIF
## 0x496c90 the item tooltip read), and places it by the control's own rect
## (0x776c00 / 0x497350, below). Setting a control's help while it is hovered
## shows the new text at once (0x653dc0). The bubble is the item tooltip's
## window: com_tooltip_corner.ddj / com_tooltip_edge.ddj with all eight
## borders 8 (CIFHelperBubbleWindow::Create 0x776ea0 passes (8, 8) to both
## border setters), so ItemTooltipBubble draws it.
##
## **Which control owns the help (OURS, Godot's rule).** The hovered control,
## or the nearest ancestor with a tooltip, stopping at one that stops the
## mouse or is top-level (Viewport::_gui_get_tooltip's own walk), so every
## site that sets `tooltip_text` or overrides `_get_tooltip` keeps the owner
## it had under Godot's popup. Godot's popup itself never shows: its delay is
## set past any session in project.godot (gui/timers/tooltip_delay_sec).
## Controls HudPanels gives an item or skill bubble of its own (metas
## `item_tip` / `bubble_tip`) are left to it.
##
## **Text inputs (READ).** The original's edit boxes are Win32 EDIT windows
## created off the client area, at (-100, -100), 200 x 14 (CIFEdit::Create
## 0x637a60, CNIFEdit::Create 0x47ae00), subclassed (0x637a30 -> 0x636cd0) for
## the keys; the box the player sees is drawn by the client, so a right click
## on it reaches the game window and opens no menu. Every LineEdit and
## TextEdit therefore has Godot's context menu off. Their middle-button paste
## (the X11 primary selection) is off too: the original's middle button fires
## quick slot 0 (WM_MBUTTONDOWN -> 0x77c4cc -> 0x60bb80(0), HudUnderbar).

## Above the HUD (its CanvasLayer) and ComboList's open list (120): the
## original's bubble is topmost (0x776c00 restyles it 0xc4 before each show).
const LAYER := 121
## The text box's width before the help is written (READ, `0x54(200, 1)` in
## 0x6528c0 / 0x46cdf0). That it wraps longer rows at that width is INFERRED,
## as for the skill tooltip (round 786).
const WRAP := 200.0
## A control's help given here rather than as tooltip_text: rows in
## ItemTooltipLines' shape, a Callable returning rows or a String, or a String.
const SOURCE_META := &"help_tip"
## HudPanels' own bubbles (its item and skill tips): not routed here.
const HUD_ITEM_META := &"item_tip"
const HUD_BUBBLE_META := &"bubble_tip"

## The builder the bubble loads its frame and face from. Unset, the shared
## Media archive (AssetArchives) is opened for it on first show, unless
## archive_fallback is off (tests).
static var builder: UiBuilder = null
static var archive_fallback := true
## Tests (a headless run has no mouse to hover with): Callables returning the
## hovered Control and the cursor in the root canvas, in place of the
## viewport's gui_get_hovered_control() / get_mouse_position().
static var hover_probe := Callable()
static var mouse_probe := Callable()
static var _inst: HelpTips = null

var _layer: CanvasLayer
var _bubble: ItemTooltipBubble
## The control whose help is on show, and the rows it showed.
var _owner: Control = null
var _shown_key := ""
## The owner whose bubble the cursor walked into (the bubble hides then and
## stays hidden until another control is hovered -- see _process).
var _dismissed: Control = null

func _enter_tree() -> void:
	_inst = self
	get_tree().node_added.connect(_on_node_added)

func _exit_tree() -> void:
	if _inst == self:
		_inst = null
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for n in get_tree().root.find_children("*", "", true, false):
		_on_node_added(n)

## The running router, or null (a tool or test without the autoload).
static func instance() -> HelpTips:
	return _inst if is_instance_valid(_inst) else null

## Gives `control` its help in the original's bubble: a String (one white row
## a line), rows (ItemTooltipLines' shape), or a Callable returning either at
## hover time. Empty clears it. Its tooltip_text is emptied so Godot's popup
## has nothing to show; the router finds the meta first.
static func set_tip(control: Control, source: Variant) -> void:
	if control == null:
		return
	control.tooltip_text = ""
	var empty: bool = source == null or (source is String and String(source) == "") \
		or (source is Array and (source as Array).is_empty())
	if empty:
		if control.has_meta(SOURCE_META):
			control.remove_meta(SOURCE_META)
	else:
		control.set_meta(SOURCE_META, source)
		if control.mouse_filter == Control.MOUSE_FILTER_IGNORE:
			control.mouse_filter = Control.MOUSE_FILTER_PASS
	var r := instance()
	if r != null and r._owner == control:
		r._refresh(true)

## The text a control's help shows now (its rows joined by "\n"), "" for none.
static func tip_text(control: Control) -> String:
	var rows := rows_of(control, Vector2.ZERO)
	var parts := PackedStringArray()
	for row in rows:
		parts.append(String((row as Dictionary).get("text", "")))
	return "\n".join(parts)

## A control's own help as rows ([] for none): its meta, else Godot's
## get_tooltip at `local_pos` (tooltip_text, or a _get_tooltip override).
static func rows_of(control: Control, local_pos: Vector2) -> Array:
	if control == null or not is_instance_valid(control):
		return []
	if control.has_meta(SOURCE_META):
		var src: Variant = control.get_meta(SOURCE_META)
		if src is Callable:
			src = (src as Callable).call()
		if src is Array:
			return src
		return text_rows(String(src) if src != null else "")
	return text_rows(control.get_tooltip(local_pos))

## Plain help text as white rows, one a line (0x7769a0 writes it in
## 0xffffffff).
static func text_rows(text: String) -> Array:
	if text == "":
		return []
	var rows: Array = []
	for line in text.split("\n"):
		rows.append({"text": line, "color": ItemTooltipLines.WHITE, "bold": false, "icon": false})
	return rows

## The control that owns the help under the cursor when `hovered` is the
## control Godot hovers, and its rows: [owner, rows], or [null, []].
## Godot's walk (Viewport::_gui_get_tooltip): up through the parents until one
## has help, stopping after a control that stops the mouse or is top-level.
static func find_owner(hovered: Control, mouse: Vector2 = Vector2.INF) -> Array:
	var c := hovered
	while c != null:
		if c.has_meta(HUD_ITEM_META) or c.has_meta(HUD_BUBBLE_META):
			return [null, []]
		var local := c.get_local_mouse_position() if mouse == Vector2.INF \
			else c.get_global_transform_with_canvas().affine_inverse() * mouse
		var rows := rows_of(c, local)
		if not rows.is_empty():
			return [c, rows]
		if c.mouse_filter == Control.MOUSE_FILTER_STOP or c.top_level:
			break
		c = c.get_parent_control()
	return [null, []]

## The rect `control` covers in the root canvas (where the bubble's layer
## draws), for the placement.
static func canvas_rect(control: Control) -> Rect2:
	var xf := control.get_global_transform_with_canvas()
	return Rect2(xf.origin, control.size * xf.get_scale().abs())

func _process(_delta: float) -> void:
	_refresh(false)

## Follows the hovered control: a new owner shows its help at once, none
## hides it, and the same owner with new text shows the new text (0x653dc0).
## The CIF bubble also hides itself while the cursor is inside it
## (CIFHelperBubbleWindow::vslot_013 0x776bb0: 0xb8f3d0 at the mouse, then
## show(0)); OURS: it then stays hidden until the cursor hovers another
## control, since the original's next show only comes with the next 0x4009.
func _refresh(force: bool) -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var hovered: Control = hover_probe.call() if hover_probe.is_valid() else vp.gui_get_hovered_control()
	var mouse: Vector2 = mouse_probe.call() if mouse_probe.is_valid() else vp.get_mouse_position()
	var found := find_owner(hovered, mouse) if hovered != null else [null, []]
	var who: Control = found[0]
	var rows: Array = found[1]
	if who != _dismissed:
		_dismissed = null
	if who == null:
		_owner = null
		_shown_key = ""
		if _bubble != null and _bubble.visible:
			_bubble.hide_bubble()
		return
	if who == _dismissed:
		return
	var key := var_to_str(rows)
	if who != _owner or key != _shown_key or force or _bubble == null or not _bubble.visible:
		_owner = who
		_shown_key = key
		show_rows(rows, canvas_rect(who), who)
	if _bubble != null and _bubble.visible and _inner_rect().has_point(mouse):
		_bubble.hide_bubble()
		_dismissed = who

## The bubble's window rect without its frame (0x776bb0 tests the window's
## own rect; the frame is drawn outside it).
func _inner_rect() -> Rect2:
	var f := float(ItemTooltipBubble.FRAME)
	return Rect2(_bubble.position + Vector2(f, f), _bubble.size - Vector2(f, f) * 2.0)

## Shows `rows` beside `anchor` (a rect in the root canvas) for `from`.
func show_rows(rows: Array, anchor: Rect2, from: Control = null) -> void:
	_ensure_bubble()
	_bubble.show_lines(rows, anchor, from, WRAP)

func _ensure_bubble() -> void:
	if _bubble != null and is_instance_valid(_bubble):
		return
	if builder == null and archive_fallback:
		var media := AssetArchives.media()
		if media != null:
			builder = UiBuilder.new(media, null)
	_layer = CanvasLayer.new()
	_layer.name = "HelpBubbleLayer"
	_layer.layer = LAYER
	add_child(_layer)
	_bubble = ItemTooltipBubble.new(builder)
	_bubble.name = "HelpBubble"
	_bubble.hide_under_cursor = false
	_layer.add_child(_bubble)

## The rows on show, [] when hidden (tests and QA).
func shown_lines() -> Array:
	return _bubble.shown_lines() if _bubble != null else []

## The bubble (tests and QA), or null before the first show.
func bubble() -> ItemTooltipBubble:
	return _bubble

## The control whose help is on show, or null.
func owner_shown() -> Control:
	return _owner if _bubble != null and _bubble.visible else null

func _on_node_added(n: Node) -> void:
	if n is LineEdit:
		var e := n as LineEdit
		e.context_menu_enabled = false
		e.middle_mouse_paste_enabled = false
	elif n is TextEdit:
		var t := n as TextEdit
		t.context_menu_enabled = false
		t.middle_mouse_paste_enabled = false
