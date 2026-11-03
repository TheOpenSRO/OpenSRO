extends RefCounted
class_name TextLayout

## Round 859: where the original puts a control's text and an edit's caret,
## as pure formulas, so a test can check them against known strings and rects
## and the alignment census (TextAlignCensus) can measure ours against them.
## Every address is sro_client.exe's (`c:`). Labels: READ, INFERRED, OURS.
##
## **The text rect (READ, c:0x652800).** The control's rect moved in by its
## ClientRect: left + `+0x18c`, top + `+0x190`, width - (`+0x18c` + `+0x194`),
## height - (`+0x190` + `+0x198`) -- the parsed ClientRect's left, top, right,
## bottom (round 630). UiBuilder.text_rect is the same rule.
##
## **A static's or button's text (READ, CIFStatic c:0x64d9b0).** With the
## text's extent (`+0xdc` wide, `+0xde` tall):
##   HAlign 0: left    1: left + (width - text w) * 0.5    2: right - text w
##   VAlign 0: top     1: top + (height - text h) * 0.5    2: bottom - text h
## (0.5 is the double at 0xe1b7d0.) UiBuilder.place_label lays its labels by it.
##
## **An edit's text (READ, CIFEdit c:0x637b70; CIFEInputChatBox shares it;
## the .2dt CNIFEdit's c:0x47b5b0 is the same code on its own fields).** The
## same rect and the same rule, except HAlign 2 ends 2.0 short of the right
## (`(right - text w) - 2.0`, the double at 0xe1b898). The text's extent is
## the text board's (`+0x4c`: width, height). With **no text** (height 0) and
## VAlign 1 the top is `top + ((height - tmHeight - 2) >> 1)` (0x637e54..
## 0x637e7c: the caret's own height centred), with VAlign 2 `bottom -
## tmHeight` (0x637e3d).
##
## **A long edit's text (READ, 0x637d85..0x637de3, 0x637ef1..0x637f6f).** A
## single-line edit whose text is at least `width - 5` wide is drawn with its
## END at `left + width - 5` (left = that minus the text's width), whatever
## the caret; then, while that start is left of the rect and the caret is
## within 40 (the double at 0xe1b8f8) of the rect's left, the text moves right
## by min(rect left - text left, rect left - caret x + 40).
##
## **The caret (READ, 0x637e80..0x637ee5 and the quad at 0x637f83..).** Its x
## is the text's left plus the advances of the characters before the caret
## (0x8b3820 sums each glyph cell's width and spacing up to `+0x448`, plus one
## while an IME composition is open); its quad runs from that x to x + 2.0,
## from the text's top (plus the caret line's y, for a multi-line edit) to the
## top + the font's tmHeight + 2.0, in the edit's FontColor.

## The caret's width and the extra below the font's height (READ, 2.0 at 0xe1b898).
const CARET_WIDTH := 2.0
const CARET_EXTRA := 2.0
## A long single-line edit keeps its end this far in from the right (READ, 0x637d89 `add -5`).
const LONG_RIGHT_GAP := 5.0
## The caret's room at the left once a long text has been scrolled (READ, 40.0 at 0xe1b8f8).
const SCROLL_BACK_ROOM := 40.0
## HAlign 2's right inset in an edit (READ, 2.0 at 0xe1b898).
const EDIT_RIGHT_INSET := 2.0

## The text rect: `rect` less the ClientRect insets (left, top, right, bottom
## as a Rect2i's x, y, width, height -- UiLayoutParser's order).
static func text_rect(rect: Rect2, client: Rect2i) -> Rect2:
	return Rect2(rect.position.x + client.position.x, rect.position.y + client.position.y,
		rect.size.x - client.position.x - client.size.x, rect.size.y - client.position.y - client.size.y)

## A static's (button's) text top-left for a text of `text_size`.
static func static_origin(rect: Rect2, client: Rect2i, halign: int, valign: int, text_size: Vector2) -> Vector2:
	var r := text_rect(rect, client)
	var x := r.position.x
	match halign:
		1: x = r.position.x + (r.size.x - text_size.x) * 0.5
		2: x = r.end.x - text_size.x
	var y := r.position.y
	match valign:
		1: y = r.position.y + (r.size.y - text_size.y) * 0.5
		2: y = r.end.y - text_size.y
	return Vector2(x, y)

