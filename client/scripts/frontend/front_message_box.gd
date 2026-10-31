extends Control
class_name FrontMessageBox

## A yes/no question box before the world, built from the client's own
## message box (round 848): the update prompt Boot shows when a newer
## release is out. The question is OURS -- the retail client has no update
## prompt of its own (its patcher is a separate program) -- so the box is
## put together from the original's parts, the way NetOffBox puts together
## the NETOFF box:
##
## - CIFMessageBox's own layout, resinfo\ifmessagebox.txt: the "Create"
##   section's body tile GDR_MSGBOX_BG (com_bg_tile_b, 16, 40) and section
##   MsgBoxINIF's controls -- the two message lines GDR_MBIN_STATIC_MESSAGE1
##   (id 1, 0, 52, 300 x 12) and _MESSAGE2 (id 2, 6, 70, 300 x 12), and the
##   buttons GDR_MBIN_BTN_OK (200, "UIIT_CTL_YES", 72, 99) and _BTN_CANCEL
##   (201, "UIIT_CTL_NO", 152, 99), com_button.ddj 76 x 24 -- READ from the
##   archive's layout, as the client's 0x643c20(1) loads it;
## - the box 308 x 148 at (W/2 - 150, H/2 - 72) on the message boxes'
##   msgbox2_window_ frame, its title at (10, 11), the width less 21 wide,
##   in UIIT_STT_CONFIRM_BOX's words -- as the client places its MsgBoxINIF
##   box (READ, 0x862450 / 0x644c90; NetOffBox's header);
## - only the YES and NO buttons shown (the client hides the ones a box type
##   does not use, 0x644c90; here the type is OURS: a yes/no question).
##
## OURS: which lines the question takes, that Escape answers No, and that
## the box blocks the screen under it. Without the player's Media.pk2 (a run
## with no game data, where none of this art exists) the same geometry is
## drawn with plain controls.

const MSGBOX_LAYOUT := "resinfo\\ifmessagebox.txt"
const FRAME := "interface\\messagebox\\msgbox2_window_"
const SECTION := "MsgBoxINIF"
const SIZE := Vector2(308, 148)
const OFFSET := Vector2(150, 72)
const ID_MESSAGE1 := 1
const ID_MESSAGE2 := 2
const ID_YES := 200
const ID_NO := 201
## The text table the captions come from (the title's own).
const TEXT_TABLE_PATH := "server_dep\\silkroad\\textdata\\textuisystem.txt"

## YES was pressed.
signal accepted
## NO was pressed (or Escape).
signal declined

var _builder: UiBuilder = null
var _text: UiTextTable = null
var box: Control = null
var title: Control = null
var line1: Control = null
var line2: Control = null
var yes_button: BaseButton = null
var no_button: BaseButton = null
var _answered := false

## READ (0x862450): (W/2 - 150, H/2 - 72), whole pixels.
static func box_position(screen: Vector2) -> Vector2:
	return Vector2(int(screen.x) / 2 - int(OFFSET.x), int(screen.y) / 2 - int(OFFSET.y))

## The archive's UI text table, or null.
static func load_text_table(media: Pk2Reader) -> UiTextTable:
	if media == null:
		return null
	var entry := ObjectLoader.find_file(media, TEXT_TABLE_PATH)
	if entry == null:
		return null
	return UiTextTable.parse(media.read_file(entry))

