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
##     not 3/3/3/1, 3/3/3/3 or 3/3/13/6.
## Not recovered: the frame/tile resize arithmetic for several buttons, and
## what UI_SILKMALL::FUN_00655ec0 does to a zero-count button (OURS: it is
## disabled).

const LAYOUT := "resinfo\\ifcompositeitemwnd.txt"
const REGISTRY := "GDR_COMPOSITE_ITEM"
const BUTTON_DDJ := "interface\\system\\sys_button.ddj"
const BUTTON_SIZE := Vector2(150, 25)
const BUTTON_ORIGIN := Vector2(0x1f, 0x3a)
const BUTTON_STEP := 0x22

## A button was pressed for this granted item.
signal use_requested(item_id: int)

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
			hide()
			use_requested.emit(item_id))
	var cancel_text := _builder.resolve_text("UIIT_CTL_CANCEL") if _builder != null else ""
	var cancel := _make_button("CompositeCancel",
		cancel_text if cancel_text != "" and cancel_text != "UIIT_CTL_CANCEL" else "UIIT_CTL_CANCEL", entries.size())
	if cancel != null:
		cancel.pressed.connect(func() -> void: hide())
	print("CompositeItemWindow: %d button(s): %s" % [entries.size(), ", ".join(_buttons.map(func(b): return button_text(b)))])

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
