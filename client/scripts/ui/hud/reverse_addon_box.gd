extends ReverseReturnBox
class_name ReverseAddonBox

## Round 838, OURS: the special reverse return scroll's add-on windows -- the
## party members' list (option 4), the "User Setting Window" with its
## "Setting Location" and "Movement" (option 5), and the slot lists those
## open. The archive's add-on that drew them (vsroplus) is packed and ships no
## layout (MEASURED: no resinfo or 2dt of its own), so every geometry here is
## OpenSRO's: the reverse box's frame, base, title and message, and one
## 252 x 24 com_return_button row per choice at its 31-pixel pitch, Cancel
## last. The texts are the archive's VPLUS_UI_REVERSE_* (MEASURED,
## textuisystem's English column), the fallbacks their English.

## A row was pressed: its index into the rows `build_list` was given.
signal row_chosen(index: int)

const ROW_PITCH := 31
const FIRST_ROW_Y := 76

## The column header the party list puts over its rows (one static, the
## add-on's three column titles).
var header := ""

## Builds a list box: title and message by key (with fallbacks), one button
## per entry of `rows` ({"text": String, "enabled": bool}), and Cancel.
func build_list(builder: UiBuilder, bag_slot: int, title_key: String, title_fallback: String,
		message_key: String, message_fallback: String, rows: Array) -> bool:
	_builder = builder
	slot = bag_slot
	special = true
	var n := rows.size() + 1
	box_size = Vector2(SIZE.x, FIRST_ROW_Y + n * ROW_PITCH + 4)
	name = "ReverseAddonBox"
	size = box_size
	custom_minimum_size = box_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	var layout: UiLayoutParser.LayoutDef = null
	if _builder != null:
		_add_frame()
		layout = _builder.load_layout(MSGBOX_LAYOUT, PackedStringArray(StoreMessageBox.DEFINES), true)
		_add_base(layout)
	var section: UiLayoutParser.SectionDef = layout.sections.get(SECTION) if layout != null else null
	_add_list_title(_text(title_key, title_fallback))
	_add_list_message(section, _text(message_key, message_fallback))
	for i in rows.size():
		var row: Dictionary = rows[i]
		var btn := _list_button(section, 210 + i, "Row%d" % i, FIRST_ROW_Y + i * ROW_PITCH, String(row.get("text", "")))
		if btn is BaseButton:
			(btn as BaseButton).disabled = not bool(row.get("enabled", true))
			(btn as BaseButton).pressed.connect(func() -> void: row_chosen.emit(i))
	var cancel := _list_button(section, 201, "Cancel", FIRST_ROW_Y + rows.size() * ROW_PITCH, _text("UIO_COMMON_CTL_CANCEL", "Cancel"))
	if cancel is BaseButton:
		(cancel as BaseButton).pressed.connect(func() -> void:
			cancelled.emit()
			close())
	if _builder != null:
		UiBuilder.settle_authored_rects(self)
	return true

func _add_list_title(text: String) -> void:
	var def := UiLayoutParser.ControlDef.new()
	def.name = "Title"
	def.type = "CIFStatic"
	def.halign = 1
	def.rect = Rect2i(10, 11, int(box_size.x) - 21, 12)
	var title := _control(def)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_set_text(title, text, false)

func _add_list_message(section: UiLayoutParser.SectionDef, text: String) -> void:
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
	_set_text(msg, text if header == "" else header, false)

func _list_button(section: UiLayoutParser.SectionDef, id: int, member_name: String, y: int, text: String) -> Control:
	var rect := Rect2i(BUTTON_X, y, int(BUTTON_SIZE.x), int(BUTTON_SIZE.y))
	var src: UiLayoutParser.ControlDef = null
	if section != null and section.control_by_name.has("GDR_MBIN_BTN_OK"):
		src = section.control_by_name["GDR_MBIN_BTN_OK"]
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
	def.name = member_name
	def.id = id
	def.ddj = BUTTON_DDJ
	def.text = ""
	var btn := _control(def)
	_set_text(btn, text, true)
	return btn
