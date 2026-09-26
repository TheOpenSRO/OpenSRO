extends HudWindow
class_name HudWorldmap

## The world map window.
##
## Unlike the panel windows this is **registry-framed**: `GDR_WORLDMAP` is a
## `CIFWorldMap` at `100,100,652,424` on `interface\frame\mframe_wnd_` in
## resinfo\ginterface.txt, and its own layout file carries nothing but three
## buttons -- the map is the control's own drawing. So the frame comes from
## the registry, the interior is ours to draw, and the buttons come from the
## layout on top.
##
## What goes in the interior is not ours, though. Every number below is out
## of `worldmap_mapinfo.txt`, read through WorldmapInfoReader:
##
##   * which tile covers which region, and where it sits in the grid
##   * the world-space box each map covers, and so the scale -- 6.0 world
##     units to a pixel on the world map, 0.75 on a city's own map
##   * therefore where the player marker goes, with no fitting
##
## See docs/protocol/WORLDMAP_FORMAT.md.
##
## The marker artwork is `interface\minimap\mm_sign_character.ddj`, which is
## not a guess either: the client's world map loads exactly seven textures
## besides the map tiles, and that is one of them, alongside
## `wmap_sign_party`, `wmap_sign_apprenticeship`, `wmap_sign_questnpc`,
## `wmap_sign_huntingpoint` and the four `wmap_window_edge_N` pieces.

const WINDOW_NAME := "GDR_WORLDMAP"
const LAYOUT_PATH := "resinfo\\ifworldmap.txt"
const MARKER_DDJ := "interface\\minimap\\mm_sign_character.ddj"

## The button that switches from a city's own map to the whole world.
const BTN_TO_WORLD := "GDR_WM_BTN_TO_WMAP"

## The name plate the world map draws a label on: a horizontal three-slice,
## an 8x24 cap each side of a 4x24 middle that tiles. Measured from the
## artwork, the same scheme as `com_bar01_`.
const PLATE_SIDE_DDJ := "interface\\worldmap\\wmap_name_side.ddj"
const PLATE_MIDDLE_DDJ := "interface\\worldmap\\wmap_name_middle.ddj"
const PLATE_HEIGHT := 24.0
## Padding inside the plate, each side of the text. **Ours, not authored**:
## the artwork gives the plate's height and its three pieces, and nothing
## found says how much room a caption gets.
const PLATE_TEXT_PAD := 8.0

## How far beyond the visible rect to keep tiles loaded, so a drag does not
## reveal an empty column before the next frame fills it.
const TILE_MARGIN := 128.0

var _table: WorldmapInfoReader.ParsedTable
## The map currently drawn -- the world map, or a city's own.
var _current: WorldmapInfoReader.MapInfo
var _viewport: Control
var _canvas: Control
var _marker: TextureRect
## Archive path -> the TextureRect showing it, for the tiles built so far.
var _tiles := {}
var _panning := false
var _pan_from := Vector2.ZERO
## Set once the player has switched to the world map by hand, so a region
## change does not drop them back onto a city map.
var _pinned_to_world := false
var _player_world := Vector2.ZERO
var _player_region := Vector2i(-1, -1)
## The strip that drags the window: this frame's own top border rather than
## HudWindow's 42, which is ifalchemybox's number for a different frame set.
## `mframe_wnd_`'s corners are 68 tall.
var _title_strip := 0.0

func _init(builder: UiBuilder = null) -> void:
	_builder = builder

