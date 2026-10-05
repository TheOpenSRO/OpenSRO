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
## The registry's raw text (bytes, or a String in a test), kept so an entry
## can be read again with `#ifdef` branches selected; and those parses, by
## their defines.
var _window_registry_data: Variant = null
var _window_registry_by_defines: Dictionary = {}
var _layout_cache: Dictionary = {} # String -> UiLayoutParser.LayoutDef

## The client's `#ifdef` symbol table (round 725; docs/protocol/npc_gui.md
## §0). READ: at start-up CGame opens `config\define.txt` through the archive
## reader (`push 0xdd3d60` at 0x848210) and writes each name it lists into the
## std::map at [CGame]+0x660 = 0xeed4e0 (0x6441b0, 0x848355..0x8483ba), with
## the value 0 or absent forced to 1 ("%s Value 0 => 1"). READ (round 725's
## review): the layout parser's `#ifdef` (IFTVariable::FUN_00b37a30, case 1)
## asks IFTVariable::FUN_005004a0, which looks the name up in that same map
## (`mov ecx,0xeed4e0` at 0x500502) and answers 0 for an absent name. The
## archive's copy defines 22 names, RENEWAL_SHOP_SYSTEM and
## RESTORE_SOLDITEM_INSHOP among them.
const DEFINE_TXT_PATH := "config\\define.txt"
## null until read; a test may set it.
var _archive_defines: Variant = null

## The names `config\define.txt` defines, read once from the archive. Empty
## with no archive or no file.
func archive_defines() -> PackedStringArray:
	if _archive_defines == null:
		# Cached only once the archive is open, so an early call does not
		# leave the table empty for good.
		if _media_pk2 == null:
			return PackedStringArray()
		_archive_defines = PackedStringArray()
		var entry := ObjectLoader.find_file(_media_pk2, DEFINE_TXT_PATH)
		if entry != null:
			_archive_defines = parse_define_txt(_media_pk2.read_file(entry))
	return _archive_defines

## The names a define.txt lists, as the client's loader reads it (READ,
## round 725's review): each line is split on `=`, `"`, `,`, space and tab
## (0x401070 with 0x3d, 0x22, 0x2c, 0x20, 0x09 at 0x8482e4..0x848341) and its
## first token is a name. Every listed name is defined, `NAME = 0` included
## (the loader forces a 0 value to 1). There is no comment handling: a
## `// Define String` line defines the token `//`, which no layout tests.
## Bytes are read one per character (the file is ANSI; the names are ASCII).
## A line's trailing CR is dropped (OURS: the review measured the archive's
## CRLF file giving the same 22 names in the client).
static func parse_define_txt(data: PackedByteArray) -> PackedStringArray:
	var out := PackedStringArray()
	var token := ""
	var first := true
	for i in data.size() + 1:
		var b: int = data[i] if i < data.size() else 0x0a
		if b == 0x0a or b == 0x0d or b == 0x3d or b == 0x22 or b == 0x2c or b == 0x20 or b == 0x09:
			if token != "" and first:
				if not out.has(token):
					out.append(token)
				first = false
			token = ""
			if b == 0x0a:
				first = true
			continue
		token += String.chr(b)
	return out

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

## Parsed `res_ui\*.2dt` window files by archive path (TwoDtReader). A test
## puts synthetic ones here; nothing is committed from the archive.
var _twodt_cache: Dictionary = {}

## Loads and caches a `.2dt` window file from Media.pk2 by its archive path
## (e.g. "res_ui\\guild.2dt"). Null if it is not there or does not parse.
func load_2dt(path: String) -> TwoDtReader.TwoDtFile:
	var key := path.to_lower()
	if _twodt_cache.has(key):
		return _twodt_cache[key]
	if _media_pk2 == null:
		return null
	var entry := ObjectLoader.find_file(_media_pk2, path)
	if entry == null:
		push_warning("UiBuilder: %s not in Media.pk2" % path)
		return null
	var file := TwoDtReader.parse(_media_pk2.read_file(entry))
	if file != null:
		_twodt_cache[key] = file
	return file

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
##
## **Art is measured at the size it is drawn.** A zero-size rect means "the
## artwork's own size" (build_control draws it so), and ignoring those let
## the party, academy and alchemy windows' buttons and the guild window's
## 588x108 header and 376-wide GP bar hang outside a window sized without
## them. Reading a natural size needs the archive, so a caller passes its
## builder; with none, zero-size art counts only as the point it is placed
## at, as before.
##
## **Parked controls are skipped.** ifexchange declares 13 controls at
## `x = 9999` -- the message box and its two backings (under
## `#ifdef UI_UPDATE_2009_FIRST`), the six avatar-view controls (under
## `APPLY_EXCHANGE_UPDATE_1TH`) and the two `ch_line.ddj` dividers -- and
## counting them made the Exchange window 10344 wide, which centred it at
## x = -4222. 9999 is the only such coordinate in the archive: across all
## 229 `resinfo\if*.txt` layouts no other control reaches past x = 864
## (ifunderbar's `800,0,64,52`) or y = 652. Whether the client moves them
## into view later is not read; they are built where the layout puts them,
## and only the window's size ignores them.
static func section_size(sec: UiLayoutParser.SectionDef, builder: UiBuilder = null) -> Vector2:
	var framed := Vector2.ZERO
	var art := Vector2.ZERO
	var bounds := Vector2.ZERO
	for def in sec.controls:
		if is_parked(def.rect):
			continue
		var extent := Vector2(def.rect.size)
		var natural := false
		if (def.rect.size.x <= 0 or def.rect.size.y <= 0) and builder != null:
			var art_size := builder._natural_size(def)
			if art_size != Vector2.ZERO:
				extent = art_size
				natural = true
		var far := Vector2(def.rect.position) + extent
		bounds = Vector2(maxf(bounds.x, far.x), maxf(bounds.y, far.y))
		if def.ddj != "" or natural:
			art = Vector2(maxf(art.x, far.x), maxf(art.y, far.y))
		if def.rect.position == Vector2i.ZERO and def.rect.size.x > framed.x:
			framed = Vector2(def.rect.size)
	if framed == Vector2.ZERO:
		return bounds
	return Vector2(maxf(framed.x, art.x), maxf(framed.y, art.y))

## Where a layout parks a control it does not show: `x = 9999`, used by 13 of
## ifexchange's controls and by nothing else in the archive (see
## section_size).
const PARKED_X := 9999

