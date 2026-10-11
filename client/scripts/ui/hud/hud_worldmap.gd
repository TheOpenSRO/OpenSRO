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
##
## **Dungeons (round 775, every item READ unless marked).** The window has
## three modes (+0x97d0): 0 the world map, 1 a local map, 2 a dungeon floor
## (a `Dungeonmap` row, ids from 2001, +0x99a0).
## - The world map carries signs from `worldmap_localinfo.txt`
##   (WorldmapLocalInfoReader; 0x6210b0 lists the signs of the map shown),
##   among them the two dungeon icons `xy_dungeon.ddj`. A press and a release
##   on the same sign with a link (vslot_017 0x623220, WM_LBUTTONDOWN records
##   it at +0x9800, WM_LBUTTONUP compares) opens that map: below 2001 a local
##   map (0x622b60), from 2001 a dungeon floor (0x6217e0); a fortress
##   (1001..1999) opens nothing. Then the view is centred (0x61cc30).
## - A floor (0x6217e0): its tiles `<path><left + a>x<top - b>.ddj`, a side
##   of `scale * 256` each (0x6196d0); its box and scale from its region
##   bounds; the floor spinner 4 set to the row's floor and shown when the
##   dungeon has more than one; the caption 0x6145e0; the floor's own signs.
## - The spinner (0x60f210, 0x60f080 up = button 22, 0x60efc0 down = 24,
##   label 27 by 0x60edd0): a press turns auto-move off with the stale flag
##   (as a press on the map does), steps the floor and greys the button at
##   its end; the render's tail (0x621ca0) then shows the row of the same
##   dungeon name with that floor (0x621c60 -> 0x6143b0). **0x6217e0 steps
##   the spinner through the same two functions, so showing any floor turns
##   auto-move off** -- the map then stays on that floor until button 20 is
##   pressed twice (0x616870's stale flag takes the first press back).
## - In a dungeon (bit 15 of the player's region), auto-move picks the floor
##   (0x623060 -> 0x614280): the row whose zone code is the region id and
##   whose floor label (`1F`, `B2`) is the text of the player's floor name.
##   The arrow (0x60f660) is drawn on a floor only when that floor is the
##   player's (0x614890 -> 0x612920); on a field map it is drawn at the
##   dungeon's field point from `worldmap_instanceinfo.txt` (0x60fa90,
##   WorldmapInstanceInfoReader).

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
## The spinner's children (0x60f210: GetChild 0x1b, 0x18, 0x16; the message
## map at 0xeb5468 sends 0x18 to 0x60efc0 and 0x16 to 0x60f080, READ).
const ID_FLOOR_UP := 22
const ID_FLOOR_DOWN := 24
const ID_FLOOR_LABEL := 27
## 0x60f210 gives the spinner this picture (0xe19b90, vslot 0x34 of its own
## texture object at +0x84). That it fills the spinner's rect is INFERRED.
const FLOOR_BACK_DDJ := "interface\\store\\str_slot_02.ddj"

## The three modes (+0x97d0).
const MODE_WORLD := 0
const MODE_LOCAL := 1
const MODE_DUNGEON := 2

## The caption's join before a room name (0x6145e0 -> " - " at 0xd99114).
const ROOM_JOIN := " - "
## A type-1 sign's decorations by its link column (0x6210b0: 1 -> "<-" at
## 0xd99c90 before the text, 2 -> "->" at 0xd99c88 after it; which side each
## goes is INFERRED from the two concatenations' argument order).
const SIGN_PREFIX_1 := "<-"
const SIGN_SUFFIX_2 := "->"

## The text tables a dungeon caption and a sign's name are looked up in:
## the client's TextStringManager holds them all in one map (0x8cac30), and
## a miss gives an empty string (0x8c9b20 -> 0xec3b70; READ).
const TEXT_ZONE_PATH := "server_dep\\silkroad\\textdata\\textzonename.txt"
const TEXT_OBJECT_PATH := "server_dep\\silkroad\\textdata\\textdata_object.txt"

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
## The signs and the instance points to use instead of the archive's (tests;
## set before build_worldmap). Left null with no archive, the world map has
## no signs and keeps the round-599 name plates (OURS).
var local_table: WorldmapLocalInfoReader.Table
var instance_table: WorldmapInstanceInfoReader.Table
## Text tables to look keys up in instead of the archive's textzonename and
## textdata_object (tests). A key the builder's own table has is found too.
var text_tables: Array = []

var _twodt: TwoDtBuilder
var _file: TwoDtReader.TwoDtFile
var _table: WorldmapInfoReader.ParsedTable
## The map currently drawn -- the world map, or a city's own.
var _current: WorldmapInfoReader.MapInfo
var _viewport: Control
var _canvas: Control
var _marker: TextureRect
## The party's marks (round 717, PartyMapMarks): pooled 16x16 dots, and the
## hovered member's name over its dot.
var _party_layer: Control
var _party_tex: Texture2D
var _party_dots: Array[TextureRect] = []
var _party_label: Label
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
## +0x9990: the teleport-selection mode (0x622dd0, entered from the reverse
## return scroll's box; round 778, enter_select_mode). 0x616870 checks the
## stale flag only when it is 0.
var _teleport_select := false
## +0x97cc: 0 big, 1 small.
var _small := false
## +0x7b0: the first ShowWindow(1) centres the map (0x6246c8).
var _shown_once := false

## +0x97d0: which kind of map is shown.
var _mode := MODE_WORLD
## +0x99a0: the floor shown in MODE_DUNGEON.
var _dungeon_map: WorldmapInfoReader.DungeonMapInfo
## The spinner (0x60ee90..0x60ef00): its value +0x35c (0-based floor), its
## top +0x354 (floors - 1), its bottom +0x358 (0), its letter +0x360 and its
## spelling +0x364 (2 "%d%c", 1 "%c%d").
var _floor_index := 0
var _floor_max := 0
var _floor_letter := ""
var _floor_mode := 0
## +0x9800: the link of the sign a left press landed on (0 none).
var _pressed_link := 0
## The signs of the map shown, as built: [Sign, Control] pairs, in file order.
var _signs: Array = []
var _sign_layer: Control
var _signs_loaded := false
var _instances_loaded := false
## The player in a dungeon: its region id (bit 15 set), its `.dof`-space
## position, and its block's floor and room name keys. -1 in the field.
var _player_rid := -1
var _player_dungeon_pos := Vector3.ZERO
var _player_floor_key := ""
var _player_room_key := ""
var _zone_texts: UiTextTable
var _object_texts: UiTextTable
var _zone_texts_loaded := false
var _object_texts_loaded := false

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

	_load_signs()
	_load_instances()
	_twodt = TwoDtBuilder.new(_builder)
	panel_root = _twodt.build(_file, WORLDMAP_2DT)
	var window_size := Vector2(_file.root().rect.size)
	custom_minimum_size = window_size
	size = window_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel_root)
	_build_map_area()
	_build_floor_spinner()

	_apply_create_state()
	_add_title_bar("")
	var bar := get_node_or_null("TitleBar") as Label
	if bar != null:
		# The caption's text-object slot 6 is 0 (0x479c0b): top.
		bar.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_wire()
	_show_map(_table.world())
	_settle()
	visibility_changed.connect(_on_visibility_changed)
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

## `worldmap_localinfo.txt` (WorldmapLocalInfoReader), unless a test set
## `local_table`. Missing, the world map shows no signs.
func _load_signs() -> void:
	if _signs_loaded:
		return
	_signs_loaded = true
	if local_table != null:
		return
	var archive := _builder.media_archive()
	if archive == null:
		return
	var entry := ObjectLoader.find_file(archive, WorldmapLocalInfoReader.TABLE_PATH)
	if entry != null:
		local_table = WorldmapLocalInfoReader.parse(archive.read_file(entry))

