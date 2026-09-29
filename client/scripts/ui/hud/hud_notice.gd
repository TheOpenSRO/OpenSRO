extends Control
class_name HudNotice

## GDR_NOTICE, the notice banner a GM notice raises besides its chat line
## (round 634; docs/protocol/chat.md).
##
## READ: 0x876810's type-7 branch calls 0x777bf0, which fetches the
## interface's child 0x14 -- ginterface.txt's GDR_NOTICE, a CIFNotify -- and
## hands it the text (0x7b3eb0). That function
##
##   - sets the banner's life to 7000 ms (+0x7c8 = 7000);
##   - sets the text, measures it (0x8b2f20) and sizes the window and its text
##     to the extent;
##   - places it at x = screen width / 2 - text width / 2, y = +0x7d4, which
##     the constructor (0x7b3c40) sets to 0 and nothing in the dump changes
##     for this class -- the top of the screen;
##   - shows it at alpha 255.
##
## Its update (0x7b3e20) counts the life down and, over the last 2000 ms
## (0x7d0), sets the alpha to remaining * 255 / 2000; at 0 it hides.
##
## The frame is CIFNotify's CIFStretchWnd base built from
## `com_notice_edge.ddj`, `com_notice_edge2.ddj` and `com_notice_corner.ddj`
## (0x7b3fe0). READ: those three names; MEASURED: all three are the one
## translucent maroon (128, 45, 67) -- the corner fading in both directions,
## edge2 (40x8) across, edge (4x8) down to alpha 128. INFERRED: laid out as a
## stretch frame, corners at the corners, edge2 on the sides, edge along the
## top and bottom, alpha-128 maroon inside, the pieces around the text's
## rect (how 0x8185e0 / 0x8182e0 size the frame was not read).

const UiBuilder = preload("res://scripts/ui/ui_builder.gd")

const LIFE_MS := 7000
const FADE_MS := 2000
const EDGE_DDJ := "interface\\ifcommon\\com_notice_edge.ddj"
const EDGE2_DDJ := "interface\\ifcommon\\com_notice_edge2.ddj"
const CORNER_DDJ := "interface\\ifcommon\\com_notice_corner.ddj"
## The pieces' size: the corner and edge2 are 40x8, the edge 4x8.
const SIDE := Vector2(40, 8)
## The fill inside the frame (MEASURED: the edge's full-alpha rows).
const FILL := Color8(128, 45, 67, 128)
## GDR_NOTICE's FontColor (255,255,255,255) and FontIndex 0.
const TEXT_COLOR := Color.WHITE

var _font: Font
var _font_size := 12
var _edge: Texture2D
var _edge2: Texture2D
var _corner: Texture2D
var _text := ""
var _left_ms := 0

func setup(builder: UiBuilder) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	if builder != null:
		_font = builder.font_at(0)
		_font_size = UiBuilder.FONT_SIZES[0]
		_edge = builder.load_texture(EDGE_DDJ)
		_edge2 = builder.load_texture(EDGE2_DDJ)
		_corner = builder.load_texture(CORNER_DDJ)
	if _font == null:
		_font = ThemeDB.fallback_font

## Shows `text` for LIFE_MS (0x7b3eb0).
func show_notice(text: String) -> void:
	_text = text
	_left_ms = LIFE_MS
	var extent := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size)
	extent.y = _font.get_height(_font_size)
	var screen_w := get_viewport_rect().size.x if is_inside_tree() else 1024.0
	size = extent + SIDE * 2.0
	position = Vector2(floor(screen_w / 2.0 - extent.x / 2.0) - SIDE.x, 0)
	modulate.a = 1.0
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
		visible = false
		return
	modulate.a = alpha_for(_left_ms)

func _draw() -> void:
	var inner := Rect2(SIDE, size - SIDE * 2.0)
	draw_rect(inner, FILL)
	var w := size.x
	var h := size.y
	if _edge != null:
		# Top and bottom: the edge tiled across, the bottom one flipped.
		draw_texture_rect(_edge, Rect2(SIDE.x, 0, inner.size.x, SIDE.y), true)
		draw_texture_rect(_edge, Rect2(SIDE.x, h, inner.size.x, -SIDE.y), true)
	if _edge2 != null:
		# The sides: edge2 stretched down, the right one mirrored.
		draw_texture_rect(_edge2, Rect2(0, SIDE.y, SIDE.x, inner.size.y), false)
		draw_texture_rect(_edge2, Rect2(w, SIDE.y, -SIDE.x, inner.size.y), false)
	if _corner != null:
		draw_texture_rect(_corner, Rect2(0, 0, SIDE.x, SIDE.y), false)
		draw_texture_rect(_corner, Rect2(w, 0, -SIDE.x, SIDE.y), false)
		draw_texture_rect(_corner, Rect2(0, h, SIDE.x, -SIDE.y), false)
		draw_texture_rect(_corner, Rect2(w, h, -SIDE.x, -SIDE.y), false)
	if _font != null and _text != "":
		var at := Vector2(SIDE.x, SIDE.y + _font.get_ascent(_font_size))
		draw_string(_font, at, _text, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, TEXT_COLOR)
