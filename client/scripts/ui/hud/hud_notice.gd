extends Control
class_name HudNotice

## A CIFNotify banner: GDR_NOTICE, the notice banner a GM notice raises
## besides its chat line (round 634; docs/protocol/chat.md), and
## GDR_WARNING_WND, the banner for the level-up line, the unique monster
## notices and some seventy other lines (rounds 639 and 657;
## docs/protocol/unique_notice.md). Round 703 rebuilt how it is drawn from
## CIFStretchWnd, its base class; docs/protocol/notice_banner.md has every
## address.
##
## Labels: READ = read from the binary or the data; MEASURED = counted from
## real files or reference pixels; INFERRED = follows from what was read but
## was not read itself; OURS = OpenSRO's choice.
##
## **Showing (READ, 0x7b3eb0).** 0x876810's type-7 branch calls 0x777bf0,
## which fetches the interface's child 0x14 -- ginterface.txt's GDR_NOTICE,
## a CIFNotify -- and hands it the text; 0x77b580 does the same for child
## 0x23, GDR_WARNING_WND. The show
##
##   - sets the life to 7000 ms (+0x7c8);
##   - sets the text on the GDR_NOTIFY_TXT static and measures it (0x8b2f20);
##   - places the window at x = W / 2 - w / 2 (two truncating halvings,
##     `cdq; sub; sar` at 0x7b3f0b..0x7b3f24), y = +0x7d4;
##   - sizes the window and the static to the text's extent;
##   - lays the stretch frame out around that rect (0x8185e0(w, h), then
##     0x8182e0(x, y, 1.0));
##   - shows it at alpha 255.
##
## A second show replaces the first at once -- text, life and alpha: there
## is no queue (READ: nothing in 0x7b3eb0 looks at the old state). The two
## instances are separate windows, so a GM notice (y 100) and a warning
## (y 130) are up together.
##
## **Fading (READ, 0x7b3e20).** The update counts the life down by the frame
## time and, while 2000 ms or less is left (`< 0x7d1`), sets the window's
## alpha to remaining * 255 / 2000; at 0 it hides the window and the text.
## The text fades with it: a child window's alpha is its own times its
## parent's / 255 (0x652670, READ).
##
## **The band (READ, CIFStretchWnd).** The class's render (vslot 13,
## 0x7b3cb0) draws, while shown (+0x7cc):
##
##   1. a quad over the window's rect (0x654d10) in the fill colour
##      (+0x7d8..+0x7da) with alpha byte `-0x80 - (0xff - a) / 2` for the
##      window alpha a -- 128 at full -- untextured (texture factor colour,
##      0x654d10's stage states);
##   2. the stretch frame (0x81a450 -> 0x819d80): eight textured quads laid
##      out by 0x8182e0 **outside** the window's rect --
##
##        corner TL  (x - cw, y - ch) .. (x, y)          corner texture
##        corner TR  (x + w, y - ch)  .. (x + w + cw, y)  mirrored in u
##        corner BR  (x + w, y + h)   .. (+cw, +ch)       mirrored in u and v
##        corner BL  (x - cw, y + h)  .. (x, y + h + ch)  mirrored in v
##        left       (x - lw, y) .. (x, y + h)            edge2
##        top        (x, y - th) .. (x + w, y)            edge
##        right      (x + w, y) .. (x + w + lw, y + h)    edge2 mirrored in u
##        bottom     (x, y + h) .. (x + w, y + h + th)    edge mirrored in v
##
##      each piece's size its own texture's (GetLevelDesc, 0x819690 /
##      0x8193d0 -> 0x818120.. / 0x818200..), the mirroring the UV modes
##      0x818a50(0) and 0x818d30(0) that vslot_010 sets. vslot_010 hands
##      0x819690 (edge2, edge, edge2, edge) for (left, top, right, bottom)
##      -- the strings built at 0x7b4069..0x7b40e2, last argument first --
##      and 0x8199e0 the one corner name for all four. The frame is drawn
##      point-sampled (sampler states 5/6 = 1, 0x819e14..0x819e5f) with its
##      texels' alpha times the window's (texture factor = a << 24).
##
## MEASURED (Media.pk2): every frame texture is one colour, its instance's
## fill -- com_notice_* (128, 45, 67), com_warning_* (0, 52, 92) -- in
## A8R8G8B8. The corner and edge2 are 40x8, the edge 4x8. edge2's alpha runs
## 0 -> 127 across its 40 columns; the edge's rows are 51, 89, then 128; the
## corner is both. So the band is the text's rect plus a 40-pixel fade on
## each side and an 8-pixel lip above and below whose outer two rows fade:
## (w + 80) x (h + 16). MEASURED on the reference picture of the original
## (2x scaled): the band runs 28.5 px tall over 12 px text, its top edge
## ramps over two rows, and it fades out past the text on both sides.
##
## **The text (READ).** ifnotify.txt's GDR_NOTIFY_TXT: FontColor
## (255,255,255,255), FontIndex 0 (12 px), HAlign 1. vslot_010 ORs text flag
## 2 into it (0x8b44b0(5, 2), pushes at 0x7b4136..0x7b413e), which selects
## the font's weight-600 variant (0x8b39e0 -> glyph mode 2; the variants are
## created in 0x00baa110: 1 italic, 2 weight 600, 3 underlined). Flag 1, the
## one-pixel drop shadow (0x8b48b0 -> 0x8b2290's fourth argument), is not
## set, so the notice text has no shadow. MEASURED on the reference: the
## glyph strokes are 2 px (bold) and the pixels right of and below them are
## the band's colour, not black.
##
## **What differs between the two instances** is set once, by CGInterface's
## setup (round 657, READ):
##
##   - y (+0x7d4, `0x7b3d40`): GDR_NOTICE 100 (`push 0x64` at 0x78cbbe),
##     GDR_WARNING_WND 130 (`push 0x82` at 0x78cbed);
##   - the frame: GDR_NOTICE keeps the class's `com_notice_*.ddj`;
##     GDR_WARNING_WND is given `com_warning_*.ddj` (0x78cc0d..0x78ccfb);
##   - the fill (+0x7d8..+0x7da, `0x7b3d10(r, g, b)`): GDR_NOTICE
##     (128, 45, 67) (0x78cbd2..0x78cbe8) -- the pink-red banner --
##     GDR_WARNING_WND (0, 52, 92) (0x78cd00..0x78cd12) -- the blue one.
##
## The layout's `Color=` lines (GDR_WARNING_WND's "255,119,119,251") are
## not read by the client (the resinfo parser 0x82c1d0 has no such field).

