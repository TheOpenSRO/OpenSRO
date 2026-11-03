extends SceneTree

## Round 858: the Help window opens again after it was closed, by every path
## the original has (the frame's X, the H key's toggle, Escape), starts as a
## new window each time (the original makes GDR_GAMEGUIDE afresh on each open,
## c:0x79b140), and its menu carries CIFGGMenu's three tabs (c:0x7685a0). The
## layouts are synthetic, with ifgameguide.txt's / ifggmenu.txt's / the
## GameGuide registry entry's real names and rects; no game data.
##   godot4 --headless --path client --script res://scripts/ui/help_window858_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

const DOCS := [{"title": "One", "path": "res://no/such/one.md"},
	{"title": "Two", "path": "res://no/such/two.md"}]

static func _c(control_name: String, type: String, rect: String, id: int, ddj: String = "", text: String = "") -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tHAlign=INTEGER,\"0\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tStyle=INTEGER,\"0\"\n\t\tText=STRING,\"%s\"\n\t}\n" % [
		control_name, type, ddj, id, rect, text]

static func _layout(body: String) -> UiLayoutParser.LayoutDef:
	return UiLayoutParser.parse("Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n%s}\n" % body)

## A builder holding ifgameguide.txt, ifggmenu.txt and the registry entry.
static func _builder() -> UiBuilder:
	var rows := PackedStringArray()
	for k in ["UIIT_STT_HELP", "UIIT_STT_GAMEGUIDE", "UIIT_STT_GAMEEVENTGUIDE", "UIIT_STT_QUESTGUIDE1"]:
		rows.append("1\t%s\t\t\t\t\t\t\t<%s>" % [k, k])
	var b := UiBuilder.new(null, UiTextTable.parse(("\n".join(rows)).to_utf16_buffer()))
	var cache: Dictionary = b.get("_layout_cache")
	var guide := ""
	guide += _c("GDR_GUIDE_STARTPGDECO", "CIFStatic", "56,112,0,0", 1, "interface\\guide\\gd_guide.ddj")
	guide += _c("GDR_GUIDE_DATA_SCL", "CIFVerticalScroll", "354,112,16,254", 2)
	guide += _c("GDR_GUIDE_DATA_PML", "CIFPML", "53,96,290,303", 3)
	guide += _c("GDR_GUIDE_PAPER", "CIFStatic", "23,49,0,0", 4, "interface\\guide\\gd_paper.ddj")
	guide += _c("GDR_GUIDE_FRAME_1", "CIFFrame", "13,40,395,401", 5, "interface\\inventory\\int_window_")
	guide += _c("GDR_GUIDE_MENU", "CIFGGMenu", "-206,45,213,390", 6, "interface\\messagebox\\msgbox_window_")
	cache["resinfo\\ifgameguide.txt"] = _layout(guide)
	var menu := ""
	menu += _c("GDR_GUIDE_MENU_SCROLLMGR", "CIFScrollManager", "10,34,192,346", 13, "interface\\equipment\\equip_window_")
	menu += _c("GDR_GUIDE_MENU_TILE_2", "CIFNormalTile", "22,46,168,322", 12, "interface\\ifcommon\\bg_tile\\com_bg_tile_d.ddj")
	menu += _c("GDR_GUIDE_MENU_TILE_1", "CIFNormalTile", "69,16,128,128", 11, "interface\\ifcommon\\bg_tile\\com_bg_tile_b.ddj")
	cache["resinfo\\ifggmenu.txt"] = _layout(menu)
	b.set("_window_registry_loaded", true)
	b.set("_window_registry", _layout(_c("GDR_GAMEGUIDE", "CIFGameGuide", "100,100,420,452", 32,
		"interface\\frame\\mframe_wnd_", "UIIT_STT_HELP")))
	return b

func _initialize() -> void:
	root.size = Vector2i(1280, 720)
	await process_frame
	await _authored()
	await _fallback()
	await _escape()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _close_button(frame: Control) -> BaseButton:
	for n in frame.find_children("*", "BaseButton", true, false):
		if String(n.name).to_upper().contains("CLOSE"):
			return n as BaseButton
	return null

