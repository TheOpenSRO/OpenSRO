extends SceneTree

## Round 631 review: a click on a world-map name plate. The plate's own
## gui_input (_on_plate_input -> _show_map -> _build_place_labels) used to
## free() the plates' layer -- the plate's parent -- while the plate was still
## emitting, which Godot reports as "freed or unreferenced while a signal is
## being emitted" and which let the press fall through to the world (a real
## click on the Jangan plate walked the player). Measured here with a press
## pushed through the live viewport and a recorder standing in for World3D's
## _unhandled_input. The fixture is worldmap_window_test.gd's synthetic
## worldmapguide.2dt records and three-row map table (no game data):
##   godot4 --headless --path client --script res://scripts/ui/hud/worldmap_plate_test.gd

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
		# A one-region map's box is its region (the shared fixture leaves
		# the corners zero, which _build_place_labels skips as a placeholder).
		m.coord_lt = Vector2i(0, WorldmapInfoReader.REGION_SPAN)
		m.coord_rb = Vector2i(WorldmapInfoReader.REGION_SPAN, 0)
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


func _find_plate(node: Node, text: String) -> Control:
	if node.name.begins_with("Plate"):
		for c in node.get_children():
			if c is Label and (c as Label).text == text:
				return node as Control
	for c in node.get_children():
		var found := _find_plate(c, text)
		if found != null:
			return found
	return null

func _push(at: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = at
	ev.global_position = at
	root.push_input(ev, true)

func _run() -> void:
	await process_frame
	get_root().size = Vector2i(1152, 648)
	await process_frame
	var recorder_script := GDScript.new()
	recorder_script.source_code = "extends Node\nvar presses := 0\nvar releases := 0\nfunc _unhandled_input(e: InputEvent) -> void:\n\tif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:\n\t\tif e.pressed:\n\t\t\tpresses += 1\n\t\telse:\n\t\t\treleases += 1\n"
	recorder_script.reload()
	var recorder := Node.new()
	recorder.set_script(recorder_script)
	get_root().add_child(recorder)

	var script := load(WORLDMAP_PATH) as GDScript
	var window: Control = script.new(_builder())
	window.set("map_table", _table())
	get_root().add_child(window)
	var built: bool = window.call("build_worldmap")
	_check(built, "the world map builds from the synthetic fixture")
	if not built:
		return
	window.call("centre")
	window.hide()
	window.call("toggle")
	await process_frame
	var shown: Object = window.call("current_map")
	print("    showing map %s" % (shown.get("id") if shown != null else "none"))
	var plate := _find_plate(window, "The Town")
	_check(plate != null, "the world map carries a plate for The Town")
	if plate == null:
		return
	var layer := plate.get_parent()
	var at := plate.get_global_rect().get_center()
	print("    plate at %s" % at)
	_push(at, true)
	_push(at, false)
	# NEGATIVE (fails on dev cfddf39: the layer was freed with the plate
	# inside it while the plate was emitting).
	_check(is_instance_valid(plate), "the clicked plate is not freed inside its own gui_input")
	_check(is_instance_valid(layer) and layer.is_queued_for_deletion() and not layer.is_inside_tree(),
		"its PlaceLabels layer leaves the map and is deleted at the end of the frame")
	# World3D walks on a left release that reaches _unhandled_input.
	_check(int(recorder.get("presses")) == 0 and int(recorder.get("releases")) == 0,
		"neither half of the click falls through to the world (%d press(es), %d release(s) reached _unhandled_input)" % [int(recorder.get("presses")), int(recorder.get("releases"))])
	var cur: Object = window.call("current_map")
	_check(cur != null and cur.get("id") == 1, "the plate shows The Town's map")
	await process_frame
	_check(not is_instance_valid(layer), "the old layer is gone a frame later")
