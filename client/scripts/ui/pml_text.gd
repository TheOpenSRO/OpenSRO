extends Control
class_name PmlText

## The client's PML text control, `CIFPML`, as it lays out and draws the
## `<sml2>` markup of a quest's SN_PAYCON_ text (round 845, lane K: the quest
## detail's "white and unreadable" text). Every address is sro_client.exe's;
## docs/protocol/quests.md section 8 has the reading with its evidence. Labels:
## READ (from the binary), MEASURED (counted in the data), INFERRED, OURS.
##
## **The parse (READ).** The tag names are matched whole (0x9b2160): `sml2`
## 2, `br` 3, `p` 4, `center` 5, `left` 6, `right` 7, `font` 8, `strong` 9,
## `table` 10, `tr` 11, `td` 12, `img` 13, `layer` 14; a leading `/` closes
## (0x9b5600). `<font>`'s attributes (0x9b23e0): `index` (the font table's
## index), `color`, `style` (the names `shadow|bold|blur|outline|underline`,
## bits 1, 2, 4, 8, 16: 0x9b3090), `bgcolor`. An attribute's value starts
## after the first `"` past its name (0x9b2e40..0x9b2fb0). A colour is four
## numbers A,R,G,B (0x9b1e40: `((a << 8 | r) << 8 | g) << 8 | b`), each read
## by 0xb9cc80 -- digits after any blanks, or 0 without moving when the next
## character is not a digit -- and the scan skipped past the next `,`. So the
## data's 20 doubled-quote colours (`color=""255,226,74,0""`, MEASURED in
## textquest_otherstring) read A = 0 and R, G, B as written.
##
## **The state (READ).** The layout (CPMLLayer 0x9b0bd0) keeps a stack of
## {font, background colour, colour, style}. CIFPML's layout 0x64b2c0 starts
## it from the control's own text: font `+0x94`, colour `+0xa0` -- the
## record's FontColor, which the ResInfo loader copies there (0x82c7c1 ->
## record +0x90; 0x8b56c5 -> 0x8b2b70 writes the window's +0xa0..+0xb0) --
## style `+0xf0`. `<font>` pushes the state with its attributes changed;
## `<strong>` pushes it with style 2 (0x9b0f6b: `FUN_009ae970(font, bg,
## colour, 2)`). A tag's end pops (INFERRED from the stack: the tree's
## children are laid inside their tag).
##
## **The lines (READ).** The paragraph state starts at {line margin 5, the
## control's HAlign} (0x64b2c0 `local_40 = 5`), and the first line at y 0
## (0x9af0f0). A text run (0x9af330) is a text item with the state's font,
## colour (0x8b2ba0) and style (0x8b4400), its line gap set to 0 (0x8b2c80),
## wrapped at the width left on the line (0x8b2c60: width - x). The wrap
## (0x8b3ef0, word mode): the advances are summed and the first glyph that
## passes the width (never the run's first) breaks the run after the last
## space seen in it, or before that glyph when it had none; the rest starts a
## new line at x 0. A line's height is the tallest run on it: the face's
## tmHeight (0x8b3040: the TEXTMETRIC 0xbaa110 stored for the run's glyph
## mode -- 2, the weight-600 face, for style 2). `<br>` (and a wrap) starts
## the next line at `y + height + margin` (0x9b0c6d). So a line of text is
## tmHeight + 5 below the last, and an empty line -- `<br><br>` -- only 5.
##
## **The draw (READ).** 0x8b48b0 draws each glyph cell from the item's top,
## in `colour & 0xffffff | alpha << 24` -- the markup's alpha is replaced by
## the draw's -- with style bit 1 a black shadow at (+1, +1) first; style 2
## is the face's weight-600 variant (HudNotice.bold_file, or its
## simulation as HudNotice.draw_bold draws it: each glyph at x and x + 1). INFERRED: the PML draws at alpha
## 0xff, as the world map's and the plates' text do.
##
## **The scroll (READ).** The content scrolls by whole pixels: the linked
## scroll's range is 0..content height - control height, step 1 (0x649c30 ->
## 0x65a390), and the wheel (vslot_036, 0x649cb0) moves it by the step times
## delta / 20 -- one notch (120) is 6 pixels.
##
## **Not built (OURS).** `table`, `tr`, `td`, `img` and `layer` draw their
## text as plain runs; no quest text uses them (MEASURED: the quest tables'
## tags are `sml2`, `br`, `font` and `strong` only).

