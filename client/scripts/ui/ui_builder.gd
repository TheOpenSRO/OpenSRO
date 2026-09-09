extends RefCounted
class_name UiBuilder

## Constructs Godot Control node hierarchies from parsed Silkroad Online UI layout definitions
## (UiLayoutParser.LayoutDef) and textures loaded from Media.pk2 via DdjReader.

const DdjReader = preload("res://scripts/ddj/ddj_reader.gd")
const ObjectLoader = preload("res://scripts/assets/object_loader.gd")
const UiLayoutParser = preload("res://scripts/ui/ui_layout_parser.gd")
const UiTextTable = preload("res://scripts/ui/ui_text_table.gd")

## The client's top-level window registry. Each HUD window is declared here
## with its background artwork and its screen rect -- information that is
## *not* in the per-window layout files. `resinfo\\ifunderbar.txt` lists the
## bar's 76 child controls but never names the bar's own background;
## `GDR_UNDERBAR` in this file does (`ub_window_01.ddj`, 800x52 at 112,684).
const WINDOW_REGISTRY_PATH := "resinfo\\ginterface.txt"

var _media_pk2: Pk2Reader
var _text_table: UiTextTable
var _texture_cache: Dictionary = {} # String -> Texture2D
var _window_registry: UiLayoutParser.LayoutDef = null
var _window_registry_loaded: bool = false
var _layout_cache: Dictionary = {} # String -> UiLayoutParser.LayoutDef

## Loads and caches a layout file from Media.pk2 by its archive path
## (e.g. "resinfo\\ifinventory.txt"). Returns null if it isn't there.
func load_layout(layout_path: String) -> UiLayoutParser.LayoutDef:
	if _layout_cache.has(layout_path):
		return _layout_cache[layout_path]
	if _media_pk2 == null:
		return null
	var entry := ObjectLoader.find_file(_media_pk2, layout_path)
	if entry == null:
		push_warning("UiBuilder: layout %s not in Media.pk2" % layout_path)
		return null
	var layout := UiLayoutParser.parse(_media_pk2.read_file(entry))
	_layout_cache[layout_path] = layout
	return layout

## The size a window built from this section should be: the largest rect
## among its controls that starts at the origin -- which in every real
## layout read is the window's own CIFFrame (ifinventory's
## GDR_INVENTORY_FRAME is 0,0,176,308). Falls back to the bounding box of
## everything, so a layout with no frame still gets a sensible size rather
## than zero.
static func section_size(sec: UiLayoutParser.SectionDef) -> Vector2:
	var framed := Vector2.ZERO
	var bounds := Vector2.ZERO
	for def in sec.controls:
		var far := Vector2(def.rect.position + def.rect.size)
		bounds = Vector2(maxf(bounds.x, far.x), maxf(bounds.y, far.y))
		if def.rect.position == Vector2i.ZERO and def.rect.size.x > framed.x:
			framed = Vector2(def.rect.size)
	return framed if framed != Vector2.ZERO else bounds

func _init(media_pk2: Pk2Reader = null, text_table: UiTextTable = null) -> void:
	_media_pk2 = media_pk2
	_text_table = text_table

## Returns the top-level declaration of a HUD window (e.g. "GDR_UNDERBAR",
## "GDR_MINIMAP") from the client's own window registry, or null if the
## registry or the entry is missing. The returned def carries the window's
## background `ddj` and its authored `rect`.
##
## The registry's rect is `x, y, width, height` -- confirmed by every
## authored size matching its artwork's real dimensions exactly
## (ub_window_01 800x52, ub_deco_left 64x52, ub_menu_button 60x56,
## ub_sp_bar 144x8, mm_window 140x184), which also shows the art is drawn
## 1:1 rather than stretched.
func window_def(window_name: String) -> UiLayoutParser.ControlDef:
	if not _window_registry_loaded:
		_window_registry_loaded = true
		if _media_pk2 != null:
			var entry := ObjectLoader.find_file(_media_pk2, WINDOW_REGISTRY_PATH)
			if entry != null:
				_window_registry = UiLayoutParser.parse(_media_pk2.read_file(entry))
	if _window_registry == null:
		return null
	var sec := _window_registry.get_section("Create")
	if sec == null:
		return null
	return sec.control_by_name.get(window_name)

