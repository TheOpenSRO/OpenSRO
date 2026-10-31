extends Control
class_name FrontEndFrame

## The letterbox frame every front-end screen sits in (round 678): the top
## and bottom bands, the black covers over them while an intro flies, the
## screen's title art top-left, the big logo, the logo, the version, the
## operator's copyright line and a message line. The login screen uses it
## now; character select, region select and customize reuse it later.
##
## Built from the archive's own layout and art (READ): Media.pk2
## resinfo\pstitle.txt, section "Title", whose rects are in a 1600x1200
## design space (GDR_FADE's own rect is 0,0,1600,1200). CPSTitle::OnCreate
## runs FUN_00849c70 over windows 1, 2, 3, 4, 5, 7, 8 and 13 with its 4:3
## flag off, which scales each rect by screen_w / 1600 and screen_h / 1200
## (the floats at 0xed7cc8 / 0xed7ccc, divided into the screen size at
## 0x842dd1..0x842de7) -- so on a wide screen the bands and logos stretch
## sideways, as retail's do. The `#ifdef` branches are taken as the
## undefined ones (the `#else` art): INFERRED from FUN_00866760 replacing
## window 9's texture with login_window_europe.ddj by hand, which a build
## defining EUROPE_SYSTEM would not need.
##
## The windows, by the layout's IDs:
##   1 GDR_STA_SCREENUP    blackbar_up_18.ddj            the top band art
##   2 GDR_STA_SCREENDOWN  blackbar_down_copyright.ddj   the bottom band art
##   3 GDR_STA_BSCREENUP   CIFFade, colour 0xff000000    black over band 1
##   4 GDR_STA_BSCREENDOWN CIFFade, colour 0xff000000    black over band 2
##   5 GDR_STA_TITLE       text-connect.ddj               the screen's title
##   7 GDR_STA_BIGLOGO     logo-big.ddj                   shown during the fly
##   8 GDR_STA_LOGO        logo.ddj                       above the login box
## (OnCreate sets 3 and 4 to colour 0xff000000 at alpha 255, 0x86b763 and
## 0x86b78b.) Windows are made in reverse file order (the client's OnCreate,
## round 583), so the black covers draw over the band art.
##
## The fade (CIFFade, READ): UI_SILKMALL::FUN_006526e0(from, to, duration,
## start) stores from/to bytes and a duration, and sets the elapsed time to
## `start` (FUN_006552b0); each step (FUN_006552f0) sets alpha = from while
## elapsed <= 0, = to once elapsed >= duration, else
## round(from * (1 - u) + to * u) with u = elapsed / duration. That the
## elapsed time grows by the frame's delta is INFERRED (the caller that adds
## it is not read).
##
## Branding (OURS, FrontEndTheme): the band art, the logo and a copyright line
## can be the operator's -- custom/frontend/<file> named by the theme, or
## band_top.png / band_bottom.png / logo.png there -- each falling back to the
## archive's art, with a line in the log saying why. An operator's copyright
## line draws over the archive's plain bottom band (blackbar_down.ddj), so the
## archive's own copyright art is not shown under it.

const DdjReader = preload("res://scripts/ddj/ddj_reader.gd")

const DESIGN_SIZE := Vector2(1600.0, 1200.0)
const LAYOUT_PATH := "resinfo\\pstitle.txt"
const ID_SCREENUP := 1
const ID_SCREENDOWN := 2
const ID_BSCREENUP := 3
const ID_BSCREENDOWN := 4
const ID_TITLE := 5
const ID_BIGLOGO := 7
const ID_LOGO := 8
const ID_LOGINWINDOW := 9
const ID_OK := 11
const ID_CANCEL := 12
## The archive's bottom band without the copyright line (Media.pk2), drawn
## under an operator's own line.
const PLAIN_BOTTOM_DDJ := "interface\\outer\\blackbar_down.ddj"

