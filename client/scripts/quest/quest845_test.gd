extends SceneTree

## Round 845 lane K, against the real Media.pk2 where the box has it:
## - the quest detail's text drawn as the client's CIFPML draws it (PmlText):
##   the record's FontColor black, `<font color>` runs in their colour
##   (the headers' 226,74,0, the scenario's 44,15,1), `<strong>` in the
##   weight-600 face, lines tmHeight + 5 apart and a `<br><br>` gap of 5, the
##   pixel scroll and its scroll bar;
## - the quest list's world-map button (QuestMapGuide, HudWorldmap.show_quest):
##   the area test of 0x612e60, the error line's text, the monster areas and
##   icons of 0x6256e0 / 0x624f40 on the world map.
## Synthetic markup checks run everywhere; the archive's checks SKIP without
## it (no game data in the repo, docs/LEGAL.md).
##
##   client/tools/remote_godot.sh script res://scripts/quest/quest845_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const ORANGE := Color8(226, 74, 0)
const SCENARIO := Color8(44, 15, 1)

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await _run()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

func _run() -> void:
	_markup()
	_layout_synthetic()
	if not FileAccess.file_exists(MEDIA):
		print("SKIP (no %s)" % MEDIA)
		return
	var pk2 := Pk2Reader.open(MEDIA)
	_check(pk2 != null, "Media.pk2 opens")
	if pk2 == null:
		return
	var entry := ObjectLoader.find_file(pk2, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	var table := UiTextTable.parse(pk2.read_file(entry)) if entry != null else null
	root.size = Vector2i(1280, 720)
	await process_frame
	var builder := UiBuilder.new(pk2, table)
	var tables := QuestTables.shared(pk2)
	await _detail(builder, tables)
	await _map(builder, pk2, tables)

# --- The markup (synthetic) ----------------------------------------------------

func _markup() -> void:
	var items := PmlText.parse("<sml2><strong><font color=\"255,226,74,0\"> A</font></strong><br>b<br><br><font color=\"255,44,15,1\"><strong> C</strong><br>d</font></sml2>", Color.BLACK)
	var runs := items.filter(func(it: Dictionary) -> bool: return it.has("text"))
	_check(runs.size() == 4, "four runs (got %d)" % runs.size())
	if runs.size() == 4:
		_check(runs[0]["color"] == ORANGE and int(runs[0]["style"]) == PmlText.STYLE_BOLD,
			"<strong><font color=\"255,226,74,0\">: R,G,B 226,74,0 (the four numbers are A,R,G,B, 0x9b1e40) in style 2")
		_check(runs[1]["color"] == Color.BLACK and int(runs[1]["style"]) == 0, "text after </font></strong> is the control's colour, style 0")
		_check(runs[2]["color"] == SCENARIO and int(runs[2]["style"]) == PmlText.STYLE_BOLD, "a <strong> inside a <font> keeps the font's colour")
		_check(runs[3]["color"] == SCENARIO and int(runs[3]["style"]) == 0, "</strong> pops back to the <font>'s state")
	var brs := items.filter(func(it: Dictionary) -> bool: return it.has("br"))
	_check(brs.size() == 4, "four <br> (got %d)" % brs.size())
	# The data's doubled quotes (20 colours in textquest_otherstring): A reads
	# 0, R,G,B as written -- and the alpha is not drawn.
	var dq := PmlText.parse("<font color=\"\"255,226,74,0\"\">x</font>", Color.BLACK)
	_check(dq.size() == 1 and dq[0]["color"] == ORANGE, "color=\"\"255,226,74,0\"\" gives 226,74,0 (got %s)" % [dq[0]["color"] if dq.size() > 0 else null])
	_check(PmlText.colour_of("255,255,0,0") == Color8(255, 0, 0), "\"255,255,0,0\" is red")
	_check(PmlText.style_of("shadow|bold\"") == 3 and PmlText.style_of("underline\"") == 16, "style names are bits 1, 2 .. 16 (0x9b3090)")
	var unknown := PmlText.parse("a<blink>b</blink><br/>c", Color.WHITE)
	_check(unknown.size() == 4 and str(unknown[0]["text"]) == "a" and str(unknown[1]["text"]) == "b" and unknown[2].has("br"),
		"an unknown tag is dropped, its text kept; <br/> breaks")

func _layout_synthetic() -> void:
	var p := PmlText.new()
	p.size = Vector2(290, 247)
	root.add_child(p)
	p.setup(ThemeDB.fallback_font, 12, Color.BLACK)
	p.set_markup("one<br>two<br><br>three")
	var tm := p.text_height(0)
	_check(p.lines.size() == 4, "four lines: one, two, an empty one, three (got %d)" % p.lines.size())
	if p.lines.size() == 4:
		_check(int(p.lines[1]["y"]) - int(p.lines[0]["y"]) == tm + PmlText.LINE_MARGIN,
			"a text line is tmHeight + 5 below the last (0x9b0c6d, got %d, tm %d)" % [int(p.lines[1]["y"]) - int(p.lines[0]["y"]), tm])
		_check(int(p.lines[3]["y"]) - int(p.lines[2]["y"]) == PmlText.LINE_MARGIN and int(p.lines[2]["h"]) == 0,
			"an empty line is 0 tall, so <br><br> adds only the 5-pixel margin")
	# The word wrap (0x8b3ef0): a long run breaks after its last space.
	var words := "aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll mmmm nnnn"
	p.set_markup(words)
	var lines := p.plain_lines()
	_check(lines.size() >= 2 and lines[0].ends_with(" ") and words.begins_with(lines[0]) and p.text_width(lines[0].strip_edges(), 0) <= 290.0,
		"a wrapped line ends after a space and fits the width (got %s)" % [lines])
	_check("".join(lines) == words, "the wrap loses no character")
	var long := "x".repeat(200)
	p.set_markup(long)
	_check(p.plain_lines().size() > 1 and p.plain_lines()[0].length() > 1, "a word wider than the line breaks before the glyph that passes it")
	p.set_markup("<br>".join(PackedStringArray(range(40).map(func(i: int) -> String: return "line %d" % i))))
	_check(p.max_scroll() == p.content_height - 247 and p.content_height > 247, "the scroll's range is content - height (0x649c30)")
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_DOWN
	ev.pressed = true
	p._gui_input(ev)
	_check(p.scroll == PmlText.WHEEL_PIXELS, "a wheel notch scrolls 6 pixels (vslot_036: 120 / 20 x step 1)")
	p.queue_free()

# --- The detail (the real archive) ---------------------------------------------

func _quest_id(tables: QuestTables, code: String) -> int:
	for id in tables.by_id:
		if (tables.by_id[id] as QuestTables.Quest).code == code:
			return int(id)
	return 0

func _detail(builder: UiBuilder, tables: QuestTables) -> void:
	# Several quests' markup: every header orange and bold, the plain lines
	# black, the scenario its own dark brown.
	for code in ["QNO_CH_SMITH_1", "QNO_CH_POTION_1", "QNO_CH_CHEF_1", "QNO_EU_CONS_1"]:
		var q := tables.quest(_quest_id(tables, code))
		if q == null:
			_check(false, "%s is in questdata" % code)
			continue
		var items := PmlText.parse(tables.resolve(q.paycon, ""), Color.BLACK)
		var heads := items.filter(func(it: Dictionary) -> bool:
			return it.has("text") and it["color"] == ORANGE and int(it["style"]) == PmlText.STYLE_BOLD)
		var black := items.filter(func(it: Dictionary) -> bool: return it.has("text") and it["color"] == Color.BLACK)
		var brown := items.filter(func(it: Dictionary) -> bool: return it.has("text") and it["color"] == SCENARIO)
		_check(heads.size() >= 4 and black.size() >= 4 and brown.size() >= 2,
			"%s: %d orange bold headers, %d black runs, %d scenario runs" % [code, heads.size(), black.size(), brown.size()])
	var ev := tables.resolve("SN_PAYCON_QEV_ALL_BASIC3_11", "")
	_check(ev.contains("\"\"255,226,74,0\"\""), "QEV_ALL_BASIC3_11 carries the doubled quotes (MEASURED)")
	var ev_heads := PmlText.parse(ev, Color.BLACK).filter(func(it: Dictionary) -> bool: return it.has("text") and it["color"] == ORANGE)
	_check(ev_heads.size() >= 3, "its headers read orange too (got %d)" % ev_heads.size())

	# The detail window itself (CIFQuestReward on ifquestreward.txt).
	var panels := Control.new()
	panels.size = Vector2(1280, 720)
	root.add_child(panels)
	var hud := QuestHud.new(panels, builder, null)
	hud.tables = tables
	panels.add_child(hud)
	var id := _quest_id(tables, "QNO_CH_SMITH_1")
	var w := hud.open_detail(id)
	await process_frame
	_check(w != null and w.visible, "the detail opens")
	if w == null:
		return
	var body := w.get_node_or_null("QuestContents") as PmlText
	_check(body != null, "its contents are a PmlText (the CIFPML 18)")
	if body == null:
		return
	_check(body.default_color == Color.BLACK, "the contents' colour is the record's FontColor 255,0,0,0 (got %s)" % body.default_color)
	_check(body.position == Vector2(30, 74) and body.size == Vector2(290, 247), "at the record's 30,74 290x247 (got %s %s)" % [body.position, body.size])
	var first: Dictionary = body.lines[0]
	_check((first["runs"] as Array).size() == 1 and (first["runs"][0]["color"] as Color) == ORANGE and str(first["runs"][0]["text"]).contains("Mission"),
		"line 0 is the orange ' ◈ Mission' header (got %s)" % [first["runs"]])
	var second: Dictionary = body.lines[1]
	_check(str(second["runs"][0]["text"]) == "Deliver weapons list" and (second["runs"][0]["color"] as Color) == Color.BLACK,
		"line 1 the black 'Deliver weapons list'")
	_check(int(body.lines[2]["h"]) == 0 and int(body.lines[3]["y"]) - int(body.lines[2]["y"]) == 5, "line 2 the empty <br><br> line, 5 to the next")
	var scroll := w.find_child("QuestContentsScroll", true, false) as HudChat.ChatScroll
	_check(scroll != null and is_equal_approx(scroll.length, 247.0 - 48.0) and scroll.maximum == body.max_scroll(),
		"the scroll bar 15: length 247 - 48, range 0..content - 247 (got %s / %s)" % [scroll.length if scroll else -1, scroll.maximum if scroll else -1])
	var title := w.node("GDR_QUESTREWARD_TITLE")
	var tl := title.get_node_or_null("Text") as Label if title != null else null
	_check(tl != null and tl.text == "Weapon dealer's letter" and title.get_meta(QuestHud.TITLE_BOLD_META, false),
		"the title 17 is SN_PAY_ in the weight-600 face (got '%s')" % (tl.text if tl else ""))
	panels.queue_free()

# --- The map button (the real archive) -----------------------------------------

func _map(builder: UiBuilder, pk2: Pk2Reader, tables: QuestTables) -> void:
	var guide := QuestMapGuide.shared(pk2)
	var running := QuestNet.View.new()
	running.status = 1
	_check(guide.has_area(running, "QNO_CH_POTION_1"), "QNO_CH_POTION_1 has a guide row: the map shows it")
	_check(not guide.has_area(running, "QNO_CH_SMITH_1"), "QNO_CH_SMITH_1 has none: the error line")
	_check(not guide.has_area(running, "QNO_RM_MEETROC_1"), "a service-0 row does not count (QNO_RM_MEETROC_1)")
	var kill := QuestNet.View.new()
	kill.status = 8
	_check(not guide.has_area(kill, "QNO_CH_POTION_1"), "status 8 with no NPC list: no place, whatever the guide says")
	kill.npcs = PackedInt64Array([2005])
	_check(guide.has_area(kill, "QNO_CH_SMITH_1"), "status 8 with an NPC: a place")
	var err := builder.resolve_text(QuestMapGuide.MAP_ERR_KEY)
	_check(err == "Does not have any information about that quest.", "UIIT_MSG_MAP_ERR's text (got '%s')" % err)
	_check(HudSystemMessage.color_for(HudSystemMessage.TYPE_ALWAYS) == HudChat.argb(0xffdbc99b), "the line is type 0, 0xffdbc99b")
	var rows := guide.quest_rows("QNO_CH_POTION_1")
	_check(rows.size() == 1 and (rows[0] as WorldmapGuideReader.GuidePoint).kind == 0
		and (rows[0] as WorldmapGuideReader.GuidePoint).codes() == PackedStringArray(["MOB_CH_WATERGHOST"]),
		"POTION_1: one kind-0 row naming MOB_CH_WATERGHOST")
	var m := guide.monster("MOB_CH_WATERGHOST")
	_check(m != null and m.area == "field" and m.region == Vector2i(166, 101) and m.pos == Vector2i(62, 58)
		and m.colours() == PackedInt64Array([0x80000004]), "the water ghost's MONSTER row: field, 166x101 + (62, 58), colour 0x80000004")
	_check(guide.tiles_of("MOB_CH_WATERGHOST") == [Vector2i(162, 101), Vector2i(166, 101), Vector2i(170, 101)],
		"its mask tiles from worldmapguidedata_region.txt (got %s)" % [guide.tiles_of("MOB_CH_WATERGHOST")])
	var field := guide.map_named("field")
	_check(field != null and field.map_id == 0 and field.start_region == Vector2i(46, 113) and field.regions_per_tile == Vector2i(4, 4),
		"MAP_MANAGER's field: map 0, from 46x113, 4x4 regions a tile")
	var hwan := guide.quest_rows("QNO_CH_HWAN_1_3_1")
	_check(hwan.size() == 1 and (hwan[0] as WorldmapGuideReader.GuidePoint).kind == 1, "QNO_CH_HWAN_1_3_1: the one kind-1 row")

	# The texel pass on the real mask (MEASURED: 9366 texels 0x80000004).
	var tex := builder.load_texture("interface\\worldmap\\monster\\field_166x101.ddj")
	var img := (tex.get_image().duplicate() as Image) if tex != null and tex.get_image() != null else null
	_check(img != null, "field_166x101.ddj loads")
	if img != null:
		var n := HudWorldmap.paint_mask(img, PackedInt64Array([0x80000004]), {}, HudWorldmap.QUEST_AREA_ARGB)
		var gold := 0
		var other := 0
		var d := img.get_data()
		for i in range(0, d.size(), 4):
			var v: int = (d[i + 3] << 24) | (d[i] << 16) | (d[i + 1] << 8) | d[i + 2]
			if v == HudWorldmap.QUEST_AREA_ARGB:
				gold += 1
			elif v != HudWorldmap.MASK_CLEAR_ARGB:
				other += 1
		_check(n == 9366 and gold == 9366 and other == 0, "the mask's 9366 water-ghost texels turn 0x80e9c624, the rest clear (got %d / %d / %d)" % [n, gold, other])
		var again := tex.get_image().duplicate() as Image
		_check(HudWorldmap.paint_mask(again, PackedInt64Array([0x80000004]), {0x80000004: true}, HudWorldmap.QUEST_AREA_ARGB) == 0,
			"a colour already painted is not painted again (+0x229b0)")

	# The world map with the quest on it.
	var wm := HudWorldmap.new(builder)
	root.add_child(wm)
	_check(wm.build_worldmap(), "the world map builds")
	await process_frame
	wm.quest_guide = guide
	wm.show_quest(running, "QNO_CH_POTION_1")
	var rep := wm.quest_report()
	_check(rep.contains("wmap_monster_icon.ddj@(3902,442)") and rep.contains("focus=[0, (3902.0, 442.0)]"),
		"the water ghost's icon at (166 - 46) * 32 + 62, (113 - 101) * 32 + 58 and the map there (got %s)" % rep)
	_check(rep.contains("162x101 tile (29, 3) painted 1116") and rep.contains("166x101 tile (30, 3) painted 9366") and rep.contains("170x101 tile (31, 3) painted 1596"),
		"its three mask tiles over map tiles (29..31, 3)")
	_check(not wm.is_auto_move() and rep.contains("canvas=(-3584,-266)"),
		"auto-move off and the point at the area's (304, 176) -- (304 - 3902, 176 - 442), the x held at the map's right edge (0x61c5a0's clamp)")
	wm.show_quest(running, "QNO_CH_HWAN_1_3_1")
	rep = wm.quest_report()
	_check(rep.contains("wmap_quest_icon.ddj@(4032,638)") and not rep.contains("QuestArea"),
		"a kind-1 row: the quest icon at (170 - 46) * 32 + 64, (113 - 97) * 32 + 126 -- the row's own x, y -- and the last marks cleared (got %s)" % rep)
	wm.queue_free()

	# The quest list's button 18 asks for the map (0x6e51e0).
	var qw := QuestWindow.new()
	root.add_child(qw)
	_check(qw.build_quest(builder), "the quest list builds from questlist.2dt")
	qw.tables = tables
	var asked := []
	qw.map_requested.connect(func(qid: int) -> void: asked.append(qid))
	var v := QuestNet.View.new()
	v.status = 1
	var pid := _quest_id(tables, "QNO_CH_POTION_1")
	qw.fill_log([[pid, v]])
	var b18 := qw.control([5, 18]) as BaseButton
	_check(b18 != null and b18.visible, "row 5's world-map button 18 is shown in quest mode")
	if b18 != null:
		b18.pressed.emit()
	_check(asked == [pid], "pressing it asks for the row's quest (got %s)" % [asked])
	qw.queue_free()
