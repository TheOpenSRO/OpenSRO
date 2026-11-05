extends LineEdit
class_name CifEdit

## The client's text edit, `CIFEdit` (and `CIFEInputChatBox`, which shares its
## draw and message handlers), as a LineEdit with Godot's own behaviour taken
## away where the original has none (round 848, lane H). Every address is
## sro_client.exe's. Labels: READ (from the binary), INFERRED, OURS, OPEN.
##
## **How the original edits (READ).** CIFEdit keeps its own text buffer
## (`+0x5474`, at most 0x1000 characters: 0x6354e0 / 0x63748c) and caret
## (`+0x444`). Its Create (vslot_010, 0x637a60) makes a hidden Win32 EDIT at
## (-100, -100) only to own the keyboard focus and the IME, and subclasses it
## (0x637a30 -> 0x636cd0). The keys it acts on (0x637290, WM_KEYDOWN):
## End, Home, Left, Right (one character each, 0x635460) and Delete; and on
## WM_CHAR: Backspace, Enter, Tab / Escape (handed to the parent with style
## bit 2) and every character from 0x20 up. There is **no selection** of a
## range, **no word move or word delete**, and no mouse placement of the
## caret: a left press inside the edit only gives it the focus (0x637290
## case 0x201 -> 0xb9d9f0), outside it ends the input.
##
## **The hidden EDIT does not decide what is shown (READ).** Create replaces
## the EDIT's window procedure: `SetWindowLongA(hwnd, GWL_WNDPROC (-4),
## 0x637a30)` with the old one kept at `+0x384` (0x637a60's body, decompile of
## CIFEdit::vslot_010); 0x637a30 calls 0x636cd0, which hands a message to the
## stock EDIT (`CallWindowProcA(+0x384, ...)`) only on its fall-through. It
## returns 0 for WM_PASTE 0x302 and WM_UNDO 0x304 (never reaching the EDIT);
## for WM_KEYDOWN / WM_KEYUP (0x100 / 0x101) with Ctrl down it eats A, C, X, Z
## and V (V pastes only with style 0x200, through its own clipboard read
## 0x636bd0: OpenClipboard / GetClipboardData(CF_UNICODETEXT) into the
## client's buffer -- the developer console's edit alone sets 0x200, `push
## 0x1302` at 0x54170b); with Shift down it eats Insert and makes Home / End
## the whole-text mark; every other key goes to the game's input
## (0xba6f10, which reaches 0x637290 below) and then to the stock EDIT. WM_CHAR
## 0x102 goes to the game first too, then to the EDIT for a style-2 edit
## except Enter and Tab. So Ctrl+Left, Shift+arrows, WM_CHAR 0x16 (the Ctrl+V
## TranslateMessage makes) and EM_SETSEL do act on the stock EDIT -- whose
## window sits off-screen at (-100, -100) and is never drawn: the draw
## 0x637b70 reads only the client's buffer (`+0x5474`), caret (`+0x448`) and
## mark (`+0x41a`), and nothing in the class (0x634300..0x638300) reads the
## EDIT back -- no GetWindowText, WM_GETTEXT or EM_GETSEL (searched). What
## the player sees is 0x637290's own handling: Left / Right one character
## whether Ctrl or Shift is down (0x6376db cases 0x25 / 0x27 through
## 0x635460: 1, or 2 for a surrogate pair), Delete one character (case 0x2e),
## and WM_CHAR 0x16 below 0x20, so not inserted. No range selection is drawn.
## The mouse never reaches the EDIT (it is off the window); a press inside the
## edit is 0x637290's case 0x201, which only gives the focus (0xb9d9f0) -- no
## caret placement. OPEN: the Apps key (VK_APPS falls through to the EDIT,
## whose DefWindowProc would open its context menu at the hidden window);
## not built. OURS: Ctrl+Backspace deletes one character -- the original's
## WM_CHAR 0x7f is at or above 0x20 and so is inserted as U+007F.
##
## **The limit is in bytes (READ).** 0x634f80 stores the limit at `+0x3fc`
## (the chat's 100, the boxes' 12 / 40 / 64 ...); WM_CHAR inserts a character
## only while `+0x434` is below it (0x6375e6), and after every change 0x636330
## re-measures `+0x434` as the text's length in the ANSI code page
## (0x63641b, after 0x4fc870: WideCharToMultiByte(CP_ACP, ...) - 1) and cuts
## the text back to the limit when it is over (0x63642a -> 0x6362d0). So a
## limit counts bytes in the player's Windows code page: one a character in
## a Western one, two a Korean / Chinese / Japanese character in theirs. This
## edit takes LineEdit's `max_length` as that byte count; which code page the
## player has is INFERRED from the OS locale (DBCS for ko / zh / ja).
##
## **An edit no code limits takes 512 characters (READ).** The byte limit is
## its own field: the constructor (0x635cc0) sets `+0x3fc` to -1 (0x635d39 /
## 0x635d59, "no byte limit") and `+0x400` to 0x200 (0x635d85). WM_CHAR tests
## `+0x3fc` first (0x6375db): -1 makes it insert only while the shown text's
## length (`+0x1b0`, its wide string's) is below `+0x400` (0x6375f3..0x6375ff),
## and 0x636330 cuts back to `+0x400` characters the same way. Only 0x634f80
## (clamped 1..0x1000) sets the byte limit; 0x634fb0 sets `+0x400` and has no
## direct caller. So the login's ID and password (CPSTitle sets none) take 512.
## Here: `max_length` > 0 is a 0x634f80 byte limit; 0 is the 512 default,
## counted in Godot's characters (the original counts UTF-16 units, so a
## character outside the BMP counts two there -- not reproduced). OPEN: which
## setter each of our callers' limits came from was not traced site by site.
##
## **The whole-text mark (READ).** Shift+Home or Shift+End sets the edit's
## mark (`+0x41a`, 0x635030(1)), which gives the text board the background
## colour 0xff3b457a (0x635044); Home, End, Left and Right clear it
## (0x635030(0)); Delete with the mark empties the edit (0x6354e0); a
## character or Backspace with the mark first empties it (0x635720). This is
## the LineEdit's select_all with that selection colour, the text keeping its
## own colour.
##
## **The caret (READ, the draw 0x637b70).** A quad from the caret's x to x +
## 2.0 (`0xe1b898`), in the edit's own FontColor (`+0xa0`), drawn while the
## blink flag `+0x3ec` is set, the edit has the focus (0x634ea0) and style
## bit 0x20 is clear. The flag starts clear (0x637b50) and flips each time
## the edit's CETime (`+0x388`, set to 5 per second by 0x637b3c ->
## 0xba9aa0(5): 1000 / 5 = 200 ms) ticks (0x635530). So the caret is 2 pixels
## wide, the text's colour, and blinks 200 ms on, 200 ms off. Its height is
## the font's point size + 2.0 from the text's top (round 862: `[[+0x11c] +
## 4]`, the font object's size, not tmHeight; MEASURED 11 rows for FontIndex
## 0's 9 pt -- TextLayout's header). Its x and top are not truncated as the
## text is: a quad edge on a half pixel covers the next pixel (MEASURED,
## TextLayout.caret_pixels), so a centred text with an odd `w - text w` has
## its caret a pixel right of the glyph boundary.
##
## **Where the text and the caret go (READ, round 859; TextLayout has the
## formulas).** The text rect is the edit's rect less its ClientRect
## (0x652800); HAlign 0 / 1 / 2 put the text at its left, centre, or 2.0
## short of its right; VAlign 0 / 1 / 2 at its top, centre or bottom; the
## caret at the text's left + the advances before it, from the text's top,
## point size + 2 tall (round 862). Round 848's chat line was a second edit laid over the
## authored one with no insets at all, so its text and caret sat 5 px left of
## the original's (ClientRect 5,4,0,0) and its text was centred in the 20 px
## (VAlign 0 is the top). `lay_out` gives every edit the rule: the ClientRect
## and HAlign as LineEdit's content margins and alignment, VAlign by the top
## and bottom margins (LineEdit only centres; a top-aligned text gets the
## room below it as margin, kept on every resize and font change), and the
## caret is drawn here (`_draw`) by the original's quad -- Godot's own caret
## is the line's height, starts its blink shown and is switched off
## (transparent). The caret's x is Godot's own shaping of the shown text
## (TextServer's caret at the column, the same buffer LineEdit draws), so it
## stays on the glyph boundary LineEdit draws at every UI scale.
##
## **A long text, and what the edit draws (READ, round 860; TextLayout has
## the rule).** The draw works out where the text goes afresh every frame --
## no scroll is kept: a text more than `w - 5` wide (w the text rect's width)
## has its end at the rect's left + `w - 5` whatever the caret, and when its
## start is then left of the rect and the caret within 40 px of the rect's
## left, it moves right until the caret is 40 px in or its start is at the
## rect's left (0x637d85..0x637de3, 0x637ef1..0x637f6f). The text is drawn at
## that left truncated (0x6356c0: `_ftol`, cvttsd2si, of `+0x370` / `+0x374`),
## the caret from it. The whole draw runs inside a viewport of the edit's own
## rect (0x6531a0 with the control's `+0x40` rect from 0xb8f420, before the
## draw; 0x653220 puts the full screen back after), so a glyph crossing the
## edit's edge is cut there and drawn in part -- at the edit's edge, not the
## text rect's (the ClientRect's inset shows text). A password edit's text
## board holds '*' per character (0x636330, style 2), so the rule measures the
## mask. LineEdit's own scroll (the caret kept just inside the content area,
## glyphs crossing it left out) has no setter, so CifEdit draws the text itself
## (`_draw_ink`, on an internal child clipped to the edit's rect) by that rule,
## and LineEdit's own drawing is hidden (`self_modulate` alpha 0: its box,
## text, marked text and caret). The art box is drawn once, as CIFEdit draws
## it: Godot's second "focus" box over it while the edit has the keyboard is
## not drawn (the draw has no focus look but the caret).
##
## **Not built (OPEN):** the IME composition underline the draw adds
## (0x637b70, `0x468` / DAT_0110f9c8: dotted 0xff969696 or solid white; its
## y not read through); none is drawn. The composition itself is drawn in the
## text at the caret and the caret after it (READ: the composition is in the
## edit's buffer and 0x634c50 adds one to the caret column while it is open;
## a multi-character composition's caret at its end is INFERRED). Where the
## IME's own window goes (OURS): under our caret, as LineEdit puts it under
## its own.

