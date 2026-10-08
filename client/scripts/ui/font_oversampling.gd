extends RefCounted
class_name FontOversampling

## Round 760: the text Godot 4.2.2 drew at a UI scale, on Godot 4.7.2.
##
## **What changed (READ, 4.2.2-stable and 4.7.2-stable).** 4.2.2 had ONE
## oversampling for every font, the window's content scale while its
## font-oversampling flag is on (Window::_update_viewport_size ->
## TS->font_set_global_oversampling; ClientSettings.apply_ui_scale). From 4.5
## it is per viewport, applied when a CanvasItem draws a glyph
## (TextServerAdvanced::_font_draw_glyph: the size key becomes
## `size x 64 x oversampling`). Two of our text paths read differently there:
##
## 1. **Emboldened faces were twice as heavy at UI scale 2.** FreeType's
##    embolden strength is `embolden x size` of the size KEY: 4.2.2 keyed by
##    the unscaled size (`embolden x p_size.x x 4`, 26.6 units, then rasterised
##    at size x oversampling), so on screen the stroke was strength /
##    oversampling; 4.7.2 keys by the oversampled size (`embolden x p_size.x /
##    16`, p_size.x = size x 64 x oversampling), so the stroke keeps its full
##    width. The tooltip's bold lines (embolden 1.4) and the chat's bold (0.6)
##    were 2x as wide at 2.0 (the user's 4.7.2 screenshot). So a face's
##    embolden is the 4.2.2 value divided by the UI's oversampling here.
## 2. **Label3D is never oversampled.** 4.2.2's global oversampling reached
##    the 3D labels too: their glyphs were rasterised at size x oversampling
##    and drawn with metrics / oversampling (TextServerAdvanced
##    `_ensure_cache_for_size`, `fd->oversampling`), so a plate at UI scale 2
##    was a 2x raster. 4.7.2's Label3D asks for glyph textures at the plain
##    size (no CanvasItem draw, so no viewport oversampling, and the font's
##    oversampling override is read only by the canvas draw), and a plate that
##    grows with the UI scale (the monster name boxes) was a 1x raster
##    magnified 2x -- the blocky, heavy names. So a Label3D is given 4.2.2's
##    raster itself: font_size and outline_size x oversampling, pixel_size /
##    oversampling (the same quad on screen; label3d()).
##
## The outlines need nothing: 4.2.2 stroked `outline x oversampling x 16` and
## 4.7.2 strokes `outline x oversampling x 16` too (the outline key is
## scaled). Below 4.5 nothing here changes anything (the engine still had the
## global oversampling).

## The UI's oversampling now (the main window's content scale), set by
## ClientSettings.apply_ui_scale.
static var ui := 1.0
## Every emboldened face made through bold(): [FontVariation, 4.2.2 embolden].
static var _bolds: Array = []

static func per_viewport() -> bool:
	return int(Engine.get_version_info().hex) >= 0x040500

## QA only: OPENSRO_QA_FONT_OVERSAMPLING=0 leaves 4.7.2's own text (the
## before of round 760's A/B).
static var _qa_off := OS.get_environment("OPENSRO_QA_FONT_OVERSAMPLING") == "0"

## The factor this engine needs to match 4.2.2 (1.0 before 4.5).
static func factor() -> float:
	return ui if per_viewport() and not _qa_off else 1.0

## An emboldened variation of `base` that looks as 4.2.2's `embolden` did at
## every UI scale.
static func bold(base: Font, embolden: float) -> FontVariation:
	var v := FontVariation.new()
	v.base_font = base
	v.variation_embolden = embolden / factor()
	_bolds.append([weakref(v), embolden])
	return v

## Gives a Label3D 4.2.2's oversampled raster: `font_size`, `outline_size`
## and `pixel_size` as 4.2.2 would have drawn them, stored on the label and
## applied x / / factor(). Call again whenever one of the three is set.
const META := &"font_oversampling_base"

static func label3d(label: Label3D, font_size: int, outline_size: int, pixel_size: float) -> void:
	label.set_meta(META, [font_size, outline_size, pixel_size])
	_apply_label(label)

static func label3d_pixel_size(label: Label3D, pixel_size: float) -> void:
	var base: Array = label.get_meta(META, [label.font_size, label.outline_size, pixel_size])
	base[2] = pixel_size
	label.set_meta(META, base)
	_apply_label(label)

static func _apply_label(label: Label3D) -> void:
	var base: Array = label.get_meta(META)
	var k := factor()
	label.font_size = maxi(1, roundi(float(base[0]) * k))
	label.outline_size = roundi(float(base[1]) * k)
	label.pixel_size = float(base[2]) / k

## A UI scale change: every face and every registered Label3D under `root`.
static func set_ui(scale: float, root: Node = null) -> void:
	ui = maxf(scale, 0.01)
	var keep: Array = []
	for e in _bolds:
		var v := (e[0] as WeakRef).get_ref() as FontVariation
		if v != null:
			v.variation_embolden = float(e[1]) / factor()
			keep.append(e)
	_bolds = keep
	if root != null:
		for n in root.find_children("*", "Label3D", true, false):
			if (n as Node).has_meta(META):
				_apply_label(n as Label3D)