## The authored frame: X, reopen, H toggle, a fresh window each open, the tabs.
func _authored() -> void:
	var help := HelpWindow.new()
	root.add_child(help)
	help.setup(_builder(), DOCS, false)
	_check(help.has_authored_frame(), "the synthetic ifgameguide.txt builds the authored frame")
	var frame := help.get_node_or_null("HelpFrame") as Control
	_check(not help.is_open(), "built hidden")
	UiSounds.clear_fired()
	help.open()
	_check(help.is_open() and help.visible and frame.visible, "open: the root and the frame shown")
	_check(UiSounds.count(UiSounds.KEY_WINDOW_OPEN) == 1, "the open sounds snd_window_open once (0x79b140(1) -> 0x79a7e0)")
	help.open()
	_check(UiSounds.count(UiSounds.KEY_WINDOW_OPEN) == 1, "an open of a shown window only raises it, silently")
	var x := _close_button(frame)
	_check(x != null, "the frame has its close button")
	if x != null:
		x.pressed.emit()
	_check(not help.is_open() and not help.visible, "the X closes the whole window, the root with the frame")
	_check(UiSounds.count(UiSounds.KEY_WINDOW_CLOSE) == 1, "the X sounds snd_window_close once")
	help.open()
	_check(help.is_open() and frame.visible, "THE BUG: after the X, open shows the window again (frame visible)")
	help.toggle()
	_check(not help.is_open(), "H (0x79f690) on a shown window closes it")
	help.toggle()
	_check(help.is_open(), "H on a closed one opens it")
	for i in 3:
		if x != null:
			x.pressed.emit()
		help.toggle()
	_check(help.is_open() and frame.visible, "X then H, three times over: open every time")

	# CIFGGMenu's tabs (0x7685a0): three, at (14 + 62 i, 12) 60 x 24 in the menu.
	var menu := frame.find_child("GDR_GUIDE_MENU", true, false) as Control
	var tabs := frame.find_child(HelpWindow.TABS_NODE, true, false) as Control
	_check(tabs != null and tabs.get_child_count() == 3, "the menu has CIFGGMenu's three tabs")
	if tabs != null and menu != null:
		_check(tabs.position == menu.position, "the tabs sit in the menu's coordinates")
		var t1 := tabs.get_child(1) as Control
		_check(t1.position == Vector2(76, 12) and t1.size == Vector2(60, 24), "tab 1 at (76, 12) 60 x 24 (READ 0x76868b: (i * 31) * 2 + 0xe)")
		var cap := tabs.get_child(2).get_node_or_null("Text") as Label
		_check(cap != null and cap.text == "<UIIT_STT_QUESTGUIDE1>", "tab 2's caption is UIIT_STT_QUESTGUIDE1 (0x76884c)")
	_check(help.selected_tab() == 0 and help.selected() == 0, "open: the first tab and the first document")
	var list := frame.find_child("DocList", true, false) as Control
	_check(list != null and list.get_child_count() == 2, "the first tab lists the documents")
	help.select_tab(2)
	await process_frame
	_check(help.selected_tab() == 2 and list.get_child_count() == 0, "the third tab lists nothing here (the guide data is not built)")
	help.select_tab(0)
	await process_frame
	var row1 := list.get_node_or_null("Doc1") as BaseButton
	if row1 != null:
		row1.pressed.emit()
	_check(help.selected() == 1, "a row press shows its document")
	help.select_tab(1)
	help.close()
	help.open()
	await process_frame
	_check(help.selected_tab() == 0 and help.selected() == 0,
		"a reopen starts as a new window: tab 0, document 0 (the original remakes it, 0x79b140(1) -> 0x8b5580)")
	help.queue_free()
	await process_frame

## The plain fallback (no layout): the same open / close / open.
func _fallback() -> void:
	var help := HelpWindow.new()
	root.add_child(help)
	help.setup(null, DOCS, false)
	_check(not help.has_authored_frame(), "no builder: the plain frame")
	help.open()
	_check(help.is_open(), "fallback: open")
	help.close()
	_check(not help.is_open(), "fallback: close")
	help.open()
	_check(help.is_open(), "fallback: open again")
	help.queue_free()
	await process_frame

## Escape (0x79d620): the help window closes after the System window, before
## the world map, and opens again after.
func _escape() -> void:
	var panels: Control = (load("res://scripts/ui/hud/hud_panels.gd") as GDScript).new(null)
	root.add_child(panels)
	var help := HelpWindow.new()
	root.add_child(help)
	help.setup(_builder(), DOCS, false)
	panels.set("help_window", help)
	help.open()
	_check(bool(panels.call("_escape_close")), "Escape takes the help window")
	_check(not help.is_open(), "Escape closed it")
	help.open()
	_check(help.is_open(), "and it opens again after Escape")
	_check(bool(panels.call("_escape_close")) and not help.is_open(), "Escape closes it again")
	_check(not bool(panels.call("_escape_close")) and not help.is_open(), "with nothing open, Escape takes nothing and does not reopen it")
	help.queue_free()
	panels.queue_free()
	await process_frame
