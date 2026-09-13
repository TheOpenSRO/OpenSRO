class_name FrontEndUi
extends RefCounted

## Shared helpers for the front-end screens (login, character select, race
## select, character customize): opening the player's Media.pk2, loading its
## real art at runtime (never shipped), and the gold-on-dark styling those
## screens share. The look is a disclosed design choice, not recovered art;
## the frame/backdrop textures themselves are the client's own. See
## docs/FRONTEND.md.

const DdjReader = preload("res://scripts/ddj/ddj_reader.gd")

const GOLD := Color(0.95, 0.88, 0.62)
const GOLD_EDGE := Color(0.66, 0.54, 0.26)
const GOLD_EDGE_BRIGHT := Color(0.85, 0.70, 0.34)

## Opens the player's Media.pk2, or null when none is configured (a dev run
## without game data -- the screens then fall back to plain panels).
static func open_media() -> Pk2Reader:
	var path := Pk2Config.media_path()
	if path == "":
		return null
	return Pk2Reader.open(path)

## Decodes one .ddj out of an open Media.pk2 into a texture, or null.
static func load_ddj(media: Pk2Reader, ddj_path: String) -> Texture2D:
	if media == null:
		return null
	var entry := ObjectLoader.find_file(media, ddj_path)
	if entry == null:
		return null
	var parsed := DdjReader.parse(media.read_file(entry))
	if parsed == null:
		return null
	return DdjReader.to_texture(parsed)

## A full-rect backdrop TextureRect for a .ddj, or null if the art is
## missing. Covers the screen keeping aspect, and ignores the mouse.
static func backdrop(media: Pk2Reader, ddj_path: String) -> TextureRect:
	var tex := load_ddj(media, ddj_path)
	if tex == null:
		return null
	var bg := TextureRect.new()
	bg.texture = tex
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return bg

## A dark radial vignette laid over the backdrop, so the panels pop and a
## letterboxed backdrop's black bands read as intentional framing rather than
## an accident. Ignores the mouse.
static func vignette() -> TextureRect:
	var grad := Gradient.new()
	grad.set_color(0, Color(0, 0, 0, 0))
	grad.set_color(1, Color(0, 0, 0, 0.62))
	grad.add_point(0.55, Color(0, 0, 0, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 1.05)
	tex.width = 320
	tex.height = 240
	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr

## Applies the client's own UI font (fonts\*.ttf in the player's Media.pk2, the
## same face the in-game HUD uses via UiBuilder) as the root's default font, so
## the front-end reads in the game's own type rather than Godot's default. Sets
## it through a Theme on the root, which every child inherits unless it overrides
## its own font. No-ops without an archive/font -- Godot's default stays then.
static func apply_client_font(root: Control, media: Pk2Reader) -> void:
	if root == null or media == null:
		return
	var font := UiBuilder.new(media, null).font_at(0)
	if font == null:
		return
	var theme := root.theme if root.theme != null else Theme.new()
	theme.default_font = font
	root.theme = theme

## A dark ground so a missing backdrop is black, not the host theme.
static func ground(colour: Color = Color(0.03, 0.03, 0.04)) -> ColorRect:
	var g := ColorRect.new()
	g.color = colour
	g.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return g

## The dark, gold-edged plate the panels sit on.
static func plate_style(bg: Color = Color(0.07, 0.07, 0.09, 0.92), border: Color = GOLD_EDGE) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(2)
	s.set_corner_radius_all(8)
	s.set_content_margin_all(12)
	return s

static func plate(bg: Color = Color(0.07, 0.07, 0.09, 0.92), border: Color = GOLD_EDGE) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", plate_style(bg, border))
	return p

static func _button_style(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(2)
	s.set_corner_radius_all(4)
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 7
	s.content_margin_bottom = 7
	return s

## A dark plate button with a gold edge and gold text.
static func button(text: String, min_size: Vector2 = Vector2.ZERO) -> Button:
	var b := Button.new()
	b.text = text
	if min_size != Vector2.ZERO:
		b.custom_minimum_size = min_size
	b.add_theme_stylebox_override("normal", _button_style(Color(0.11, 0.10, 0.08, 0.95), GOLD_EDGE))
	b.add_theme_stylebox_override("hover", _button_style(Color(0.17, 0.15, 0.10, 0.98), GOLD_EDGE_BRIGHT))
	b.add_theme_stylebox_override("pressed", _button_style(Color(0.08, 0.07, 0.05, 1.0), GOLD_EDGE_BRIGHT))
	b.add_theme_stylebox_override("focus", _button_style(Color(0.11, 0.10, 0.08, 0.95), GOLD_EDGE_BRIGHT))
	b.add_theme_color_override("font_color", GOLD)
	b.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.72))
	return b

## A label in the front-end's gold, with a black outline so it reads over
## any backdrop.
static func label(text: String, size: int = 16, colour: Color = GOLD) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", colour)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	if size > 0:
		l.add_theme_font_size_override("font_size", size)
	return l

## The black screen header bar with a title, like the original's
## "CHARACTER SELECT". Anchored across the top.
static func header(title: String) -> Control:
	var bar := ColorRect.new()
	bar.color = Color(0.0, 0.0, 0.0, 0.82)
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.custom_minimum_size = Vector2(0, 54)
	bar.size.y = 54
	var title_label := label(title, 26)
	title_label.position = Vector2(28, 12)
	bar.add_child(title_label)
	return bar
