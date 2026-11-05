extends HudWindow
class_name CompositeItemWindow

## CIFCompositeItemWnd (round 632 review): the window a left-click on an
## item-grant icon opens -- one button per granted item, then a Cancel
## button (count + 1 in all).
##
## READ (retail client, the round's RE):
##   - Registry `GDR_COMPOSITE_ITEM:CIFCompositeItemWnd`, resinfo\ginterface.txt,
##     ID 36, Rect 300,200,214,245, frame interface\frame\mframe_wnd_.
##   - Layout resinfo\ifcompositeitemwnd.txt, section Create: GDR_COMPOSITE_FRAME
##     (CIFFrame, 17,45,180,185) and GDR_COMPOSITE_BGTILE (CIFNormalTile,
##     33,82,148,110).
##   - FUN_007af830(key) builds the buttons in code: interface\system\sys_button.ddj,
##     150 x 25, from (0x1f, 0x3a) down 0x22 px per button, labelled
##     swprintf "%s(%d)" -- the granted item's name and its uses left -- and
##     ONE MORE after them, labelled with UIIT_CTL_CANCEL's text (0x7afb57
##     pushes the key, 0x8c9c30 resolves it). FUN_007b03e0 hit-tests all
##     count + 1; the last closes the window (composite review).
##   - A button's click (FUN_007b03e0 -> FUN_007afbf0) closes the window and
##     sends 0x715F {compositeRefId, limitedRefId} for a granted item that is
##     not 3/3/3/1, 3/3/3/3 or 3/3/13/6. Round 864: those three are tested
##     first (c:0x7afd05..0x7b035d): a 3/3/3/1 while dead posts 0x1889, a
##     3/3/13/6 while alive 0x1887, and the window stays (pre_check); a
##     3/3/3/3 opens the reverse return box.
## Not recovered: the frame/tile resize arithmetic for several buttons, and
## what UI_SILKMALL::FUN_00655ec0 does to a zero-count button (OURS: it is
## disabled; MEASURED round 864: a fill at 0 shows "<name>(0)" greyed).

const LAYOUT := "resinfo\\ifcompositeitemwnd.txt"
const REGISTRY := "GDR_COMPOSITE_ITEM"
const BUTTON_DDJ := "interface\\system\\sys_button.ddj"
const BUTTON_SIZE := Vector2(150, 25)
const BUTTON_ORIGIN := Vector2(0x1f, 0x3a)
const BUTTON_STEP := 0x22

## A button was pressed for this granted item.
signal use_requested(item_id: int)
## Round 864: a button's own pre-check refused the fill (the window stays
## open, nothing is sent): the code the client posts itself.
signal refused(code: int)

## Round 864: asked before a fill goes (item_id -> 0 to go, else the code);
## the window's caller supplies it (World3D._composite_fill_check, READ
## c:0x7afd05..0x7b035d). Unset lets every fill go.
var pre_check: Callable = Callable()

var _buttons: Array = []

## Builds the window; false when the archive has no such layout.
func setup(builder: UiBuilder) -> bool:
	name = "CompositeItemWindow"
	return build(builder, LAYOUT, "", PackedStringArray(), PackedStringArray(), false, {"name": REGISTRY})

## Fills the buttons: `entries` is [[item_id, label_name, remaining], ...];
## a Cancel button follows them.
func show_entries(entries: Array) -> void:
	for b in _buttons:
		if is_instance_valid(b):
			b.queue_free()
	_buttons.clear()
	for i in entries.size():
		var e: Array = entries[i]
		var btn := _make_button("CompositeButton%d" % i, "%s(%d)" % [String(e[1]), int(e[2])], i)
		if btn == null:
			continue
		btn.disabled = int(e[2]) <= 0
		var item_id := int(e[0])
		btn.pressed.connect(func() -> void:
			var code := int(pre_check.call(item_id)) if pre_check.is_valid() else 0
			if code != 0:
				refused.emit(code)
				return
			hide()
			use_requested.emit(item_id))
	var cancel_text := _builder.resolve_text("UIIT_CTL_CANCEL") if _builder != null else ""
	var cancel := _make_button("CompositeCancel",
		cancel_text if cancel_text != "" and cancel_text != "UIIT_CTL_CANCEL" else "UIIT_CTL_CANCEL", entries.size())
	if cancel != null:
		cancel.pressed.connect(func() -> void: hide())
	fit_to_buttons(entries.size() + 1)
	print("CompositeItemWindow: %d button(s): %s" % [entries.size(), ", ".join(_buttons.map(func(b): return button_text(b)))])

