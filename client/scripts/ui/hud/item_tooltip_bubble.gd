extends Control
class_name ItemTooltipBubble

## The item tooltip window, CNIFHelperBubbleWindow (round 731;
## docs/protocol/item_tooltip.md §1). It replaces Godot's `tooltip_text` for
## every item: that popup is its own sub-window, drawn in Godot's default face
## at 1x and magnified by the UI scale, so at the user's DPI 2.0 it was blurry,
## grey and frameless. This one is a Control in the HUD's own canvas, its text
## in the client's face at FontIndex 0's 12 px through round 672's crisp path,
## so a glyph pixel is whole at every UI scale.
##
## Geometry, each with its source:
##   - the frame: com_tooltip_corner.ddj (8x8, the TOP-LEFT corner) and
##     com_tooltip_edge.ddj (8x4, the LEFT edge, outside in: black, light
##     blue, navy, two dark lines, fill), all eight border widths 8 (READ,
##     0x496b0f..0x496bc4; the orientation MEASURED from the decoded texels:
##     the corner's transparent pixels are its top-left);
##   - the lines: 18 px apart, 14 when the box holds one line (READ, 0x496c90,
##     `+0x374 = (lines != 1) * 4 + 14`); the width the widest line's (READ);
##   - the text's pen at the frame's inner edge, 8 px in, its cap top 3 px
##     below the line's top (MEASURED in XjjJyA5.png: the outer black column
##     at x 346, the first glyph column at 355 after a 1-px bearing, the
##     name's cap top at 239 for the box's top at 228); so its baseline is 12
##     px below the line's top (cap top 3 + a 9-row cap), and each label is
##     placed by that baseline -- line_top + 12 - the face's ascent -- so
##     any face the client loads (Tahoma, or the disclosed Arial fallback a
##     Linux client gets) sits where the original's text sits;
##   - the name icon, com_itemsign.ddj (GDR_ITEMNAME_L, 12x12), at the name
##     line's start; the name is padded with spaces past it (READ, 0x776d20:
##     it adds ceil(12 / space) + 1 spaces -- 16 px at 12 px, MEASURED: the
##     name's first glyph at x 370 = 354 + 16);
##   - every text pixel has a black drop shadow one pixel right and down
##     (MEASURED: #010101 under and right of every glyph pixel, at text
##     colours drawn exact -- the text is opaque);
##   - the frame and fill drawn at alpha 200/255 (MEASURED: 0.77-0.78 from
##     three texels over known ground -- the fill over the screen's black
##     #010101 rows reads #131931 = 0.78 x (24,32,65); the light-blue and
##     black edge columns over #292929 read 0.78. The byte at +0x131 that
##     holds it is not read: the 200 is the measured ratio, INFERRED as a
##     byte);
##   - font 3 (name, seal, set, advanced elixir) is the same face emboldened:
##     the same 9-row cap height with 2-px stems against 1-px (MEASURED); the
##     client's own bold face (weight 600) is not loaded here, so it is drawn
##     with FontVariation's embolden (OURS, measured to give 2-px stems).
##
## OURS: the placement (right of the hovered slot, top aligned with it --
## MEASURED in the one screenshot, x 346 after a slot ending at 345, y 228 for
## a slot top of 229 -- and kept on screen), and the frame's NEAREST filter so
## its 1-px lines stay whole at UI scale 2.0.

const CORNER_DDJ := "interface\\ifcommon\\com_tooltip_corner.ddj"
const EDGE_DDJ := "interface\\ifcommon\\com_tooltip_edge.ddj"
const ITEM_SIGN_DDJ := "interface\\ifcommon\\com_itemsign.ddj"
const FRAME := 8
const LINE_HEIGHT := 18
const LINE_HEIGHT_SINGLE := 14
const ICON_SIZE := 12
## The text's baseline below its line's top (MEASURED, see above).
const BASELINE := 12
const WINDOW_ALPHA := 200.0 / 255.0
## The fill where no texture is available (a test without an archive): the
## edge's own fill texel, A1R5G5B5 (3, 4, 8) (MEASURED).
const FILL_FALLBACK := Color8(24, 32, 65)
const SHADOW := Color(0, 0, 0)
## FontVariation embolden for font 3: FreeType widens each glyph by
## embolden x size x 4 / 64 px (READ, TextServerAdvanced::_ensure_glyph), so
## 1.4 at 12 px is 1.05 px -- one more pixel of stem (OURS).
const BOLD_EMBOLDEN := 1.4

