extends SceneTree

## Round 725 (docs/protocol/npc_gui.md, lane A): the NPC window, its text and
## menu, the store's archive-defined branch, and the talk box's chaining.
## Every table, layout and text here is a fixture, never the archive's.
##   godot4 --headless --path client --script res://scripts/ui/hud/npc_talk_view_test.gd

const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the live checks never reported (a script error stopped them)")
		quit(1))
	_define_checks()
	_store_line_checks()
	_menu_checks()
	_colour_checks()
	# HudPanels names the NetClient autoload, registered after _init, and its
	# windows centre on the viewport: wait a frame (teleport_board_test.gd).
	await process_frame
	var panels_script := load(PANELS_PATH) as GDScript
	var compiled := panels_script != null and panels_script.can_instantiate()
	_check(compiled, "HudPanels compiles in _initialize")
	if compiled:
		await _window_checks(panels_script)
		_store_checks(panels_script)
		_chain_checks(panels_script)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

# --- config\define.txt -------------------------------------------------------

func _define_checks() -> void:
	# ANSI, as the client tokenises it: split on = " , space and tab, the
	# first token a name -- so a comment line defines "//", `NAME = 0` is
	# defined, an indented name counts, a repeat is one name.
	var raw := PackedByteArray()
	raw.append_array("// Define String\r\n\r\nWHISPER_BLOCKING_SYSTEM\t\t//".to_ascii_buffer())
	raw.append_array(PackedByteArray([0xc0, 0xcc, 0xb8, 0xa7]))
	raw.append_array("\r\nRENEWAL_SHOP_SYSTEM\t//x\r\n  RESTORE_SOLDITEM_INSHOP // y\r\nRENEWAL_SHOP_SYSTEM\r\nZERO_NAME = 0\r\n\"QUOTED\",1".to_ascii_buffer())
	var names := UiBuilder.parse_define_txt(raw)
	_check(names == PackedStringArray(["//", "WHISPER_BLOCKING_SYSTEM", "RENEWAL_SHOP_SYSTEM", "RESTORE_SOLDITEM_INSHOP", "ZERO_NAME", "QUOTED"]),
		"define.txt: the first token of each line, NAME = 0 defined, no comment handling, no repeats (got %s)" % [names])
	_check(UiBuilder.parse_define_txt(PackedByteArray()).is_empty(), "NEGATIVE: an empty file defines nothing")
	var b := UiBuilder.new(null, null)
	_check(b.archive_defines().is_empty(), "NEGATIVE: with no archive there is no define table")
	_check(b.get("_archive_defines") == null, "NEGATIVE: and the empty answer is not cached before the archive opens")

# --- the store lines -----------------------------------------------------------

func _table(rows: Array) -> PackedByteArray:
	return ("\r\n".join(PackedStringArray(rows)) + "\r\n").to_utf16_buffer()

func _shop_reader() -> ShopReader:
	var tables := {
		ShopReader.T_SHOPGROUP: _table(["1\t15\t1\tGROUP_STORE_FX_POTION\tNPC_FX_POTION", "1\t15\t2\tGROUP_STORE_FX_ARMOR\tNPC_FX_ARMOR"]),
		ShopReader.T_MAPGROUP: _table(["1\t15\tGROUP_STORE_FX_POTION\tSTORE_FX_POTION", "1\t15\tGROUP_STORE_FX_ARMOR\tSTORE_FX_ARMOR"]),
		ShopReader.T_MAPTAB: _table(["1\t15\tSTORE_FX_POTION\tSTORE_FX_POTION_GROUP1",
			"1\t15\tSTORE_FX_ARMOR\tSTORE_FX_ARMOR_GROUP1", "1\t15\tSTORE_FX_ARMOR\tSTORE_FX_ARMOR_GROUP2"]),
		ShopReader.T_TABGROUP: _table(["1\t15\t10\tSTORE_FX_POTION_GROUP1\tSN_FX_POTION_GROUP1",
			"1\t15\t11\tSTORE_FX_ARMOR_GROUP1\tSN_FX_ARMOR_GROUP1", "1\t15\t12\tSTORE_FX_ARMOR_GROUP2\tSN_FX_ARMOR_GROUP2"]),
		ShopReader.T_TAB: _table(["1\t15\t1\tSTORE_FX_POTION_TAB1\tSTORE_FX_POTION_GROUP1\tSN_TAB_P",
			"1\t15\t2\tSTORE_FX_ARMOR_TAB1\tSTORE_FX_ARMOR_GROUP1\tSN_TAB_A1",
			"1\t15\t3\tSTORE_FX_ARMOR_TAB2\tSTORE_FX_ARMOR_GROUP2\tSN_TAB_A2"]),
		ShopReader.T_GOODS: _table([]),
		ShopReader.T_SCRAP: _table([]),
	}
	return ShopReader.new().load(func(path: String) -> PackedByteArray: return tables.get(path, PackedByteArray()))

