extends Control
class_name CaptchaWindow

## The image-code window a legacy gateway asks for after a right password
## (round 788): retail's window 0x2f, CIFConfirmbox (vtable 0xd9a44c,
## OnCreate 0x62cd10), from resinfo\ifconfirmbox.txt. READ from sro_client.exe:
##
## - Layout: "Create" holds the frame (id 2, imagecode_window.ddj, 400 x 180);
##   "MainBox" the caption (3, UIIT_PAG_GLOBAL_AUTHENTICATION), the picture
##   (4, GDR_BIC_IMAGECODE, a CIFBltImage, 200 x 64), the explanation (5, a
##   CIFPML, UIIT_STT_GLOBAL_AUTHENTICATION_NOTICE), the edit (6,
##   GDR_EDT_CODEIN) and the button (7, GDR_BTN_ACCEPT, UIIS_CTL_CONFIRM).
##   No Cancel, no close button, no timer.
## - 0x2322 (the title's event 0x1002): the window shows, the picture is
##   replaced (RetailCaptcha: drawn unscaled at the control's origin), the
##   edit is cleared and focused, the Enter latch reset (0x62caf0).
## - Submit (0x62cbe0): Enter in the edit (WM_CHAR 0x0D, once until the next
##   picture: the latch +0x380) or the button (which does not check the
##   latch): the text as typed -- no case change, no trimming, no empty check
##   -- goes out in 0x6323; the window then takes no input (0xb8f540(0),
##   INFERRED) until the next picture.
## - 0xA323, whatever its result: the window hides (0x86c99f); a wrong code's
##   message goes to the title's message line (Login.gd).
##
## OURS: centred on the screen (where retail places window 0x2f was not
## read); the explanation's PML markup is reduced to plain lines; the edit
## takes up to 0x200 characters (CIFEdit's default, INFERRED to apply).

const LAYOUT := "resinfo\\ifconfirmbox.txt"
const SIZE := Vector2(400, 180)
const ID_FRAME := 2
const ID_CAPTION := 3
const ID_IMAGE := 4
const ID_EXPLAIN := 5
const ID_EDIT := 6
const ID_ACCEPT := 7
const EDIT_MAX := 0x200

## The code the player typed, to go out in 0x6323.
signal submitted(code: String)

var _builder: UiBuilder = null
var picture: TextureRect = null
var edit: LineEdit = null
var accept: BaseButton = null
var _latch := false
var _taking := true

func build(builder: UiBuilder) -> void:
	_builder = builder
	name = "CaptchaWindow"
	size = SIZE
	custom_minimum_size = SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 50
	var layout: UiLayoutParser.LayoutDef = _builder.load_layout(LAYOUT) if _builder != null else null
	var create: UiLayoutParser.SectionDef = layout.sections.get("Create") if layout != null else null
	var main: UiLayoutParser.SectionDef = layout.sections.get("MainBox") if layout != null else null
	var frame_def := _def(create, ID_FRAME, "CIFStatic", Rect2i(0, 0, 400, 180))
	var frame := _control(frame_def)
	if frame == null or _builder == null:
		var plate := FrontEndUi.plate()
		plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(plate)
		move_child(plate, 0)
	if frame != null:
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cap := _control(_def(main, ID_CAPTION, "CIFStatic", Rect2i(85, 18, 229, 15)))
	_set_text(cap, _text("UIIT_PAG_GLOBAL_AUTHENTICATION", LoginMessages.text(null, LoginMessages.KEY_CAPTCHA_TITLE)))
	var ex_def := _def(main, ID_EXPLAIN, "CIFStatic", Rect2i(32, 40, 336, 40))
	var ex := Label.new()
	ex.name = "Explain"
	ex.position = Vector2(ex_def.rect.position)
	ex.size = Vector2(ex_def.rect.size)
	ex.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ex.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ex.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ex.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	ex.text = plain_pml(_text("UIIT_STT_GLOBAL_AUTHENTICATION_NOTICE", "Type the characters in the picture."))
	add_child(ex)
	var img_def := _def(main, ID_IMAGE, "CIFStatic", Rect2i(33, 80, 200, 64))
	picture = TextureRect.new()
	picture.name = "ImageCode"
	picture.position = Vector2(img_def.rect.position)
	picture.size = Vector2(img_def.rect.size)
	picture.stretch_mode = TextureRect.STRETCH_KEEP # READ: unscaled, at the origin
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(picture)
	var ed := _control(_def(main, ID_EDIT, "CIFEdit", Rect2i(260, 88, 95, 15)))
	edit = ed as LineEdit
	if edit == null:
		edit = LineEdit.new()
		edit.position = Vector2(260, 88)
		edit.size = Vector2(95, 15)
		add_child(edit)
	edit.name = "CodeIn"
	edit.placeholder_text = ""
	edit.max_length = EDIT_MAX
	edit.text_submitted.connect(func(_t: String) -> void: _on_enter())
	var acc := _control(_def(main, ID_ACCEPT, "CIFButton", Rect2i(257, 121, 55, 18)))
	_set_text(acc, _text("UIIS_CTL_CONFIRM", "OK"))
	accept = acc as BaseButton
	if accept != null:
		accept.pressed.connect(_on_accept)
	if _builder != null:
		UiBuilder.settle_authored_rects(self)
	visible = false

## The PML explanation as plain lines (OURS): <br> a line break, other tags
## dropped.
static func plain_pml(s: String) -> String:
	var out := s.replace("<br>", "\n").replace("<BR>", "\n")
	var re := RegEx.create_from_string("<[^>]*>")
	return re.sub(out, "", true).strip_edges()

## A new picture (0x2322): shown, the edit cleared and focused, input taken.
func show_image(blob: PackedByteArray) -> String:
	var r := RetailCaptcha.decode(blob)
	if r.has("error"):
		# READ (0x62c6d7): a picture that does not decompress is not redrawn.
		push_warning("CaptchaWindow: %s" % r["error"])
	else:
		picture.texture = ImageTexture.create_from_image(r["image"])
		picture.size = Vector2(int(r["width"]), int(r["height"]))
	visible = true
	edit.text = ""
	_latch = false
	_taking = true
	edit.editable = true
	if edit.is_inside_tree():
		edit.grab_focus()
	return str(r.get("error", ""))

## 0xA323 arrived (READ: the window hides whatever the result).
func hide_window() -> void:
	visible = false

func _on_enter() -> void:
	if _latch or not _taking:
		return
	_latch = true
	_submit()

func _on_accept() -> void:
	if not _taking:
		return
	_submit()

func _submit() -> void:
	_taking = false
	edit.editable = false
	print("CAPTCHA: code submitted (%d characters)" % edit.text.length())
	submitted.emit(edit.text)

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
		match def.type:
			"CIFButton":
				node = Button.new()
			"CIFEdit":
				node = LineEdit.new()
			_:
				var l := Label.new()
				l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				node = l
	node.position = Vector2(def.rect.position)
	node.size = Vector2(def.rect.size)
	node.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(def.rect))
	add_child(node)
	return node

func _set_text(node: Control, text: String) -> void:
	if node == null:
		return
	if _builder != null and node.has_meta(UiBuilder.STATIC_DEF_META):
		if node is BaseButton:
			_builder.set_button_text(node, text)
		else:
			_builder.set_static_text(node, text)
		return
	if node is Button:
		(node as Button).text = text
	elif node is Label:
		(node as Label).text = text

func _text(key: String, fallback: String) -> String:
	if _builder == null:
		return fallback
	var t := _builder.resolve_text(key)
	return fallback if t == "" or t == key else t
