extends Control
class_name HudNotice

## A CIFNotify banner: GDR_NOTICE, the notice banner a GM notice raises
## besides its chat line (round 634; docs/protocol/chat.md), and
## GDR_WARNING_WND, the banner for the level-up line and the unique monster
## notices (rounds 639 and 657; docs/protocol/unique_notice.md).
##
## READ: 0x876810's type-7 branch calls 0x777bf0, which fetches the
## interface's child 0x14 -- ginterface.txt's GDR_NOTICE, a CIFNotify -- and
## hands it the text (0x7b3eb0); 0x77b580 does the same for child 0x23,
## GDR_WARNING_WND. That function
##
##   - sets the banner's life to 7000 ms (+0x7c8 = 7000);
##   - sets the text, measures it (0x8b2f20) and sizes the window and its text
##     to the extent;
##   - places it at x = screen width / 2 - text width / 2, y = +0x7d4;
##   - shows it at alpha 255.
##
## Its update (0x7b3e20) counts the life down and, over the last 2000 ms
## (0x7d0), sets the alpha to remaining * 255 / 2000; at 0 it hides.
##
## What differs between the two instances is set once, when the interface is
## built (CGInterface's setup, round 657 READ):
##
##   - y (+0x7d4, `0x7b3d40`): GDR_NOTICE 100 (`push 0x64` at 0x78cbbe),
##     GDR_WARNING_WND 130 (`push 0x82` at 0x78cbed). The class's constructor
##     (0x7b3c40) sets 0, which round 634 took for the answer; the setup
##     overwrites it for both.
##   - the frame (0x819690 with edge, edge2, edge, edge2; 0x8199e0 with the
##     corner): GDR_NOTICE keeps the class's `com_notice_*.ddj` (0x7b3fe0);
##     GDR_WARNING_WND is given `com_warning_edge.ddj`,
##     `com_warning_edge2.ddj` and `com_warning_corner.ddj` (0x78cc0d..
##     0x78ccfb, the strings at 0xdb977c, 0xdb9750, 0xdb9724).
##   - the fill colour (+0x7d8..+0x7da, `0x7b3d10(r, g, b)`): GDR_NOTICE
##     (128, 45, 67) (0x78cbd2..0x78cbe8), GDR_WARNING_WND (0, 52, 92)
##     (0x78cd00..0x78cd12) -- a dark blue.
##
## The fill is drawn by the class's render (vslot 13, 0x7b3cb0) while the
## banner is up (+0x7cc): a quad in the fill colour (0x654d10) whose alpha
## byte is `-0x80 - (0xff - a) / 2` for the window's alpha a -- 128 at full
## alpha, fading with it -- and then the stretch frame (0x81a450). MEASURED:
## each frame texture is ONE colour, the same as its instance's fill:
## com_notice_* all (128, 45, 67) and com_warning_* all (0, 52, 92), in
## A8R8G8B8, the corner fading in both directions, edge2 (40x8) across, edge
## (4x8) down to alpha 128. INFERRED: the fill's quad is the window's rect
## (0x654d10's vertices come from the window; how was not read) and the frame
## is laid out as a stretch frame over it -- corners at the corners, edge2 on
## the sides, edge along the top and bottom (how 0x8185e0 / 0x8182e0 size the
## frame was not read).
##
## The text is ifnotify.txt's GDR_NOTIFY_TXT, FontColor (255,255,255,255),
## FontIndex 0 (0x7b3fe0 builds it from that file); nothing in 0x7b3eb0 or
## 0x77b580 changes its colour. The layout's `Color=` lines (GDR_WARNING_WND's
## "255,119,119,251") are not read by the client (the resinfo parser
## 0x82c1d0 has no such field; docs/WORLD_ISSUES.md).

const UiBuilder = preload("res://scripts/ui/ui_builder.gd")

const LIFE_MS := 7000
const FADE_MS := 2000
const EDGE_DDJ := "interface\\ifcommon\\com_notice_edge.ddj"
const EDGE2_DDJ := "interface\\ifcommon\\com_notice_edge2.ddj"
const CORNER_DDJ := "interface\\ifcommon\\com_notice_corner.ddj"

## The two instances, as CGInterface's setup makes them (READ, see above).
## GDR_NOTICE, interface child 0x14: the GM notice.
const STYLE_NOTICE := {
	"name": "GDR_NOTICE", "y": 100, "fill": Color(128.0 / 255.0, 45.0 / 255.0, 67.0 / 255.0),
	"edge": EDGE_DDJ, "edge2": EDGE2_DDJ, "corner": CORNER_DDJ,
}
## GDR_WARNING_WND, interface child 0x23: the level-up line and the unique
## notices -- the blue banner.
const STYLE_WARNING := {
	"name": "GDR_WARNING_WND", "y": 130, "fill": Color(0.0, 52.0 / 255.0, 92.0 / 255.0),
	"edge": "interface\\ifcommon\\com_warning_edge.ddj",
	"edge2": "interface\\ifcommon\\com_warning_edge2.ddj",
	"corner": "interface\\ifcommon\\com_warning_corner.ddj",
}
## The pieces' size: the corner and edge2 are 40x8, the edge 4x8.
const SIDE := Vector2(40, 8)
## GDR_NOTICE's FontColor (255,255,255,255) and FontIndex 0.
const TEXT_COLOR := Color.WHITE

