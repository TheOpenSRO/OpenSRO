extends Control
class_name PartySettingsDialog

## The party settings dialog, CIFSetPartyMode (round 711, lane C1;
## docs/protocol/party_gui.md §2). Everything READ from sro_client.exe:
##
## - It is child 70 (0x46) of the party pane at (32, 85), 300x200, on the
##   `interface\messagebox\msgbox2_window_` frame (0x6d61e0); the caption is a
##   static at (10, 11), the width less 21 wide and 12 high, centred, with
##   UIIT_STT_CONFIRM_BOX (CIFSetPartyMode::Create 0x6db980, its +0x7c0;
##   placed by vslot 21 0x6db6f0).
## - `resinfo\ifsetpartymode.txt` "Create" is loaded into it: the message,
##   the two black boxes, the check box (ID 17) with its label (ID 18), Yes
##   (20) and No (21).
## - The two radio groups, IDs 13 (exp) and 14 (item), each get two items
##   (0x657c40(2, 0)): a 16x16 dot at (3, 4 + 20 i) in the group -- art
##   `com_radiobutton_off.ddj`, `com_radiobutton_on.ddj` when chosen -- and a
##   label at the dot's x + 20 and y + 3, 100 wide and 12 high, centred
##   (0x657910(3, 4), 0x657930(20) the pitch, 0x657940(20) the label's x
##   offset, 0x657950(1) its alignment, 0x657960(100) its width). Item 0 is
##   SHARE, item 1 SELF (0x657ba0(radio, SHARE, SELF)). The groups' own
##   captions (UIIT_STT_PARTY_EXP_METHOD / _ITEM_METHOD) are set on a static
##   the group hides at create (CIFRadioButton vslot 10 0x6577e0, ShowWindow(0)),
##   so none is drawn -- screenshot 05 shows none either.
## - It opens on the settings block: exp radio item 0 when exp = 1, item 1
##   when 0; the same for item; the check box is "anyone may invite"
##   (0x6d61e0, 0x6db770 / 0x6db7b0).
## - Yes (0x6d6470) writes exp = (radio 0 ? 1 : 0), the same for item, and
##   anyone = the box into the block, refreshes the type line and the caption
##   and closes. No request is sent: the values wait for the next create.
##   No only closes.

const LAYOUT := "resinfo\\ifsetpartymode.txt"
const FRAME := "interface\\messagebox\\msgbox2_window_"
const RECT := Rect2(32, 85, 300, 200)
const RADIO_ON := "interface\\ifcommon\\com_radiobutton_on.ddj"
const RADIO_OFF := "interface\\ifcommon\\com_radiobutton_off.ddj"
## The radio item geometry (CIFRadioButton fields +0x384/+0x388, +0x374,
## +0x378, +0x380 as Create sets them).
const DOT_ORIGIN := Vector2(3, 4)
const DOT_SIZE := Vector2(16, 16)
const PITCH := 20.0
const LABEL_DX := 20.0
const LABEL_DY := 3.0
const LABEL_SIZE := Vector2(100, 12)

## Yes was pressed: the values the block takes.
signal confirmed(exp: int, item: int, anyone: int)

var _builder: UiBuilder
## The chosen item per group: index 0 SHARE, 1 SELF.
var exp_choice := 0
var item_choice := 1
var anyone_box: TextureButton
var _dots := {}

