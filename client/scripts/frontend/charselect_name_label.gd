extends RefCounted
class_name CharSelectNameLabel

## A character's name over its model (round 848, lane R). READ, the select
## screen's own text item (SCharacterInfo +0x2dc, made by FUN_008b4f30 at
## 0x85a4c0): FUN_0085a580 sets font 4 (0x85a596..0x85a5a6) and then the
## name through FUN_008b3bd0 (0x85a5b4), which for any non-empty text sets
## font 0 again and the box colour 0x40000000 (0x8b3bde..0x8b3bf8) -- so the
## name is drawn in font 0 (12 px), not 4, on the world plates' box. Its
## colour is the item's constructor's 0xffffffff (FUN_008b46d0, 0x8b46d9..
## 0x8b4704; nothing calls 0x8b2b70 on +0x2dc: its only uses are 0x85a4b5,
## 0x85a50a, 0x85a598 and 0x85ab66) and its style flags 0 (0x8b472b): white,
## no shadow, no outline, normal weight. vslot_013 (0x85ab2b..0x85ab6c) draws
## it through FUN_008b4d90(point, alpha byte +0x2be) only while that byte is
## not 0: the item centred on the projected point (0x8b4e6c..0x8b4e99:
## x - w / 2, y - h / 2, h = 14) and FUN_008b48b0's box 1 px round it in
## the texture factor, black at 64/255 -- the fade's alpha goes to the
## glyphs only (0x8b4909..0x8b490e: colour & 0xffffff | alpha << 24), the box keeps
## its 64. The box's size and place are the world's (NamePlates: 16 rows,
## the cell's top 1 row under it, 2 px either side, MEASURED round 673).
## Before: font 4 (20 px) with a black outline 3 (no source), Godot's white,
## its bottom on the point (INFERRED) and no box.
const NAME_COLOUR := Color(1.0, 1.0, 1.0, 1.0)
## The text item's height (READ above): line gap 5 + font 0's 9 points.
const NAME_ITEM_H := 14
## The box under a name (NamePlates.BOX_COLOUR, READ 0x40000000).
const NAME_BOX_META := &"name_box"

static func make() -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	l.add_theme_color_override("font_color", NAME_COLOUR)
	l.add_theme_constant_override("outline_size", 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	l.clip_text = false
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiBuilder.crisp_text(l)
	# The fade is the glyphs' alpha (self_modulate), so the box under them
	# keeps its own.
	l.self_modulate.a = 0.0
	var box := ColorRect.new()
	box.name = "Box"
	box.color = NamePlates.BOX_COLOUR
	box.show_behind_parent = true
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.visible = false
	l.add_child(box)
	l.set_meta(NAME_BOX_META, box)
	return l

## Lays a name label on its projected point (READ, make): the text
## item's top-left at (trunc(x - w / 2), trunc(y - 7)) with w the text's
## advance, the glyph cell from that top (the baseline the face's cell
## ascent below it, NamePlates.cell_ascent), and the box 16 rows from one
## row above the cell, 2 px either side of the text.
static func place(l: Label, at: Vector2) -> void:
	var font := l.get_theme_font(&"font")
	var px := l.get_theme_font_size(&"font_size")
	var w := ceilf(font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x) if font != null else 0.0
	var item := Vector2(float(int(at.x - float(int(w) >> 1))), float(int(at.y - float(NAME_ITEM_H >> 1))))
	var ascent := NamePlates.cell_ascent(font, px) if font != null else 0.0
	var godot_ascent := font.get_ascent(px) if font != null else 0.0
	l.position = Vector2(item.x, item.y + ascent - godot_ascent)
	l.size = Vector2(w, 0)
	var box := (l.get_meta(NAME_BOX_META) if l.has_meta(NAME_BOX_META) else null) as ColorRect
	if box != null:
		var top := item.y - NamePlates.BOX_OVER_CELL_PX
		box.position = Vector2(-NamePlates.BOX_PAD_PX, top - l.position.y)
		box.size = Vector2(w + 2.0 * NamePlates.BOX_PAD_PX, NamePlates.BOX_HEIGHT_PX)

## The name's fade (its glyphs' alpha byte); the box shows while it is not 0.
static func set_alpha(l: Label, a: float) -> void:
	l.self_modulate.a = a
	var box := (l.get_meta(NAME_BOX_META) if l.has_meta(NAME_BOX_META) else null) as ColorRect
	if box != null:
		box.visible = a > 0.0
