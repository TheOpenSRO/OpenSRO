extends RefCounted
class_name AcademyNoticeContents

## Round 865: the academy window's notice contents panel -- GDR_APPRENTICESHIP_
## NOTIFY_CONTENTS (ID 140), a CIFGuildNotifyContents at 0,102,364,201 on
## `inventory\int_window_` -- and the notice line above it.
##
## Round 867: rebuilt to the original's numbers (READ in sro_client.exe, and
## MEASURED at 1280 x 1024 against the same title and eleven-line content).
##
## The panel -- CIFGuildNotifyContents::Create (c:0x70b210): it loads
## resinfo\ifguildnotifycontents.txt into itself, and when its parent is the
## academy window (c:0x70b2a4 0xb8f4f0 + 0xb94b90) moves and sizes each child
## from the panel's own position (c:0x70b2c6 0xb8f460):
##   the black square (1) to +0xc,+0xd, 0x156 x 0x95 (c:0x70b2d6..0x70b30e);
##   BG_01 (2, com_bg_tile_b) to +0xa,+0x8, 0x158 x 0xb4 (c:0x70b31b..0x70b353);
##   BG_02 (3, com_bg_tile_e, black) to +0xa,+0xb, 0x14c x 0x8b (c:0x70b360..0x70b398);
##   the scroll (5) to +0x146,+0x1c, 0x10 x 0x5c, its length 0x5c (c:0x70b39a..0x70b3db);
##   Confirm (4) to +0x8e,+0xa8 (c:0x70b3e0..0x70b404);
##   the text (6) to +0x17,+0x1b, 0x125 x 0x6d (c:0x70b406..0x70b438);
## then the text's line pitch 0x12 (c:0x70b440 -> 0x638c20) and 6 at +0x3a4,
## the lines it shows. The children draw last-listed first, so the black
## square lies under BG_01 and is never seen. MEASURED: the black field at
## 10..341 x 11..149 of the panel, the scroll's arrows at 12 and 136, the
## thumb's track 28..135, the first line's capitals from y 29, x 24, every
## line 18 below the last, six lines shown.
## The content (c:0x70b050): the text set, its line count n read back; for
## n > 6 the scroll's range 0..n-6 (0x65a390(0x5c, 0, n-6, 1)), else 0..0;
## then the text scrolled to its first line. So every refresh and every
## opening (the panel is made anew each time, c:0x6e9690) starts at the top
## (MEASURED: a member logging on put an open panel back to its first line).
## One step of an arrow or the wheel is one line (MEASURED: 13 lines, the
## thumb at 28, 41, 54, 67 .. 120 for lines 0, 1, 2, 3 .. 7: 28 + n * 92 / 7).
##
## The notice line -- GDR_APPRENTICESHIP_NOTIFY_SUBJECT (61), a
## CIFSelectableArea at 4,306,358,28. CIFApprenticeShip::Create gives it the
## guild notice bar's art (c:0x6e99f8..0x6e9a65: 0x64ce30 with
## guild\gil_windo02_on.ddj as the selected art (+0x380), gil_windo02_off.ddj
## as the normal one (+0x384) and none disabled; c:0x6e9a75 0x655770 with
## gil_windo02_on.ddj as the art under the pointer (+0x13c)), draws it in its
## normal state (c:0x6e9aa1 0x64cc30(0)), and insets its text by 0x50, 7
## (c:0x6e9ac0 0x6527d0 {0x50, 7, 0, 0}; 0x652800 adds them). The art fills
## the line's rect. The pointer over the line swaps to the hover art and back
## on leaving (CIFSelectableArea::vslot_019 c:0x64cbb0, events 0x4009 /
## 0x400a); nothing in the academy window ever selects it (0x64cc30 is called
## only with 0, at Create and at the reset c:0x6e8d26). MEASURED: the line
## orange (140, 82, 0) over 84..337 x 310..326 of the pane only while the
## pointer is on it, never while the contents panel is open; its title's
## capitals from (85, 315), "You have no notes." the same; the black field
## 83..337 x 309..327; the art point-sampled.

