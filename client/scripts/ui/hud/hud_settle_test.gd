extends SceneTree

## The HUD widgets' authored labels settle (round 585). A Label built before
## it is in the tree is clamped to the default face's height (23 at Godot's
## 16px), and only HudWindow re-applied the authored rects afterwards, so the
## underbar, minimap, player info, target and chat kept every label 23 tall
## over an authored 11-15. Each widget is built here from a synthetic layout
## carrying real control names and rects (never real game data), put in the
## tree, and given a few frames; every authored label must then be at its
## authored rect, as tall as Godot allows -- the larger of the authored
## height and the label's own font minimum:
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_settle_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _control(control_name: String, type: String, rect: String, ddj: String = "") -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"\"\n\t}\n" % [control_name, type, ddj, rect]

func _layout(body: String) -> String:
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" + body + "}\n"

## ifunderbar.txt's three text rows.
func _underbar() -> String:
	return _layout(_control("GDR_STATIC_QUICKSLOT", "CIFStatic", "653,22,17,11")
		+ _control("GDR_STATIC_SP", "CIFStatic", "167,9,48,12")
		+ _control("GDR_STATIC_EXP", "CIFStatic", "18,31,198,12"))

## ifminimap.txt's text rows.
func _minimap() -> String:
	return _layout(_control("GDR_MINIMAP_TEXT_AREANAME", "CIFStatic", "12,9,104,12")
		+ _control("GDR_MINIMAP_TEXT_POS_X", "CIFStatic", "8,32,56,11")
		+ _control("GDR_MINIMAP_TEXT_POS_Y", "CIFStatic", "67,32,56,11"))

## ifplayerminiinfo.txt's name, level and HP rows.
func _player_info() -> String:
	return _layout(_control("GDR_PMI_TXT_ID", "CIFStatic", "71,4,93,15")
		+ _control("GDR_PMI_TXT_LEVEL", "CIFStatic", "168,7,37,15")
		+ _control("GDR_PMI_TXT_HP", "CIFStatic", "79,26,124,12"))

## iftargetwindowex.txt's container piece and iftw_commonenemy.txt's rows.
func _target_container() -> String:
	return _layout(_control("GDR_TW_COMMONENEMY", "CIFStatic", "0,0,196,51", "interface\\targetwindow\\fixture.ddj"))

func _target_common() -> String:
	return _layout(_control("GDR_TWCE_GEM", "CIFStatic", "8,5,20,20")
		+ _control("GDR_TWCE_TEXT_ID", "CIFStatic", "34,10,137,12"))

## ifchatviewer.txt's penalty line.
func _chat() -> String:
	return _layout(_control("GDR_CHAT_STA_PENALTY", "CIFStatic", "404,380,160,20")
		+ _control("GDR_LIST_CHATTING", "CIFTextBox", "27,28,365,343"))

## UiBuilder.load_layout's cache key for a layout read with these defines
## (the path, \x01, the defines joined by \x02).
func _ifdef_key(path: String, defines: Array) -> String:
	return "%s%s%s" % [path, char(1), char(2).join(PackedStringArray(defines))]

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, null)
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\ifplayerminiinfo.txt"] = UiLayoutParser.parse(_player_info())
	cache["resinfo\\iftargetwindowex.txt"] = UiLayoutParser.parse(_target_container())
	cache["resinfo\\iftw_commonenemy.txt"] = UiLayoutParser.parse(_target_common())
	cache["resinfo\\ifchatviewer.txt"] = UiLayoutParser.parse(_chat())
	cache[_ifdef_key("resinfo\\ifchatviewer.txt", ["UI_UPDATE_2009_FIRST"])] = UiLayoutParser.parse(_chat(), true, PackedStringArray(["UI_UPDATE_2009_FIRST"]))
	return builder

## Every authored label under `root`: [name, drawn size, authored size, font minimum].
func _labels(root: Node) -> Array:
	var out := []
	for n in root.find_children("*", "Label", true, false):
		var l := n as Label
		if not l.has_meta(UiBuilder.AUTHORED_RECT_META):
			continue
		var ar: Rect2 = l.get_meta(UiBuilder.AUTHORED_RECT_META)
		out.append([String(l.name), l.size, ar.size, l.get_minimum_size().y])
	return out

func _settled(widget: String, root: Node, want: int) -> void:
	var labels := _labels(root)
	_check(labels.size() == want, "%s: %d authored labels built (got %d)" % [widget, want, labels.size()])
	for row in labels:
		var drawn: Vector2 = row[1]
		var authored: Vector2 = row[2]
		var expect := Vector2(authored.x, maxf(authored.y, row[3]))
		_check(drawn == expect, "%s: %s is %s -- authored %s, font minimum %s (got %s)" % [
			widget, row[0], expect, authored, row[3], drawn])

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the live checks never reported (a script error stopped them)")
		quit(1))
	await process_frame
	var hud := Control.new()
	root.add_child(hud)

	var bar := HudUnderbar.new(UiBuilder.new(null, null), null, null)
	bar.setup(_underbar())
	hud.add_child(bar)
	var minimap := HudMinimap.new(UiBuilder.new(null, null), null, null)
	minimap.setup(_minimap())
	hud.add_child(minimap)
	var builder := _builder()
	var pmi := HudPlayerInfo.new(builder)
	pmi.setup()
	hud.add_child(pmi)
	var target := HudTarget.new(builder)
	var target_built: bool = target.setup()
	hud.add_child(target)
	var chat := HudChat.new(builder)
	chat.setup()
	hud.add_child(chat)
	# The pass is a few frames; give it more than enough.
	for i in 8:
		await process_frame

	_settled("underbar", bar, 3)
	_settled("minimap", minimap, 3)
	_settled("player info", pmi, 3)
	_check(target_built, "the target window builds from the fixture")
	_settled("target", target, 2)
	# The gem art is drawn at the gem slot's authored 20x20, not at the
	# slot's clamped size.
	var gem := target.find_child("GDR_TWCE_GEM_art", true, false) as Control
	_check(gem != null and gem.size == Vector2(20, 20) and gem.position == Vector2(8, 5),
		"target: the gem art is at the authored 8,5,20,20 (got %s)" % (Rect2(gem.position, gem.size) if gem != null else "<none>"))
	_settled("chat", chat, 1)

	# A window still settles its title bar through the same pass.
	var win := HudWindow.new()
	hud.add_child(win)
	var wb := UiBuilder.new(null, null)
	(wb.get("_layout_cache") as Dictionary)["resinfo\\iffixture.txt"] = UiLayoutParser.parse(
		_layout(_control("GDR_FIXTURE_TEXT", "CIFStatic", "20,50,100,12") + _control("GDR_FIXTURE_FRAME", "CIFFrame", "0,0,300,200")))
	_check(win.build(wb, "resinfo\\iffixture.txt", "Fixture"), "a HudWindow builds from the fixture")
	for i in 8:
		await process_frame
	_settled("window", win.panel_root, 1)
	var title := win.get_node_or_null("TitleBar") as Label
	_check(title != null and title.position == Vector2(HudWindow.TITLE_INSET, HudWindow.TITLE_TEXT_Y)
		and title.size == Vector2(300 - HudWindow.TITLE_INSET * 2.0, maxf(HudWindow.TITLE_TEXT_HEIGHT, title.get_minimum_size().y)),
		"window: the title bar settles to its strip (got %s)" % (Rect2(title.position, title.size) if title != null else "<none>"))

	hud.free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