## An edit's text top-left before any long-text scroll. `text_size` is the
## text's extent (zero wide and tall when the edit is empty); `font_height`
## the face's tmHeight (the empty edit's rule).
static func edit_origin(rect: Rect2, client: Rect2i, halign: int, valign: int, text_size: Vector2,
		font_height: float) -> Vector2:
	var r := text_rect(rect, client)
	var x := r.position.x
	match halign:
		1: x = r.position.x + (r.size.x - text_size.x) * 0.5
		2: x = r.end.x - text_size.x - EDIT_RIGHT_INSET
	var y := r.position.y
	match valign:
		1: y = r.position.y + (r.size.y - text_size.y) * 0.5
		2: y = r.end.y - text_size.y
	if text_size.y <= 0.0:
		if valign == 1:
			# Unsigned shift in the original; a caret taller than the rect
			# wraps to a huge value there and is put back by the 2^32 fix-up
			# (0x637e76) -- the same as a signed floor here.
			y = r.position.y + floorf((r.size.y - font_height - CARET_EXTRA) / 2.0)
		elif valign == 2:
			y = r.end.y - font_height
	return Vector2(x, y)

## The long-text rule: the text's left for a single-line edit given its
## unscrolled `left`, the text rect, the text's width and the caret's advance
## from the text's start.
static func edit_scrolled_left(left: float, r: Rect2, text_w: float, caret_advance: float) -> float:
	if r.size.x - LONG_RIGHT_GAP < text_w:
		left = r.position.x + r.size.x - LONG_RIGHT_GAP - text_w
	var caret_x := left + caret_advance
	if left < r.position.x and caret_x <= r.position.x + SCROLL_BACK_ROOM:
		left += minf(r.position.x - left, r.position.x - caret_x + SCROLL_BACK_ROOM)
	return left

## The caret's quad: from the text's left + the advance before the caret, 2
## wide, from the text's top, tmHeight + 2 tall.
static func caret_rect(origin: Vector2, caret_advance: float, font_height: float) -> Rect2:
	return Rect2(origin.x + caret_advance, origin.y, CARET_WIDTH, font_height + CARET_EXTRA)

## Content margins that make a Godot LineEdit of height `height` draw its
## text where `edit_origin` puts it vertically, for a text `text_height` tall
## (Godot: y = top margin + int((height - top - bottom - text h) / 2), text
## left at the left margin; line_edit.cpp NOTIFICATION_DRAW). Returns
## [left, top, right, bottom]. The horizontal centring and right alignment
## are LineEdit's own on the same rect (its CENTER is int((w - margins -
## text w) / 2), the original's * 0.5 then truncated where it is drawn).
static func line_edit_margins(height: float, client: Rect2i, halign: int, valign: int,
		text_height: float) -> PackedFloat32Array:
	var left := float(client.position.x)
	var right := float(client.size.x) + (EDIT_RIGHT_INSET if halign == 2 else 0.0)
	var top := float(client.position.y)
	var bottom := float(client.size.y)
	var inner := height - top - bottom
	match valign:
		0:
			# Text at the top: the area below the text is all margin.
			bottom = maxf(0.0, height - top - text_height)
		2:
			# Text at the bottom: the area above it.
			top = maxf(0.0, height - bottom - text_height)
		_:
			# Centred: LineEdit's own centring on the inner rect. Its
			# int((inner - h) / 2) is the original's (inner - h) * 0.5
			# truncated where it is drawn, for an inner rect at least the
			# text's height.
			if inner < text_height:
				# Godot would grow the edit; keep it and put the top where
				# the original's negative half lands (trunc toward zero of
				# the screen coordinate: the top moves up by the floor).
				top = maxf(0.0, top + floorf((inner - text_height) * 0.5))
				bottom = maxf(0.0, height - top - text_height)
	return PackedFloat32Array([left, top, right, bottom])