## The caret's width (READ, the double at 0xe1b898).
const CARET_WIDTH := 2
## The caret's blink: the CETime at 5 Hz, a flip per tick (READ).
const CARET_BLINK_SEC := 0.2
## The whole-text mark's background (READ, 0x635044: 0xff3b457a).
const MARK_COLOUR := Color8(0x3b, 0x45, 0x7a)
## The constructor's character limit with no byte limit set (READ, above).
const DEFAULT_CHAR_LIMIT := 0x200

var _colour := Color.WHITE
## The layout the text follows (lay_out): the ClientRect insets (left, top,
## right, bottom as x, y, w, h), HAlign and VAlign. Unset (`_laid` false), the
## edit keeps whatever margins its maker gave it and LineEdit's centring.
var _client := Rect2i()
var _halign := 0
var _valign := 1
var _laid := false
var _margins_busy := false
## The drawn caret's blink: shown half, 200 ms each, starting hidden when the
## edit takes the keyboard (READ 0x637b50 clears the flag).
var _blink_on := false
var _blink_t := 0.0
## A caret drawn regardless of the blink and the focus (the census's probe).
var caret_probe := false
## What the edit draws (round 860): an internal child the size of the edit,
## clipped to it (the original's viewport), drawn after LineEdit's own
## (hidden) drawing. `_draw_ink` fills it.
var _ink: Control
## The shaped text the ink draws, kept while its text and face do not change.
var _shaped: TextLine
var _shaped_key := []