## Builds a Godot Control containing all controls defined in the specified section.
func build_section(layout: UiLayoutParser.LayoutDef, section_name: String = "Create") -> Control:
	var sec := layout.get_section(section_name)
	if sec == null:
		return null

	var root := Control.new()
	root.name = sec.name
	# Transparent container: it must not eat mouse input meant for the world
	# behind it. IGNORE applies to this node alone, so the controls inside
	# keep their own filters.
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if sec.rect.size.x > 0 and sec.rect.size.y > 0:
		root.position = Vector2(sec.rect.position)
		root.size = Vector2(sec.rect.size)
		root.custom_minimum_size = Vector2(sec.rect.size)

	for ctrl_def in sec.controls:
		var node := build_control(ctrl_def)
		if node != null:
			root.add_child(node)

	return root

## Builds a single Godot node corresponding to a ControlDef.
func build_control(def: UiLayoutParser.ControlDef) -> Control:
	var node: Control = null

	match def.type:
		"CIFButton":
			node = _build_button(def)
		"CIFStatic":
			node = _build_static(def)
		"CIFGauge":
			node = _build_gauge(def)
		"CIFFrame", "CIFStretchWnd":
			node = _build_frame(def)
		"CIFEdit", "CIFEInputChatBox":
			node = _build_edit(def)
		"CIFSlotWithHelp", "CIFSlot", "CIFExtQuickSlotSlot", "CIFPartySlot":
			node = _build_slot(def)
		"CIFLattice":
			node = _build_lattice(def)
		_:
			# Generic container for unhandled or compound control types
			node = _build_generic(def)

	if node != null:
		node.name = def.name
		node.position = Vector2(def.rect.position)
		if def.rect.size.x > 0 and def.rect.size.y > 0:
			node.size = Vector2(def.rect.size)
			node.custom_minimum_size = Vector2(def.rect.size)
		else:
			# A zero-size rect means "use the artwork's own size". Real
			# layouts do this (`GDR_DECORATE_3` in ifunderbar.txt is
			# `Rect=RECT,"677,-40,0,0"` carrying ub_window_02.ddj), and
			# leaving the node at zero size made it invisible. Every authored
			# rect that *does* carry a size matches its texture's dimensions
			# exactly -- ub_window_01 800x52, ub_deco_left 64x52,
			# ub_menu_button 60x56, ub_sp_bar 144x8, mm_window 140x184 --
			# so the art is authored 1:1 and its own size is the right
			# fallback.
			var natural := _natural_size(def)
			if natural != Vector2.ZERO:
				node.size = natural
				node.custom_minimum_size = natural

	return node

## The size of a control's own artwork, or zero if it has none.
func _natural_size(def: UiLayoutParser.ControlDef) -> Vector2:
	if def.ddj == "":
		return Vector2.ZERO
	var tex := load_texture(def.ddj)
	if tex == null:
		return Vector2.ZERO
	return tex.get_size()

func _build_button(def: UiLayoutParser.ControlDef) -> TextureButton:
	var btn := TextureButton.new()
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_SCALE

	if def.ddj != "":
		btn.texture_normal = load_texture_region(def.ddj, def.uv_lt, def.uv_rb)

		# State textures convention: _focus, _press, _disable
		var focus_path := _insert_suffix(def.ddj, "_focus")
		var press_path := _insert_suffix(def.ddj, "_press")
		var disable_path := _insert_suffix(def.ddj, "_disable")

		btn.texture_hover = load_texture(focus_path)
		btn.texture_focused = btn.texture_hover
		btn.texture_pressed = load_texture(press_path)
		btn.texture_disabled = load_texture(disable_path)

	if def.text != "":
		var label := Label.new()
		label.name = "ButtonLabel"
		label.text = _resolve_text(def.text)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.set_anchors_preset(Control.PRESET_FULL_RECT)
		if def.font_color != Color.WHITE:
			label.add_theme_color_override("font_color", def.font_color)
		_apply_font(label, def)
		btn.add_child(label)

	return btn

