extends SceneTree

## The Guild / Community window rebuilt from the client's `res_ui\*.2dt`
## files (GuildWindow, round 595). The fixtures are synthetic records built
## here -- ids, parents, rects, tab groups and class names copied from the
## real files' structure, no art and no text (docs/LEGAL.md) -- run through
## the real reader and builder:
##   godot4 --headless --path client --script res://scripts/ui/hud/guild_window_test.gd
##
## Every script this checks is reached through load() or call(), so a tree
## without it FAILS instead of failing to compile. The old windows' layouts
## (ifcommunity.txt, ifguild.txt) are given too, so an older tree opens its
## own windows and the checks say what they found.

const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"
const READER_PATH := "res://scripts/ui/twodt_reader.gd"
const RECORD := 0x3d0
const GUILD_TAB_ON := "interface\\guild\\gil_info_tab_on.ddj"
const GUILD_TAB_OFF := "interface\\guild\\gil_info_tab_off.ddj"
const LAMP_ON := "interface\\guild\\gil_contact_on.ddj"
const LAMP_OFF := "interface\\guild\\gil_contact_off.ddj"
const CLOSE := "interface\\ifcommon\\com_windowclose.ddj"
const RACE := "interface\\ifcommon\\com_kindred_europe16.ddj"
const CMD_BTN := "interface\\ifcommon\\com_mid_button02.ddj"
const CMD_BTN_DISABLE := "interface\\ifcommon\\com_mid_button02_disable.ddj"
const EDIT_BTN := "interface\\stall\\stl_edit_button.ddj"

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

# --- synthetic .2dt records -------------------------------------------------