## The ink: draws for its edit (`CifEdit._draw_ink`).
class Ink extends Control:
	var edit: Object
	func _init() -> void:
		name = "CifEditInk"
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		focus_mode = Control.FOCUS_NONE
		clip_contents = true
		set_anchors_preset(Control.PRESET_TOP_WIDE)
	func _draw() -> void:
		if edit != null:
			edit.call(&"_draw_ink", self)

func _init() -> void:
	text_changed.connect(_hold_byte_limit)
	KeyInput.line_edit_as_42(self)  # round 754: Godot 4.4+ editing state
	context_menu_enabled = false
	shortcut_keys_enabled = false
	middle_mouse_paste_enabled = false
	drag_and_drop_selection_enabled = false
	if "emoji_menu_enabled" in self:
		set("emoji_menu_enabled", false)
	caret_blink = true
	caret_blink_interval = CARET_BLINK_SEC
	add_theme_constant_override("caret_width", CARET_WIDTH)
	add_theme_color_override("selection_color", MARK_COLOUR)
	set_colour(_colour)
	set_process(false)
	# CIFEdit draws no box of its own (its art, if any, is the layout's,
	# which the maker sets as a texture box): no Godot LineEdit box, whose
	# 4 px margins would also hold the edit taller than its rect.
	for st in _STYLES:
		add_theme_stylebox_override(st, StyleBoxEmpty.new())
	# Round 860: LineEdit's own drawing hidden (its scroll is not the
	# original's); the ink draws the box, the text and the caret.
	self_modulate = Color(1, 1, 1, 0)
	_ink = Ink.new()
	_ink.edit = self
	add_child(_ink, false, Node.INTERNAL_MODE_FRONT)

