extends Control
class_name HudWindow

## One floating game window -- Quest, Guild, the NPC talk box and the
## rest -- built from the client's own authored layout. The character,
## inventory, skill, action, party and academy windows are one of these too:
## the main popup, a registry-framed HudWindow whose panes HudMainPopup
## builds and switches.
##
## A self-framed window is one this client frames from its own layout, with
## no registry entry used: quest, guild, community, the NPC talk
## box and the store. Some of those classes do have an
## entry in resinfo\ginterface.txt (GDR_COMMUNITY, GDR_ALCHEMYBOX, GDR_STORE,
## GDR_NPCWINDOW) that is not used, each for the reason docs/RE_COMPLETION.md
## gives (round 586); guild has none. (The teleport board had none either;
## round 603 removed it -- the client lists a gate's destinations in the
## talk box.) The layout file
## carries a CIFFrame (or CIFStretchWnd) at the origin whose `ddj` is an 8-slice base
## ending in an underscore, and whose rect is the window's size --
## ifinventory.txt's GDR_INVENTORY_FRAME is `0,0,176,308` with
## `interface\inventory\int_window_`. UiBuilder already expands that base
## into its eight pieces, so building a window is: read the layout, build
## the section, size to the frame.
##
## Most layouts do not carry the title text or the close button -- the real
## client's window base draws those itself over the frame's top edge. A few
## do, though, and those are what the chrome added here is measured from:
## see TITLE_BAR_HEIGHT.
##
## **Some windows are registry-framed instead.** Storage, exchange, system,
## party match, auto potion, the game guide and the world map each have an
## entry in resinfo\ginterface.txt, an `mframe_wnd_` frame with the window's
## size and caption, and their layouts sit inside it without a frame of their
## own at the origin. Those are built with `registry` (see build) and take
## CIFMainFrame's chrome, read from the client (MAINFRAME_*).

const UiBuilder = preload("res://scripts/ui/ui_builder.gd")
const UiLayoutParser = preload("res://scripts/ui/ui_layout_parser.gd")

signal closed
## Emitted while the player drags the window by its strip, after each move,
## so an owner that keeps its own idea of where the window should be (the
## main popup) can take the player's position as the new one.
signal dragged

## Window chrome, taken from the layouts that spell theirs out.
##
## ifalchemybox.txt is the one that gives the whole convention at once, in a
## 376-wide window:
##
##   GDR_ALCHEMYBOX_DRAG   CIFDragableArea  10,  0, 355, 42
##   GDR_ALCHEMYBOX_TITLE  CIFStatic        10, 18, 355, 12   HAlign=1
##   GDR_ALCHEMYBOX_CLOSE  CIFCloseButton  350, 12,  16, 16
##
## -- a 42-pixel title strip inset 10 from each side, a centred caption 12
## tall sitting 18 down, and a 16x16 close button 26 in from the right edge.
## Every other close button in the archive is 16x16 too (iftargetwindow,
## ifteleportboard, ifnewalchemybox), so the size at least is not one
## window's habit.
const TITLE_BAR_HEIGHT := 42.0
const TITLE_INSET := 10.0
const TITLE_TEXT_Y := 18.0
const TITLE_TEXT_HEIGHT := 12.0
const CLOSE_BUTTON_SIZE := 16.0
const CLOSE_BUTTON_Y := 12.0
## Distance from the window's right edge to the close button's left edge.
const CLOSE_BUTTON_INSET := 26.0

