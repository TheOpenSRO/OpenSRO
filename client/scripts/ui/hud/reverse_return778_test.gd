extends SceneTree

## Round 778: the reverse return scroll's client half -- the table reader
## (OptionalTeleportReader), the message box (ReverseReturnBox, kind 0x21),
## the world map's selection mode (HudWorldmap.enter_select_mode: the icons,
## their blink, hover and pick, the popup and its floors), the use's wire
## form (UseItemNet) and the refusal lines (ErrorText.scroll_line). Synthetic
## records, rows and text only -- no art, no game text (docs/LEGAL.md):
##   godot4 --headless --path client --script res://scripts/ui/hud/reverse_return778_test.gd

const ErrorText = preload("res://scripts/net/error_text.gd")
const WORLDMAP_PATH := "res://scripts/ui/hud/hud_worldmap.gd"
const READER_PATH := "res://scripts/ui/twodt_reader.gd"
const RECORD := 0x3d0
const ICON := "interface\\worldmap\\map\\xy_returnicon.ddj"
const ICON_FOCUS := "interface\\worldmap\\map\\xy_returnicon_focus.ddj"
const ICON_PRESS := "interface\\worldmap\\map\\xy_returnicon_press.ddj"
const POPUP_BTN := "interface\\worldmap\\map\\map_return.ddj"

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

# --- fixtures ----------------------------------------------------------------

## A refoptionalteleport-shaped table (19 fields, UTF-16LE with its BOM): a
## service-0 row, a lone town point in region (100, 102), a group flag in
## (99, 104) with one floor under it in a dungeon, a second flag whose group
## has nothing under it, and a point off the fixture's world map.
func _table_bytes() -> PackedByteArray:
	var rows := PackedStringArray([
		"0\t1\tx\tTEST_SKIPPED\t25702\t1\t0\t1\t1\t-1\t1\t0\t0\t-1\txxx\t-1\txxx\t-1\txxx",
		"1\t1\tx\tTEST_TOWN_POINT\t25702\t960\t0\t960\t1\t-1\t1\t0\t0\t-1\txxx\t-1\txxx\t-1\txxx",
		"1\t29\tx\txxx\t25448\t480\t452\t1440\t1\t1\t1\t0\t0\t-1\txxx\t-1\txxx\t-1\txxx",
		"1\t30\tx\tTEST_CAVE_1F\t-32767\t1115\t0\t-935\t1\t1\t0\t50\t999\t-1\txxx\t-1\txxx\t-1\txxx",
		"1\t31\tx\txxx\t25446\t960\t0\t960\t1\t2\t1\t0\t0\t-1\txxx\t-1\txxx\t-1\txxx",
		"1\t40\tx\tTEST_FAR\t9999\t960\t0\t960\t1\t-1\t1\t90\t999\t-1\txxx\t-1\txxx\t-1\txxx",
		"//Copyright test",
	])
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(("\r\n".join(rows)).to_utf16_buffer())
	return out

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

## worldmap_dungeon_test.gd's synthetic window records.
func _worldmap() -> Array:
	return [
		{"type": 0, "id": 28, "name": "CNIFWorldMap", "root": true, "rect": Rect2i(496, 115, 650, 422), "base": "interface\\frame\\mframe_wnd_"},
		{"type": 4, "id": 6, "parent": 28, "rect": Rect2i(1063, 154, 36, 36), "tex": "interface\\worldmap\\wmap_big_button_world.ddj"},
		{"type": 4, "id": 20, "parent": 28, "rect": Rect2i(1101, 154, 36, 36), "tex": "interface\\worldmap\\wmap_button_passivity.ddj"},
		{"type": 4, "id": 7, "parent": 28, "rect": Rect2i(1102, 125, 16, 16), "tex": "interface\\worldmap\\wmap_button_windowsize.ddj"},
		{"type": 18, "id": 4, "name": "CNIFVerticalSpinButtonCtrl", "parent": 28, "rect": Rect2i(1107, 204, 29, 47)},
		{"type": 4, "id": 22, "parent": 4, "gp": 28, "rect": Rect2i(1108, 205, 28, 12), "tex": "interface\\worldmap\\wmap_up_button.ddj"},
		{"type": 4, "id": 24, "parent": 4, "gp": 28, "rect": Rect2i(1108, 238, 28, 12), "tex": "interface\\worldmap\\wmap_down_button.ddj"},
		{"type": 5, "id": 27, "parent": 4, "gp": 28, "rect": Rect2i(1111, 221, 23, 17)},
	]

