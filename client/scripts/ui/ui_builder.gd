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
## Loads and parses a layout. `defines` selects `#ifdef` branches (see
## UiLayoutParser.parse); passing any turns preprocessing on. The cache key
## includes the defines so the same file can be read both ways.
func load_layout(layout_path: String, defines: PackedStringArray = PackedStringArray(),
		honor_ifdef: bool = false) -> UiLayoutParser.LayoutDef:
	var cache_key := layout_path
	if honor_ifdef:
		cache_key = "%s%s" % [layout_path, "".join(defines)]
	if _layout_cache.has(cache_key):
		return _layout_cache[cache_key]
	if _media_pk2 == null:
		return null
	var entry := ObjectLoader.find_file(_media_pk2, layout_path)
	if entry == null:
		push_warning("UiBuilder: layout %s not in Media.pk2" % layout_path)
		return null
	var layout := UiLayoutParser.parse(_media_pk2.read_file(entry), honor_ifdef, defines)
	_layout_cache[cache_key] = layout
	return layout

## The size a window built from this section should be: its frame's rect,
## extended by any **artwork** that reaches past it.
##
## The frame is the rect that starts at the origin -- ifinventory's
## GDR_INVENTORY_FRAME is `0,0,176,308` -- and a layout with no frame falls
## back to the bounding box so it does not come out zero.
##
## The frame is not always the whole window, though. ifinventory's gold row
## (GDR_INVENTORY_STA_MONEY, `0,305,176,28`, carrying
## `int_window_downbox.ddj`) hangs 25 pixels below the frame's bottom edge
## and is plainly part of the window; sized to the frame alone it fell
## outside both the window and its hit area.
##
## Only artwork extends a window, not every control. Text fields are
## authored as generous boxes and overrun: ifplayerinfo's GDR_PI_TEXT_HP_DAT
## is 228 wide starting at x=153 in a 364-wide window, so counting it made
## the character panel 381 wide for a field the client clips. Across the
## archive's 140 framed sections, artwork stays inside the frame in 103 and
## every control in only 92 -- and the sections where artwork does overrun
## are the ones, like the inventory, where it is meant to.
static func section_size(sec: UiLayoutParser.SectionDef) -> Vector2:
	var framed := Vector2.ZERO
	var art := Vector2.ZERO
	var bounds := Vector2.ZERO
	for def in sec.controls:
		var far := Vector2(def.rect.position + def.rect.size)
		bounds = Vector2(maxf(bounds.x, far.x), maxf(bounds.y, far.y))
		if def.ddj != "":
			art = Vector2(maxf(art.x, far.x), maxf(art.y, far.y))
		if def.rect.position == Vector2i.ZERO and def.rect.size.x > framed.x:
			framed = Vector2(def.rect.size)
	if framed == Vector2.ZERO:
		return bounds
	return Vector2(maxf(framed.x, art.x), maxf(framed.y, art.y))

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

	# **Back to front.** A resinfo section lists its controls in front-to-
	# back order: the window's own frame is always the *last* entry
	# (`GDR_PI_SUBFRAME` in ifplayerinfo, `GDR_INVENTORY_FRAME` in
	# ifinventory), and a frame has to be behind everything it frames.
	# Godot draws children in tree order, so the list is added reversed.
	#
	# Verified as behaviour rather than traced in the client: in file order
	# every window covered its own contents, and reversed it matches the
	# reference screenshots. On the client side the factory appends each
	# control to a list with a `_Buynode(head, head->prev, value)` -- a
	# push_back in parse order -- so for a last-declared frame to end up
	# behind everything, the renderer has to walk that list backwards. That
	# iteration has not been found, so the ordering here rests on the data
	# and the pictures, not on reading the draw loop.
	#
	# Adding them in file order put every window's frame and background
	# tiles on top of its own contents -- which is why the inventory looked
	# like an empty bordered box, and why the character panel's labels
	# vanished the moment its background tiles started being built.
	for i in range(sec.controls.size() - 1, -1, -1):
		var node := build_control(sec.controls[i])
		if node != null:
			root.add_child(node)

	return root

## Whether a `ddj` names an 8-slice base rather than a texture: the
## convention is a trailing underscore, and the pieces are that path plus
## `left_up.ddj`, `mid_up.ddj` and the rest.
static func is_slice_base(ddj: String) -> bool:
	return ddj != "" and ddj.ends_with("_")