static func is_parked(rect: Rect2i) -> bool:
	return rect.position.x >= PARKED_X

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
##
## **Every section is searched, "Create" first.** The client builds "Create"
## once, in `CGInterface::Create` (0x78c910: `resinfo\ginterface.txt` pushed
## at 0x78c9ce, the section built at 0x78c9ff), and the other sections by name
## when a window is first wanted: "PartyMatch" at 0x79c1e5, "AutoPotion" at
## 0x79c7a4 and "GameGuide" at 0x79b191, each built on the same layout
## object and followed by a fetch of that entry's own ID (0x82, 0x87, 0x20 --
## GDR_PARTY_MATCH's 130, GDR_AUTO_POTION's 135, GDR_GAMEGUIDE's 32). Looking
## in "Create" alone found none of the three.
##
## `defines` selects the registry's `#ifdef` branches (UiLayoutParser.parse),
## for an entry whose rect differs by branch -- GDR_EXCHANGE, GDR_STORE. With
## none the parse reads every branch, and a property given in several
## branches keeps the last one's value.
func window_def(window_name: String, defines: PackedStringArray = PackedStringArray(),
		honor_ifdef: bool = false) -> UiLayoutParser.ControlDef:
	if not _window_registry_loaded:
		_window_registry_loaded = true
		if _media_pk2 != null:
			var entry := ObjectLoader.find_file(_media_pk2, WINDOW_REGISTRY_PATH)
			if entry != null:
				_window_registry_data = _media_pk2.read_file(entry)
				_window_registry = UiLayoutParser.parse(_window_registry_data)
	var registry := _window_registry
	if honor_ifdef:
		if _window_registry_data == null:
			return null
		var key := ",".join(defines)
		if not _window_registry_by_defines.has(key):
			_window_registry_by_defines[key] = UiLayoutParser.parse(_window_registry_data, true, defines)
		registry = _window_registry_by_defines[key]
	if registry == null:
		return null
	var first := registry.sections.get("Create") as UiLayoutParser.SectionDef
	if first != null and first.control_by_name.has(window_name):
		return first.control_by_name[window_name]
	for sec_name in registry.sections:
		var sec: UiLayoutParser.SectionDef = registry.sections[sec_name]
		if sec.control_by_name.has(window_name):
			return sec.control_by_name[window_name]
	return null

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
			"CIFSpinButtonCtrl":
				node = _build_spin(def)
			_ when def.type.contains("Slot"):
				# Matched on the name rather than listed: the archive has
				# fifteen slot types and the four that were listed reached
				# neither the party-match rows nor the stall network's.
				node = _build_slot(def)
			_:
				# Generic container for unhandled or compound control types
				node = _build_generic(def)

	if node != null and def.type == "CIFSubFrame" and def.text != "":
		_add_subframe_caption(node, def)

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
		for caption_name in ["Text", "ButtonLabel"]:
			var caption := node.get_node_or_null(caption_name) as Label
			if caption != null and caption.has_meta(STATIC_TEXT_META):
				_lay_caption(node, caption)
		# READ: the resinfo builder hides a control whose Style has bit 0x40
		# as it creates it (0x8b5710..0x8b5726: 0x652da0(0x40), then vslot
		# 0x5c ShowWindow(0)). 92 of the archive's 3,754 resinfo controls
		# carry it; the client shows each one from code when it applies (the
		# minimap's dungeon ring in a dungeon, the party leader's mark on the
		# leader). A window that shows one sets it visible itself.
		if def.style & STYLE_HIDDEN_AT_CREATION:
			node.visible = false

	return node

const STYLE_HIDDEN_AT_CREATION := 0x40

## Where build_control stashes the rect the layout asked for.
const AUTHORED_RECT_META := "opensro_authored_rect"

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
		if ctrl is Label and ctrl.has_meta(STATIC_TEXT_META):
			place_label(ctrl as Label, rect)
			_relay(ctrl as Label)
		else:
			ctrl.position = rect.position
			ctrl.size = rect.size
	for child in root.get_children():
		apply_authored_rects(child)

## Lays a text label on its authored rect the way the client lays text out
## (CIFStatic's 0x64d9b0; the comment above _map_halign has the reading). A label that fits
## takes the rect, and its own alignment places the text inside it. One whose
## text is taller or wider than the rect -- a Label is never smaller than its
## text -- overruns it by the alignment: evenly when centred, toward the top
## or left when bottom- or right-aligned, from the truncated position the
## client draws at (0x64d96c: 0xb42d10 of the float, cvttsd2si, which truncates).
## The client truncates the SCREEN coordinate, window position plus the
## offset; the windows sit at whole pixels and the screen coordinate is not
## negative, so trunc(window + offset) is window + floor(offset), and the
## offset here is floored. (Truncating the offset itself would be a pixel off
## whenever it is negative and fractional: a centred 15-pixel text on a
## 4-pixel row at the top of its parent.) Godot placed it at the rect's
## top-left and grew it right and down, so a centred row drew its text low
## by half the overrun (round 630). Measured on the render box (the archive's
## Arial fallback): GDR_PMI_TXT_HP, 124x12 with a 13-pixel line, now starts at
## y 25 rather than 26. That the client's text height (the extent 0x64d9b0
## reads at +0xde) equals Godot's line height for the same face is INFERRED.
const RELAY_META := "opensro_label_relay"
## Marks a label this builder made for a CIFStatic's or CIFButton's text:
## the ones the client lays out with 0x64d9b0, and so the only ones
## place_label moves.
## Other labels that carry an authored rect (a window's caption strip) keep
## their rect as before -- their draw was not read.
const STATIC_TEXT_META := "opensro_static_text"
## A text label's ClientRect (left, top, right, bottom insets, as the layout
## writes them), and an art static's def.
const CLIENT_RECT_META := "opensro_client_rect"
const STATIC_DEF_META := "opensro_static_def"

## The rect a control's text is laid out in. READ: 0x64d9b0 asks 0x652800
## for it, which takes the control's rect and moves its left and top in by
## +0x18c and +0x190 and takes +0x18c + +0x194 off the width and +0x190 +
## +0x198 off the height (0x65280e..0x65283b). 0x6527d0 copies those four
## from its argument, and the builder passes it the parsed ClientRect
## (0x8b566e..0x8b5674, the def's +0x58..+0x64), in the file's order: left,
## top, right, bottom. UiLayoutParser keeps them as a Rect2i's x, y, width
## and height. 60 CIFStatics and 238 CIFButtons carry a non-zero one
## (round 630 review's census); GDR_STORAGE_TXT_MONEY_TITLE's "8,4,174,3"
## centres its title in the strip's left 54 pixels.
static func text_rect(rect: Rect2, client: Rect2i) -> Rect2:
	return Rect2(rect.position.x + client.position.x, rect.position.y + client.position.y,
		rect.size.x - client.position.x - client.size.x, rect.size.y - client.position.y - client.size.y)
