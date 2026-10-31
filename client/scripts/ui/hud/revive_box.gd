extends HudCosBox
class_name ReviveBox

## The dead player's box, CMessageBoxManager purpose 3 (round 848, lane H; it
## was this client's own dark, gold-edged panel with Godot buttons since
## round 548). Built from `resinfo\ifmessagebox.txt` section MsgBoxINIF in
## the shell the message boxes share (HudCosBox). READ from sro_client.exe,
## UI_SILKMALL::FUN_00644c90 case 3 (0x645092..0x6456d3), outside a fortress
## war (the branch at 0x6451da; the war's lines are not built):
##
## - opened through 0x6ec5d0 (0x780f88, 0x9d6e39), so first placed at screen
##   w / 2 - 0x9a, h / 2 - 0x4a, then resized to 0x190 x 0xd2 (400 x 210)
##   keeping that corner; title UIIT_STT_CONFIRM_BOX (0xd89140);
## - +0x840 at (0x80, 0x2b), 0x94 x 0x34, showing
##   `interface\messagebox\msgbox_rebirth.ddj` (0xd9d674);
## - +0x844 at (0, 0x86) and +0x848 at (0, 0x96), each 0x190 x 0x14, no text
##   on this path;
## - a CIFPML made for the box (class 0xee9634 is CIFPML::vslot_000's, id
##   0x12c) at (0, 0x75), 0x190 x 0x10, with UIIT_MSG_MSGBOX_ASK_SELF_REBIRTH_1
##   (0xd9d450) -- "the character <is now> paralyzed." in the player's table,
##   "is now" in (255, 217, 83);
## - +0x808 hidden;
## - +0x800 at (0x16, 0xa8) and +0x804 at (0xca, 0xa8), each 0xb0 x 0x18, on
##   `interface\messagebox\msgbox_rebirth_button.ddj` (0xd9d420): +0x800
##   UIIT_MSG_MSGBOX_REBIRTH_POINT_BUTTON (UIIT_MSG_FLAGWAR_GO_TO_REVIVAL in a
##   flag world, not built), +0x804 UIIT_MSG_MSGBOX_REBIRTH_STANDING_BUTTON
##   while the max level is at most 10 (`cmp al,0xa; ja` at 0x645688), else
##   UIIT_MSG_MSGBOX_REBIRTH_HELP_BUTTON. docs/protocol/character_state.md
##   has the buttons' requests (round 665).
##
## INFERRED: the CIFPML's line is centred (its text board's 0x14 slot is
## called with 1 at 0x64551a, the value the statics use for centred) and its
## base colour white (a box-made CIFPML has no layout FontColor; OPEN); the
## table's text is drawn from its `<sml2>` element (the archive's string is
## wrapped in CSV quotes, `"""<sml2>...</sml2>"""`, which the client's
## loader is not read to strip -- OPEN). OURS, as since round 665: the help
## button is drawn disabled and the box stays, where the original's click
## would close it (no one can resurrect another player in OpenSRO yet).

const SIZE := Vector2(0x190, 0xd2)
const IMAGE_DDJ := "interface\\messagebox\\msgbox_rebirth.ddj"
const IMAGE_RECT := Rect2(0x80, 0x2b, 0x94, 0x34)
const LINE2_RECT := Rect2(0, 0x86, 0x190, 0x14)
const LINE3_RECT := Rect2(0, 0x96, 0x190, 0x14)
const PML_RECT := Rect2(0, 0x75, 0x190, 0x10)
const PML_COLOUR := Color.WHITE
const BUTTON_DDJ := "interface\\messagebox\\msgbox_rebirth_button.ddj"
const POINT_RECT := Rect2(0x16, 0xa8, 0xb0, 0x18)
const HERE_RECT := Rect2(0xca, 0xa8, 0xb0, 0x18)
## The highest max level the present point is offered at (READ, 0x645688).
const PRESENT_POINT_MAX_LEVEL := 10

## A resurrect button: 1 the return point, 2 the present point.
signal chosen(option: int)

var pml: PmlText