## Builds the window. Returns false, having built nothing, if the registry
## entry or the map table is missing -- the caller should treat that as
## "this archive cannot show a world map" rather than open an empty box.
func build_worldmap() -> bool:
	if _builder == null:
		return false
	var def := _builder.window_def(WINDOW_NAME)
	if def == null or def.rect.size.x <= 0 or def.rect.size.y <= 0:
		return false
	_table = _load_table()
	if _table == null or _table.world() == null:
		return false

	custom_minimum_size = Vector2(def.rect.size)
	size = Vector2(def.rect.size)
	mouse_filter = Control.MOUSE_FILTER_PASS

	# The frame, at the window's own origin rather than the registry's
	# screen position -- `position` here is where the window sits, which is
	# the caller's business.
	var frame := _builder.build_control(def)
	if frame != null:
		frame.position = Vector2.ZERO
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(frame)

	var insets := _frame_insets(def.ddj)
	_title_strip = insets.position.y
	_build_interior(insets)

	# The three authored buttons go on top of everything.
	var layout := _builder.load_layout(LAYOUT_PATH)
	if layout != null:
		panel_root = _builder.build_section(layout, "Create")
		if panel_root != null:
			add_child(panel_root)
			var to_world := panel_root.find_child(BTN_TO_WORLD, true, false)
			if to_world is BaseButton:
				(to_world as BaseButton).pressed.connect(_on_to_world_pressed)
			# GDR_WM_BTN_WNDSIZE and GDR_WM_BTN_AUTO_MOVE are left inert.
			# The archive has both a 268-wide and a 652-wide window bottom,
			# so the size button plainly toggles between two window widths,
			# but nothing authored says what the small window's *height* is
			# or which controls move -- and auto-move needs a path to an
			# arbitrary world point, which the client does not have yet.
			_disable(panel_root, "GDR_WM_BTN_WNDSIZE")
			_disable(panel_root, "GDR_WM_BTN_AUTO_MOVE")

	_add_title_bar(_builder.resolve_text(_table.world().name_key))
	_show_map(_table.world())
	_settle()
	return true

## Reads the map table out of the archive the builder is holding.
func _load_table() -> WorldmapInfoReader.ParsedTable:
	var archive := _builder.media_archive()
	if archive == null:
		return null
	var entry := ObjectLoader.find_file(archive, WorldmapInfoReader.TABLE_PATH)
	if entry == null:
		return null
	return WorldmapInfoReader.parse(archive.read_file(entry))

## How far in from each edge the frame's artwork reaches, measured from the
## pieces themselves rather than assumed: `mframe_wnd_` is 40 wide down the
## sides, 68 tall across the top and 48 across the bottom. Reading it from
## the art means a window on a different frame set still gets it right.
func _frame_insets(base: String) -> Rect2:
	var lu := _builder.load_texture(base + "left_up.ddj")
	var ld := _builder.load_texture(base + "left_down.ddj")
	if lu == null:
		return Rect2(0, 0, 0, 0)
	var side := float(lu.get_width())
	var top := float(lu.get_height())
	var bottom := float(ld.get_height()) if ld != null else side
	return Rect2(side, top, side, bottom)

func _build_interior(insets: Rect2) -> void:
	_viewport = Control.new()
	_viewport.name = "MapViewport"
	_viewport.position = Vector2(insets.position.x, insets.position.y)
	_viewport.size = Vector2(
		size.x - insets.position.x - insets.size.x,
		size.y - insets.position.y - insets.size.y)
	_viewport.clip_contents = true
	_viewport.mouse_filter = Control.MOUSE_FILTER_STOP
	_viewport.gui_input.connect(_on_viewport_input)
	add_child(_viewport)

	_canvas = Control.new()
	_canvas.name = "MapCanvas"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport.add_child(_canvas)

	_marker = TextureRect.new()
	_marker.name = "PlayerMarker"
	_marker.texture = _builder.load_texture(MARKER_DDJ)
	_marker.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _marker.texture != null:
		_marker.size = _marker.texture.get_size()
		_marker.pivot_offset = _marker.size / 2.0
	_marker.visible = false
	_canvas.add_child(_marker)

## Switches the interior to a map: the world grid, or a single image.
func _show_map(info: WorldmapInfoReader.MapInfo) -> void:
	if info == null or info == _current:
		return
	_current = info
	for node in _tiles.values():
		node.queue_free()
	_tiles.clear()
	_canvas.size = Vector2(info.draw_size)
	_canvas.position = Vector2.ZERO

	if not info.is_tiled():
		var tex := _map_texture(_builder.load_texture(info.addr), info)
		if tex != null:
			var whole := TextureRect.new()
			whole.name = "MapImage"
			whole.texture = tex
			whole.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			whole.stretch_mode = TextureRect.STRETCH_SCALE
			whole.size = Vector2(info.draw_size)
			whole.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_canvas.add_child(whole)
			_canvas.move_child(whole, 0)
			_tiles[info.addr] = whole

	_build_place_labels(info)
	var bar := get_node_or_null("TitleBar")
	if bar is Label:
		(bar as Label).text = _builder.resolve_text(info.name_key)
	_centre_on_player()
	_refresh_tiles()
	_place_marker()

