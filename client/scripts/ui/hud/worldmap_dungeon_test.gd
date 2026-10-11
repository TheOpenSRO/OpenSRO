extends SceneTree

## Round 775: the world map's dungeons (HudWorldmap; the RE is in its header
## and docs/protocol/WORLDMAP_FORMAT.md). The window is built from synthetic
## records with the real worldmapguide.2dt's ids, types, parents and rects
## (as worldmap_window_test.gd), a synthetic map table (a world map, a town,
## a fortress and five dungeon floors), synthetic signs and instance points
## and a synthetic text table -- no art, no game text (docs/LEGAL.md):
##   godot4 --headless --path client --script res://scripts/ui/hud/worldmap_dungeon_test.gd
##
## It checks the click on a world-map dungeon sign (0x623220), the floor shown
## (0x6217e0: tiles, caption, spinner, world button, auto-move turned off),
## the spinner (0x60f080 / 0x60efc0 / 0x621ca0), the way back (0x6231e0), and
## the player in a dungeon (0x614280, 0x60f660, 0x614890, 0x60fa90).

const WORLDMAP_PATH := "res://scripts/ui/hud/hud_worldmap.gd"
const READER_PATH := "res://scripts/ui/twodt_reader.gd"
const RECORD := 0x3d0
const AUTO_DDJ := "interface\\worldmap\\wmap_button_automatic.ddj"
const MANUAL_DDJ := "interface\\worldmap\\wmap_button_passivity.ddj"
const WORLD_DDJ := "interface\\worldmap\\wmap_big_button_world.ddj"
const UP_DDJ := "interface\\worldmap\\wmap_up_button.ddj"
const DOWN_DDJ := "interface\\worldmap\\wmap_down_button.ddj"
const ICON_DDJ := "interface\\worldmap\\map\\test_dungeon.ddj"
const TOWN_DDJ := "interface\\worldmap\\map\\test_town.ddj"
const FORT_DDJ := "interface\\worldmap\\map\\test_fort.ddj"
const CAVE := "interface\\worldmap\\dungeon\\test_cave_f%d_"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await _run()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

# --- synthetic records (worldmap_window_test.gd's) ---------------------------