func _build_static(def: UiLayoutParser.ControlDef) -> Control:
	if def.ddj != "":
		var rect := TextureRect.new()
		rect.texture = load_texture_region(def.ddj, def.uv_lt, def.uv_rb)
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_SCALE
		# `Color` is deliberately NOT applied as a tint. It looks like one,
		# but it is a per-control editor id: across ifunderbar.txt's 76
		# controls there are 64 distinct values, scattered
		# (255,51,191,68 / 255,91,102,218 / 255,64,213,106 ...), whereas
		# `FontColor` -- a field that really is a colour -- is pure white on
		# 74 of those same 76. Modulating by it tinted every piece of
		# artwork a different random colour.

		if def.text != "":
			var label := Label.new()
			label.name = "Text"
			label.text = _resolve_text(def.text)
			label.horizontal_alignment = _map_halign(def.halign)
			label.vertical_alignment = _map_valign(def.valign)
			label.set_anchors_preset(Control.PRESET_FULL_RECT)
			if def.font_color != Color.WHITE:
				label.add_theme_color_override("font_color", def.font_color)
			rect.add_child(label)

		return rect
	# No artwork means this is a text field, and it stays one even when its
	# text starts empty -- the client fills those at runtime. Returning a
	# plain Control for the empty case (as this used to) meant every live
	# data field in a window, GDR_PMI_TXT_ID and the HP/MP readouts
	# included, was built as something that can never show text.
	var label := Label.new()
	label.text = _resolve_text(def.text)
	label.horizontal_alignment = _map_halign(def.halign)
	label.vertical_alignment = _map_valign(def.valign)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if def.font_color != Color.WHITE:
		label.add_theme_color_override("font_color", def.font_color)
	_apply_font(label, def)
	return label

## A 1x1 white texture, so a gauge with no artwork of its own can still be
## drawn and tinted. Built once and shared.
static var _flat_texture: ImageTexture = null

static func flat_texture() -> ImageTexture:
	if _flat_texture == null:
		var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		image.set_pixel(0, 0, Color.WHITE)
		_flat_texture = ImageTexture.create_from_image(image)
	return _flat_texture

func _build_gauge(def: UiLayoutParser.ControlDef) -> TextureProgressBar:
	var gauge := TextureProgressBar.new()
	gauge.min_value = 0
	gauge.max_value = 100
	gauge.value = 100
	gauge.nine_patch_stretch = true
	gauge.mouse_filter = Control.MOUSE_FILTER_IGNORE

	if def.ddj != "":
		gauge.texture_progress = load_texture_region(def.ddj, def.uv_lt, def.uv_rb)
	# Several real gauges name no artwork at all -- the player block's
	# GDR_PMI_GAUGE_HP and _MP among them, which the client colours itself.
	# Without a texture a TextureProgressBar draws nothing, so fall back to
	# a flat fill the caller can tint, rather than leaving the bar invisible.
	if gauge.texture_progress == null:
		gauge.texture_progress = flat_texture()
		gauge.texture_under = flat_texture()
		gauge.tint_under = Color(0.10, 0.10, 0.12, 0.85)

	return gauge

## Interior fill for a framed window.
##
## **This colour is ours, not authored.** Every 8-slice frame set in the
## archive -- `mframe_wnd_`, `int_window_`, `game_window_`, `event_sub_wnd_`
## and the rest, 30-odd of them -- contains exactly eight pieces: four
## corners and four edges, and **no centre**. So the interior of a window is
## not painted by the frame art, and nothing found so far says what the real
## client fills it with. Left unfilled the windows are see-through, which is
## worse than a stand-in, so this is a flat dark fill chosen to match what
## the reference screenshots show. Replace it the moment the real fill is
## identified.
const FRAME_FILL := Color(0.055, 0.055, 0.07, 0.94)

