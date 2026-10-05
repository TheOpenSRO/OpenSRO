extends RefCounted
class_name NpcTalkView

## The NPC talk window's inside (round 725; docs/protocol/npc_gui.md §1): the
## CIF_NPCTalk box composed into the GDR_NPCWINDOW registry window, its text
## in the client's colours, and its scroll bar.
##
## **Structure (READ).** GDR_NPCWINDOW (ginterface.txt ID 30, 386x451,
## `mframe_wnd_`) is a CIF_NPCWindow; its Create (0x704b40) loads
## if_npcwindow.txt, whose one control GDR_NW_NPCTALK is a CIF_NPCTalk at
## 11,48 (364x391, the 8-slice `npc_conversation_window_`). CIF_NPCTalk::Create
## (0x6fa110) loads if_npctalk.txt with itself as the parent, so that file's
## rects are relative to the talk box: the dark panel GDR_NPCTALK_BGTILE
## 20,20, the text GDR_NT_TALKBOX 23,23,302,343, the scroll bar
## GDR_NPCTALK_SCROLL 336,27,16,320 and the quest parchment, hidden for a plain
## talk. HudPanels builds the registry window from if_npcwindow.txt
## (HudWindow.build) and compose() puts if_npctalk.txt inside the talk box.
##
## **Text (READ, the builder FUN_00700440 and the line adder FUN_006fcd60).**
## The greeting in 0xffffffff; for an NPC of a fortress, the tax line
## SN_FORTRESS_SHOP_TAX in 0xffd6ff7e and a blank line; then one "%d. " line
## per offered service with the colour triple 0xffefdaa4 / 0xffff8a00 /
## 0xffff8a00 (beige; orange for the other two states -- INFERRED hover and
## press) and no underline; "End conversation." last.
##
## **Scroll bar (READ).** CIF_NPCTalk::Create gives its CIFVerticalScroll a
## length of 320 (`push 0x140` at 0x6fa1c9 into 0x65a390 at 0x6fa1d6, the
## same setter the chat's 308 goes through), drawn with ifverticalscroll.txt's
## parts (HudChat.ChatScroll: the up arrow 16 above the control, the down
## arrow below the length). One step is one line (0x6592a0, as the chat's).
##
## **Line pitch (READ).** Create sets the text box's pitch to 18 (`push 0x12`
## at 0x6fa1e1 into 0x638c20, the setter the chat's 14 goes through at
## 0x7abeb8), wrapped lines included -- the 18 px rows of the user's original
## screenshot (tcHCl0v: 295, 313, 331, 349). Create also stores 100 at +0x3a0
## (the chat's line cap) and 19 at +0x3a4; 343 / 18 rounds down to 19 shown
## lines, so +0x3a4 is INFERRED to be the visible-line count.

const NPC_WINDOW_LAYOUT := "resinfo\\if_npcwindow.txt"
const NPC_TALK_LAYOUT := "resinfo\\if_npctalk.txt"
const TALK_CONTROL := "GDR_NW_NPCTALK"
const TALKBOX := "GDR_NT_TALKBOX"
const SCROLL_CONTROL := "GDR_NPCTALK_SCROLL"
## The quest parchment and its title strip, hidden for a plain talk.
const QUEST_PARTS := ["GDR_NPCTALK_QUESTBG", "GDR_NPCTALK_QUESTBG_TITLE"]

const COLOUR_GREETING := Color8(255, 255, 255)
const COLOUR_TAX := Color8(214, 255, 126)
const COLOUR_MENU := Color8(239, 218, 164)
const COLOUR_MENU_ACTIVE := Color8(255, 138, 0)

const SCROLL_LENGTH := 320.0
## The text box's line pitch, READ (see the header).
const LINE_PITCH := 18

## The label and its clipping box, by node name (QA hooks find the label).
const BODY_NAME := "TalkText"
const CLIP_NAME := "TalkClip"
const SCROLL_NAME := "TalkScroll"

const TAX_STRID := "SN_FORTRESS_SHOP_TAX"
const TAX_FALLBACK := "The current tax rate of %s is %d%%."

## Metas on the label: the lines as composed (BBCode, before colouring), the
## line key under the mouse, and the first shown line.
const META_LINES := "talk_lines"
const META_HOVER := "talk_hover"
const META_SCROLL := "talk_scroll"