var _font: Font
var _font_size := 12
var _edge: Texture2D
var _edge2: Texture2D
var _corner: Texture2D
var _text := ""
var _left_ms := 0
var _style: Dictionary = STYLE_NOTICE
## The window's alpha, 0..255 (CIFWnd +0x12d): 255 while shown, then
## remaining * 255 / 2000 over the fade. The frame and the text are drawn at
## it and the fill at fill_alpha_for(it), so no modulate is used.
var _alpha := 255

## `style` is STYLE_NOTICE (the default) or STYLE_WARNING.
func setup(builder: UiBuilder, style: Dictionary = STYLE_NOTICE) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_style = style
	if builder != null:
		_font = builder.font_at(0)
		_font_size = UiBuilder.FONT_SIZES[0]
		_edge = builder.load_texture(String(style["edge"]))
		_edge2 = builder.load_texture(String(style["edge2"]))
		_corner = builder.load_texture(String(style["corner"]))
	if _font == null:
		_font = ThemeDB.fallback_font

## The instance's layout name (GDR_NOTICE / GDR_WARNING_WND).
func style_name() -> String:
	return String(_style["name"])

## The fill colour, opaque (the alpha is fill_alpha_for's).
func fill_color() -> Color:
	return _style["fill"]

## The fill quad's alpha byte for the window alpha `a` (0x7b3cb0:
## `-0x80 - (0xff - a) / 2`, kept to its low byte): 128 at 255, 1 at 0.
static func fill_alpha_for(a: int) -> int:
	return (-0x80 - (0xff - a) / 2) & 0xff

## The window's current alpha, 0..255.
func alpha() -> int:
	return _alpha

## Shows `text` for LIFE_MS (0x7b3eb0): the window is the text's extent,
## centred, at the instance's y.
func show_notice(text: String) -> void:
	_text = text
	_left_ms = LIFE_MS
	var extent := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size)
	extent.y = _font.get_height(_font_size)
	var screen_w := get_viewport_rect().size.x if is_inside_tree() else 1024.0
	size = extent
	position = Vector2(floor(screen_w / 2.0 - extent.x / 2.0), float(_style["y"]))
	_alpha = 255
	visible = true
	queue_redraw()

func text() -> String:
	return _text

func remaining_ms() -> int:
	return _left_ms

## The banner's alpha, 0..1, for `left` ms of life (0x7b3e20).
static func alpha_for(left: int) -> float:
	if left <= 0:
		return 0.0
	if left > FADE_MS:
		return 1.0
	return float(left * 255 / FADE_MS) / 255.0

func _process(delta: float) -> void:
	if not visible:
		return
	advance(int(delta * 1000.0))

func advance(ms: int) -> void:
	_left_ms -= ms
	if _left_ms <= 0:
		_left_ms = 0
		_alpha = 0
		visible = false
		return
	var a := 255 if _left_ms > FADE_MS else _left_ms * 255 / FADE_MS
	if a != _alpha:
		_alpha = a
		queue_redraw()

## The instance's fill over the window's rect, then the frame pieces -- the
## corners at its corners, the edge along the top and bottom, edge2 down the
## sides -- and the text (the fill's colour and alpha and the texture names
## are READ; the fill's rect and the arrangement are INFERRED).
func _draw() -> void:
	var w := size.x
	var h := size.y
	# The fill first, then the frame (vslot 13: 0x654d10 then 0x81a450).
	var fill: Color = _style["fill"]
	fill.a = float(fill_alpha_for(_alpha)) / 255.0
	draw_rect(Rect2(0, 0, w, h), fill, true)
	var tint := Color(1, 1, 1, float(_alpha) / 255.0)
	var cw := minf(SIDE.x, w / 2.0)
	var ch := minf(SIDE.y, h / 2.0)
	if _edge != null and w > 2.0 * cw:
		draw_texture_rect(_edge, Rect2(cw, 0, w - 2.0 * cw, ch), true, tint)
		draw_texture_rect(_edge, Rect2(cw, h, w - 2.0 * cw, -ch), true, tint)
	if _edge2 != null and h > 2.0 * ch:
		draw_texture_rect(_edge2, Rect2(0, ch, cw, h - 2.0 * ch), false, tint)
		draw_texture_rect(_edge2, Rect2(w, ch, -cw, h - 2.0 * ch), false, tint)
	if _corner != null:
		draw_texture_rect(_corner, Rect2(0, 0, cw, ch), false, tint)
		draw_texture_rect(_corner, Rect2(w, 0, -cw, ch), false, tint)
		draw_texture_rect(_corner, Rect2(0, h, cw, -ch), false, tint)
		draw_texture_rect(_corner, Rect2(w, h, -cw, -ch), false, tint)
	if _font != null and _text != "":
		draw_string(_font, Vector2(0, _font.get_ascent(_font_size)), _text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			_font_size, Color(TEXT_COLOR, TEXT_COLOR.a * tint.a))