const UiBuilder = preload("res://scripts/ui/ui_builder.gd")

const LIFE_MS := 7000
const FADE_MS := 2000
const EDGE_DDJ := "interface\\ifcommon\\com_notice_edge.ddj"
const EDGE2_DDJ := "interface\\ifcommon\\com_notice_edge2.ddj"
const CORNER_DDJ := "interface\\ifcommon\\com_notice_corner.ddj"

## The two instances, as CGInterface's setup makes them (READ, see above).
## GDR_NOTICE, interface child 0x14: the GM notice -- the pink-red banner.
const STYLE_NOTICE := {
	"name": "GDR_NOTICE", "y": 100, "fill": Color(128.0 / 255.0, 45.0 / 255.0, 67.0 / 255.0),
	"edge": EDGE_DDJ, "edge2": EDGE2_DDJ, "corner": CORNER_DDJ,
}
## GDR_WARNING_WND, interface child 0x23: the level-up line, the unique
## notices and the rest -- the blue banner.
const STYLE_WARNING := {
	"name": "GDR_WARNING_WND", "y": 130, "fill": Color(0.0, 52.0 / 255.0, 92.0 / 255.0),
	"edge": "interface\\ifcommon\\com_warning_edge.ddj",
	"edge2": "interface\\ifcommon\\com_warning_edge2.ddj",
	"corner": "interface\\ifcommon\\com_warning_corner.ddj",
}

## Which instance a line goes to (READ: the callers of the two show paths);
## World3D._show_banner routes every banner it raises through it.
## 0x777bf0 (GDR_NOTICE) has four callers: the chat's notice type 7
## (0x876810), the guild-created result (UI_GUILD::Guild_OnCreateResult
## 0x8852c0), 0x887330 and the arena's 0x89f860. 0x77b580 (GDR_WARNING_WND)
## has about seventy: the level-up line (Client_ApplyExpAndLevelUp
## 0x8a97c0), the unique notices (0x874ea0, 15 sites), the recall point
## (0x77b580 from the rebirth-point result), the siege and training-camp
## results, the error-code dispatcher 0x7b8b40 and more.
const KIND_STYLES := {
	"gm_notice": "notice",
	"guild_created": "notice",
	"arena": "notice",
	"level_up": "warning",
	"unique": "warning",
	"recall_point": "warning",
	"system": "warning",
	# Round 785: a quest's progress line, GDR_UPDATE_QUEST_INFO.
	"quest_info": "quest",
	# Round 802: the safe trade's grant (UI_SAFETRADE c:0x891080 -> 0x77b580,
	# GDR_WARNING_WND).
	"safe_trade": "warning",
}

