extends Control
class_name HudWindow

## One floating game window -- Inventory, Character, Skill, Party and the
## rest -- built from the client's own authored layout.
##
## Panel windows are self-framed: unlike the underbar and minimap, they have
## no entry in resinfo\ginterface.txt. Their own layout file carries a
## CIFFrame (or CIFStretchWnd) at the origin whose `ddj` is an 8-slice base
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

const UiBuilder = preload("res://scripts/ui/ui_builder.gd")
const UiLayoutParser = preload("res://scripts/ui/ui_layout_parser.gd")

signal closed

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

var _builder: UiBuilder
var _dragging := false
var _drag_offset := Vector2.ZERO

## The built layout section. Panel bindings look their controls up in here
## by the authored names (GDR_INVENTORY_LATTICE, GDR_PMI_TXT_HP, ...).
var panel_root: Control

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
func build(builder: UiBuilder, layout_path: String, title: String,
		extra_sections: PackedStringArray = PackedStringArray()) -> bool:
	_builder = builder
	if builder == null:
		return false
	var layout := builder.load_layout(layout_path)
	if layout == null:
		return false
	var sec := layout.get_section("Create")
	if sec == null or sec.controls.is_empty():
		return false

	var window_size := UiBuilder.section_size(sec)
	if window_size == Vector2.ZERO:
		return false
	custom_minimum_size = window_size
	size = window_size
	# The window itself is opaque chrome and should take clicks (that is
	# what stops a click landing on the world behind it), but it must also
	# not steal them from its own children, so PASS rather than STOP.
	mouse_filter = Control.MOUSE_FILTER_PASS

	# No interior fill is added here any more. A window's body is filled by
	# its own `CIFNormalTile` controls, which the layout declares and
	# UiBuilder now builds -- see _build_tile. Two earlier attempts (a flat
	# colour chosen by eye, then one sampled from the frame's edge pixels)
	# were both working around a control type that simply was not handled.

	panel_root = builder.build_section(layout, "Create")
	if panel_root == null:
		return false
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

	_add_title_bar(_authored_title(builder, sec, title))
	set_process(true)
	return true

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

## Puts every control back on the rect its layout asked for.
##
## Godot clamps a Control's size up to its minimum, and a Label's minimum is
## computed from the theme's default font until the theme cache refreshes --
## which takes a frame in the tree. Until then every authored row is forced
## to the height of Godot's own 16px face: ifplayerinfo's 12-pixel exp rows
## came out 23 tall, and so did every window's close button. So the rects
## are applied once more after a frame has passed.
## Frames left in the settling pass. A Label's minimum size is computed
## from the theme's *default* font until its theme cache refreshes, and
## Godot clamps `size` up to that minimum, so a rect applied too early is
## silently inflated -- ifplayerinfo's 12-pixel exp rows came out 23 tall,
## the height of Godot's own 16px face. One frame is normally enough; a
## few are cheap and remove the guesswork about exactly which one.
const SETTLE_FRAMES := 3
var _settle_frames_left := SETTLE_FRAMES

func _process(_delta: float) -> void:
	_settle_frames_left -= 1
	if _settle_frames_left <= 0:
		set_process(false)
	if panel_root != null and is_instance_valid(panel_root):
		UiBuilder.apply_authored_rects(panel_root)
	var bar := get_node_or_null("TitleBar")
	if bar is Control:
		var label := bar as Control
		label.custom_minimum_size = Vector2.ZERO
		label.size = Vector2(size.x - TITLE_INSET * 2.0, TITLE_TEXT_HEIGHT)

func _add_title_bar(title: String) -> void:
	var bar := Label.new()
	bar.name = "TitleBar"
	bar.text = title
	bar.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bar.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.position = Vector2(TITLE_INSET, TITLE_TEXT_Y)
	bar.size = Vector2(size.x - TITLE_INSET * 2.0, TITLE_TEXT_HEIGHT)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_theme_color_override("font_color", Color(0.93, 0.87, 0.70))
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
	close.position = Vector2(size.x - CLOSE_BUTTON_INSET, CLOSE_BUTTON_Y)
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
			if mb.position.y <= TITLE_BAR_HEIGHT:
				_dragging = true
				_drag_offset = mb.position
				accept_event()
		else:
			_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		position += (event as InputEventMouseMotion).position - _drag_offset
		_clamp_to_viewport()
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
