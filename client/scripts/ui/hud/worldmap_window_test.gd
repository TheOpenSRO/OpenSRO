extends SceneTree

## The world map M opens: `CNIFWorldMap`, built from `res_ui\worldmapguide.2dt`
## (HudWorldmap; docs/RE_COMPLETION.md has the round). The fixture is
## synthetic records -- ids, parents, types, rects and class names copied from
## the real file's structure, no art and no text (docs/LEGAL.md) -- and a
## synthetic map table of three rows, run through the real reader and builder:
##   godot4 --headless --path client --script res://scripts/ui/hud/worldmap_window_test.gd
##
## Every script this checks is reached through load(), call() or get(), so a
## tree that builds the older CIFWorldMap window FAILS here instead of failing
## to compile.

const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"
const WORLDMAP_PATH := "res://scripts/ui/hud/hud_worldmap.gd"
const READER_PATH := "res://scripts/ui/twodt_reader.gd"
const RECORD := 0x3d0
const AUTO_DDJ := "interface\\worldmap\\wmap_button_automatic.ddj"
const MANUAL_DDJ := "interface\\worldmap\\wmap_button_passivity.ddj"
const WORLD_DDJ := "interface\\worldmap\\wmap_big_button_world.ddj"
const SIZE_DDJ := "interface\\worldmap\\wmap_button_windowsize.ddj"
const CLOSE := "interface\\ifcommon\\com_windowclose.ddj"
const EDGES := ["interface\\worldmap\\wmap_window_edge_1.ddj", "interface\\worldmap\\wmap_window_edge_2.ddj",
	"interface\\worldmap\\wmap_window_edge_3.ddj", "interface\\worldmap\\wmap_window_edge_4.ddj"]

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

# --- synthetic records --------------------------------------------------------

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

## worldmapguide.2dt's 18 records in file order.
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
		{"type": 4, "id": 7, "parent": 28, "rect": Rect2i(1102, 125, 16, 16), "tex": SIZE_DDJ},
		{"type": 18, "id": 4, "name": "CNIFVerticalSpinButtonCtrl", "parent": 28, "rect": Rect2i(1107, 204, 29, 47)},
		{"type": 4, "id": 22, "parent": 4, "gp": 28, "rect": Rect2i(1108, 205, 28, 12), "tex": "interface\\worldmap\\wmap_up_button.ddj"},
		{"type": 4, "id": 24, "parent": 4, "gp": 28, "rect": Rect2i(1108, 238, 28, 12), "tex": "interface\\worldmap\\wmap_down_button.ddj"},
		{"type": 5, "id": 27, "parent": 4, "gp": 28, "rect": Rect2i(1111, 221, 23, 17)},
	]

## Three maps: an 8x4-tile world over regions y 100..107 / x 101..98, a local
## map on region (98, 101), and a fortress map (id 1001) on region (99, 104).
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
	return table

func _text_table() -> UiTextTable:
	var rows := PackedStringArray()
	for pair in [["UIIT_PAG_WORLDMAP", "World map (tip)"], ["UIIT_PAG_LOCALMAP", "Local map"],
			["UIIT_STT_WORLDMAP_AUTO_MOVE", "Auto (tip)"], ["UIIT_STT_WORLDMAP_MANUAL_MOVE", "Manual (tip)"],
			["TEST_WORLD", "The World"], ["TEST_TOWN", "The Town"], ["TEST_FORT", "The Fort"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

func _tex(builder: UiBuilder, path: String, size: Vector2i) -> void:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.4, 0.3, 0.2, 1.0))
	(builder.get("_texture_cache") as Dictionary)[path.to_lower()] = ImageTexture.create_from_image(img)

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, _text_table())
	var Reader = load(READER_PATH)
	var cache = builder.get("_twodt_cache")
	if Reader != null and cache is Dictionary:
		cache["res_ui\\worldmapguide.2dt"] = Reader.parse(_file(_worldmap()))
	for p in [AUTO_DDJ, MANUAL_DDJ, WORLD_DDJ]:
		_tex(builder, p, Vector2i(36, 36))
	for p in [SIZE_DDJ, CLOSE]:
		_tex(builder, p, Vector2i(16, 16))
	for p in EDGES:
		_tex(builder, p, Vector2i(4, 4))
	return builder