## READ: the version window (gwnd::FUN_00ba20b0 at 0x86bc1d): x 5,
## y = screen height - 0x19, 0x50 x 0x14, text colour 0xffff8080
## (FUN_008b2b70, 0x86bc49), text "Ver %d.%03d" (0xdd8dc0).
## Round 848 (lane R), READ: the window is a CIFStatic (class record
## 0xee9720, named "CIFStatic" at 0xd9e1cc by its registration 0xd6afdb; its
## constructor 0x64d5f0 over CIFWnd's 0x654520), made with no layout record,
## so its text keeps what the constructors give it: font 0 (0x65460e..
## 0x65462e, FUN_00ba5460(0)) -- 12 px, UiBuilder.FONT_SIZES[0] -- and
## CTextBoard's HAlign 1 and VAlign 1 (+0x88 / +0x8c = 1, 0x655c28..
## 0x655c3b): centred both ways in the 80 x 20 rect, by CIFStatic's layout
## 0x64d9b0 (UiBuilder._map_halign's reading). Its OnCreate (vslot 10,
## 0x64d6b0) only returns 1, and nothing sets the text's flags: no shadow, no
## outline. Before, a Label with no size of its own drew Godot's 16 px,
## left and top in the rect (MEASURED: ink rows 698..709, columns 5..67 at
## 1280 x 720). The words are OpenSRO's version (OURS: "Ver 0.1.612" for
## retail's "Ver %d.%03d" of its own number).
const VERSION_POS_X := 5.0
const VERSION_FROM_BOTTOM := 0x19
const VERSION_SIZE := Vector2(0x50, 0x14)
const VERSION_COLOR := Color(1.0, 0x80 / 255.0, 0x80 / 255.0, 1.0)
const VERSION_FONT_INDEX := 0
## The operator's copyright line (OURS, FrontEndTheme) in font 0 (12 px), the
## size of the title's own drawn text nearest it -- the version line above,
## READ -- in white, the colour of the archive's own copyright line it
## replaces (MEASURED: blackbar_down_copyright.ddj's line drawn at 1280 x 720,
## ink rows 701..710, its core pixels 255,255,255). Before: Godot's 16 px.
const COPYRIGHT_COLOR := Color(1.0, 1.0, 1.0, 1.0)
const COPYRIGHT_FONT_INDEX := 0
## The clearance kept between the logo and the login window when retail's
## own placement would overlap them (logo_rect). INFERRED: retail's own
## clearance at the reference's 1024x768, 0x78 - round(172 * 768 / 1200) =
## 120 - 110 = 10 (the iSRO reference shows the logo that far above the box).
const LOGO_GAP := 10.0
## MEASURED (see relayout): the archive's copyright line's middle, design y.
const COPYRIGHT_MID_Y := 1177.5

var layout: UiLayoutParser.LayoutDef = null
## The section the frame's windows are read from ("Title" at the title).
var _title_section: UiLayoutParser.SectionDef = null
## Which layout ID plays which part of the frame (round 684): the title's
## own IDs by default; the character select screen's layout
## (pscharacterselect.txt, section "Select") names its bands 1/2 and its title
## 3, and has no covers or logos (READ: MEASURED in that file, -1 = none).
const TITLE_ROLES := {"screenup": ID_SCREENUP, "screendown": ID_SCREENDOWN, "bscreenup": ID_BSCREENUP,
	"bscreendown": ID_BSCREENDOWN, "title": ID_TITLE, "biglogo": ID_BIGLOGO, "logo": ID_LOGO}
const SELECT_LAYOUT_PATH := "resinfo\\pscharacterselect.txt"
const SELECT_ROLES := {"screenup": 1, "screendown": 2, "bscreenup": -1, "bscreendown": -1,
	"title": 3, "biglogo": -1, "logo": -1}
var _roles: Dictionary = TITLE_ROLES
var _media: Pk2Reader = null

var band_top: TextureRect
var band_bottom: TextureRect
var cover_top: ColorRect
var cover_bottom: ColorRect
var title_art: TextureRect
var big_logo: TextureRect
var logo: TextureRect
var version_label: Label
var copyright_label: Label
## Whether the logo is the operator's (keeps its own aspect ratio).
var custom_logo := false

## node -> {from, to, duration, elapsed} (bytes 0..255, seconds)
var _fades := {}

## The archive layout, or null when Media.pk2 has no pstitle.txt.
static func load_layout(media: Pk2Reader, path: String = LAYOUT_PATH) -> UiLayoutParser.LayoutDef:
	if media == null:
		return null
	var entry := ObjectLoader.find_file(media, path)
	if entry == null:
		return null
	return UiLayoutParser.parse(media.read_file(entry), true, PackedStringArray())

