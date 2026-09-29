extends HudWindow
class_name HudWorldmap

## The world map window: the retail client's `CNIFWorldMap`, built from
## `res_ui\worldmapguide.2dt` the way its class assembles it. Every address is
## `sro_client.exe`'s (md5 2a5794b72c90908d945be8b3f3f2edd4);
## docs/RE_COMPLETION.md has this window's round and docs/protocol/2DT_FORMAT.md
## the file format. Each fact below says whether it was **read** out of the
## binary, **measured** in the retail files, or is **inferred** or **ours**.
##
## **What M opens (read).** The default key table (0x7778be) puts 'M' in slot
## 7; 0x778310 turns slot 7 into command 0x4d, and the dispatch 0x780610 sends
## 0x4d through its jump table (0x780e48 / 0x780e00) to 0x78087d, which calls
## 0x79abe0. The minimap's map button (its message map sends id 8, which is
## ifminimap's GDR_MINIMAP_BTN_TOG_MAP, to 0x6606a0) jumps to the same
## 0x79abe0. 0x79abe0 asks the `.2dt` window manager 0x115dd40 for window 28;
## the first time it loads `res_ui\worldmapguide.2dt` (0x469140), otherwise it
## toggles the window's visibility (0x46d740) and calls 0x79ab80; either way it
## then centres window 28 on the screen (0x798c50). Escape hides it too
## (0x78b6c7 -> 0x79d620, at 0x79d785..0x79d7c2; HudPanels._escape_close). Record 0 of that file is
## `CNIFWorldMap`, a CNIFMainFrame 650x422, id 28 (measured); its runtime class
## (descriptor 0xee933c, size 0x229ec) is the NIFWorldMap.cpp world map.
##
## **The older CIFWorldMap is not what players see.** `GDR_WORLDMAP`
## (CIFWorldMap, `resinfo\ifworldmap.txt`, the window this class used to build)
## is created with ginterface.txt's Create section, but the only getters for it
## -- 0x799740 and 0x79db90 -- have no caller: no call or jump to either in the
## disassembly, and neither address appears anywhere in the exe's bytes. The
## only other code that fetches id 28 from that layout saves, restores or
## resets its position (0x79a9b0, 0x79e620, 0x79eb20, and 0x79f030, which
## centres a child with id 28 through 0x79ac50 and moves GDR_WORLDMAP by
## (0, -60) with 0xb90db0). Nothing shows it; ginterface.txt gives it Style 64,
## and the layout builder hides a style-0x40 control (0x8b5710..0x8b5726).
##
## **The window as the client leaves it** (every item read):
##
## - The map is drawn in the window's own area at (6, 34), 640x384 in the big
##   size and 256x256 in the small one (0x60f4d0, the vslot 0xcc that SetPos
##   0x620550 calls), over the frame and under the children, with the four
##   4x4 `wmap_window_edge_N` pieces at its corners (0x60f350 lays the quads,
##   0x61c4e0 draws them: edge_1 top-left, edge_2 top-right, edge_4
##   bottom-right, edge_3 bottom-left, each texture whole and unflipped).
## - OnCreate (0x620f70): auto-move on (+0x7b1 = 1, 0x620fab), the auto-move
##   button 20 shown (its authored manual art stays: OnCreate does not call
##   0x616870), the floor spinner 4 hidden, the guide 11 hidden, the check box 31 unchecked, the bottom
##   frame 26 and the side tab 13 given +0x1c0 = 1 (the flag CNIFWnd's mouse
##   handler 0x46c8e0 returns as "handled", so they eat clicks -- the meaning
##   is inferred), and the world button 6 given UIIT_PAG_WORLDMAP as its hover
##   text (style 0x80, 0x46d880 / 0x46d7d0; that it is a tooltip is inferred,
##   as for the guild window).
## - At game entry 0x786f30 calls 0x616b80(1) on it (0x78780b): auto-move on,
##   and 0x616870 gives button 20 `wmap_button_automatic.ddj` and the hover
##   text UIIT_STT_WORLDMAP_AUTO_MOVE. 0x786f30 is reached from CPSMission's
##   per-frame step (0x84c300 -> 0x84c060) once a load is flagged; whether
##   that happens after every teleport, turning auto-move back on each time,
##   is **not established**. This client does it once, when it builds the
##   window.
## - Six records are authored 0x0 (26, both 30s, 31, 13 and 15; measured, and
##   no other `.2dt` file has any). A static's quad is its rect times a scale
##   that starts at 1.0 (0x46cff0, 0x46c4f6), the factory passes the record's
##   rect unchanged (0x48f9c9..0x48fa93, 0x489eec), and no code resizes them
##   (the only vslot 0x54 calls in NIFWorldMap.cpp resize the window itself,
##   0x61ca40 / 0x61cb23, and nothing calls 0xb91b00 there). So they draw
##   nothing, and they are built here at 0x0 too. That the side button 15,
##   and so the guide, cannot be reached with the mouse is **inferred** from
##   the same rect: the hit test 0x46cb40 is inclusive, which leaves a
##   0x0 control one pixel.
##
## The map inside is this project's reading of `worldmap_mapinfo.txt`
## (WorldmapInfoReader, docs/protocol/WORLDMAP_FORMAT.md): which tile covers
## which region, the box each map covers and so the scale, and the player
## marker `interface\minimap\mm_sign_character.ddj` -- one of the textures
## CNIFWorldMap::vslot_040 (0x6160d0) loads.

