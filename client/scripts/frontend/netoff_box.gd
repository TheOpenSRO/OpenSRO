extends Control
class_name NetOffBox

## The box a front-end screen shows when the server closes the connection
## (round 788). READ from sro_client.exe:
##
## - The title, character select, character create and quick start all
##   handle the drop in slot 40 (0x862450): a CIFMessageBox (class 0xee95a0,
##   resinfo\ifmessagebox.txt section MsgBoxINIF, created by 0x63e570), 308 x
##   148 at (W/2 - 150, H/2 - 72). 0x643c20(1) loads the section and
##   0x644c90(1, 0) -- case 1 -- titles it UIIT_STT_CONFIRM_BOX and puts
##   UIIT_MSG_MSGBOX_NETOFF in line 1 (GDR_MBIN_STATIC_MESSAGE1, id 1); of
##   the buttons only 202, GDR_MBIN_BTN_CERTIFY "UIIT_CTL_CONFIRM", stays
##   (200 YES and 201 NO hidden).
## - Its Confirm (0x641eb0, message map 0xeb5eb8) switches to CPSQuit for a
##   type-1 box: the client QUITS. There is no way back to the title.
## - The world (CPSMission::vslot_040 0x84ae90) shows the same box and quits
##   the same way (not built here: World3D still returns to the title, which
##   its QA reconnect hooks rely on -- docs/TODO.md).
##
## The controls are MsgBoxINIF's own rects and art; the frame is the
## message boxes' msgbox2_window_ (docs/protocol/message_box.md) and the
## title static sits at (10, 11), the width less 21 wide, as the other
## message boxes' (ReverseReturnBox). OURS: whether the box is modal is OPEN;
## this one blocks the screen under it (a full-screen catcher).

const MSGBOX_LAYOUT := "resinfo\\ifmessagebox.txt"
const FRAME := "interface\\messagebox\\msgbox2_window_"
const SECTION := "MsgBoxINIF"
## READ (0x862450): the box's size and its offset from the screen's middle.
const SIZE := Vector2(308, 148)
const OFFSET := Vector2(150, 72)
const ID_MESSAGE1 := 1
const ID_CONFIRM := 202

## Confirm was pressed (before the quit; tests replace `on_confirm`).
signal confirmed
## What Confirm does: quits the client (READ), unless a test sets another.
var on_confirm := Callable()

var _builder: UiBuilder = null
var box: Control = null
var message: Control = null
var confirm_button: BaseButton = null

## READ (0x862450): (W/2 - 150, H/2 - 72), whole pixels.
static func box_position(screen: Vector2) -> Vector2:
	return Vector2(int(screen.x) / 2 - int(OFFSET.x), int(screen.y) / 2 - int(OFFSET.y))

## Shows the box over `parent` (a screen), from the player's archive when
## `media` is there, plain otherwise. Returns the box.
static func show_on(parent: Node, media: Pk2Reader, text_table: UiTextTable) -> NetOffBox:
	var b := NetOffBox.new()
	b.name = "NetOffBox"
	parent.add_child(b)
	b.build(UiBuilder.new(media, text_table) if media != null else null, text_table)
	UiSounds.error_box("connection closed")
	return b

func build(builder: UiBuilder, text_table: UiTextTable) -> void:
	_builder = builder
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP # OURS: the screen under it takes nothing
	z_index = 100
	box = Control.new()
	box.name = "MsgBox"
	box.size = SIZE
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(box)
	var layout: UiLayoutParser.LayoutDef = null
	if _builder != null:
		var fd := UiLayoutParser.ControlDef.new()
		fd.name = "Frame"
		fd.type = "CIFFrame"
		fd.ddj = FRAME
		fd.rect = Rect2i(Vector2i.ZERO, Vector2i(SIZE))
		var frame := _builder.build_control(fd)
		if frame != null:
			frame.mouse_filter = Control.MOUSE_FILTER_PASS
			box.add_child(frame)
		layout = _builder.load_layout(MSGBOX_LAYOUT, PackedStringArray(StoreMessageBox.DEFINES), true)
		if layout != null and layout.sections.has("Create"):
			var base := _builder.build_section(layout, "Create")
			if base != null:
				base.name = "MsgBoxBase"
				box.add_child(base)
				var tile := base.get_node_or_null("GDR_MSGBOX_BG") as Control
				if tile != null:
					var r := Rect2(16, 40, SIZE.x - 32, SIZE.y - 56)
					tile.set_meta(UiBuilder.AUTHORED_RECT_META, r)
					tile.position = r.position
					tile.size = r.size
	else:
		var plate := FrontEndUi.plate()
		plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(plate)
	var section: UiLayoutParser.SectionDef = layout.sections.get(SECTION) if layout != null else null
	var td := UiLayoutParser.ControlDef.new()
	td.name = "Title"
	td.type = "CIFStatic"
	td.halign = 1
	td.rect = Rect2i(10, 11, int(SIZE.x) - 21, 12)
	var title := _control(td)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_set_text(title, LoginMessages.confirm_title(text_table), false)
	var md := _def(section, ID_MESSAGE1, "CIFStatic", Rect2i(0, 52, 300, 12))
	md.name = "Message"
	md.text = ""
	message = _control(md)
	message.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_set_text(message, LoginMessages.netoff(text_table), false)
	var cd := _def(section, ID_CONFIRM, "CIFButton", Rect2i(112, 99, 76, 24))
	cd.name = "Confirm"
	cd.text = ""
	var c := _control(cd)
	_set_text(c, _confirm_text(text_table), true)
	if c is BaseButton:
		confirm_button = c as BaseButton
		confirm_button.pressed.connect(_on_confirm)
	if _builder != null:
		UiBuilder.settle_authored_rects(box)
	_place()
	resized.connect(_place)

func _confirm_text(t: UiTextTable) -> String:
	if t != null and t.has("UIIT_CTL_CONFIRM"):
		var s := t.get_text("UIIT_CTL_CONFIRM", "")
		if s != "":
			return s
	return "OK" # OURS fallback

func _place() -> void:
	if size.x <= 0 and not is_inside_tree():
		return
	var s := size if size.x > 0 else get_viewport_rect().size
	box.position = box_position(s)

func _def(section: UiLayoutParser.SectionDef, id: int, type: String, fallback: Rect2i) -> UiLayoutParser.ControlDef:
	if section != null:
		var d := FrontEndFrame.by_id(section, id)
		if d != null:
			return d.with_rect(d.rect)
	var def := UiLayoutParser.ControlDef.new()
	def.type = type
	def.id = id
	def.halign = 1
	def.rect = fallback
	return def

func _control(def: UiLayoutParser.ControlDef) -> Control:
	var node: Control = null
	if _builder != null:
		node = _builder.build_control(def)
	if node == null:
		node = Button.new() if def.type == "CIFButton" else Label.new()
		if node is Label:
			(node as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	node.name = def.name
	node.position = Vector2(def.rect.position)
	node.size = Vector2(def.rect.size)
	node.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(def.rect))
	box.add_child(node)
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

## The text the box shows (tests, logs).
func message_text() -> String:
	if message is Label:
		return (message as Label).text
	for l in message.find_children("*", "Label", true, false):
		return (l as Label).text
	return ""

func _on_confirm() -> void:
	confirmed.emit()
	print("FRONTEND: disconnected box confirmed -- quitting (READ, 0x641eb0 -> CPSQuit)")
	if on_confirm.is_valid():
		on_confirm.call()
	elif is_inside_tree():
		get_tree().quit()