signal scrolled(pos: int)

const TAG_SML2 := 2
const TAG_BR := 3
const TAG_P := 4
const TAG_CENTER := 5
const TAG_LEFT := 6
const TAG_RIGHT := 7
const TAG_FONT := 8
const TAG_STRONG := 9
## 0x9b2160's names, in its order.
const TAG_NAMES := {"sml2": TAG_SML2, "br": TAG_BR, "p": TAG_P, "left": TAG_LEFT,
	"center": TAG_CENTER, "right": TAG_RIGHT, "font": TAG_FONT, "strong": TAG_STRONG,
	"table": 10, "tr": 11, "td": 12, "img": 13, "layer": 14}

## Style bits (0x9b3090).
const STYLE_SHADOW := 1
const STYLE_BOLD := 2
const STYLE_NAMES := {"shadow": 1, "bold": 2, "blur": 4, "outline": 8, "underline": 16}

## 0x64b2c0: the paragraph's line margin.
const LINE_MARGIN := 5
## vslot_036: pixels a wheel notch moves (step 1 x 120 / 20).
const WHEEL_PIXELS := 6

## The control's own colour (its record's FontColor) and font.
var default_color := Color.BLACK
var font: Font
var font_size := 12
## The face's weight-600 file, or null for the simulation (HudNotice).
var bold_face: Font
## The paragraph's starting alignment, the control's HAlign (0x64b2c0, READ:
## the paragraph state starts from it): TAG_LEFT, TAG_CENTER or TAG_RIGHT.
var base_align := TAG_LEFT
## The markup shown.
var markup := ""
## Laid-out lines: {y, h, runs: [{x, text, color, style}]}.
var lines: Array = []
var content_height := 0
## The scroll, in pixels from the top.
var scroll := 0

func _init() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_PASS
	UiBuilder.crisp_text(self)

## Sets the face, its pixel size and the control's colour, then lays out.
func setup(face: Font, px: int, colour: Color) -> void:
	font = face
	font_size = px
	default_color = Color(colour, 1.0)
	bold_face = HudNotice.bold_file(face) if face != null else null
	relayout()

## The markup shown, laid out from the top (0x64b720: a new text resets the
## layout; the scroll goes back to 0 with the new range).
func set_markup(text: String) -> void:
	markup = text
	scroll = 0
	relayout()

func relayout() -> void:
	lines = layout(parse(markup, default_color), int(size.x))
	content_height = 0
	if not lines.is_empty():
		var last: Dictionary = lines[lines.size() - 1]
		content_height = int(last["y"]) + int(last["h"])
	scroll = clampi(scroll, 0, max_scroll())
	queue_redraw()

func max_scroll() -> int:
	return maxi(0, content_height - int(size.y))

func set_scroll(pos: int) -> void:
	var to := clampi(pos, 0, max_scroll())
	if to == scroll:
		return
	scroll = to
	queue_redraw()
	scrolled.emit(scroll)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and font != null:
		relayout()

func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed:
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			set_scroll(scroll - WHEEL_PIXELS)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			set_scroll(scroll + WHEEL_PIXELS)
			accept_event()

## Round 848: a PmlText over a CIFPML record's node `host` (made by
## UiBuilder, which keeps the record: UiBuilder.PML_DEF_META), in the record's
## FontColor and HAlign and font 0, showing `markup_text`; the one already
## there is reused. `colour` and `halign` (0 left, 1 centre, 2 right) stand in
## for a node without its record (a .2dt one); halign -1 takes the record's.
static func put_on(host: Control, builder: UiBuilder, markup_text: String, colour := Color.WHITE,
		halign := -1) -> PmlText:
	if host == null:
		return null
	var def = (host.get_meta(UiBuilder.PML_DEF_META) if host.has_meta(UiBuilder.PML_DEF_META) else null)
	var c := colour
	var h := halign
	if def != null:
		c = (def as UiLayoutParser.ControlDef).font_color
		if h < 0:
			h = (def as UiLayoutParser.ControlDef).halign
	var p := host.get_node_or_null("PmlText") as PmlText
	if p == null:
		p = PmlText.new()
		p.name = "PmlText"
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var r: Rect2 = host.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(Vector2.ZERO, host.size))
		p.position = Vector2.ZERO
		p.size = r.size
		host.add_child(p)
	p.base_align = TAG_CENTER if h == 1 else (TAG_RIGHT if h == 2 else TAG_LEFT)
	p.setup(builder.font_at(0) if builder != null else null, UiBuilder.FONT_SIZES[0], c)
	p.set_markup(markup_text)
	return p