## Composes the talk box into `window` and returns the label the lines go on.
## A window built from if_npcwindow.txt gets if_npctalk.txt inside its
## GDR_NW_NPCTALK; one built from if_npctalk.txt alone (a fixture, or an
## archive without if_npcwindow.txt) takes its talk box at the window's origin.
static func compose(window: HudWindow, builder: UiBuilder) -> RichTextLabel:
	var existing := body_of(window)
	if existing != null:
		return existing
	var talk_origin := Vector2.ZERO
	var talk := window.node(TALK_CONTROL) as Control
	var talk_layout := builder.load_layout(NPC_TALK_LAYOUT) if builder != null else null
	if talk != null and talk_layout != null:
		var npcwin := builder.load_layout(NPC_WINDOW_LAYOUT)
		var talk_def := _def(npcwin, TALK_CONTROL)
		if talk_def != null:
			talk_origin = Vector2(talk_def.rect.position)
		var inner := builder.build_section(talk_layout, "Create")
		if inner != null:
			inner.name = "NpcTalkBox"
			talk.add_child(inner)
			UiBuilder.settle_authored_rects(inner)
	for part in QUEST_PARTS:
		var q := window.node(part) as CanvasItem
		if q != null:
			q.visible = false
	var box := Rect2(talk_origin + Vector2(23, 23), Vector2(302, 343))
	var bar := Rect2(talk_origin + Vector2(336, 27), Vector2(16, 320))
	var box_def := _def(talk_layout, TALKBOX)
	if box_def != null:
		box = Rect2(talk_origin + Vector2(box_def.rect.position), Vector2(box_def.rect.size))
	var bar_def := _def(talk_layout, SCROLL_CONTROL)
	if bar_def != null:
		bar = Rect2(talk_origin + Vector2(bar_def.rect.position), Vector2(bar_def.rect.size))
	var clip := Control.new()
	clip.name = CLIP_NAME
	clip.clip_contents = true
	clip.position = box.position
	clip.size = box.size
	clip.mouse_filter = Control.MOUSE_FILTER_PASS
	window.add_child(clip)
	var body := RichTextLabel.new()
	body.name = BODY_NAME
	body.bbcode_enabled = true
	body.scroll_active = false
	body.fit_content = true
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.meta_underlined = false
	body.position = Vector2.ZERO
	body.size = Vector2(box.size.x, 0)
	body.custom_minimum_size = Vector2(box.size.x, 0)
	body.mouse_filter = Control.MOUSE_FILTER_PASS
	body.add_theme_color_override("default_color", COLOUR_GREETING)
	if builder != null:
		var font := builder.font_at(0)
		if font != null:
			body.add_theme_font_override("normal_font", font)
		body.add_theme_font_size_override("normal_font_size", UiBuilder.FONT_SIZES[0])
	# The pitch is the font's own height plus the separation.
	var pitch_font := body.get_theme_font("normal_font")
	if pitch_font != null:
		var font_h := pitch_font.get_height(body.get_theme_font_size("normal_font_size"))
		body.add_theme_constant_override("line_separation", LINE_PITCH - roundi(font_h))
	clip.add_child(body)
	body.meta_hover_started.connect(func(meta: Variant) -> void:
		body.set_meta(META_HOVER, str(meta))
		_render(body))
	body.meta_hover_ended.connect(func(_meta: Variant) -> void:
		body.set_meta(META_HOVER, "")
		_render(body))
	var scroll := HudChat.ChatScroll.new()
	scroll.name = SCROLL_NAME
	if builder != null:
		scroll.up_texture = builder.load_texture(HudChat.ARROW_UP_DDJ)
		scroll.down_texture = builder.load_texture(HudChat.ARROW_DOWN_DDJ)
		scroll.bar_texture = builder.load_texture(HudChat.SCROLL_BAR_DDJ)
		scroll.thumb_texture = builder.load_texture(HudChat.SCROLL_THUMB_DDJ)
	scroll.length = SCROLL_LENGTH
	scroll.position = bar.position - Vector2(0, HudChat.SCROLL_BUTTON.y)
	scroll.size = Vector2(HudChat.SCROLL_BUTTON.x, HudChat.SCROLL_BUTTON.y * 3 + SCROLL_LENGTH)
	scroll.moved.connect(func(pos: int) -> void: scroll_to(window, pos))
	window.add_child(scroll)
	clip.gui_input.connect(func(ev: InputEvent) -> void:
		var mb := ev as InputEventMouseButton
		if mb == null or not mb.pressed:
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			scroll_to(window, int(body.get_meta(META_SCROLL, 0)) - 1)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			scroll_to(window, int(body.get_meta(META_SCROLL, 0)) + 1))
	return body

static func _def(layout: UiLayoutParser.LayoutDef, control_name: String) -> UiLayoutParser.ControlDef:
	if layout == null:
		return null
	var sec := layout.get_section("Create")
	if sec == null or not sec.control_by_name.has(control_name):
		return null
	return sec.control_by_name[control_name]

## The talk label of `window`, or null before compose().
static func body_of(window: Node) -> RichTextLabel:
	if window == null:
		return null
	return window.find_child(BODY_NAME, true, false) as RichTextLabel