const TwoDtBuilder = preload("res://scripts/ui/twodt_builder.gd")

const WORLDMAP_2DT := "res_ui\\worldmapguide.2dt"
const MARKER_DDJ := "interface\\minimap\\mm_sign_character.ddj"

## Control ids of worldmapguide.2dt (measured), as the class fetches them.
const ID_WINDOW := 28
const ID_BOTTOM_FRAME := 26
## GetChild(0x1e) returns the first direct child with id 30, record 2 (the
## "level" label at 32767,32767); record 6, the corner static, is also 30.
const ID_LEVEL_LABEL := 30
const ID_LEVEL_CHECK := 31
const ID_WORLD := 6
const ID_AUTO := 20
const ID_GUIDE := 11
const ID_SIDE_TAB := 13
const ID_SIDE_BUTTON := 15
const ID_SIZE := 7
const ID_FLOOR := 4

## The map area (0x60f4d0): the window's own position plus (6, 0x22), 0x280 x
## 0x180 in the big size (+0x97cc = 0) and 0x100 x 0x100 in the small one.
const MAP_AREA_ORIGIN := Vector2(6, 34)
const MAP_AREA_BIG := Vector2(640, 384)
const MAP_AREA_SMALL := Vector2(256, 256)

## The size button's two states (0x61ca20): SetSize 0x28a x 0x1a6 or 0x10c x
## 0x128, and the controls moved to (window x + dx, window y + dy).
const SIZE_BIG := Vector2(650, 422)
const SIZE_SMALL := Vector2(268, 296)
const PLACES_BIG := {ID_SIZE: Vector2(606, 10), ID_WORLD: Vector2(567, 39),
	ID_AUTO: Vector2(605, 39), ID_FLOOR: Vector2(611, 89)}
const PLACES_SMALL := {ID_SIZE: Vector2(224, 10), ID_WORLD: Vector2(185, 39),
	ID_AUTO: Vector2(224, 39), ID_FLOOR: Vector2(229, 89)}

## The guide's side tab and button (0x616ba0): moved to the window's x less
## 0x13d / 0x13 (tab) and less 0x139 / 0xf, y + 0x60 (button), open / closed,
## and the button's art switched.
const SIDE_TAB_OPEN := Vector2(-317, 0)
const SIDE_TAB_CLOSED := Vector2(-19, 0)
const SIDE_BUTTON_OPEN := Vector2(-313, 96)
const SIDE_BUTTON_CLOSED := Vector2(-15, 96)
const SIDE_BUTTON_OPEN_DDJ := "interface\\ifcommon\\com_side_button.ddj"
const SIDE_BUTTON_CLOSED_DDJ := "interface\\ifcommon\\com_side02_button.ddj"

## Button 20's two looks and hover texts (0x616870).
const AUTO_DDJ := "interface\\worldmap\\wmap_button_automatic.ddj"
const MANUAL_DDJ := "interface\\worldmap\\wmap_button_passivity.ddj"
const AUTO_TIP := "UIIT_STT_WORLDMAP_AUTO_MOVE"
const MANUAL_TIP := "UIIT_STT_WORLDMAP_MANUAL_MOVE"
const WORLD_TIP := "UIIT_PAG_WORLDMAP"

