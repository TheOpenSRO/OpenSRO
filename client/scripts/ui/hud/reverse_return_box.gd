extends Control
class_name ReverseReturnBox

## The reverse return scroll's message box (round 778;
## docs/protocol/reverse_return_scroll.md). READ from sro_client.exe unless a
## line says otherwise.
##
## **Which box.** A right-click on a bag item of TypeID 3/3/3/3 (the use path
## IFSlotWithHelp::FUN_00676570, `switch (tid >> 0xb)` case 3 at 0x676abe)
## opens message box kind 0x21 (`push 0x21; ... call 0x6ec5d0`) instead of
## sending the use; kind 0x24 is the same box opened from elsewhere
## (0x7ae963, 0x7b00c3). The box is a CIFMessageBox built by
## UI_SILKMALL::FUN_00644c90's case 0x21/0x24 (asm 0x647dff..0x648114):
##
## - its size 300 x 204 (`push 0xcc; push 0x12c`, vslot 0x54, 0x647e60) and
##   title `UIIT_STT_CONFIRM_BOX` (0x647dff);
## - the message static (+0x840) moved to (0x1b, 0x30) and sized 246 x 20
##   (0x647f8a..0x647fbe), its text `UIIT_MSG_QUESTION_SILKMALL_ITEM_USE_
##   REVERSE_PORTAL` ("Select the location used by the reverse return
##   scroll.");
## - four 252 x 24 buttons at x 0x19, each given
##   `interface\ifcommon\com_return_button.ddj` (vslot 0x34 on +0x84):
##     y 0x4c  +0x800, control 200: `UIIT_MSG_ITEM_USE_REVERSE_PORTAL_RETRUN_TO_LAST_RETURN`
##     y 0x6b  +0x808, control 202: `UIIT_MSG_ITEM_USE_REVERSE_PORTAL_RETRUN_TO_LAST_DEATH`
##     y 0x8a  +0x80c, control 203, created here (gwnd 0xba20b0, class
##             0xee9828, font colour 0xfffefbd8): `UIIT_CLT_REVERSE_RETRUN_SCROLL_TO_APPOINT_CHANGE`
##     y 0xa9  +0x804, control 201: `UIO_COMMON_CTL_CANCEL` (0x648105);
## - the box's message map (.data 0xeb5e70.., objdump) sends 200 to 0x63b6e0
##   (result 1), 202 to 0x641eb0 (result 2), 203 to 0x63b9a0 (result 3, the
##   map) and 201 to 0x63b8b0 (result 0); FUN_00797d90 case 0x21 sends the
##   use (SendItem_HandleUseItem 0x796660) with option 2 for result 1, 3 for
##   2 and 7 for 3 (0x798862..0x7988d8), and nothing for 0.
## - Result 3 (0x63b9a0) hides the box, shows the world map (window 0x1c) and
##   puts it in its selection mode with the box's kind (0x622dd0(1, kind));
##   the map's popup then sends option 7 with the chosen point
##   (HudWorldmap.select_mode).
##
## The controls are MsgBoxINIF's (resinfo\ifmessagebox.txt) where the layout
## has them -- 200 GDR_MBIN_BTN_OK, 201 GDR_MBIN_BTN_CANCEL, 202
## GDR_MBIN_BTN_CERTIFY (ClientRect 0,6,0,0, FontColor 254,251,216, HAlign 1)
## -- moved and re-textured as the case does; 203 is built from 200's def at
## its own rect (INFERRED: a created CIFButton's alignment is not read; the
## other three's is used). The message static takes GDR_MBIN_STATIC_MESSAGE1's
## look (INFERRED: which INIF static is +0x840 was not mapped).
##
## OURS: the box is centred on the screen at its own size (the generic
## box's placement was not traced for kind 0x21); it is not modal.

const MSGBOX_LAYOUT := "resinfo\\ifmessagebox.txt"
const FRAME := "interface\\messagebox\\msgbox2_window_"
const BUTTON_DDJ := "interface\\ifcommon\\com_return_button.ddj"
const SECTION := "MsgBoxINIF"

const SIZE := Vector2(300, 204)
const MESSAGE_RECT := Rect2(27, 48, 246, 20)
const BUTTON_X := 25
const BUTTON_SIZE := Vector2(252, 24)