static func place_label(label: Label, authored: Rect2) -> void:
	var rect := text_rect(authored, label.get_meta(CLIENT_RECT_META, Rect2i()))
	var need := label.get_combined_minimum_size()
	var pos := rect.position
	var size := rect.size
	if need.x > size.x:
		pos.x = floorf(rect.position.x + _align_share(label.horizontal_alignment) * (size.x - need.x))
		size.x = need.x
	if need.y > size.y:
		pos.y = floorf(rect.position.y + _valign_share(label.vertical_alignment) * (size.y - need.y))
		size.y = need.y
	label.position = pos
	label.size = size

## The text can change after the rect is settled (a number, a name), and
## with it how far it overruns: re-lay it on its authored rect then.
static func _on_label_min_changed(label: Label) -> void:
	if is_instance_valid(label) and label.has_meta(AUTHORED_RECT_META):
		place_label(label, label.get_meta(AUTHORED_RECT_META))

static func _align_share(h: HorizontalAlignment) -> float:
	match h:
		HORIZONTAL_ALIGNMENT_CENTER: return 0.5
		HORIZONTAL_ALIGNMENT_RIGHT: return 1.0
		_: return 0.0

static func _valign_share(v: VerticalAlignment) -> float:
	match v:
		VERTICAL_ALIGNMENT_CENTER: return 0.5
		VERTICAL_ALIGNMENT_BOTTOM: return 1.0
		_: return 0.0

## Frames the settling pass runs for. One is normally enough; a few are cheap
## and remove the guesswork about exactly which frame the theme cache
## refreshes on.
const SETTLE_FRAMES := 3

## Runs apply_authored_rects over `root` on each of the next SETTLE_FRAMES
## frames it spends in the tree, starting when it enters one.
##
## This is the one settling pass every built widget shares. HudWindow ran it
## from its own _process, and nothing ran it for the HUD widgets that build
## sections without being a HudWindow -- the underbar, minimap, player info,
## target window and chat -- so every authored label there kept the 23-pixel
## height of Godot's default face (the audit's node dumps: GDR_STATIC_EXP
## authored 198x12 drawn 198x23, GDR_PMI_TXT_HP 124x12 drawn 124x23).
##
## A Label still cannot be shorter than its own font's line height, which is
## Godot's minimum-size rule, not a size this pass chooses: a 12-pixel row
## in the client's font settles at that font's height, as it does in every
## window.
##
## Calling it again while a pass is running starts another; both only
## re-apply the same authored rects, so an overlap is harmless.
static func settle_authored_rects(root: Node, frames: int = SETTLE_FRAMES) -> void:
	if root == null:
		return
	if not root.is_inside_tree():
		root.tree_entered.connect(func() -> void: settle_authored_rects(root, frames),
			CONNECT_ONE_SHOT)
		return
	var tree := root.get_tree()
	for i in frames:
		await tree.process_frame
		if not is_instance_valid(root):
			return
		apply_authored_rects(root)

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

	# The def is kept so set_button_text can caption a button authored with
	# no text (ifpartyslot's row button, round 711).
	btn.set_meta(STATIC_DEF_META, def)
	if def.text != "":
		# READ: CIFButton draws its text with CIFStatic's own draw (its vtable
		# slot 13, 0x655f30, jumps to 0x64d940) and lays it out with the same
		# 0x64d9b0 (its slot 42), and the builder gives every control its
		# layout's HAlign and VAlign (0x8b5696..0x8b56b8, no type test). So a
		# caption follows its def's alignment and ClientRect, as a static's
		# text does -- it used to be centred both ways whatever the layout
		# said (round 630 review).
		var label := _make_text_label(def)
		label.name = "ButtonLabel"
		label.text = _resolve_text(def.text)
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

		# The def is kept so set_static_text can put text on a static that
		# was authored without any (GDR_INVENTORY_STA_MONEY: the purse's
		# amount on int_window_downbox, filled at runtime).
		rect.set_meta(STATIC_DEF_META, def)
		if def.text != "":
			var label := _make_text_label(def)
			label.name = "Text"
			label.text = _resolve_text(def.text)
			rect.add_child(label)

		return rect
	# No artwork means this is a text field, and it stays one even when its
	# text starts empty -- the client fills those at runtime. Returning a
	# plain Control for the empty case (as this used to) meant every live
	# data field in a window, GDR_PMI_TXT_ID and the HP/MP readouts
	# included, was built as something that can never show text.
	var label := _make_text_label(def)
	label.text = _resolve_text(def.text)
	return label

## A text label for a control's text, styled from its def and marked to be
## laid out by CIFStatic's rule (place_label) inside the def's ClientRect.
func _make_text_label(def: UiLayoutParser.ControlDef) -> Label:
	var label := Label.new()
	label.horizontal_alignment = _map_halign(def.halign)
	label.vertical_alignment = _map_valign(def.valign)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.clip_text = false
	label.set_meta(STATIC_TEXT_META, true)
	label.set_meta(CLIENT_RECT_META, def.client_rect)
	if def.font_color != Color.WHITE:
		label.add_theme_color_override("font_color", def.font_color)
	_apply_font(label, def)
	return label

## Puts `text` on a static the way the client's SetText does: a text label is
## the static itself, and a static with art gets its text drawn over the art
## in its ClientRect, the label made the first time. Null when the node is
## neither (not built by this builder).
func set_static_text(node: Control, text: String) -> Label:
	if node == null:
		return null
	if node is Label:
		(node as Label).text = text
		return node as Label
	var label := node.get_node_or_null("Text") as Label
	if label == null:
		var def = node.get_meta(STATIC_DEF_META, null)
		if def == null:
			return null
		label = _make_text_label(def)
		label.name = "Text"
		node.add_child(label)
		_lay_caption(node, label)
	label.text = text
	return label

## Puts `text` on a button the way SetText does on a CIFButton (round 711):
## its caption label, made from the button's def the first time when the
## layout authored it with no text. Null for a node this builder did not make.
func set_button_text(node: Control, text: String) -> Label:
	if node == null:
		return null
	var label := node.get_node_or_null("ButtonLabel") as Label
	if label == null:
		var def = node.get_meta(STATIC_DEF_META, null)
		if def == null:
			return null
		label = _make_text_label(def)
		label.name = "ButtonLabel"
		node.add_child(label)
		_lay_caption(node, label)
	label.text = text
	return label

## A caption drawn over its control (a static's art, a button): laid in the
## control's own rect, from its top-left, by place_label -- now, and on the
## settling pass through the meta.
static func _lay_caption(owner: Control, label: Label) -> void:
	var r: Rect2 = owner.get_meta(AUTHORED_RECT_META, Rect2(Vector2.ZERO, owner.size))
	label.set_meta(AUTHORED_RECT_META, Rect2(Vector2.ZERO, r.size))
	place_label(label, Rect2(Vector2.ZERO, r.size))
	_relay(label)