func _store_line_checks() -> void:
	var r := _shop_reader()
	var potion := r.store_lines_for("NPC_FX_POTION")
	_check(potion.size() == 1 and potion[0]["tabgroup"] == "STORE_FX_POTION_GROUP1" and potion[0]["name_strid"] == "SN_FX_POTION_GROUP1",
		"one store line per tab group, worded by the group's own name key (got %s)" % [potion])
	var armor := r.store_lines_for("npc_fx_armor")
	_check(armor.size() == 2 and armor[0]["tabgroup"] == "STORE_FX_ARMOR_GROUP1" and armor[1]["tabgroup"] == "STORE_FX_ARMOR_GROUP2",
		"a shop with two tab groups has two lines, in table order (got %s)" % [armor])
	var t2 := r.tabs_for("NPC_FX_ARMOR", "STORE_FX_ARMOR_GROUP2")
	_check(t2.size() == 1 and (t2[0] as ShopReader.Tab).name_strid == "SN_TAB_A2", "a store line opens its own tab group's tabs")
	_check(r.store_lines_for("NPC_FX_NOBODY").is_empty(), "NEGATIVE: an NPC with no shop has no store line")

# --- the menu: ids -> lines, in FUN_00700440's order -----------------------------

func _keys(services: Array) -> Array:
	var out: Array = []
	for s in services:
		out.append((s as NpcServiceReader.Service).key)
	return out

func _menu_checks() -> void:
	var lines := [{"tabgroup": "G1", "name_strid": "SN_G1"}, {"tabgroup": "G2", "name_strid": "SN_G2"}]
	var shop := NpcServiceReader.services_for("NPC_FX_POTION", {"NPC_FX_POTION": true}, -1, false, 0, lines)
	_check(_keys(shop) == ["shop:G1", "shop:G2"], "store lines first, one per tab group (got %s)" % [_keys(shop)])
	_check((shop[0] as NpcServiceReader.Service).strid == "SN_G1", "a store line's token is its group's name key")
	var keeper := NpcServiceReader.services_for("NPC_FX_WAREHOUSE_M", {"NPC_FX_WAREHOUSE_M": true}, -1, false, 0, lines.slice(0, 1))
	_check(_keys(keeper) == ["shop:G1", "storage"], "a keeper: store line, then the warehouse line (kind 3) (got %s)" % [_keys(keeper)])
	var fallback := NpcServiceReader.services_for("NPC_FX_POTION", {"NPC_FX_POTION": true})
	_check(_keys(fallback) == ["shop"], "an NPC whose tab groups do not resolve keeps the Buy stand-in (got %s)" % [_keys(fallback)])
	var gate := NpcServiceReader.gate_services(true, true, false)
	_check(_keys(gate) == ["recall_designate", "teleport"], "a gate: recall (id 7 -> kind 9), then teleport (id 8 -> kind 10) (got %s)" % [_keys(gate)])
	var drawn := NpcServiceReader.talk_menu_lines("fx", shop, func(t: String, f: String) -> String: return "Purchase " + t if t != "" else f)
	_check(drawn.size() == 3 and drawn[0] == "[url=shop:G1]1. Purchase SN_G1[/url]" and drawn[2].begins_with("[url=end]3. "),
		"numbered '%%d. ' lines, the end line last (got %s)" % [drawn])
	_check(NpcServiceReader.is_shop_key("shop:G1") and NpcServiceReader.is_shop_key("shop") and not NpcServiceReader.is_shop_key("storage"),
		"is_shop_key")
	_check(NpcServiceReader.tabgroup_of("shop:G2") == "G2" and NpcServiceReader.tabgroup_of("shop") == "", "tabgroup_of")

# --- colours ----------------------------------------------------------------------