# --- The parse --------------------------------------------------------------

## The markup as a flat list of items: {"text", "color", "style"} runs and
## {"br": true} breaks (and {"align": n} for p / center / left / right), in
## the state each run is drawn with.
static func parse(src: String, base_color: Color) -> Array:
	var out: Array = []
	var stack: Array = [{"color": Color(base_color, 1.0), "style": 0, "index": 0}]
	var tags: Array = []
	var i := 0
	var text := ""
	while i < src.length():
		var ch := src[i]
		if ch != "<":
			text += ch
			i += 1
			continue
		var close := src.find(">", i)
		if close == -1:
			text += src.substr(i)
			break
		if text != "":
			var st: Dictionary = stack[stack.size() - 1]
			out.append({"text": text, "color": st["color"], "style": st["style"]})
			text = ""
		var body := src.substr(i + 1, close - i - 1)
		i = close + 1
		var closing := body.begins_with("/")
		if closing:
			body = body.substr(1)
		var name_end := body.find(" ")
		var name := (body if name_end == -1 else body.substr(0, name_end)).to_lower()
		if name.ends_with("/"):
			name = name.substr(0, name.length() - 1)
		var tag := int(TAG_NAMES.get(name, 0))
		if tag == 0:
			continue
		if tag == TAG_BR:
			out.append({"br": true})
			continue
		if closing:
			# The innermost open tag of that kind ends, and the state it
			# pushed with it.
			for k in range(tags.size() - 1, -1, -1):
				if int(tags[k]) == tag:
					while tags.size() > k:
						tags.pop_back()
						if stack.size() > 1:
							stack.pop_back()
					break
			continue
		var top: Dictionary = (stack[stack.size() - 1] as Dictionary).duplicate()
		match tag:
			TAG_FONT:
				var c: Variant = attribute(body, "color")
				if c != null:
					top["color"] = colour_of(str(c))
				var s: Variant = attribute(body, "style")
				if s != null:
					top["style"] = style_of(str(s))
				var ix: Variant = attribute(body, "index")
				if ix != null:
					top["index"] = leading_int(str(ix))
			TAG_STRONG:
				top["style"] = STYLE_BOLD
			TAG_CENTER, TAG_LEFT, TAG_RIGHT:
				out.append({"align": tag})
		tags.append(tag)
		stack.append(top)
	if text != "":
		var st: Dictionary = stack[stack.size() - 1]
		out.append({"text": text, "color": st["color"], "style": st["style"]})
	return out

## The value of attribute `key` in a tag's text: what follows the first `"`
## after the name, up to the end of the tag -- the scan the readers then
## walk (0x9b2e40). Null when the tag has no such attribute.
static func attribute(tag_body: String, key: String) -> Variant:
	var low := tag_body.to_lower()
	var at := 0
	while true:
		at = low.find(key, at)
		if at == -1:
			return null
		var before := low[at - 1] if at > 0 else " "
		var after := at + key.length()
		if (before == " " or before == "\t") and after < low.length() \
				and (low[after] == "=" or low[after] == " "):
			var q := tag_body.find("\"", after)
			if q == -1:
				return null
			return tag_body.substr(q + 1)
		at += 1
	return null

## 0x9b1e40 over a value: four numbers (A, R, G, B) by 0xb9cc80, each scan
## skipped past the next `,`. The alpha is dropped where it is drawn.
static func colour_of(value: String) -> Color:
	var nums: Array[int] = []
	var at := 0
	for k in 4:
		var r := _number_at(value, at)
		nums.append(int(r[0]))
		at = int(r[1])
		if k < 3:
			var comma := value.find(",", at)
			at = value.length() if comma == -1 else comma + 1
	return Color8(nums[1] & 0xff, nums[2] & 0xff, nums[3] & 0xff, 255)