## The caption of a local map (0x612fd0, mode 1): UIIT_PAG_LOCALMAP (UTF-16
## at 0xd9911c), " - " (0xd99114), then the map's name.
const LOCAL_CAPTION := "UIIT_PAG_LOCALMAP"
const CAPTION_JOIN := " - "
## Fortress maps: 0x612fd0 tests `id - 1001 <= 998` (0x61311a..0x613120), and
## the table's own comment says fortress map ids start at 1001 (measured).
const FORT_FIRST := 1001
const FORT_LAST := 1999

## The corner pieces in draw order (0x6160d0 loads edge_1, 2, 4, 3 into
## +0x7d8..+0x7e4; 0x61c4e0 pairs them with the top-left, top-right,
## bottom-right and bottom-left quads), each 4x4 (0x60f350; measured, every
## piece is 4x4).
const EDGE_DDJ := ["interface\\worldmap\\wmap_window_edge_1.ddj",
	"interface\\worldmap\\wmap_window_edge_2.ddj",
	"interface\\worldmap\\wmap_window_edge_4.ddj",
	"interface\\worldmap\\wmap_window_edge_3.ddj"]
const EDGE_SIZE := 4.0

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
## reveal an empty column before the next frame fills it. Ours.
const TILE_MARGIN := 128.0

## A table to use instead of the archive's (tests; set before build_worldmap).
var map_table: WorldmapInfoReader.ParsedTable

var _twodt: TwoDtBuilder
var _file: TwoDtReader.TwoDtFile
var _table: WorldmapInfoReader.ParsedTable
## The map currently drawn -- the world map, or a city's own.
var _current: WorldmapInfoReader.MapInfo
var _viewport: Control
var _canvas: Control
var _marker: TextureRect
var _edges: Array[TextureRect] = []
## Archive path -> the TextureRect showing it, for the tiles built so far.
var _tiles := {}
var _panning := false
var _pan_from := Vector2.ZERO
var _player_world := Vector2.ZERO
var _player_region := Vector2i(-1, -1)
## +0x7b1: auto-move. On, the map follows the player (vslot_013 0x624380
## centres on the player every frame, and switches to the player's map when
## it changes, 0x6243f8..0x62452a).
var _auto := true
## +0x229ac: set when auto-move was turned off by a click or the world button
## without button 20's look being updated; the next press of 20 then settles
## on manual (0x616870, 0x61688d..0x6168a7).
var _auto_art_stale := false
## +0x9990: the teleport-selection mode (0x622dd0, entered from the optional
## teleport path). 0x616870 checks the stale flag only when it is 0. This
## client never enters that mode, so it stays false.
var _teleport_select := false
## +0x97cc: 0 big, 1 small.
var _small := false
## +0x7b0: the first ShowWindow(1) centres the map (0x6246c8).
var _shown_once := false

func _init(builder: UiBuilder = null) -> void:
	_builder = builder

## Builds the window. Returns false, having built nothing, if the `.2dt` file
## or the map table is missing -- the caller should treat that as "this
## archive cannot show a world map" rather than open an empty box.
func build_worldmap() -> bool:
	if _builder == null:
		return false
	_file = _builder.load_2dt(WORLDMAP_2DT)
	if _file == null or _file.records.is_empty():
		return false
	_table = map_table if map_table != null else _load_table()
	if _table == null or _table.world() == null:
		return false

	_twodt = TwoDtBuilder.new(_builder)
	panel_root = _twodt.build(_file, WORLDMAP_2DT)
	var window_size := Vector2(_file.root().rect.size)
	custom_minimum_size = window_size
	size = window_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel_root)
	_build_map_area()

	_apply_create_state()
	_add_title_bar("")
	var bar := get_node_or_null("TitleBar") as Label
	if bar != null:
		# The caption's text-object slot 6 is 0 (0x479c0b): top.
		bar.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_wire()
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