static func _relay(label: Label) -> void:
	if not label.has_meta(RELAY_META):
		label.set_meta(RELAY_META, true)
		label.minimum_size_changed.connect(_on_label_min_changed.bind(label))

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
	# Empty until a caller sets it: a full bar would state a value nobody
	# sent (the character pane's job-EXP bar, the guild's GP bar and the
	# party rows' HP/MP have no data here). Every caller that has a number
	# sets it -- the player block, the character HP/MP, the SP bar, the
	# target's HP -- so only bars without data change.
	gauge.value = 0
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
		#
		# **And the reused piece is laid on its side** (round 718, READ). The
		# user saw `com_blacksquare_`'s bottom drawn as a row of vertical
		# ticks: `right_side` is a 4x4 tile whose column 3 is a grey line
		# (#7B797B, the rest black), and tiled upright along the bottom it
		# puts a grey dot every 4 px. A resinfo CIFStretchWnd (vtable
		# `0xdd2174`): the loader checks the class at `0x8b57ce`, loads the
		# six pieces (`0x819c00`) and calls slot 47 (`0x819110` ->
		# `0x8190f0`) with the control's StretchType (`[esi+0xf0]`); every
		# six-piece CIFStretchWnd in the archive has StretchType 0, which
		# sets corner UV mode 2 (`0x818a50`) and edge UV mode 3 (`0x818d30`).
		# The .2dt windows' CNIFStretchWnd does the same through its own copy
		# (the 2dt loader `0x489b80` calls slot 49 with 0 at `0x48a408`:
		# corners `0x49a140` mode 2, edges `0x49a410` mode 3, jump table
		# `0x49a7b8` -> `0x49a6b0`). Mode 3
		# writes the left and right quads upright and the top and bottom
		# quads as TL (0,1), TR (0,0), BR (1,0), BL (1,1) -- the texture
		# turned 90 degrees clockwise, so a texture column becomes a screen
		# row -- and copies the sizes across swapped: the top's height is
		# `left_side`'s width (`[0x78c] = [0x780]`), the bottom's
		# `right_side`'s (`[0x79c] = [0x790]`). So `right_side`'s grey
		# column 3 is the bottom strip's last row: a horizontal line.
		var top_reused := mu == null
		var bottom_reused := md == null
		if mu == null and ls != null:
			mu = rotated_cw(ls)
		if md == null and rs != null:
			md = rotated_cw(rs)

		# **Each piece at its own size**, as the client lays them out -- read
		# from CNIFFrame's own code, not inferred. The loader
		# (`FUN_004745a0`) fills four corner slots and four edge slots, and
		# for every texture stores its width and height beside it
		# (`FUN_00475400` at +0x76c..+0x788 for the edges). The corner quads
		# (`FUN_00474d00`) are each that corner's own width and height,
		# anchored to their corner of the frame. The draw (`FUN_004736a0`)
		# then tiles each edge at its **own** thickness, across the gap
		# between the two corners it meets, the last tile cropped:
		#
		#   top     y = top,             x from left + left_up.w  to right - right_up.w
		#   bottom  y = bottom - own.h,  x from left + left_down.w to right - right_down.w
		#   left    x = left,            y from top + left_up.h   to bottom - left_down.h
		#   right   x = right - own.w,   y from top + left_up.h, for height - right_up.h - right_down.h
		#
		# The layouts' own types (CIFFrame / CIFSubFrame / CIFMainFrame) are
		# a sibling family with its own copy of this code -- loader
		# `FUN_00815300`, corners `FUN_0081ae80` / `FUN_0081a740`, edges
		# `FUN_0081b1b0`, draw `FUN_00815490` -- with the same geometry at
		# offsets shifted by +0x24.
		#
		# (The right edge really does start at *left_up*'s height. All 18
		# eight-piece bases the archive's layouts name have left_up and
		# right_up the same size, so it only matters to a set not yet seen.)
		#
		# Sizing all eight from `left_up` instead is what stretched every
		# `sframe_wnd_` bottom corner from 16 to 36 tall (its top pieces are
		# 36, its bottom ones 16), drew `mframe_wnd_`'s 48-tall bottom 68
		# tall, and left the side edges 20 pixels short of the bottom
		# corners. Godot's STRETCH_TILE tiles from the rect's origin and crops
		# the last tile, which is the client's own tiling.
		#
		# A six-piece set (no mid_up / mid_down, the sides reused for the top
		# and bottom) is a CIFStretchWnd's (every six-piece base in the
		# archive's layouts is one, round 718). Its placement is READ (CIF
		# slot 41, `0x8186a0`): every piece inside the control's rect -- top
		# from LT.w to W - RT.w, `left_side.w` thick; bottom from LB.w to
		# W - RB.w at H - `right_side.w`; left from LT.h to H - LB.h; right
		# from RT.h to H - RB.h -- which this function's geometry matches for
		# every 4x4 set. **Its edges are stretched, not tiled** (READ: mode
		# 3's UVs are 0 and 1, and the draw `0x819d80` copies the quads and
		# samples with point filtering, `0x819e3c`/`0x819e5f`), so a
		# six-piece set's four edges are scaled here with NEAREST filtering;
		# an eight-piece frame's edges stay tiled (CNIFFrame, above).
		# `com_lattice_outline_` and `com_blacksquare_` are 4x4 in every
		# piece; `com_square_`'s sides are 4x64 (one control, not built).
		var w := def.rect.size.x
		var h := def.rect.size.y
		var lu_s := _piece_size(lu)
		var ru_s := _piece_size(ru)
		var ld_s := _piece_size(ld)
		var rd_s := _piece_size(rd)
		# A reused top or bottom is the side piece turned on its side, so its
		# thickness is that side's width (mode 3's swapped sizes, above).
		var top_h := _piece_size(mu).y
		var bottom_h := _piece_size(md).y
		var left_w := lu_s.x if top_reused else _piece_size(ls).x
		var right_w := ru_s.x if bottom_reused else _piece_size(rs).x

		_add_slice(container, lu, Rect2(Vector2.ZERO, lu_s))
		var six := top_reused or bottom_reused
		_add_slice(container, mu, Rect2(lu_s.x, 0, w - lu_s.x - ru_s.x, top_h), not six, six)
		_add_slice(container, ru, Rect2(Vector2(w - ru_s.x, 0), ru_s))

		_add_slice(container, ls, Rect2(0, lu_s.y, left_w, h - lu_s.y - ld_s.y), not six, six)
		_add_slice(container, rs, Rect2(w - right_w, lu_s.y, right_w, h - ru_s.y - rd_s.y), not six, six)

		_add_slice(container, ld, Rect2(Vector2(0, h - ld_s.y), ld_s))
		_add_slice(container, md, Rect2(ld_s.x, h - bottom_h, w - ld_s.x - rd_s.x, bottom_h), not six, six)
		_add_slice(container, rd, Rect2(Vector2(w - rd_s.x, h - rd_s.y), rd_s))

	return container