## Builds the frame. False when the archive has no title layout (the caller
## keeps its plain screen).
func build(media: Pk2Reader, theme: FrontEndTheme, custom_dir: String, version_text: String,
		parsed_layout: UiLayoutParser.LayoutDef = null, section: String = "Title", roles: Dictionary = TITLE_ROLES) -> bool:
	_media = media
	_roles = roles
	layout = parsed_layout if parsed_layout != null else load_layout(media)
	if layout == null or not layout.sections.has(section):
		print("FrontEndFrame: no section %s in the layout -- no letterbox frame" % section)
		return false
	_title_section = layout.sections[section]
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bottom_default := role_def("screendown").ddj if role_def("screendown") != null else ""
	if theme != null and theme.copyright != "":
		bottom_default = PLAIN_BOTTOM_DDJ
	band_top = _art_rect(_branded_texture(theme.band_top if theme != null else "", "band_top.png", role_def("screenup").ddj if role_def("screenup") != null else "", custom_dir, "top band"))
	band_bottom = _art_rect(_branded_texture(theme.band_bottom if theme != null else "", "band_bottom.png", bottom_default, custom_dir, "bottom band"))
	cover_top = _cover()
	cover_bottom = _cover()
	title_art = _art_rect(_ddj(role_def("title").ddj if role_def("title") != null else ""))
	big_logo = _art_rect(_ddj(role_def("biglogo").ddj if role_def("biglogo") != null else ""))
	# A frame whose layout has no logo window (the select screen's) draws no
	# logo, the operator's included: its branding is the band art.
	var logo_tex: Texture2D = null
	if role_def("logo") != null:
		logo_tex = _custom_texture(theme.logo if theme != null else "", "logo.png", custom_dir, "logo")
	custom_logo = logo_tex != null
	if logo_tex == null:
		logo_tex = _ddj(role_def("logo").ddj if role_def("logo") != null else "")
	logo = _art_rect(logo_tex)
	if custom_logo:
		logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# Reverse file order (the client's): band art under the black covers, the
	# title and logos over them.
	for n in [band_top, band_bottom, cover_top, cover_bottom, title_art, big_logo, logo]:
		add_child(n)
	version_label = text_line(version_text, VERSION_COLOR, VERSION_FONT_INDEX)
	version_label.name = "Version"
	add_child(version_label)
	copyright_label = text_line(theme.copyright if theme != null else "", COPYRIGHT_COLOR, COPYRIGHT_FONT_INDEX)
	copyright_label.name = "Copyright"
	copyright_label.visible = copyright_label.text != ""
	add_child(copyright_label)
	resized.connect(relayout)
	relayout()
	return true