## The edit's FontColor: its text, its caret and its marked text. Also the
## colour of an edit that does not take input (INFERRED: CIFEdit's draw has
## one text colour; Godot greys a read-only line) and of a layout's own text
## shown before anything is typed (OURS: Godot's placeholder is a faded grey;
## how CIFEdit shows a layout's Text was not read).
func set_colour(colour: Color) -> void:
	_colour = colour
	add_theme_color_override("font_color", colour)
	# Godot's caret is not drawn: _draw draws the original's (round 859).
	add_theme_color_override("caret_color", Color(colour, 0.0))
	add_theme_color_override("font_selected_color", colour)
	add_theme_color_override("font_uneditable_color", colour)
	add_theme_color_override("font_placeholder_color", colour)

func colour() -> Color:
	return _colour

## Lays the text out by the original's rule (the header; TextLayout): the
## text rect is the edit less `client` (ClientRect left, top, right, bottom
## as a Rect2i's x, y, w, h), placed by `halign` / `valign` (the layout's 0 /
## 1 / 2). Applied now and on every resize or font change.
func lay_out(client: Rect2i, halign: int, valign: int) -> void:
	_client = client
	_halign = halign
	_valign = valign
	_laid = true
	match halign:
		1: alignment = HORIZONTAL_ALIGNMENT_CENTER
		2: alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_: alignment = HORIZONTAL_ALIGNMENT_LEFT
	_apply_margins()
	_fit_ink()

## The same layout as `other` (an edit laid over an authored one, as the chat
## line is over GDR_CHAT_INPUTBOX).
func lay_out_as(other: CifEdit) -> void:
	if other != null and other._laid:
		lay_out(other._client, other._halign, other._valign)

func is_laid_out() -> bool:
	return _laid

func layout_client() -> Rect2i:
	return _client

func layout_halign() -> int:
	return _halign

func layout_valign() -> int:
	return _valign

## The point size the edit's font was made at (round 862, READ: the caret is
## that + 2.0 tall; TextLayout.point_size).
func caret_points() -> int:
	return TextLayout.point_size(get_theme_font_size(&"font_size"))

## The face's height at the edit's size: the tmHeight stand-in (GDI's
## tmHeight is tmAscent + tmDescent; Godot's height is ascent + descent of
## the same face -- INFERRED equivalent).
func font_height() -> float:
	var font := get_theme_font(&"font")
	return font.get_height(get_theme_font_size(&"font_size")) if font != null else 0.0

const _STYLES := [&"normal", &"focus", &"read_only"]
const _OWN_BOX_META := &"cif_edit_own"

func _apply_margins() -> void:
	if not _laid or _margins_busy:
		return
	var fh := ceilf(font_height())
	if fh <= 1.0:
		# The face is not resolved yet (outside the tree): wait for it.
		return
	_margins_busy = true
	var m := TextLayout.line_edit_margins(layout_height(), _client, _halign, _valign, fh)
	for st in _STYLES:
		var sb: StyleBox = get_theme_stylebox(st) if has_theme_stylebox_override(st) else null
		if sb == null or not sb.has_meta(_OWN_BOX_META):
			# A box of its own, so a box shared with another edit (or a
			# caller's) is not changed under it.
			sb = sb.duplicate() if sb != null else StyleBoxEmpty.new()
			sb.set_meta(_OWN_BOX_META, true)
			_set_margins(sb, m)
			add_theme_stylebox_override(st, sb)
		else:
			_set_margins(sb, m)
	_margins_busy = false

## The height the margins are worked out for: the layout's own (the rect the
## builder recorded) when there is one -- Godot holds a Control at least as
## tall as its minimum, so a size read back after a taller minimum would keep
## the edit that tall -- else the edit's height now.
func layout_height() -> float:
	if has_meta(UiBuilder.AUTHORED_RECT_META):
		var r: Rect2 = get_meta(UiBuilder.AUTHORED_RECT_META)
		if r.size.y > 0.0:
			return r.size.y
	return size.y