## `worldmap_instanceinfo.txt` (WorldmapInstanceInfoReader), unless a test
## set `instance_table`. The client loads it only when vslot 0xb8 of
## +0x4c4 returns 0 (Client_LoadAllRefData 0x844cd0; what that asks is not
## traced); missing, the two constants of 0x610c5e stand in (READ).
func _load_instances() -> void:
	if _instances_loaded:
		return
	_instances_loaded = true
	if instance_table != null:
		return
	var archive := _builder.media_archive()
	if archive == null:
		return
	var entry := ObjectLoader.find_file(archive, WorldmapInstanceInfoReader.TABLE_PATH)
	if entry != null:
		instance_table = WorldmapInstanceInfoReader.parse(archive.read_file(entry))

## The floor spinner (record 4) as 0x60f210 sets it up: its picture behind
## its children, the label 27, and the two buttons wired to 0x60f080 (22)
## and 0x60efc0 (24).
func _build_floor_spinner() -> void:
	var spinner := _at(ID_FLOOR)
	if spinner == null:
		return
	var back_tex := _builder.load_texture(FLOOR_BACK_DDJ)
	if back_tex != null:
		var back := TextureRect.new()
		back.name = "FloorBack"
		back.texture = back_tex
		back.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		back.stretch_mode = TextureRect.STRETCH_SCALE
		back.size = spinner.size
		back.mouse_filter = Control.MOUSE_FILTER_IGNORE
		spinner.add_child(back)
		spinner.move_child(back, 0)
	var up := TwoDtBuilder.child(spinner, ID_FLOOR_UP) as BaseButton
	if up != null:
		up.pressed.connect(floor_up)
	var down := TwoDtBuilder.child(spinner, ID_FLOOR_DOWN) as BaseButton
	if down != null:
		down.pressed.connect(floor_down)
	_refresh_floor_label()

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
	# The signs (round 775), under the party's marks and the marker: the
	# render (0x61eec0) draws the map's signs before them.
	_sign_layer = Control.new()
	_sign_layer.name = "Signs"
	_sign_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_sign_layer)
	# The party's marks (round 717) go under the player's marker, as
	# FUN_0061eec0 draws them first.
	make_party_layer(_canvas, _builder.load_texture(PartyMapMarks.WORLD_DOT_DDJ))
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

## 0x616870 (asm 0x616870..0x616a16). The spinner is hidden first; outside
## the teleport-selection mode (+0x9990 == 0), a stale flag with auto-move on
## turns auto-move off and clears the flag (the press that set it is taken
## back), and with auto-move already off the flag is left set (0x61689b
## jumps past the clear); then button 20 gets the look and hover text of the
## state. Auto-move on a dungeon floor shows the spinner when the dungeon has
## more than one floor. Manual: a local map shows the world button; a
## dungeon floor in the big size shows it and the spinner (more than one
## floor), in the small size hides both. A fortress map hides the world
## button.
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
	if _auto:
		if _mode == MODE_DUNGEON and _dungeon_map != null:
			_set_visible(ID_FLOOR, _dungeon_map.total_layers > 1)
	elif _mode == MODE_LOCAL:
		_set_visible(ID_WORLD, true)
	elif _mode == MODE_DUNGEON:
		_set_visible(ID_WORLD, not _small)
		_set_visible(ID_FLOOR, not _small and _dungeon_map != null and _dungeon_map.total_layers > 1)
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
## (0x61cc30), and the floor spinner hidden. From a dungeon floor this is the
## way back to the world map.
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
	# 0x616a20: the big size refreshes any caption, the small one a dungeon
	# floor's (id above 2000 -> 0x6145e0).
	if not _small or _mode == MODE_DUNGEON:
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
## the view centred on the player. In a dungeon the player's map is the
## floor 0x614280 picks (the region id and the floor's text), or the world
## map when no row is that floor (0x623060).
func _follow_player() -> void:
	if _table != null and in_dungeon():
		var id := _table.dungeon_for(_player_rid, _text(_player_floor_key))
		if id >= WorldmapInfoReader.FIRST_DUNGEON_ID:
			if _mode != MODE_DUNGEON or _dungeon_map == null or _dungeon_map.id != id:
				show_dungeon(id)
		else:
			_show_map(_table.world())
	elif _table != null and _player_region.x >= 0:
		var local := _table.local_for_region(_player_region.x, _player_region.y)
		_show_map(local if local != null else _table.world())
	_centre_on_player()
	_refresh_tiles()
	_place_marker()

## Throws the tiles of the map shown away and sizes the canvas for the next.
func _clear_map(draw_size: Vector2i) -> void:
	for node in _tiles.values():
		node.queue_free()
	_tiles.clear()
	_canvas.size = Vector2(draw_size)
	_canvas.position = Vector2.ZERO

## Switches the interior to a map: the world grid, or a single image
## (0x622b60: the mode, the map, the caption, the box and scale, the signs,
## and the spinner hidden at its end).
func _show_map(info: WorldmapInfoReader.MapInfo) -> void:
	if info == null or info == _current:
		return
	_current = info
	_mode = MODE_WORLD if _is_world(info) else MODE_LOCAL
	_dungeon_map = null
	_clear_map(info.draw_size)

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

	_build_signs(info.id)
	_build_place_labels(info)
	_refresh_caption()
	_refresh_world_button()
	_set_visible(ID_FLOOR, false)
	_centre_on_player()
	_refresh_tiles()
	_place_marker()
	_qa_note("map %d" % info.id)

## NIFWorldMap 0x6217e0: dungeon floor `id` (a Dungeonmap row) shown in mode
## 2 -- the caption (0x6145e0), the tiles, the box and scale, the spinner
## set to the row's floor through its own step functions (which turn
## auto-move off, see the header), the tile quads (0x6196d0), the floor's
## signs (0x6210b0) and the spinner shown when the dungeon has more than one
## floor. Returns false for an id with no row (the client asserts "Illigal
## Dungeon Map Index" there and shows nothing).
func show_dungeon(id: int) -> bool:
	var d := _table.dungeon_by_id(id) if _table != null else null
	if d == null:
		return false
	_mode = MODE_DUNGEON
	_dungeon_map = d
	_current = null
	_clear_map(d.draw_size)
	_refresh_caption()
	# 0x60ee90 (top = floors - 1), 0x60eef0 (the letter), 0x60ef00 (the
	# spelling), 0x60eed0(0), then one step up, one down, and up until the
	# row's own floor.
	_floor_max = d.total_layers - 1
	_floor_letter = d.layer.substr(0, 1)
	_floor_mode = d.spinner_mode()
	_floor_index = 0
	_floor_step(1)
	_floor_step(-1)
	var n := _floor_index + 1
	while n < d.layers:
		_floor_step(1)
		n += 1
	_build_signs(id)
	_build_place_labels(null)
	_set_visible(ID_FLOOR, d.total_layers > 1)
	_centre_on_player()
	_refresh_tiles()
	_place_marker()
	_qa_note("dungeon %d" % id)
	return true

func _is_world(info: WorldmapInfoReader.MapInfo) -> bool:
	return _table != null and info == _table.world()

static func _is_fort(info: WorldmapInfoReader.MapInfo) -> bool:
	return info != null and info.id >= FORT_FIRST and info.id <= FORT_LAST

## 0x612fd0: the world map hides the world button; a local map shows it,
## except a fortress map, which hides it. A dungeon floor shows it
## (0x6145e0's ShowWindow(1) on +0x9818, 0x614840).
func _refresh_world_button() -> void:
	if _mode == MODE_DUNGEON:
		_set_visible(ID_WORLD, true)
		return
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
	if _mode == MODE_DUNGEON:
		_refresh_dungeon_caption()
		return
	if _current == null:
		return
	var name_text := _builder.resolve_text(_current.name_key)
	if not _is_world(_current):
		name_text = _builder.resolve_text(LOCAL_CAPTION) + CAPTION_JOIN + name_text
	set_title(name_text)

## CNIFWorldMap 0x6145e0 (asm 0x6145e0..0x614886), a dungeon floor's
## caption: the zone code as "%d" looked up in the text tables (0x8c9c30),
## that text written with "%s" and looked up again, and the caption the
## second lookup followed by the first -- a miss gives "", so it reads as the
## zone's name. Then, with the player in a dungeon, and either auto-move on
## or this floor the player's (0x612920), " - " and the text of the player's
## room name (0x9d7830). The world button is shown.
##
## MEASURED: the archive's textzonename names zone 32769 (the Donwhang cave,
## floors 2001..2004) "Job Temple"; the client shows what the table says.
func _refresh_dungeon_caption() -> void:
	if _dungeon_map == null:
		return
	var first := _text(str(_dungeon_map.zone_code))
	var caption := _text(first) + first
	if _dungeon_map.id > 2000 and in_dungeon():
		if _auto or _dungeon_map.floor_label() == _text(_player_floor_key):
			if _player_room_key != "":
				caption += ROOM_JOIN + _text(_player_room_key)
	set_title(caption)
	_refresh_world_button()