## A line of the frame's own text, as a CIFStatic made without a layout
## record draws it (VERSION_* above, READ): `font_index`'s size, `colour`,
## centred both ways in its rect, no outline or shadow, crisp. The face is
## the screen's (FrontEndUi.apply_client_font on the screen's root).
static func text_line(text: String, colour: Color, font_index: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[clampi(font_index, 0, UiBuilder.FONT_SIZES.size() - 1)])
	l.add_theme_color_override("font_color", colour)
	l.add_theme_constant_override("outline_size", 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.clip_text = false
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiBuilder.crisp_text(l)
	return l

func def(id: int) -> UiLayoutParser.ControlDef:
	return by_id(_title_section, id)

## The window playing `role` in this frame (_roles), or null when the layout
## has none.
func role_def(role: String) -> UiLayoutParser.ControlDef:
	var id: int = _roles.get(role, -1)
	return def(id) if id >= 0 else null

func login_def(id: int) -> UiLayoutParser.ControlDef:
	if layout == null or not layout.sections.has("Login"):
		return null
	return by_id(layout.sections["Login"], id)

## A section's control by its layout ID (the parser lists them; its
## control_by_id map is not filled).
static func by_id(section: UiLayoutParser.SectionDef, id: int) -> UiLayoutParser.ControlDef:
	if section == null:
		return null
	for c in section.controls:
		if c.id == id:
			return c
	return null

## screen_w / 1600, screen_h / 1200 (READ).
func design_scale() -> Vector2:
	var s := size if size.x > 0 else get_viewport_rect().size
	return Vector2(s.x / DESIGN_SIZE.x, s.y / DESIGN_SIZE.y)

## A design rect scaled to the screen (FUN_00849c70, 4:3 flag off).
func scaled(rect: Rect2i) -> Rect2:
	var k := design_scale()
	return Rect2(roundf(rect.position.x * k.x), roundf(rect.position.y * k.y),
		roundf(rect.size.x * k.x), roundf(rect.size.y * k.y))

## READ, FUN_00866760: the vertical middle between the bands -- band 1's
## bottom and band 2's top, both as scaled -- `(top2 - bottom1) >> 1 +
## bottom1`; and the screen's horizontal middle, width >> 1.
func centre_line() -> Vector2i:
	var up := scaled(role_def("screenup").rect) if role_def("screenup") != null else Rect2()
	var down := scaled(role_def("screendown").rect) if role_def("screendown") != null else Rect2()
	var bottom1 := int(up.position.y + up.size.y)
	var top2 := int(down.position.y)
	var s := size if size.x > 0 else get_viewport_rect().size
	return Vector2i(int(s.x) >> 1, ((top2 - bottom1) >> 1) + bottom1)

## Round 788, READ (FUN_00866760, 0x86695e..0x8669b1): the title's message
## line, window 500 (GDR_TEXT_MESSAGE), at window 2's -- the bottom band's --
## top-left + (9, 0x18), sized the screen's width x 0x49.
func message_rect() -> Rect2:
	var down := scaled(role_def("screendown").rect) if role_def("screendown") != null else Rect2()
	var s := size if size.x > 0 else get_viewport_rect().size
	return Rect2(down.position + Vector2(9, 0x18), Vector2(s.x, 0x49))

## The bottom edge of the top band, scaled (where the logo may reach up to).
func band_bottom_edge() -> int:
	var up := scaled(role_def("screenup").rect) if role_def("screenup") != null else Rect2()
	return int(up.position.y + up.size.y)

## Where the logo goes, given its scaled size, the centre line and the top
## band's bottom edge.
##
## READ, FUN_00866760 (0x8667e4..0x866803): the logo's top-left is
## (cx - w/2, mid + 6 - 0x78) whatever its height -- its size is the pstitle
## rect (508x172) scaled by OnCreate (FUN_00849c70) -- and the login window's
## top is mid + 6 (0x866860). So the logo clears the window only while its
## scaled height is at most 0x78 = 120, 172 * h / 1200 <= 120: a screen (in
## our UI units) at most 837 tall. At the reference's 1024x768 it is 110 tall
## and 10 clear; at 1080 lines it reaches 35 into the window, and on the
## player's 3840x2160 at UI scale 1.95 (a 1969x1108 canvas) 39 -- the "ONLINE"
## line hidden behind the box (round 679).
##
## OURS (round 679): where retail's own placement would overlap, the logo is
## lifted until it clears the window by LOGO_GAP; where it does not, it stays
## exactly where retail puts it. Its size stays retail's, and it never rises
## above the top band.
static func logo_rect(logo_size: Vector2, c: Vector2i, band_bottom: int) -> Rect2:
	var x := float(c.x - (int(logo_size.x) >> 1))
	var y := float(c.y + 6 - 0x78)
	var box_top := float(c.y + 6)
	if y + logo_size.y > box_top - LOGO_GAP:
		y = maxf(box_top - LOGO_GAP - logo_size.y, float(band_bottom))
	return Rect2(Vector2(x, y), logo_size)

func relayout() -> void:
	_place(band_top, role_def("screenup"))
	_place(band_bottom, role_def("screendown"))
	_place(cover_top, role_def("bscreenup"))
	_place(cover_bottom, role_def("bscreendown"))
	_place(title_art, role_def("title"))
	_place(big_logo, role_def("biglogo"))
	# The logo: scaled like the others (OnCreate), then centred above the
	# login box by FUN_00866760 (logo_rect).
	if logo != null and role_def("logo") != null:
		var r := logo_rect(scaled(role_def("logo").rect).size, centre_line(), band_bottom_edge())
		logo.size = r.size
		logo.position = r.position
	var s := size if size.x > 0 else get_viewport_rect().size
	if version_label != null:
		version_label.position = Vector2(VERSION_POS_X, s.y - VERSION_FROM_BOTTOM)
		version_label.size = VERSION_SIZE
	# OURS: the operator's line centred in the bottom band where the
	# archive's own line sits in its art -- MEASURED on the 1600x172
	# blackbar_down_copyright.ddj (thresholded at 70 % grey): the line's
	# pixels span rows 139..156 and columns 490..1110, so its middle is at
	# 1030 + 147.5 in the design space, centred at x 800.
	if copyright_label != null and role_def("screendown") != null:
		var k := design_scale()
		copyright_label.position = Vector2(0, roundf(COPYRIGHT_MID_Y * k.y) - 10.0)
		copyright_label.size = Vector2(s.x, 20.0)

func _place(n: Control, d: UiLayoutParser.ControlDef) -> void:
	if n == null or d == null:
		return
	var r := scaled(d.rect)
	n.position = r.position
	n.size = r.size

func _art_rect(tex: Texture2D) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr

func _cover() -> ColorRect:
	var c := ColorRect.new()
	c.color = Color(0, 0, 0, 1)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

func _ddj(path: String) -> Texture2D:
	if path == "" or _media == null:
		return null
	return FrontEndUi.load_ddj(_media, path)

## The operator's image if there is a usable one, else null (and why, in the
## log). `named` is the theme's file name, `default_name` the file looked
## for when the theme names none.
func _custom_texture(named: String, default_name: String, custom_dir: String, what: String) -> Texture2D:
	var path := ""
	if named != "":
		path = FrontEndTheme.custom_image_path(custom_dir, named)
		if path == "":
			print("FrontEnd: %s '%s' not found in %s -- the archive's art" % [what, named, custom_dir.path_join("frontend")])
			return null
	else:
		path = FrontEndTheme.custom_image_path(custom_dir, default_name)
		if path == "":
			return null
	var tex := load_image_file(path)
	if tex == null:
		print("FrontEnd: %s %s could not be read as an image -- the archive's art" % [what, path])
		return null
	print("FrontEnd: %s from %s (%dx%d)" % [what, path, tex.get_width(), tex.get_height()])
	return tex

func _branded_texture(named: String, default_name: String, archive_ddj: String, custom_dir: String, what: String) -> Texture2D:
	var tex := _custom_texture(named, default_name, custom_dir, what)
	return tex if tex != null else _ddj(archive_ddj)

## A PNG or DDJ from the filesystem as a texture, or null.
static func load_image_file(path: String) -> Texture2D:
	if path.to_lower().ends_with(".ddj"):
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.is_empty():
			return null
		var parsed := DdjReader.parse(bytes)
		return DdjReader.to_texture(parsed) if parsed != null else null
	var img := Image.new()
	if img.load(path) != OK or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)

