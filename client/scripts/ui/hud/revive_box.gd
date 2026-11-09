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
## loader is not read to strip -- OPEN).
##
## Round 874: the help button is the original's. READ: control 0xca's handler
## FUN_0063b8b0 records result 0 and hands it to FUN_00777dd0 ->
## FUN_00797d90 case 3, which above max level 10 sends nothing, and the box
## closes (FUN_006ec860). MEASURED: the click closes the box and nothing goes
## out; 70 s later the character is still dead with no box. (Round 665's OURS
## rule -- the button drawn disabled and the box kept, because no one could
## resurrect another player then -- is gone: round 785 added that.) Enter and
## Escape are the same button (the box's key handler 0x6449d0, case 1: Enter
## on a kind-3 box calls FUN_0063b8b0 at 0x644a27; Escape does while +0x804
## is shown, 0x6449ff..0x644a10) -- MEASURED both close it and send nothing --
## so at max level 10 or under they ask for the present point.

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

## A resurrect button: 1 the return point, 2 the present point, 0 "Waiting
## for other player's help." (nothing to send).
signal chosen(option: int)

## The second button's option: 2 at max level 10 or under (the present
## point), else 0 (waiting for help). Set by build_revive.
var second_option := 0

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
	second_option = 2 if here else 0
	if second != null:
		second.name = "ReviveHere" if here else "ReviveHelp"
		second.pressed.connect(press_second)
	return true

## The second button (FUN_0063b8b0's result 0): the present point at max
## level 10 or under, else waiting for help -- the box closes either way.
func press_second() -> void:
	chosen.emit(second_option)

## Enter and Escape press the second button (READ 0x6449d0 case 1, above).
## The shortcut pass, after a focused text line has had its keys and before
## the chat's Enter (HudChat._unhandled_key_input) and the HUD's Escape
## (HudPanels._unhandled_key_input) -- the box has the keys while it is up.
func _shortcut_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo or not visible:
		return
	if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER or k.keycode == KEY_ESCAPE:
		var vp := get_viewport()
		if vp != null:
			vp.set_input_as_handled()
		if is_offer:
			# The offer box: Enter is +0x800 (yes), Escape +0x804 (no).
			var yes := k.keycode != KEY_ESCAPE
			print("ReviveBox: %s answers the resurrection offer (%s)" % [OS.get_keycode_string(k.keycode), "yes" if yes else "no"])
			chosen.emit(1 if yes else 0)
			return
		print("ReviveBox: %s presses the second button (option %d)" % [OS.get_keycode_string(k.keycode), second_option])
		press_second()

# --- The resurrection offer (round 874) -----------------------------------
#
# Another player's resurrection skill offers the dead player a revive: 0x3080
# kind 4 (kind 8 with 'rmut'). READ, NetProcessInInterface::FUN_0088aa60
# (jump table 0x88b1d4): kind 4 (0x88af3a) closes message boxes 3 -- the
# dead window -- and 4 (0x778b90 -> 0x6ec7f0) and opens box kind 4, built by
# UI_SILKMALL::FUN_00644c90's entry 0x6456d5: title UIIT_STT_AGREEMENT_BOX,
# 0x190 x 0xd2, +0x800 at (0x7b, 0xa8), +0x804 at (0xcb, 0xa8), three
# statics 0x132 x 0x10 at (0x2e, 0x3b), (0x2e, 0x4d) and (0x2e, 0x71) with
# UIIT_MSG_MSGBOX_ASK_SKL_RESURRECTION_0/1/2 (the third's colour 0xfffff1d3,
# 0x6457fa..0x645820), +0x808 hidden. Its answer (FUN_00797d90's kind-4 entry
# 0x798101): 0x3080 {01, result} -- 1 from +0x800, 0 from +0x804. Enter takes
# +0x800 and Escape +0x804 (0x6449d0: a box of another kind than 3). Kind 8
# (0x88b11c) closes box 3 and asks through the generic agreement box with
# UIIT_MSG_MSGBOX_ASK_REBIRTH_MUTATION (0x788270, "simple_msgbox_type" 2);
# its layout was not read, so OpenSRO shows kind 8 in this same box with
# that one line (OURS).

const OFFER_SIZE := Vector2(0x190, 0xd2)
const OFFER_OK_AT := Vector2(0x7b, 0xa8)
const OFFER_CANCEL_AT := Vector2(0xcb, 0xa8)
const OFFER_LINES := [Rect2(0x2e, 0x3b, 0x132, 0x10), Rect2(0x2e, 0x4d, 0x132, 0x10), Rect2(0x2e, 0x71, 0x132, 0x10)]
const OFFER_LINE3_COLOUR := Color8(0xff, 0xf1, 0xd3)

## Whether this box is the resurrection offer (Enter accepts, Escape refuses)
## rather than the dead window (both press its second button).
var is_offer := false

## Builds the offer box for 0x3080 `kind` (4, or 8 with 'rmut'). chosen
## emits 1 for yes, 0 for no. False without the layout.
func build_offer(builder: UiBuilder, kind: int) -> bool:
	name = "ResurrectOffer"
	is_offer = true
	if not build_shell(builder, OFFER_SIZE, "UIIT_STT_AGREEMENT_BOX", "UIIT_STT_AGREEMENT_BOX", LAYOUT, "MsgBoxINIF"):
		return false
	_add_background(builder, OFFER_SIZE)
	var keys := ["UIIT_MSG_MSGBOX_ASK_SKL_RESURRECTION_0", "UIIT_MSG_MSGBOX_ASK_SKL_RESURRECTION_1",
		"UIIT_MSG_MSGBOX_ASK_SKL_RESURRECTION_2"]
	if kind == 8:
		keys = ["UIIT_MSG_MSGBOX_ASK_REBIRTH_MUTATION", "", ""]
	var statics := ["GDR_MBIN_STATIC_MESSAGE1", "GDR_MBIN_STATIC_MESSAGE2", "GDR_MBIN_STATIC_MESSAGE3"]
	for i in 3:
		var n := node(statics[i])
		if n == null:
			continue
		_place(n, OFFER_LINES[i])
		builder.set_static_text(n, text(keys[i], keys[i]) if keys[i] != "" else "")
		if i == 2 and n is Label:
			(n as Label).add_theme_color_override("font_color", OFFER_LINE3_COLOUR)
	_wire(node("GDR_MBIN_BTN_OK"), OFFER_OK_AT, func() -> void: chosen.emit(1))
	_wire(node("GDR_MBIN_BTN_CANCEL"), OFFER_CANCEL_AT, func() -> void: chosen.emit(0))
	var certify := node("GDR_MBIN_BTN_CERTIFY")
	if certify != null:
		certify.visible = false
	second_option = 0
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