## The signs of map `id` (NIFWorldMap 0x6210b0, READ; WorldmapLocalInfoReader
## has the columns): a type-2 sign is its picture at its quad, a type-1 sign
## its text centred on its anchor. Each is kept with its sign for the click
## test, in the table's order (the list at +0x982c, which the press and
## release walk).
##
## **Draw order (READ, round 776).** The render (vslot_013 0x624380 ->
## 0x61c360) walks the list twice: first every picture sign with a texture
## (`*sign == 2 && +0x9c`, a DrawPrimitiveUP of the quad at +0xc4), then
## every text sign with text (`*sign == 1 && +0x7c`, 0x8b48b0 at
## +0xac / +0xb0). So every text is over every picture, whatever the file
## order -- a town's name (Jangan's `SN_ZONE_22001`, listed before its
## `city_jangan.ddj` icon) lands on the icon's name plate. The children here
## are added in that order: the pictures in file order, then the texts.
func _build_signs(id: int) -> void:
	_signs.clear()
	if _sign_layer == null:
		return
	for c in _sign_layer.get_children():
		_sign_layer.remove_child(c)
		c.queue_free()
	if local_table == null or _table == null or _table.world() == null:
		return
	var world := _table.world()
	for sign: WorldmapLocalInfoReader.Sign in local_table.for_map(id):
		var node: Control = null
		var at := Vector2(sign.anchor(world.region_left, world.region_top))
		if sign.type == WorldmapLocalInfoReader.TYPE_PICTURE:
			var tex := _builder.load_texture(sign.text.replace("/", "\\"))
			if tex == null:
				continue
			var pic := TextureRect.new()
			pic.texture = tex
			pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			pic.stretch_mode = TextureRect.STRETCH_SCALE
			pic.position = at
			pic.size = Vector2(sign.size)
			node = pic
		elif sign.type == WorldmapLocalInfoReader.TYPE_TEXT:
			node = _sign_label(sign, at)
		if node == null:
			continue
		node.name = "Sign%d" % sign.id
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_signs.append([sign, node])
	for pass_type in [WorldmapLocalInfoReader.TYPE_PICTURE, WorldmapLocalInfoReader.TYPE_TEXT]:
		for pair in _signs:
			if (pair[0] as WorldmapLocalInfoReader.Sign).type == pass_type:
				_sign_layer.add_child(pair[1])
	_canvas.move_child(_sign_layer, -1)
	if _party_layer != null:
		_canvas.move_child(_party_layer, -1)
	if _marker != null:
		_canvas.move_child(_marker, -1)

## A type-1 sign (0x6210b0, READ, asm 0x6211d4..0x621444): the text object
## at sign + 0x34 gets
## - the font of index `h` (column 14, +0x94 -> 0xba5460(index) ->
##   0x8b2b50; INFERRED the same index table as a .2dt record's FontIndex,
##   UiBuilder.FONT_SIZES);
## - the colour (columns 15..17, 0x8b2b70; 0x8b48b0 draws it at alpha 0xff);
## - its text flags, in this order: column 18 sets or clears flag 1, column
##   19 flag 2, column 20 flag 1 again (0x8b44b0 / 0x8b4560 with (5, 1),
##   (5, 2), (5, 1)) -- so **column 20 decides the drop shadow and column 18
##   has no effect**; flag 2 is the face's weight-600 variant (0x8b39e0),
##   flag 1 the one-pixel black shadow (0x8b48b0 -> 0x8b2290);
## - the text: the key's text (0x8c9bb0), "<-" before it for link 1, "->"
##   after it for link 2.
## The text is measured after the flags (0x8b3b60 -> 0x8b39e0 -> 0x8b3910:
## the sum of the glyphs' advances, in the bold face when flag 2 is set) and
## placed at `origin + anchor.x - width / 2` (an int division, `cdq; sub;
## sar 1`), `origin + anchor.y` -- the glyph cells' top (0x8b2290 draws each
## cell from that y down). MEASURED on the original's picture at Jangan
## (round 776): the ink of all five labels measured is centred on the anchor
## to half a pixel and its capitals start 3 px below it.
func _sign_label(sign: WorldmapLocalInfoReader.Sign, at: Vector2) -> Control:
	var text := _text(sign.text, true)
	if text == "":
		return null
	if sign.link == 1:
		text = SIGN_PREFIX_1 + text
	elif sign.link == 2:
		text = text + SIGN_SUFFIX_2
	var index := clampi(sign.size.y, 0, UiBuilder.FONT_SIZES.size() - 1)
	var font: Font = _builder.font_at(index) if _builder != null else null
	if font == null:
		# No archive face (tests): Godot's own, so the text still measures.
		font = ThemeDB.fallback_font
	var label := SignText.new()
	label.setup(text, font, UiBuilder.FONT_SIZES[index], sign.color, sign.is_bold(), sign.has_shadow())
	label.position = Vector2(at.x - floorf(floorf(label.text_width) / 2.0), at.y)
	return label

## A world-map text sign as the client's text object draws it (0x8b48b0,
## READ): glyph by glyph from the left, each glyph's cell top at the node's
## top, the pen moving by the glyph's advance (no kerning: 0x8b3910 / 0x8b48b0
## sum the glyph records' advances). With flag 1 each glyph is drawn first one
## pixel right and down in black at the text's alpha, then in its colour
## (0x8b2290: `x + 1, y + 1`, colour `& 0xff000000`) -- glyph by glyph, so a
## glyph's shadow lands over the glyph before it. With flag 2 the glyphs are
## the face's weight-600 variant (0x8b39e0 -> glyph mode 2, created in
## 0xbaa110 with lfWeight 600): the system's bold file, or, without one,
## GDI's simulation -- each glyph drawn at x and x + 1, its advance one wider
## (HudNotice.draw_bold, round 703; OURS as code). The glyphs are sampled
## unfiltered (UiBuilder.crisp_text), as every other UI text.
class SignText extends Control:
	var text := ""
	var font: Font
	## The weight-600 file, or null for the simulation.
	var bold_face: Font
	var px := 12
	var color := Color.WHITE
	var bold := false
	var shadow := false
	## 0x8b3910's width: the advances' sum (the shadow is not counted).
	var text_width := 0.0

	func setup(s: String, f: Font, size_px: int, c: Color, is_bold: bool, has_shadow: bool) -> void:
		text = s
		font = f
		px = size_px
		color = Color(c, 1.0)
		bold = is_bold
		shadow = has_shadow
		bold_face = HudNotice.bold_file(f) if bold else null
		text_width = 0.0
		for ch in text:
			text_width += advance(ch)
		var h := font.get_height(px) if font != null else float(px)
		var pad := 1.0 if shadow else 0.0
		size = Vector2(text_width + pad, h + pad)
		UiBuilder.crisp_text(self)
		queue_redraw()

	## The pen's step after `ch`.
	func advance(ch: String) -> float:
		if font == null:
			return 0.0
		var code := ch.unicode_at(0)
		if bold and bold_face != null:
			return bold_face.get_char_size(code, px).x
		return font.get_char_size(code, px).x + (1.0 if bold else 0.0)

	func _draw() -> void:
		if font == null or text == "":
			return
		var face: Font = bold_face if bold and bold_face != null else font
		var y := face.get_ascent(px)
		var x := 0.0
		var black := Color(0, 0, 0, color.a)
		for ch in text:
			if shadow:
				_glyph(ch, Vector2(x + 1.0, y + 1.0), black)
			_glyph(ch, Vector2(x, y), color)
			x += advance(ch)

	func _glyph(ch: String, at: Vector2, c: Color) -> void:
		if bold and bold_face != null:
			draw_char(bold_face, at, ch, px, c)
		elif bold:
			draw_char(font, at, ch, px, c)
			draw_char(font, at + Vector2(1, 0), ch, px, c)
		else:
			draw_char(font, at, ch, px, c)