func _rec(f: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(RECORD)
	b.fill(0)
	for pair in [[0x000, "name"], [0x040, "base"], [0x140, "tex"], [0x240, "textid"]]:
		var bytes: PackedByteArray = str(f.get(pair[1], "")).to_ascii_buffer()
		for i in bytes.size():
			b[pair[0] + i] = bytes[i]
	b.encode_u32(0x340, f.get("type", 5))
	b.encode_u32(0x344, f.get("id", 0))
	b.encode_u32(0x348, f.get("parent", 0))
	b.encode_u32(0x34c, f.get("gp", 0))
	b.encode_u32(0x358, 0xffffffff)
	var r: Rect2i = f.get("rect", Rect2i())
	b.encode_s32(0x35c, r.position.x)
	b.encode_s32(0x360, r.position.y)
	b.encode_s32(0x364, r.size.x)
	b.encode_s32(0x368, r.size.y)
	b.encode_u32(0x390, 0xffffffff)
	b.encode_u32(0x394, 1 if f.get("root", false) else 0)
	b[0x3cd] = 1
	b[0x3ce] = 1
	return b

func _file(records: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, records.size())
	for r in records:
		out.append_array(_rec(r))
	return out

func _worldmap() -> Array:
	return [
		{"type": 0, "id": 28, "name": "CNIFWorldMap", "root": true, "rect": Rect2i(496, 115, 650, 422), "base": "interface\\frame\\mframe_wnd_"},
		{"type": 5, "id": 26, "parent": 28, "rect": Rect2i(496, 127, 0, 0), "tex": "interface\\worldmap\\wmap_wnd_bottom_frame.ddj"},
		{"type": 5, "id": 30, "parent": 28, "rect": Rect2i(32767, 32767, 0, 0), "textid": "UIIT_STT_WORLDMAP_LEVEL_MONSTER_LIST"},
		{"type": 11, "id": 31, "parent": 28, "rect": Rect2i(1110, 541, 0, 0), "tex": "interface\\ifcommon\\com_checkbutton_off.ddj"},
		{"type": 4, "id": 6, "parent": 28, "rect": Rect2i(1063, 154, 36, 36), "tex": WORLD_DDJ},
		{"type": 4, "id": 20, "parent": 28, "rect": Rect2i(1101, 154, 36, 36), "tex": MANUAL_DDJ},
		{"type": 5, "id": 30, "parent": 28, "rect": Rect2i(496, 115, 0, 0), "tex": "interface\\worldmap\\wmap_wnd_corner_02.ddj"},
		{"type": 1, "id": 11, "name": "CNIFWorldMapGuide", "parent": 28, "rect": Rect2i(198, 115, 298, 296), "base": "interface\\inventory\\int_window_"},
		{"type": 2, "id": 12, "parent": 11, "gp": 28, "rect": Rect2i(214, 131, 270, 264), "base": "interface\\ifcommon\\bg_tile\\com_bg_tile_b.ddj"},
		{"type": 1, "id": 16, "parent": 11, "gp": 28, "rect": Rect2i(209, 147, 279, 258), "base": "interface\\equipment\\equip_window_"},
		{"type": 2, "id": 21, "parent": 11, "gp": 28, "rect": Rect2i(220, 158, 257, 235), "base": "interface\\ifcommon\\bg_tile\\com_bg_tile_d.ddj"},
		{"type": 5, "id": 13, "parent": 28, "rect": Rect2i(478, 116, 0, 0), "tex": "interface\\guide\\gd_side_tab.ddj"},
		{"type": 4, "id": 15, "parent": 28, "rect": Rect2i(484, 212, 0, 0), "tex": "interface\\ifcommon\\com_side02_button.ddj"},
		{"type": 4, "id": 7, "parent": 28, "rect": Rect2i(1102, 125, 16, 16), "tex": "interface\\worldmap\\wmap_button_windowsize.ddj"},
		{"type": 18, "id": 4, "name": "CNIFVerticalSpinButtonCtrl", "parent": 28, "rect": Rect2i(1107, 204, 29, 47)},
		{"type": 4, "id": 22, "parent": 4, "gp": 28, "rect": Rect2i(1108, 205, 28, 12), "tex": UP_DDJ},
		{"type": 4, "id": 24, "parent": 4, "gp": 28, "rect": Rect2i(1108, 238, 28, 12), "tex": DOWN_DDJ},
		{"type": 5, "id": 27, "parent": 4, "gp": 28, "rect": Rect2i(1111, 221, 23, 17)},
	]

## The world map of worldmap_window_test.gd (regions y 100..107, x 101..98,
## 1024x512), a town (id 1), a fortress (1001), a four-floor cave (2001..2004,
## region id 0x8001, three by three tiles of 256) and a one-floor tomb (2005).
func _table() -> Object:
	var table := WorldmapInfoReader.ParsedTable.new()
	var world := WorldmapInfoReader.MapInfo.new()
	world.id = 0
	world.type = WorldmapInfoReader.TYPE_WORLD
	world.addr = "interface\\worldmap\\map\\test_world_"
	world.texture_size = Vector2i(128, 128)
	world.pic_area = Vector2i(128, 128)
	world.draw_size = Vector2i(1024, 512)
	world.region_left = 100
	world.region_right = 107
	world.region_top = 101
	world.region_bottom = 98
	world.regions_per_tile = Vector2i(2, 2)
	world.name_key = "TEST_WORLD"
	table.maps.append(world)
	for spec in [[1, 101, 98, "TEST_TOWN"], [1001, 104, 99, "TEST_FORT"]]:
		var m := WorldmapInfoReader.MapInfo.new()
		m.id = spec[0]
		m.type = WorldmapInfoReader.TYPE_LOCAL
		m.addr = "interface\\worldmap\\map\\test_local_%d.ddj" % spec[0]
		m.texture_size = Vector2i(1024, 1024)
		m.pic_area = Vector2i(1024, 768)
		m.draw_size = Vector2i(1024, 768)
		m.region_left = spec[1]
		m.region_right = spec[1]
		m.region_top = spec[2]
		m.region_bottom = spec[2]
		m.name_key = spec[3]
		table.maps.append(m)
	for n in 4:
		table.dungeons.append(_floor(2001 + n, "Cave", "F", n + 1, 4, 0x8001, CAVE % (n + 1)))
	table.dungeons.append(_floor(2005, "Tomb", "B", 1, 1, 0x8007, "interface\\worldmap\\dungeon\\test_tomb_"))
	return table

func _floor(id: int, name: String, layer: String, n: int, total: int, code: int, path: String) -> WorldmapInfoReader.DungeonMapInfo:
	var d := WorldmapInfoReader.DungeonMapInfo.new()
	d.id = id
	d.name = name
	d.layer = layer
	d.layers = n
	d.total_layers = total
	d.zone_code = code
	d.texture_count = Vector2i(3, 3)
	d.draw_size = Vector2i(768, 768)
	d.region_left = 127
	d.region_top = 128
	d.region_right = 129
	d.region_bottom = 126
	d.scale = 1.0
	d.addr = path
	d.region_id = code & 0x7fff
	return d

func _sign(id: int, type: int, text: String, link: int, parent: int, ra: int, rb: int, pos: Vector2i, size: Vector2i) -> Object:
	var s := WorldmapLocalInfoReader.Sign.new()
	s.id = id
	s.type = type
	s.text = text
	s.link = link
	s.parent = parent
	s.region_a = ra
	s.region_b = rb
	s.pos = pos
	s.size = size
	return s

## On the world map: the cave's icon at region (102, 100) + (4, 4), the
## town's at (101, 100) + (4, 4), the fortress's at (104, 100) + (4, 4), all
## 32x32; on the cave's first floor a text sign.
func _signs() -> Object:
	var t := WorldmapLocalInfoReader.Table.new()
	t.signs.append(_sign(1, 2, ICON_DDJ, 2001, 0, 102, 100, Vector2i(4, 4), Vector2i(32, 32)))
	t.signs.append(_sign(2, 2, TOWN_DDJ, 1, 0, 101, 100, Vector2i(4, 4), Vector2i(32, 32)))
	t.signs.append(_sign(3, 2, FORT_DDJ, 1001, 0, 104, 100, Vector2i(4, 4), Vector2i(32, 32)))
	t.signs.append(_sign(4, 1, "TEST_EXIT", 0, 2001, -1, -1, Vector2i(405, 394), Vector2i(2, 0)))
	return t

## The cave's field point: region (103, 99), position (960, 0, 960).
func _instances() -> Object:
	var text := "//CodeName\tName\n" + "Worldmap_TEST\tx\t1\t128\t1\t128\t103\t99\t960\t0\t960\n"
	return WorldmapInstanceInfoReader.parse(text.to_utf16_buffer())

func _text_table() -> UiTextTable:
	var rows := PackedStringArray()
	for pair in [["UIIT_PAG_WORLDMAP", "World map (tip)"], ["UIIT_PAG_LOCALMAP", "Local map"],
			["UIIT_STT_WORLDMAP_AUTO_MOVE", "Auto (tip)"], ["UIIT_STT_WORLDMAP_MANUAL_MOVE", "Manual (tip)"],
			["TEST_WORLD", "The World"], ["TEST_TOWN", "The Town"], ["TEST_FORT", "The Fort"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

func _zone_table() -> UiTextTable:
	var rows := PackedStringArray()
	for pair in [["32769", "Test Cave"], ["32775", "Test Tomb"], ["TEST_F1", "1F"], ["TEST_F2", "2F"],
			["TEST_ROOM", "Room A"], ["TEST_EXIT", "Exit"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

func _tex(builder: UiBuilder, path: String, size: Vector2i) -> void:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.4, 0.3, 0.2, 1.0))
	var tex := ImageTexture.create_from_image(img)
	tex.resource_name = path.to_lower()
	(builder.get("_texture_cache") as Dictionary)[path.to_lower()] = tex

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, _text_table())
	var Reader = load(READER_PATH)
	var cache = builder.get("_twodt_cache")
	if Reader != null and cache is Dictionary:
		cache["res_ui\\worldmapguide.2dt"] = Reader.parse(_file(_worldmap()))
	for p in [AUTO_DDJ, MANUAL_DDJ, WORLD_DDJ, ICON_DDJ, TOWN_DDJ, FORT_DDJ]:
		_tex(builder, p, Vector2i(32, 32))
	for p in [UP_DDJ, DOWN_DDJ]:
		_tex(builder, p, Vector2i(28, 12))
	for n in 2:
		for a in 3:
			for b in 3:
				_tex(builder, (CAVE % (n + 1)) + "%dx%d.ddj" % [127 + a, 128 - b], Vector2i(4, 4))
	return builder

# --- helpers -----------------------------------------------------------------

func _at(root: Node, id: int) -> Control:
	if root == null:
		return null
	for c in root.get_children():
		if c.has_meta("twodt_id") and int(c.get_meta("twodt_id")) == id:
			return c
	return null

func _caption(window: Control) -> String:
	var bar := window.get_node_or_null("TitleBar") as Label
	return bar.text if bar != null else "<no caption>"

## A real press and release on the map at canvas pixel `press` (and `release`).
func _click(window: Control, press: Vector2, release: Vector2 = Vector2(-1, -1)) -> void:
	var canvas := window.find_child("MapCanvas", true, false) as Control
	for down in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = down
		var at: Vector2 = press if down or release.x < 0.0 else release
		ev.position = canvas.position + at
		window.call("_on_viewport_input", ev)

func _floor_label(spinner: Control) -> String:
	var label := _at(spinner, 27)
	var text := label.get_node_or_null("Text") as Label if label != null else null
	return text.text if text != null else "<none>"

func _dungeon_id(window: Control) -> int:
	var d = window.call("current_dungeon")
	return d.id if d != null else -1

# --- the checks --------------------------------------------------------------

func _run() -> void:
	await process_frame
	get_root().size = Vector2i(1152, 648)
	await process_frame
	var builder := _builder()
	var script := load(WORLDMAP_PATH) as GDScript
	var window: Control = script.new(builder)
	window.set("map_table", _table())
	window.set("local_table", _signs())
	window.set("instance_table", _instances())
	window.set("text_tables", [_zone_table()])
	get_root().add_child(window)
	var built: bool = window.call("build_worldmap")
	_check(built, "the world map builds")
	if not built:
		return
	window.call("open")
	await process_frame
	var root: Control = window.get("panel_root")
	var spinner := _at(root, 4)
	var world_btn := _at(root, 6)
	var up := _at(spinner, 22) as BaseButton
	var down := _at(spinner, 24) as BaseButton

	# --- the world map's signs ----------------------------------------------
	_check(int(window.call("map_mode")) == 0, "it opens on the world map (mode 0)")
	_check(window.find_child("PlaceLabels", true, false) == null,
		"with the sign table, the world map draws its signs and not the round-599 name plates")
	var sign_layer := window.find_child("Signs", true, false) as Control
	var icon := sign_layer.get_node_or_null("Sign1") as TextureRect if sign_layer != null else null
	_check(icon != null and icon.position == Vector2(68, 36) and icon.size == Vector2(32, 32),
		"the dungeon icon is at (4 + 2 * 32, 4 + 1 * 32), 32x32 (0x6210b0; got %s)" % (icon.position if icon else null))
	_check((window.call("signs") as Array).size() == 3, "the world map lists its three signs, not the floor's")

	# --- a click that is not one --------------------------------------------
	_click(window, Vector2(84, 52), Vector2(52, 52))
	_check(int(window.call("map_mode")) == 0, "a press on the dungeon icon released on the town's opens nothing (0x6238d4)")
	_click(window, Vector2(148, 52))
	_check(int(window.call("map_mode")) == 0, "a fortress icon opens nothing (0x6238e2)")
	_click(window, Vector2(68, 52))
	_check(int(window.call("map_mode")) == 0, "a press on the icon's very edge is not on it (strictly inside, 0x623220)")

	# --- the dungeon icon ---------------------------------------------------
	# Button 20 pressed twice: the clicks above left the stale flag, and the
	# first press is taken back (0x616870).
	window.call("set_auto_move", true)
	window.call("set_auto_move", true)
	_check(bool(window.call("is_auto_move")), "auto-move is on before the click")
	_click(window, Vector2(84, 52))
	_check(int(window.call("map_mode")) == 2 and _dungeon_id(window) == 2001,
		"a press and a release on the dungeon icon open its floor, map 2001 (0x6217e0; got mode %d, %d)"
			% [int(window.call("map_mode")), _dungeon_id(window)])
	_check(_caption(window) == "Test Cave", "the caption is the zone code's text (0x6145e0; got '%s')" % _caption(window))
	_check(world_btn.visible, "the world button is shown on a floor (0x614840)")
	_check(spinner.visible and _floor_label(spinner) == "1F",
		"the floor spinner is shown, on 1F (0x6217e0, 0x60edd0; got %s '%s')" % [spinner.visible, _floor_label(spinner)])
	_check(up != null and not up.disabled and down != null and down.disabled,
		"up can step, down cannot (0x471dc0)")
	_check(not bool(window.call("is_auto_move")) and bool(window.get("_auto_art_stale")),
		"the press turned auto-move off with the stale flag (0x6235ad)")
	var tiles: PackedStringArray = window.call("tile_paths")
	_check(tiles.has((CAVE % 1) + "127x128.ddj") and tiles.has((CAVE % 1) + "129x126.ddj"),
		"its tiles are <path><left+a>x<top-b> (got %d tiles)" % tiles.size())
	var tile := window.find_child("Tile_2_1", true, false) as Control
	_check(tile != null and tile.position == Vector2(512, 256) and tile.size == Vector2(256, 256),
		"tile (2, 1) is at (512, 256), 256 a side (0x6196d0; got %s)" % (Rect2(tile.position, tile.size) if tile else null))
	var floor_signs := window.call("signs") as Array
	var exit := sign_layer.get_node_or_null("Sign4") as Label
	_check(floor_signs.size() == 1 and exit != null and exit.text == "Exit"
		and is_equal_approx(exit.position.x + floorf(exit.size.x / 2.0), 405.0) and exit.position.y == 394.0,
		"the floor's text sign, centred on its x (got %s)" % (exit.position if exit else null))
	var marker := window.find_child("PlayerMarker", true, false) as Control
	_check(not marker.visible, "with the player in the field, no arrow on a floor (0x614890)")

	# --- the spinner --------------------------------------------------------
	up.pressed.emit()
	_check(_dungeon_id(window) == 2002 and _floor_label(spinner) == "2F",
		"up shows the same dungeon's 2F (0x60f080 -> 0x621ca0 -> 0x6143b0; got %d '%s')" % [_dungeon_id(window), _floor_label(spinner)])
	tiles = window.call("tile_paths")
	_check(tiles.has((CAVE % 2) + "128x127.ddj") and not tiles.has((CAVE % 1) + "128x127.ddj"),
		"with the second floor's tiles")
	_check(not down.disabled, "and down can step now")
	down.pressed.emit()
	_check(_dungeon_id(window) == 2001, "down goes back to 1F")
	for i in 3:
		up.pressed.emit()
	_check(_dungeon_id(window) == 2004 and up.disabled and _floor_label(spinner) == "4F",
		"three ups reach 4F, where up stops (got %d)" % _dungeon_id(window))
	up.pressed.emit()
	_check(_dungeon_id(window) == 2004, "a press past the top changes nothing")

	# --- back to the world --------------------------------------------------
	world_btn.pressed.emit()
	_check(int(window.call("map_mode")) == 0 and not spinner.visible and not world_btn.visible,
		"the world button goes back to the world map and hides the spinner (0x6231e0)")
	_check((window.call("signs") as Array).size() == 3, "with the world map's signs again")

	# --- a one-floor dungeon ------------------------------------------------
	window.call("set_auto_move", true)
	window.call("set_auto_move", true)
	window.call("show_dungeon", 2005)
	_check(not bool(window.call("is_auto_move")) and bool(window.get("_auto_art_stale")),
		"showing a floor turns auto-move off with the stale flag (0x6217e0 steps the spinner through 0x60f080)")
	_check(not spinner.visible and String(window.call("floor_text")) == "B1",
		"a one-floor dungeon hides the spinner; a B floor is spelled B1 (got '%s')" % window.call("floor_text"))
	_check(not bool(window.call("show_dungeon", 2099)) and _dungeon_id(window) == 2005,
		"an id with no row shows nothing (the client's \"Illigal Dungeon Map Index\")")
	window.call("show_world")

	# --- the player in a dungeon --------------------------------------------
	# Button 20 twice, as a player would: the first press is taken back by
	# the stale flag the floor left (0x616870).
	window.call("set_auto_move", true)
	_check(not bool(window.call("is_auto_move")), "the first press of 20 after a floor is taken back (0x616870)")
	window.call("set_auto_move", true)
	window.call("update_player_dungeon", 0x8001, Vector3(0, 10, 0), Vector2(0, 1), "TEST_F1", "TEST_ROOM")
	_check(int(window.call("map_mode")) == 2 and _dungeon_id(window) == 2001,
		"auto-move follows the player to its floor: the row of its region id whose label is its floor's text (0x614280)")
	var px: Variant = window.call("player_pixel")
	_check(marker.visible and px is Vector2 and (px as Vector2).is_equal_approx(Vector2(256, 256))
		and marker.position + marker.size / 2.0 == Vector2(256, 256),
		"the arrow is at dungeon (0, 0)'s pixel, (256, 256) (0x60f660; got %s)" % px)
	_check(_caption(window) == "Test Cave - Room A", "the caption names the player's room (got '%s')" % _caption(window))
	_check(not bool(window.call("is_auto_move")), "and auto-move is off now: the floor turned it off")
	window.call("update_player_dungeon", 0x8001, Vector3(1920, 10, 1920), Vector2(0, 1), "TEST_F2", "TEST_ROOM")
	_check(_dungeon_id(window) == 2001 and not marker.visible,
		"with auto-move off the map stays; the player on 2F has no arrow on 1F (0x612920)")
	_check(_caption(window) == "Test Cave", "and the caption names no room (got '%s')" % _caption(window))
	up.pressed.emit()
	_check(_dungeon_id(window) == 2002 and marker.visible
		and (window.call("player_pixel") as Vector2).is_equal_approx(Vector2(512, 0)),
		"on 2F the arrow is at (1920, 1920)'s pixel, (512, 0) (got %s)" % window.call("player_pixel"))
	window.call("show_world")
	px = window.call("player_pixel")
	_check(marker.visible and px is Vector2 and (px as Vector2).is_equal_approx(Vector2(512, 256)),
		"on the world map the arrow is at the dungeon's field point (worldmap_instanceinfo, 0x60fa90; got %s)" % px)
	window.call("update_player", 99, 102, Vector3(960, 0, 960), Vector2(0, 1))
	_check(not bool(window.call("in_dungeon")), "a field update leaves the dungeon")

	window.queue_free()
	await process_frame