## On the whole-world view, a clickable name plate for every local map the
## table carries that falls inside it -- the cities, the fortresses, the
## arenas. Where each one goes is not fitted: `world_min`/`world_max` give
## the box that map covers, and the plate sits at the middle of it, which
## the world map's own transform turns into a pixel.
##
## **The choice of the box's middle is ours.** The client draws its own
## location signs from `wmap_sign_location.ddj` and nothing found says
## where it puts them; what is authored is the box, and the box's middle is
## the one point in it that needs no further number.
func _build_place_labels(info: WorldmapInfoReader.MapInfo) -> void:
	var old := _canvas.get_node_or_null("PlaceLabels")
	if old != null:
		old.free()
	if _table == null or info != _table.world():
		return
	var layer := Control.new()
	layer.name = "PlaceLabels"
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(layer)
	for other in _table.maps:
		if other.type != WorldmapInfoReader.TYPE_LOCAL:
			continue
		var text := _builder.resolve_text(other.name_key)
		if text == "" or text == other.name_key:
			# No resolvable name: better nothing than a raw `SN_ZONE_*`.
			continue
		var lo := other.world_min()
		var hi := other.world_max()
		if lo == hi:
			# A placeholder row with every region bound zero -- three of
			# the archive's do that.
			continue
		var middle := Vector2(lo + hi) / 2.0
		var at := info.pixel_for_world(middle)
		if at.x < 0.0 or at.y < 0.0 or at.x > info.draw_size.x or at.y > info.draw_size.y:
			# Somewhere the world map does not reach -- Jupiter and the
			# arenas are off its east edge.
			continue
		var plate := _name_plate(text)
		plate.position = at - plate.size / 2.0
		plate.gui_input.connect(_on_plate_input.bind(other))
		layer.add_child(plate)
	# The player's own marker belongs over the labels, not under them.
	if _marker != null:
		_canvas.move_child(_marker, -1)

## One name plate: `wmap_name_side` capped each end of a tiled
## `wmap_name_middle`, with the caption over it.
func _name_plate(text: String) -> Control:
	var side := _builder.load_texture(PLATE_SIDE_DDJ)
	var middle := _builder.load_texture(PLATE_MIDDLE_DDJ)
	var cap := float(side.get_width()) if side != null else 0.0
	var font := _builder.font_at(0)
	var text_width := 0.0
	if font != null:
		text_width = font.get_string_size(
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, UiBuilder.FONT_SIZES[0]).x

	var plate := Control.new()
	plate.name = "Plate"
	plate.size = Vector2(cap * 2.0 + text_width + PLATE_TEXT_PAD * 2.0, PLATE_HEIGHT)
	plate.mouse_filter = Control.MOUSE_FILTER_STOP

	if middle != null:
		var body := TextureRect.new()
		body.texture = middle
		body.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		body.stretch_mode = TextureRect.STRETCH_TILE
		body.position = Vector2(cap, 0.0)
		body.size = Vector2(plate.size.x - cap * 2.0, PLATE_HEIGHT)
		body.mouse_filter = Control.MOUSE_FILTER_IGNORE
		plate.add_child(body)
	if side != null:
		for i in 2:
			var end := TextureRect.new()
			end.texture = side
			end.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			end.position = Vector2(0.0 if i == 0 else plate.size.x - cap, 0.0)
			end.size = Vector2(cap, PLATE_HEIGHT)
			# The right cap is the left one turned round; the archive has
			# one piece, not two.
			end.flip_h = i == 1
			end.mouse_filter = Control.MOUSE_FILTER_IGNORE
			plate.add_child(end)

	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size = plate.size
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font != null:
		label.add_theme_font_override("font", font)
		label.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	plate.add_child(label)
	return plate

func _on_plate_input(event: InputEvent, info: WorldmapInfoReader.MapInfo) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and (event as InputEventMouseButton).pressed:
		_pinned_to_world = false
		_show_map(info)