# --- helpers -----------------------------------------------------------------

func _at(root: Node, id: int) -> Control:
	if root == null:
		return null
	for c in root.get_children():
		if c.has_meta("twodt_id") and int(c.get_meta("twodt_id")) == id:
			return c
	return null

func _rect(window: Control, node: Control) -> Rect2:
	if node == null:
		return Rect2(-1, -1, -1, -1)
	return Rect2(node.get_global_rect().position - window.get_global_rect().position, node.size)

func _art(node: Control) -> String:
	var b := node as TextureButton
	if b == null or b.texture_normal == null:
		return "<none>"
	return b.texture_normal.resource_name

func _caption(window: Control) -> String:
	var bar := window.get_node_or_null("TitleBar") as Label
	return bar.text if bar != null else "<no caption>"

# --- the checks --------------------------------------------------------------

func _run() -> void:
	await process_frame
	get_root().size = Vector2i(1152, 648)
	await process_frame
	var builder := _builder()
	# Name the fake textures so a check can say which one a button shows.
	var tc: Dictionary = builder.get("_texture_cache")
	for k in tc:
		(tc[k] as Texture2D).resource_name = k

	# --- M ---------------------------------------------------------------
	var panels_script := load(PANELS_PATH) as GDScript
	var panels: Control = panels_script.new(builder)
	get_root().add_child(panels)
	await process_frame
	var asked := [0]
	if panels.has_signal("world_map_toggle_requested"):
		panels.connect("world_map_toggle_requested", func() -> void: asked[0] += 1)
	var ev := InputEventKey.new()
	ev.keycode = KEY_M
	ev.pressed = true
	panels.call("_unhandled_key_input", ev)
	_check(asked[0] == 1, "M asks for the world map (HudPanels.world_map_toggle_requested; got %d)" % asked[0])

	# --- the window as built -------------------------------------------------
	var script := load(WORLDMAP_PATH) as GDScript
	var window: Control = script.new(builder)
	window.set("map_table", _table())
	get_root().add_child(window)
	var built: bool = window.call("build_worldmap")
	_check(built, "the world map builds from res_ui\\worldmapguide.2dt and the map table")
	if not built:
		return
	# World3D builds it, centres it and hides it, as the client loads it at
	# game start and hides it at once (0x777a70).
	window.call("centre")
	window.hide()
	await process_frame
	var root: Control = window.get("panel_root")
	_check(root != null and str(root.get_meta("twodt_class", "")) == "CNIFWorldMap",
		"its root is the file's CNIFWorldMap record")
	_check(window.size == Vector2(650, 422), "it is 650x422 (got %s)" % window.size)

	# M from hidden: shown and centred (0x79abe0 -> 0x46d740, 0x798c50).
	window.call("toggle")
	await process_frame
	_check(window.visible, "the toggle shows it")
	_check(window.position == Vector2(251, 113),
		"centred on the 1152x648 view at (251, 113) (got %s)" % window.position)

	var area: Rect2 = window.call("map_area")
	_check(area == Rect2(6, 34, 640, 384), "the map area is (6, 34) 640x384 (got %s)" % area)
	var vp := window.find_child("MapViewport", true, false) as Control
	_check(vp != null and vp.clip_contents and _rect(window, vp) == Rect2(6, 34, 640, 384),
		"the map is clipped to that area (got %s)" % (_rect(window, vp) if vp else null))
	var edge_rects := []
	var edge_art := []
	for i in 4:
		var e := window.find_child("MapEdge%d" % (i + 1), true, false) as TextureRect
		edge_rects.append(_rect(window, e) if e != null else null)
		edge_art.append(e.texture.resource_name if e != null and e.texture != null else "")
	_check(edge_rects == [Rect2(6, 34, 4, 4), Rect2(642, 34, 4, 4), Rect2(642, 414, 4, 4), Rect2(6, 414, 4, 4)],
		"the four 4x4 corner pieces sit at the area's corners (got %s)" % [edge_rects])
	_check(edge_art == [EDGES[0], EDGES[1], EDGES[3], EDGES[2]],
		"top-left edge_1, top-right edge_2, bottom-right edge_4, bottom-left edge_3 (got %s)" % [edge_art])

	# The buttons where the file puts them.
	_check(_rect(window, _at(root, 7)) == Rect2(606, 10, 16, 16), "the size button is at (606, 10) (got %s)" % _rect(window, _at(root, 7)))
	_check(_rect(window, _at(root, 20)) == Rect2(605, 39, 36, 36), "the auto-move button is at (605, 39) (got %s)" % _rect(window, _at(root, 20)))
	_check(_rect(window, _at(root, 6)) == Rect2(567, 39, 36, 36), "the world button is at (567, 39) (got %s)" % _rect(window, _at(root, 6)))

	# The state the OnCreates and game entry leave (0x620f70, 0x616b80(1)).
	_check(not _at(root, 4).visible, "the floor spinner is hidden")
	_check(not _at(root, 11).visible, "the guide is hidden")
	var check := _at(root, 31) as BaseButton
	_check(check != null and not check.button_pressed, "the level check box is unchecked")
	_check(_at(root, 26).mouse_filter == Control.MOUSE_FILTER_STOP and _at(root, 13).mouse_filter == Control.MOUSE_FILTER_STOP,
		"the bottom frame and the side tab take the click (+0x1c0)")
	var auto_btn := _at(root, 20)
	_check(auto_btn.visible and _art(auto_btn) == AUTO_DDJ and auto_btn.tooltip_text == "Auto (tip)",
		"auto-move is on: button 20 shows wmap_button_automatic with UIIT_STT_WORLDMAP_AUTO_MOVE (got %s, '%s')" % [_art(auto_btn), auto_btn.tooltip_text])
	_check(bool(window.call("is_auto_move")), "auto-move is on")
	_check(_at(root, 6).tooltip_text == "World map (tip)", "the world button carries UIIT_PAG_WORLDMAP")
	var zero := []
	for id in [26, 31, 13, 15]:
		zero.append(_at(root, id).size)
	_check(zero == [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO],
		"the four 0x0 records are built 0x0 (got %s)" % [zero])
	# ShowWindow(1) closes the guide: the tab and button move off their
	# authored spots (0x616ba0(0)).
	_check(_rect(window, _at(root, 13)).position == Vector2(-19, 0) and _rect(window, _at(root, 15)).position == Vector2(-15, 96),
		"the side tab is at (-19, 0) and its button at (-15, 96) (got %s, %s)" % [_rect(window, _at(root, 13)).position, _rect(window, _at(root, 15)).position])

	# CNIFMainFrame's chrome.
	var bar := window.get_node_or_null("TitleBar") as Control
	# (A Label's height is its font's; the caption's width and place are the chrome's.)
	_check(bar != null and bar.position == Vector2(10, 12) and bar.size.x == 629,
		"the caption is at (10, 12), 629 wide (got %s)" % (_rect(window, bar) if bar else null))
	var close := window.get_node_or_null("CloseButton") as Control
	_check(close != null and _rect(window, close) == Rect2(624, 10, 16, 16), "the close button is (624, 10) (got %s)" % (_rect(window, close) if close else null))

	# The world map: its name alone, and no world button.
	_check(_caption(window) == "The World", "the world map is captioned with its name (got '%s')" % _caption(window))
	_check(not _at(root, 6).visible, "the world button is hidden on the world map")

	# --- auto-move follows the player ---------------------------------------
	window.call("update_player", 98, 101, Vector3(960, 0, 960))
	var cur: Object = window.call("current_map")
	_check(cur != null and cur.get("id") == 1, "auto-move puts a player on region (98, 101) on that town's map")
	_check(_caption(window) == "Local map - The Town", "a local map is captioned UIIT_PAG_LOCALMAP - name (got '%s')" % _caption(window))
	_check(_at(root, 6).visible, "the world button shows on a local map")

	# The world button: auto-move off, the stale flag set, the world map.
	(_at(root, 6) as BaseButton).pressed.emit()
	cur = window.call("current_map")
	_check(cur != null and cur.get("id") == 0, "the world button shows the world map")
	_check(not bool(window.call("is_auto_move")), "and turns auto-move off")
	_check(_art(auto_btn) == AUTO_DDJ, "button 20 keeps its automatic look until pressed")
	(auto_btn as BaseButton).pressed.emit()
	_check(not bool(window.call("is_auto_move")) and _art(auto_btn) == MANUAL_DDJ and auto_btn.tooltip_text == "Manual (tip)",
		"pressed after that, it settles on manual (got auto=%s, %s)" % [window.call("is_auto_move"), _art(auto_btn)])
	window.call("update_player", 98, 101, Vector3(960, 0, 960))
	cur = window.call("current_map")
	_check(cur != null and cur.get("id") == 0, "in manual the map does not follow the player")
	(auto_btn as BaseButton).pressed.emit()
	_check(bool(window.call("is_auto_move")) and _art(auto_btn) == AUTO_DDJ, "pressed again, auto-move is back on")
	window.call("update_player", 99, 104, Vector3(960, 0, 960))
	cur = window.call("current_map")
	_check(cur != null and cur.get("id") == 1001 and not _at(root, 6).visible,
		"a fortress map hides the world button")

	# --- the size button ---------------------------------------------------
	(_at(root, 7) as BaseButton).pressed.emit()
	_check(window.size == Vector2(268, 296), "the size button makes it 268x296 (got %s)" % window.size)
	_check(window.call("map_area") == Rect2(6, 34, 256, 256), "with a 256x256 map area (got %s)" % window.call("map_area"))
	var small := [_rect(window, _at(root, 7)).position, _rect(window, _at(root, 6)).position,
		_rect(window, _at(root, 20)).position, _rect(window, _at(root, 4)).position]
	_check(small == [Vector2(224, 10), Vector2(185, 39), Vector2(224, 39), Vector2(229, 89)],
		"and the buttons at (224,10) (185,39) (224,39) (229,89) (got %s)" % [small])
	_check(not _at(root, 31).visible and not _at(root, 30).visible and not _at(root, 26).visible,
		"the check box, the level label and the bottom frame hidden")
	_check(bar != null and bar.position == Vector2(10, 12) and bar.size.x == 247 and _rect(window, close) == Rect2(242, 10, 16, 16),
		"the caption and close re-laid for 268 (got %s, %s)" % [_rect(window, bar), _rect(window, close)])
	(_at(root, 7) as BaseButton).pressed.emit()
	_check(window.size == Vector2(650, 422) and window.call("map_area") == Rect2(6, 34, 640, 384)
			and _at(root, 31).visible and _rect(window, _at(root, 6)).position == Vector2(567, 39),
		"pressed again, the big size is back")

	# --- M again hides it; kept on screen at a small view --------------------
	window.call("toggle")
	_check(not window.visible, "the toggle hides it again")
	get_root().size = Vector2i(768, 432)
	await process_frame
	window.call("toggle")
	_check(window.position == Vector2(59, 5), "at 768x432 it is centred at (59, 5) (got %s)" % window.position)

	# --- Escape (0x78b6c7 -> 0x79d620) ---------------------------------------
	# A stand-in System window, so this runs without the archive's layout.
	var system := HudWindow.new()
	system.name = "Window_system"
	panels.add_child(system)
	var windows = panels.get("_windows")
	if windows is Dictionary:
		(windows as Dictionary)["system"] = system
	system.hide()
	panels.set("world_map", window)
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	_check(window.visible, "the map is open before Escape")
	panels.call("_unhandled_key_input", esc)
	_check(not window.visible, "Escape closes the world map (0x79d785..0x79d7c2)")
	_check(not system.visible, "and does not raise the System menu while the map was open")
	# The System window comes first in 0x79d620's list, then the map.
	window.call("toggle")
	system.show()
	panels.call("_unhandled_key_input", esc)
	_check(not system.visible and window.visible, "with both open, Escape closes the System window first (0x79d657)")
	panels.call("_unhandled_key_input", esc)
	_check(not window.visible, "and the next Escape the world map")
	window.queue_free()
	panels.queue_free()