## A copy of `tex` turned 90 degrees clockwise (a texture column becomes a
## screen row), cached per texture: how CNIFStretchWnd's edge mode 3 draws a
## six-piece set's top and bottom from its side pieces (round 718).
var _rotated_cache: Dictionary = {}

func rotated_cw(tex: Texture2D) -> Texture2D:
	if tex == null:
		return null
	if _rotated_cache.has(tex):
		return _rotated_cache[tex]
	var img := tex.get_image()
	if img == null:
		return tex
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.rotate_90(CLOCKWISE)
	var out := ImageTexture.create_from_image(img)
	_rotated_cache[tex] = out
	return out

## A frame piece's own size, or zero when the archive has no such piece.
static func _piece_size(tex: Texture2D) -> Vector2:
	return tex.get_size() if tex != null else Vector2.ZERO

func _add_slice(parent: Control, tex: Texture2D, rect: Rect2, tile: bool = false, point_filter: bool = false) -> void:
	if tex == null or rect.size.x <= 0 or rect.size.y <= 0:
		return
	var tr := TextureRect.new()
	tr.texture = tex
	# The modes go on **before** the size. With the default expand mode a
	# TextureRect's minimum size is its texture, and assigning `size` first
	# is clamped up to it -- which is how the Action window's 117-tall
	# subframes grew 128-tall side rails (the side piece is 16x128), and
	# setting IGNORE_SIZE afterwards never gave the height back.
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_TILE if tile else TextureRect.STRETCH_SCALE
	if point_filter:
		tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.position = rect.position
	tr.size = rect.size
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(tr)

## A CIFEdit: text over the art behind it, in the layout's face, size,
## colour and alignment.
##
## **No box of Godot's own** (round 718). The client's edit draws no frame:
## every one in the archive sits on art of its own (party matching's three
## on `com_bg_tile_e` inside a `com_blacksquare_`). Godot's default LineEdit
## style is a padded box whose minimum height (content margins plus the
## line) is taller than the layouts' 11-15 px edit rects, so the control
## grew and drew its text 4-5 px low in the black boxes (the user's report:
## party matching's "1 ~ 110" and the page number "too low"). With the style
## empty the edit settles at its own line. CIFEdit's draw (slot 13,
## `0x637b70`, READ in the round's review) lays the text in the rect less
## ClientRect (`0x652800`) and, for VAlign 0, at that rect's top
## (`0x637d58`..`0x637d64`); Godot's LineEdit centres its line instead, so
## the two agree only while the rect is no taller than the line -- true for
## party matching's 11-15 px edits, not for whole chat's 36 px one (which
## centred before this round too).
##
## **HAlign, READ** (`0x637c7f`): 0 left, 1 centred, 2 `left = right - w -
## 2.0` (the double at `0xe1b898`) -- right-aligned 2 px in. Party matching's
## Name edit and the register dialog's level edits are HAlign 2.
## **ClientRect** (left, top, right, bottom insets) becomes the styles'
## content margins, as `0x652800` takes it off the rect.
func _build_edit(def: UiLayoutParser.ControlDef) -> LineEdit:
	var edit := LineEdit.new()
	if def.text != "":
		edit.placeholder_text = _resolve_text(def.text)
	var cr := def.client_rect
	# An edit that names its own art draws it behind its text (the chat's
	# CIFEInputChatBox carries a window_all.ddj slice): a texture stylebox,
	# not a child, so the art stays under the line. Without art, no box
	# of Godot's own (above). Before round 718 the chat line's dark look
	# came from Godot's default LineEdit box, not from its layout art; the
	# empty box then left it see-through (the user's report, 2026-10-05).
	var art: Texture2D = load_texture_region(def.ddj, def.uv_lt, def.uv_rb) if def.ddj != "" else null
	for style in ["normal", "focus", "read_only"]:
		var sb: StyleBox
		if art != null:
			var tsb := StyleBoxTexture.new()
			tsb.texture = art
			if def.ddj.contains(TILE_DIR):
				tsb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
				tsb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
			sb = tsb
		else:
			sb = StyleBoxEmpty.new()
		sb.content_margin_left = cr.position.x
		sb.content_margin_top = cr.position.y
		sb.content_margin_right = cr.size.x + (EDIT_RIGHT_INSET if def.halign == 2 else 0.0)
		sb.content_margin_bottom = cr.size.y
		edit.add_theme_stylebox_override(style, sb)
	edit.alignment = _map_halign(def.halign)
	var font := font_at(def.font_index)
	if font != null:
		edit.add_theme_font_override("font", font)
	var size: int = FONT_SIZES[def.font_index] if def.font_index >= 0 and def.font_index < FONT_SIZES.size() else FONT_SIZE_FALLBACK
	edit.add_theme_font_size_override("font_size", size)
	edit.add_theme_color_override("font_color", def.font_color)
	return edit

## CIFEdit's right inset for HAlign 2: 2.0 (`0xe1b898`, READ).
const EDIT_RIGHT_INSET := 2.0

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
	# A square item slot is not clipped (round 728): its layers are sized
	# exactly, and the original draws a 4-digit count from 1 px left of the
	# slot (ItemCountLabel, READ), which a clip cut off -- measured against
	# qty_Pp886X3.png, the '5' of "5000" lost its first column. Row slots,
	# whose text can run long, stay clipped.
	slot.clip_contents = inner.x != inner.y

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

	# The stack count (round 728): the original's digit images at the slot's
	# top left, ItemCountLabel (READ, FUN_0067bd70); still a Label, so callers
	# set its text as before.
	ItemCountLabel.ensure_digits(self)
	var count_lbl := ItemCountLabel.new()
	count_lbl.name = "CountLabel"
	count_lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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

## The spin control's parts, read from the client's own constructor
## (CNIFSpinButtonCtrl, 0x49d2e0): the control is backed by
## `interface\store\str_slot_02.ddj`, a left arrow button at (0,0) 16x16
## (`com_left_arrow.ddj`), the value label at (16,4) 18x12, and a right arrow
## at (34,0) 16x16 (`com_right_arrow.ddj`). The label shows value+1
## (0x49d4d0), so a 0-based page reads "1"; the arrows step within
## [min, max] (0x49d580 / 0x49d5c0).
const SPIN_BG_DDJ := "interface\\store\\str_slot_02.ddj"
const SPIN_LEFT_DDJ := "interface\\ifcommon\\com_left_arrow.ddj"
const SPIN_RIGHT_DDJ := "interface\\ifcommon\\com_right_arrow.ddj"
const SPIN_ARROW_SIZE := Vector2(16, 16)
const SPIN_LABEL_RECT := Rect2(16, 4, 18, 12)
const SPIN_RIGHT_X := 34