const LAYOUT := "resinfo\\ifguildnotifycontents.txt"
const LINE_PITCH := 0x12
## The lines the text shows (+0x3a4).
const SHOWN_LINES := 6
const SCROLL_LENGTH := 0x5c
## Each child's rect in the 364 x 201 panel (READ above).
const RECTS := {
	"GDR_GUILD_NOTIFY_CON_BLACKSQUARE": Rect2(0xc, 0xd, 0x156, 0x95),
	"GDR_GUILD_NOTIFY_CON_BG_01": Rect2(0xa, 0x8, 0x158, 0xb4),
	"GDR_GUILD_NOTIFY_CON_BG_02": Rect2(0xa, 0xb, 0x14c, 0x8b),
	"GDR_GUILD_NOTIFY_CON_SCROLL": Rect2(0x146, 0x1c, 0x10, 0x5c),
	"GDR_GUILD_NOTIFY_CON_TEXT": Rect2(0x17, 0x1b, 0x125, 0x6d),
}
const BUTTON_AT := Vector2(0x8e, 0xa8)

## The notice line's art (READ above).
const SUBJECT_NORMAL_ART := "interface\\guild\\gil_windo02_off.ddj"
const SUBJECT_HOVER_ART := "interface\\guild\\gil_windo02_on.ddj"
## The line's text inset (0x6527d0 {0x50, 7, 0, 0}).
const SUBJECT_TEXT_INSET := Vector2(0x50, 7)

## The text's and the scroll's node names (found under the host).
const BODY := "Body"
const SCROLL := "NoticeScroll"

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
	# build, so the rect is set on the record, not after), last-listed first.
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
	# (HudChat.ChatScroll), its length 0x5c, the arrows above and below it.
	var bar: HudChat.ChatScroll = null
	var host_scroll := built.get_node_or_null("GDR_GUILD_NOTIFY_CON_SCROLL") as Control
	if host_scroll != null:
		bar = HudChat.ChatScroll.new()
		bar.name = "NoticeScroll"
		bar.up_texture = builder.load_texture(HudChat.ARROW_UP_DDJ)
		bar.down_texture = builder.load_texture(HudChat.ARROW_DOWN_DDJ)
		bar.bar_texture = builder.load_texture(HudChat.SCROLL_BAR_DDJ)
		bar.thumb_texture = builder.load_texture(HudChat.SCROLL_THUMB_DDJ)
		bar.length = float(SCROLL_LENGTH)
		bar.position = Vector2(0, -HudChat.SCROLL_BUTTON.y)
		bar.size = Vector2(HudChat.SCROLL_BUTTON.x, HudChat.SCROLL_BUTTON.y * 3 + SCROLL_LENGTH)
		host_scroll.add_child(bar)
	# The text (6): the record's colour and font, top-aligned, wrapped at
	# words to the box, 18 between lines, six lines from the scroll's line.
	var box := built.get_node_or_null("GDR_GUILD_NOTIFY_CON_TEXT") as Control
	var text := Label.new()
	text.name = "Body"
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	text.max_lines_visible = SHOWN_LINES
	text.position = Vector2.ZERO
	text.size = RECTS["GDR_GUILD_NOTIFY_CON_TEXT"].size
	text.clip_text = true
	# The wheel over the text scrolls it (MEASURED).
	text.mouse_filter = Control.MOUSE_FILTER_STOP
	var font := builder.font_at(0)
	if font != null:
		text.add_theme_font_override("font", font)
	text.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	text.add_theme_color_override("font_color", Color.WHITE)
	var used: Font = font if font != null else text.get_theme_font("font")
	var font_h := used.get_height(UiBuilder.FONT_SIZES[0]) if used != null else float(LINE_PITCH)
	text.add_theme_constant_override("line_spacing", LINE_PITCH - roundi(font_h))
	if box != null:
		box.add_child(text)
	else:
		text.position = RECTS["GDR_GUILD_NOTIFY_CON_TEXT"].position
		built.add_child(text)
	if bar != null:
		bar.moved.connect(func(pos: int) -> void: _show_from(text, pos))
	text.gui_input.connect(func(ev: InputEvent) -> void:
		var mb := ev as InputEventMouseButton
		if mb == null or not mb.pressed or bar == null:
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			bar._step(-1)
			text.accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			bar._step(1)
			text.accept_event())
	return built.get_node_or_null("GDR_GUILD_NOTIFY_CON_BUTTON") as BaseButton