## Builds a single Godot node corresponding to a ControlDef.
##
## **The artwork decides before the type does**, for one case. A `ddj`
## ending in an underscore is not a texture: it is an 8-slice base that
## expands into corners and edges. 496 controls across the archive name
## one, spread over 220 different type names -- `CIFSkillBoard`,
## `CIFCommunity`, `CIFGuild`, `CIFBarWnd`, `CIFJobRankSlot` and two
## hundred more, most of them appearing once. Matching on the type name
## reached four of them and built the rest as empty Controls, which is why
## the skill, quest and guild windows came out see-through: ifskill's
## `GDR_SKILL_BOARD` is a `CIFSkillBoard` carrying
## `interface\inventory\int_window_` over 351x270 of a 364x333 window.
##
## Reading the suffix instead covers all 496 and cannot go stale as new
## type names turn up. `CIFLattice` is the one exception and is matched
## first: its base expands into four *cell* pieces, not eight frame ones.
func build_control(def: UiLayoutParser.ControlDef) -> Control:
	var node: Control = null

	if def.type == "CIFLattice":
		node = _build_lattice(def)
	elif is_slice_base(def.ddj):
		node = _build_frame(def)
	else:
		match def.type:
			"CIFButton", "CIFCloseButton":
				node = _build_button(def)
			"CIFStatic", "CIFDecoratedStatic", "CIFBarWnd":
				node = _build_static(def)
			"CIFGauge":
				node = _build_gauge(def)
			"CIFFrame", "CIFStretchWnd", "CIFSubFrame":
				node = _build_frame(def)
			"CIFNormalTile":
				node = _build_tile(def)
			"CIFEdit", "CIFEInputChatBox":
				node = _build_edit(def)
			_ when def.type.contains("Slot"):
				# Matched on the name rather than listed: the archive has
				# fifteen slot types and the four that were listed reached
				# neither the party-match rows nor the stall network's.
				node = _build_slot(def)
			_:
				# Generic container for unhandled or compound control types
				node = _build_generic(def)

	if node != null:
		node.name = def.name
		node.position = Vector2(def.rect.position)
		if def.rect.size.x > 0 and def.rect.size.y > 0:
			# The meta records what the layout *asked for*, not `node.size`:
			# the assignment on the next line is clamped up to the node's
			# minimum, so reading it back stores the inflated size and the
			# settling pass then re-applies the very number it exists to fix.
			node.set_meta(AUTHORED_RECT_META, Rect2(Vector2(def.rect.position), Vector2(def.rect.size)))
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
				node.set_meta(AUTHORED_RECT_META, Rect2(Vector2(def.rect.position), natural))
				node.size = natural
				node.custom_minimum_size = natural

	return node

## Where build_control stashes the rect the layout asked for.
const AUTHORED_RECT_META := "srrevamp_authored_rect"

## Re-applies every authored rect, after the tree has settled.
##
## Godot clamps `Control.size` up to the node's combined minimum size, and
## for a Label that minimum is computed from the theme's *default* font
## until the theme cache refreshes -- which does not happen until the node
## has been in the tree for a frame. Assigning the rect at build time
## therefore silently inflated every authored row: ifplayerinfo's
## GDR_PI_TEXT_CURXP is `65x12` and came out `65x23`, the height of Godot's
## own 16px face, and the close button of every window came out twice as
## tall as it was asked to be.
##
## The same clamp caught the background tiles for a different reason -- a
## TextureRect's minimum is its texture -- which is why GDR_PI_BG_TILE_D,
## authored `332x37` over a 128x128 tile, covered 332x128 and buried the
## rows under it. That one is fixed at the source (EXPAND_IGNORE_SIZE);
## this pass is for the rest.
static func apply_authored_rects(root: Node) -> void:
	if root is Control and root.has_meta(AUTHORED_RECT_META):
		var rect: Rect2 = root.get_meta(AUTHORED_RECT_META)
		var ctrl := root as Control
		ctrl.custom_minimum_size = Vector2.ZERO
		ctrl.position = rect.position
		ctrl.size = rect.size
	for child in root.get_children():
		apply_authored_rects(child)