## Builds an authored spin button: a control whose "value" meta is stepped by
## its two arrow buttons ("Left"/"Right") between the "min" and "max" metas,
## with the label ("Value") showing value+1 as the original does. The owner
## sets the range with set_spin_range and listens on the "spin_changed"
## user signal.
func _build_spin(def: UiLayoutParser.ControlDef) -> Control:
	var ctrl := Control.new()
	ctrl.mouse_filter = Control.MOUSE_FILTER_PASS
	ctrl.add_user_signal("spin_changed", [{"name": "value", "type": TYPE_INT}])
	ctrl.set_meta("value", 0)
	ctrl.set_meta("min", 0)
	ctrl.set_meta("max", 0)

	var bg := TextureRect.new()
	bg.name = "Background"
	bg.texture = load_texture(SPIN_BG_DDJ)
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ctrl.add_child(bg)

	var label := Label.new()
	label.name = "Value"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_font(label, def)
	# Laid on its 18x12 rect by place_label, the client's rule (round 718): a
	# Godot Label is never shorter than its line (15 px for FontIndex 0), so
	# set straight to 12 it grew downward and drew the page number low -- the
	# user's "numbers ... too low" under party matching. Centred, the line
	# now overruns the rect evenly, as the client's centred text does.
	label.set_meta(AUTHORED_RECT_META, SPIN_LABEL_RECT)
	place_label(label, SPIN_LABEL_RECT)
	_relay(label)
	ctrl.add_child(label)

	for side in [["Left", SPIN_LEFT_DDJ, 0.0, -1], ["Right", SPIN_RIGHT_DDJ, float(SPIN_RIGHT_X), 1]]:
		var btn := TextureButton.new()
		btn.name = side[0]
		btn.ignore_texture_size = true
		btn.stretch_mode = TextureButton.STRETCH_SCALE
		btn.texture_normal = load_texture(side[1])
		btn.texture_hover = load_texture(_insert_suffix(side[1], "_focus"))
		btn.texture_pressed = load_texture(_insert_suffix(side[1], "_press"))
		btn.position = Vector2(side[2], 0.0)
		btn.size = SPIN_ARROW_SIZE
		var step: int = side[3]
		btn.pressed.connect(func() -> void: _spin_step(ctrl, step))
		ctrl.add_child(btn)
	_spin_refresh(ctrl)
	return ctrl

static func set_spin_range(ctrl: Control, minimum: int, maximum: int) -> void:
	ctrl.set_meta("min", minimum)
	ctrl.set_meta("max", maxi(minimum, maximum))
	ctrl.set_meta("value", clampi(int(ctrl.get_meta("value", 0)), minimum, maxi(minimum, maximum)))
	_spin_refresh(ctrl)

static func spin_value(ctrl: Control) -> int:
	return int(ctrl.get_meta("value", 0))

static func _spin_step(ctrl: Control, step: int) -> void:
	var value := int(ctrl.get_meta("value", 0)) + step
	if value < int(ctrl.get_meta("min", 0)) or value > int(ctrl.get_meta("max", 0)):
		return
	ctrl.set_meta("value", value)
	_spin_refresh(ctrl)
	ctrl.emit_signal("spin_changed", value)

static func _spin_refresh(ctrl: Control) -> void:
	var label := ctrl.get_node_or_null("Value") as Label
	if label != null:
		label.text = str(int(ctrl.get_meta("value", 0)) + 1)

## The caption a CIFSubFrame draws (round 711). READ, CIFSubFrame's Create
## (vslot 10, 0x81a530): it makes a text static at (10, 7), the frame's width
## less 20 wide and 12 high (`ecx = width - 0x14`, the rect 0xa/0x7/../0xc),
## gives it font 0 (0xba5460(0) -> 0x655270), HAlign 1 (centred, slot +0x14)
## and VAlign 0 (top, slot +0x18); SetText on the frame (vslot 45, 0x81a610)
## is that static's SetText, so the layout's Text lands there. Nine resinfo
## subframes carry one (MEASURED: ifparty's "Party informaiton", ifaction's
## four headers, the academy, quest, storage and item mall frames). Its
## colour is not set by that code: white, as the static's default (INFERRED
## from the user's party screenshots 01/12).
const SUBFRAME_CAPTION := "Caption"

func _add_subframe_caption(frame: Control, def: UiLayoutParser.ControlDef) -> void:
	var label := Label.new()
	label.name = SUBFRAME_CAPTION
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.clip_text = false
	label.set_meta(STATIC_TEXT_META, true)
	label.set_meta(CLIENT_RECT_META, Rect2i())
	var font := font_at(0)
	if font != null:
		label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", FONT_SIZES[0] if FONT_SIZES.size() > 0 else FONT_SIZE_FALLBACK)
	crisp_text(label)
	label.text = _resolve_text(def.text)
	var rect := Rect2(10, 7, maxf(0.0, float(def.rect.size.x) - 20.0), 12)
	label.set_meta(AUTHORED_RECT_META, rect)
	place_label(label, rect)
	_relay(label)
	frame.add_child(label)

## The caption label of a subframe built by build_control, or null.
static func subframe_caption(frame: Node) -> Label:
	return frame.get_node_or_null(SUBFRAME_CAPTION) as Label if frame != null else null

## The check box CIFCheckBox draws (round 711), put into `holder` (the generic
## control the builder makes for a CIFCheckBox). READ: CIFCheckBox::Create
## (0x656f90) loads `resinfo\ifcheckbox.txt`'s Create into itself -- one
## static, GDR_STATIC_SELECTED (ID 0), `com_checkbutton_on.ddj` at 0,0 with
## its art's size -- over the box's own art (the layout's DDJ). A press's
## release (message 0x202, vslot 17 0x656ce0) flips the state byte +0x36c
## when enabled (+0x36d) and shows child 0 by it (0x8b51f0(0, 1) -> ShowWindow);
## the constructor (0x656c70) starts it checked and enabled. Returns the
## button; its `toggled` signal and `button_pressed` are the state.
func make_checkbox(holder: Control, box_ddj: String, checked: bool = true) -> TextureButton:
	var btn := TextureButton.new()
	btn.name = "CheckBox"
	btn.toggle_mode = true
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_SCALE
	btn.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	btn.texture_normal = load_texture(box_ddj)
	var mark := TextureRect.new()
	mark.name = "GDR_STATIC_SELECTED"
	mark.texture = load_texture("interface\\ifcommon\\com_checkbutton_on.ddj")
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	if mark.texture != null:
		mark.size = mark.texture.get_size()
	btn.add_child(mark)
	btn.button_pressed = checked
	mark.visible = checked
	btn.toggled.connect(func(on: bool) -> void: mark.visible = on)
	holder.add_child(btn)
	return btn