## Puts `lines` (BBCode: plain text, the tax line as tax_line() made it, and
## `[url=key]n. text[/url]` menu lines) on the window's label, from the top.
static func show_lines(window: HudWindow, lines: PackedStringArray) -> void:
	var body := body_of(window)
	if body == null:
		return
	body.set_meta(META_LINES, lines)
	body.set_meta(META_HOVER, "")
	body.set_meta(META_SCROLL, 0)
	body.position.y = 0.0
	_render(body)
	_update_scroll.call_deferred(window)

## The tax line, in its colour (READ, SN_FORTRESS_SHOP_TAX in 0xffd6ff7e).
static func tax_line(text: String) -> String:
	return "[color=#%s]%s[/color]" % [COLOUR_TAX.to_html(false), TeleportBoard.escape(text)]

## The label's text for its lines: each menu line in beige, the one under the
## mouse in orange, the rest as composed.
static func coloured(lines: PackedStringArray, hovered: String) -> String:
	var out := PackedStringArray()
	for line in lines:
		if line.begins_with("[url=") and line.ends_with("[/url]"):
			var open_end := line.find("]")
			var key := line.substr(5, open_end - 5)
			var inner := line.substr(open_end + 1, line.length() - open_end - 1 - 6)
			var colour := COLOUR_MENU_ACTIVE if key == hovered and hovered != "" else COLOUR_MENU
			out.append("[url=%s][color=#%s]%s[/color][/url]" % [key, colour.to_html(false), inner])
		else:
			out.append(line)
	return "\n".join(out)

static func _render(body: RichTextLabel) -> void:
	var lines: PackedStringArray = body.get_meta(META_LINES, PackedStringArray())
	body.text = coloured(lines, str(body.get_meta(META_HOVER, "")))

## The height of one line of the label: the READ pitch once compose() set
## it, else what the label laid out (0 before).
static func line_height(body: RichTextLabel) -> float:
	var n := body.get_line_count()
	if n <= 0:
		return 0.0
	if body.has_theme_constant_override("line_separation"):
		return float(LINE_PITCH)
	return float(body.get_content_height()) / float(n)

## How many lines fit in the box and how many there are.
static func _counts(window: HudWindow) -> Vector2i:
	var body := body_of(window)
	var clip := window.find_child(CLIP_NAME, true, false) as Control
	if body == null or clip == null:
		return Vector2i.ZERO
	var h := line_height(body)
	if h <= 0.0:
		return Vector2i(0, body.get_line_count())
	return Vector2i(int(floor(clip.size.y / h)), body.get_line_count())

## The scroll bar's range: lines that do not fit, one step each.
static func _update_scroll(window: HudWindow) -> void:
	if window == null or not is_instance_valid(window):
		return
	var scroll := window.find_child(SCROLL_NAME, true, false) as HudChat.ChatScroll
	var body := body_of(window)
	if scroll == null or body == null:
		return
	var c := _counts(window)
	scroll.set_range(maxi(0, c.y - c.x), int(body.get_meta(META_SCROLL, 0)))

## Shows the text from line `pos` (clamped to the range).
static func scroll_to(window: HudWindow, pos: int) -> void:
	var body := body_of(window)
	if body == null:
		return
	var c := _counts(window)
	var top := clampi(pos, 0, maxi(0, c.y - c.x))
	body.set_meta(META_SCROLL, top)
	body.position.y = -float(top) * line_height(body)
	var scroll := window.find_child(SCROLL_NAME, true, false) as HudChat.ChatScroll
	if scroll != null:
		scroll.set_range(maxi(0, c.y - c.x), top)

## OURS (round 725, until the server sends a fortress NPC's tax data, lane C):
## the fortress whose tax line an NPC or gate shows, by its codename, as
## siegefortress.txt names the two town fortresses (FORTRESS_JANGAN /
## SN_FORTRESS_JANGAN, FORTRESS_HOTAN / SN_FORTRESS_HOTAN -- READ from the
## archive's table): a Chinese codename (`_CH_`) shows Jangan's, a Khotan one
## (`_KT_`) Hotan's, at 0 %. READ is only that the line exists and when: the
## builder adds it when the NPC object's +0x18c is set and the talk window's
## +0x800 (the fortress id the server fills) is non-zero, with the rate the s16
## at +0x804 (docs/protocol/npc_gui.md §1, OPEN 1). Which NPCs the server marks
## is not read; this mapping is ours, and wider than the original's can be: it
## gives the line to every `_CH_`/`_KT_` code (keepers, guild and job NPCs
## too), where the original needs the NPC's own +0x18c. When lane C reads
## +0x18c, restrict the line to it (round 725's review, F7).
static func fortress_strid_for(code: String) -> String:
	var up := code.to_upper()
	if up.contains("_CH_"):
		return "SN_FORTRESS_JANGAN"
	if up.contains("_KT_"):
		return "SN_FORTRESS_HOTAN"
	return ""