## The map area and its corner pieces, over the frame and under the file's
## own controls: the class's render (vslot_013, 0x624380) draws the frame
## (0x4736a0), then the map, then the corners (0x61c4e0), and the children
## draw after their parent.
func _build_map_area() -> void:
	_viewport = Control.new()
	_viewport.name = "MapViewport"
	_viewport.clip_contents = true
	_viewport.mouse_filter = Control.MOUSE_FILTER_STOP
	_viewport.gui_input.connect(_on_viewport_input)

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

	# After the frame's own pieces, before the first record's node.
	var at := panel_root.get_child_count()
	for i in panel_root.get_child_count():
		if panel_root.get_child(i).has_meta(TwoDtBuilder.META_ID):
			at = i
			break
	panel_root.add_child(_viewport)
	panel_root.move_child(_viewport, at)
	_edges.clear()
	for i in EDGE_DDJ.size():
		var edge := TextureRect.new()
		edge.name = "MapEdge%d" % (i + 1)
		edge.texture = _builder.load_texture(EDGE_DDJ[i])
		edge.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		edge.stretch_mode = TextureRect.STRETCH_SCALE
		edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		edge.size = Vector2(EDGE_SIZE, EDGE_SIZE)
		panel_root.add_child(edge)
		panel_root.move_child(edge, at + 1 + i)
		_edges.append(edge)
	_layout_map_area()

## Puts the map area and its corners where 0x60f4d0 and 0x60f350 put them
## for the current size.
func _layout_map_area() -> void:
	var area := Rect2(MAP_AREA_ORIGIN, MAP_AREA_SMALL if _small else MAP_AREA_BIG)
	_viewport.position = area.position
	_viewport.size = area.size
	var corners := [area.position,
		Vector2(area.end.x - EDGE_SIZE, area.position.y),
		area.end - Vector2(EDGE_SIZE, EDGE_SIZE),
		Vector2(area.position.x, area.end.y - EDGE_SIZE)]
	for i in _edges.size():
		_edges[i].position = corners[i]

## The map area's rect in the window.
func map_area() -> Rect2:
	return Rect2(_viewport.position, _viewport.size) if _viewport != null else Rect2()

## The state the OnCreates leave. **They run in reverse file order**
## (docs/protocol/2DT_FORMAT.md): record 14 (CNIFVerticalSpinButtonCtrl,
## whose map has no 0x8065 handler), then record 7 (CNIFWorldMapGuide,
## 0x6290d0: it builds its own list under itself -- not built here, see the
## record), then the window's own, 0x620f70.
func _apply_create_state() -> void:
	var auto_btn := _at(ID_AUTO)
	if auto_btn != null:
		auto_btn.visible = true                                    # 0x620fa7
	_set_visible(ID_FLOOR, false)                                  # 0x620fef
	_set_visible(ID_GUIDE, false)                                  # 0x621025
	var check := _at(ID_LEVEL_CHECK) as BaseButton
	if check != null:
		check.set_pressed_no_signal(false)                         # 0x621013
		var mark := check.get_node_or_null(TwoDtBuilder.MARK_NODE) as Control
		if mark != null:
			mark.visible = false
	for id in [ID_BOTTOM_FRAME, ID_SIDE_TAB]:                      # 0x621034, 0x621043
		var c := _at(id)
		if c != null:
			c.mouse_filter = Control.MOUSE_FILTER_STOP
	var world := _at(ID_WORLD)
	if world != null:
		world.tooltip_text = _builder.resolve_text(WORLD_TIP)      # 0x621059..0x621074
	# 0x620fab: auto-move on. Then game entry (0x78780b): 0x616b80(1), which
	# sets it again and updates button 20 (0x616870).
	_auto = true
	set_auto_move(true)

## 0x616b80: auto-move set, then button 20 updated (0x616870).
func set_auto_move(on: bool) -> void:
	_auto = on
	_refresh_auto_button()

func is_auto_move() -> bool:
	return _auto