## Builds the box with `line_1` and `line_2` (either may be "").
func build(media: Pk2Reader, text_table: UiTextTable, line_1: String, line_2: String) -> void:
	_builder = UiBuilder.new(media, text_table) if media != null else null
	_text = text_table
	name = "FrontMessageBox"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP # OURS: the screen under it takes nothing
	z_index = 100
	FrontEndUi.apply_client_font(self, media)
	box = Control.new()
	box.name = "MsgBox"
	box.size = SIZE
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(box)
	var section: UiLayoutParser.SectionDef = null
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
		var layout := _builder.load_layout(MSGBOX_LAYOUT, PackedStringArray(StoreMessageBox.DEFINES), true)
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
		if layout != null:
			section = layout.sections.get(SECTION)
	else:
		var plate := ColorRect.new()
		plate.color = Color(0, 0, 0, 0.85) # no archive: no art to draw (OURS)
		plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(plate)
	var td := UiLayoutParser.ControlDef.new()
	td.name = "Title"
	td.type = "CIFStatic"
	td.halign = 1
	td.rect = Rect2i(10, 11, int(SIZE.x) - 21, 12)
	title = _static(td, LoginMessages.confirm_title(text_table))
	var d1 := _def(section, ID_MESSAGE1, "CIFStatic", Rect2i(0, 52, 300, 12))
	d1.name = "Message1"
	line1 = _static(d1, line_1)
	var d2 := _def(section, ID_MESSAGE2, "CIFStatic", Rect2i(6, 70, 300, 12))
	d2.name = "Message2"
	line2 = _static(d2, line_2)
	var yd := _def(section, ID_YES, "CIFButton", Rect2i(72, 99, 76, 24))
	yd.name = "Yes"
	yes_button = _button(yd, _caption("UIIT_CTL_YES", "Yes"))
	yes_button.pressed.connect(_on_yes)
	var nd := _def(section, ID_NO, "CIFButton", Rect2i(152, 99, 76, 24))
	nd.name = "No"
	no_button = _button(nd, _caption("UIIT_CTL_NO", "No"))
	no_button.pressed.connect(_on_no)
	if _builder != null:
		UiBuilder.settle_authored_rects(box)
	_place()
	resized.connect(_place)

func _caption(key: String, fallback: String) -> String:
	if _text != null and _text.has(key):
		var s := _text.get_text(key, "")
		if s != "" and s != key:
			return s
	return fallback # OURS fallback

func _place() -> void:
	var s := size if size.x > 0 else (get_viewport_rect().size if is_inside_tree() else SIZE)
	box.position = box_position(s)

func _def(section: UiLayoutParser.SectionDef, id: int, type: String, fallback: Rect2i) -> UiLayoutParser.ControlDef:
	if section != null:
		var d := FrontEndFrame.by_id(section, id)
		if d != null:
			var copy := d.with_rect(d.rect)
			copy.text = ""
			return copy
	var def := UiLayoutParser.ControlDef.new()
	def.type = type
	def.id = id
	def.halign = 1
	def.valign = 1
	def.rect = fallback
	if type == "CIFButton":
		def.ddj = "interface\\ifcommon\\com_button.ddj"
		def.client_rect = Rect2i(0, 6, 0, 0)
	return def

func _static(def: UiLayoutParser.ControlDef, text: String) -> Control:
	var node: Control = null
	if _builder != null:
		node = _builder.build_control(def)
		_builder.set_static_text(node, text)
	else:
		var l := Label.new()
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.text = text
		node = l
	node.name = def.name
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.position = Vector2(def.rect.position)
	node.size = Vector2(def.rect.size)
	node.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(def.rect))
	box.add_child(node)
	return node

func _button(def: UiLayoutParser.ControlDef, text: String) -> BaseButton:
	var b := FrontEndUi.cif_button(_builder, def, text, "interface\\ifcommon\\com_button.ddj", Vector2(76, 24))
	b.name = def.name
	box.add_child(b)
	return b

## The text a line shows (tests, logs).
func line_text(n: Control) -> String:
	if n is Label:
		return (n as Label).text
	for l in n.find_children("*", "Label", true, false):
		return (l as Label).text
	return ""

func _on_yes() -> void:
	if _answered:
		return
	_answered = true
	accepted.emit()

func _on_no() -> void:
	if _answered:
		return
	_answered = true
	declined.emit()

## OURS: Escape answers No.
func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and (event as InputEventKey).pressed \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_on_no()