## The ink is the original's viewport: the edit's rect as the layout gives it
## (0x6531a0 with the control's `+0x40` rect). Godot can hold the edit taller
## than that (its minimum: the font's line), so the ink takes the edit's
## width and the layout's height -- a caret or glyph below the authored rect
## is cut there, as the original cuts it (the party match name edit, 11 px
## tall, cuts the 16 px caret to 11).
func _fit_ink() -> void:
	if _ink == null:
		return
	var h := minf(size.y, layout_height()) if layout_height() > 0.0 else size.y
	if _ink.offset_bottom != h:
		_ink.offset_bottom = h

static func _set_margins(sb: StyleBox, m: PackedFloat32Array) -> void:
	if sb.content_margin_left != m[0]:
		sb.content_margin_left = m[0]
	if sb.content_margin_top != m[1]:
		sb.content_margin_top = m[1]
	if sb.content_margin_right != m[2]:
		sb.content_margin_right = m[2]
	if sb.content_margin_bottom != m[3]:
		sb.content_margin_bottom = m[3]

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED, NOTIFICATION_THEME_CHANGED, NOTIFICATION_ENTER_TREE:
			_apply_margins()
			_fit_ink()
		NOTIFICATION_FOCUS_ENTER:
			_blink_on = false
			_blink_t = 0.0
			set_process(true)
			queue_redraw()
		NOTIFICATION_FOCUS_EXIT:
			set_process(false)
			_blink_on = false
			queue_redraw()

func _process(delta: float) -> void:
	_blink_t += delta
	while _blink_t >= CARET_BLINK_SEC:
		_blink_t -= CARET_BLINK_SEC
		_blink_on = not _blink_on
		queue_redraw()

## LineEdit redraws on every change of its text, caret, focus, IME and
## theme; the ink follows it in the same frame (round 860).
func _draw() -> void:
	if _ink != null:
		_ink.queue_redraw()

## What the edit shows (round 860, the header): its box, the marked text's
## background, the text where the original puts it and the original's caret
## (READ 0x637b70: while the blink flag is set and the edit has the keyboard),
## on the ink -- the edit's own coordinates, clipped to its rect.
func _draw_ink(ink: Control) -> void:
	var sb := get_theme_stylebox(&"normal" if editable else &"read_only")
	if not flat and sb != null:
		ink.draw_style_box(sb, Rect2(Vector2.ZERO, size))
	var p := placement()
	if p.is_empty():
		return
	var line: TextLine = p["line"]
	if line != null:
		var at := Vector2(p["left"], p["top"])
		var marked: bool = has_selection() and not p["placeholder"]
		if marked:
			var sel := TextServerManager.get_primary_interface().shaped_text_get_selection(line.get_rid(),
				get_selection_from_column(), get_selection_to_column())
			for v in sel:
				ink.draw_rect(Rect2(at.x + v.x, at.y, v.y - v.x, p["text_h"]), get_theme_color(&"selection_color"))
		var colour: Color
		if p["placeholder"]:
			colour = get_theme_color(&"font_placeholder_color")
		elif marked:
			colour = get_theme_color(&"font_selected_color")
		else:
			colour = get_theme_color(&"font_color" if editable else &"font_uneditable_color")
		line.draw(ink.get_canvas_item(), at, colour)
	var r: Rect2 = p["caret"]
	if (caret_probe or (_blink_on and caret_shown())) and r.size.x > 0.0:
		ink.draw_rect(r, _colour)
	_place_ime_window(r)

## Whether the caret is drawn at all now (the blink aside): the edit has the
## keyboard and takes input.
func caret_shown() -> bool:
	if not has_focus() or not editable:
		return false
	if has_method("is_editing") and not bool(call("is_editing")):
		return false
	return true

## Where the caret goes, in the edit's own coordinates (READ, the header):
## x at the text's left + the advance before the caret column, 2 wide; from
## the text's top, the font's point size + 2 tall, on the pixels the quad
## covers (round 862).
func caret_rect() -> Rect2:
	var p := placement()
	return p["caret"] if not p.is_empty() else Rect2()

## The text's drawn left in the edit's coordinates (the long-text rule
## applied), 0 without a face.
func text_left() -> float:
	var p := placement()
	return p["left"] if not p.is_empty() else 0.0

## The text rect's left and width along x in the edit's coordinates, which
## the long-text rule measures: the laid-out ClientRect (0x652800; no HAlign
## 2 inset), else the content margins.
func rule_span(sb: StyleBox = null) -> Vector2:
	if _laid:
		return Vector2(_client.position.x, size.x - _client.position.x - _client.size.x)
	if sb == null:
		sb = get_theme_stylebox(&"normal" if editable else &"read_only")
	var ml := sb.get_margin(SIDE_LEFT)
	return Vector2(ml, size.x - ml - sb.get_margin(SIDE_RIGHT))