## The size of a control's own artwork, or zero if it has none.
func _natural_size(def: UiLayoutParser.ControlDef) -> Vector2:
	var art := def.ddj
	if art == "" and def.type == "CIFCloseButton":
		art = CLOSE_BUTTON_DDJ
	if art == "":
		return Vector2.ZERO
	var tex := load_texture(art)
	if tex == null:
		return Vector2.ZERO
	return tex.get_size()

## The close button's artwork when its layout names none, which four of the
## archive's six CIFCloseButtons do not. The client's own close-button class
## hardcodes this path and builds its focus and press states from the usual
## suffixes.
const CLOSE_BUTTON_DDJ := "interface\\ifcommon\\com_windowclose.ddj"

func _build_button(def: UiLayoutParser.ControlDef) -> TextureButton:
	var btn := TextureButton.new()
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_SCALE

	var art := def.ddj
	if art == "" and def.type == "CIFCloseButton":
		art = CLOSE_BUTTON_DDJ
	if art != "":
		btn.texture_normal = load_texture_region(art, def.uv_lt, def.uv_rb)

		# State textures convention: _focus, _press, _disable
		var focus_path := _insert_suffix(art, "_focus")
		var press_path := _insert_suffix(art, "_press")
		var disable_path := _insert_suffix(art, "_disable")

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

## Artwork from this directory is a repeating pattern, whatever control
## names it. A `CIFStatic` carrying one -- ifguild's `GDR_GUILD_BG` is
## `com_bg_tile_b.ddj` over 403x58 -- means the author used the tile art as
## a plain image, and stretching a 128x128 damask across it smears the
## pattern instead of repeating it.
const TILE_DIR := "bg_tile\\"

func _build_static(def: UiLayoutParser.ControlDef) -> Control:
	if def.ddj != "":
		var rect := TextureRect.new()
		rect.texture = load_texture_region(def.ddj, def.uv_lt, def.uv_rb)
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_TILE if def.ddj.contains(TILE_DIR) else TextureRect.STRETCH_SCALE
		# A static is decorative and must not take the click itself: a
		# TextureRect stops mouse input by default, so a window's own
		# artwork was swallowing clicks meant for the window -- which is
		# what makes a window draggable by its frame, and what lets it
		# block the world behind it. The frame slices and tiles already do
		# this; statics were the outlier.
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
			_apply_font(label, def)
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

func _build_frame(def: UiLayoutParser.ControlDef) -> Control:
	var container := Control.new()
	container.mouse_filter = Control.MOUSE_FILTER_PASS

	if def.ddj != "" and def.ddj.ends_with("_"):
		# **Not every base is an 8-slice.** `com_bar01_`, `com_bar01select_`
		# and `com_bar02_` expand to `left`, `mid` and `right` -- a
		# horizontal 3-slice, 4x24 caps around a 24x24 middle -- and looking
		# for `left_up.ddj` under them finds nothing, which left every list
		# row and every CIFBarWnd drawing an empty box. Which scheme a base
		# uses is a question the archive answers: ask it for the corner.
		if load_texture(def.ddj + "left_up.ddj") == null:
			_add_row_bar_from(container, def.ddj, Vector2(def.rect.size))
			return container

		# 8-slice border: left_up, mid_up, right_up, left_side, right_side, left_down, mid_down, right_down
		var lu := load_texture(def.ddj + "left_up.ddj")
		var mu := load_texture(def.ddj + "mid_up.ddj")
		var ru := load_texture(def.ddj + "right_up.ddj")
		var ls := load_texture(def.ddj + "left_side.ddj")
		var rs := load_texture(def.ddj + "right_side.ddj")
		var ld := load_texture(def.ddj + "left_down.ddj")
		var md := load_texture(def.ddj + "mid_down.ddj")
		var rd := load_texture(def.ddj + "right_down.ddj")

		# A six-piece set has no horizontal edge art of its own, and the
		# client reuses the vertical pieces for the top and bottom:
		# **left_side draws the left and the top, right_side the right and
		# the bottom.**
		#
		# Read out of the client rather than reasoned about. Its loader for
		# these sets fills four edge slots from the two textures, taking
		# `left_side` twice and then `right_side` twice, and the function
		# that lays the quads out writes each slot's four vertices in turn:
		# the first spans the full height at x = right - w (the left edge),
		# the second the full width at y = bottom - h (the top), the third
		# is the opposite vertical and the fourth the opposite horizontal.
		# So the slot order is left, top, right, bottom, and the pairing
		# follows.
		#
		# `com_lattice_outline_` is the set in play here -- the border the
		# inventory draws around its item grid -- four corners and two
		# sides, all 4x4.
		if mu == null and ls != null:
			mu = ls
		if md == null and rs != null:
			md = rs

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