## 0xb9cc80(0, 1): blanks skipped, then the digits; [value, index after].
## A non-digit there reads 0 and the index stays where the blanks ended.
static func _number_at(s: String, at: int) -> Array:
	var i := at
	while i < s.length() and (s[i] == " " or s[i] == "\t"):
		i += 1
	var start := i
	while i < s.length() and s.unicode_at(i) >= 48 and s.unicode_at(i) <= 57:
		i += 1
	if i == start:
		return [0, at]
	return [int(s.substr(start, i - start)), i]

static func leading_int(value: String) -> int:
	return int(_number_at(value, 0)[0])

## 0x9b3090: the names joined by `|`, up to the closing quote.
static func style_of(value: String) -> int:
	var q := value.find("\"")
	var body := value if q == -1 else value.substr(0, q)
	var bits := 0
	for part in body.split("|", false):
		bits |= int(STYLE_NAMES.get(part.strip_edges().to_lower(), 0))
	return bits

# --- The layout -------------------------------------------------------------

## The items laid out at `width` (0 or less: no wrap, as 0x9b1280 makes it
## 0x7fffffff): the lines with their runs.
func layout(items: Array, width: int) -> Array:
	var limit := width if width > 0 else 0x7fffffff
	var out: Array = []
	var line := {"y": 0, "h": 0, "runs": [], "align": base_align}
	out.append(line)
	var x := 0
	for item: Dictionary in items:
		if item.has("br"):
			line = _new_line(out, line)
			x = 0
			continue
		if item.has("align"):
			line["align"] = int(item["align"])
			continue
		var rest: String = item["text"]
		var style := int(item["style"])
		var h := text_height(style)
		while rest != "":
			var cut := wrap_index(rest, style, limit - x)
			var part := rest.substr(0, cut)
			line["runs"].append({"x": x, "text": part, "color": item["color"], "style": style})
			line["h"] = maxi(int(line["h"]), h)
			x += int(text_width(part, style))
			rest = rest.substr(cut)
			if rest != "":
				line = _new_line(out, line)
				x = 0
	_align(out, limit)
	return out

func _new_line(out: Array, line: Dictionary) -> Dictionary:
	var next := {"y": int(line["y"]) + int(line["h"]) + LINE_MARGIN, "h": 0, "runs": [],
		"align": int(line["align"])}
	out.append(next)
	return next

## Centre / right lines moved by their slack (0x9b0c6d's align byte; OURS
## arithmetic: half the slack, rounded down).
func _align(out: Array, limit: int) -> void:
	if limit >= 0x7fffffff:
		return
	for line: Dictionary in out:
		var align := int(line["align"])
		if align == TAG_LEFT or (line["runs"] as Array).is_empty():
			continue
		var last: Dictionary = line["runs"][(line["runs"] as Array).size() - 1]
		var w := int(last["x"]) + int(text_width(str(last["text"]), int(last["style"])))
		var slack := limit - w
		var dx := slack / 2 if align == TAG_CENTER else slack
		for r: Dictionary in line["runs"]:
			r["x"] = int(r["x"]) + dx

## 0x8b3ef0, word mode: how many characters of `s` go on a line `room`
## wide. The advances are summed; the first character past the room (never
## the first) breaks after the last space before it, or before it when there
## was none. All of `s` when it fits.
func wrap_index(s: String, style: int, room: int) -> int:
	var sum := 0.0
	var after_space := -1
	for i in s.length():
		var adv := advance(s[i], style)
		sum += adv
		if sum > float(room) and i > 0:
			return after_space if after_space > 0 else i
		if s[i] == " ":
			after_space = i + 1
	return s.length()

## A glyph's advance (no kerning: 0x8b3910 sums the glyph records'). Each
## character is shaped alone, so a glyph the face lacks -- the quest texts'
## `◈` (U+25C8) is in neither Tahoma nor Arial -- comes from the system's
## fallback, as GDI's font linking draws it (OURS mechanism).
func advance(ch: String, style: int) -> float:
	if font == null:
		return 0.0
	if style & STYLE_BOLD:
		if bold_face != null:
			return bold_face.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		return font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 1.0
	return font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x

func text_width(s: String, style: int) -> float:
	var w := 0.0
	for ch in s:
		w += advance(ch, style)
	return w

## A run's line height: the face's tmHeight for its glyph mode.
func text_height(style: int) -> int:
	var face: Font = bold_face if (style & STYLE_BOLD) and bold_face != null else font
	return tm_height(face, font_size)