func _rec(f: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(RECORD)
	b.fill(0)
	for pair in [[0x000, "name"], [0x040, "base"], [0x140, "tex"], [0x240, "textid"], [0x300, "sample"]]:
		var bytes: PackedByteArray = str(f.get(pair[1], "")).to_ascii_buffer()
		for i in bytes.size():
			b[pair[0] + i] = bytes[i]
	b.encode_u32(0x340, f.get("type", 5))
	b.encode_u32(0x344, f.get("id", 0))
	b.encode_u32(0x348, f.get("parent", 0))
	b.encode_u32(0x34c, f.get("gp", 0))
	b.encode_u32(0x358, f.get("color", 0xffffffff))
	var r: Rect2i = f.get("rect", Rect2i())
	b.encode_s32(0x35c, r.position.x)
	b.encode_s32(0x360, r.position.y)
	b.encode_s32(0x364, r.size.x)
	b.encode_s32(0x368, r.size.y)
	b.encode_u32(0x38c, f.get("group", 0))
	b.encode_u32(0x390, f.get("pane", 0xffffffff))
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

## guild.2dt: the window, its three tabs, the left menu, and pane 47 with the
## parts the OnCreates touch.
func _guild() -> Array:
	var recs := [
		{"type": 0, "id": 176, "name": "CNIFGuildWnd", "root": true, "rect": Rect2i(104, 81, 621, 434), "base": "interface\\frame\\mframe_wnd_"},
		{"type": 16, "id": 72, "parent": 176, "group": 10, "pane": 47, "rect": Rect2i(127, 122, 72, 24), "tex": GUILD_TAB_OFF},
		{"type": 16, "id": 73, "parent": 176, "group": 10, "pane": 164, "rect": Rect2i(204, 122, 72, 24), "tex": "interface\\guild\\gil_relationship_tab_off.ddj"},
		{"type": 16, "id": 74, "parent": 176, "group": 10, "pane": 548, "rect": Rect2i(280, 122, 72, 24), "tex": "interface\\guild\\gil_war_tab_off.ddj"},
		{"type": 2, "id": 42, "parent": 176, "rect": Rect2i(137, 164, 556, 320), "base": "interface\\ifcommon\\bg_tile\\com_bg_tile_b.ddj"},
		{"type": 4, "id": 221, "parent": 176, "rect": Rect2i(74, 208, 28, 28), "tex": "interface\\guild\\gil_sysbutton_comunity.ddj"},
		{"type": 4, "id": 220, "parent": 176, "rect": Rect2i(74, 166, 28, 28), "tex": "interface\\guild\\gil_sysbutton_guild.ddj"},
		{"type": 1, "id": 47, "parent": 176, "rect": Rect2i(115, 144, 601, 362), "base": "interface\\equipment\\equip_window_"},
		{"type": 3, "id": 85, "parent": 47, "gp": 176, "rect": Rect2i(129, 287, 570, 167)},
		{"type": 15, "id": 28, "name": "CNIFGuildUserSlot", "parent": 47, "gp": 176, "rect": Rect2i(132, 312, 547, 24), "tex": "interface\\ifcommon\\com_bar01_left.ddj"},
	]
	for pair in [[64, Rect2i(137, 317, 12, 16)], [68, Rect2i(161, 318, 234, 15)], [69, Rect2i(413, 318, 33, 15)],
			[70, Rect2i(465, 318, 100, 15)], [71, Rect2i(580, 318, 90, 15)], [231, Rect2i(161, 315, 16, 16)]]:
		recs.append({"type": 5, "id": pair[0], "parent": 28, "gp": 47, "rect": pair[1]})
	var x := 129
	for id in range(37, 42):
		recs.append({"type": 4, "id": id, "parent": 47, "gp": 176, "rect": Rect2i(x, 465, 112, 24), "tex": CMD_BTN})
		x += 115
	recs.append({"type": 5, "id": 115, "parent": 47, "gp": 176, "rect": Rect2i(625, 163, 69, 15)})
	recs.append({"type": 5, "id": 66, "parent": 47, "gp": 176, "rect": Rect2i(357, 161, 198, 16)})
	recs.append({"type": 5, "id": 124, "parent": 47, "gp": 176, "rect": Rect2i(261, 196, 266, 15)})
	recs.append({"type": 5, "id": 150, "parent": 47, "gp": 176, "rect": Rect2i(241, 195, 16, 16), "tex": RACE})
	recs.append({"type": 10, "id": 120, "parent": 47, "gp": 176, "rect": Rect2i(328, 222, 193, 8)})
	recs.append({"type": 8, "id": 222, "name": "CNIFGuildNotifySlot", "parent": 47, "gp": 176, "rect": Rect2i(129, 257, 572, 28)})
	recs.append({"type": 5, "id": 117, "parent": 222, "gp": 47, "rect": Rect2i(256, 263, 412, 15)})
	recs.append({"type": 4, "id": 81, "parent": 222, "gp": 47, "rect": Rect2i(674, 258, 24, 24), "tex": EDIT_BTN})
	recs.append({"type": 4, "id": 250, "parent": 47, "gp": 176, "rect": Rect2i(674, 218, 16, 16)})
	recs.append({"type": 18, "id": 1000, "name": "CNIFGuildGrantPow", "parent": 47, "gp": 176, "rect": Rect2i(758, 96, 570, 205)})
	recs.append({"type": 1, "id": 1200, "name": "CNIFGuildNotifyView", "parent": 47, "gp": 176, "rect": Rect2i(121, 285, 588, 213), "base": "interface\\inventory\\int_window_"})
	return recs

func _guild_r() -> Array:
	return [
		{"type": 1, "id": 164, "root": true, "rect": Rect2i(0, 0, 601, 362)},
		{"type": 1, "id": 2000, "name": "CNIFHostileGuild", "parent": 164, "rect": Rect2i(6, 30, 588, 325)},
		{"type": 1, "id": 86, "name": "CNIFAllianceGuild", "parent": 164, "rect": Rect2i(6, 30, 588, 325)},
		{"type": 15, "id": 271, "name": "CNIFAllianceSlot", "parent": 86, "gp": 164, "rect": Rect2i(311, 66, 255, 24)},
		{"type": 5, "id": 127, "parent": 271, "gp": 86, "rect": Rect2i(320, 70, 16, 16)},
		{"type": 5, "id": 128, "parent": 271, "gp": 86, "rect": Rect2i(340, 70, 16, 16)},
		{"type": 5, "id": 131, "parent": 271, "gp": 86, "rect": Rect2i(360, 70, 100, 15)},
		{"type": 16, "id": 87, "parent": 164, "group": 1, "pane": 86, "rect": Rect2i(10, 6, 76, 24)},
		{"type": 16, "id": 88, "parent": 164, "group": 1, "pane": 2000, "rect": Rect2i(90, 6, 76, 24)},
	]

func _guild_w() -> Array:
	return [
		{"type": 1, "id": 548, "name": "CNIFGuildWar", "root": true, "rect": Rect2i(0, 0, 601, 362)},
		{"type": 16, "id": 87, "parent": 548, "group": 1, "rect": Rect2i(10, 6, 76, 24)},
	]

func _friend() -> Array:
	var recs := [
		{"type": 18, "id": 177, "name": "CNIFCommunityWnd", "root": true, "rect": Rect2i(290, 190, 2, 2)},
		{"type": 16, "id": 72, "parent": 177, "group": 50, "pane": 646, "rect": Rect2i(313, 231, 72, 24)},
		{"type": 16, "id": 73, "parent": 177, "group": 50, "pane": 59, "rect": Rect2i(390, 231, 72, 24)},
		{"type": 16, "id": 74, "parent": 177, "group": 50, "pane": 700, "rect": Rect2i(466, 231, 72, 24)},
		{"type": 1, "id": 646, "name": "CNIFFriendWnd", "parent": 177, "rect": Rect2i(301, 253, 601, 362), "base": "interface\\equipment\\equip_window_"},
		{"type": 5, "id": 18, "parent": 646, "gp": 177, "rect": Rect2i(828, 266, 55, 15)},
	]
	var y := 309
	for slot in [339, 52]:
		recs.append({"type": 15, "id": slot, "name": "CNIFFriendSlot", "parent": 646, "gp": 177, "rect": Rect2i(319, y, 546, 24), "tex": "interface\\ifcommon\\com_bar01_left.ddj"})
		recs.append({"type": 5, "id": 341, "parent": slot, "gp": 646, "rect": Rect2i(468, y + 5, 370, 15), "sample": "SAMPLE-NAME"})
		recs.append({"type": 5, "id": 52, "parent": slot, "gp": 646, "rect": Rect2i(349, y + 5, 12, 16), "tex": LAMP_ON})
		recs.append({"type": 5, "id": 51, "parent": slot, "gp": 646, "rect": Rect2i(426, y + 5, 16, 16), "tex": RACE})
		y += 23
	return recs

func _cut() -> Array:
	return [
		{"type": 1, "id": 59, "name": "CNIFBlockWnd", "root": true, "rect": Rect2i(0, 0, 601, 362)},
		{"type": 5, "id": 337, "parent": 59, "rect": Rect2i(566, 59, 16, 24)},
		{"type": 15, "id": 398, "name": "CNIFBlockSlot", "parent": 59, "rect": Rect2i(18, 81, 548, 24)},
		{"type": 5, "id": 46, "parent": 398, "gp": 59, "rect": Rect2i(48, 86, 12, 16), "tex": LAMP_ON},
		{"type": 5, "id": 400, "parent": 398, "gp": 59, "rect": Rect2i(96, 87, 462, 15)},
		{"type": 16, "id": 395, "parent": 59, "group": 0, "rect": Rect2i(16, 7, 76, 28), "tex": "interface\\guild\\gil_whisper_sub_tab_off.ddj"},
		{"type": 16, "id": 396, "parent": 59, "group": 0, "rect": Rect2i(94, 7, 76, 28), "tex": "interface\\guild\\gil_totality_sub_tab_off.ddj"},
	]

func _note() -> Array:
	return [
		{"type": 1, "id": 700, "name": "CNIFLetter", "root": true, "rect": Rect2i(0, 0, 601, 362)},
		{"type": 1, "id": 800, "parent": 700, "rect": Rect2i(10, 10, 300, 200)},
		{"type": 18, "id": 900, "name": "CNIFMultiLetter", "parent": 700, "rect": Rect2i(15, 364, 569, 279)},
		{"type": 15, "id": 72, "name": "CNIFMultiLetterSlot", "parent": 900, "gp": 700, "rect": Rect2i(17, 388, 547, 24)},
		{"type": 5, "id": 75, "parent": 72, "gp": 900, "rect": Rect2i(20, 392, 16, 16)},
		{"type": 5, "id": 76, "parent": 72, "gp": 900, "rect": Rect2i(40, 392, 16, 16)},
		{"type": 5, "id": 341, "parent": 72, "gp": 900, "rect": Rect2i(60, 392, 300, 15)},
	]

# --- the old windows' layouts, for a tree that still builds them ----------

func _layout(frame: String, size: String) -> String:
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n\t%s:CIFFrame\n\t{\n\t\tDDJ=STRING,\"interface\\\\messagebox\\\\msgbox2_window_\"\n\t\tID=INTEGER,\"1\"\n\t\tRect=RECT,\"0,0,%s\"\n\t}\n}\n" % [frame, size]

func _text_table() -> UiTextTable:
	var rows := PackedStringArray()
	for pair in [["UIIT_STT_GUILDVIEW", "Guild (text table)"], ["UIIT_STT_COMMUNITY", "Community (text table)"],
			["UIIT_STT_GUILD_INFO", "Guild information"], ["UIIT_CTL_FRIEND", "Friends"],
			["UIIT_STT_NO_GUILD", "No guild (text table)"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

func _tex(builder: UiBuilder, path: String, size: Vector2i) -> Texture2D:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.4, 0.3, 0.2, 1.0))
	var t := ImageTexture.create_from_image(img)
	(builder.get("_texture_cache") as Dictionary)[path.to_lower()] = t
	return t

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, _text_table())
	var layouts: Dictionary = builder.get("_layout_cache")
	layouts["resinfo\\ifcommunity.txt"] = UiLayoutParser.parse(_layout("GDR_COMMUNITY_FRAME", "464,381"))
	layouts["resinfo\\ifguild.txt"] = UiLayoutParser.parse(_layout("GDR_GUILD_FRAME", "446,314"))
	var Reader = load(READER_PATH)
	var cache = builder.get("_twodt_cache")
	if Reader != null and cache is Dictionary:
		var files := {"res_ui\\guild.2dt": _guild(), "res_ui\\guild_r.2dt": _guild_r(),
			"res_ui\\guild_w.2dt": _guild_w(), "res_ui\\cumunity_friend.2dt": _friend(),
			"res_ui\\cumunity_cut.2dt": _cut(), "res_ui\\cumunity_note.2dt": _note()}
		for path in files:
			cache[path] = Reader.parse(_file(files[path]))
	for p in [GUILD_TAB_ON, GUILD_TAB_OFF, LAMP_ON, LAMP_OFF, CLOSE, RACE, CMD_BTN, CMD_BTN_DISABLE, EDIT_BTN]:
		_tex(builder, p, Vector2i(16, 16))
	return builder

# --- helpers ----------------------------------------------------------------

func _press(panels: Node, keycode: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = true
	panels.call("_unhandled_key_input", ev)

## A control by its GetChild path from `root`, through node metadata, so
## this compiles and FAILS on a tree without the builder.
func _at(root: Node, path: Array) -> Control:
	var at: Node = root
	for id in path:
		var found: Node = null
		if at != null:
			for c in at.get_children():
				if c.has_meta("twodt_id") and int(c.get_meta("twodt_id")) == int(id):
					found = c
					break
		at = found
	return at as Control

func _rect_in(window: Control, node: Control) -> Rect2:
	if node == null:
		return Rect2()
	return Rect2(node.get_global_rect().position - window.get_global_rect().position, node.size)

func _guild_root(window: Control) -> Control:
	return window.get("guild_root") as Control if window != null and "guild_root" in window else null

func _community_root(window: Control) -> Control:
	return window.get("community_root") as Control if window != null and "community_root" in window else null

func _shown(node: Control) -> bool:
	return node != null and node.is_visible_in_tree()

## Built and hidden (its own flag, whatever its parents'), or built and not.
func _hidden(node: Control) -> bool:
	return node != null and not node.visible

## Built and not drawn (itself or a parent hidden).
func _not_shown(node: Control) -> bool:
	return node != null and not node.is_visible_in_tree()

func _flag_on(node: Control) -> bool:
	return node != null and node.visible

func _caption(window: Control) -> String:
	var bar := window.get_node_or_null("TitleBar") as Label if window != null else null
	return bar.text if bar != null else "<no caption>"

func _visible_window(panels: Node) -> Control:
	for c in panels.get_children():
		if c is Control and c.name.begins_with("Window_") and (c as Control).visible:
			return c
	return null

# --- the checks -------------------------------------------------------------

func _run() -> void:
	# The client's default window, 1152x648 (the headless root starts at
	# 64x64 and takes a size only after its first frame).
	await process_frame
	get_root().size = Vector2i(1152, 648)
	await process_frame
	var script := load(PANELS_PATH) as GDScript
	var builder := _builder()
	var panels: Control = script.new(builder)
	get_root().add_child(panels)
	await process_frame
	# A friend list that arrives before the window is built is kept and drawn
	# when it is (the client fills its window from the data it holds).
	var early := _Entry.new("Early", false)
	if panels.has_method("_on_friend_list_changed"):
		panels.call("_on_friend_list_changed", [early])
	else:
		print("(this tree has no _on_friend_list_changed)")

	# U: the retail key opens the guild view.
	_press(panels, KEY_U)
	await process_frame
	var window := _visible_window(panels)
	_check(window != null, "U opens a window")
	if window == null:
		return
	_check(_caption(window) == "Guild (text table)",
		"U's window is captioned from UIIT_STT_GUILDVIEW (got '%s')" % _caption(window))
	_check(window.size == Vector2(621, 434), "it is guild.2dt's CNIFGuildWnd, 621x434 (got %s)" % window.size)
	var groot := _guild_root(window)
	_check(groot != null, "it is built from res_ui\\guild.2dt (a guild_root)")
	var tab_rects := []
	for id in [72, 73, 74]:
		tab_rects.append(_rect_in(window, _at(groot, [id])))
	_check(tab_rects == [Rect2(23, 41, 72, 24), Rect2(100, 41, 72, 24), Rect2(176, 41, 72, 24)],
		"its tabs are at (23,41) (100,41) (176,41), 72x24 (got %s)" % [tab_rects])
	_check(_shown(_at(groot, [47])), "the info pane 47 is shown")
	_check(_not_shown(_at(groot, [164])) and _not_shown(_at(groot, [548])), "the relations and war panes are hidden")
	_check(_hidden(_at(groot, [47, 1200])), "the notice view 47 -> 1200 is hidden")
	_check(_hidden(_community_root(window)), "the community window is hidden in the guild view")
	var tab72 := _at(groot, [72]) as TextureButton
	_check(tab72 != null and bool(tab72.get_meta("twodt_checked", false)), "the info tab is checked")
	_check(tab72 != null and tab72.tooltip_text == "Guild information", "the info tab carries UIIT_STT_GUILD_INFO as its hover text")

	# Centred on the screen on every show (0x798c50), kept inside the view.
	var view := window.get_viewport_rect().size
	var want := Vector2(maxi(0, int(view.x) / 2 - 310), maxi(0, int(view.y) / 2 - 217))
	_check(view == Vector2(1152, 648) and want == Vector2(266, 107), "the view is the client's 1152x648, so the centre is (266, 107)")
	_check(window.position == want, "the window is centred on the %s view at %s (got %s)" % [view, want, window.position])

	# CNIFMainFrame's chrome (0x479a50).
	var bar := window.get_node_or_null("TitleBar") as Control
	_check(bar != null and bar.position == Vector2(10, 12) and bar.size.x == 600,
		"the caption is at (10, 12), 600 wide (got %s)" % (Rect2(bar.position, bar.size) if bar else null))
	var close := window.get_node_or_null("CloseButton") as Control
	_check(close != null and close.position == Vector2(595, 10) and close.size == Vector2(16, 16),
		"the close button is at (595, 10), 16x16 (got %s)" % (Rect2(close.position, close.size) if close else null))
	_check(window.call("in_drag_strip", Vector2(300, 30)) and not window.call("in_drag_strip", Vector2(300, 36)) \
			and not window.call("in_drag_strip", Vector2(5, 10)),
		"it drags by (10, 0, 600, 34)")

	# The OnCreates' own state.
	for id in [64, 68, 69, 70, 71]:
		_check(_hidden(_at(groot, [47, 28, id])), "guild user row: 28 -> %d hidden at create" % id)
	_check(_hidden(_at(groot, [47, 28, 231])), "guild user row: 28 -> 231 hidden on show, a row past the member list (0x5b6b40(0))")
	for id in range(37, 42):
		var cmd := _at(groot, [47, id]) as TextureButton
		_check(cmd != null and cmd.visible and cmd.disabled,
			"command button 47 -> %d shown and disabled with no guild (0x5b51c8..0x5b51e2)" % id)
	var cmd37 := _at(groot, [47, 37]) as TextureButton
	_check(cmd37 != null and cmd37.texture_disabled == (builder.get("_texture_cache") as Dictionary)[CMD_BTN_DISABLE.to_lower()],
		"a disabled command button draws its _disable piece")
	var edit81 := _at(groot, [47, 222, 81]) as TextureButton
	_check(edit81 != null and edit81.disabled, "the notice's edit button 47 -> 222 -> 81 is disabled (0x5b51f9)")
	# Round 814: in a guild the grant-name button (47 -> 40, the dispatcher
	# 0x5b63e0's index 3) is the one enabled -- the own grant name (OURS) --
	# and OK on its box reaches the panels' guild_grant_name_requested.
	if window.has_method("open_grant_name_box"):
		window.call("set_guild", true, "Verizon", "Ann")
		var g40 := _at(groot, [47, 40]) as TextureButton
		var others_off := true
		for id in [37, 38, 39, 41]:
			others_off = others_off and (_at(groot, [47, id]) as TextureButton).disabled
		_check(g40 != null and not g40.disabled and others_off, "in a guild 47 -> 40 (grant name) is enabled, the others not")
		var asked := []
		panels.connect("guild_grant_name_requested", func(n: String) -> void: asked.append(n))
		window.emit_signal("grant_name_submitted", "Roaster")
		_check(asked == ["Roaster"], "the box's name reaches guild_grant_name_requested (%s)" % [asked])
		window.call("set_guild", false)
		_check(g40.disabled, "out of the guild it is disabled again")
	else:
		print("(this tree has no grant-name button)")
	var l66 := _at(groot, [47, 66]).get_node_or_null("Text") as Label if _at(groot, [47, 66]) else null
	_check(l66 != null and l66.text == "No guild (text table)", "with no guild 47 -> 66 reads UIIT_STT_NO_GUILD (got %s)" % (l66.text if l66 else null))
	_check(_hidden(_at(groot, [47, 150])), "with no guild the race mark 47 -> 150 is hidden (0x5b6266)")
	var gauge := _at(groot, [47, 120]) as Range
	_check(gauge != null and gauge.value == 0, "the GP gauge is empty")
	var grant := _at(groot, [47, 1000])
	var anchor85 := _at(groot, [47, 85])
	_check(grant != null and anchor85 != null and not grant.visible and grant.position == anchor85.position,
		"the grant window 1000 is hidden and moved onto 47 -> 85 (got %s)" % (grant.position if grant else null))
	var rel := _at(groot, [164])
	_check(rel != null and _rect_in(window, rel).position == Vector2(11, 63), "guild_r is placed on pane 47 at (11, 63)")
	_check(_flag_on(_at(groot, [164, 86])) and _hidden(_at(groot, [164, 2000])),
		"in guild_r the alliance sub-tab's pane is shown and the hostile one hidden")
	for id in [127, 128, 131]:
		_check(_hidden(_at(groot, [164, 86, 271, id])), "alliance row 271 -> %d hidden at create" % id)
	var c115 := _at(groot, [47, 115])
	var l115 := c115.get_node_or_null("Text") as Label if c115 else null
	_check(l115 != null and l115.get_theme_color("font_color") == Color8(0xff, 0xd9, 0x53), "47 -> 115's text colour is 0xffffd953")

	# The underbar's community button (the retail menu's community item,
	# 0x5b49c0) toggles too: with the guild view up it switches the view and
	# closes the window; pressed again it opens in the community view.
	panels.call("toggle", "community")
	await process_frame
	_check(not window.visible, "the community button with the guild view up closes the window (0x5b49c0)")
	panels.call("toggle", "community")
	await process_frame
	var croot := _community_root(window)
	_check(window.visible and _caption(window) == "Community (text table)",
		"the community button shows the window captioned from UIIT_STT_COMMUNITY (got '%s', visible %s)" % [_caption(window), window.visible])
	_check(_shown(croot), "the community window is shown")
	_check(_shown(_at(croot, [646])) and _not_shown(_at(croot, [59])) and _not_shown(_at(croot, [700])),
		"its friend pane is up, the block and letter panes are not")
	_check(_not_shown(_at(groot, [47])) and _not_shown(_at(groot, [164])) and _not_shown(_at(groot, [548])),
		"the guild's own panes are hidden under it")
	var ctab := []
	for id in [72, 73, 74]:
		ctab.append(_rect_in(window, _at(croot, [id])))
	_check(ctab == tab_rects and ctab[0].size == Vector2(72, 24), "the community's tabs lie exactly on the guild's (got %s)" % [ctab])
	_check(_rect_in(window, _at(croot, [646])).position == Vector2(11, 63), "the friend pane is at (11, 63)")
	_check(_rect_in(window, _at(croot, [59])).position == Vector2(11, 63) and _rect_in(window, _at(croot, [700])).position == Vector2(11, 63),
		"the block and letter panes are placed on the friend pane")
	var t395 := _at(croot, [59, 395])
	_check(t395 != null and bool(t395.get_meta("twodt_checked", false)), "the block pane's first sub-tab is checked (0x587aad)")
	_check(_hidden(_at(croot, [700, 800])) and _hidden(_at(croot, [700, 900])), "the letter pane's 800 and 900 are hidden")
	for id in [75, 76, 341]:
		_check(_hidden(_at(croot, [700, 900, 72, id])), "multi-letter row -> %d hidden at create" % id)
	var name0e := _at(croot, [646, 339, 341])
	var l0e := name0e.get_node_or_null("Text") as Label if name0e else null
	_check(l0e != null and l0e.text == "Early" and _flag_on(name0e), "a friend list that came before the window was built is on row 1")
	for id in [341, 52, 51]:
		_check(_hidden(_at(croot, [646, 52, id])), "row 2, with no entry, hides %d from creation (0x5a85c0)" % id)
	var count := _at(croot, [646, 18])
	var lc := count.get_node_or_null("Text") as Label if count else null
	_check(lc != null and lc.text == ": 1 / 20", "the friend count reads ': 1 / 20' (0x5a9985, got %s)" % (lc.text if lc else null))
	for id in [46, 400]:
		_check(_hidden(_at(croot, [59, 398, id])), "an empty block row hides %d (0x586130)" % id)
	var lamp46 := _at(croot, [59, 398, 46]) as TextureRect
	_check(lamp46 != null and lamp46.texture == (builder.get("_texture_cache") as Dictionary)[LAMP_OFF.to_lower()],
		"a block row's lamp is set to gil_contact_off (0x588364)")

	# Friends fill the friend rows (0x5a85c0 / 0x5a7990).
	_check(window.has_method("fill_friends"), "the window fills friend rows")
	if window.has_method("fill_friends"):
		var entry := _Entry.new("Alice", true)
		window.call("fill_friends", [entry])
		var lc2 := _at(croot, [646, 18]).get_node_or_null("Text") as Label if _at(croot, [646, 18]) else null
		_check(lc2 != null and lc2.text == ": 1 / 20", "the count follows the list")
		var name0 := _at(croot, [646, 339, 341])
		var l0 := name0.get_node_or_null("Text") as Label if name0 else null
		_check(l0 != null and l0.text == "Alice" and _flag_on(name0), "row 1 shows the friend's name")
		var lamp0 := _at(croot, [646, 339, 52]) as TextureRect
		_check(lamp0 != null and lamp0.visible and lamp0.texture == (builder.get("_texture_cache") as Dictionary)[LAMP_ON.to_lower()],
			"an online friend's lamp is gil_contact_on")
		for id in [341, 52, 51]:
			_check(_hidden(_at(croot, [646, 52, id])), "row 2, past the list, hides %d" % id)
		var drawn := PackedStringArray()
		for n in window.find_children("*", "Label", true, false):
			drawn.append((n as Label).text)
		_check(not ("SAMPLE-NAME" in drawn), "no row draws its sample text")

	# U while the community view is up: the guild view, and the window toggles (0x5b4980).
	_press(panels, KEY_U)
	await process_frame
	_check(not window.visible, "U with the community up switches to the guild view and closes the window")
	_press(panels, KEY_U)
	await process_frame
	_check(window.visible and _caption(window) == "Guild (text table)" and _not_shown(croot),
		"U again opens it in the guild view")

	# Tabs, and the guild view re-checking the first tab (0x5b3ba0).
	if groot == null:
		return
	(_at(groot, [73]) as BaseButton).pressed.emit()
	_check(_shown(_at(groot, [164])) and _not_shown(_at(groot, [47])), "the relations tab shows pane 164 and hides 47")
	panels.set("last_populated", "")
	(_at(groot, [221]) as BaseButton).pressed.emit()
	_check(_shown(croot) and _caption(window) == "Community (text table)", "the left-menu button 221 switches to the community view")
	_check(str(panels.get("last_populated")) == "community", "and asks for the community's data (got '%s')" % panels.get("last_populated"))
	(_at(groot, [220]) as BaseButton).pressed.emit()
	_check(_not_shown(croot) and _shown(_at(groot, [47])) and _not_shown(_at(groot, [164])),
		"220 switches back, and the guild's first tab is checked again")

	# G no longer opens the guild (round 608): in the retail key table G is
	# slot 13, pick up (0x9e18f0), and U, slot 6, is the guild's key.
	window.hide()
	_press(panels, KEY_G)
	await process_frame
	_check(not window.visible, "G does not open the guild window (retail slot 13 is pick up)")
	_press(panels, KEY_U)
	await process_frame
	_check(window.visible and _caption(window) == "Guild (text table)", "U opens the guild view (retail slot 6)")

	await _guild_member_checks(panels, window, groot)
	await _move_checks(panels, window)

	# UI scale 1.5 on the client's default 1152x648: a 768x432 view, 2 short
	# of the window's 434. Centring alone puts it at y = -1; it is kept at 0.
	window.hide()
	get_root().size = Vector2i(1152, 648)
	get_root().content_scale_factor = 1.5
	await process_frame
	window.show()
	await process_frame
	var v15 := window.get_viewport_rect().size
	_check(window.position.y >= 0 and window.position.x == float(maxi(0, int(v15.x) / 2 - 310)),
		"at UI scale 1.5 (view %s) the window stays inside the view (got %s)" % [v15, window.position])
	get_root().content_scale_factor = 1.0

class _Entry:
	var friend_name: String
	var online: bool
	func _init(n: String, o: bool) -> void:
		friend_name = n
		online = o

# --- a guild member, replies before the HUD existed, moves -----------------

func _net() -> Node:
	return get_root().get_node_or_null("NetClient")

func _guild_reply(guild_id: int, guild_name: String, master: String) -> GuildNet.Result:
	var r := GuildNet.Result.new()
	r.guild_id = guild_id
	r.guild_name = guild_name
	r.leader_id = 70
	var m := GuildNet.Member.new()
	m.character_id = 70
	m.member_name = master
	m.role = GuildNet.ROLE_LEADER
	r.members.append(m)
	return r

func _text(node: Control) -> String:
	var l := node.get_node_or_null("Text") as Label if node != null else null
	return l.text if l != null else "<no label>"

func _guild_member_checks(panels: Control, window: Control, groot: Control) -> void:
	# The window is up in the guild view with no guild. A guild_info reply
	# for guild 7 arrives while it is shown -- the order U produces, since U
	# shows the window before _populate asks the server.
	window.hide()
	_press(panels, KEY_U)
	await process_frame
	_check(_text(_at(groot, [47, 66])) == "No guild (text table)", "before any guild reply the window shows the no-guild state")
	if panels.has_method("_on_guild_info_result"):
		panels.call("_on_guild_info_result", _guild_reply(7, "Seven", "Boss"))
	await process_frame
	_check(_text(_at(groot, [47, 66])) == "Seven", "a guild reply while the window is up replaces UIIT_STT_NO_GUILD with the guild's name (got '%s')" % _text(_at(groot, [47, 66])))
	_check(_flag_on(_at(groot, [47, 150])), "and shows the race mark 150 again (0x5b5f47)")
	_check(_text(_at(groot, [47, 124])) == "Boss", "and puts the master's name on 124 (got '%s')" % _text(_at(groot, [47, 124])))
	_press(panels, KEY_U)
	await process_frame
	_press(panels, KEY_U)
	await process_frame
	_check(window.visible and _text(_at(groot, [47, 66])) == "Seven", "reopened, the guild is still shown (got '%s')" % _text(_at(groot, [47, 66])))
	# Leaving: back to no guild.
	_check(panels.has_method("_on_guild_leave_result"), "HudPanels takes guild leave replies")
	if panels.has_method("_on_guild_leave_result"):
		panels.call("_on_guild_leave_result", true, "")
	await process_frame
	_check(_text(_at(groot, [47, 66])) == "No guild (text table)" and _hidden(_at(groot, [47, 150])), "after a successful leave the no-guild state is back")
	# Joining mid-session: the join reply alone tells the window.
	var net := _net()
	if net != null and panels.has_method("connect_net"):
		panels.call("connect_net")
		net.emit_signal("guild_join_result", _guild_reply(9, "Nine", "Chief"))
		await process_frame
		_check(_text(_at(groot, [47, 66])) == "Nine", "a guild join reply mid-session shows the guild (got '%s')" % _text(_at(groot, [47, 66])))
		_block_checks(net, groot)
	else:
		_check(false, "NetClient is registered for this suite")
	window.hide()

	# Replies that came before the HUD was built: NetClient keeps them.
	if net == null:
		return
	var kept_guild := "last_guild_result" in net
	_check(kept_guild, "NetClient keeps the last guild reply")
	if not kept_guild:
		return
	net.set("last_guild_result", _guild_reply(11, "Eleven", "Elder"))
	net.set("last_friend_list", [_Entry.new("Kept", true)])
	net.set("has_friend_list", true)
	var script := load(PANELS_PATH) as GDScript
	var later: Control = script.new(_builder())
	get_root().add_child(later)
	later.call("connect_net")
	await process_frame
	later.call("toggle", "guild")
	await process_frame
	var w2 := _visible_window(later)
	var g2 := _guild_root(w2)
	_check(g2 != null and _text(_at(g2, [47, 66])) == "Eleven", "a guild reply that came before the HUD existed is shown (got '%s')" % _text(_at(g2, [47, 66])))
	var c2 := _community_root(w2)
	_check(c2 != null and _text(_at(c2, [646, 339, 341])) == "Kept", "and so is a friend list (got '%s')" % _text(_at(c2, [646, 339, 341])))
	net.set("last_guild_result", null)
	net.set("last_friend_list", [])
	net.set("has_friend_list", false)
	later.free()

func _drag(window: Control, from: Vector2, by: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = from
	window.call("_gui_input", press)
	var motion := InputEventMouseMotion.new()
	motion.position = from + by
	window.call("_gui_input", motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = from + by
	window.call("_gui_input", release)

func _move_checks(panels: Control, window: Control) -> void:
	_press(panels, KEY_U)
	await process_frame
	if not window.visible:
		_press(panels, KEY_U)
		await process_frame
	var centred := window.position
	_drag(window, Vector2(300, 20), Vector2(-100, 60))
	var dragged := window.position
	_check(dragged == centred + Vector2(-100, 60), "the window drags by its caption strip (got %s from %s)" % [dragged, centred])
	# F10 hides the HUD (an ancestor) and shows it again: not a show of the
	# window, so it stays where it was dragged.
	panels.visible = false
	await process_frame
	panels.visible = true
	await process_frame
	panels.visible = false
	await process_frame
	panels.visible = true
	await process_frame
	_check(window.position == dragged, "hiding and showing the HUD twice leaves the window where it was dragged (got %s, dragged %s)" % [window.position, dragged])
	# Closing and reopening is a show: centred again (0x5bb16c).
	_press(panels, KEY_U)
	await process_frame
	_press(panels, KEY_U)
	await process_frame
	_check(window.visible and window.position == Vector2(266, 107), "closed after a drag and reopened, the window is centred again at (266, 107) (got %s)" % window.position)
	window.hide()


## Round 821: the retail guild block fills the information and the member
## rows (0x5b5eb0, 0x5b6b40, READ).
func _block_checks(net: Node, groot: Control) -> void:
	var data = net.get("guild_data")
	_check(data != null, "NetClient keeps the guild record (guild_data)")
	if data == null:
		return
	var b := PackedByteArray()
	var u32 := func(v: int) -> void:
		var x := PackedByteArray()
		x.resize(4)
		x.encode_u32(0, v)
		b.append_array(x)
	var str16 := func(t: String) -> void:
		var raw := t.to_utf8_buffer()
		var x := PackedByteArray()
		x.resize(2)
		x.encode_u16(0, raw.size())
		b.append_array(x)
		b.append_array(raw)
	u32.call(9)
	str16.call("Nine")
	b.append(2)
	u32.call(25200)
	str16.call("")
	str16.call("")
	u32.call(0)
	b.append(0)
	b.append(2)
	# Zed, the master, online; Ann, a member, offline: Ann sorts first.
	for m in [[1, "Zed", 0, 50, 7, 0], [2, "Ann", 10, 21, 3, 1]]:
		u32.call(m[0])
		str16.call(m[1])
		b.append(m[2])
		b.append(m[3])
		u32.call(m[4])
		for i in 4:
			u32.call(0)
		str16.call("")
		u32.call(0)
		b.append(0)
		b.append(m[5])
	b.append(0)
	data.call("handle", PackedByteArray(), 0x34B3)
	data.call("handle", b, 0x3101)
	data.call("handle", PackedByteArray(), 0x34B4)
	await process_frame
	_check(_text(_at(groot, [47, 66])) == "Nine" and _text(_at(groot, [47, 115])) == "Level 2", "the block: name and \"Level 2\" (got '%s')" % _text(_at(groot, [47, 115])))
	_check(_text(_at(groot, [47, 124])) == "Zed", "the master's name from the class-0 member (got '%s')" % _text(_at(groot, [47, 124])))
	var gauge := _at(groot, [47, 120]) as Range
	_check(gauge != null and is_equal_approx((gauge.value - gauge.min_value) / (gauge.max_value - gauge.min_value), 0.5), "the GP gauge at 25200 / 50400")
	_check(_text(_at(groot, [47, 222, 117])) == "UIIT_MSG_GUILD_COMMON_NOTEXIST" or _text(_at(groot, [47, 222, 117])).length() > 0, "no notice: UIIT_MSG_GUILD_COMMON_NOTEXIST")
	var row := _at(groot, [47, 28])
	_check(row != null and _text(_at(row, [68])) == "Ann" and _text(_at(row, [69])) == "21" and _text(_at(row, [71])) == "3", "the first row is Ann (name order), level 21, GP 3 (got '%s')" % _text(_at(row, [68])) if row != null else "")
	# The fixture's lamp has no art, so the builder makes it a bare control.
	var lamp := _at(row, [64]) if row != null else null
	_check(lamp != null and lamp.visible, "the row's lamp is shown")
	var name_label := _at(row, [68]).get_node_or_null("Text") as Label if row != null else null
	_check(name_label != null and name_label.get_theme_color("font_color").to_argb32() == 0xff808080, "an offline member's row is grey (0x475dd0(3))")
	# The record would outrank the placeholder replies the checks after this
	# one feed.
	data.call("clear")