## The artwork a list row draws itself with, and the one it uses when it is
## the selected row.
##
## Straight out of the client: one method on a row slot sets
## `interface\\ifcommon\\com_bar01_` when the row is unselected and
## `com_bar01select_` when it is, and six classes carry the same pair. It is
## a horizontal 3-slice -- `_left` and `_right` are 4x24, `_mid` is 24x24,
## all fully opaque.
##
## This is what fills a list body. ifpartymatch draws a `com_blacksquare_`
## border around its list and declares **no** fill behind it, while
## declaring `com_bg_tile_e` behind each of its three small black input
## boxes in the same section -- the big one is left empty because the rows
## fill it.
const ROW_BAR_DDJ := "interface\\ifcommon\\com_bar01_"
const ROW_BAR_SELECTED_DDJ := "interface\\ifcommon\\com_bar01select_"

## Where a slot stops being an item square and starts being a list row.
##
## Measured, not chosen: across the archive every slot control that names no
## artwork is either exactly 1.0 wide-to-tall (335 of them -- CIFSlotWithHelp,
## CIFExtQuickSlotSlot, CIFSlotWithHelpForPackage, CIFSkillSlot) or at least
## 3.5 (58 of them -- CIFPartyMatchSlot and CIFMentorMatchSlot at 29.8,
## CIFStallNetworkSlot at 20.3, down to CIFEquipSkillSlotWnd at 3.5). There
## is nothing in between, so this sits in an empty gap rather than on a
## judgement call. See tools/sweep_slot_shapes.gd.
const ROW_SLOT_ASPECT := 3.0

## Whether a slot's authored rect is a list row rather than an item square.
static func is_row_slot(rect: Rect2i) -> bool:
	return rect.size.y > 0 and float(rect.size.x) / float(rect.size.y) >= ROW_SLOT_ASPECT

## One item cell. `background` overrides the control's own `ddj`, which is
## how a lattice hands each cell the piece its position calls for -- a
## lattice's `ddj` is an 8-slice-style base and is not loadable as a single
## texture, so a cell built from it came out empty. That is why the
## inventory was a bordered hole with the world showing through it.
func _build_slot(def: UiLayoutParser.ControlDef, background: Texture2D = null,
		cell_size: Vector2 = Vector2.ZERO) -> Control:
	var slot := Control.new()
	slot.mouse_filter = Control.MOUSE_FILTER_PASS
	# The three layers are anchored to fill the slot, but they are also sized
	# outright: a Control does not lay its children out until it has been in
	# the tree and resized, and a lattice cell is built, filled and measured
	# before any of that happens.
	var inner: Vector2 = cell_size if cell_size != Vector2.ZERO else Vector2(def.rect.size)
	# The slot is given its final size outright (its own or the lattice cell's)
	# so the FULL_RECT children below fill a real rectangle, and nothing they
	# hold can spill past it.
	slot.size = inner
	slot.custom_minimum_size = inner
	slot.clip_contents = true

	var art: Texture2D = background
	if art == null and def.ddj != "" and not is_slice_base(def.ddj):
		art = load_texture_region(def.ddj, def.uv_lt, def.uv_rb)
	# A list row with no artwork of its own draws the client's own row bar.
	if art == null and background == null and def.ddj == "" and is_row_slot(def.rect):
		_add_row_bar(slot, inner)
	if art != null:
		var bg := TextureRect.new()
		bg.name = "SlotBg"
		bg.texture = art
		# Anchors AND offsets, so each layer exactly fills the slot no matter
		# when the slot is sized. Setting size alone against a still-zero-size
		# parent baked a +inner offset into the far anchors, which then doubled
		# the child once the slot grew (a 32px slot showed a 64px icon).
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(bg)

	var icon := TextureRect.new()
	icon.name = "ItemIcon"
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(icon)

	var count_lbl := Label.new()
	count_lbl.name = "CountLabel"
	count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count_lbl.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count_lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	count_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_font(count_lbl, def)
	slot.add_child(count_lbl)

	return slot