# --- Fades (CIFFade, READ above) ---------------------------------------------

## Starts a fade on a node, alpha bytes `from` -> `to` over `duration`
## seconds, after `delay` seconds (retail passes the start as a negative
## elapsed time: the big logo's -15.0).
func fade(n: CanvasItem, from: int, to: int, duration: float, delay: float = 0.0) -> void:
	if n == null:
		return
	_fades[n] = {"from": from, "to": to, "duration": duration, "elapsed": -delay}
	_apply_fade(n)

## Sets an alpha at once (no fade).
func set_alpha(n: CanvasItem, alpha: int) -> void:
	if n == null:
		return
	_fades.erase(n)
	n.modulate.a = alpha / 255.0

## The current alpha byte of a node's fade.
static func fade_alpha(from: int, to: int, duration: float, elapsed: float) -> int:
	if elapsed <= 0.0:
		return from
	if duration <= elapsed:
		return to
	var u := elapsed / duration
	return int(roundf(float(from) * (1.0 - u) + float(to) * u))

func fades_running() -> int:
	return _fades.size()

func _process(delta: float) -> void:
	for n in _fades.keys():
		if not is_instance_valid(n):
			_fades.erase(n)
			continue
		var f: Dictionary = _fades[n]
		f["elapsed"] = float(f["elapsed"]) + delta
		_apply_fade(n)
		if float(f["elapsed"]) >= float(f["duration"]):
			_fades.erase(n)

func _apply_fade(n: CanvasItem) -> void:
	var f: Dictionary = _fades[n]
	n.modulate.a = fade_alpha(f["from"], f["to"], f["duration"], f["elapsed"]) / 255.0