## The first type-2 sign whose quad holds `at` (canvas pixels), or null --
## the press and release tests of 0x623220 stop at the first hit.
func sign_at(at: Vector2) -> WorldmapLocalInfoReader.Sign:
	if _table == null or _table.world() == null:
		return null
	var world := _table.world()
	for pair in _signs:
		var sign: WorldmapLocalInfoReader.Sign = pair[0]
		if sign.type == WorldmapLocalInfoReader.TYPE_PICTURE and sign.hit(world.region_left, world.region_top, at):
			return sign
	return null

## The signs built for the map shown (tests, the QA hook).
func signs() -> Array:
	var out: Array = []
	for pair in _signs:
		out.append(pair[0])
	return out

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
	if local_table != null:
		# Round 775: the world map has its authored signs -- the city,
		# fortress and dungeon icons of worldmap_localinfo.txt, clickable as
		# the client's are -- so the plates, which stood in for them, are not
		# drawn. They stay for an archive without the table.
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
	# The party's marks and the player's own marker belong over the labels,
	# not under them; the marker over the party's marks.
	if _party_layer != null:
		_canvas.move_child(_party_layer, -1)
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
	if _mode == MODE_DUNGEON:
		_refresh_dungeon_tiles()
		return
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

## A dungeon floor's tiles that overlap what can be seen: column `a`, row
## `b` is `<path><left + a>x<top - b>.ddj` at `(a, b) * side`, `side` the
## scale times 256 (0x6217e0's names, 0x6196d0's quads; READ), each drawn
## whole (the quads' UVs are 0..1, 0x6217e0).
func _refresh_dungeon_tiles() -> void:
	if _dungeon_map == null:
		return
	var side := _dungeon_map.tile_side()
	if side <= 0.0:
		return
	var tile := Vector2(side, side)
	var span := visible_tile_range(_canvas.position, _viewport.size, tile,
		_dungeon_map.texture_count.x, _dungeon_map.texture_count.y)
	for a in range(span.position.x, span.end.x):
		for b in range(span.position.y, span.end.y):
			var path := _dungeon_map.tile_path(a, b)
			if _tiles.has(path):
				continue
			var tex := _builder.load_texture(path)
			if tex == null:
				_tiles[path] = _placeholder(Vector2(a, b) * tile, tile)
				continue
			var tr := TextureRect.new()
			tr.name = "Tile_%d_%d" % [a, b]
			tr.texture = tex
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_SCALE
			tr.position = Vector2(a, b) * tile
			tr.size = tile
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_canvas.add_child(tr)
			_canvas.move_child(tr, 0)
			_tiles[path] = tr

## The tile paths built so far (tests).
func tile_paths() -> PackedStringArray:
	var out := PackedStringArray()
	for k in _tiles:
		out.append(String(k))
	return out

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
##
## `local_facing` is the way the player faces, a region-local ground vector
## (x east, z north). The marker is the minimap's arrow and is turned the
## same way: CNIFWorldMap keeps the heading less pi / 2 at +0x97c8 (0x60f6a5,
## 0x610a05) and turns the marker's 16x16 quad (+-8, 0xd99a70 / 0xd89240) by
## -(+0x97c8) through 0x8b5c50 (0x6200de..0x620236) -- HudMinimap.
## arrow_rotation has the reading. It was never turned before (round 630).
func update_player(region_x: int, region_y: int, local_pos: Vector3,
		local_facing: Vector2 = Vector2.ZERO) -> void:
	_player_rid = -1
	_player_floor_key = ""
	_player_room_key = ""
	if _marker != null and not local_facing.is_zero_approx():
		_marker.rotation = HudMinimap.arrow_rotation(local_facing)
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

## The player in a dungeon (round 775; World3D's dungeon minimap step calls
## this instead of update_player): `region_id` the dungeon's region id (bit
## 15 set, 0x8001 the Donwhang cave), `dungeon_pos` the player's position in
## the `.dof`'s own space (DungeonWorld.to_dungeon -- the client's +0x80 /
## +0x84 / +0x88), `facing` as update_player's, and the player's block's
## floor and room name keys (DofReader: `DH_A01_FLOOR01`,
## `DH_A01_F01_ROOM_01`; the client's 0x9d7880 / 0x9d7830 ask the region's
## current floor and room names, INFERRED the same lists). With auto-move on
## the map follows (0x623060): the floor 0x614280 picks.
func update_player_dungeon(region_id: int, dungeon_pos: Vector3, facing: Vector2,
		floor_key: String, room_key: String) -> void:
	if _marker != null and not facing.is_zero_approx():
		_marker.rotation = HudMinimap.arrow_rotation(facing)
	var changed := region_id != _player_rid or floor_key != _player_floor_key or room_key != _player_room_key
	_player_rid = region_id
	_player_dungeon_pos = dungeon_pos
	_player_floor_key = floor_key
	_player_room_key = room_key
	# The field's own region is not where the player is.
	_player_region = Vector2i(-1, -1)
	# The party's marks are not placed in a dungeon (OPEN, see
	# docs/protocol/WORLDMAP_FORMAT.md's dungeon section).
	if _party_layer != null and not _party_dots.is_empty():
		place_party_dots(PackedVector2Array(), PackedStringArray(), false, Vector2(-1e9, -1e9))
	# Only a shown window follows (OURS for the field's update_player, which
	# follows hidden too): the client's follow is its render's (0x6243f8)
	# and ShowWindow's (0x623060), and a floor shown turns auto-move off
	# (0x6217e0), so following while hidden would leave the map on the
	# floor the player was on when the window was last updated.
	if _auto and is_visible_in_tree():
		_follow_player()
	else:
		_place_marker()
	if changed and _mode == MODE_DUNGEON:
		# The caption names the player's room (0x6145e0).
		_refresh_dungeon_caption()

## Whether the player is in a dungeon (bit 15 of its region id).
func in_dungeon() -> bool:
	return _player_rid >= 0 and (_player_rid & 0x8000) != 0

## The party's layer, its dots' art and the hover label, under `parent`
## (the map canvas; a test passes its own).
func make_party_layer(parent: Control, tex: Texture2D) -> void:
	_party_layer = Control.new()
	_party_layer.name = "PartyMarks"
	_party_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_party_layer)
	_party_tex = tex
	_party_label = Label.new()
	_party_label.name = "PartyHover"
	_party_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_party_label.visible = false
	_party_layer.add_child(_party_label)

## Marks each party member (round 717): `members_local` holds each drawn
## member's region-local ground position (x east, y north) in the player's
## region (`region_x`, `region_y`), `names` their names in the same order,
## `job_party` whether the party is a job party (its names show with a `*`).
## A mark off this map lands off the canvas and is clipped by the map area
## (OURS: the original's own clipping was not traced).
func update_party(region_x: int, region_y: int, members_local: PackedVector2Array,
		names: PackedStringArray, job_party := false) -> void:
	if _party_layer == null:
		return
	_party_pixels.resize(members_local.size())
	for i in members_local.size():
		_party_pixels[i] = _current.pixel_for_world(party_world(region_x, region_y, members_local[i])) \
			if _current != null else Vector2(-1e9, -1e9)
	var mouse := _canvas.get_local_mouse_position() if _canvas != null and _canvas.is_inside_tree() \
		else Vector2(-1e9, -1e9)
	place_party_dots(_party_pixels, names, job_party, mouse)

var _party_pixels := PackedVector2Array()
## The hovered member's index and the name the label was given for it, so the
## label's text is only rebuilt when either changes.
var _party_hover_index := -1
var _party_hover_name := ""
var _party_hover_job := false