var _builder: UiBuilder
var _font: Font
var _bold: Font
var _size := UiBuilder.FONT_SIZES[0]
var _tex := {}
var _fill := FILL_FALLBACK
var _lines: Array = []
var _labels: Array[Label] = []
var _icon: TextureRect
var _line_height := LINE_HEIGHT
## The control the bubble describes; it closes when that one leaves the screen.
var source: Control = null

func _init(builder: UiBuilder = null) -> void:
	name = "ItemTooltipBubble"
	_builder = builder
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_level = true
	z_index = 4000
	z_as_relative = false
	visible = false
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	self_modulate = Color(1, 1, 1, WINDOW_ALPHA)
	_font = builder.font_at(0) if builder != null else null
	if _font == null:
		_font = ThemeDB.fallback_font
	var v := FontVariation.new()
	v.base_font = _font
	v.variation_embolden = BOLD_EMBOLDEN
	_bold = v
	_load_frame()
	_icon = TextureRect.new()
	_icon.name = "ItemSign"
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP
	_icon.texture = builder.load_texture(ITEM_SIGN_DDJ) if builder != null else null
	_icon.visible = false
	add_child(_icon)

func _load_frame() -> void:
	if _builder == null:
		return
	var corner := _builder.load_image(CORNER_DDJ)
	var edge := _builder.load_image(EDGE_DDJ)
	if corner == null or edge == null:
		return
	_fill = edge.get_pixel(edge.get_width() - 1, 0)
	_tex["tl"] = ImageTexture.create_from_image(corner)
	var c := corner.duplicate() as Image
	c.flip_x()
	_tex["tr"] = ImageTexture.create_from_image(c)
	c = corner.duplicate() as Image
	c.flip_y()
	_tex["bl"] = ImageTexture.create_from_image(c)
	c.flip_x()
	_tex["br"] = ImageTexture.create_from_image(c)
	_tex["l"] = ImageTexture.create_from_image(edge)
	var e := edge.duplicate() as Image
	e.flip_x()
	_tex["r"] = ImageTexture.create_from_image(e)
	# The top: the left edge turned so its outside (column 0) is row 0.
	var t := edge.duplicate() as Image
	t.rotate_90(CLOCKWISE)
	_tex["t"] = ImageTexture.create_from_image(t)
	var b := t.duplicate() as Image
	b.flip_y()
	_tex["b"] = ImageTexture.create_from_image(b)