## Cell pitch when a lattice names no artwork, in pixels. Every lattice in
## the archive does name artwork, so this is only a floor.
const LATTICE_CELL_FALLBACK := 36

## The four cell pieces of a lattice, in the order the client loads them.
##
## `CIFLattice`'s ddj is an 8-slice-style base with a trailing underscore --
## every one of them is `interface\\ifcommon\\lattice_window\\com_lattice_`,
## which is also hardcoded in the client as the default -- but unlike a
## frame it expands to only **four** names. The client's loader for it takes
## exactly `left_up`, `right_up`, `right_down`, `left_down` and nothing else,
## against the eight a frame takes and the six a stretch window takes.
##
## The four are not corners. They are one cell each, differing only in which
## separators they carry, because a grid's cells share their dividers:
##
##   left_up     opaque to its edges -- draws the divider on its right and
##               the bar under it, so it serves every interior cell
##   right_up    right 4 columns transparent -- last column, no divider
##   left_down   bottom 4 rows transparent -- last row, no bar
##   right_down  both transparent -- the bottom-right cell
##
## (Measured from the art's alpha: 0, 144, 144 and 272 fully transparent
## pixels respectively, out of 36x36.)
const LATTICE_PIECES := ["left_up.ddj", "right_up.ddj", "left_down.ddj", "right_down.ddj"]

## Builds a slot grid: the inventory's item cells, and the same control in
## storage, stalls, exchange and the action bar.
##
## **The grid comes from the artwork, not from a count.** The layout gives a
## lattice a pixel rect and nothing else, and the cell is one piece of its
## own art -- 36x36 for `com_lattice_`. Every one of the 14 lattices in the
## archive divides by that exactly, in both axes and with no remainder:
## inventory 4x8, storage and stalls 6x5, exchange 6x2, the action bar 9x2
## and 4x2, the pet bag 7x4. Not one of them divides by 32, which is what
## this used to assume.
func _build_lattice(def: UiLayoutParser.ControlDef) -> Control:
	var grid := Control.new()
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var pieces: Array[Texture2D] = []
	for suffix in LATTICE_PIECES:
		pieces.append(load_texture(def.ddj + suffix) if def.ddj.ends_with("_") else null)

	var cell := LATTICE_CELL_FALLBACK
	if pieces[0] != null:
		cell = maxi(1, int(pieces[0].get_width()))

	var cols: int = maxi(1, def.rect.size.x / cell)
	var rows: int = maxi(1, def.rect.size.y / cell)
	for row in range(rows):
		for col in range(cols):
			var last_col := col == cols - 1
			var last_row := row == rows - 1
			var piece: Texture2D = pieces[(2 if last_row else 0) + (1 if last_col else 0)]
			var slot := _build_slot(def, piece, Vector2(cell, cell))
			slot.name = "Cell%d" % (row * cols + col)
			slot.position = Vector2(col * cell, row * cell)
			slot.size = Vector2(cell, cell)
			slot.custom_minimum_size = slot.size
			grid.add_child(slot)
	return grid

## Builds a tiled background panel.
##
## **This is what fills a window's body.** No 8-slice frame set in the
## archive has a centre piece -- confirmed twice, and confirmed a third time
## in the client itself, where `CNIFFrame` loads exactly eight suffixes
## (`left_up`, `mid_up`, `right_up`, `left_side`, `right_side`, `left_down`,
## `mid_down`, `right_down`) and no ninth. The interior is not the frame's
## job at all: the layout declares `CIFNormalTile` controls over the body,
## carrying textures from `interface\\ifcommon\\bg_tile\\`, and those tile to
## fill it. ifplayerinfo.txt has three, covering the panel between its
## decorative dividers.
##
## `CIFNormalTile` is the fourth most common control type in the archive --
## **253** across the layouts -- and building it as a plain Control, which
## is what happened before, is why every window came out hollow. Two rounds
## were spent inventing an interior colour and then deriving one from the
## frame's edge pixels; neither was necessary.
func _build_tile(def: UiLayoutParser.ControlDef) -> TextureRect:
	var tile := TextureRect.new()
	tile.texture = load_texture_region(def.ddj, def.uv_lt, def.uv_rb)
	tile.stretch_mode = TextureRect.STRETCH_TILE
	# Without this the node's minimum size is the tile's own -- 128x128 --
	# and an authored strip smaller than that grows to fit it. That is what
	# made GDR_PI_BG_TILE_D, a 37-pixel band, cover 128 pixels of the
	# character panel and hide the rows beneath.
	tile.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tile