## The composition the IME holds now (drawn at the caret), or "".
func _ime_text() -> String:
	if not has_focus() or not (has_method("has_ime_text") and bool(call("has_ime_text"))):
		return ""
	return DisplayServer.ime_get_text()

## Where everything goes this frame: `line` (the shaped text, or the
## placeholder; null when there is neither), `left` / `top` (the text's
## top-left), `text_w` / `text_h`, `advance` (the caret's, from the text's
## left), `caret` (its quad), `placeholder`, `shown` (the text as drawn: the
## IME composition in it, a password masked). Vertically, and horizontally
## for a text that is not long, where LineEdit puts it on the content margins
## lay_out set (line_edit.cpp's NOTIFICATION_DRAW with no scroll; round 859
## measured that against the original's rule: 0 px); a long text by the
## original's rule (round 860).
func placement() -> Dictionary:
	var font := get_theme_font(&"font")
	if font == null:
		return {}
	var fs := get_theme_font_size(&"font_size")
	var sb := get_theme_stylebox(&"normal" if editable else &"read_only")
	var ml := sb.get_margin(SIDE_LEFT)
	var mr := sb.get_margin(SIDE_RIGHT)
	var mt := sb.get_margin(SIDE_TOP)
	var y_area := int(size.y - sb.get_minimum_size().y)
	var fh := font_height()
	var col := caret_column
	var shown := text
	var ime := _ime_text()
	if ime != "":
		shown = text.substr(0, col) + ime + text.substr(col)
		col += ime.length()
	if secret and shown != "":
		shown = (secret_character if secret_character != "" else "*").left(1).repeat(shown.length())
	var placeholder := shown == "" and placeholder_text != ""
	var drawn := atr(placeholder_text) if placeholder else shown
	var line: TextLine = _shape(drawn, font, fs) if drawn != "" else null
	var tw := line.get_size().x if line != null else 0.0
	var th := line.get_size().y if line != null else 0.0
	# LineEdit's x with no scroll (ints, as line_edit.cpp has them).
	var x := float(int(ml))
	# Round 862: the unrounded left and top the original works the caret
	# from (`+0x370` / `+0x374` as floats; only the text board is drawn at
	# their truncation, 0x6356c0). Centred, the left is left + (w - text w)
	# * 0.5, a half pixel whenever w - text w is odd.
	var x_exact := x
	match alignment:
		HORIZONTAL_ALIGNMENT_CENTER:
			x = float(int(ml + maxi(0, int(size.x - float(int(ml + mr)) - tw) / 2)))
			x_exact = maxf(ml, ml + (size.x - ml - mr - tw) * 0.5)
		HORIZONTAL_ALIGNMENT_RIGHT:
			x = float(maxi(int(ml), int(size.x - ceilf(mr + tw))))
			x_exact = x
	var top_exact := mt + (y_area - th) / 2.0
	var top := float(int(top_exact))
	var adv := 0.0
	if line != null and not placeholder:
		var carets: Dictionary = TextServerManager.get_primary_interface().shaped_text_get_carets(line.get_rid(), col)
		var lead: Rect2 = carets.get("leading_rect", Rect2())
		var trail: Rect2 = carets.get("trailing_rect", Rect2())
		adv = lead.position.x if lead != Rect2() else trail.position.x
		if lead == Rect2() and trail == Rect2():
			adv = tw if col >= shown.length() else 0.0
	var left := x
	if line != null:
		# The long-text rule (READ, the header): the text's extent in the
		# text board's whole pixels; the left truncated where it is drawn
		# (0x6356c0) -- only when the rule moved it.
		var span := rule_span(sb)
		var ruled := TextLayout.edit_scrolled_left(x, Rect2(span.x, 0.0, span.y, 0.0), ceilf(tw), adv)
		if ruled != x:
			left = floorf(ruled)
			x_exact = left
	var caret: Rect2
	if shown == "":
		# No text: the empty caret (LineEdit's x per alignment; the
		# original's VAlign 1 / 2 tops, 0x637e3d..0x637e7c).
		var ex := ml
		match alignment:
			HORIZONTAL_ALIGNMENT_CENTER:
				# Round 862: left + w * 0.5, unrounded (a half pixel for an
				# odd width; the quad's pixels below).
				ex = ml + maxf(0.0, size.x - ml - mr) * 0.5
			HORIZONTAL_ALIGNMENT_RIGHT:
				ex = size.x - mr
		var ey := mt + int((y_area - ceilf(fh)) / 2.0)
		if _laid:
			ey = TextLayout.edit_origin(Rect2(Vector2.ZERO, size), _client, 0, _valign, Vector2.ZERO, fh).y
		caret = TextLayout.caret_pixels(TextLayout.caret_rect(Vector2(ex, ey), 0.0, caret_points()))
	else:
		caret = TextLayout.caret_pixels(TextLayout.caret_rect(Vector2(x_exact, top_exact), adv, caret_points()))
	return {"line": line, "left": left, "top": top, "text_w": tw, "text_h": th, "advance": adv,
		"caret": caret, "placeholder": placeholder, "shown": shown}