## A **registry-framed** window's chrome: CIFMainFrame's own, read from its
## OnCreate, `CIFMainFrame::vslot_010` (0x816f80), not from a layout.
##
## Every registry entry this client frames is a CIFMainFrame subclass
## (CIFStorageRoom, CIFSystemWnd, CIFExchange, CIFPartyMatch, CIFAutoPotion,
## CIFGameGuide, CIFWorldMap -- their RTTI chains), and each class's Create
## calls that OnCreate before it loads its own layout. It reads the window's
## own rect (0xb8f420: x, y, width, height) and creates three children with
## the window factory 0xba20b0, at rects relative to the window:
##
##   CIFStatic        (10, 12, width - 0x15, 12)   ID 0 -- the caption
##   CIFDragableArea  (10,  0, width - 0x15, 0x22) ID 1 -- the drag strip
##   CIFCloseButton   (width - 0x1a, 10, 16, 16)   ID 2
##
## (the class of each is what its vslot_000 returns: 0xee9720 is CIFStatic's,
## 0xeea6bc CIFDragableArea's, 0xee9868 CIFCloseButton's). Each gets font
## index 0 (0xba5460(0)), horizontal alignment 1 and vertical 0 -- the two
## text-board slots, +0x14 and +0x18, that the layout builder 0x8b5580 feeds
## from a control's HAlign and VAlign (the parser stores those at +0x88 and
## +0x8a, 0x82c785 / 0x82c7a3, and the builder passes the same two fields to
## the same two slots, 0x8b56a6 / 0x8b56b8). The registry entry's `Text` reaches the
## caption through CIFMainFrame's slot 45 (0x817230), which forwards to the
## caption static's SetText; the layout builder calls slot 45 with every
## control's Text (0x8b5706). The resize slot 21 (0x817210) re-lays the three
## the same way (0x817170).
##
## The caption's colour is READ (round 725's review): CIFMainFrame::vslot_010
## (0x816f80) creates the caption CIFStatic at +0x7b0 and sets its font and
## alignment, never a colour, and every window is a CTextBoard whose
## constructor 0x655b50 runs 0x8b4f30 -> 0x8b46d0, which writes 0xffffffff to
## the five colour slots +0x10..+0x20 (the ones the setter 0x8b2b70 writes;
## nothing in the CIFStatic..CIFMainFrame chain calls it). The entry's
## FontColor goes to the frame's own text board (0x8b56d4), not the
## caption's. So a registry window's caption is white
## (MAINFRAME_CAPTION_COLOUR), as the user's original shows on five windows. A
## self-framed window keeps the beige every window here used before (OURS).
const MAINFRAME_CAPTION_X := 10.0
const MAINFRAME_CAPTION_Y := 12.0
const MAINFRAME_CAPTION_HEIGHT := 12.0
## A registry window's caption colour: the CTextBoard default (READ, see above).
const MAINFRAME_CAPTION_COLOUR := Color(1, 1, 1)
## The caption and drag strip are the window's width less 0x15.
const MAINFRAME_STRIP_WIDTH_LESS := 21.0
const MAINFRAME_DRAG_HEIGHT := 34.0
## The close button sits width - 0x1a across, 10 down.
const MAINFRAME_CLOSE_INSET := 26.0
const MAINFRAME_CLOSE_Y := 10.0

var _builder: UiBuilder
var _dragging := false
var _drag_offset := Vector2.ZERO

## The built layout section. Panel bindings look their controls up in here
## by the authored names (GDR_INVENTORY_LATTICE, GDR_PMI_TXT_HP, ...).
var panel_root: Control

## A window CONSUMES mouse input, from the moment it exists.
##
## This is set here as well as in build() because build() fails when the
## archive has no such layout, and the caller then draws a plain fallback
## frame (help_window.gd does exactly that) -- which still has to block
## clicks. See the note on the assignment in build() for why STOP rather
## than PASS.
func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

