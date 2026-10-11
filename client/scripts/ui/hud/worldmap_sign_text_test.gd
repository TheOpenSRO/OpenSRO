extends SceneTree

## Round 776: how the world map draws its text signs (HudWorldmap._sign_label,
## SignText; the RE is in their doc comments and docs/protocol/WORLDMAP_FORMAT.md,
## "The text signs"). The window is built from synthetic records with the real
## worldmapguide.2dt's ids and rects (as worldmap_dungeon_test.gd), a synthetic
## world map, synthetic signs and a synthetic text table -- no art, no game
## text (docs/LEGAL.md):
##   godot4 --headless --path client --script res://scripts/ui/hud/worldmap_sign_text_test.gd
##
## It checks the draw order (0x61c360: every picture, then every text), the
## text flags (0x6210b0: Bold -> flag 2, Blur -> flag 1, the Shadow byte
## overridden), the colour, the font index, the width (0x8b3910: the
## advances' sum) and the placement (`x - width / 2`, top at `y`).

const WORLDMAP_PATH := "res://scripts/ui/hud/hud_worldmap.gd"
const READER_PATH := "res://scripts/ui/twodt_reader.gd"
const RECORD := 0x3d0
const TOWN_DDJ := "interface\\worldmap\\map\\test_town.ddj"

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
		{"type": 4, "id": 6, "parent": 28, "rect": Rect2i(1063, 154, 36, 36)},
		{"type": 4, "id": 20, "parent": 28, "rect": Rect2i(1101, 154, 36, 36)},
		{"type": 1, "id": 11, "name": "CNIFWorldMapGuide", "parent": 28, "rect": Rect2i(198, 115, 298, 296), "base": "interface\\inventory\\int_window_"},
		{"type": 4, "id": 7, "parent": 28, "rect": Rect2i(1102, 125, 16, 16)},
		{"type": 18, "id": 4, "name": "CNIFVerticalSpinButtonCtrl", "parent": 28, "rect": Rect2i(1107, 204, 29, 47)},
		{"type": 4, "id": 22, "parent": 4, "gp": 28, "rect": Rect2i(1108, 205, 28, 12)},
		{"type": 4, "id": 24, "parent": 4, "gp": 28, "rect": Rect2i(1108, 238, 28, 12)},
		{"type": 5, "id": 27, "parent": 4, "gp": 28, "rect": Rect2i(1111, 221, 23, 17)},
	]

## A world map of regions y 100..107, x 101..98, 1024x512 (as
## worldmap_dungeon_test.gd's).
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
	return table

## A sign; `style` is the Shadow, Bold and Blur bytes, `rgb` the colour.
func _sign(id: int, type: int, text: String, link: int, ra: int, rb: int, pos: Vector2i, size: Vector2i,
		rgb: Color = Color.WHITE, style: Array = [0, 0, 0]) -> Object:
	var s := WorldmapLocalInfoReader.Sign.new()
	s.id = id
	s.type = type
	s.text = text
	s.link = link
	s.parent = 0
	s.region_a = ra
	s.region_b = rb
	s.pos = pos
	s.size = size
	s.color = rgb
	s.shadow = style[0]
	s.bold = style[1]
	s.blur = style[2]
	return s

## As the archive lists Jangan (MEASURED, round 776): the town's name, a bold
## shadowed text, BEFORE the town's icon it is drawn over; then a white
## shadowed name, a shadow byte with Blur 0, a bold name in font 2, and the
## two decorated texts.
func _signs() -> Object:
	var t := WorldmapLocalInfoReader.Table.new()
	t.signs.append(_sign(1, 1, "TEST_TOWN_NAME", 0, 101, 100, Vector2i(15, 26), Vector2i(0, 0),
		Color8(255, 247, 182), [0, 1, 1]))
	t.signs.append(_sign(2, 2, TOWN_DDJ, 1, 101, 100, Vector2i(0, 0), Vector2i(32, 32)))
	t.signs.append(_sign(3, 1, "TEST_FIELD", 0, 103, 100, Vector2i(9, 3), Vector2i(0, 0),
		Color.WHITE, [0, 0, 1]))
	t.signs.append(_sign(4, 1, "TEST_FIELD", 0, 104, 99, Vector2i(10, 10), Vector2i(0, 0),
		Color.WHITE, [1, 0, 0]))
	t.signs.append(_sign(5, 1, "TEST_FIELD", 0, 105, 99, Vector2i(10, 10), Vector2i(0, 2),
		Color8(217, 240, 152), [0, 1, 1]))
	t.signs.append(_sign(6, 1, "TEST_FIELD", 1, 102, 99, Vector2i(10, 10), Vector2i(0, 0)))
	t.signs.append(_sign(7, 1, "TEST_FIELD", 2, 102, 98, Vector2i(10, 10), Vector2i(0, 0)))
	t.signs.append(_sign(8, 1, "TEST_MISSING", 0, 102, 98, Vector2i(10, 10), Vector2i(0, 0)))
	return t