## `s` shaped in the edit's face, kept until the text or the face changes.
func _shape(s: String, font: Font, fs: int) -> TextLine:
	var key := [s, font.get_rid(), fs, language]
	if _shaped != null and key == _shaped_key:
		return _shaped
	_shaped = TextLine.new()
	_shaped.add_string(s, font, fs, language)
	_shaped_key = key
	return _shaped

## The IME's window under our caret while the edit is editing (OURS: LineEdit
## puts it under its own caret in its draw, which runs before the ink's; the
## same sum with our caret's x).
func _place_ime_window(caret: Rect2) -> void:
	if not (has_method("is_editing") and bool(call("is_editing"))):
		return
	if not DisplayServer.has_feature(DisplayServer.FEATURE_IME):
		return
	var w := get_window()
	if w == null:
		return
	var font := get_theme_font(&"font")
	var fh := font.get_height(get_theme_font_size(&"font_size")) if font != null else 0.0
	var pos := w.get_screen_transform() * (Vector2(caret.position.x, (size.y + fh) / 2.0) + get_global_position())
	DisplayServer.window_set_ime_position(Vector2i(pos), w.get_window_id())

## Whether the player's Windows code page is a double-byte one (INFERRED from
## the OS locale's language: Korean, Chinese, Japanese).
static func dbcs_code_page() -> bool:
	return OS.get_locale_language() in ["ko", "zh", "ja"]

## `s`'s length in the ANSI code page, as 0x4fc870 measures it: a character
## above 0x7f takes two bytes in a double-byte code page, one otherwise.
static func acp_bytes(s: String, dbcs: bool = dbcs_code_page()) -> int:
	var n := 0
	for i in s.length():
		n += 2 if dbcs and s.unicode_at(i) > 0x7f else 1
	return n

## The byte limit (READ, above): a typed character that takes the text past
## `max_length` bytes is not taken (0x6375e6); any other change over it is cut
## back from the end (0x6362d0).
func _hold_byte_limit(t: String) -> void:
	if max_length <= 0:
		# No byte limit: the 512-character default, cut back as 0x636330 does.
		if t.length() > DEFAULT_CHAR_LIMIT:
			var at0 := caret_column
			text = t.left(DEFAULT_CHAR_LIMIT)
			caret_column = mini(at0, DEFAULT_CHAR_LIMIT)
		return
	if acp_bytes(t) <= max_length:
		return
	var at := caret_column
	var without := t.substr(0, at - 1) + t.substr(at) if at > 0 else t
	if at > 0 and acp_bytes(without) <= max_length:
		text = without
		caret_column = at - 1
		return
	while t != "" and acp_bytes(t) > max_length:
		t = t.left(t.length() - 1)
	text = t
	caret_column = mini(at, t.length())

## An existing LineEdit given the same look (a line this file did not make).
## Its behaviour stays Godot's.
static func style(edit: LineEdit, colour: Color) -> void:
	if edit == null:
		return
	if edit is CifEdit:
		(edit as CifEdit).set_colour(colour)
		return
	edit.context_menu_enabled = false
	edit.shortcut_keys_enabled = false
	edit.middle_mouse_paste_enabled = false
	edit.selecting_enabled = false
	edit.drag_and_drop_selection_enabled = false
	if "emoji_menu_enabled" in edit:
		edit.set("emoji_menu_enabled", false)
	edit.caret_blink = true
	edit.caret_blink_interval = CARET_BLINK_SEC
	edit.add_theme_constant_override("caret_width", CARET_WIDTH)
	edit.add_theme_color_override("selection_color", MARK_COLOUR)
	for c in ["font_color", "caret_color", "font_selected_color", "font_uneditable_color"]:
		edit.add_theme_color_override(c, colour)