## Round 858: the resize FUN_007af830 does after its buttons (READ, c:0x7af937..
## 0x7afa15 and 0x7afb8d..0x7afbcc; the round 632 review left it open). Three
## heights start at 0xf, 0x46 and 0 and grow per button (count + 1, the
## Cancel too) by 0x22, 0x24 and 0x14; then SetSize (vslot 0x54) keeps each
## control's width (0xb8f480, +0x48) and gives GDR_COMPOSITE_FRAME (ID 6,
## +0x7c4) 0xf + 0x22 n, the window 0x46 + 0x24 n, and GDR_COMPOSITE_BGTILE
## (ID 5, +0x7c0) 0x14 n. Without it the layout's 185-tall frame and
## 110-tall tile left a strip of the frame's inside bare under the tile with
## two items (the hole census: 134 x 5 px of the world showing through).
const FIT_FRAME := [0xf, 0x22]
const FIT_WINDOW := [0x46, 0x24]
const FIT_TILE := [0, 0x14]

## The three heights for `n` buttons (Cancel included): [frame, window, tile].
static func fit_heights(n: int) -> Array:
	return [FIT_FRAME[0] + FIT_FRAME[1] * n, FIT_WINDOW[0] + FIT_WINDOW[1] * n, FIT_TILE[0] + FIT_TILE[1] * n]

func fit_to_buttons(n: int) -> void:
	var h := fit_heights(n)
	if registry_def != null:
		set_registry_size(Vector2(size.x, h[1]))
	else:
		custom_minimum_size = Vector2(size.x, h[1])
		size = custom_minimum_size
	var tile := node("GDR_COMPOSITE_BGTILE") as Control
	if tile != null:
		_resize_authored(tile, float(h[2]))
	var frame := node("GDR_COMPOSITE_FRAME") as Control
	if frame != null and _builder != null:
		var layout := _builder.load_layout(LAYOUT)
		var sec := layout.get_section("Create") if layout != null else null
		var def: UiLayoutParser.ControlDef = sec.control_by_name.get("GDR_COMPOSITE_FRAME") if sec != null else null
		if def != null:
			var rect := Rect2i(def.rect.position, Vector2i(def.rect.size.x, int(h[0])))
			var rebuilt := _builder.build_control(def.with_rect(rect))
			if rebuilt != null:
				var parent := frame.get_parent()
				var at := frame.get_index()
				rebuilt.name = frame.name
				parent.remove_child(frame)
				frame.queue_free()
				parent.add_child(rebuilt)
				parent.move_child(rebuilt, at)
				rebuilt.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(rect))
				UiBuilder.settle_authored_rects(rebuilt)

static func _resize_authored(c: Control, height: float) -> void:
	var r: Rect2 = c.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(c.position, c.size))
	r.size.y = height
	c.set_meta(UiBuilder.AUTHORED_RECT_META, r)
	c.size = r.size

## Round 848: one of FUN_007af830's buttons as a CIFButton -- the client's own
## art with its _focus / _press / _disable files (UiBuilder's rule 6), where
## it was a Godot Button wearing sys_button.ddj in every state in Godot's own
## font colours. 150 x 25 at the button's place (READ, above). The caption
## centred both ways: the code sets no alignment, and a code-made control's
## text board starts at HAlign 1 and VAlign 1 (the CTextBoard ctor,
## 0x655c2f / 0x655c3b, READ). White: the default colour (INFERRED).
func _make_button(node_name: String, caption: String, i: int) -> BaseButton:
	if _builder == null:
		return null
	var def := UiLayoutParser.ControlDef.new()
	def.name = node_name
	def.type = "CIFButton"
	def.ddj = BUTTON_DDJ
	def.halign = 1
	def.valign = 1
	def.text = caption
	def.rect = Rect2i(Vector2i(BUTTON_ORIGIN + Vector2(0, BUTTON_STEP * i)), Vector2i(BUTTON_SIZE))
	var btn := _builder.build_control(def) as BaseButton
	if btn == null:
		return null
	btn.name = node_name
	btn.focus_mode = Control.FOCUS_NONE
	btn.position = Vector2(def.rect.position)
	btn.size = BUTTON_SIZE
	btn.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(def.rect))
	add_child(btn)
	UiBuilder.settle_authored_rects(btn)
	_buttons.append(btn)
	return btn

## A button's caption ("" without one).
static func button_text(b: Node) -> String:
	if b is Button:
		return (b as Button).text
	var l := b.get_node_or_null("ButtonLabel") as Label if b != null else null
	return l.text if l != null else ""

## A button's centre on screen, for a QA run to aim a real click.
func button_screen_centre(i: int) -> Vector2:
	if i < 0 or i >= _buttons.size():
		return Vector2(-1, -1)
	var b: Control = _buttons[i]
	return b.global_position + b.size * 0.5
