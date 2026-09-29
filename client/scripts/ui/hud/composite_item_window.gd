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
	var tex: Texture2D = _builder.load_texture(BUTTON_DDJ) if _builder != null else null
	for i in entries.size():
		var e: Array = entries[i]
		var btn := Button.new()
		btn.name = "CompositeButton%d" % i
		btn.text = "%s(%d)" % [String(e[1]), int(e[2])]
		btn.position = BUTTON_ORIGIN + Vector2(0, BUTTON_STEP * i)
		btn.size = BUTTON_SIZE
		btn.custom_minimum_size = BUTTON_SIZE
		btn.clip_text = true
		if tex != null:
			var sb := StyleBoxTexture.new()
			sb.texture = tex
			for st in ["normal", "hover", "pressed", "disabled", "focus"]:
				btn.add_theme_stylebox_override(st, sb)
		btn.disabled = int(e[2]) <= 0
		var item_id := int(e[0])
		btn.pressed.connect(func() -> void:
			hide()
			use_requested.emit(item_id))
		add_child(btn)
		_buttons.append(btn)
	var cancel := Button.new()
	cancel.name = "CompositeCancel"
	var cancel_text := _builder.resolve_text("UIIT_CTL_CANCEL") if _builder != null else ""
	cancel.text = cancel_text if cancel_text != "" and cancel_text != "UIIT_CTL_CANCEL" else "Cancel"
	cancel.position = BUTTON_ORIGIN + Vector2(0, BUTTON_STEP * entries.size())
	cancel.size = BUTTON_SIZE
	cancel.custom_minimum_size = BUTTON_SIZE
	if tex != null:
		var csb := StyleBoxTexture.new()
		csb.texture = tex
		for st in ["normal", "hover", "pressed", "disabled", "focus"]:
			cancel.add_theme_stylebox_override(st, csb)
	cancel.pressed.connect(func() -> void: hide())
	add_child(cancel)
	_buttons.append(cancel)
	print("CompositeItemWindow: %d button(s): %s" % [entries.size(), ", ".join(_buttons.map(func(b): return (b as Button).text))])

## A button's centre on screen, for a QA run to aim a real click.
func button_screen_centre(i: int) -> Vector2:
	if i < 0 or i >= _buttons.size():
		return Vector2(-1, -1)
	var b: Button = _buttons[i]
	return b.global_position + b.size * 0.5