## Lays the three pieces of a row bar across `size`: a left cap, the middle
## tiled, and a right cap, each at its own authored width.
func _add_row_bar(parent: Control, bar_size: Vector2) -> void:
	_add_row_bar_from(parent, ROW_BAR_DDJ, bar_size)

## The same, from any horizontal 3-slice base.
func _add_row_bar_from(parent: Control, base: String, bar_size: Vector2) -> void:
	if bar_size.x <= 0.0 or bar_size.y <= 0.0:
		return
	var left := load_texture(base + "left.ddj")
	var mid := load_texture(base + "mid.ddj")
	var right := load_texture(base + "right.ddj")
	if mid == null:
		return
	var cap_w := float(left.get_width()) if left != null else 0.0
	var cap_r := float(right.get_width()) if right != null else 0.0
	var bar := Control.new()
	bar.name = "RowBar"
	bar.size = bar_size
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_add_slice(bar, left, Rect2(0.0, 0.0, cap_w, bar_size.y))
	_add_slice(bar, mid, Rect2(cap_w, 0.0, bar_size.x - cap_w - cap_r, bar_size.y), true)
	_add_slice(bar, right, Rect2(bar_size.x - cap_r, 0.0, cap_r, bar_size.y))
	parent.add_child(bar)

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

## The client's UI typeface, chosen the way the client chooses it.
##
## The client does not pick a font per `FontIndex`; it picks ONE face by name
## and builds every index from it at a different size. Read out of the binary
## (docs/rounds/ui.md has the addresses):
##
## - `Game.cpp` walks `fonts\\` in Media.pk2, extracts each file to a hidden
##   file on disk and registers it with `AddFontResourceA`
##   (`gfxmainframe::FUN_00ba60b0`), so the bundled faces are installed.
## - The font-table builder `FUN_00469350` receives the face name from its
##   caller, which looks it up in the UI text table: `FUN_008c9c30(
##   L"UIC_STT_FONTNAME")`. A NULL name falls back to the literal at
##   `0xe172d8`, CP949 `b1bc b8b2 c3bc` = "굴림체" (GulimChe). The same name
##   is in ESI for all five `GNFontChar::FUN_004927b0(index, size)` calls.
## - `FUN_00baa110` then does `CreateFontIndirectA` with that `lfFaceName`.
##
## In a real Media.pk2 `UIC_STT_FONTNAME` is **Tahoma** in the English column
## ("굴림체" in the Korean one; an older row says Arial). The bundled files
## are TaeUtum, SeUtum, Arial Rounded MT Bold (`fonts\\`) and Arial
## (`vplus\\vfont.ttf`) -- none is Tahoma, which is a Windows system font, so
## the real client renders the English UI in the *system's* Tahoma.
##
## Resolution, in the client's own order: a bundled file whose family IS the
## named face; else the system's font of that name (what the real client
## gets on Windows); else -- DISCLOSED, ours -- Arial from `vplus\\vfont.ttf`,
## the archive's other authored value for this same key, so a machine
## without Tahoma still draws a plain sans from the archive rather than
## Godot's default. A system match is accepted only if the file's own family
## name is the one asked for: fontconfig hands back a substitute (DejaVu Sans
## for Tahoma) rather than nothing, and that must not pass as the real face.
##
## Nothing is committed: faces come from the user's own archive or their own
## operating system, per docs/LEGAL.md.
const FONT_DIR := "fonts"
const FONT_FALLBACK_FILE := "vplus\\vfont.ttf"
const FONT_NAME_KEY := "UIC_STT_FONTNAME"
## The binary's own default when the text table has no name (`0xe172d8`).
const FONT_NAME_BINARY_DEFAULT := "굴림체"
## The face the disclosed fallback file carries, named so a log reads plainly.
const FONT_FALLBACK_FAMILY := "Arial"