func _build_frame(def: UiLayoutParser.ControlDef) -> Control:
	var container := Control.new()
	container.mouse_filter = Control.MOUSE_FILTER_PASS

	if def.ddj != "" and def.ddj.ends_with("_"):
		# 8-slice border: left_up, mid_up, right_up, left_side, right_side, left_down, mid_down, right_down
		var lu := load_texture(def.ddj + "left_up.ddj")
		var mu := load_texture(def.ddj + "mid_up.ddj")
		var ru := load_texture(def.ddj + "right_up.ddj")
		var ls := load_texture(def.ddj + "left_side.ddj")
		var rs := load_texture(def.ddj + "right_side.ddj")
		var ld := load_texture(def.ddj + "left_down.ddj")
		var md := load_texture(def.ddj + "mid_down.ddj")
		var rd := load_texture(def.ddj + "right_down.ddj")

		var corner_w := lu.get_width() if lu != null else 10
		var corner_h := lu.get_height() if lu != null else 10

		_add_slice(container, lu, Rect2(0, 0, corner_w, corner_h))
		_add_slice(container, mu, Rect2(corner_w, 0, def.rect.size.x - corner_w * 2, corner_h), true)
		_add_slice(container, ru, Rect2(def.rect.size.x - corner_w, 0, corner_w, corner_h))

		_add_slice(container, ls, Rect2(0, corner_h, corner_w, def.rect.size.y - corner_h * 2), true)
		_add_slice(container, rs, Rect2(def.rect.size.x - corner_w, corner_h, corner_w, def.rect.size.y - corner_h * 2), true)

		_add_slice(container, ld, Rect2(0, def.rect.size.y - corner_h, corner_w, corner_h))
		_add_slice(container, md, Rect2(corner_w, def.rect.size.y - corner_h, def.rect.size.x - corner_w * 2, corner_h), true)
		_add_slice(container, rd, Rect2(def.rect.size.x - corner_w, def.rect.size.y - corner_h, corner_w, corner_h))

	return container

func _add_slice(parent: Control, tex: Texture2D, rect: Rect2, tile: bool = false) -> void:
	if tex == null or rect.size.x <= 0 or rect.size.y <= 0:
		return
	var tr := TextureRect.new()
	tr.texture = tex
	tr.position = rect.position
	tr.size = rect.size
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_TILE if tile else TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(tr)

func _build_edit(def: UiLayoutParser.ControlDef) -> LineEdit:
	var edit := LineEdit.new()
	if def.text != "":
		edit.placeholder_text = _resolve_text(def.text)
	return edit

func _build_slot(def: UiLayoutParser.ControlDef) -> Control:
	var slot := Control.new()
	slot.mouse_filter = Control.MOUSE_FILTER_PASS

	if def.ddj != "":
		var bg := TextureRect.new()
		bg.name = "SlotBg"
		bg.texture = load_texture_region(def.ddj, def.uv_lt, def.uv_rb)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(bg)

	var icon := TextureRect.new()
	icon.name = "ItemIcon"
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(icon)

	var count_lbl := Label.new()
	count_lbl.name = "CountLabel"
	count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count_lbl.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count_lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	count_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(count_lbl)

	return slot

## The cell pitch of a lattice, in pixels. Real inventory art is a 32x32
## slot on a 32-pixel grid; ifinventory's GDR_INVENTORY_LATTICE is 144x288,
## which is not a whole number of 32s (4.5 x 9). The 4-pixel shortfall is
## the outline the layout draws around it (GDR_INVENTORY_LATTICE_OUTLINE is
## 146x290 at 15,10 against the lattice's 144x288 at 18,13), so the usable
## grid is 4 columns and the remainder is border. Rounding down is what
## keeps a partial cell from being drawn.
const LATTICE_CELL := 32

## Builds a slot grid. A CIFLattice is the item-grid control -- the
## inventory's 5x9 of item slots, and the same control in storage and
## stall windows. The layout gives its pixel rect, not a row/column count,
## so the grid is derived from the cell pitch.
func _build_lattice(def: UiLayoutParser.ControlDef) -> Control:
	var grid := Control.new()
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cols: int = maxi(1, def.rect.size.x / LATTICE_CELL)
	var rows: int = maxi(1, def.rect.size.y / LATTICE_CELL)
	for i in range(cols * rows):
		var slot := _build_slot(def)
		slot.name = "Cell%d" % i
		slot.position = Vector2((i % cols) * LATTICE_CELL, (i / cols) * LATTICE_CELL)
		slot.size = Vector2(LATTICE_CELL, LATTICE_CELL)
		slot.custom_minimum_size = slot.size
		grid.add_child(slot)
	return grid

func _build_generic(def: UiLayoutParser.ControlDef) -> Control:
	var ctrl := Control.new()
	ctrl.mouse_filter = Control.MOUSE_FILTER_PASS
	return ctrl