## Builds the tiles that overlap what can be seen, and no others. The world
## map is 363 tiles; at 128x128 apiece that is a lot of texture to hold for
## a window whose viewport shows about fifteen of them.
func _refresh_tiles() -> void:
	if _current == null or not _current.is_tiled():
		return
	var tile := Vector2(_current.texture_size)
	if tile.x <= 0.0 or tile.y <= 0.0:
		return
	var span := visible_tile_range(_canvas.position, _viewport.size, tile,
		_current.tiles_across(), _current.tiles_down())
	var step_y: int = maxi(1, _current.regions_per_tile.x)
	var step_x: int = maxi(1, _current.regions_per_tile.y)
	for i in range(span.position.x, span.end.x):
		for j in range(span.position.y, span.end.y):
			# The first name component ascends from `left` and the second
			# descends from `top`, so index (i, j) is exactly this pair.
			var path := "%s%dx%d.ddj" % [_current.addr,
				_current.region_left + i * step_y, _current.region_top - j * step_x]
			if _tiles.has(path):
				continue
			var tex := _map_texture(_builder.load_texture(path), _current)
			if tex == null:
				# Recorded either way, so a missing tile is looked up once
				# rather than every frame the window is open.
				_tiles[path] = _placeholder(Vector2(i, j) * tile, tile)
				continue
			var tr := TextureRect.new()
			tr.texture = tex
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_SCALE
			tr.position = Vector2(i, j) * tile
			tr.size = tile
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_canvas.add_child(tr)
			_canvas.move_child(tr, 0)
			_tiles[path] = tr

## The part of a map image that is actually map.
##
## `Pic Area` against `Texture Size` is not decoration: a city's map is
## stored 1024x1024 but only its top 1024x768 is drawn -- Jangan's row says
## texture 1024x1024, pic area 1024x768, draw 1024x768. Stretching the whole
## texture into the draw size instead squashed the map and left the padding
## showing as a blank band across the bottom of the window. The world map's
## own tiles have pic area equal to texture size, so this costs them
## nothing.
func _map_texture(tex: Texture2D, info: WorldmapInfoReader.MapInfo) -> Texture2D:
	if tex == null:
		return null
	var used := Vector2(info.pic_area)
	if used.x <= 0.0 or used.y <= 0.0 or used == tex.get_size():
		return tex
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = Rect2(Vector2.ZERO, used)
	return atlas

## Which tile indices overlap what can be seen, as a half-open Rect2i:
## columns `position.x` up to but not including `end.x`, rows likewise.
## Empty when the map is scrolled entirely off the viewport.
##
## `canvas_pos` is the map's offset inside the viewport, so it is zero or
## negative once the map is larger than the window; the visible box in map
## coordinates is therefore `-canvas_pos` to `-canvas_pos + viewport`.
static func visible_tile_range(canvas_pos: Vector2, viewport: Vector2, tile: Vector2,
		across: int, down: int, margin: float = TILE_MARGIN) -> Rect2i:
	if tile.x <= 0.0 or tile.y <= 0.0 or across <= 0 or down <= 0:
		return Rect2i()
	var view := Rect2(-canvas_pos, viewport).grow(margin)
	var i0: int = maxi(0, int(floorf(view.position.x / tile.x)))
	var i1: int = mini(across - 1, int(floorf((view.position.x + view.size.x) / tile.x)))
	var j0: int = maxi(0, int(floorf(view.position.y / tile.y)))
	var j1: int = mini(down - 1, int(floorf((view.position.y + view.size.y) / tile.y)))
	if i1 < i0 or j1 < j0:
		return Rect2i()
	return Rect2i(i0, j0, i1 - i0 + 1, j1 - j0 + 1)

func _placeholder(at: Vector2, tile: Vector2) -> Control:
	var node := Control.new()
	node.position = at
	node.size = tile
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(node)
	_canvas.move_child(node, 0)
	return node