## A multi-line CIFEdit (style bit 0x40: the draw's line offset 0x637d6a and
## the scroll 0x635070 makes) shown as a TextEdit, given the same rules as far
## as a TextEdit takes them: the caret, no selection, menu, shortcuts or
## middle-button paste, and a left press that only gives it the keyboard
## (accepted in the gui_input signal, which runs before TextEdit's own
## handling). Its scroll bar is not the original's (OPEN).
static func style_text_edit(edit: TextEdit, colour: Color) -> void:
	if edit == null:
		return
	edit.context_menu_enabled = false
	edit.shortcut_keys_enabled = false
	edit.selecting_enabled = false
	edit.middle_mouse_paste_enabled = false
	edit.drag_and_drop_selection_enabled = false
	if "emoji_menu_enabled" in edit:
		edit.set("emoji_menu_enabled", false)
	edit.caret_blink = true
	edit.caret_blink_interval = CARET_BLINK_SEC
	edit.highlight_current_line = false
	edit.highlight_all_occurrences = false
	edit.add_theme_constant_override("caret_width", CARET_WIDTH)
	for c in ["font_color", "caret_color", "font_readonly_color", "font_selected_color"]:
		edit.add_theme_color_override(c, colour)
	edit.add_theme_color_override("background_color", Color(0, 0, 0, 0))
	edit.gui_input.connect(func(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb != null and mb.button_index != MOUSE_BUTTON_WHEEL_UP and mb.button_index != MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and edit.editable and not edit.has_focus():
				edit.grab_focus()
			edit.accept_event()
		elif event is InputEventMouseMotion and (event as InputEventMouseMotion).button_mask != 0:
			edit.accept_event())

## The original's input rules, ahead of LineEdit's own (a handled event never
## reaches LineEdit: Control._call_gui_input).
func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null:
		# Every button: no caret placed, no range selected, no menu, no
		# middle-button paste. A left press gives the edit the keyboard.
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and editable:
			take_keyboard()
		if mb.button_index != MOUSE_BUTTON_WHEEL_UP and mb.button_index != MOUSE_BUTTON_WHEEL_DOWN:
			accept_event()
		return
	if event is InputEventMouseMotion and (event as InputEventMouseMotion).button_mask != 0:
		accept_event()
		return
	var k := event as InputEventKey
	if k == null or not k.pressed:
		return
	if _key(k):
		accept_event()

## The keyboard to this edit, editing (a left press inside it).
func take_keyboard() -> void:
	if not has_focus():
		grab_focus()
	if has_method("edit") and has_method("is_editing") and not bool(call("is_editing")):
		call("edit")

## One key press: true when it is handled here (and so not by LineEdit).
func _key(k: InputEventKey) -> bool:
	var code := k.keycode
	var ctrl := k.ctrl_pressed or k.meta_pressed
	if ctrl and code in [KEY_A, KEY_C, KEY_X, KEY_Z, KEY_V, KEY_Y]:
		return true
	if k.shift_pressed and code == KEY_INSERT:
		return true
	if k.shift_pressed and (code == KEY_HOME or code == KEY_END):
		if text != "":
			select_all()
		return true
	match code:
		KEY_LEFT, KEY_RIGHT:
			# One character, with Shift or Ctrl too; the mark goes.
			var at := caret_column
			deselect()
			caret_column = clampi(at + (1 if code == KEY_RIGHT else -1), 0, text.length())
			return true
		KEY_HOME, KEY_END:
			deselect()
			caret_column = 0 if code == KEY_HOME else text.length()
			return true
		KEY_BACKSPACE, KEY_DELETE:
			if not editable:
				return true
			if has_selection():
				# The mark empties the edit (0x6354e0 / 0x635720).
				_replace_all("")
				return true
			if ctrl:
				# One character, not a word: Ctrl+Delete as the original's
				# case 0x2e (READ); Ctrl+Backspace OURS (the header).
				var at := caret_column
				if code == KEY_BACKSPACE and at > 0:
					_replace_all(text.substr(0, at - 1) + text.substr(at), at - 1)
				elif code == KEY_DELETE and at < text.length():
					_replace_all(text.substr(0, at) + text.substr(at + 1), at)
				return true
	return false

func _replace_all(value: String, caret := 0) -> void:
	text = value
	caret_column = caret
	text_changed.emit(text)
