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
## What the layout does *not* carry is the title bar text or the close
## button -- the real client draws those itself over the frame's top edge.
## Those are added here, and their placement is this project's own choice,
## not recovered data.

const UiBuilder = preload("res://scripts/ui/ui_builder.gd")
const UiLayoutParser = preload("res://scripts/ui/ui_layout_parser.gd")

signal closed

## Height of the frame's own title strip. The 8-slice bases used by real
## panels have a tall top piece (`mframe_wnd_left_up.ddj` is 40x68,
## `mid_up` 128x68), and the title sits inside it.
const TITLE_BAR_HEIGHT := 22.0
const CLOSE_BUTTON_SIZE := 16.0

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
func build(builder: UiBuilder, layout_path: String, title: String) -> bool:
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

	# Interior fill, behind everything.
	#
	# **This colour is ours, not authored.** Every 8-slice frame set in the
	# archive -- mframe_wnd_, int_window_, game_window_, event_sub_wnd_ and
	# the rest, thirty-odd of them -- contains exactly eight pieces: four
	# corners and four edges, and **no centre**. A window's interior is
	# therefore not painted by its frame art, and nothing found so far says
	# what the real client fills it with. Left unfilled the windows are
	# see-through, which is worse than a stand-in, so this is a flat dark
	# fill matching what the reference screenshots show. Replace it the
	# moment the real fill is identified.
	var fill := ColorRect.new()
	fill.name = "InteriorFill"
	fill.color = Color(0.055, 0.055, 0.07, 0.94)
	fill.size = window_size
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(fill)

	panel_root = builder.build_section(layout, "Create")
	if panel_root == null:
		return false
	# The section root is IGNORE so it doesn't eat world clicks when used
	# for a transparent HUD overlay; inside a window the window itself
	# already blocks, and the children keep their own filters.
	add_child(panel_root)

	_add_title_bar(title)
	return true

func _add_title_bar(title: String) -> void:
	var bar := Label.new()
	bar.name = "TitleBar"
	bar.text = title
	bar.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bar.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.position = Vector2(0, 2)
	bar.size = Vector2(size.x, TITLE_BAR_HEIGHT)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_theme_color_override("font_color", Color(0.93, 0.87, 0.70))
	# The client's own UI font, so a window title doesn't sit in Godot's
	# default face over authored artwork.
	if _builder != null:
		var font := _builder.font_at(0)
		if font != null:
			bar.add_theme_font_override("font", font)
		bar.add_theme_font_size_override("font_size", 12)
	add_child(bar)

	var close := Button.new()
	close.name = "CloseButton"
	close.text = "x"
	close.position = Vector2(size.x - CLOSE_BUTTON_SIZE - 6.0, 4.0)
	close.size = Vector2(CLOSE_BUTTON_SIZE, CLOSE_BUTTON_SIZE)
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(func() -> void:
		hide()
		closed.emit())
	add_child(close)

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

## Finds a control the authored layout named, or null.
func node(control_name: String) -> Node:
	if panel_root == null:
		return null
	return panel_root.find_child(control_name, true, false)