func build(builder: UiBuilder, party: PartyState) -> bool:
	_builder = builder
	name = "PartySettings"
	position = RECT.position
	size = RECT.size
	custom_minimum_size = RECT.size
	mouse_filter = Control.MOUSE_FILTER_STOP
	var frame_def := UiLayoutParser.ControlDef.new()
	frame_def.name = "Frame"
	frame_def.type = "CIFFrame"
	frame_def.ddj = FRAME
	frame_def.rect = Rect2i(Vector2i.ZERO, Vector2i(RECT.size))
	var frame := builder.build_control(frame_def)
	if frame != null:
		add_child(frame)
	var caption := Label.new()
	caption.name = "Caption"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.text = _text("UIIT_STT_CONFIRM_BOX", "Confirmation window")
	caption.position = Vector2(10, 11)
	caption.size = Vector2(RECT.size.x - 21, 12)
	add_child(caption)
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(LAYOUT)
	if layout == null:
		return false
	var root := builder.build_section(layout, "Create")
	if root == null:
		return false
	add_child(root)
	UiBuilder.settle_authored_rects(root)
	exp_choice = 0 if party.exp_share == 1 else 1
	item_choice = 0 if party.item_share == 1 else 1
	_build_radio(root.get_node_or_null("GDR_SETPARTYMODE_RBTN_EXP") as Control, "exp",
		["UIIT_STT_PARTY_EXP_SHARE", "UIIT_STT_PARTY_EXP_SELF"], ["Exp Auto Share", "Exp Free-For-All"])
	_build_radio(root.get_node_or_null("GDR_SETPARTYMODE_RBTN_ITEM") as Control, "item",
		["UIIT_STT_PARTY_ITEM_SHARE", "UIIT_STT_PARTY_ITEM_SELF"], ["Item Auto Share", "Item Free-For-All"])
	var holder := root.get_node_or_null("GDR_SETPARTYMODE_CB_ALLOW_INVITATION") as Control
	if holder != null:
		anyone_box = builder.make_checkbox(holder, RADIO_OFF, party.anyone_invite == 1)
	var yes := root.get_node_or_null("GDR_SETPARTYMODE_BTN_OK") as BaseButton
	if yes != null:
		yes.pressed.connect(press_yes)
	var no := root.get_node_or_null("GDR_SETPARTYMODE_BTN_CANCEL") as BaseButton
	if no != null:
		no.pressed.connect(press_no)
	return true

func _build_radio(group: Control, key: String, text_keys: Array, fallbacks: Array) -> void:
	if group == null:
		return
	var dots: Array[TextureButton] = []
	for i in 2:
		var at := DOT_ORIGIN + Vector2(0, PITCH * i)
		var dot := TextureButton.new()
		dot.name = "Item%d" % i
		dot.ignore_texture_size = true
		dot.stretch_mode = TextureButton.STRETCH_SCALE
		dot.position = at
		dot.size = DOT_SIZE
		dot.custom_minimum_size = DOT_SIZE
		dot.pressed.connect(choose.bind(key, i))
		group.add_child(dot)
		dots.append(dot)
		var label := Label.new()
		label.name = "Label%d" % i
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.text = _text(text_keys[i], fallbacks[i])
		label.position = at + Vector2(LABEL_DX, LABEL_DY)
		label.size = LABEL_SIZE
		group.add_child(label)
	_dots[key] = dots
	_paint(key)

## Picks item `i` of group `key` ("exp" or "item"), as a click on its dot
## does (IFRadioButton 0x657ad0: the pressed item on, the others off).
func choose(key: String, i: int) -> void:
	if key == "exp":
		exp_choice = i
	else:
		item_choice = i
	_paint(key)

func _paint(key: String) -> void:
	var chosen := exp_choice if key == "exp" else item_choice
	var dots: Array = _dots.get(key, [])
	for i in dots.size():
		var dot := dots[i] as TextureButton
		var art := RADIO_ON if i == chosen else RADIO_OFF
		dot.texture_normal = _builder.load_texture(art) if _builder != null else null

func press_yes() -> void:
	var anyone := 1 if anyone_box != null and anyone_box.button_pressed else 0
	confirmed.emit(1 if exp_choice == 0 else 0, 1 if item_choice == 0 else 0, anyone)
	_close()

func press_no() -> void:
	_close()

## Hidden now and freed next frame: the dialog is an ancestor of the button
## whose press is closing it (round 631's confirm-box crash).
func _close() -> void:
	visible = false
	queue_free()

func _text(key: String, fallback: String) -> String:
	if _builder == null:
		return fallback
	var t := _builder.resolve_text(key)
	return fallback if t == "" or t == key else t