func _colour_checks() -> void:
	var lines := PackedStringArray(["Hello", "", NpcTalkView.tax_line("Tax 0%"), "", "[url=a]1. A[/url]", "[url=end]2. End[/url]"])
	var plain := NpcTalkView.coloured(lines, "")
	_check(plain.contains("[url=a][color=#efdaa4]1. A[/color][/url]") and plain.contains("[url=end][color=#efdaa4]2. End"),
		"menu lines in 0xffefdaa4 (got %s)" % plain)
	_check(plain.contains("[color=#d6ff7e]Tax 0%[/color]"), "the tax line in 0xffd6ff7e")
	_check(plain.begins_with("Hello\n"), "the greeting keeps the label's default colour (white)")
	var hovered := NpcTalkView.coloured(lines, "a")
	_check(hovered.contains("[url=a][color=#ff8a00]1. A") and hovered.contains("[url=end][color=#efdaa4]"),
		"the hovered line in 0xffff8a00, the others beige")
	_check(NpcTalkView.fortress_strid_for("NPC_CH_POTION") == "SN_FORTRESS_JANGAN"
		and NpcTalkView.fortress_strid_for("STORE_CH_GATE") == "SN_FORTRESS_JANGAN"
		and NpcTalkView.fortress_strid_for("NPC_KT_SMITH") == "SN_FORTRESS_HOTAN"
		and NpcTalkView.fortress_strid_for("NPC_WC_POTION") == "", "the tax line's fortress (OURS mapping)")

# --- fixtures for the live windows ---------------------------------------------------

func _control(control_name: String, type: String, rect: String, ddj: String = "", text: String = "") -> String:
	return "\t%s:%s\n\t{\n\t\tClientRect=RECT,\"0,0,0,0\"\n\t\tDDJ=STRING,\"%s\"\n\t\tFontColor=COLOR,\"255,255,255,255\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"%s\"\n\t}\n" % [control_name, type, ddj, rect, text]

func _layout(body: String) -> String:
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" + body + "}\n"

func _registry() -> String:
	return _layout(
		_control("GDR_NPCWINDOW", "CIF_NPCWindow", "200,200,386,451", "interface\\\\frame\\\\mframe_wnd_")
		+ "#ifdef RENEWAL_SHOP_SYSTEM\n#ifdef RESTORE_SOLDITEM_INSHOP\n"
		+ _control("GDR_STORE", "CIFStoreForPackage", "0,0,254,370", "interface\\\\frame\\\\mframe_wnd_")
		+ "#else\n" + _control("GDR_STORE", "CIFStoreForPackage", "0,0,254,317", "interface\\\\frame\\\\mframe_wnd_")
		+ "#endif\n#else\n" + _control("GDR_STORE", "CIFStore", "0,0,254,317", "interface\\\\frame\\\\mframe_wnd_")
		+ "#endif\n"
		+ _control("GDR_STORAGEROOM", "CIFStorageRoom", "0,0,254,317", "interface\\\\frame\\\\mframe_wnd_", "UIIT_STT_STORAGEROOM"))

func _builder(defines: PackedStringArray) -> UiBuilder:
	var rows := PackedStringArray()
	for pair in [["UIIT_STT_STORAGEROOM", "Fixture Storage"], ["UIIT_STT_NPC_CHATTING_WND_TALKEND", "Fixture end."]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	var builder := UiBuilder.new(null, UiTextTable.parse(("\n".join(rows)).to_utf16_buffer()))
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\if_npcwindow.txt"] = UiLayoutParser.parse(_layout(
		_control("GDR_NW_NPCTALK", "CIF_NPCTalk", "11,48,364,391", "interface\\\\npc\\\\npc_conversation_window_")))
	cache["resinfo\\if_npctalk.txt"] = UiLayoutParser.parse(_layout(
		_control("GDR_NT_TALKBOX", "CIFTextBox", "23,23,302,343")
		+ _control("GDR_NPCTALK_SCROLL", "CIFVerticalScroll", "336,27,16,320")
		+ _control("GDR_NPCTALK_QUESTBG", "CIFStatic", "-5,-10,374,400")
		+ _control("GDR_NPCTALK_BGTILE", "CIFNormalTile", "20,20,324,351")))
	var store := _control("GDR_STORE_FRAME", "CIFFrame", "9,60,236,219") \
		+ "#ifdef RESTORE_SOLDITEM_INSHOP\n" + _control("GDR_STORE_ICON_SLOT_01", "CIFSlotWithHelp", "61,289,32,32") + "#endif\n"
	# UiBuilder.load_layout's key for a read with #ifdef selection: the path,
	# \u0001, then the defines joined with \u0002.
	cache["resinfo\\ifstore.txt" + "\u0001" + "\u0002".join(defines)] = UiLayoutParser.parse(_layout(store), true, defines)
	cache["resinfo\\ifstorageroom.txt"] = UiLayoutParser.parse(_layout(
		_control("GDR_STORAGE_BG_CTRL", "CIFSubFrame", "9,38,236,241")))
	builder.set("_window_registry", UiLayoutParser.parse(_registry()))
	builder.set("_window_registry_loaded", true)
	builder.set("_window_registry_data", _registry())
	builder.set("_archive_defines", defines)
	return builder