## The frame pieces' sizes when no texture is loaded (MEASURED from
## Media.pk2): corner and edge2 40x8, edge 4x8. With the textures loaded
## each piece takes its texture's own size, as 0x819690 does.
const CORNER_SIZE := Vector2(40, 8)
const EDGE_SIZE := Vector2(4, 8)
const EDGE2_SIZE := Vector2(40, 8)
## GDR_NOTIFY_TXT's FontColor (255,255,255,255) and FontIndex 0.
const TEXT_COLOR := Color.WHITE
## Text flag 2 (READ): the weight-600 face (bold_file / draw_bold).
const TEXT_BOLD := true
## Text flag 1, the drop shadow (READ): not set on the notice text.
const TEXT_SHADOW := false

var _font: Font
## The face's own bold file, or null for the synthetic bold (bold_file).
var _bold: Font
var _font_size := 12
var _edge: Texture2D
var _edge2: Texture2D
var _corner: Texture2D
var _text := ""
## The banner's text, drawn on its own unfiltered layer over the frame
## (UiBuilder.TextLayer, round 672).
var _text_layer: UiBuilder.TextLayer
var _left_ms := 0
var _style: Dictionary = STYLE_NOTICE
## The window's alpha, 0..255 (CIFWnd +0x12d): 255 while shown, then
## remaining * 255 / 2000 over the fade. The frame and the text are drawn at
## it and the fill at fill_alpha_for(it), so no modulate is used.
var _alpha := 255

func _init() -> void:
	_text_layer = UiBuilder.TextLayer.new(_draw_text)
	add_child(_text_layer)
	# The frame is point-sampled (0x819d80's sampler states, READ).
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

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
	_bold = bold_file(_font) if TEXT_BOLD else _font

## The style a line of `kind` (KIND_STYLES) is shown in; an unknown kind is
## a warning, the instance nearly every caller uses.
## GDR_UPDATE_QUEST_INFO (round 785), ginterface id 42, the third CIFNotify:
## a quest's progress line (READ: shown through 0x77b5b0 -> control 0x2a when
## an open mission's text changes on 0x30D5). Its y, fill and frame, which
## CGInterface's setup gives it, are NOT read: OURS -- the warning's frame and
## fill, at y 160 so it does not cover the warning band at 130.
const STYLE_QUEST_INFO := {
	"name": "GDR_UPDATE_QUEST_INFO", "y": 160, "fill": Color(0.0, 52.0 / 255.0, 92.0 / 255.0),
	"edge": "interface\\ifcommon\\com_warning_edge.ddj",
	"edge2": "interface\\ifcommon\\com_warning_edge2.ddj",
	"corner": "interface\\ifcommon\\com_warning_corner.ddj",
}

static func style_for_kind(kind: String) -> Dictionary:
	var style := String(KIND_STYLES.get(kind, "warning"))
	if style == "quest":
		return STYLE_QUEST_INFO
	return STYLE_NOTICE if style == "notice" else STYLE_WARNING

## The instance's layout name (GDR_NOTICE / GDR_WARNING_WND).
func style_name() -> String:
	return String(_style["name"])

## The fill colour, opaque (the alpha is fill_alpha_for's).
func fill_color() -> Color:
	return _style["fill"]

## The UI face the text is drawn in (text flag 2 makes it the weight-600
## variant: the face's bold file when there is one, bold_file).
func text_font() -> Font:
	return _font

## The bold file in use, or null when the synthetic bold is drawn.
func text_bold_file() -> Font:
	return _bold

## How wide `s` is in the notice's bold text.
func text_width(s: String) -> float:
	return bold_width(_font, _bold, s, _font_size)

func text_size() -> int:
	return _font_size

## The fill quad's alpha byte for the window alpha `a` (0x7b3cb0:
## `-0x80 - (0xff - a) / 2`, kept to its low byte): 128 at 255, 1 at 0.
static func fill_alpha_for(a: int) -> int:
	return (-0x80 - (0xff - a) / 2) & 0xff

## The window's current alpha, 0..255.
func alpha() -> int:
	return _alpha

## x of a window `text_w` wide on a screen `screen_w` wide: the two
## truncating halvings of 0x7b3f0b..0x7b3f24.
static func window_x(screen_w: int, text_w: int) -> int:
	return screen_w / 2 - text_w / 2