var _ui_font: FontFile = null
var _ui_font_source := ""
var _fonts_loaded := false

## The face name the client would ask GDI for: the text table's
## `UIC_STT_FONTNAME`, else the binary's default.
func ui_face_name() -> String:
	var name := ""
	if _text_table != null:
		name = _text_table.get_text(FONT_NAME_KEY, "")
		if name == FONT_NAME_KEY:
			name = ""
	elif _media_pk2 != null:
		# A builder made without a text table (the login screen builds one
		# just for the font) still gets the archive's answer: only that one
		# row is scanned, not the whole 3.5 MB table parsed.
		name = _scan_face_name_row()
	return name if name != "" else FONT_NAME_BINARY_DEFAULT

func _scan_face_name_row() -> String:
	var entry := ObjectLoader.find_file(_media_pk2, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	if entry == null:
		return ""
	var text := _media_pk2.read_file(entry).get_string_from_utf16()
	var at := text.find("\t" + FONT_NAME_KEY + "\t")
	while at != -1:
		var line_start := text.rfind("\n", at) + 1
		var line_end := text.find("\n", at)
		var line := text.substr(line_start, (line_end if line_end != -1 else text.length()) - line_start)
		var picked := UiTextTable._pick_language_column(line.strip_edges().split("\t"), UiTextTable.COL_ENGLISH)
		if picked != "":
			return picked
		at = text.find("\t" + FONT_NAME_KEY + "\t", at + 1)
	return ""

func _new_font(data: PackedByteArray) -> FontFile:
	if data.is_empty():
		return null
	var font := FontFile.new()
	font.data = data
	if font.get_face_count() == 0:
		return null
	# The reference client's text is aliased: every glyph pixel in the
	# reference screenshots is one luminance level (measured, round in
	# docs/rounds/ui.md). GDI drew it at integer pixel positions with the
	# face's own hints. These are Godot's settings for that same look; the
	# aliasing is measured, the hinting/subpixel choice is the analog of
	# GDI's behaviour, not a value read from the binary.
	font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	font.hinting = TextServer.HINTING_NORMAL
	font.force_autohinter = false
	font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	return font

func _bundled_fonts() -> Dictionary:
	# family name (lower) -> FontFile, for every font file the archive carries.
	var found := {}
	if _media_pk2 == null:
		return found
	var dir_entry := ObjectLoader.find_file(_media_pk2, FONT_DIR)
	if dir_entry != null and dir_entry.is_dir:
		for entry in _media_pk2.read_dir_at(dir_entry):
			if entry.is_dir or not entry.name.to_lower().ends_with(".ttf"):
				continue
			var font := _new_font(_media_pk2.read_file(entry))
			if font != null:
				found[font.get_font_name().to_lower()] = font
	var vfont := ObjectLoader.find_file(_media_pk2, FONT_FALLBACK_FILE)
	if vfont != null:
		var font := _new_font(_media_pk2.read_file(vfont))
		if font != null and not found.has(font.get_font_name().to_lower()):
			found[font.get_font_name().to_lower()] = font
	return found

func _system_font(face: String) -> FontFile:
	var path := OS.get_system_font_path(face)
	if path == "" or not FileAccess.file_exists(path):
		return null
	var font := _new_font(FileAccess.get_file_as_bytes(path))
	# Only the face that was asked for; a fontconfig substitute is not it.
	if font == null or font.get_font_name().to_lower() != face.to_lower():
		return null
	_ui_font_source = "system font %s" % path
	return font

func _load_fonts() -> void:
	if _fonts_loaded:
		return
	_fonts_loaded = true
	if _media_pk2 == null:
		return
	var face := ui_face_name()
	var bundled := _bundled_fonts()
	if bundled.has(face.to_lower()):
		_ui_font = bundled[face.to_lower()]
		_ui_font_source = "bundled in the archive"
	else:
		_ui_font = _system_font(face)
	if _ui_font == null and bundled.has(FONT_FALLBACK_FAMILY.to_lower()):
		_ui_font = bundled[FONT_FALLBACK_FAMILY.to_lower()]
		_ui_font_source = "'%s' not installed -- disclosed fallback %s (%s)" % [face, FONT_FALLBACK_FILE, FONT_FALLBACK_FAMILY]
	if _ui_font == null and not bundled.is_empty():
		_ui_font = bundled.values()[0]
		_ui_font_source = "'%s' not installed -- first bundled face" % face
	if _ui_font == null:
		print("UiBuilder: UI face '%s' (%s): no font available -- Godot's default" % [face, FONT_NAME_KEY])
		return
	print("UiBuilder: UI face '%s' (%s) -> %s (family '%s'); sizes px %s" % [
		face, FONT_NAME_KEY, _ui_font_source, _ui_font.get_font_name(), str(FONT_SIZES)])

## The UI font for a control's `FontIndex`. One face serves every index --
## the client builds all five from the same name -- so the index only ever
## selects a size (FONT_SIZES); it is kept in the signature because that is
## what a layout carries. Null only if the archive has no font at all.
func font_at(_index: int) -> FontFile:
	_load_fonts()
	return _ui_font

## How many UI fonts are in play: one, or none.
func font_count() -> int:
	_load_fonts()
	return 1 if _ui_font != null else 0

## The archive this builder reads from, for callers that need to pull data
## files out of it rather than textures.
func media_archive() -> Pk2Reader:
	return _media_pk2

## The UI text table this builder resolves keys through, for a caller that
## needs to resolve names itself (a mastery's own name, say).
func text_table() -> UiTextTable:
	return _text_table

## Resolves a `UIIT_*` key through the client's own text table, or returns
## the string unchanged when it is not a key. Public because a window's
## caption comes from its frame's `Text` and is resolved the same way.
func resolve_text(key_or_text: String) -> String:
	return _resolve_text(key_or_text)

func _resolve_text(key_or_text: String) -> String:
	if _text_table != null:
		return _text_table.get_text(key_or_text)
	return key_or_text

## The size of each `FontIndex`, read out of the client -- in the unit the
## client actually uses.
##
## `FUN_00469350` registers the five indices with `GNFontChar::FUN_004927b0
## (index, size)`: (0, 9), (1, 8), (2, 12), (3, 11), (4, 15). Those are
## **points**, not pixels: the creator `FUN_00baa110` fills a LOGFONTA with
##
##   lfHeight = -MulDiv(size, 0x60, 0x48)     i.e.  -(size * 96 / 72)
##
## a hardcoded 96 dpi, and a negative lfHeight is the em height in pixels.
## So index 0 is 9pt = a 12px em, which is also what the reference
## screenshots measure (a 9-row cap height on Tahoma; a 12px em gives 8.7px,
## a 9px em 6.5px -- docs/rounds/ui.md). An earlier version used the point
## values as pixel sizes, which is why every window's text was a third too
## small for its authored box.
##
## Per index the client also creates a bold (weight 600) variant; which
## controls draw with it is not recovered, so none is applied here.
const FONT_POINT_SIZES := [9, 8, 12, 11, 15]
## MulDiv rounds to nearest: 9->12, 8->10.67->11, 12->16, 11->14.67->15, 15->20.
const FONT_SIZES := [12, 11, 16, 15, 20]
## Used only for a FontIndex outside the table, which no real layout has.
const FONT_SIZE_FALLBACK := 12

func _apply_font(label: Label, def: UiLayoutParser.ControlDef) -> void:
	var font := font_at(def.font_index)
	if font != null:
		label.add_theme_font_override("font", font)
	var size: int = FONT_SIZES[def.font_index] if def.font_index >= 0 and def.font_index < FONT_SIZES.size() else FONT_SIZE_FALLBACK
	label.add_theme_font_size_override("font_size", size)
	# Not clipped to the authored rect, because the client does not clip:
	# in the reference screenshot "Phy. balance" is 63.8px wide and "Mag.
	# balance" 65.7px, drawn in GDR_PI_TEXT_PHYBAL / _MAGBAL rects that are
	# 58 wide (the same overrun rule 13 of UI_TODO.md records for
	# TEXT_HP_DAT). Clipping here cut them to "Phy. balan". A long string
	# runs out to the right, as it does in the original; nothing wraps.
	label.clip_text = false

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