## 0x616870. The spinner is hidden first; outside the teleport-selection mode
## (+0x9990 == 0), a stale flag with auto-move on turns auto-move off and
## clears the flag (the press that set it is taken back), and with auto-move
## already off the flag is left set (0x61689b jumps past the clear); then
## button 20 gets
## the look and hover text of the state. In manual on a local map the world
## button is shown, and on a fortress map it is hidden. (Its dungeon branches
## are not built: this client draws no dungeon floor.)
func _refresh_auto_button() -> void:
	_set_visible(ID_FLOOR, false)
	if not _teleport_select and _auto_art_stale and _auto:
		_auto = false
		_auto_art_stale = false
	var btn := _at(ID_AUTO)
	if btn != null:
		btn.tooltip_text = _builder.resolve_text(AUTO_TIP if _auto else MANUAL_TIP)
		if btn is TextureButton:
			_set_button_art(btn as TextureButton, AUTO_DDJ if _auto else MANUAL_DDJ)
	if not _auto and _current != null and not _is_world(_current):
		_set_visible(ID_WORLD, true)
	if _current != null and _is_fort(_current):
		_set_visible(ID_WORLD, false)

func _set_button_art(btn: TextureButton, texture: String) -> void:
	btn.texture_normal = _builder.load_texture(texture)
	btn.texture_hover = _builder.load_texture(_builder._insert_suffix(texture, "_focus"))
	btn.texture_pressed = _builder.load_texture(_builder._insert_suffix(texture, "_press"))
	btn.texture_disabled = _builder.load_texture(_builder._insert_suffix(texture, "_disable"))

func _wire() -> void:
	var world := _at(ID_WORLD) as BaseButton
	if world != null:
		world.pressed.connect(show_world)
	var auto_btn := _at(ID_AUTO) as BaseButton
	if auto_btn != null:
		auto_btn.pressed.connect(_on_auto_pressed)
	var size_btn := _at(ID_SIZE) as BaseButton
	if size_btn != null:
		size_btn.pressed.connect(toggle_size)
	var side := _at(ID_SIDE_BUTTON) as BaseButton
	if side != null:
		side.pressed.connect(toggle_guide)

## Button 20 (message map: id 20 -> 0x617eb0): auto-move flipped, then 0x616870.
func _on_auto_pressed() -> void:
	_auto = not _auto
	_refresh_auto_button()

## The world button (id 6 -> 0x6231e0), and the QA hook's "world" mode: with
## auto-move on, it is turned off and the stale flag set (button 20 keeps its
## look); then the whole-world map (0x622b60(0, 0)), centred on the player
## (0x61cc30), and the floor spinner hidden.
func show_world() -> void:
	if _auto:
		_auto_art_stale = true
		_auto = false
	if _table != null:
		_show_map(_table.world())
	_centre_on_player()
	_refresh_tiles()
	_set_visible(ID_FLOOR, false)

## The guide's side button (id 15 -> 0x617ed0): 0x616ba0 with the guide's
## visibility flipped.
func toggle_guide() -> void:
	var guide := _at(ID_GUIDE)
	_set_guide_open(guide != null and not guide.visible)

## 0x616ba0: the guide shown or hidden, the side tab and button moved beside
## it, and the button's art switched.
func _set_guide_open(open_it: bool) -> void:
	_set_visible(ID_GUIDE, open_it)
	_place(_at(ID_SIDE_TAB), SIDE_TAB_OPEN if open_it else SIDE_TAB_CLOSED)
	var side := _at(ID_SIDE_BUTTON)
	_place(side, SIDE_BUTTON_OPEN if open_it else SIDE_BUTTON_CLOSED)
	if side is TextureButton:
		_set_button_art(side as TextureButton, SIDE_BUTTON_OPEN_DDJ if open_it else SIDE_BUTTON_CLOSED_DDJ)

## The size button (id 7 -> 0x61ee80 -> 0x61ca20): the window resized between
## 650x422 and 268x296, the four buttons moved, and the check box 31, the
## label 30 and the bottom frame 26 hidden in the small size and shown in the
## big one. CNIFMainFrame's resize (vslot 0x54, 0x479dd0 -> 0x479d20) re-lays
## the frame and its caption (10, 12, W-21, 12), drag area (10, 0, W-21, 34)
## and close button (W-26, 10). 0x616a20 then refreshes the caption, which in
## the small size changes only for a map id above 1000.
func toggle_size() -> void:
	_small = not _small
	var new_size := SIZE_SMALL if _small else SIZE_BIG
	custom_minimum_size = new_size
	size = new_size
	_rebuild_frame(new_size)
	var places: Dictionary = PLACES_SMALL if _small else PLACES_BIG
	for id in places:
		_place(_at(int(id)), places[id])
	for id in [ID_LEVEL_CHECK, ID_LEVEL_LABEL, ID_BOTTOM_FRAME]:
		_set_visible(id, not _small)
	_layout_map_area()
	var bar := get_node_or_null("TitleBar") as Control
	if bar != null:
		_place_title_bar(bar)
	var close := get_node_or_null("CloseButton") as Control
	if close != null:
		close.position = _close_position()
	if not _small:
		_refresh_caption()
	if _auto:
		_centre_on_player()
	_refresh_tiles()