## Where the player is, in the same terms the minimap is told.
##
##   world X = (region_y - 135) * 192 + local_x / 10
##   world Y = (region_x -  92) * 192 + local_z / 10
##
## which is the transform NIFWorldMap.cpp uses on the map's own bounds, so
## a marker needs no fitting: the map says which world box it covers and
## the position falls where it falls.
func update_player(region_x: int, region_y: int, local_pos: Vector3) -> void:
	_player_world = Vector2(
		(region_y - WorldmapInfoReader.REGION_Y_ORIGIN) * WorldmapInfoReader.REGION_SPAN
			+ local_pos.x / 10.0,
		(region_x - WorldmapInfoReader.REGION_X_ORIGIN) * WorldmapInfoReader.REGION_SPAN
			+ local_pos.z / 10.0)
	var moved_region := Vector2i(region_x, region_y) != _player_region
	var first_fix := _player_region.x < 0
	_player_region = Vector2i(region_x, region_y)
	if _table != null and moved_region and not _pinned_to_world:
		# Walking into a city puts you on that city's own map, which is
		# what the "to world map" button exists to undo.
		var local := _table.local_for_region(region_x, region_y)
		_show_map(local if local != null else _table.world())
	if first_fix:
		# The window can be built and even opened before the first position
		# arrives, and centring on a player who is nowhere yet leaves the
		# view parked in the middle of the map. Centre once it is known.
		_centre_on_player()
		_refresh_tiles()
	_place_marker()

func _place_marker() -> void:
	if _marker == null or _current == null:
		return
	if _player_region.x < 0 or not _current.covers_region(_player_region.x, _player_region.y):
		_marker.visible = false
		return
	_marker.visible = true
	_marker.position = _current.pixel_for_world(_player_world) - _marker.size / 2.0

## Puts the player under the middle of the viewport, clamped to the map.
func _centre_on_player() -> void:
	if _current == null:
		return
	var target := _viewport.size / 2.0
	if _player_region.x >= 0 and _current.covers_region(_player_region.x, _player_region.y):
		target -= _current.pixel_for_world(_player_world)
	else:
		target -= _canvas.size / 2.0
	_canvas.position = _clamp_scroll(target)

func _clamp_scroll(at: Vector2) -> Vector2:
	return clamp_scroll(at, _canvas.size, _viewport.size)

## A map smaller than the viewport is centred rather than pinned to a
## corner; a larger one may not be dragged past its own edges.
static func clamp_scroll(at: Vector2, canvas: Vector2, viewport: Vector2) -> Vector2:
	var slack := canvas - viewport
	var out := at
	out.x = (-slack.x / 2.0) if slack.x <= 0.0 else clampf(at.x, -slack.x, 0.0)
	out.y = (-slack.y / 2.0) if slack.y <= 0.0 else clampf(at.y, -slack.y, 0.0)
	return out

func _on_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		_panning = mb.pressed
		_pan_from = mb.position
		if mb.pressed:
			move_to_front()
		_viewport.accept_event()
	elif event is InputEventMouseMotion and _panning:
		var mm := event as InputEventMouseMotion
		_canvas.position = _clamp_scroll(_canvas.position + mm.position - _pan_from)
		_pan_from = mm.position
		_refresh_tiles()
		_viewport.accept_event()

func _on_to_world_pressed() -> void:
	show_world()

## Switches to the whole-world view and stays there: walking into a city no
## longer drops the window back onto that city's own map.
func show_world() -> void:
	_pinned_to_world = true
	if _table != null:
		_show_map(_table.world())
	_centre_on_player()
	_refresh_tiles()

static func _disable(root: Node, control_name: String) -> void:
	var node := root.find_child(control_name, true, false)
	if node is BaseButton:
		(node as BaseButton).disabled = true

## Opens the window centred on the screen the first time, and puts the
## player back under the middle of the map each time.
func open() -> void:
	if not visible:
		show()
		move_to_front()
	_centre_on_player()
	_refresh_tiles()

func toggle() -> void:
	if visible:
		hide()
	else:
		open()

## Drag by this frame's own top border rather than HudWindow's 42-pixel
## strip, which is a different frame set's number.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			move_to_front()
			if mb.position.y <= _title_strip:
				_dragging = true
				_drag_offset = mb.position
				accept_event()
		else:
			_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		position += (event as InputEventMouseMotion).position - _drag_offset
		_clamp_to_viewport()
		accept_event()