func _text_table() -> UiTextTable:
	var rows := PackedStringArray()
	for pair in [["TEST_WORLD", "The World"], ["TEST_TOWN_NAME", "Townname"], ["TEST_FIELD", "Wide Field Name"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, _text_table())
	var Reader = load(READER_PATH)
	var cache = builder.get("_twodt_cache")
	if Reader != null and cache is Dictionary:
		cache["res_ui\\worldmapguide.2dt"] = Reader.parse(_file(_worldmap()))
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.4, 0.3, 0.2, 1.0))
	var tex := ImageTexture.create_from_image(img)
	(builder.get("_texture_cache") as Dictionary)[TOWN_DDJ.to_lower()] = tex
	return builder

## The advances' sum the node measured with, recomputed from its own font.
func _width(node: Control) -> float:
	var w := 0.0
	for ch in String(node.get("text")):
		w += float(node.call("advance", ch))
	return w

func _run() -> void:
	await process_frame
	get_root().size = Vector2i(1152, 648)
	await process_frame
	var script := load(WORLDMAP_PATH) as GDScript
	var window: Control = script.new(_builder())
	window.set("map_table", _table())
	window.set("local_table", _signs())
	window.set("text_tables", [_text_table()])
	get_root().add_child(window)
	var built: bool = window.call("build_worldmap")
	_check(built, "the world map builds")
	if not built:
		return
	window.call("open")
	await process_frame
	var layer := window.find_child("Signs", true, false) as Control
	_check(layer != null, "the sign layer is built")
	if layer == null:
		return

	# --- draw order (0x61c360) ----------------------------------------------
	var name_node := layer.get_node_or_null("Sign1") as Control
	var icon := layer.get_node_or_null("Sign2") as Control
	_check(name_node != null and icon != null and name_node.get_index() > icon.get_index(),
		"the town's name, listed before its icon, is drawn over it (every picture, then every text)")
	var order := PackedStringArray()
	for c in layer.get_children():
		order.append(c.name)
	_check(order[0] == "Sign2" and order.size() == 7,
		"the pictures come first; the text with no text is not built (got %s)" % ",".join(order))
	var listed := (window.call("signs") as Array)
	_check(listed.size() == 7 and (listed[0] as WorldmapLocalInfoReader.Sign).id == 1,
		"the click list keeps the table's order (the press walks +0x982c)")

	# --- the town's name ----------------------------------------------------
	var anchor := Vector2(15 + (101 - 100) * 32, 26 + (101 - 100) * 32)
	_check(String(name_node.get("text")) == "Townname", "the key's text (got '%s')" % name_node.get("text"))
	_check(bool(name_node.get("bold")) and bool(name_node.get("shadow")),
		"Bold 1, Blur 1: the weight-600 face with the drop shadow")
	_check((name_node.get("color") as Color) == Color8(255, 247, 182), "its colour, at alpha 255")
	var w := float(name_node.get("text_width"))
	_check(w > 0.0 and is_equal_approx(w, _width(name_node)),
		"its width is the sum of its glyphs' advances (0x8b3910; got %s)" % w)
	_check(name_node.position == Vector2(anchor.x - floorf(floorf(w) / 2.0), anchor.y),
		"it is centred on the anchor's x -- x - width / 2, an int division -- with its top at the anchor's y (got %s for %s)"
			% [name_node.position, anchor])
	_check(int(name_node.get("px")) == UiBuilder.FONT_SIZES[0], "font index 0 is the 12 px face")

	# --- the flags ----------------------------------------------------------
	var plain := layer.get_node_or_null("Sign3") as Control
	_check(plain != null and bool(plain.get("shadow")) and not bool(plain.get("bold")),
		"Shadow 0, Bold 0, Blur 1: plain text with the drop shadow (the white place names)")
	var no_shadow := layer.get_node_or_null("Sign4") as Control
	_check(no_shadow != null and not bool(no_shadow.get("shadow")),
		"Shadow 1 with Blur 0: no shadow -- the Blur byte sets flag 1 after the Shadow byte (0x621256)")
	var big := layer.get_node_or_null("Sign5") as Control
	_check(big != null and int(big.get("px")) == UiBuilder.FONT_SIZES[2] and bool(big.get("bold")),
		"the h column picks the font index: 2 is the 16 px face (0xba5460)")
	_check(plain != null and big != null and float(big.get("text_width")) > float(plain.get("text_width")),
		"the same text in the bold 16 px face is wider")
	var plain_w := 0.0
	if plain != null:
		for ch in "Wide Field Name":
			plain_w += float(plain.call("advance", ch))
	_check(plain != null and is_equal_approx(float(plain.get("text_width")), plain_w),
		"the plain width is the plain advances' sum")
	_check(plain != null and plain.size == Vector2(float(plain.get("text_width")) + 1.0,
		(plain.get("font") as Font).get_height(UiBuilder.FONT_SIZES[0]) + 1.0),
		"a shadowed text's node holds the shadow's extra pixel each way")

	# --- the decorations ----------------------------------------------------
	var left := layer.get_node_or_null("Sign6") as Control
	var right := layer.get_node_or_null("Sign7") as Control
	_check(left != null and String(left.get("text")) == "<-Wide Field Name",
		"link 1 puts \"<-\" before the text (0xd99c90)")
	_check(right != null and String(right.get("text")) == "Wide Field Name->",
		"link 2 puts \"->\" after it (0xd99c88)")
	_check(layer.get_node_or_null("Sign8") == null, "a key with no text draws nothing")

	window.queue_free()
	await process_frame