# --- the NPC window -----------------------------------------------------------------

func _window_checks(panels_script: GDScript) -> void:
	var panels: Node = panels_script.new(_builder(PackedStringArray()))
	root.add_child(panels)
	panels.call("open_npc_talk", "Herbalist", "Fixture greeting", [], "Fixture tax 0%")
	var window: Control = (panels.get("_windows") as Dictionary).get("npctalk")
	_check(window != null and window.size == Vector2(386, 451), "the talk window is GDR_NPCWINDOW's 386x451 (got %s)" % [window.size if window != null else null])
	var talk := (window as HudWindow).node("GDR_NW_NPCTALK") as Control if window != null else null
	_check(talk != null and talk.find_child("GDR_NT_TALKBOX", true, false) != null,
		"if_npctalk.txt is composed inside CIF_NPCTalk (GDR_NW_NPCTALK)")
	var quest := (window as HudWindow).node("GDR_NPCTALK_QUESTBG") as CanvasItem if window != null else null
	_check(quest != null and not quest.visible, "the quest parchment is hidden for a plain talk")
	var clip := window.find_child(NpcTalkView.CLIP_NAME, true, false) as Control if window != null else null
	_check(clip != null and clip.position == Vector2(34, 71) and clip.size == Vector2(302, 343),
		"the text sits on GDR_NT_TALKBOX: (11+23, 48+23), 302x343 (got %s)" % [Rect2(clip.position, clip.size) if clip != null else null])
	var bar := window.find_child(NpcTalkView.SCROLL_NAME, true, false) as Control if window != null else null
	_check(bar != null and bar.position == Vector2(347, 59) and (bar as HudChat.ChatScroll).length == 320.0,
		"the scroll bar: the up arrow 16 above (11+336, 48+27), length 320 (READ 0x6fa1c9) (got %s)" % [bar.position if bar != null else null])
	var body := NpcTalkView.body_of(window)
	_check(body != null and not body.meta_underlined, "the menu lines are not underlined")
	var parsed := body.get_parsed_text().split("\n") if body != null else PackedStringArray()
	_check(parsed.size() >= 5 and parsed[0] == "Fixture greeting" and parsed[2] == "Fixture tax 0%" and parsed[3] == "" and parsed[4] == "1. Fixture end.",
		"greeting, blank, tax line, blank, then the menu (got %s)" % [parsed])
	# Scroll: many lines run past the box; the bar's range is what does not fit.
	var many := PackedStringArray()
	for i in range(60):
		many.append("[url=x%d]%d. line[/url]" % [i, i + 1])
	NpcTalkView.show_lines(window, many)
	await process_frame
	await process_frame
	var scroll := bar as HudChat.ChatScroll
	_check(scroll != null and scroll.maximum > 0, "60 lines give the scroll bar a range (got %s)" % [scroll.maximum if scroll != null else null])
	# The READ pitch (18, 0x6fa1e1): the font's height plus the separation, and
	# 343 / 18 = 19 lines shown, so 60 lines leave 41 steps.
	var font_h := body.get_theme_font("normal_font").get_height(body.get_theme_font_size("normal_font_size"))
	_check(roundi(font_h) + body.get_theme_constant("line_separation") == NpcTalkView.LINE_PITCH and NpcTalkView.LINE_PITCH == 18,
		"the line pitch is 18 (font %.1f + separation %d)" % [font_h, body.get_theme_constant("line_separation")])
	_check(scroll != null and is_equal_approx(scroll.maximum, 41.0), "19 of 60 lines fit, 41 steps (got %s)" % [scroll.maximum if scroll != null else null])
	NpcTalkView.scroll_to(window, 3)
	_check(is_equal_approx(body.position.y, -54.0) and int(body.get_meta(NpcTalkView.META_SCROLL)) == 3, "scrolling 3 lines moves the text up 3 x 18 (got %.1f)" % body.position.y)
	panels.queue_free()

# --- the store's branch ----------------------------------------------------------------

