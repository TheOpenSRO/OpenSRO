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
## Round 789: the shared set's Media (AssetArchives), packs included.
static func open_media() -> Pk2Reader:
	return AssetArchives.media()

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
	# Drawn unfiltered, as the in-game text is (UiBuilder.apply_ui_theme,
	# round 672). The front-end's own sizes are left as they are.
	UiBuilder.watch_text(root)

## The outer screens' button art (pstitle.txt / pscharacterselect.txt's
## CIFButtons), for a button whose layout control is missing.
const OUTER_BUTTON_DDJ := "interface\\outer\\button.ddj"

## A CIFButton built the way every window's is (round 848): UiBuilder's
## TextureButton -- the art's normal, _focus, _press and _disable states, at
## the layout's rect, 1:1 -- with its caption a label in the client's face,
## laid out by CIFStatic's rule in the def's ClientRect (UiBuilder.
## set_button_text). Before round 848 the front end made these as Godot
## Buttons skinned with StyleBoxTextures, which left Godot's own pieces
## showing: its grey disabled box while a button faded out (CharacterSelect
## disables a button the moment it starts fading), its hover and pressed
## font colours, and its text centring instead of the layout's alignment.
##
## `d` is the layout's control (copied, never changed); without one a def is
## made from `fallback_ddj` at `fallback_size`, centred both ways. The caller
## gives the caption already resolved; "" leaves the button without one.
## A button never takes keyboard focus (as every front-end button did).
static func cif_button(builder: UiBuilder, d: UiLayoutParser.ControlDef, text: String,
		fallback_ddj: String = OUTER_BUTTON_DDJ, fallback_size: Vector2 = Vector2(91, 41)) -> TextureButton:
	var def: UiLayoutParser.ControlDef
	if d != null:
		def = d.with_rect(d.rect)
	else:
		def = UiLayoutParser.ControlDef.new()
		def.name = "Button"
		def.halign = 1
		def.valign = 1
		def.rect = Rect2i(Vector2i.ZERO, Vector2i(fallback_size))
	def.type = "CIFButton"
	if def.name == "":
		def.name = "Button"
	if def.ddj == "":
		def.ddj = fallback_ddj
	def.text = ""
	var b: TextureButton = null
	if builder != null:
		# A zero-size rect takes the art's own size (UI_TODO rule 4).
		b = builder.build_control(def) as TextureButton
	if b == null:
		# Not reached with a builder (build_control always makes a CIFButton);
		# kept so a caller never gets null.
		b = TextureButton.new()
		b.ignore_texture_size = true
		b.stretch_mode = TextureButton.STRETCH_SCALE
		b.set_meta(UiBuilder.STATIC_DEF_META, def)
	if not b.has_meta(UiBuilder.AUTHORED_RECT_META):
		# No size in the layout and no art to take one from (OURS fallback).
		var r := Rect2(Vector2(def.rect.position), fallback_size)
		b.set_meta(UiBuilder.AUTHORED_RECT_META, r)
		b.size = r.size
		b.custom_minimum_size = r.size
		def.rect.size = Vector2i(fallback_size)
	b.focus_mode = Control.FOCUS_NONE
	# The screens show and hide their buttons themselves (a Style 0x40 hides
	# one at creation in UiBuilder).
	b.visible = true
	if text != "":
		set_cif_button_text(builder, b, text)
	# READ (round 848): a disabled CIFButton draws its caption in 0xffe6e6e6
	# -- SetEnable 0x655ec0(false) switches the text to state 3, and
	# CIFButton's slot 40 (0x655ea0, called by the loader at 0x8b5974) sets
	# state 3's colour to 0xffe6e6e6 -- and its image to the _disable art
	# (+0x390); pressing changes the image only (0x656160), never the
	# caption's place or colour. A TextureButton redraws when its disabled
	# flag changes, so the caption follows on `draw`.
	# UiBuilder._build_button greys the caption while disabled (READ there);
	# the no-builder fallback above gets the same.
	if builder == null:
		b.draw.connect(func() -> void: UiBuilder.sync_disabled_caption(b))
	return b

## READ (UiBuilder.DISABLED_CAPTION): CIFButton's disabled caption colour.
const DISABLED_CAPTION := UiBuilder.DISABLED_CAPTION

## A CIFButton's caption (SetText): the label UiBuilder keeps under it,
## made the first time.
static func set_cif_button_text(builder: UiBuilder, b: BaseButton, text: String) -> void:
	if b == null:
		return
	if builder != null:
		builder.set_button_text(b, text)
		return
	var l := b.get_node_or_null("ButtonLabel") as Label
	if l == null:
		l = Label.new()
		l.name = "ButtonLabel"
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		b.add_child(l)
	l.text = text

## A CIFButton's caption as shown, or "".
static func cif_button_text(b: BaseButton) -> String:
	if b == null:
		return ""
	if b is Button:
		return (b as Button).text
	for n in ["ButtonLabel", "Text"]:
		var l := b.get_node_or_null(n) as Label
		if l != null:
			return l.text
	return ""

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