## The pixel width of a line's text in its face.
func text_width(line: Dictionary) -> float:
	var f: Font = _bold if line.get("bold", false) else _font
	return f.get_string_size(String(line["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1, _size).x

## The name's indent: ceil(icon / space) + 1 spaces (READ, 0x776d20).
func icon_indent() -> float:
	var sp := _font.get_string_size(" ", HORIZONTAL_ALIGNMENT_LEFT, -1, _size).x
	if sp <= 0.0:
		return ICON_SIZE + 4.0
	return (ceilf(ICON_SIZE / sp) + 1.0) * sp

## Shows `lines` (ItemTooltipLines.compose) beside `anchor`, a rect in this
## canvas's coordinates (the hovered slot's), for `from`.
func show_lines(lines: Array, anchor: Rect2, from: Control = null) -> void:
	_lines = lines
	source = from
	if lines.is_empty():
		hide_bubble()
		return
	_line_height = LINE_HEIGHT if lines.size() != 1 else LINE_HEIGHT_SINGLE
	var width := 0.0
	for i in lines.size():
		var l: Dictionary = lines[i]
		var w := text_width(l) + (icon_indent() if l.get("icon", false) else 0.0)
		width = maxf(width, w)
		var label: Label
		if i < _labels.size():
			label = _labels[i]
		else:
			label = Label.new()
			label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
			label.add_theme_color_override("font_shadow_color", SHADOW)
			label.add_theme_constant_override("shadow_offset_x", 1)
			label.add_theme_constant_override("shadow_offset_y", 1)
			label.add_theme_constant_override("shadow_outline_size", 0)
			label.add_theme_font_size_override("font_size", _size)
			label.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
			UiBuilder.crisp_text(label)
			add_child(label)
			_labels.append(label)
		label.visible = true
		label.text = String(l["text"])
		label.add_theme_font_override("font", _bold if l.get("bold", false) else _font)
		label.add_theme_color_override("font_color", l["color"])
		var x := FRAME + (icon_indent() if l.get("icon", false) else 0.0)
		var face: Font = _bold if l.get("bold", false) else _font
		label.position = Vector2(x, FRAME + i * _line_height + BASELINE - roundf(face.get_ascent(_size)))
		label.size = Vector2(maxf(text_width(l), 1.0) + 2.0, _line_height)
		if l.get("icon", false):
			_icon.visible = _icon.texture != null
			_icon.position = Vector2(FRAME, FRAME + i * _line_height)
			_icon.size = Vector2(ICON_SIZE, ICON_SIZE)
	for j in range(lines.size(), _labels.size()):
		_labels[j].visible = false
	if not lines.any(func(l): return l.get("icon", false)):
		_icon.visible = false
	size = Vector2(ceilf(width) + FRAME * 2, lines.size() * _line_height + FRAME * 2)
	position = place(anchor, size, _view_rect())
	visible = true
	queue_redraw()

func hide_bubble() -> void:
	visible = false
	source = null

## A slot hidden or freed under the mouse sends no mouse_exited in 4.2, so
## the bubble checks its source itself.
func _process(_delta: float) -> void:
	if visible and source != null and (not is_instance_valid(source) or not source.is_visible_in_tree()):
		hide_bubble()

## The lines on show, for tests and logs.
func shown_lines() -> Array:
	return _lines if visible else []

func _view_rect() -> Rect2:
	if is_inside_tree():
		return get_viewport_rect()
	return Rect2(0, 0, 1e6, 1e6)

## Right of the anchor, top aligned (MEASURED); flipped left of it when it
## would leave the screen on the right and moved up when it would leave it
## at the bottom (OURS).
static func place(anchor: Rect2, box: Vector2, view: Rect2) -> Vector2:
	var p := Vector2(anchor.end.x, anchor.position.y)
	if p.x + box.x > view.end.x:
		p.x = anchor.position.x - box.x
	if p.y + box.y > view.end.y:
		p.y = view.end.y - box.y
	p.x = maxf(p.x, view.position.x)
	p.y = maxf(p.y, view.position.y)
	return p.round()

func _draw() -> void:
	var w := size.x
	var h := size.y
	if _tex.is_empty():
		draw_rect(Rect2(Vector2.ZERO, size), _fill)
		return
	draw_rect(Rect2(FRAME, FRAME, w - FRAME * 2, h - FRAME * 2), _fill)
	draw_texture(_tex["tl"], Vector2.ZERO)
	draw_texture(_tex["tr"], Vector2(w - FRAME, 0))
	draw_texture(_tex["bl"], Vector2(0, h - FRAME))
	draw_texture(_tex["br"], Vector2(w - FRAME, h - FRAME))
	draw_texture_rect(_tex["l"], Rect2(0, FRAME, FRAME, h - FRAME * 2), true)
	draw_texture_rect(_tex["r"], Rect2(w - FRAME, FRAME, FRAME, h - FRAME * 2), true)
	draw_texture_rect(_tex["t"], Rect2(FRAME, 0, w - FRAME * 2, FRAME), true)
	draw_texture_rect(_tex["b"], Rect2(FRAME, h - FRAME, w - FRAME * 2, FRAME), true)