## Loads a .ddj texture from Media.pk2, using an in-memory cache to avoid duplicate decodes.
func load_texture(ddj_path: String) -> Texture2D:
	if ddj_path.is_empty():
		return null
	var key := ddj_path.to_lower().replace("/", "\\")
	if _texture_cache.has(key):
		return _texture_cache[key]

	if _media_pk2 == null:
		return null

	var entry := ObjectLoader.find_file(_media_pk2, key)
	if entry == null:
		return null
	var data := _media_pk2.read_file(entry)
	if data.is_empty():
		return null
	var parsed := DdjReader.parse(data)
	if parsed == null:
		return null
	var tex := DdjReader.to_texture(parsed)
	if tex != null:
		_texture_cache[key] = tex
	return tex

## Loads a texture, cropped to the sub-rect a control's UV fields name.
##
## Several interface textures are **atlases**, not single images:
## `interface\\ifcommon\\window_all.ddj` is 1024x512 and holds many panel
## backgrounds side by side. A control that uses one names its slice with
## `UV_LT`/`UV_RB`, and those really are texture coordinates -- verified
## against the artwork's own pixel size:
##
##   GDR_PLAYER_MINI_INFO  UV 0.723633,0 -> 0.930664,0.136719
##     x: 0.723633*1024 = 741, 0.930664*1024 = 953  -> 212 wide
##     y: 0            = 0,   0.136719*512  =  70   ->  70 tall
##   and its authored Rect is exactly 212x70.
##
##   GDR_PMI_STA_CINFOBG   UV 0.391602,0.300781 -> 0.523438,0.669922
##     -> 135x189, and its Rect is exactly 135x189.
##
## So the slice is 1:1 with the control, which is the same "art is authored
## at its real size" rule the rest of this format follows.
##
## An earlier version of this project's notes claimed these fields were
## always 0,0-1,1 and therefore unused. That came from reading three files.
## Across the 229 real `resinfo\\if*.txt` layouts there are 18 distinct
## `UV_LT` values and 45 controls whose `UV_RB` is not 1,1.
func load_texture_region(ddj_path: String, uv_lt: Vector2, uv_rb: Vector2) -> Texture2D:
	var tex := load_texture(ddj_path)
	if tex == null:
		return null
	if is_zero_approx(uv_lt.x) and is_zero_approx(uv_lt.y) \
			and is_equal_approx(uv_rb.x, 1.0) and is_equal_approx(uv_rb.y, 1.0):
		return tex
	var full := tex.get_size()
	var region := Rect2(
		Vector2(uv_lt.x * full.x, uv_lt.y * full.y),
		Vector2((uv_rb.x - uv_lt.x) * full.x, (uv_rb.y - uv_lt.y) * full.y)).abs()
	if region.size.x < 1.0 or region.size.y < 1.0:
		return tex
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = region
	return atlas

## The client's own UI fonts, loaded from the player's Media.pk2 at runtime.
##
## `fonts\\` in a real Media.pk2 holds three `.ttf` files (plus `vplus\\
## vfont.ttf`). Their names are Korean and survive the archive as mangled
## bytes, so they are found by extension rather than named -- which is also
## why this walks the directory instead of hardcoding a path.
##
## Nothing is committed: the font is read out of the user's own archive the
## same way every texture is, per docs/LEGAL.md.
const FONT_DIR := "fonts"

var _fonts: Array[FontFile] = []
var _fonts_loaded := false

func _load_fonts() -> void:
	if _fonts_loaded:
		return
	_fonts_loaded = true
	if _media_pk2 == null:
		return
	var dir_entry := ObjectLoader.find_file(_media_pk2, FONT_DIR)
	if dir_entry == null or not dir_entry.is_dir:
		return
	for entry in _media_pk2.read_dir_at(dir_entry):
		if entry.is_dir or not entry.name.to_lower().ends_with(".ttf"):
			continue
		var data := _media_pk2.read_file(entry)
		if data.is_empty():
			continue
		var font := FontFile.new()
		font.data = data
		if font.get_face_count() > 0:
			_fonts.append(font)

## The UI font at index (a control's `FontIndex`), or null if the archive
## has none. Out-of-range indices fall back to the first font rather than
## to Godot's default, which looks nothing like the client's.
func font_at(index: int) -> FontFile:
	_load_fonts()
	if _fonts.is_empty():
		return null
	return _fonts[index] if index >= 0 and index < _fonts.size() else _fonts[0]