## Places the dots on their map pixels (centres) and the hover name
## (FUN_0061eec0): each the 16x16 wmap_sign_party with its corners through
## 0xb42d10, MSVC's _ftol2, which truncates (`cvttsd2si`, 0xb42d25; a floor
## for these positive coordinates). The first member whose quad holds the
## mouse (PartyMapMarks.hover_hit; every member's quad is tested until one
## hits, 0x61fec0) has its name drawn centred above the quad, right after its
## dot (0x61ffc1), at trunc(x - trunc(w / 2)), trunc(top - h) with the top
## unrounded (0x61fd8e, 0x61ff95..0x61ffb9); in a job party the name is
## `*Name` (CharacterDependentData 0x99a4c5: the manager's job-party flag).
func place_party_dots(pixels: PackedVector2Array, names: PackedStringArray, job_party: bool,
		mouse: Vector2) -> void:
	var n := pixels.size()
	while _party_dots.size() < n:
		var dot := TextureRect.new()
		dot.name = "party_%d" % _party_dots.size()
		dot.texture = _party_tex
		dot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		dot.stretch_mode = TextureRect.STRETCH_SCALE
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dot.size = PartyMapMarks.WORLD_DOT_SIZE
		# The quad's texture is transposed, as the minimap's (PartyMapMarks).
		dot.flip_h = true
		dot.pivot_offset = PartyMapMarks.WORLD_DOT_SIZE / 2.0
		dot.rotation = PartyMapMarks.TRANSPOSE_TURN
		_party_layer.add_child(dot)
		_party_dots.append(dot)
	var hovered := -1
	for i in n:
		var dot := _party_dots[i]
		dot.position = (pixels[i] - PartyMapMarks.WORLD_DOT_SIZE / 2.0).floor()
		dot.visible = dot.texture != null and pixels[i].x > -1e8
		if hovered < 0 and dot.visible and PartyMapMarks.hover_hit(Rect2(dot.position, dot.size), mouse):
			hovered = i
	for i in range(n, _party_dots.size()):
		_party_dots[i].visible = false
	if hovered < 0 or hovered >= names.size():
		_party_label.visible = false
		_party_hover_index = -1
		return
	if hovered != _party_hover_index or names[hovered] != _party_hover_name or job_party != _party_hover_job:
		_party_hover_index = hovered
		_party_hover_name = names[hovered]
		_party_hover_job = job_party
		_party_label.text = ("*" + _party_hover_name) if job_party else _party_hover_name
		_party_label.size = _party_label.get_minimum_size()
		# Right after its dot: later dots draw over it, as in the loop.
		var di := _party_dots[hovered].get_index()
		_party_layer.move_child(_party_label, di if _party_label.get_index() < di else di + 1)
	var c := pixels[hovered]
	_party_label.position = Vector2(floorf(c.x - floorf(_party_label.size.x / 2.0)),
		floorf(c.y - PartyMapMarks.WORLD_DOT_SIZE.y / 2.0 - _party_label.size.y))
	_party_label.visible = true

## A member's world-map world position from its region-local position in the
## player's region: the player's own rule (update_player).
static func party_world(region_x: int, region_y: int, local: Vector2) -> Vector2:
	return Vector2(
		(region_y - WorldmapInfoReader.REGION_Y_ORIGIN) * WorldmapInfoReader.REGION_SPAN + local.x / 10.0,
		(region_x - WorldmapInfoReader.REGION_X_ORIGIN) * WorldmapInfoReader.REGION_SPAN + local.y / 10.0)

## Each shown party dot's centre on the canvas, "(x,y)", for the QA log and
## the tests.
func party_dots_report() -> String:
	var out: PackedStringArray = []
	for dot in _party_dots:
		if dot.visible:
			var c := dot.position + dot.size / 2.0
			out.append("(%.0f,%.0f)" % [c.x, c.y])
	return " ".join(out)

## The hovered member's name, or "" when no name is shown.
func party_hover_text() -> String:
	return _party_label.text if _party_label != null and _party_label.visible else ""

func _place_marker() -> void:
	if _marker == null:
		return
	var at: Variant = player_pixel()
	_marker.visible = at != null
	if at != null:
		_marker.position = (at as Vector2) - _marker.size / 2.0

## Where the player's arrow goes on the map shown, in canvas pixels, or null
## when it is not drawn:
## - a dungeon floor: 0x60f660's pixel, drawn only when the floor is the
##   player's (0x614890 -> 0x612920: the floor's label against the text of
##   the player's floor name; no floor, no arrow);
## - a field map, the player in a dungeon: the dungeon's field point
##   (0x60fa90, worldmap_instanceinfo.txt), when the map covers it (OURS, as
##   the field's own test below);
## - a field map: the player's world position, when the map covers its
##   region.
func player_pixel() -> Variant:
	if _mode == MODE_DUNGEON:
		if _dungeon_map == null or not in_dungeon():
			return null
		if _dungeon_map.floor_label() != _text(_player_floor_key):
			return null
		return _dungeon_map.pixel_for_dungeon(_player_dungeon_pos, (_player_rid >> 8) & 0xff)
	if _current == null:
		return null
	if in_dungeon():
		var point: Variant = WorldmapInstanceInfoReader.field_point(instance_table, _player_rid)
		if point == null:
			return null
		var px := _current.pixel_for_world(point as Vector2)
		if px.x < 0.0 or px.y < 0.0 or px.x > _current.draw_size.x or px.y > _current.draw_size.y:
			return null
		return px
	if _player_region.x < 0 or not _current.covers_region(_player_region.x, _player_region.y):
		return null
	return _current.pixel_for_world(_player_world)

## Puts the player under the middle of the map area (0x61cc30: the scroll
## set from the player's pixel less half the area, through 0x61c5a0),
## clamped to the map. A player who is not on this map leaves the map's
## middle there instead (ours).
##
## On a dungeon floor the scroll goes to the player's pixel too (0x61cc30,
## mode 2: +0x97ac), drawn or not; on a field map with the player in a
## dungeon, to the dungeon's field point (+0x97b4).
func _centre_on_player() -> void:
	if _viewport == null or (_current == null and _mode != MODE_DUNGEON):
		return
	var target := _viewport.size / 2.0
	var at: Variant = null
	if _mode == MODE_DUNGEON:
		if _dungeon_map != null and in_dungeon():
			at = _dungeon_map.pixel_for_dungeon(_player_dungeon_pos, (_player_rid >> 8) & 0xff)
	else:
		at = player_pixel()
	if at != null:
		target -= at as Vector2
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
##
## Round 775, the signs (0x6232e4..0x623580 and 0x623819..0x6238fd): on the
## world map a press records the link of the first picture sign under the
## mouse (+0x9800, cleared by every press); the release takes the first
## picture sign under the mouse and, when its link is that one and not a
## fortress (1001..1999), opens it -- a local map below 2001, a dungeon floor
## from it -- and centres the view (0x61cc30). The press and the release
## both stay the viewport's, so neither walks the player.
func _on_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		_panning = mb.pressed
		_pan_from = mb.position
		var on_map := mb.position - _canvas.position
		if mb.pressed:
			_pressed_link = 0
			if _teleport_select:
				# 0x6232c0: the popup hidden and every icon's pick cleared.
				_select_press()
			elif _mode == MODE_WORLD:
				var hit := sign_at(on_map)
				if hit != null and hit.link != 0:
					_pressed_link = hit.link
			_mouse_turns_auto_off()
			move_to_front()
		else:
			if _teleport_select:
				# 0x623610..0x6237fb: the selection mode's release is the
				# icons' alone -- no sign opens a map.
				_select_release(on_map)
			elif _mode == MODE_WORLD:
				_release_on_sign(on_map)
			_pressed_link = 0
		_viewport.accept_event()
	elif event is InputEventMouseMotion and _teleport_select and not _panning:
		_select_hover((event as InputEventMouseMotion).position - _canvas.position)
	elif event is InputEventMouseMotion and _panning:
		var mm := event as InputEventMouseMotion
		_canvas.position = _clamp_scroll(_canvas.position + mm.position - _pan_from)
		_pan_from = mm.position
		_refresh_tiles()
		_viewport.accept_event()