func _build_generic(def: UiLayoutParser.ControlDef) -> Control:
	var ctrl := Control.new()
	ctrl.mouse_filter = Control.MOUSE_FILTER_PASS
	return ctrl

## Loads a .ddj texture from Media.pk2, using an in-memory cache to avoid duplicate decodes.
## `cache` false leaves the texture out of the builder's cache, which keeps
## every texture it loads for the builder's life: a caller that streams many
## textures in and out keeps its own bounded set (HudMinimap's region tiles,
## round 630 review). A texture already cached is still returned from there.
func load_texture(ddj_path: String, cache: bool = true) -> Texture2D:
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
	if tex != null and cache:
		_texture_cache[key] = tex
	return tex

## A .ddj's top-level Image, decoded on the CPU and not cached, for a caller
## that resamples the art itself (HudBuffBoard's authentic 20x20 icons, round
## 624). Null where load_texture would be null.
func load_image(ddj_path: String) -> Image:
	if ddj_path.is_empty() or _media_pk2 == null:
		return null
	var entry := ObjectLoader.find_file(_media_pk2, ddj_path.to_lower().replace("/", "\\"))
	if entry == null:
		return null
	var data := _media_pk2.read_file(entry)
	if data.is_empty():
		return null
	var parsed := DdjReader.parse(data)
	if parsed == null:
		return null
	return DdjReader.to_image(parsed)

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
## The box's Media.pk2 has two `UIC_STT_FONTNAME` rows: the file's FIRST
## line says **Arial** in the English columns, and a later row says Tahoma
## ("굴림체" in its Korean one). The binary keeps a key's first row
## (TextStringManager 0x8cac30 -- round 634's review), so it would ask GDI
## for Arial there. The later row opens the stock table that follows the
## private server's one, and by the USER DECISION of 2026-10-05 the stock row
## wins in such a joined table (UiTextTable.select_rows), so OpenSRO asks for
## **Tahoma**. MEASURED, round 725: the user's original draws the herbalist's
## first greeting line 286 px wide and the tax line 253 px, where OpenSRO's
## Arial draws 279 and 244 -- the original's face is wider than Arial, as
## Tahoma is (a hint, not a proof of the face). The bundled files are TaeUtum, SeUtum, Arial Rounded MT Bold
## (`fonts\\`) and Arial (`vplus\\vfont.ttf`); Tahoma, if named, is a
## Windows system font, which the real client takes from the system.
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

## One FontFile per archive and face for the whole process (round 684's
## review): each screen used to parse the face afresh, and guard_button_font
## pins every face it meets in `_button_fonts` for good -- ~1.3 MB and 5
## objects kept per visit of a screen (MEASURED, the select screen's reload
## loop). The cached font carries the same flags (_new_font), so round 672's
## crispness is unchanged. Key: the archive's file path and the face asked.
static var _font_cache := {}

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
	var data := _media_pk2.read_file(entry)
	var text := data.get_string_from_utf16()
	var at := text.find("\t" + FONT_NAME_KEY + "\t")
	# A key written more than once goes through the table's own row rule
	# (UiTextTable.select_rows: in a joined table the stock row wins, USER
	# DECISION 2026-10-05), so the login screen asks for the same face as the
	# world. Only then is the whole table parsed.
	if at != -1 and text.find("\t" + FONT_NAME_KEY + "\t", at + 1) != -1:
		var table := UiTextTable.parse(data)
		var name := table.get_text(FONT_NAME_KEY, "")
		return "" if name == FONT_NAME_KEY else name
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
	var key := "%s|%s" % [_media_pk2._file.get_path_absolute() if _media_pk2._file != null else str(_media_pk2.get_instance_id()), face.to_lower()]
	if _font_cache.has(key):
		var hit: Array = _font_cache[key]
		_ui_font = hit[0]
		_ui_font_source = str(hit[1]) + " (cached)"
		return
	_load_fonts_uncached(face)
	_font_cache[key] = [_ui_font, _ui_font_source]

func _load_fonts_uncached(face: String) -> void:
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

## **Every in-game text path goes through here** (round 672).
##
## The reference client draws all its text with one face (`font_at`) at the
## five FontIndex sizes, glyphs rasterised one bit deep -- GetGlyphOutlineW
## with GGO_BITMAP (format 1) in GFontChar 0x8b0a00 / GNFontChar 0x492bc0,
## each set bit stored as an opaque texel (READ) -- and drawn 1:1, since it
## never scales its UI. So a glyph pixel is the text colour or nothing.
##
## `apply_ui_theme` gives a UI root that look for everything under it:
##   - a Theme whose default font is the client's face at FontIndex 0's
##     12 px, so a Label, Button, LineEdit or RichTextLabel made in code
##     without a font of its own no longer falls back to Godot's anti-aliased
##     default font at 16 px;
##   - `crisp_text` on every text node that enters the root, now or later:
##     the glyph texture is sampled NEAREST. The window rasterises glyphs at
##     the UI scale (ClientSettings.apply_ui_scale), but a glyph still lands
##     at a fractional pixel position, and at a scale like 1.95 its texel is
##     1.017 px (FreeType takes a whole pixel size: 12 x 1.95 = 23.4 -> 23).
##     A LINEAR filter turns that into a 2-3 px ramp on 60-70 % of text
##     pixels (measured at 1.95, and still 33-43 % at a whole 2.0, from
##     half-pixel placements); NEAREST keeps every pixel one level at every
##     scale measured (1.0 to 2.5, round 672). The UI's ART keeps its
##     linear filter: only text nodes are switched.
func apply_ui_theme(root: Control) -> void:
	if root == null:
		return
	var font := font_at(0)
	if font != null:
		var theme := root.theme if root.theme != null else Theme.new()
		theme.default_font = font
		theme.default_font_size = FONT_SIZES[0]
		root.theme = theme
	watch_text(root)

## Makes every text node under `root` -- those there now and every one added
## later, at any depth -- draw its glyphs unfiltered (`crisp_text`). Only the
## UI's own subtree is watched: each node in it gets one child_entered_tree
## connection, so nothing is paid for the 3D world's nodes.
static func watch_text(root: Node) -> void:
	if root == null:
		return
	if not root.is_inside_tree():
		root.tree_entered.connect(func() -> void: _watch_node(root), CONNECT_ONE_SHOT)
		return
	_watch_node(root)