## Builds the window from layout_path (an archive path such as
## "resinfo\\ifinventory.txt"). Returns false, having built nothing, if the
## layout is missing or empty -- a caller should treat that as "this panel
## isn't available" rather than showing an empty box.
## `extra_sections` names sections beyond "Create" to build into the same
## window.
##
## A layout is not always one section. ifskill has three -- Create,
## MainSkillWnd and Withdrawal -- and ifguild has ten. "Create" is the
## window's chrome; the rest are its content and its modes, and building
## only Create is why the skill and guild windows came out nearly empty.
##
## Which ones compose is per window and has to be established rather than
## assumed: the skill window's two are **alternates**, picked by
## `m_bySkillWndType` in the client (type 1 loads Withdrawal, types 2 and 3
## load MainSkillWnd -- one function, one branch, confirmed in the binary),
## so building both would draw two layouts over each other.
##
## `registry` frames the window from resinfo\ginterface.txt instead of from
## its layout, for a window the client registers there (see
## HudPanels.REGISTRY_FRAMES): `{"name": "GDR_STORAGEROOM"}`, plus
## `"defines"` to select the entry's `#ifdef` branches and `"caption": false`
## when the entry's Text is not to be used. The window then takes the entry's
## size, draws the entry's frame behind everything, and carries CIFMainFrame's
## caption, drag strip and close button (MAINFRAME_*). The layout goes in at
## the window's origin: its controls are the window's own children, created
## with rects relative to it (see _add_registry_frame). An entry that is
## missing, sized zero or not an 8-slice frame leaves the window self-framed,
## as before.
func build(builder: UiBuilder, layout_path: String, title: String,
		extra_sections: PackedStringArray = PackedStringArray(),
		defines: PackedStringArray = PackedStringArray(),
		honor_ifdef: bool = false, registry: Dictionary = {}) -> bool:
	_builder = builder
	if builder == null:
		return false
	var layout := builder.load_layout(layout_path, defines, honor_ifdef)
	if layout == null:
		return false
	var sec := layout.get_section("Create")
	if sec == null or sec.controls.is_empty():
		return false

	var reg_def := _registry_entry(builder, registry)
	var window_size := UiBuilder.section_size(sec, builder)
	if reg_def != null:
		window_size = Vector2(reg_def.rect.size)
	if window_size == Vector2.ZERO:
		return false
	custom_minimum_size = window_size
	size = window_size
	# The window is opaque chrome and must CONSUME clicks, or they land on
	# the world behind it and walk the character (playtest 2026-09-20, items
	# 5 and 13).
	#
	# This was PASS, on the reasoning that STOP would "steal clicks from its
	# own children". It does not: Godot hit-tests the deepest control under
	# the cursor first, so a Button inside the window still gets its click
	# and STOP only catches what the children did not want. PASS, by
	# contrast, delivers the event here AND keeps propagating it, so every
	# click on window chrome -- and every mouse wheel over it -- reached
	# World3D._unhandled_input, which walked the player and zoomed the
	# camera.
	mouse_filter = Control.MOUSE_FILTER_STOP

	# No interior fill is added here any more. A window's body is filled by
	# its own `CIFNormalTile` controls, which the layout declares and
	# UiBuilder now builds -- see _build_tile. Two earlier attempts (a flat
	# colour chosen by eye, then one sampled from the frame's edge pixels)
	# were both working around a control type that simply was not handled.

	panel_root = builder.build_section(layout, "Create")
	if panel_root == null:
		return false
	if reg_def != null:
		# Added first, so it is behind the layout: the frame is the window
		# itself, and every layout control is one of its children.
		_add_registry_frame(reg_def)
	# Sections are declared front-to-back like controls, and "Create" holds
	# the frame, so the content sections go behind nothing and in front of
	# it -- added after, which is on top.
	for extra in extra_sections:
		var extra_root := builder.build_section(layout, extra)
		if extra_root == null:
			push_warning("HudWindow: %s has no section %s" % [layout_path, extra])
			continue
		panel_root.add_child(extra_root)
	# The section root is IGNORE so it doesn't eat world clicks when used
	# for a transparent HUD overlay; inside a window the window itself
	# already blocks, and the children keep their own filters.
	add_child(panel_root)

	var caption := _authored_title(builder, sec, title)
	if reg_def != null and registry.get("caption", true):
		caption = _registry_caption(builder, reg_def, caption)
	_add_title_bar(caption)
	_settle()
	return true