## The four buttons, top to bottom: control id, member, y, text key, English
## fallback (textuisystem's English column), and the option the click sends
## (-1 the map, 0 nothing).
const BUTTONS := [
	[200, "LastReturn", 76, "UIIT_MSG_ITEM_USE_REVERSE_PORTAL_RETRUN_TO_LAST_RETURN", "Move to the last recall point.", 2],
	[202, "LastDeath", 107, "UIIT_MSG_ITEM_USE_REVERSE_PORTAL_RETRUN_TO_LAST_DEATH", "Move to the place where you died.", 3],
	[203, "MapPoint", 138, "UIIT_CLT_REVERSE_RETRUN_SCROLL_TO_APPOINT_CHANGE", "Move to certain location at the map.", -1],
	[201, "Cancel", 169, "UIO_COMMON_CTL_CANCEL", "Cancel", 0],
]
const INIF_NAMES := {200: "GDR_MBIN_BTN_OK", 201: "GDR_MBIN_BTN_CANCEL", 202: "GDR_MBIN_BTN_CERTIFY"}
const MESSAGE_KEY := "UIIT_MSG_QUESTION_SILKMALL_ITEM_USE_REVERSE_PORTAL"
const MESSAGE_FALLBACK := "Select the location used by the reverse return scroll."
const TITLE_KEY := "UIIT_STT_CONFIRM_BOX"
const TITLE_FALLBACK := "Confirmation window"
## The button text colour of the created control 203 (0xfffefbd8, READ) and
## the layout's for the others.
const BUTTON_FONT_COLOR := Color8(254, 251, 216)

## Retail's options (the 0x704C option byte).
const OPTION_RECALL := 2
const OPTION_DEATH := 3
const OPTION_MAP := 7

## A destination button: 2 the recall point, 3 the death point.
signal option_chosen(option: int)
## The map button (result 3): the world map's selection mode is wanted.
signal map_requested
## Cancel (result 0).
signal cancelled

## The bag slot of the scroll the box was opened for.
var slot := -1
var _builder: UiBuilder

## Builds the box for the scroll in bag slot `bag_slot`. Without a layout
## (a test's bare builder) the controls are built from the values above.
func build(builder: UiBuilder, bag_slot: int) -> bool:
	_builder = builder
	slot = bag_slot
	name = "ReverseReturnBox"
	size = SIZE
	custom_minimum_size = SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	var layout: UiLayoutParser.LayoutDef = null
	if _builder != null:
		_add_frame()
		layout = _builder.load_layout(MSGBOX_LAYOUT, PackedStringArray(StoreMessageBox.DEFINES), true)
		_add_base(layout)
	_add_title()
	var section: UiLayoutParser.SectionDef = layout.sections.get(SECTION) if layout != null else null
	_add_message(section)
	for b in BUTTONS:
		_add_button(section, b)
	if _builder != null:
		UiBuilder.settle_authored_rects(self)
	return true

func _add_frame() -> void:
	var def := UiLayoutParser.ControlDef.new()
	def.name = "Frame"
	def.type = "CIFFrame"
	def.ddj = FRAME
	def.rect = Rect2i(Vector2i.ZERO, Vector2i(SIZE))
	var frame := _builder.build_control(def)
	if frame != null:
		frame.mouse_filter = Control.MOUSE_FILTER_PASS
		add_child(frame)

## ifmessagebox's "Create": the background tile, which the box's resize
## (0x63b420) sizes to (width - 32, height - 56).
func _add_base(layout: UiLayoutParser.LayoutDef) -> void:
	if layout == null or not layout.sections.has("Create"):
		return
	var base := _builder.build_section(layout, "Create")
	if base == null:
		return
	base.name = "MsgBoxBase"
	add_child(base)
	var tile := base.get_node_or_null("GDR_MSGBOX_BG") as Control
	if tile != null:
		var r := Rect2(16, 40, SIZE.x - 32, SIZE.y - 56)
		tile.set_meta(UiBuilder.AUTHORED_RECT_META, r)
		tile.position = r.position
		tile.size = r.size

## The title static at (10, 11), the width less 21 wide (message_box.md).
func _add_title() -> void:
	var def := UiLayoutParser.ControlDef.new()
	def.name = "Title"
	def.type = "CIFStatic"
	def.halign = 1
	def.rect = Rect2i(10, 11, int(SIZE.x) - 21, 12)
	var title := _control(def)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_set_text(title, _text(TITLE_KEY, TITLE_FALLBACK), false)