## Only a node INSIDE the tree is handled: its theme (the root's face, a
## Button's styles) resolves only there. A subtree added in one go enters
## parent first, and each node's parent emits child_entered_tree as that
## node enters -- after the parent was connected here, before the node's
## own children enter. So a descendant still outside the tree is skipped
## now and handled when it enters. Handled from outside, a dialog's nested
## Buttons were guarded in Godot's default face and kept it (round 672's
## review, H1: every HudPanels dialog).
static func _watch_node(n: Node) -> void:
	if not n.is_inside_tree():
		return
	if is_text_node(n):
		crisp_text(n as CanvasItem)
	if n is Button:
		guard_button_font(n as Button)
	var cb := Callable(UiBuilder, "_watch_node")
	if not n.child_entered_tree.is_connected(cb):
		n.child_entered_tree.connect(cb)
	for c in n.get_children():
		_watch_node(c)

## Meta that marks a custom-drawn node (one whose `_draw` writes text and
## nothing textured) as a text node for `is_text_node`.
const TEXT_NODE_META := &"ui_text"

## Whether `n` draws text and nothing else textured, so it can be sampled
## NEAREST without touching the UI's art. A Button counts unless a style of
## it is a texture (CompositeItemWindow's buttons wear the client's art);
## CheckBox, CheckButton and OptionButton never, because they also draw
## theme icons (the box, the switch, the arrow) that must keep their filter
## (none is under the UI root today; review L4). TextureButton and the other
## art controls never. Their text keeps the guard (guard_button_font).
static func is_text_node(n: Node) -> bool:
	if n is Label or n is LineEdit or n is RichTextLabel or n is ItemList:
		return true
	if n is CheckBox or n is CheckButton or n is OptionButton:
		return false
	if n is Button:
		for st in [&"normal", &"hover", &"pressed", &"disabled", &"focus"]:
			if (n as Button).get_theme_stylebox(st) is StyleBoxTexture:
				return false
		return true
	return n is CanvasItem and n.has_meta(TEXT_NODE_META)

## The one switch: a text node's glyph textures are sampled NEAREST, so a
## glyph pixel is drawn whole or not at all (see apply_ui_theme for why).
static func crisp_text(ci: CanvasItem) -> void:
	if ci != null:
		ci.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

## **A Button's last glyph at a fractional scale** -- the 2026-09-11
## "Registe", reproduced in round 672 as "Sel" for "Sell" at 1.25, fresh
## start and live change alike (measured: ink 20 px against 25).
##
## READ in 4.2.2: a Button draws its text through a TextLine whose width it
## sets to the text's own width, rounded UP to a whole unit
## (scene/gui/button.cpp, `int text_width = ... text_buf->get_size().x`;
## TextServerAdvanced::_shaped_text_get_size `.ceil()`), and the line is
## drawn clipped to that width: shaped_text_draw stops at the first glyph
## whose end passes it (servers/text_server.cpp, "Clip right"). At a
## fractional oversampling the glyph advances are fractions -- "Sell" at
## 1.25 is 8 + 6.675 + 2.662 + 2.662 (MEASURED, TextLine) -- and when they
## sum to a whole number the ceiling adds nothing, so the running total
## (INFERRED: float rounding, a hair over) passes the clip on the last glyph
## and it is not drawn. A Label draws without that clip and never lost one.
##
## The guard: the Button's face with `variation_embolden` BUTTON_NUDGE. Each
## glyph's advance grows by embolden x size / 64 (READ,
## TextServerAdvanced::_get_extra_advance) -- 0.0019 at 12 px -- so a
## whole-number sum gets a fraction and the ceiling a whole unit of room.
## The glyph is not touched: FreeType's embolden strength is embolden x size
## x 4 in 1/64 px, truncated to an integer -- 0 below 25 px (READ,
## _ensure_glyph). At scale 1.0 a shaped advance plus that extra is rounded
## to a whole pixel (READ, _shape_run: `subpos` is off when the font's scale
## is 1 and subpixel positioning is disabled), so 1.0's layout is unchanged
## (text_crispness_test checks the widths). OURS: a workaround for an engine
## edge, kept to Buttons.
const BUTTON_NUDGE := 0.01
const _BUTTON_GUARD_META := &"ui_button_guard"
static var _button_fonts := {}

static func guard_button_font(b: Button) -> void:
	var base := b.get_theme_font(&"font")
	if base == null or base.has_meta(_BUTTON_GUARD_META) or base is FontVariation:
		return
	if not _button_fonts.has(base):
		var v := FontVariation.new()
		v.base_font = base
		v.variation_embolden = BUTTON_NUDGE
		v.set_meta(_BUTTON_GUARD_META, true)
		_button_fonts[base] = v
	b.add_theme_font_override(&"font", _button_fonts[base])

## For a node that draws art AND text in its own `_draw` (the chat's tabs,
## the notice banner): the text goes on this child, which covers the parent
## and draws whatever `draw_text` draws on it, unfiltered, after (over) the
## parent's own drawing -- so the art keeps its filter and the text loses
## its. The parent calls `queue_redraw` on it when its text changes.
class TextLayer extends Control:
	var draw_text: Callable

	func _init(drawer: Callable = Callable()) -> void:
		draw_text = drawer
		name = "TextLayer"
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		set_meta(TEXT_NODE_META, true)
		UiBuilder.crisp_text(self)

	func _draw() -> void:
		if draw_text.is_valid():
			draw_text.call(self)

## Uses the face in `data` (a font file's bytes) as the UI font, with the
## client's rendering flags, instead of resolving one from the archive --
## for a test or tool that has no archive. Returns the font, or null.
func use_font_data(data: PackedByteArray) -> FontFile:
	_fonts_loaded = true
	_ui_font = _new_font(data)
	_ui_font_source = "given"
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
	crisp_text(label)
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

## The client's text layout, which place_label follows.
##
## READ: CIFStatic's text layout 0x64d9b0 takes the rect 0x652800 fills
## (left, top, width, height) and the text's extent (+0xdc wide,
## +0xde tall), and puts the text's top-left at
##
##   HAlign (+0x88)  0: left            1: left + (width - text w) * 0.5
##                   2: right - text w
##   VAlign (+0x8c)  0: top             1: top + (height - text h) * 0.5
##                   2: bottom - text h
##
## (0x64da4d..0x64db39; 0.5 is 0xe1b7d0), and the draw 0x64d940 hands that
## point to 0x8b48b0 unclipped. So a text taller or wider than its rect
## overruns it evenly when centred, and toward the top or left when bottom-
## or right-aligned. A Godot Label is never smaller than its text and grew
## right and down only, so every centred row shorter than the font's line
## (the underbar's 4 px rows, round 598, which TwoDtBuilder.set_text fixed
## for .2dt windows) drew its text low, and a right-aligned number too wide
## for its rect started at the rect's left. This is the same rule for the
## resinfo builder (round 630), for every CIFStatic's and CIFButton's text,
## inside its ClientRect (text_rect).

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