## The registry entry `registry` names (see build), or null when there is
## none to frame the window with.
static func _registry_entry(builder: UiBuilder, registry: Dictionary) -> UiLayoutParser.ControlDef:
	# A CIFMainFrame declared outside ginterface.txt (round 788: the
	# Additional Quick Slot's option window, GDR_EXT_QUICKSLOT_OPTION in
	# ifextquickslot.txt's section Option) is passed in as its def.
	var given = registry.get("def", null)
	if given is UiLayoutParser.ControlDef:
		var d := given as UiLayoutParser.ControlDef
		if d.rect.size.x > 0 and d.rect.size.y > 0 and UiBuilder.is_slice_base(d.ddj):
			return d
		return null
	var reg_name: String = registry.get("name", "")
	if reg_name == "":
		return null
	var honor := registry.has("defines")
	var reg_defines := PackedStringArray(registry.get("defines", []))
	var def := builder.window_def(reg_name, reg_defines, honor)
	if def == null or def.rect.size.x <= 0 or def.rect.size.y <= 0 \
			or not UiBuilder.is_slice_base(def.ddj):
		push_warning("HudWindow: no framed registry entry %s; the window stays self-framed" % reg_name)
		return null
	return def

## The registry entry's own caption, or `fallback` when its Text is empty or
## does not resolve (GDR_STORE's is empty: the store's class sets its own).
static func _registry_caption(builder: UiBuilder, def: UiLayoutParser.ControlDef,
		fallback: String) -> String:
	if def.text == "":
		return fallback
	var resolved := builder.resolve_text(def.text)
	if resolved == "" or resolved == def.text:
		return fallback
	return resolved

## The registry entry the window is framed by, or null for a self-framed one.
var registry_def: UiLayoutParser.ControlDef
## Its frame, the window's backmost child.
var registry_frame: Control

## Draws the registry entry's frame over the whole window, behind everything.
##
## **The layout's origin is the window's origin -- read, not fitted.** Each
## class's Create (CIFStorageRoom 0x6cc780, CIFSystemWnd 0x6f6610,
## CIFExchange 0x7b27d0, CIFPartyMatch 0x73ae90, CIFAutoPotion 0x741980,
## CIFGameGuide 0x765920, CIFWorldMap 0x6964e0) loads its layout and builds
## every section with the window itself as the parent (`push esi` / `push
## ebp` before the builder 0x8b5580). The builder hands each control's Rect
## unchanged to the factory 0xba20b0 (0x8b5639..0x8b564b), and the factory
## stores the rect and then adds the parent's position to it (0xba223e:
## `add [new+0x40], [parent+0x40]`, and the same for y). So a layout rect is
## relative to the registry window's top-left, and the 9-17 pixel margins the
## layouts leave are their own coordinates -- ifstorageroom's frame starts at
## 9,38 in a 254x317 window.
##
## The frame is placed at the window's origin, not at the entry's rect (a
## screen position -- GDR_SYSTEM's is 300,200), and its settling rect is the
## local one, so no settling pass can move it there.
func _add_registry_frame(def: UiLayoutParser.ControlDef) -> void:
	registry_def = def
	if registry_frame != null:
		registry_frame.queue_free()
		remove_child(registry_frame)
	var local := def.with_rect(Rect2i(Vector2i.ZERO, Vector2i(size)))
	registry_frame = _builder.build_control(local)
	if registry_frame == null:
		return
	registry_frame.name = "RegistryFrame"
	registry_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The frame is always drawn (round 633). The registry entry is the
	# WINDOW, not a control inside it: CGInterface creates GDR_MAINPOPUP,
	# GDR_STORAGEROOM, GDR_EXCHANGE, GDR_GAMEGUIDE and the rest from
	# ginterface.txt through the same builder, and the builder's Style 0x40
	# test (0x8b5710..0x8b5726: 0x652da0(0x40), then vslot 0x5c
	# ShowWindow(0)) hides that window object as it creates it -- 43 of
	# ginterface's entries carry Style 64, GDR_MAINPOPUP among them. The
	# window's own ShowWindow(1) (an I, C, P key, an NPC's storage) shows it
	# again, and with it the frame it draws. Here the window is the HudWindow,
	# which HudPanels hides and shows; the frame is a child drawn with it.
	# build_control applied the bit to this child instead (round 630), and
	# nothing ever showed it again: the inventory, character, party, skill,
	# action and academy panes, the warehouse, the exchange and the help
	# window lost their frames and caption strips.
	registry_frame.visible = true
	add_child(registry_frame)
	move_child(registry_frame, 0)

