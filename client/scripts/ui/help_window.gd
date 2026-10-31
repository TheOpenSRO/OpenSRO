extends Control
class_name HelpWindow

## The in-client Help window. The original client showed help and notices
## through an embedded Internet Explorer control (an ifhelp/web-board panel);
## Godot has no webview, so this renders our own bundled Markdown docs
## natively instead. It is grounded in the authored slot: the ESC System
## window's Help button (round 138) and the authored ifgameguide frame, which
## this reuses for the window chrome via UiBuilder.
##
## Inside (round 848, lane H: the native-GUI census; before, a Godot ItemList
## and RichTextLabel over dark ColorRects of this project's own): the
## document list in the layout's own menu (GDR_GUIDE_MENU, the CIFGGMenu hung
## left of the frame), one row a document drawn as the client's list rows
## draw themselves (com_bar01_ / com_bar01select_, UI_TODO rule 17; INFERRED
## for CIFGGMenu, whose own rows were not read); the document as the client's
## PML (PmlText, the CIFPML record GDR_GUIDE_DATA_PML on the guide's paper,
## in the record's FontColor and HAlign) from MdToPml; the record's
## CIFVerticalScroll GDR_GUIDE_DATA_SCL drawn as the quest detail draws its
## guide-art scroll (HudChat.ChatScroll with gd_scroll_up / _down / _button;
## the layout's own GDR_GUIDE_DATA_SCL_BG draws the line, INFERRED); and the
## authored frame's own Close. The start page's decoration (GDR_GUIDE_
## STARTPGDECO and its two text boxes) is hidden while a document is shown
## (OURS). The GM document's GM section is shown only to a GM (the doc marks
## it with sentinels).
##
## Everything not from the authored layout -- the doc list contents, the
## rendered text, the row captions' place -- is our own and disclosed.

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
## The document list (a Control of rows) and the selected row (-1: none).
var _list: Control
var _selected := -1
var _content: PmlText
var _scroll: HudChat.ChatScroll
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
	# Round 848: the client's close button (CIFCloseButton's hardcoded art),
	# not a Godot Button reading "X".
	var close_def := UiLayoutParser.ControlDef.new()
	close_def.name = "Close"
	close_def.type = "CIFCloseButton"
	close_def.rect = Rect2i(int(_frame.size.x) - 26, 10, 16, 16)
	var close := _builder.build_control(close_def) as BaseButton if _builder != null else null
	if close != null:
		close.pressed.connect(func() -> void: hide())
		_frame.add_child(close)
	add_child(_frame)
	_frame.centre()

## Row geometry of the document list (OURS: the list rows' bar is 24 tall,
## rule 18; the caption 8 in).
const ROW_H := 24.0
const ROW_TEXT_X := 8.0
## The content's record, scroll and the start page's parts (ifgameguide.txt).
const PML_RECORD := "GDR_GUIDE_DATA_PML"
const SCROLL_RECORD := "GDR_GUIDE_DATA_SCL"
const MENU_LAYOUT := "resinfo\\ifggmenu.txt"
const START_PAGE := ["GDR_GUIDE_STARTPGDECO", "GDR_GUIDE_STARTPGDECO_TEXT_1", "GDR_GUIDE_STARTPGDECO_TEXT_2"]

## Lays the document list and the content inside the frame: the list in the
## layout's menu (or a strip inside the frame without one), the content on
## the authored PML record (or a box inside the frame without one).
func _build_body() -> void:
	var frame := _root()
	var w: float = frame.size.x
	var h: float = frame.size.y
	var top := HudWindow.TITLE_BAR_HEIGHT
	var margin := 12.0
	var list_w := minf(150.0, w * 0.32)

	# The authored layout has a document menu of its own, GDR_GUIDE_MENU (the
	# CIFGGMenu frame the original lists its guide sections in, hung to the
	# LEFT of the main frame at x=-206). When it built, the list goes on its
	# tile (GDR_GUIDE_MENU_TILE_2's 22,46 168x322 in ifggmenu.txt, OURS: the
	# menu's own layout is not loaded) and the whole frame is left to the text.
	var list_rect := Rect2(Vector2(margin, top), Vector2(list_w, h - top - margin))
	var content_rect := Rect2(Vector2(margin + list_w + margin, top), Vector2(w - list_w - 3 * margin, h - top - margin))
	var menu: Control = null
	if _authored and _frame != null:
		menu = _frame.node("GDR_GUIDE_MENU") as Control
	if menu != null and menu.size.x > 40.0 and menu.size.y > 60.0:
		list_rect = Rect2(menu.position + Vector2(22.0, 46.0), Vector2(168.0, 322.0))
		# The menu's inside: ifggmenu.txt (its scroll manager's equip_window_
		# frame over the com_bg_tile_d / _b tiles) at the menu's origin
		# (INFERRED: CIFGGMenu's Create was not read; the file is the class's
		# by name). Without it the menu was see-through.
		var mlayout: UiLayoutParser.LayoutDef = _builder.load_layout(MENU_LAYOUT) if _builder != null else null
		var inside := _builder.build_section(mlayout, "Create") if mlayout != null else null
		if inside != null:
			inside.name = "GGMenuInside"
			inside.position = menu.position
			inside.mouse_filter = Control.MOUSE_FILTER_IGNORE
			frame.add_child(inside)
			UiBuilder.settle_authored_rects(inside)
	_list = Control.new()
	_list.name = "DocList"
	_list.position = list_rect.position
	_list.size = list_rect.size
	_list.clip_contents = true
	_list.mouse_filter = Control.MOUSE_FILTER_PASS
	frame.add_child(_list)

	var host: Control = _frame.node(PML_RECORD) as Control if _authored and _frame != null else null
	if host != null:
		_content = PmlText.put_on(host, _builder, "")
		host.mouse_filter = Control.MOUSE_FILTER_PASS
	else:
		_content = PmlText.new()
		_content.name = "PmlText"
		_content.position = content_rect.position
		_content.size = content_rect.size
		frame.add_child(_content)
		_content.setup(_builder.font_at(0) if _builder != null else null, UiBuilder.FONT_SIZES[0], Color.WHITE)
	_content.mouse_filter = Control.MOUSE_FILTER_STOP
	_link_scroll()