## The release half of a sign click (0x623819..0x62393b, READ): the picture
## signs under the mouse in order; the first one decides -- no link, or not
## the pressed one, and nothing opens -- except that a pressed fortress
## (1001..1999, 0x6238e2..0x6238ee) passes on to the next sign under the
## mouse. A link up to 2000 opens as a local map (0x622b60(1, id)), above it
## as a dungeon floor (0x6217e0); both then centre (0x61cc30).
func _release_on_sign(on_map: Vector2) -> void:
	if _table == null or _table.world() == null:
		return
	var world := _table.world()
	for pair in _signs:
		var sign: WorldmapLocalInfoReader.Sign = pair[0]
		if sign.type != WorldmapLocalInfoReader.TYPE_PICTURE or not sign.hit(world.region_left, world.region_top, on_map):
			continue
		if sign.link == 0 or sign.link != _pressed_link:
			return
		if _pressed_link >= FORT_FIRST and _pressed_link <= FORT_LAST:
			continue
		open_link(sign.link)
		return

## Opens a sign's linked map, as its click does: below 2001 a local map
## (0x622b60), from 2001 a dungeon floor (0x6217e0), then the view centred
## on the player (0x61cc30).
func open_link(link: int) -> void:
	if _table == null:
		return
	if link < WorldmapInfoReader.FIRST_DUNGEON_ID:
		var info := _table.by_id(link)
		if info == null:
			return
		_show_map(info)
	elif not show_dungeon(link):
		return
	_centre_on_player()
	_refresh_tiles()

## The floor spinner's up button (22 -> 0x60f080), then the render's floor
## check (0x621ca0), which this client runs at once rather than on the next
## frame (OURS).
func floor_up() -> void:
	_floor_step(1)
	_poll_floor()

## The down button (24 -> 0x60efc0), then the floor check.
func floor_down() -> void:
	_floor_step(-1)
	_poll_floor()

## 0x60f080 / 0x60efc0: auto-move turned off with the stale flag when on
## (the window's +0x229ac = 1, +0x7b1 = 0, through 0x799920 -> window 28),
## then, within the spinner's bounds, the floor stepped, the label redrawn
## (0x60edd0), and the two buttons enabled by whether a further step is
## possible (0x471dc0).
func _floor_step(delta: int) -> void:
	if _auto:
		_auto_art_stale = true
		_auto = false
	var next := _floor_index + delta
	if next < 0 or next > _floor_max:
		return
	_floor_index = next
	_refresh_floor_label()
	var spinner := _at(ID_FLOOR)
	if spinner == null:
		return
	var up := TwoDtBuilder.child(spinner, ID_FLOOR_UP) as BaseButton
	if up != null:
		up.disabled = _floor_index >= _floor_max
	var down := TwoDtBuilder.child(spinner, ID_FLOOR_DOWN) as BaseButton
	if down != null:
		down.disabled = _floor_index <= 0

## 0x60edd0: "%c%d" (letter, floor) for spelling 1, "%d%c" for 2, "%d"
## otherwise, on the label 27.
func _refresh_floor_label() -> void:
	var spinner := _at(ID_FLOOR)
	var label := TwoDtBuilder.child(spinner, ID_FLOOR_LABEL) if spinner != null else null
	if label == null or _twodt == null:
		return
	_twodt.set_text(label, floor_text())

## The spinner's text (0x60edd0).
func floor_text() -> String:
	var n := _floor_index + 1
	if _floor_mode == 1:
		return "" if _floor_letter == "" else "%s%d" % [_floor_letter, n]
	if _floor_mode == 2:
		return "%d%s" % [n, _floor_letter]
	return "%d" % n

## CNIFWorldMap 0x621ca0 (READ), on a dungeon floor: with auto-move on the
## spinner is brought to the floor shown; off, a spinner on another floor
## shows that floor of the same dungeon (0x621c60: 0x6143b0 by name and
## number, 0x6217e0, then the arrow, 0x610980).
func _poll_floor() -> void:
	if _mode != MODE_DUNGEON or _dungeon_map == null:
		return
	var want := _dungeon_map.layers - 1
	if _auto:
		while _floor_index > want and _floor_index > 0:
			_floor_step(-1)
		while _floor_index < want and _floor_index < _floor_max:
			_floor_step(1)
		return
	if _floor_index == want:
		return
	var id := _table.dungeon_floor(_dungeon_map.id, _floor_index + 1)
	if id != 0:
		show_dungeon(id)
	_place_marker()

## A key looked up as the client's TextStringManager does for the world map
## (0x8c9c30): one map of every text table, "" on a miss (0x8c9b20). This
## client looks in textzonename (zone codes, floor and room names), then the
## builder's own textuisystem, then -- for a sign's name only, as it is a
## large table -- textdata_object (the signs' `SN_ZONE_` / `STORE_` keys).
## Each archive table is read the first time it is wanted.
func _text(key: String, with_objects: bool = false) -> String:
	if key == "":
		return ""
	if not text_tables.is_empty():
		for t in text_tables:
			if t != null and (t as UiTextTable).has(key):
				return (t as UiTextTable).get_text(key)
		return ""
	var zone := _zone_table()
	if zone != null and zone.has(key):
		return zone.get_text(key)
	var ui = _builder.get("_text_table")
	if ui is UiTextTable and (ui as UiTextTable).has(key):
		return (ui as UiTextTable).get_text(key)
	if with_objects:
		var objects := _object_table()
		if objects != null and objects.has(key):
			return objects.get_text(key)
	return ""

func _zone_table() -> UiTextTable:
	if not _zone_texts_loaded:
		_zone_texts_loaded = true
		_zone_texts = _read_text_table(TEXT_ZONE_PATH)
	return _zone_texts

func _object_table() -> UiTextTable:
	if not _object_texts_loaded:
		_object_texts_loaded = true
		_object_texts = _read_text_table(TEXT_OBJECT_PATH)
	return _object_texts

func _read_text_table(path: String) -> UiTextTable:
	var archive := _builder.media_archive() if _builder != null else null
	if archive == null:
		return null
	var entry := ObjectLoader.find_file(archive, path)
	return UiTextTable.parse(archive.read_file(entry)) if entry != null else null

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

## Which kind of map is shown: MODE_WORLD, MODE_LOCAL or MODE_DUNGEON.
func map_mode() -> int:
	return _mode

## The dungeon floor shown, or null (tests, tools).
func current_dungeon() -> WorldmapInfoReader.DungeonMapInfo:
	return _dungeon_map if _mode == MODE_DUNGEON else null

# --- The reverse return scroll's selection mode (round 778) ------------------
#
# READ (docs/protocol/reverse_return_scroll.md): the box's map button
# (0x63b9a0) hides the box, shows this window and calls 0x622dd0(1, kind).
# 0x622dd0 sets +0x9990 and the box's kind (+0x9994), turns auto-move off
# (0x616b80(0)), shows the world map (0x622b60(0, 0)), returns a small window
# to the big size (0x61ca20), hides the size button 7, the world button 6,
# the floor spinner 4 and the auto button 20 (+0x9814 / +0x9818 / +0x999c /
# +0x981c, OnCreate 0x620f70's GetChild ids), centres the view (0x61cc30) and
# starts timer 0xd at 500 ms. Leaving (0x622dd0(0)) shows 20, 7 and 6 again,
# hides the popup (+0x9984) and stops the timer.
#
# The icons (+0x985c, built by 0x6192f0 from GlobalDataManager::FUN_00927850:
# one per refoptionalteleport row whose map-point byte is 1) are drawn by
# 0x61e270 only in this mode: a 32 x 32 quad (half-side 16.0, the double at
# 0xe1b8e0) centred on the point -- x = ((rid & 0xff) - 0x87) * 0xc0 + px /
# 10, y = ((rid >> 8) - 0x5c) * 0xc0 + pz / 10, the player marker's own
# transform -- less 0.5 (0xe1b7d0). The texture is
# `interface\worldmap\map\xy_returnicon.ddj`, its `_focus` under the mouse
# (WM_MOUSEMOVE, +0x38) and its `_press` once picked (+0x3c, +0xc0 = 1); the
# plain texture is drawn with the UVs at +0x9864, which timer 0xd
# (vslot_005 0x6191d0) swaps every 500 ms between its left half (u 0..0.5,
# +0x98c4) and its right half (u 0.5..1, +0x9924) -- a two-frame blink --
# while the other two are drawn whole.
#
# A release on an icon (0x623610..0x6237fb) picks it, clears the popup
# (CIFButtonPopup 0x631bc0) and fills it: a point with group -1 gives one
# button, else one per row of its group whose map-point byte is not 1 (the
# Donwhang cave's floor under its entrance's flag), each 155 x 22
# (0x631d60: `push 0x16; push 0x9b`) at y 1 + 22 * i, on
# `interface\worldmap\map\map_return.ddj`, captioned with the row's zone
# name through the text tables; the popup is shown with its corner at the
# icon's lower-left vertex (+0xa8 / +0xac, ftol). A release off every icon
# hides it. A button (0x60f5f0) records the row's id (+0x998c), runs the box's
# result 3 (FUN_00777dd0 -> 0x797d90: the use with option 7 and the id) and
# hides the window. Hiding the window in this mode (vslot_023 0x624550)
# destroys the box -- the use is not sent -- and leaves the mode.
#
# OURS: the popup's caption colour and alignment (a created CIFButton's
# defaults were not read: white, centred).