## GDI's tmHeight for `face` at an em of `px`: the face's OS/2 usWinAscent
## and usWinDescent over its head unitsPerEm, each times the em and rounded
## to nearest, summed (INFERRED, GDI's rule -- the ascent half is the one
## NamePlates.cell_ascent MEASURED against the original). A face whose
## tables cannot be read gives Godot's height.
static func tm_height(face: Font, px: int) -> int:
	if face == null:
		return px
	var m := win_metrics(face)
	if m.x <= 0:
		return int(ceilf(face.get_height(px)))
	return int(roundf(float(m.y) * px / float(m.x))) + int(roundf(float(m.z) * px / float(m.x)))

## The glyph cell's ascent: GDI's tmAscent (as above).
static func tm_ascent(face: Font, px: int) -> float:
	if face == null:
		return float(px)
	var m := win_metrics(face)
	if m.x <= 0:
		return face.get_ascent(px)
	return roundf(float(m.y) * px / float(m.x))

static var _metrics := {}

## [unitsPerEm, usWinAscent, usWinDescent] of the face's file, or zeros.
static func win_metrics(face: Font) -> Vector3i:
	var base := face
	while base is FontVariation and (base as FontVariation).base_font != null:
		base = (base as FontVariation).base_font
	if not (base is FontFile):
		return Vector3i.ZERO
	var key := base.get_instance_id()
	if _metrics.has(key):
		return _metrics[key]
	var m := _read_win_metrics((base as FontFile).data)
	_metrics[key] = m
	return m

static func _read_win_metrics(data: PackedByteArray) -> Vector3i:
	var at := 0
	if data.size() >= 16 and data.slice(0, 4).get_string_from_ascii() == "ttcf":
		at = _u32(data, 12)
	if data.size() < at + 12:
		return Vector3i.ZERO
	var upm := 0
	var asc := 0
	var desc := 0
	var n := _u16(data, at + 4)
	for i in range(n):
		var rec := at + 12 + i * 16
		if data.size() < rec + 16:
			break
		var tag := data.slice(rec, rec + 4).get_string_from_ascii()
		var off := _u32(data, rec + 8)
		if tag == "head" and data.size() >= off + 20:
			upm = _u16(data, off + 18)
		elif tag == "OS/2" and data.size() >= off + 78:
			asc = _u16(data, off + 74)
			desc = _u16(data, off + 76)
	return Vector3i(upm, asc, desc)

static func _u16(d: PackedByteArray, at: int) -> int:
	return (d[at] << 8) | d[at + 1]

static func _u32(d: PackedByteArray, at: int) -> int:
	return (d[at] << 24) | (d[at + 1] << 16) | (d[at + 2] << 8) | d[at + 3]

# --- The draw ---------------------------------------------------------------

func _draw() -> void:
	if font == null:
		return
	for line: Dictionary in lines:
		var top := float(int(line["y"]) - scroll)
		if top + float(line["h"]) < 0.0 or top > size.y:
			continue
		for r: Dictionary in line["runs"]:
			_draw_run(r, top)

func _draw_run(r: Dictionary, top: float) -> void:
	var style := int(r["style"])
	var bold := (style & STYLE_BOLD) != 0
	var face: Font = bold_face if bold and bold_face != null else font
	var at := Vector2(float(r["x"]), top + tm_ascent(face, font_size))
	var text := str(r["text"])
	var colour: Color = r["color"]
	if style & STYLE_SHADOW:
		_draw_text(at + Vector2(1, 1), text, bold, Color(0, 0, 0, 1))
	_draw_text(at, text, bold, colour)

## Glyph by glyph at the advances above; the weight-600 text in the bold
## file, or each glyph at x and x + 1 (GDI's simulation, HudNotice.draw_bold).
func _draw_text(at: Vector2, text: String, bold: bool, colour: Color) -> void:
	var style := STYLE_BOLD if bold else 0
	var face: Font = bold_face if bold and bold_face != null else font
	var x := at.x
	for ch in text:
		draw_string(face, Vector2(x, at.y), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, colour)
		if bold and bold_face == null:
			draw_string(face, Vector2(x + 1.0, at.y), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, colour)
		x += advance(ch, style)

## The text a QA or test reads back: the lines' runs joined.
func plain_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for line: Dictionary in lines:
		var s := ""
		for r: Dictionary in line["runs"]:
			s += str(r["text"])
		out.append(s)
	return out