func is_small() -> bool:
	return _small

## The root frame's eight pieces rebuilt at `new_size` (vslot 0xa4, 0x474d00),
## in place of the old ones, behind everything else.
func _rebuild_frame(new_size: Vector2) -> void:
	for c in panel_root.get_children():
		if not c.has_meta(TwoDtBuilder.META_ID) and c != _viewport and not (c in _edges):
			panel_root.remove_child(c)
			c.queue_free()
	var root_rec := _file.root()
	var def := TwoDtBuilder._def(root_rec.base if root_rec.base != "" else TwoDtBuilder.DEFAULT_MAINFRAME,
		Vector2i(new_size))
	var fresh := _builder._build_frame(def)
	var pieces := fresh.get_children()
	for i in pieces.size():
		fresh.remove_child(pieces[i])
		panel_root.add_child(pieces[i])
		panel_root.move_child(pieces[i], i)
	fresh.free()
	panel_root.size = new_size
	panel_root.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(Vector2.ZERO, new_size))

## CNIFWorldMap::vslot_023 (0x624550), ShowWindow(1): the player's map
## refreshed when it changed (0x623060, which switches only with auto-move
## on) and, with auto-move on, the view centred on the player (0x61cc30);
## the first show centres it too (+0x7b0, 0x6246c8); then 0x616a20, the
## guide's refresh 0x628ec0, and the guide closed (0x616ba0(0), 0x624864),
## which moves the side tab and button off their authored spots. Showing the
## map also hides GDR_HELPBUBBLEWND (CGInterface+0x730, 0x6249eb..0x624a0d),
## a window this client does not build.
func _on_show() -> void:
	if _auto:
		_follow_player()
	if not _shown_once:
		_shown_once = true
		_centre_on_player()
		_refresh_tiles()
	_set_guide_open(false)

## The render's auto-move step (0x6243f8..0x62452a): the player's map, then
## the view centred on the player.
func _follow_player() -> void:
	if _table != null and _player_region.x >= 0:
		var local := _table.local_for_region(_player_region.x, _player_region.y)
		_show_map(local if local != null else _table.world())
	_centre_on_player()
	_refresh_tiles()
	_place_marker()

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
	_refresh_caption()
	_refresh_world_button()
	_centre_on_player()
	_refresh_tiles()
	_place_marker()

func _is_world(info: WorldmapInfoReader.MapInfo) -> bool:
	return _table != null and info == _table.world()

static func _is_fort(info: WorldmapInfoReader.MapInfo) -> bool:
	return info != null and info.id >= FORT_FIRST and info.id <= FORT_LAST

## 0x612fd0: the world map hides the world button; a local map shows it,
## except a fortress map, which hides it.
func _refresh_world_button() -> void:
	if _current == null:
		return
	_set_visible(ID_WORLD, not _is_world(_current) and not _is_fort(_current))

## The caption (0x612fd0, SetText vslot 0xbc on the window): the world map's
## name alone; a local map's as UIIT_PAG_LOCALMAP + " - " + its name. **The
## name is ours**: the client reads it from its map record (0x937550 ->
## 0x96f4e0, +0x94), whose source column was not traced; this reads
## worldmap_mapinfo's name column through the text table. A fortress map's
## caption goes on to name the occupying guild (0x61312c..0x6131c9); this
## client does not know it, so that part is not drawn.
func _refresh_caption() -> void:
	if _current == null:
		return
	var name_text := _builder.resolve_text(_current.name_key)
	if not _is_world(_current):
		name_text = _builder.resolve_text(LOCAL_CAPTION) + CAPTION_JOIN + name_text
	set_title(name_text)