## The record's CIFVerticalScroll, drawn as the quest detail's (QuestHud).
func _link_scroll() -> void:
	var bar: Control = _frame.node(SCROLL_RECORD) as Control if _authored and _frame != null else null
	if bar == null or _content == null:
		return
	var r: Rect2 = bar.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(bar.position, bar.size))
	_scroll = HudChat.ChatScroll.new()
	_scroll.name = "GuideScroll"
	if _builder != null:
		_scroll.up_texture = _builder.load_texture(QuestHud.SCROLL_UP_DDJ)
		_scroll.down_texture = _builder.load_texture(QuestHud.SCROLL_DOWN_DDJ)
		_scroll.thumb_texture = _builder.load_texture(QuestHud.SCROLL_THUMB_DDJ)
	_scroll.length = r.size.y
	_scroll.position = r.position - Vector2(0, HudChat.SCROLL_BUTTON.y)
	_scroll.size = Vector2(HudChat.SCROLL_BUTTON.x, HudChat.SCROLL_BUTTON.y * 3 + _scroll.length)
	_scroll.moved.connect(func(pos: int) -> void: _content.set_scroll(pos))
	_content.scrolled.connect(func(pos: int) -> void: _scroll.set_range(_content.max_scroll(), pos))
	bar.get_parent().add_child(_scroll)

func _populate_list() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	for i in _docs.size():
		var row := TextureButton.new()
		row.name = "Doc%d" % i
		row.focus_mode = Control.FOCUS_NONE
		row.position = Vector2(0, ROW_H * i)
		row.size = Vector2(_list.size.x, ROW_H)
		var bars := Control.new()
		bars.name = "Bar"
		bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bars.size = row.size
		row.add_child(bars)
		var cap := Label.new()
		cap.name = "ButtonLabel"
		cap.text = String(_docs[i].get("title", "?"))
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		cap.position = Vector2(ROW_TEXT_X, 0)
		cap.size = Vector2(row.size.x - ROW_TEXT_X, ROW_H)
		if _builder != null and _builder.font_at(0) != null:
			cap.add_theme_font_override("font", _builder.font_at(0))
		cap.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		row.add_child(cap)
		row.pressed.connect(_show_doc.bind(i))
		_list.add_child(row)
	_paint_rows()

## Each row's bar: the selected one com_bar01select_, the others com_bar01_.
func _paint_rows() -> void:
	for i in _list.get_child_count():
		var bars := _list.get_child(i).get_node_or_null("Bar") as Control
		if bars == null:
			continue
		for c in bars.get_children():
			bars.remove_child(c)
			c.queue_free()
		if _builder != null:
			_builder._add_row_bar_from(bars, UiBuilder.ROW_BAR_SELECTED_DDJ if i == _selected else UiBuilder.ROW_BAR_DDJ, bars.size)

func _show_doc(index: int) -> void:
	if index < 0 or index >= _docs.size():
		return
	_selected = index
	_paint_rows()
	var path := String(_docs[index].get("path", ""))
	_content.set_markup(MdToPml.convert(_load_doc(path)))
	if _scroll != null:
		_scroll.set_range(_content.max_scroll(), 0)
	if _frame != null:
		for n in START_PAGE:
			var deco := _frame.node(n) as Control if _authored else null
			if deco != null:
				deco.visible = false

## The selected document's index (-1: none).
func selected() -> int:
	return _selected

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
	if _selected >= 0:
		_show_doc(_selected)