## The world map of worldmap_dungeon_test.gd: regions y 100..107, x 101..98,
## drawn 1024x512.
func _map_table() -> Object:
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
	return table

func _text_table() -> UiTextTable:
	var rows := PackedStringArray()
	for pair in [
			["UIIT_STT_CONFIRM_BOX", "Test confirm"],
			["UIIT_MSG_QUESTION_SILKMALL_ITEM_USE_REVERSE_PORTAL", "Test question"],
			["UIIT_MSG_ITEM_USE_REVERSE_PORTAL_RETRUN_TO_LAST_RETURN", "Test recall"],
			["UIIT_MSG_ITEM_USE_REVERSE_PORTAL_RETRUN_TO_LAST_DEATH", "Test death"],
			["UIIT_CLT_REVERSE_RETRUN_SCROLL_TO_APPOINT_CHANGE", "Test map"],
			["UIO_COMMON_CTL_CANCEL", "Test cancel"],
			["UIIT_MSG_STRGERR_CANT_FIND_LAST_DIEDPOS", "Test no death point"],
			["TEST_WORLD", "The World"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

func _zone_table() -> UiTextTable:
	var rows := PackedStringArray()
	for pair in [["TEST_TOWN_POINT", "Test Town"], ["TEST_CAVE_1F", "Test Cave 1F"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

func _tex(builder: UiBuilder, path: String, size: Vector2i, color: Color = Color(0.4, 0.3, 0.2, 1.0)) -> Texture2D:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(color)
	var tex := ImageTexture.create_from_image(img)
	tex.resource_name = path.to_lower()
	(builder.get("_texture_cache") as Dictionary)[path.to_lower()] = tex
	return tex

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, _text_table())
	var Reader = load(READER_PATH)
	var cache = builder.get("_twodt_cache")
	if Reader != null and cache is Dictionary:
		cache["res_ui\\worldmapguide.2dt"] = Reader.parse(_file(_worldmap()))
	_tex(builder, ICON, Vector2i(64, 32))
	_tex(builder, ICON_FOCUS, Vector2i(32, 32))
	_tex(builder, ICON_PRESS, Vector2i(32, 32))
	_tex(builder, POPUP_BTN, Vector2i(155, 22))
	return builder

func _reader() -> OptionalTeleportReader:
	var r := OptionalTeleportReader.new()
	r.parse(_table_bytes())
	return r

func _at(root: Node, id: int) -> Control:
	if root == null:
		return null
	for c in root.get_children():
		if c.has_meta("twodt_id") and int(c.get_meta("twodt_id")) == id:
			return c
	return null

# --- the checks --------------------------------------------------------------

func _run() -> void:
	await process_frame
	get_root().size = Vector2i(1152, 648)
	await process_frame
	_check_reader()
	_check_wire()
	await _check_box()
	await _check_select_mode()

func _check_reader() -> void:
	var r := _reader()
	_check(r.size() == 5, "five serviced rows read, the service-0 row skipped (got %d)" % r.size())
	var town := r.point(1)
	_check(town != null and town.zone_strid == "TEST_TOWN_POINT" and town.region_x() == 100 and town.region_y() == 102
		and town.x == 960.0 and town.group == OptionalTeleportReader.NO_GROUP and town.map_point,
		"row 1: its key, region (100, 102), x, no group, a map point")
	_check(r.map_points().size() == 4, "four map points (rows 1, 29, 31, 40)")
	var cave := r.point(30)
	_check(cave != null and cave.in_dungeon() and not cave.map_point and cave.level_min == 50,
		"the floor row: a dungeon region, no icon of its own, level 50..")
	var flag := r.point(29)
	var under := r.choices_for(flag)
	_check(under.size() == 1 and (under[0] as OptionalTeleportReader.Point).id == 30,
		"the flag lists its group's floor (0x6236e2..0x623761)")
	_check(r.choices_for(town).size() == 1 and r.choices_for(town)[0] == town, "a lone point lists itself")
	_check(r.choices_for(r.point(31)).is_empty(), "a group with nothing under its flag lists nothing")

func _check_wire() -> void:
	var plain := UseItemNet.encode_use("Aria", 9)
	_check(plain.size() == 2 + 4 + 8, "a plain use is name + slot (got %d bytes)" % plain.size())
	var two := UseItemNet.encode_use("Aria", 9, UseItemNet.OPTION_RECALL)
	_check(two.size() == plain.size() + 1 and two[two.size() - 1] == 2, "option 2 adds its byte")
	var seven := UseItemNet.encode_use("Aria", 9, UseItemNet.OPTION_MAP, 30)
	_check(seven.size() == plain.size() + 5 and seven[plain.size()] == 7 and seven.decode_u32(plain.size() + 1) == 30,
		"option 7 adds its byte and the u32 id")
	var reply := PackedByteArray()
	reply.resize(2)
	reply.encode_u16(0, 0)
	var body := PackedByteArray()
	body.resize(28 + 6 + 6)
	body.encode_s32(24, 4)
	body.encode_u16(34, 0x1886)
	body.encode_u32(36, 1000)
	reply.append_array(body)
	var res := UseItemNet.decode_result(reply)
	_check(res.remaining == 4 and res.code == 0x1886 and res.cast_ms == 1000, "the code and cast tail decode")
	var table := _text_table()
	_check(ErrorText.scroll_line(0x1886, table, "fallback") == "Test no death point",
		"0x1886 is category 1's UIIT_MSG_STRGERR_CANT_FIND_LAST_DIEDPOS")
	_check(ErrorText.scroll_line(2, table, "server words") == "server words", "2 keeps the server's words")

func _check_box() -> void:
	var builder := _builder()
	var box := ReverseReturnBox.new()
	_check(box.build(builder, 12), "the box builds without an archive")
	get_root().add_child(box)
	await process_frame
	_check(box.size == Vector2(300, 204), "300 x 204 (0x647e60)")
	var expect := {"LastReturn": [76, "Test recall"], "LastDeath": [107, "Test death"],
		"MapPoint": [138, "Test map"], "Cancel": [169, "Test cancel"]}
	for m in expect:
		var b := box.member(m)
		_check(b != null and b.position == Vector2(25, expect[m][0]) and b.size == Vector2(252, 24),
			"%s at (25, %d), 252 x 24 (got %s)" % [m, expect[m][0], Rect2(b.position, b.size) if b else null])
		_check(box.caption_of(m) == expect[m][1], "%s says '%s' (got '%s')" % [m, expect[m][1], box.caption_of(m)])
	var got := []
	box.option_chosen.connect(func(o: int) -> void: got.append(o))
	box.map_requested.connect(func() -> void: got.append("map"))
	box.member("MapPoint").emit_signal("pressed")
	_check(got == ["map"] and box.visible, "the map button asks for the map and keeps the box (0x63b9a0 hides it)")
	box.member("LastDeath").emit_signal("pressed")
	_check(got == ["map", 3], "the death button sends option 3 (0x7988aa)")
	_check(not box.visible, "and the box closes")
	var box2 := ReverseReturnBox.new()
	box2.build(builder, 12)
	get_root().add_child(box2)
	var got2 := []
	box2.option_chosen.connect(func(o: int) -> void: got2.append(o))
	box2.cancelled.connect(func() -> void: got2.append("cancel"))
	box2.member("LastReturn").emit_signal("pressed")
	_check(got2 == [2], "the recall button sends option 2 (0x798883)")
	var box3 := ReverseReturnBox.new()
	box3.build(builder, 12)
	get_root().add_child(box3)
	var got3 := []
	box3.option_chosen.connect(func(o: int) -> void: got3.append(o))
	box3.cancelled.connect(func() -> void: got3.append("cancel"))
	box3.member("Cancel").emit_signal("pressed")
	_check(got3 == ["cancel"], "cancel sends nothing")
	await process_frame

func _check_select_mode() -> void:
	var builder := _builder()
	var script := load(WORLDMAP_PATH) as GDScript
	var window: Control = script.new(builder)
	window.set("map_table", _map_table())
	window.set("local_table", WorldmapLocalInfoReader.Table.new())
	window.set("text_tables", [_zone_table()])
	get_root().add_child(window)
	if not bool(window.call("build_worldmap")):
		_check(false, "the world map builds")
		return
	window.call("open")
	await process_frame
	var reader := _reader()
	window.set("optional_reader", reader)
	window.call("enter_select_mode")
	await process_frame
	var root: Control = window.get("panel_root")
	_check(bool(window.call("in_select_mode")), "the selection mode is on (+0x9990)")
	for id in [7, 6, 4, 20]:
		var c := _at(root, id)
		_check(c == null or not c.visible, "control %d is hidden (0x622dd0)" % id)
	var icons: Array = window.call("select_icons")
	_check(icons.size() == 3, "three icons on this map: 1, 29 and 31 -- 40 lies off it (got %d)" % icons.size())
	# The icon's centre is the player marker's transform (0x61e270).
	window.call("update_player", 100, 102, Vector3(960, 0, 960))
	var marker: Variant = window.call("player_pixel")
	var town_icon: TextureRect = null
	for pair in icons:
		if (pair[0] as OptionalTeleportReader.Point).id == 1:
			town_icon = pair[1]
	_check(town_icon != null and marker != null and town_icon.position == (marker as Vector2) - Vector2(16.5, 16.5)
		and town_icon.size == Vector2(32, 32),
		"the town's icon is 32 x 32 about the marker's pixel, less 0.5 (got %s, marker %s)" % [
			Rect2(town_icon.position, town_icon.size) if town_icon else null, marker])
	var first := town_icon.texture as AtlasTexture
	_check(first != null and first.region == Rect2(0, 0, 32, 32), "the plain icon draws its left half first (+0x98c4)")
	window.call("_select_blink")
	var second := town_icon.texture as AtlasTexture
	_check(second != null and second.region == Rect2(32, 0, 32, 32), "timer 0xd swaps to the right half (+0x9924)")
	# Hover, then pick the cave's flag.
	var flag_icon: TextureRect = null
	for pair in icons:
		if (pair[0] as OptionalTeleportReader.Point).id == 29:
			flag_icon = pair[1]
	var centre := flag_icon.position + flag_icon.size / 2.0
	window.call("_select_hover", centre)
	_check(flag_icon.texture != null and flag_icon.texture.resource_name == ICON_FOCUS.to_lower(),
		"under the mouse it takes its _focus art (+0x38)")
	var canvas := window.find_child("MapCanvas", true, false) as Control
	for down in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = down
		ev.position = canvas.position + centre
		window.call("_on_viewport_input", ev)
	_check(flag_icon.texture.resource_name == ICON_PRESS.to_lower(), "picked, its _press art (+0x3c)")
	var buttons: Array = window.call("select_popup_buttons")
	_check(buttons.size() == 1, "the popup lists the group's one floor (got %d)" % buttons.size())
	if buttons.size() == 1:
		var b := buttons[0] as BaseButton
		var label := b.get_node("ButtonLabel") as Label
		_check(label.text == "Test Cave 1F", "captioned with the floor's zone name (got '%s')" % label.text)
		_check(b.position == Vector2(0, 1) and b.size == Vector2(155, 22), "155 x 22 at y 1 (0x631d60)")
		var popup := b.get_parent() as Control
		var viewport := window.find_child("MapViewport", true, false) as Control
		var corner := viewport.position + canvas.position + flag_icon.position + Vector2(0, 32)
		_check(popup.position == Vector2(floorf(corner.x), floorf(corner.y)),
			"the popup's corner is the icon's lower-left vertex (+0xa8/+0xac)")
		var chosen := []
		window.connect("select_point_chosen", func(id: int) -> void: chosen.append(id))
		b.emit_signal("pressed")
		_check(chosen == [30], "the floor's button chooses row 30 (0x60f5f0)")
		_check(not window.visible and not bool(window.call("in_select_mode")), "and the window hides, leaving the mode")
		var auto_btn := _at(root, 20)
		_check(auto_btn == null or auto_btn.visible, "the auto button is back (0x622dd0(0))")
	# Hidden while selecting: the box goes, nothing is chosen.
	window.call("open")
	window.call("enter_select_mode")
	var cancelled := []
	window.connect("select_cancelled", func() -> void: cancelled.append(true))
	window.hide()
	_check(cancelled == [true] and not bool(window.call("in_select_mode")),
		"hiding the map while selecting cancels (vslot_023 -> FUN_006ec860)")
	# A release off every icon hides the popup.
	window.call("open")
	window.call("enter_select_mode")
	window.call("qa_pick", 1)
	_check((window.call("select_popup_buttons") as Array).size() == 1, "a lone point's popup lists itself")
	for down in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = down
		ev.position = Vector2(1, 1)
		window.call("_on_viewport_input", ev)
	_check((window.call("select_popup_buttons") as Array).is_empty(), "a click elsewhere hides the popup")