func _add_message(section: UiLayoutParser.SectionDef) -> void:
	var def: UiLayoutParser.ControlDef = null
	if section != null and section.control_by_name.has("GDR_MBIN_STATIC_MESSAGE1"):
		def = (section.control_by_name["GDR_MBIN_STATIC_MESSAGE1"] as UiLayoutParser.ControlDef).with_rect(Rect2i(MESSAGE_RECT))
	else:
		def = UiLayoutParser.ControlDef.new()
		def.type = "CIFStatic"
		def.halign = 1
		def.rect = Rect2i(MESSAGE_RECT)
	def.name = "Message"
	def.text = ""
	var msg := _control(def)
	msg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_set_text(msg, _text(MESSAGE_KEY, MESSAGE_FALLBACK), false)

func _add_button(section: UiLayoutParser.SectionDef, spec: Array) -> void:
	var rect := Rect2i(BUTTON_X, int(spec[2]), int(BUTTON_SIZE.x), int(BUTTON_SIZE.y))
	var src: UiLayoutParser.ControlDef = null
	var inif: String = INIF_NAMES.get(int(spec[0]), INIF_NAMES[200])
	if section != null and section.control_by_name.has(inif):
		src = section.control_by_name[inif]
	var def: UiLayoutParser.ControlDef
	if src != null:
		def = src.with_rect(rect)
	else:
		def = UiLayoutParser.ControlDef.new()
		def.type = "CIFButton"
		def.halign = 1
		def.client_rect = Rect2i(0, 6, 0, 0)
		def.font_color = BUTTON_FONT_COLOR
		def.rect = rect
	def.name = String(spec[1])
	def.id = int(spec[0])
	def.ddj = BUTTON_DDJ
	def.text = ""
	var btn := _control(def)
	_set_text(btn, _text(String(spec[3]), String(spec[4])), true)
	var option := int(spec[5])
	if btn is BaseButton:
		(btn as BaseButton).pressed.connect(_on_pressed.bind(option))

## A control from a def: the builder's when there is one, else a plain
## stand-in of the same kind (tests without an archive).
func _control(def: UiLayoutParser.ControlDef) -> Control:
	var node: Control = null
	if _builder != null:
		node = _builder.build_control(def)
	if node == null:
		node = Button.new() if def.type == "CIFButton" else Label.new()
	node.name = def.name
	node.position = Vector2(def.rect.position)
	node.size = Vector2(def.rect.size)
	node.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(def.rect))
	add_child(node)
	return node

func _set_text(node: Control, text: String, is_button: bool) -> void:
	if _builder != null and node.has_meta(UiBuilder.STATIC_DEF_META):
		if is_button:
			_builder.set_button_text(node, text)
		else:
			_builder.set_static_text(node, text)
		return
	if node is Button:
		(node as Button).text = text
	elif node is Label:
		(node as Label).text = text
	else:
		var l := Label.new()
		l.name = "ButtonLabel" if is_button else "Text"
		l.text = text
		node.add_child(l)

func _text(key: String, fallback: String) -> String:
	if _builder == null:
		return fallback
	var t := _builder.resolve_text(key)
	return fallback if t == "" or t == key else t

func _on_pressed(option: int) -> void:
	match option:
		0:
			cancelled.emit()
			close()
		-1:
			map_requested.emit()
		_:
			option_chosen.emit(option)
			close()

## The button whose text is `caption`, for the QA hooks and tests.
func button(caption: String) -> BaseButton:
	for b in find_children("*", "BaseButton", true, false):
		var n := b as Node
		if n is Button and (n as Button).text == caption:
			return n as BaseButton
		var l := n.get_node_or_null("ButtonLabel") as Label
		if l != null and l.text == caption:
			return n as BaseButton
	return null

## The button for one of BUTTONS' members ("LastReturn", "LastDeath",
## "MapPoint", "Cancel").
func member(member_name: String) -> BaseButton:
	return find_child(member_name, true, false) as BaseButton

## The caption shown on a member button.
func caption_of(member_name: String) -> String:
	var b := member(member_name)
	if b == null:
		return ""
	if b is Button:
		return (b as Button).text
	var l := b.get_node_or_null("ButtonLabel") as Label
	return l.text if l != null else ""

## Centred on a `screen`-sized display at its own size (OURS, see the top).
func screen_position(screen: Vector2) -> Vector2:
	return Vector2(int(screen.x) / 2 - int(SIZE.x) / 2, int(screen.y) / 2 - int(SIZE.y) / 2)

## Hidden now, freed at the end of the frame (the box is an ancestor of the
## pressed button, round 631).
func close() -> void:
	if is_queued_for_deletion():
		return
	name = "%s_closing" % name
	visible = false
	queue_free()