const SELECT_ICON_DDJ := "interface\\worldmap\\map\\xy_returnicon.ddj"
const SELECT_ICON_FOCUS_DDJ := "interface\\worldmap\\map\\xy_returnicon_focus.ddj"
const SELECT_ICON_PRESS_DDJ := "interface\\worldmap\\map\\xy_returnicon_press.ddj"
const SELECT_ICON_HALF := 16.0
const SELECT_ICON_NUDGE := 0.5
const SELECT_BLINK_SECONDS := 0.5
const SELECT_POPUP_BUTTON_DDJ := "interface\\worldmap\\map\\map_return.ddj"
const SELECT_POPUP_BUTTON_SIZE := Vector2(155, 22)

## A popup button was clicked: `id` is the refoptionalteleport row (0x60f5f0).
signal select_point_chosen(id: int)
## The window was hidden while selecting: the box goes, nothing is sent
## (vslot_023).
signal select_cancelled

## The reverse return scroll's table (World3D sets it); null shows no icons.
var optional_reader: OptionalTeleportReader
var _select_layer: Control
## [Point, TextureRect] for each icon, file order.
var _select_icons: Array = []
var _select_frames: Array = []   # the plain texture's two halves (AtlasTexture)
var _select_focus_tex: Texture2D
var _select_press_tex: Texture2D
var _select_frame := 0
var _select_timer: Timer
var _select_hovered := -1
var _select_picked := -1
var _select_popup: Control
## Set while the window hides itself after a pick, so the hide is not the
## cancel (0x60f5f0 clears the box first).
var _select_sent := false

func in_select_mode() -> bool:
	return _teleport_select

## 0x622dd0(1): the selection mode, as the box's map button enters it.
func enter_select_mode() -> void:
	_teleport_select = true
	_select_sent = false
	set_auto_move(false)
	if _small:
		toggle_size()
	if _table != null:
		_show_map(_table.world())
	for id in [ID_SIZE, ID_WORLD, ID_FLOOR, ID_AUTO]:
		_set_visible(id, false)
	_build_select_icons()
	_centre_on_player()
	_refresh_tiles()
	if _select_timer == null:
		_select_timer = Timer.new()
		_select_timer.name = "SelectBlink"
		_select_timer.wait_time = SELECT_BLINK_SECONDS
		_select_timer.timeout.connect(_select_blink)
		add_child(_select_timer)
	if _select_timer.is_inside_tree():
		_select_timer.start()
	_qa_note("select mode, %d icons" % _select_icons.size())

## 0x622dd0(0): the mode left, the buttons back, the popup gone.
func leave_select_mode() -> void:
	if not _teleport_select:
		return
	_teleport_select = false
	for id in [ID_AUTO, ID_SIZE, ID_WORLD]:
		_set_visible(id, true)
	_refresh_world_button()
	_hide_select_popup()
	if _select_timer != null:
		_select_timer.stop()
	if _select_layer != null:
		_select_layer.queue_free()
		_select_layer = null
	_select_icons.clear()

func _on_visibility_changed() -> void:
	if visible or not _teleport_select:
		return
	var sent := _select_sent
	leave_select_mode()
	if not sent:
		select_cancelled.emit()

func _build_select_icons() -> void:
	if _select_layer != null:
		_select_layer.queue_free()
	_select_icons.clear()
	_select_hovered = -1
	_select_picked = -1
	_select_layer = Control.new()
	_select_layer.name = "SelectIcons"
	_select_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_select_layer)
	if optional_reader == null or _current == null:
		return
	var plain: Texture2D = _builder.load_texture(SELECT_ICON_DDJ) if _builder != null else null
	_select_focus_tex = _builder.load_texture(SELECT_ICON_FOCUS_DDJ) if _builder != null else null
	_select_press_tex = _builder.load_texture(SELECT_ICON_PRESS_DDJ) if _builder != null else null
	_select_frames.clear()
	if plain != null:
		var w := plain.get_width() / 2.0
		for i in 2:
			var a := AtlasTexture.new()
			a.atlas = plain
			a.region = Rect2(w * i, 0, w, plain.get_height())
			_select_frames.append(a)
	_select_frame = 0
	for p in optional_reader.map_points():
		var pt: OptionalTeleportReader.Point = p
		var at: Variant = select_icon_pixel(pt)
		if at == null:
			continue
		var icon := TextureRect.new()
		icon.name = "SelectIcon%d" % pt.id
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_SCALE
		icon.size = Vector2(SELECT_ICON_HALF * 2.0, SELECT_ICON_HALF * 2.0)
		icon.position = (at as Vector2) - Vector2(SELECT_ICON_HALF + SELECT_ICON_NUDGE, SELECT_ICON_HALF + SELECT_ICON_NUDGE)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_select_layer.add_child(icon)
		_select_icons.append([pt, icon])
	_refresh_select_textures()
	_canvas.move_child(_select_layer, -1)

## The canvas pixel a map point's icon is centred on (0x61e270's transform,
## the player marker's), or null when the world map shown does not cover it
## or the point is a dungeon's (never a map point in the retail table).
func select_icon_pixel(p: OptionalTeleportReader.Point) -> Variant:
	if _current == null or p == null or p.in_dungeon():
		return null
	var w := Vector2(
		(p.region_y() - WorldmapInfoReader.REGION_Y_ORIGIN) * WorldmapInfoReader.REGION_SPAN + p.x / 10.0,
		(p.region_x() - WorldmapInfoReader.REGION_X_ORIGIN) * WorldmapInfoReader.REGION_SPAN + p.z / 10.0)
	var px := _current.pixel_for_world(w)
	if px.x < 0.0 or px.y < 0.0 or px.x > _current.draw_size.x or px.y > _current.draw_size.y:
		return null
	return px

func _select_blink() -> void:
	_select_frame = 1 - _select_frame
	_refresh_select_textures()

func _refresh_select_textures() -> void:
	for i in _select_icons.size():
		var icon: TextureRect = _select_icons[i][1]
		if i == _select_picked and _select_press_tex != null:
			icon.texture = _select_press_tex
		elif i == _select_hovered and _select_focus_tex != null:
			icon.texture = _select_focus_tex
		elif not _select_frames.is_empty():
			icon.texture = _select_frames[_select_frame]

func _select_icon_at(on_map: Vector2) -> int:
	for i in _select_icons.size():
		var icon: TextureRect = _select_icons[i][1]
		var r := Rect2(icon.position, icon.size)
		# 0x623610: strictly inside the quad.
		if on_map.x > r.position.x and on_map.x < r.end.x and on_map.y > r.position.y and on_map.y < r.end.y:
			return i
	return -1

func _select_hover(on_map: Vector2) -> void:
	var i := _select_icon_at(on_map)
	if i != _select_hovered:
		_select_hovered = i
		_refresh_select_textures()

func _select_press() -> void:
	_hide_select_popup()
	_select_picked = -1
	_refresh_select_textures()

func _select_release(on_map: Vector2) -> void:
	var i := _select_icon_at(on_map)
	if i < 0:
		_hide_select_popup()
		return
	_select_picked = i
	_refresh_select_textures()
	_show_select_popup(i)