static func _show_from(text: Label, line: int) -> void:
	if is_instance_valid(text):
		text.lines_skipped = maxi(0, line)

## 0x70b050: the panel's text, the scroll's range for its lines past six,
## and the first line shown.
static func set_content(host: Control, content: String) -> void:
	if host == null:
		return
	var body := _body(host)
	if body == null:
		return
	body.text = content
	scroll_to_top(host)

## The scroll back at the top (the panel made anew when it opens).
static func scroll_to_top(host: Control) -> void:
	var body := _body(host)
	if body != null:
		body.lines_skipped = 0
	var bar := scroll_of(host)
	if bar != null:
		bar.set_range(maxi(0, line_count(host) - SHOWN_LINES), 0)

static func _body(host: Control) -> Label:
	return host.find_child(BODY, true, false) as Label if host != null else null

static func content_of(host: Control) -> String:
	var body := _body(host)
	return body.text if body != null else ""

## The content's lines as wrapped in the box.
static func line_count(host: Control) -> int:
	var body := _body(host)
	return body.get_line_count() if body != null else 0

## The first line shown.
static func first_line(host: Control) -> int:
	var body := _body(host)
	return body.lines_skipped if body != null else 0

static func scroll_of(host: Control) -> HudChat.ChatScroll:
	return host.find_child(SCROLL, true, false) as HudChat.ChatScroll if host != null else null

## The notice line's art and its pointer swap (READ above): called once, when
## the window wires the line.
static func dress_subject(subject: Control, builder: UiBuilder) -> void:
	if subject == null or subject.get_node_or_null("Art") != null:
		return
	var art := TextureRect.new()
	art.name = "Art"
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_SCALE
	# MEASURED: the 504-wide art is point-sampled into the 358-wide line (a
	# row of the original's line matches the texture's nearest texel at each
	# pixel's centre, not a linear blend).
	art.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art.set_meta("normal", builder.load_texture(SUBJECT_NORMAL_ART) if builder != null else null)
	art.set_meta("hover", builder.load_texture(SUBJECT_HOVER_ART) if builder != null else null)
	art.texture = art.get_meta("normal")
	subject.add_child(art)
	subject.move_child(art, 0)
	subject.mouse_entered.connect(func() -> void: set_hovered(subject, true))
	subject.mouse_exited.connect(func() -> void: set_hovered(subject, false))
	subject.visibility_changed.connect(func() -> void:
		if not subject.is_visible_in_tree():
			set_hovered(subject, false))

## The line's art under the pointer or not (0x4009 / 0x400a).
static func set_hovered(subject: Control, on: bool) -> void:
	var art := subject.get_node_or_null("Art") as TextureRect if subject != null else null
	if art == null:
		return
	art.texture = art.get_meta("hover" if on else "normal")
	art.set_meta("hovered", on)

static func is_hovered(subject: Control) -> bool:
	var art := subject.get_node_or_null("Art") as TextureRect if subject != null else null
	return art != null and bool(art.get_meta("hovered", false))

## The notice line's text (the title, c:0x8b47c0 with 0x104; or SetText): the
## line is a CIFSelectableArea, which the builder makes a bare container, so
## its text is a label of ours in the line's text rect (the inset above),
## top-aligned like a static's.
static func set_subject(subject: Control, text: String, builder: UiBuilder) -> Label:
	if subject == null:
		return null
	var l := subject.get_node_or_null("Text") as Label
	if l == null:
		l = Label.new()
		l.name = "Text"
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.position = SUBJECT_TEXT_INSET
		l.size = subject.size - SUBJECT_TEXT_INSET if subject.size.x > SUBJECT_TEXT_INSET.x else Vector2(0x116, 0x15)
		l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		l.clip_text = true
		if builder != null and builder.font_at(0) != null:
			l.add_theme_font_override("font", builder.font_at(0))
		l.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
		l.add_theme_color_override("font_color", Color.WHITE)
		subject.add_child(l)
	l.text = text
	return l