## How many UI fonts the archive supplied.
func font_count() -> int:
	_load_fonts()
	return _fonts.size()

## The colour a window's interior should be, taken from its own frame
## artwork rather than chosen.
##
## No frame set in the archive has a centre piece -- all thirty-odd are
## exactly eight tiles, four corners and four edges -- so a window's body is
## not painted by its frame, and nothing hardcodes a fill texture either. An
## earlier version of this project picked a dark colour by eye and said so
## in a comment. It did not need to: the frame's own edge tiles are opaque
## and carry the colour the body continues, so reading a pixel out of them
## gives the real answer and adapts to whichever frame set a window uses.
##
## Sampled from the bottom row of `<base>mid_up.ddj`, which is the edge the
## body runs down from. Returns a transparent colour when the piece cannot
## be read, so a caller can tell "unknown" from "black".
func frame_interior_colour(ddj_base: String) -> Color:
	if ddj_base == "" or not ddj_base.ends_with("_"):
		return Color(0, 0, 0, 0)
	var tex := load_texture(ddj_base + "mid_up.ddj")
	if tex == null:
		return Color(0, 0, 0, 0)
	var image := tex.get_image()
	if image == null:
		return Color(0, 0, 0, 0)
	if image.is_compressed():
		image.decompress()
	if image.get_width() == 0 or image.get_height() == 0:
		return Color(0, 0, 0, 0)
	return image.get_pixel(image.get_width() / 2, image.get_height() - 1)

## The archive this builder reads from, for callers that need to pull data
## files out of it rather than textures.
func media_archive() -> Pk2Reader:
	return _media_pk2

func _resolve_text(key_or_text: String) -> String:
	if _text_table != null:
		return _text_table.get_text(key_or_text)
	return key_or_text

## Pixel size for each `FontIndex`, read out of the client.
##
## `FUN_00469350` builds the font table with five consecutive calls, each
## pushing a size and an index:
##
##   PUSH 0x9  PUSH 0x0   -> index 0, 9px
##   PUSH 0x8  PUSH 0x1   -> index 1, 8px
##   PUSH 0xc  PUSH 0x2   -> index 2, 12px
##   PUSH 0xb  PUSH 0x3   -> index 3, 11px
##   PUSH 0xf  PUSH 0x4   -> index 4, 15px
##
## (The two branches there pick different typefaces -- a Korean set and a
## western one -- but assign the same sizes to the same indices.)
##
## This replaces a fitted size. An earlier version of this file started at
## 12px and stepped down until each string fitted its control, because the
## layouts were clipping. They were clipping because 12px is the size of
## *index 2*, and almost every control uses index 0, which is **9**. The
## layout was always right about its box; the guess was wrong about the
## text.
const FONT_SIZES := [9, 8, 12, 11, 15]
## Used only for a FontIndex outside the table, which no real layout has.
const FONT_SIZE_FALLBACK := 9

func _apply_font(label: Label, def: UiLayoutParser.ControlDef) -> void:
	var font := font_at(def.font_index)
	if font != null:
		label.add_theme_font_override("font", font)
	var size: int = FONT_SIZES[def.font_index] if def.font_index >= 0 and def.font_index < FONT_SIZES.size() else FONT_SIZE_FALLBACK
	label.add_theme_font_size_override("font_size", size)
	# Authored rows are tight, and a runtime value longer than anything the
	# layout anticipated would still push into the row under it.
	label.clip_text = true

func _insert_suffix(path: String, suffix: String) -> String:
	var dot := path.rfind(".")
	if dot == -1:
		return path + suffix
	return path.substr(0, dot) + suffix + path.substr(dot)

func _map_halign(h: int) -> HorizontalAlignment:
	match h:
		1: return HORIZONTAL_ALIGNMENT_CENTER
		2: return HORIZONTAL_ALIGNMENT_RIGHT
		_: return HORIZONTAL_ALIGNMENT_LEFT

func _map_valign(v: int) -> VerticalAlignment:
	match v:
		1: return VERTICAL_ALIGNMENT_CENTER
		2: return VERTICAL_ALIGNMENT_BOTTOM
		_: return VERTICAL_ALIGNMENT_TOP