## Shows `text` for LIFE_MS (0x7b3eb0): the window is the text's extent,
## centred, at the instance's y.
func show_notice(text: String) -> void:
	_text = text
	_left_ms = LIFE_MS
	var face: Font = _bold if _bold != null else _font
	var extent := Vector2(bold_width(_font, _bold, text, _font_size), face.get_height(_font_size)).ceil()
	size = extent
	position = Vector2(float(window_x(int(_screen_width()), int(extent.x))), float(_style["y"]))
	_alpha = 255
	visible = true
	queue_redraw()
	_text_layer.queue_redraw()

## The width the client centres on: the UI root's (the screen's, at UI scale
## 1).
func _screen_width() -> float:
	if not is_inside_tree():
		return 1024.0
	var parent := get_parent() as Control
	if parent != null and parent.size.x > 0.0:
		return parent.size.x
	return get_viewport_rect().size.x

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
		_text_layer.queue_redraw()

## The pieces' sizes as 0x819690 / 0x8193d0 take them: each texture's own,
## or the measured sizes without one.
func _corner_size() -> Vector2:
	return _corner.get_size() if _corner != null else CORNER_SIZE

func _edge_size() -> Vector2:
	return _edge.get_size() if _edge != null else EDGE_SIZE

func _edge2_size() -> Vector2:
	return _edge2.get_size() if _edge2 != null else EDGE2_SIZE

## The stretch frame around a w x h window, window-local (0x8182e0 with the
## UV modes 0x818a50(0) / 0x818d30(0)): one entry per quad, in the order
## 0x819d80 draws them -- {piece: "corner" | "edge" | "edge2", rect, flip_h,
## flip_v}. Every piece lies outside the window's rect.
static func frame_pieces(w: float, h: float, corner: Vector2 = CORNER_SIZE, edge: Vector2 = EDGE_SIZE,
		edge2: Vector2 = EDGE2_SIZE) -> Array:
	return [
		{"piece": "corner", "rect": Rect2(-corner.x, -corner.y, corner.x, corner.y), "flip_h": false, "flip_v": false},
		{"piece": "corner", "rect": Rect2(w, -corner.y, corner.x, corner.y), "flip_h": true, "flip_v": false},
		{"piece": "corner", "rect": Rect2(w, h, corner.x, corner.y), "flip_h": true, "flip_v": true},
		{"piece": "corner", "rect": Rect2(-corner.x, h, corner.x, corner.y), "flip_h": false, "flip_v": true},
		{"piece": "edge2", "rect": Rect2(-edge2.x, 0, edge2.x, h), "flip_h": false, "flip_v": false},
		{"piece": "edge", "rect": Rect2(0, -edge.y, w, edge.y), "flip_h": false, "flip_v": false},
		{"piece": "edge2", "rect": Rect2(w, 0, edge2.x, h), "flip_h": true, "flip_v": false},
		{"piece": "edge", "rect": Rect2(0, h, w, edge.y), "flip_h": false, "flip_v": true},
	]

## The whole band, window-local: the window's rect and the frame around it.
func band_rect() -> Rect2:
	var c := _corner_size()
	return Rect2(-c.x, -c.y, size.x + 2.0 * c.x, size.y + 2.0 * c.y)

## The band on screen, in the canvas's pixels (for the QA log).
func band_screen_rect() -> Rect2:
	var xf := get_global_transform_with_canvas()
	var b := band_rect()
	return Rect2(xf * b.position, b.size * xf.get_scale())

## The fill over the window's rect, then the eight frame pieces around it,
## then the text (vslot 13: 0x654d10, then 0x81a450).
func _draw() -> void:
	var w := size.x
	var h := size.y
	var fill: Color = _style["fill"]
	fill.a = float(fill_alpha_for(_alpha)) / 255.0
	draw_rect(Rect2(0, 0, w, h), fill, true)
	var tint := Color(1, 1, 1, float(_alpha) / 255.0)
	var textures := {"corner": _corner, "edge": _edge, "edge2": _edge2}
	for p in frame_pieces(w, h, _corner_size(), _edge_size(), _edge2_size()):
		var tex: Texture2D = textures[p["piece"]]
		if tex != null:
			_blit(tex, p["rect"], bool(p["flip_h"]), bool(p["flip_v"]), tint)

