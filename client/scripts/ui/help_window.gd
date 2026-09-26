extends Control
class_name HelpWindow

## The in-client Help window. The original client showed help and notices
## through an embedded Internet Explorer control (an ifhelp/web-board panel);
## Godot has no webview, so this renders our own bundled Markdown docs
## natively instead. It is grounded in the authored slot: the ESC System
## window's Help button (round 138) and the authored ifgameguide frame, which
## this reuses for the window chrome via UiBuilder.
##
## Inside: a left-hand list of documents, a RichTextLabel fed by
## MdToBbcode.convert, and the authored frame's own Close. The GM document's
## GM section is shown only to a GM (the doc marks it with sentinels).
##
## Everything not from the authored layout -- the doc list contents, the
## rendered text -- is our own and disclosed.

const AUTHORED_LAYOUT := "resinfo\\ifgameguide.txt"

## The window's registry entry: GDR_GAMEGUIDE, a CIFGameGuide (a CIFMainFrame)
## in ginterface.txt's "GameGuide" section, 420x452 on `mframe_wnd_`, which
## CIFGameGuide::Create (0x765920) fills with ifgameguide.txt. Its caption is
## not used: the entry's Text is UIIT_STT_GAMEEVENTGUIDE under
## `#ifdef RENEWAL_NEWBIE_SUPPORT` and UIIT_STT_HELP otherwise, both keys are
## in the client, and which one this build defines is not read. The window
## shows this project's own documents, titled "Help".
const REGISTRY := {"name": "GDR_GAMEGUIDE", "caption": false}

## Sentinels that fence the GM-only part of a bundled doc; stripped for a
## non-GM before the Markdown is converted.
const GM_SECTION_OPEN := "<!-- gm-only -->"
const GM_SECTION_CLOSE := "<!-- /gm-only -->"

var _builder: UiBuilder
var _frame: HudWindow
var _list: ItemList
var _content: RichTextLabel
var _docs: Array = []          # [{title, path}]
var _is_gm := false

## docs is an array of {"title": String, "path": String} (res:// paths).
func setup(builder: UiBuilder, docs: Array, is_gm: bool) -> bool:
	_builder = builder
	_docs = docs
	_is_gm = is_gm
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

	_frame = HudWindow.new()
	_frame.name = "HelpFrame"
	add_child(_frame)
	var framed := _frame.build(builder, AUTHORED_LAYOUT, "Help", PackedStringArray(),
		PackedStringArray(), false, REGISTRY)
	_authored = framed
	if not framed:
		# The authored layout did not build (an operator's archive may lack
		# it); a plain sized frame still gives a working, legible Help window.
		_frame.queue_free()
		_frame = null
		_build_fallback_frame()
	else:
		_frame.centre()
	_frame.closed.connect(func() -> void: hide())

	_build_body()
	_populate_list()
	if not _docs.is_empty():
		_list.select(0)
		_show_doc(0)
	hide()
	return true

## The window's own root Control (the authored frame, or the fallback panel).
func _root() -> Control:
	return _frame if _frame != null else self

func _build_fallback_frame() -> void:
	_frame = HudWindow.new()
	_frame.name = "HelpFrame"
	_frame.custom_minimum_size = Vector2(560, 460)
	_frame.size = Vector2(560, 460)
	var bg := ColorRect.new()
	bg.name = "Bg"
	bg.color = Color(0.09, 0.08, 0.07, 0.97)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_frame.add_child(bg)
	var title := Label.new()
	title.text = "Help"
	title.position = Vector2(HudWindow.TITLE_INSET, HudWindow.TITLE_TEXT_Y)
	_frame.add_child(title)
	var close := Button.new()
	close.text = "X"
	close.position = Vector2(_frame.size.x - 30, 8)
	close.size = Vector2(22, 22)
	close.pressed.connect(func() -> void: hide())
	_frame.add_child(close)
	add_child(_frame)
	_frame.centre()