## Resizes a registry-framed window the way CIFMainFrame's resize slot does
## (0x817210): the frame is redrawn at the new size and the caption, drag
## strip and close button re-laid (0x817170). For a class that sizes its
## window in code after building it -- CIFSystemWnd.
func set_registry_size(new_size: Vector2) -> void:
	# The minimum first: a size below the old minimum is clamped back up to it.
	custom_minimum_size = new_size
	size = new_size
	if registry_def != null:
		_add_registry_frame(registry_def)
	var bar := get_node_or_null("TitleBar") as Control
	if bar != null:
		_place_title_bar(bar)
	var close := get_node_or_null("CloseButton") as Control
	if close != null:
		close.position = _close_position()

## The caption the layout asks for, or the caller's.
##
## A window's own frame -- the one at the origin -- sometimes carries a
## `Text`, and that is the client's own wording for the window: ifquest's
## GDR_QUEST_FRAME is `UIIT_STT_QUEST_LIST`, ifparty's is
## `UIIT_STT_PARTY_INFO`. Five of the archive's seventeen origin frames have
## one; the other twelve are titled by the caller, because there is nothing
## authored to use.
static func _authored_title(builder: UiBuilder, sec: UiLayoutParser.SectionDef,
		fallback: String) -> String:
	for def in sec.controls:
		if def.rect.position != Vector2i.ZERO or def.text == "":
			continue
		if not (def.type in FRAME_TYPES):
			continue
		var resolved := builder.resolve_text(def.text)
		if resolved != "" and resolved != def.text:
			return resolved
	return fallback

const FRAME_TYPES := ["CIFFrame", "CIFSubFrame", "CIFStretchWnd"]

## Puts every control back on the rect its layout asked for, over the next
## few frames: UiBuilder.settle_authored_rects, the settling pass every built
## widget shares (its comment has why a rect applied at build time comes out
## inflated). It runs over the built layout and the title bar, which carries
## its rect in the same meta, and over nothing else: a window can hang a
## control built elsewhere on itself -- a registry frame is built from an
## entry whose rect is a screen position (GDR_GAMEGUIDE's 100,100), which the
## window moves to its own origin (_add_registry_frame).
func _settle() -> void:
	if panel_root != null:
		UiBuilder.settle_authored_rects(panel_root)
	var bar := get_node_or_null("TitleBar")
	if bar != null:
		UiBuilder.settle_authored_rects(bar)

## The title bar's rect: the strip inset from both sides at the caption's
## authored row (TITLE_INSET, TITLE_TEXT_Y, TITLE_TEXT_HEIGHT), as wide as the
## window now is -- or, on a registry-framed window, CIFMainFrame's caption
## (10, 12, width - 21, 12). Stored where the settling pass reads it.
func _place_title_bar(bar: Control) -> void:
	var rect := Rect2(Vector2(TITLE_INSET, TITLE_TEXT_Y),
		Vector2(size.x - TITLE_INSET * 2.0, TITLE_TEXT_HEIGHT))
	if registry_def != null:
		rect = Rect2(Vector2(MAINFRAME_CAPTION_X, MAINFRAME_CAPTION_Y),
			Vector2(size.x - MAINFRAME_STRIP_WIDTH_LESS, MAINFRAME_CAPTION_HEIGHT))
	bar.set_meta(UiBuilder.AUTHORED_RECT_META, rect)
	bar.position = rect.position
	bar.size = rect.size