## The names a click on icon `i` offers, as the popup lists them.
func select_choices(i: int) -> Array:
	if optional_reader == null or i < 0 or i >= _select_icons.size():
		return []
	return optional_reader.choices_for(_select_icons[i][0])

func _show_select_popup(i: int) -> void:
	_hide_select_popup()
	var popup := Control.new()
	popup.name = "SelectPopup"
	popup.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var choices := select_choices(i)
	var y := 1.0
	for c in choices:
		var pt: OptionalTeleportReader.Point = c
		var btn := _popup_button(pt)
		btn.position = Vector2(0, y)
		popup.add_child(btn)
		y += SELECT_POPUP_BUTTON_SIZE.y
	popup.size = Vector2(SELECT_POPUP_BUTTON_SIZE.x if not choices.is_empty() else 0.0, y - 1.0)
	var icon: TextureRect = _select_icons[i][1]
	# The quad's lower-left vertex (+0xa8 / +0xac), in the window.
	var corner := _viewport.position + _canvas.position + icon.position + Vector2(0, icon.size.y)
	popup.position = Vector2(floorf(corner.x), floorf(corner.y))
	add_child(popup)
	_select_popup = popup

func _popup_button(pt: OptionalTeleportReader.Point) -> BaseButton:
	var btn := TextureButton.new()
	btn.name = "Choice%d" % pt.id
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_SCALE
	btn.size = SELECT_POPUP_BUTTON_SIZE
	btn.custom_minimum_size = SELECT_POPUP_BUTTON_SIZE
	if _builder != null:
		btn.texture_normal = _builder.load_texture(SELECT_POPUP_BUTTON_DDJ)
		btn.texture_hover = _builder.load_texture(SELECT_POPUP_BUTTON_DDJ.replace(".ddj", "_focus.ddj"))
		btn.texture_pressed = _builder.load_texture(SELECT_POPUP_BUTTON_DDJ.replace(".ddj", "_press.ddj"))
	var label := Label.new()
	label.name = "ButtonLabel"
	label.text = select_point_name(pt)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	if _builder != null:
		var font: Font = _builder.font_at(0)
		if font != null:
			label.add_theme_font_override("font", font)
			label.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	btn.add_child(label)
	btn.pressed.connect(_on_select_choice.bind(pt.id))
	return btn

## A row's name as the popup captions it: its zone key through the text
## tables (0x8c9c30), the key itself never shown.
func select_point_name(pt: OptionalTeleportReader.Point) -> String:
	var t := _text(pt.zone_strid, true)
	return t if t != "" else pt.zone_strid

func _hide_select_popup() -> void:
	if _select_popup != null:
		_select_popup.queue_free()
		_select_popup = null

## 0x60f5f0: the row recorded, the box's result 3 run (World3D sends the
## use), then the window hidden -- which leaves the mode.
func _on_select_choice(id: int) -> void:
	_select_sent = true
	select_point_chosen.emit(id)
	hide()
	leave_select_mode()

## The icons built (tests, the QA hook): [Point, TextureRect] pairs.
func select_icons() -> Array:
	return _select_icons

## The popup's buttons, top to bottom (tests).
func select_popup_buttons() -> Array:
	if _select_popup == null:
		return []
	return _select_popup.get_children()

## QA: scrolls the icon of row `id` to the middle and clicks it, so the
## popup shows.
func qa_pick(id: int) -> void:
	if not _teleport_select:
		enter_select_mode()
	for i in _select_icons.size():
		if (_select_icons[i][0] as OptionalTeleportReader.Point).id != id:
			continue
		var icon: TextureRect = _select_icons[i][1]
		var centre := icon.position + icon.size / 2.0
		_canvas.position = _clamp_scroll(_viewport.size / 2.0 - centre)
		_refresh_tiles()
		var at := _canvas.position + centre
		for pressed in [true, false]:
			var ev := InputEventMouseButton.new()
			ev.button_index = MOUSE_BUTTON_LEFT
			ev.pressed = pressed
			ev.position = at
			_on_viewport_input(ev)
		print("QA WORLDMAP pick %d -> %d choices: %s" % [id, select_popup_buttons().size(),
			", ".join(select_popup_buttons().map(func(b): return (b.get_node("ButtonLabel") as Label).text))])
		return
	print("QA WORLDMAP pick %d: no such icon" % id)

## The QA hook's steps (OPENSRO_QA_WORLDMAP, World3D): a comma list of
## `world`, `sign:<map id>` (the world map scrolled to the first sign linking
## to that map), `click:<map id>` (the same, then a real press and release on
## it through the viewport's own input), `dungeon:<id>`, `up`, `down`. Groups
## separated by `;` run a second apart, so a render catches each. Each step
## logs the window's state.
func qa_apply(spec: String) -> void:
	var groups := spec.split(";")
	_qa_steps(groups[0])
	for i in range(1, groups.size()):
		get_tree().create_timer(float(i)).timeout.connect(_qa_steps.bind(groups[i]))

func _qa_steps(spec: String) -> void:
	for step in spec.split(","):
		var s := step.strip_edges()
		if s == "world":
			show_world()
		elif s.begins_with("sign:"):
			show_world()
			_qa_click_link(int(s.trim_prefix("sign:")), false)
		elif s.begins_with("click:"):
			show_world()
			_qa_click_link(int(s.trim_prefix("click:")))
		elif s.begins_with("dungeon:"):
			show_dungeon(int(s.trim_prefix("dungeon:")))
		elif s == "up":
			floor_up()
		elif s == "down":
			floor_down()
		elif s == "select":
			enter_select_mode()
		elif s.begins_with("pick:"):
			qa_pick(int(s.trim_prefix("pick:")))
		else:
			continue
		print("QA WORLDMAP %s -> %s" % [s, qa_report()])

## Scrolls the sign linking to `link` into the middle of the map area and
## (`click`) clicks it the way a mouse does.
func _qa_click_link(link: int, click: bool = true) -> void:
	if _table == null or _table.world() == null:
		return
	var world := _table.world()
	for sign: WorldmapLocalInfoReader.Sign in signs():
		if sign.link != link or sign.type != WorldmapLocalInfoReader.TYPE_PICTURE:
			continue
		var r := sign.rect(world.region_left, world.region_top)
		_canvas.position = _clamp_scroll(_viewport.size / 2.0 - r.get_center())
		_refresh_tiles()
		var at := _canvas.position + r.get_center()
		_place_marker()
		if not click:
			return
		for pressed in [true, false]:
			var ev := InputEventMouseButton.new()
			ev.button_index = MOUSE_BUTTON_LEFT
			ev.pressed = pressed
			ev.position = at
			_on_viewport_input(ev)
		return
	print("QA WORLDMAP no sign links to %d" % link)

## The window's state in one line, for the QA log and the tests.
func qa_report() -> String:
	var bar := get_node_or_null("TitleBar") as Label
	var floor_node := _at(ID_FLOOR)
	var at: Variant = player_pixel()
	return "mode=%d map=%d caption='%s' floor=%s'%s' auto=%s marker=%s signs=%d tiles=%d" % [
		_mode, _dungeon_map.id if _mode == MODE_DUNGEON and _dungeon_map != null else (_current.id if _current != null else -1),
		bar.text if bar != null else "",
		"shown " if floor_node != null and floor_node.visible else "hidden ", floor_text(),
		_auto, "(%.0f,%.0f)" % [(at as Vector2).x, (at as Vector2).y] if at != null else "none",
		_signs.size(), _tiles.size()]

## A map switch logged during a QA run (OPENSRO_QA_WORLDMAP set).
func _qa_note(what: String) -> void:
	if OS.get_environment("OPENSRO_QA_WORLDMAP") != "":
		print("QA WORLDMAP shows %s: %s" % [what, qa_report()])

## A `.dof` block's room name key (P4's first list by the block's room
## index; DofReader), or "" -- the room 0x6145e0's caption names.
static func dof_room_key(dof: DofReader.Dof, block: int) -> String:
	if dof == null or block < 0 or block >= dof.blocks.size():
		return ""
	var r: int = (dof.blocks[block] as DofReader.Block).room_index
	return dof.room_names[r] if r >= 0 and r < dof.room_names.size() else ""