## Builds the box for a player of max level `level` (0: unknown, taken as 10
## or under). False without the layout.
func build_revive(builder: UiBuilder, level: int) -> bool:
	name = "RevivePrompt"
	if not build_shell(builder, SIZE, "UIIT_STT_CONFIRM_BOX", "UIIT_STT_CONFIRM_BOX", LAYOUT, "MsgBoxINIF"):
		return false
	_add_background(builder, SIZE)
	_swap_def(builder, "GDR_MBIN_STATIC_MESSAGE1", IMAGE_RECT, IMAGE_DDJ, "")
	_place(node("GDR_MBIN_STATIC_MESSAGE2"), LINE2_RECT)
	_place(node("GDR_MBIN_STATIC_MESSAGE3"), LINE3_RECT)
	for n in ["GDR_MBIN_STATIC_MESSAGE2", "GDR_MBIN_STATIC_MESSAGE3"]:
		builder.set_static_text(node(n), "")
	pml = PmlText.new()
	pml.name = "RebirthLine"
	pml.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pml.position = PML_RECT.position
	pml.size = PML_RECT.size
	root.add_child(pml)
	pml.setup(builder.font_at(0), UiBuilder.FONT_SIZES[0], PML_COLOUR)
	pml.set_markup("<center>" + sml2_element(text("UIIT_MSG_MSGBOX_ASK_SELF_REBIRTH_1", "UIIT_MSG_MSGBOX_ASK_SELF_REBIRTH_1")))
	var certify := node("GDR_MBIN_BTN_CERTIFY")
	if certify != null:
		certify.visible = false
	var here := level <= PRESENT_POINT_MAX_LEVEL
	var point := _swap_def(builder, "GDR_MBIN_BTN_OK", POINT_RECT, BUTTON_DDJ,
		text("UIIT_MSG_MSGBOX_REBIRTH_POINT_BUTTON", "UIIT_MSG_MSGBOX_REBIRTH_POINT_BUTTON")) as BaseButton
	var second_key := "UIIT_MSG_MSGBOX_REBIRTH_STANDING_BUTTON" if here else "UIIT_MSG_MSGBOX_REBIRTH_HELP_BUTTON"
	var second := _swap_def(builder, "GDR_MBIN_BTN_CANCEL", HERE_RECT, BUTTON_DDJ, text(second_key, second_key)) as BaseButton
	if point != null:
		point.name = "RevivePoint"
		point.pressed.connect(func() -> void: chosen.emit(1))
	if second != null:
		second.name = "ReviveHere" if here else "ReviveHelp"
		if here:
			second.pressed.connect(func() -> void: chosen.emit(2))
		else:
			second.disabled = true
	return true

## The `<sml2>` element of a table string, without what the archive put
## around it (its CSV quotes); the string itself when it has none.
static func sml2_element(s: String) -> String:
	var a := s.find("<sml2>")
	var b := s.rfind("</sml2>")
	if a < 0 or b < a:
		return s
	return s.substr(a, b + 7 - a)

## Replaces layout control `control_name` with one built from its own record
## at `r` on art `ddj` (a button keeps the art's _focus / _press / _disable
## files, UiBuilder's rule 6), captioned `caption` ("": none). The new node
## takes the old one's place among its siblings.
func _swap_def(builder: UiBuilder, control_name: String, r: Rect2, ddj: String, caption: String) -> Control:
	var old := node(control_name)
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(LAYOUT)
	var sec := layout.get_section("MsgBoxINIF") if layout != null else null
	if old == null or sec == null or not sec.control_by_name.has(control_name):
		return null
	var def: UiLayoutParser.ControlDef = (sec.control_by_name[control_name] as UiLayoutParser.ControlDef).with_rect(Rect2i(r))
	def.ddj = ddj
	if def.type == "CIFStatic":
		def.text = ""
	var fresh := builder.build_control(def)
	if fresh == null:
		return null
	var parent := old.get_parent()
	var at := old.get_index()
	parent.remove_child(old)
	old.queue_free()
	fresh.name = control_name
	parent.add_child(fresh)
	parent.move_child(fresh, at)
	_place(fresh, r)
	if caption != "" and fresh is BaseButton:
		builder.set_button_text(fresh, caption)
	return fresh

## CMessageBoxManager's placement (0x6ec5d0), at the 308 x 148 size it opens
## with; the purpose's resize keeps the corner (docs/protocol/message_box.md).
func place_on(view: Vector2) -> void:
	position = Vector2(floorf(view.x / 2.0) - 0x9a, floorf(view.y / 2.0) - 0x4a)

## A button's centre on screen, for the QA hooks (Vector2(-1, -1) without it).
func button_centre(button_name: String) -> Vector2:
	var b := root.find_child(button_name, true, false) as Control if root != null else null
	return b.get_global_rect().get_center() if b != null else Vector2(-1, -1)
