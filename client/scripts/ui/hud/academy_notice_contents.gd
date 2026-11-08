extends RefCounted
class_name AcademyNoticeContents

## Round 865: the academy window's notice contents panel -- GDR_APPRENTICESHIP_
## NOTIFY_CONTENTS (ID 140), a CIFGuildNotifyContents at 0,102,364,201 on
## `inventory\int_window_` -- and the notice line's selected look.
##
## READ (CIFGuildNotifyContents::Create c:0x70b210): it loads
## resinfo\ifguildnotifycontents.txt into itself and resizes its children to
## the academy's smaller panel: the black square (1) 0x156 x 0x95 (342 x 149),
## BG_01 (2) 0x158 x 0xb4 (344 x 180), BG_02 (3) 0x14c x 0x8b (332 x 139), the
## scroll (5) 0x10 x 0x5c (16 x 92), the text box (6) 0x125 x 0x6d (293 x 109)
## with a line pitch of 0x12 (18, c:0x638c20). Their positions are computed
## from the panel's rect in code not traced: MEASURED instead, in the panel --
## the black field 7..342 x 7..145, the scroll's arrows at x 324 from y 9,
## the text's glyphs from (21, 24), Confirm at (140, 164). The Confirm button (4) closes the panel
## (the academy window's notice flag, c:0x6e9690).
## The notice line's selected fill: MEASURED (140, 82, 0) over (82, 306) 254 x
## 17 of the pane (78, 0 in the line), the title's strip, while the panel is open.

const LAYOUT := "resinfo\\ifguildnotifycontents.txt"
const LINE_PITCH := 0x12
## Each child's rect in the 364 x 201 panel: the sizes READ, the places
## MEASURED.
const RECTS := {
	"GDR_GUILD_NOTIFY_CON_BG_01": Rect2(10, 10, 344, 180),
	"GDR_GUILD_NOTIFY_CON_BLACKSQUARE": Rect2(2, 2, 342, 149),
	"GDR_GUILD_NOTIFY_CON_BG_02": Rect2(7, 7, 332, 139),
	"GDR_GUILD_NOTIFY_CON_SCROLL": Rect2(324, 25, 16, 92),
	"GDR_GUILD_NOTIFY_CON_TEXT": Rect2(20, 21, 293, 109),
}
const BUTTON_AT := Vector2(140, 164)
const SELECTED := Color8(140, 82, 0)
const SELECTED_RECT := Rect2(78, 0, 254, 17)

## Builds the panel's content into `host`; returns its Confirm button.
static func build_into(host: Control, builder: UiBuilder) -> BaseButton:
	if host == null or builder == null:
		return null
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(LAYOUT)
	if layout == null:
		return null
	var sec := layout.get_section("Create")
	if sec == null:
		return null
	# Each control built at the panel's rect (a frame's slices are laid at
	# build, so the rect is set on the record, not after).
	var built := Control.new()
	built.name = "NotifyContents"
	built.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in range(sec.controls.size() - 1, -1, -1):
		var def: UiLayoutParser.ControlDef = sec.controls[i]
		if RECTS.has(def.name):
			def = def.with_rect(Rect2i(RECTS[def.name]))
		elif def.name == "GDR_GUILD_NOTIFY_CON_BUTTON":
			def = def.with_rect(Rect2i(Vector2i(BUTTON_AT), def.rect.size))
		var node := builder.build_control(def)
		if node != null:
			built.add_child(node)
	host.add_child(built)
	UiBuilder.settle_authored_rects(built)
	# The scroll (5): a CIFVerticalScroll with ifverticalscroll.txt's parts
	# (HudChat.ChatScroll), its length the record's height (CIFVerticalScroll::
	# Create 0x65a9c0, as round 848 read it); a short notice never moves it.
	var host_scroll := built.get_node_or_null("GDR_GUILD_NOTIFY_CON_SCROLL") as Control
	if host_scroll != null:
		var bar := HudChat.ChatScroll.new()
		bar.name = "NoticeScroll"
		bar.up_texture = builder.load_texture(HudChat.ARROW_UP_DDJ)
		bar.down_texture = builder.load_texture(HudChat.ARROW_DOWN_DDJ)
		bar.bar_texture = builder.load_texture(HudChat.SCROLL_BAR_DDJ)
		bar.thumb_texture = builder.load_texture(HudChat.SCROLL_THUMB_DDJ)
		var track := float(RECTS["GDR_GUILD_NOTIFY_CON_SCROLL"].size.y)
		bar.length = track
		bar.position = Vector2(0, -HudChat.SCROLL_BUTTON.y)
		bar.size = Vector2(HudChat.SCROLL_BUTTON.x, HudChat.SCROLL_BUTTON.y * 3 + track)
		host_scroll.add_child(bar)
	var ok := built.get_node_or_null("GDR_GUILD_NOTIFY_CON_BUTTON") as BaseButton
	var text := Label.new()
	text.name = "Body"
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	var tr: Rect2 = RECTS["GDR_GUILD_NOTIFY_CON_TEXT"]
	text.position = tr.position
	text.size = tr.size
	text.clip_text = true
	if builder.font_at(0) != null:
		text.add_theme_font_override("font", builder.font_at(0))
	text.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	text.add_theme_color_override("font_color", Color.WHITE)
	text.add_theme_constant_override("line_spacing", 0)
	built.add_child(text)
	return ok

## 0x70b050: the panel's text.
static func set_content(host: Control, content: String) -> void:
	if host == null:
		return
	var body := host.get_node_or_null("NotifyContents/Body") as Label
	if body != null:
		body.text = content

static func content_of(host: Control) -> String:
	var body := host.get_node_or_null("NotifyContents/Body") as Label if host != null else null
	return body.text if body != null else ""

## The notice line's text (the title, c:0x8b47c0 with 0x104): the line is a
## CIFSelectableArea, which the builder makes a bare container, so its text
## is a label of ours over the title's strip (MEASURED: the text's left edge
## at 78 in the line, its glyphs 4..13 down, in the strip's 17 rows).
static func set_subject(subject: Control, text: String, builder: UiBuilder) -> Label:
	if subject == null:
		return null
	var l := subject.get_node_or_null("Text") as Label
	if l == null:
		l = Label.new()
		l.name = "Text"
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.position = SELECTED_RECT.position
		l.size = SELECTED_RECT.size
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.clip_text = true
		if builder != null and builder.font_at(0) != null:
			l.add_theme_font_override("font", builder.font_at(0))
		l.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		l.add_theme_color_override("font_color", Color.WHITE)
		subject.add_child(l)
	l.text = text
	return l

## The notice line drawn selected (MEASURED fill) or not.
static func mark_selected(subject: Control, on: bool, _builder: UiBuilder) -> void:
	var fill := subject.get_node_or_null("SelectedFill") as ColorRect
	if fill == null:
		fill = ColorRect.new()
		fill.name = "SelectedFill"
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fill.color = SELECTED
		fill.position = SELECTED_RECT.position
		fill.size = SELECTED_RECT.size
		subject.add_child(fill)
		subject.move_child(fill, 0)
	fill.visible = on
