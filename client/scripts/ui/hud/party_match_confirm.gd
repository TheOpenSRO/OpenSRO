extends PartyMatchBox
class_name PartyMatchConfirm

## The "Delete this party?" question (round 714, lane C2). READ: Delete entry
## (0x738a30 -> 0x738940) asks through GInterface 0x788270, the generic
## question box (docs/protocol/message_box.md "MsgBoxSimple"): caption
## UIIT_STT_CONFIRM_BOX, text UIIT_STT_PARTYMATCH_DELETE_CONFIRM; the box is
## resized to 360x151 (0x643e50(0x168, 0x97)); with style 1, OK is
## UIIT_CTL_YES at centre - 81 and Cancel UIIT_CTL_NO at centre + 5; the text
## box goes to (30, 65), (w - 60, h - 122); the "Create" background tile is
## sized (w - 32, h - 56) (0x63b420). Yes sends the delete (0x732680).
## The style is READ: 0x738940 pushes 1 at 0x738986 as 0x788270's third
## argument, the byte 0x643e50 stores at +0x908 (style 1 = Yes / No).

const SIZE := Vector2(360, 151)
const LAYOUT := "resinfo\\ifmessagebox.txt"

signal confirmed

## `box` is 0x643e50's size (round 822: the guild window's ban question
## passes 280x144); the party match's is 360x151.
func build(builder: UiBuilder, message: String, box: Vector2 = SIZE) -> bool:
	name = "PartyMatchConfirm"
	if not build_shell(builder, box, "UIIT_STT_CONFIRM_BOX", "Confirmation window", LAYOUT, "MsgBoxSimple"):
		return false
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(LAYOUT)
	if layout != null and layout.sections.has("Create"):
		var base := builder.build_section(layout, "Create")
		if base != null:
			add_child(base)
			move_child(base, root.get_index())
			var tile := base.get_node_or_null("GDR_MSGBOX_BG") as Control
			if tile != null:
				var r := Rect2(tile.position, Vector2(box.x - 32, box.y - 56))
				tile.set_meta(UiBuilder.AUTHORED_RECT_META, r)
				tile.custom_minimum_size = Vector2.ZERO
				tile.size = r.size
			UiBuilder.settle_authored_rects(base)
	var lbl := Label.new()
	lbl.name = "Message"
	lbl.text = message
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.position = Vector2(30, 65)
	lbl.size = Vector2(box.x - 60, box.y - 122)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(lbl)
	for n in root.get_children():
		if n is CanvasItem and not (n is BaseButton):
			(n as CanvasItem).visible = false
	var centre := box.x / 2.0
	for spec in [["GDR_MBSIMPLE_BTN_OK", centre - 81, "UIIT_CTL_YES", "Yes", true],
			["GDR_MBSIMPLE_BTN_CANCEL", centre + 5, "UIIT_CTL_NO", "No", false]]:
		var b := _find_button(spec[4])
		if b == null:
			continue
		var at := Vector2(float(spec[1]), b.position.y)
		b.position = at
		b.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(at, b.size))
		builder.set_button_text(b, text(spec[2], spec[3]))
		if spec[4]:
			b.pressed.connect(func() -> void:
				confirmed.emit()
				close())
		else:
			b.pressed.connect(close)
	return true

## The section's OK (ID 252) / Cancel (ID 253) buttons, by their order.
func _find_button(ok: bool) -> BaseButton:
	var buttons: Array[BaseButton] = []
	for n in root.get_children():
		if n is BaseButton:
			buttons.append(n)
	buttons.sort_custom(func(a: BaseButton, b: BaseButton) -> bool: return a.position.x < b.position.x)
	if buttons.size() < 2:
		return buttons[0] if buttons.size() == 1 and ok else null
	return buttons[0] if ok else buttons[1]