func _store_checks(panels_script: GDScript) -> void:
	var defined := PackedStringArray(["RENEWAL_SHOP_SYSTEM", "RESTORE_SOLDITEM_INSHOP"])
	var panels: Node = panels_script.new(_builder(defined))
	root.add_child(panels)
	var store: HudWindow = panels.call("open", "store")
	_check(store != null and store.size == Vector2(254, 370), "with define.txt's two names the store is GDR_STORE's 254x370 (got %s)" % [store.size if store != null else null])
	_check(store != null and store.node("GDR_STORE_ICON_SLOT_01") != null, "and builds the buy-back row (RESTORE_SOLDITEM_INSHOP)")
	_check(store != null and store.find_child("ShopPurse", true, false) == null, "NEGATIVE: no 'Gold:' label of ours under the grid")
	# The tabs' rect, READ from CIFStoreForPackage::vslot_010: {16 + 56 i, 38, 56, 24}.
	var t1 := ShopReader.Tab.new()
	t1.name_strid = "Tab A"
	var t2 := ShopReader.Tab.new()
	t2.name_strid = "Tab B"
	panels.call("open_shop", "Fixture", [t1, t2], "NPC_FIXTURE")
	store = panels.call("open", "store")
	var tab0 := store.find_child("ShopTab0", true, false) as Control if store != null else null
	var tab1 := store.find_child("ShopTab1", true, false) as Control if store != null else null
	_check(tab0 != null and tab1 != null and tab0.position == Vector2(16, 38) and tab1.position == Vector2(72, 38) and tab0.size == Vector2(56, 24),
		"the store's tabs sit at {16 + 56 i, 38}, 56x24 (got %s, %s)" % [tab0.position if tab0 != null else null, tab1.position if tab1 != null else null])
	var tab_label := tab0.get_node_or_null("Label") as Label if tab0 != null else null
	_check(tab_label != null and tab_label.get_theme_color("font_color") == Color(1, 1, 1), "and their captions are white")
	var storage: HudWindow = panels.call("open", "storage")
	var title := storage.get_node_or_null("TitleBar") as Label if storage != null else null
	_check(title != null and title.text == "Fixture Storage", "the storage is titled UIIT_STT_STORAGEROOM (got %s)" % [title.text if title != null else null])
	_check(title != null and title.get_theme_color("font_color") == Color(1, 1, 1), "a registry window's caption is white (the CTextBoard default, READ)")
	panels.call("open_storage", "Keeper Fixture")
	_check(title != null and title.text == "Fixture Storage", "NEGATIVE: opening it at a keeper does not retitle it with the keeper's name")
	panels.queue_free()
	var bare: Node = panels_script.new(_builder(PackedStringArray()))
	root.add_child(bare)
	var plain: HudWindow = bare.call("open", "store")
	_check(plain != null and plain.size == Vector2(254, 317) and plain.node("GDR_STORE_ICON_SLOT_01") == null,
		"NEGATIVE: without the names, the 317 branch and no buy-back row")
	bare.queue_free()

# --- chaining ---------------------------------------------------------------------------

func _services(keys: Array) -> Array:
	var out: Array = []
	for k in keys:
		out.append(NpcServiceReader.Service.new(k, k))
	return out

func _chain_checks(panels_script: GDScript) -> void:
	var panels: Node = panels_script.new(_builder(PackedStringArray()))
	root.add_child(panels)
	var chosen: Array = []
	panels.connect("npc_service_selected", func(k: String) -> void: chosen.append(k))
	for c in [["shop:G1", false], ["storage", false], ["recall_designate", true], ["teleport", true], ["guild_create", true]]:
		chosen.clear()
		panels.call("open_npc_talk", "Fixture", "Hello", _services(["shop:G1", "storage", "recall_designate", "teleport", "guild_create"]))
		var body := NpcTalkView.body_of((panels.get("_windows") as Dictionary)["npctalk"])
		body.meta_clicked.emit(c[0])
		var open: bool = panels.call("is_open", "npctalk")
		_check(chosen == [c[0]] and open == c[1],
			"'%s': the service is chosen and the talk window %s (got open=%s, chosen=%s)" % [c[0], "stays" if c[1] else "closes first", open, chosen])
	panels.call("open_npc_talk", "Fixture", "Hello", _services(["shop:G1", "storage"]))
	chosen.clear()
	_check(panels.call("qa_press_talk_line", 2) == "storage" and chosen == ["storage"] and not panels.call("is_open", "npctalk"),
		"qa_press_talk_line(2) presses the warehouse line, which closes the talk window")
	panels.queue_free()