## Draws `tex` over `r`, mirrored as asked. Mirrored through the transform,
## not a negative rect size: draw_texture_rect flips a negative-sized rect's
## texture but keeps its position as the left/top edge (Godot 4.2,
## RendererCanvasCull::canvas_item_add_texture_rect), so `Rect2(w, 0, -cw,
## ch)` lands at w .. w + cw, not w - cw .. w -- round 634's banner put its
## right and bottom pieces a piece's width out that way (round 703).
func _blit(tex: Texture2D, r: Rect2, flip_h: bool, flip_v: bool, tint: Color) -> void:
	var origin := Vector2(r.position.x + (r.size.x if flip_h else 0.0), r.position.y + (r.size.y if flip_v else 0.0))
	draw_set_transform(origin, 0.0, Vector2(-1.0 if flip_h else 1.0, -1.0 if flip_v else 1.0))
	draw_texture_rect(tex, Rect2(Vector2.ZERO, r.size), false, tint)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_text(on: CanvasItem) -> void:
	if _font == null or _text == "":
		return
	var c := Color(TEXT_COLOR, TEXT_COLOR.a * float(_alpha) / 255.0)
	var face: Font = _bold if _bold != null else _font
	var at := Vector2(0, face.get_ascent(_font_size))
	if TEXT_SHADOW:
		draw_bold(on, _font, _bold, at + Vector2.ONE, _text, _font_size, Color(0, 0, 0, c.a))
	draw_bold(on, _font, _bold, at, _text, _font_size, c)

# --- The weight-600 face (text flag 2) ---------------------------------------
#
# READ: 0x00baa110 creates the variant with CreateFontIndirectA, lfWeight
# 600, from the same face name (UIC_STT_FONTNAME: Arial at 9 pt, 12 px), and
# GFontChar 0x8b0a00 rasterises its glyphs one bit deep (GetGlyphOutlineW,
# GGO_BITMAP). GDI picks the face's own bold file when the system has one
# (arialbd.ttf on Windows and macOS); so does bold_file. Without one GDI
# emboldens the outline itself: each glyph smeared one pixel to the right and
# its advance one pixel wider -- what draw_bold does then (OURS as code; GDI's
# simulation, round 703's review M1). MEASURED against the reference
# (notice_gZ0D3bn.png, 2x nearest of the 1-bit text): verticals 2 px,
# horizontals 1 px, x-height 7 -- FreeType's embolden, round 703's first
# stand-in, thickened the horizontals to 2 px and the x-height to 8.

## The cache of bold files, by base font ("" for none).
static var _bold_cache := {}

## The face's weight-600 file from the system, or null when there is none
## (the synthetic bold is drawn then).
static func bold_file(font: Font) -> Font:
	if font == null:
		return null
	var key := font.get_instance_id()
	if not _bold_cache.has(key):
		_bold_cache[key] = _system_bold(font)
	return _bold_cache[key]

## `s`'s width in the weight-600 text: the bold file's, or the face's
## advances each one pixel wider.
static func bold_width(font: Font, bold: Font, s: String, px: int) -> float:
	if bold != null:
		return bold.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
	if font == null:
		return 0.0
	var w := 0.0
	for ch in s:
		w += font.get_char_size(ch.unicode_at(0), px).x + 1.0
	return w

## Draws `s` in the weight-600 text with its baseline at `at`: the bold
## file's glyphs, or each of the face's glyphs drawn at x and x + 1 with the
## advance one pixel wider.
static func draw_bold(on: CanvasItem, font: Font, bold: Font, at: Vector2, s: String, px: int, color: Color) -> void:
	if bold != null:
		on.draw_string(bold, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, px, color)
		return
	if font == null:
		return
	var x := at.x
	for ch in s:
		on.draw_char(font, Vector2(x, at.y), ch, px, color)
		on.draw_char(font, Vector2(x + 1.0, at.y), ch, px, color)
		x += font.get_char_size(ch.unicode_at(0), px).x + 1.0

static func _system_bold(font: Font) -> Font:
	var family := font.get_font_name()
	if family == "" or not (font is FontFile) or font.get_font_weight() >= 600:
		return null
	var path := OS.get_system_font_path(family, 600)
	if path == "" or not FileAccess.file_exists(path):
		return null
	var bold := FontFile.new()
	bold.data = FileAccess.get_file_as_bytes(path)
	if bold.get_face_count() == 0 or bold.get_font_name().to_lower() != family.to_lower() \
			or bold.get_font_weight() < 600:
		return null
	var ff := font as FontFile
	bold.antialiasing = ff.antialiasing
	bold.hinting = ff.hinting
	bold.force_autohinter = ff.force_autohinter
	bold.subpixel_positioning = ff.subpixel_positioning
	return bold