## On the whole-world view, a clickable name plate for every local map the
## table carries that falls inside it -- the cities, the fortresses, the
## arenas. Where each one goes is not fitted: `world_min`/`world_max` give
## the box that map covers, and the plate sits at the middle of it, which
## the world map's own transform turns into a pixel.
##
## **The plates and their place are ours.** The client draws its own
## location signs from `wmap_sign_location.ddj` and nothing found says
## where it puts them; what is authored is the box, and the box's middle is
## the one point in it that needs no further number.
func _build_place_labels(info: WorldmapInfoReader.MapInfo) -> void:
	var old := _canvas.get_node_or_null("PlaceLabels")
	if old != null:
		# Off the tree now, deleted at the end of the frame: a plate's own
		# click lands here (_on_plate_input -> _show_map), and a synchronous
		# free() deleted the plate while it was still emitting gui_input
		# (round 631 review, measured with a real click).
		_canvas.remove_child(old)
		old.queue_free()
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

## A plate pressed: a left press anywhere in the map area turns auto-move
## off (0x6235ad, below), and the plate's map is shown on the release.
##
## Round 631 review: both halves of the click stay the plate's. World3D walks
## on a left RELEASE that reaches _unhandled_input, and Godot sends a release
## only to the control that took the press; switching maps on the press
## dropped the plate, so the release went to the world and walked the player
## (measured with a real click on the Jangan plate). Switching on the release
## is this client's choice (OURS; the plates are ours).
func _on_plate_input(event: InputEvent, info: WorldmapInfoReader.MapInfo) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		if (event as InputEventMouseButton).pressed:
			_mouse_turns_auto_off()
		else:
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
## the position falls where it falls. With auto-move on, the map follows
## (vslot_013's step, _follow_player).
func update_player(region_x: int, region_y: int, local_pos: Vector3) -> void:
	_player_world = Vector2(
		(region_y - WorldmapInfoReader.REGION_Y_ORIGIN) * WorldmapInfoReader.REGION_SPAN
			+ local_pos.x / 10.0,
		(region_x - WorldmapInfoReader.REGION_X_ORIGIN) * WorldmapInfoReader.REGION_SPAN
			+ local_pos.z / 10.0)
	_player_region = Vector2i(region_x, region_y)
	if _auto:
		_follow_player()
	else:
		_place_marker()

func _place_marker() -> void:
	if _marker == null or _current == null:
		return
	if _player_region.x < 0 or not _current.covers_region(_player_region.x, _player_region.y):
		_marker.visible = false
		return
	_marker.visible = true
	_marker.position = _current.pixel_for_world(_player_world) - _marker.size / 2.0

## Puts the player under the middle of the map area (0x61cc30: the scroll
## set from the player's pixel less half the area, through 0x61c5a0),
## clamped to the map. A player who is not on this map leaves the map's
## middle there instead (ours).
func _centre_on_player() -> void:
	if _current == null or _viewport == null:
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
## corner; a larger one may not be dragged past its own edges. Ours.
static func clamp_scroll(at: Vector2, canvas: Vector2, viewport: Vector2) -> Vector2:
	var slack := canvas - viewport
	var out := at
	out.x = (-slack.x / 2.0) if slack.x <= 0.0 else clampf(at.x, -slack.x, 0.0)
	out.y = (-slack.y / 2.0) if slack.y <= 0.0 else clampf(at.y, -slack.y, 0.0)
	return out

## The window's mouse handler (vslot_017, 0x623220). WM_LBUTTONDOWN (0x201,
## jump table 0x624340) in the map area (0x60f530, the inclusive test
## 0x46cb40 against +0x97d8) starts a drag (+0x79c..+0x7a8, capture
## 0x46e030); anywhere on the window it then turns auto-move off with the
## stale flag set (0x6235ad..0x6235bd). WM_MOUSEMOVE (0x200) scrolls by the
## motion (0x61c5a0 at 0x623c45).
func _on_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		_panning = mb.pressed
		_pan_from = mb.position
		if mb.pressed:
			_mouse_turns_auto_off()
			move_to_front()
		_viewport.accept_event()
	elif event is InputEventMouseMotion and _panning:
		var mm := event as InputEventMouseMotion
		_canvas.position = _clamp_scroll(_canvas.position + mm.position - _pan_from)
		_pan_from = mm.position
		_refresh_tiles()
		_viewport.accept_event()