## Lays the document list and the content area inside the frame, on top of
## the authored interior (added last, so they draw above it), each over its
## own opaque background so authored art does not bleed through the text.
func _build_body() -> void:
	var frame := _root()
	var w: float = frame.size.x
	var h: float = frame.size.y
	var top := HudWindow.TITLE_BAR_HEIGHT
	var margin := 12.0
	var list_w := minf(150.0, w * 0.32)

	# The authored layout has a document menu of its own, GDR_GUIDE_MENU (the
	# CIFGGMenu frame the original lists its guide sections in, hung to the
	# LEFT of the main frame at x=-206). When it built, the document list goes
	# inside it and the whole main frame is left to the text; otherwise the
	# list takes a strip inside the frame.
	var list_rect := Rect2(Vector2(margin, top), Vector2(list_w, h - top - margin))
	var content_x := margin + list_w + margin
	var menu: Control = null
	if _authored and _frame != null:
		menu = _frame.node("GDR_GUIDE_MENU") as Control
	if menu != null and menu.size.x > 40.0 and menu.size.y > 60.0:
		list_rect = Rect2(menu.position + Vector2(14.0, 36.0), menu.size - Vector2(28.0, 50.0))
		content_x = margin

	var list_bg := ColorRect.new()
	list_bg.color = Color(0.05, 0.05, 0.05, 0.9)
	list_bg.position = list_rect.position
	list_bg.size = list_rect.size
	list_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	frame.add_child(list_bg)

	_list = ItemList.new()
	_list.name = "DocList"
	_list.position = list_bg.position
	_list.size = list_bg.size
	_list.mouse_filter = Control.MOUSE_FILTER_STOP
	if _builder != null:
		var font := _builder.font_at(0)
		if font != null:
			_list.add_theme_font_override("font", font)
	_list.item_selected.connect(_show_doc)
	frame.add_child(_list)

	var content_bg := ColorRect.new()
	content_bg.color = Color(0.08, 0.07, 0.06, 0.95)
	content_bg.position = Vector2(content_x, top)
	content_bg.size = Vector2(w - content_x - margin, h - top - margin)
	content_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	frame.add_child(content_bg)

	_content = RichTextLabel.new()
	_content.name = "Content"
	_content.bbcode_enabled = true
	_content.scroll_active = true
	_content.selection_enabled = true
	_content.fit_content = false
	_content.position = content_bg.position + Vector2(8, 8)
	_content.size = content_bg.size - Vector2(16, 16)
	_content.mouse_filter = Control.MOUSE_FILTER_STOP
	if _builder != null:
		var font := _builder.font_at(0)
		if font != null:
			_content.add_theme_font_override("normal_font", font)
			_content.add_theme_font_override("bold_font", font)
	frame.add_child(_content)

func _populate_list() -> void:
	_list.clear()
	for d in _docs:
		_list.add_item(String(d.get("title", "?")))

func _show_doc(index: int) -> void:
	if index < 0 or index >= _docs.size():
		return
	var path := String(_docs[index].get("path", ""))
	_content.text = MdToBbcode.convert(_load_doc(path))
	_content.scroll_to_line(0)

## Reads a bundled doc, dropping the GM-only section for a non-GM.
func _load_doc(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "# Not found\n\nThe document `%s` is not bundled with this build." % path
	var text := FileAccess.get_file_as_string(path)
	if not _is_gm:
		text = _strip_gm_sections(text)
	return text

## Removes every GM_SECTION_OPEN..GM_SECTION_CLOSE span (inclusive).
static func _strip_gm_sections(text: String) -> String:
	while true:
		var start := text.find(GM_SECTION_OPEN)
		if start < 0:
			break
		var end := text.find(GM_SECTION_CLOSE, start)
		if end < 0:
			text = text.substr(0, start)
			break
		text = text.substr(0, start) + text.substr(end + GM_SECTION_CLOSE.length())
	return text

func open() -> void:
	show()
	if _frame != null:
		_frame.move_to_front()

## Whether the authored ifgameguide frame built (false = the plain fallback).
func has_authored_frame() -> bool:
	return _authored

var _authored := false

func set_is_gm(is_gm: bool) -> void:
	if _is_gm == is_gm:
		return
	_is_gm = is_gm
	# Re-render the current doc so a newly-known GM sees the GM section.
	if _list != null and _list.is_anything_selected():
		_show_doc(_list.get_selected_items()[0])