func _add_title_bar(title: String) -> void:
	var bar := Label.new()
	bar.name = "TitleBar"
	bar.text = title
	bar.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# CIFMainFrame gives its caption vertical alignment 0, the top.
	bar.vertical_alignment = VERTICAL_ALIGNMENT_TOP if registry_def != null \
		else VERTICAL_ALIGNMENT_CENTER
	_place_title_bar(bar)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_theme_color_override("font_color", MAINFRAME_CAPTION_COLOUR if registry_def != null \
		else Color(0.93, 0.87, 0.70))
	# The client's own UI font, so a window title doesn't sit in Godot's
	# default face over authored artwork.
	if _builder != null:
		var font := _builder.font_at(0)
		if font != null:
			bar.add_theme_font_override("font", font)
		# Index 0's size, which is what the client's own controls use.
		bar.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	add_child(bar)

	# A layout that declares its own close button already built one, and
	# putting a second over it would be wrong in both look and behaviour.
	var own_close := _find_close_button()
	if own_close != null:
		own_close.pressed.connect(_on_close_pressed)
		return

	var close := TextureButton.new()
	close.name = "CloseButton"
	close.ignore_texture_size = true
	close.stretch_mode = TextureButton.STRETCH_SCALE
	close.position = _close_position()
	close.size = Vector2(CLOSE_BUTTON_SIZE, CLOSE_BUTTON_SIZE)
	close.focus_mode = Control.FOCUS_NONE
	if _builder != null:
		close.texture_normal = _builder.load_texture(UiBuilder.CLOSE_BUTTON_DDJ)
		close.texture_hover = _builder.load_texture(
			UiBuilder.CLOSE_BUTTON_DDJ.replace(".ddj", "_focus.ddj"))
		close.texture_pressed = _builder.load_texture(
			UiBuilder.CLOSE_BUTTON_DDJ.replace(".ddj", "_press.ddj"))
	close.pressed.connect(_on_close_pressed)
	add_child(close)

## Where the close button goes: CIFMainFrame's (width - 26, 10) on a
## registry-framed window, otherwise ifalchemybox's (width - 26, 12).
func _close_position() -> Vector2:
	if registry_def != null:
		return Vector2(size.x - MAINFRAME_CLOSE_INSET, MAINFRAME_CLOSE_Y)
	return Vector2(size.x - CLOSE_BUTTON_INSET, CLOSE_BUTTON_Y)

## Whether a press at `local` starts a drag: CIFMainFrame's CIFDragableArea
## (10, 0, width - 21, 34) on a registry-framed window, otherwise the top
## TITLE_BAR_HEIGHT pixels.
func in_drag_strip(local: Vector2) -> bool:
	if registry_def != null:
		return Rect2(MAINFRAME_CAPTION_X, 0.0, size.x - MAINFRAME_STRIP_WIDTH_LESS,
			MAINFRAME_DRAG_HEIGHT).has_point(local)
	return local.y <= TITLE_BAR_HEIGHT

## The close button the layout declared, if it declared one. Four of the six
## CIFCloseButtons in the archive name no artwork of their own, which is why
## UiBuilder gives that type the client's hardcoded default.
func _find_close_button() -> BaseButton:
	if panel_root == null:
		return null
	for child in panel_root.get_children():
		if child is BaseButton and (child as Node).name.to_upper().contains("CLOSE"):
			return child as BaseButton
	return null

func _on_close_pressed() -> void:
	hide()
	closed.emit()

## Drag by the title strip, and raise on any click so a click brings the
## window to the front the way every other window manager behaves.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			move_to_front()
			if in_drag_strip(mb.position):
				_dragging = true
				_drag_offset = mb.position
				accept_event()
		else:
			_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		position += (event as InputEventMouseMotion).position - _drag_offset
		_clamp_to_viewport()
		dragged.emit()
		accept_event()

## Keeps a dragged window from being lost off the edge of the screen --
## always leaves the title bar reachable.
func _clamp_to_viewport() -> void:
	var view := get_viewport_rect().size
	position.x = clampf(position.x, -size.x + 60.0, view.x - 60.0)
	position.y = clampf(position.y, 0.0, view.y - TITLE_BAR_HEIGHT)

## Centres the window in the viewport, for a first open.
func centre() -> void:
	var view := get_viewport_rect().size
	position = ((view - size) / 2.0).round()

## Sets the title-bar caption after the window is built -- for a window
## whose title is not fixed, like the NPC talk box named for whoever is
## being talked to.
func set_title(title: String) -> void:
	var bar := get_node_or_null("TitleBar") as Label
	if bar != null:
		bar.text = title

## Finds a control the authored layout named, or null.
func node(control_name: String) -> Node:
	if panel_root == null:
		return null
	return panel_root.find_child(control_name, true, false)