## A left press on the window itself -- not on a child, and so not on the
## drag area, which is CNIFMainFrame's own child (0x479a50) -- turns
## auto-move off too.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and (event as InputEventMouseButton).pressed \
			and not in_drag_strip((event as InputEventMouseButton).position):
		_mouse_turns_auto_off()
	super(event)

## 0x6235ad..0x6235bd: with auto-move on, it goes off and the stale flag is
## set; button 20 is not redrawn.
func _mouse_turns_auto_off() -> void:
	if _auto:
		_auto_art_stale = true
		_auto = false

## M and the minimap's map button (0x79abe0): the window's visibility
## toggled (0x46d740), then 0x79ab80 -- which, when the interface itself is
## visible (its first 0xb8f530 is on `this`, the interface), calls the
## window's vslot 0x50 (bringing it to the front is **inferred**), 0x79a620
## and snd_window_open if the window is now shown, or snd_window_close if
## not (UiSounds.window_toggled, round 615) -- and then the window centred on
## the screen (0x798c50), on a hide as well. The window's own close button
## only hides it (CNIFWorldMap's vslot_043 is CNIFWnd's 0x46d7c0): silent.
func toggle() -> void:
	if visible:
		hide()
	else:
		_on_show()
		show()
		move_to_front()
	var parent := get_parent() as CanvasItem
	UiSounds.window_toggled(visible, parent == null or parent.is_visible_in_tree(), "world map (0x79abe0)")
	place_centred()

## Opens the window (the QA hook and the GUI audit): ShowWindow(1) and the
## centring, as M does from hidden.
func open() -> void:
	_on_show()
	show()
	move_to_front()
	place_centred()

## 0x798c50: x = (screen width >> 1) - (width >> 1), y likewise, integer
## halves (the `cdq / sub / sar 1` pairs), through vslot 0x9c. The screen is
## the viewport in the UI's own units. **Ours:** the result is kept inside
## the viewport's top-left corner, so the caption and close button stay
## reachable when the window is larger than the view.
func place_centred() -> void:
	var view := get_viewport_rect().size
	var x := int(view.x) / 2 - int(size.x) / 2
	var y := int(view.y) / 2 - int(size.y) / 2
	position = Vector2(clampi(x, 0, maxi(0, int(view.x) - int(size.x))),
		clampi(y, 0, maxi(0, int(view.y) - int(size.y))))

func centre() -> void:
	place_centred()

## CNIFMainFrame's chrome (0x479a50): caption (10, 12, W-21, 12), drag area
## (10, 0, W-21, 34), close button (W-26, 10, 16, 16) on com_windowclose.ddj;
## the resize re-lays them the same way (0x479d20).
func _place_title_bar(bar: Control) -> void:
	var rect := Rect2(Vector2(MAINFRAME_CAPTION_X, MAINFRAME_CAPTION_Y),
		Vector2(size.x - MAINFRAME_STRIP_WIDTH_LESS, MAINFRAME_CAPTION_HEIGHT))
	bar.set_meta(UiBuilder.AUTHORED_RECT_META, rect)
	bar.position = rect.position
	bar.size = rect.size

func _close_position() -> Vector2:
	return Vector2(size.x - MAINFRAME_CLOSE_INSET, MAINFRAME_CLOSE_Y)

func in_drag_strip(local: Vector2) -> bool:
	return Rect2(MAINFRAME_CAPTION_X, 0.0, size.x - MAINFRAME_STRIP_WIDTH_LESS,
		MAINFRAME_DRAG_HEIGHT).has_point(local)

## A direct child of the window's root by id (GetChild, 0x46e060).
func _at(id: int) -> Control:
	return TwoDtBuilder.child(panel_root, id) if panel_root != null else null

## A control of the window by its GetChild path from the root.
func control(path: Array) -> Control:
	return TwoDtBuilder.find_path(panel_root, path) if panel_root != null else null

func _set_visible(id: int, on: bool) -> void:
	var c := _at(id)
	if c != null:
		c.visible = on

## Moves a control to `at` in the window, keeping the settling pass on the
## same spot (vslot 0x98 moves a window and its children together).
static func _place(node: Control, at: Vector2) -> void:
	if node == null:
		return
	node.position = at
	node.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(at, node.size))

## The map currently drawn (tests, tools).
func current_map() -> WorldmapInfoReader.MapInfo:
	return _current
