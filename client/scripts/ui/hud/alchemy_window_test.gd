extends SceneTree

## The window Y opens: `CNIFEnchantWnd`, built from `res_ui\nifenchantwnd.2dt`
## (AlchemyWindow; docs/RE_COMPLETION.md has the round). The fixture is
## synthetic records -- the real files' ids, types, parents, rects, class
## names and art paths, with every text a "tt ..." string of this test's own
## and no art (docs/LEGAL.md) -- run through the real reader and builder:
##   godot4 --headless --path client --script res://scripts/ui/hud/alchemy_window_test.gd
##
## Checked, each against what the binary does (addresses in the record):
## - Y builds CNIFEnchantWnd, 389x421, at (0x32, screen height - 0x261),
##   kept on screen (ours), with CNIFMainFrame's caption and close button;
## - the side menu hanging off its left edge, with its hover strings;
## - the create state: the alchemy pane shown and the socket pane hidden,
##   the tab byte's tab (3, the fourth) checked with its pane, button 22's
##   caption, hover string and disabled state, the tabs' hover strings, the
##   confirm box hidden inside the alchemy pane;
## - opening it shows the main popup on its inventory tab (0x79af20);
## - a tab click switches the pane and the mode, and the mode outlives the
##   window; Y again destroys the window, and the next Y rebuilds it where
##   the OnCreate puts it;
## - the side menu switches to the socket pane and back;
## - the close button destroys it; the menu's item opens it and never closes
##   it; Escape closes it before the main popup; an exchange window up
##   refuses it, and an exchange window shown closes it.
##
## Everything new is reached through load(), call(), has_method() or get(),
## so a tree that builds the older ifalchemyprocess.txt panel FAILS here
## instead of failing to compile.

const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"
const READER_PATH := "res://scripts/ui/twodt_reader.gd"
const ALCHEMY_PATH := "res://scripts/ui/hud/alchemy_window.gd"
const RECORD := 0x3d0
const CLOSE := "interface\\ifcommon\\com_windowclose.ddj"
const ACTION_DDJ := "interface\\ifcommon\\com_mid_button02.ddj"
const ACTION_DISABLED_DDJ := "interface\\ifcommon\\com_mid_button02_disable.ddj"
const TAB_BASES := ["interface\\alchemy\\alcm_tabbutton1_", "interface\\alchemy\\alcm_tabbutton2_",
	"interface\\alchemy\\alcm_tabbutton3_", "interface\\alchemy\\alcm_tabbutton4_"]

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
		print("FAIL the checks never finished (a script error stopped them)")
		quit(1))
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

## nifenchantwnd.2dt's 72 records in file order (structure only).
func _enchant() -> Array:
	return [
		{"type": 0, "id": 168, "name": "CNIFEnchantWnd", "root": true, "rect": Rect2i(413, 82, 389, 421), "base": "interface\\frame\\mframe_wnd_"},
		{"type": 5, "id": 2, "parent": 168, "rect": Rect2i(397, 144, 24, 288), "tex": "interface\\alchemy\\alcm_menu_bg.ddj"},
		{"type": 4, "id": 3, "parent": 168, "rect": Rect2i(377, 203, 40, 40), "tex": "interface\\alchemy\\alcm_menu_button2.ddj"},
		{"type": 4, "id": 4, "parent": 168, "rect": Rect2i(377, 161, 40, 40), "tex": "interface\\alchemy\\alcm_menu_button1.ddj"},
		{"type": 1, "id": 5, "name": "CNIFAlchemyWnd", "parent": 168, "rect": Rect2i(425, 146, 366, 343), "base": "interface\\frame\\frameg01_wnd_"},
		{"type": 2, "id": 6, "parent": 5, "gp": 168, "rect": Rect2i(440, 161, 337, 316), "base": "interface\\ifcommon\\bg_tile\\com_bg_tile_b.ddj"},
		{"type": 16, "id": 7, "parent": 5, "gp": 168, "rect": Rect2i(532, 124, 48, 24), "tex": "interface\\alchemy\\alcm_tabbutton3_on.ddj", "group": 10, "pane": 12},
		{"type": 16, "id": 8, "parent": 5, "gp": 168, "rect": Rect2i(582, 124, 48, 24), "tex": "interface\\alchemy\\alcm_tabbutton4_off.ddj", "group": 10, "pane": 12},
		{"type": 16, "id": 9, "parent": 5, "gp": 168, "rect": Rect2i(432, 124, 48, 24), "tex": "interface\\alchemy\\alcm_tabbutton1_on.ddj", "group": 10, "pane": 28},
		{"type": 16, "id": 10, "parent": 5, "gp": 168, "rect": Rect2i(482, 124, 48, 24), "tex": "interface\\alchemy\\alcm_tabbutton2_on.ddj", "group": 10, "pane": 28},
		{"type": 18, "id": 12, "name": "CNIFAlchemySubWndType1", "parent": 5, "gp": 168, "rect": Rect2i(435, 161, 343, 312)},
		{"type": 3, "id": 13, "parent": 12, "gp": 5, "rect": Rect2i(434, 160, 347, 151), "base": "interface\\ifcommon\\com_blacksquare_"},
		{"type": 5, "id": 20, "parent": 12, "gp": 5, "rect": Rect2i(437, 407, 345, 24), "tex": "interface\\party\\pt_progress_window.ddj"},
		{"type": 10, "id": 21, "parent": 12, "gp": 5, "rect": Rect2i(442, 413, 333, 12), "tex": "interface\\party\\pt_progress.ddj"},
		{"type": 5, "id": 24, "parent": 12, "gp": 5, "rect": Rect2i(625, 336, 48, 48), "tex": "interface\\alchemy\\alcm_slot_open.ddj"},
		{"type": 5, "id": 25, "parent": 12, "gp": 5, "rect": Rect2i(705, 336, 48, 48), "tex": "interface\\alchemy\\alcm_slot_open.ddj"},
		{"type": 18, "id": 28, "name": "CIFSlotWithHelpEx", "parent": 12, "gp": 5, "rect": Rect2i(631, 342, 32, 32)},
		{"type": 18, "id": 29, "name": "CIFSlotWithHelpEx", "parent": 12, "gp": 5, "rect": Rect2i(711, 342, 32, 32)},
		{"type": 1, "id": 282, "parent": 12, "gp": 5, "rect": Rect2i(434, 160, 347, 151), "base": "interface\\frame\\frameg_wnd_"},
		{"type": 18, "id": 18, "name": "CIFPMLEx", "parent": 12, "gp": 5, "rect": Rect2i(503, 177, 264, 112)},
		{"type": 5, "id": 16, "parent": 12, "gp": 5, "rect": Rect2i(445, 172, 48, 48), "tex": "interface\\messagebox\\msgbox_itemwindow.ddj"},
		{"type": 18, "id": 17, "name": "CIFSlotWithHelpEx", "parent": 12, "gp": 5, "rect": Rect2i(451, 179, 32, 32)},
		{"type": 5, "id": 30, "parent": 12, "gp": 5, "rect": Rect2i(467, 336, 48, 48), "tex": "interface\\alchemy\\alcm_slot_open.ddj"},
		{"type": 5, "id": 31, "parent": 12, "gp": 5, "rect": Rect2i(546, 336, 48, 48), "tex": "interface\\alchemy\\alcm_slot_open.ddj"},
		{"type": 18, "id": 26, "name": "CIFSlotWithHelpEx", "parent": 12, "gp": 5, "rect": Rect2i(473, 343, 32, 32)},
		{"type": 18, "id": 27, "name": "CIFSlotWithHelpEx", "parent": 12, "gp": 5, "rect": Rect2i(552, 343, 32, 32)},
		{"type": 18, "id": 28, "name": "CNIFAlchemySubWndType2", "parent": 5, "gp": 168, "rect": Rect2i(435, 160, 343, 312)},
		{"type": 3, "id": 13, "parent": 28, "gp": 5, "rect": Rect2i(434, 159, 347, 120), "base": "interface\\ifcommon\\com_blacksquare_"},
		{"type": 5, "id": 20, "parent": 28, "gp": 5, "rect": Rect2i(437, 406, 345, 24), "tex": "interface\\party\\pt_progress_window.ddj"},
		{"type": 10, "id": 21, "parent": 28, "gp": 5, "rect": Rect2i(442, 412, 333, 12), "tex": "interface\\party\\pt_progress.ddj"},
		{"type": 5, "id": 44, "parent": 28, "gp": 5, "rect": Rect2i(465, 291, 48, 48), "tex": "interface\\alchemy\\alcm_slot_open.ddj"},
		{"type": 5, "id": 45, "parent": 28, "gp": 5, "rect": Rect2i(544, 291, 48, 48), "tex": "interface\\alchemy\\alcm_slot_open.ddj"},
		{"type": 5, "id": 46, "parent": 28, "gp": 5, "rect": Rect2i(622, 291, 48, 48), "tex": "interface\\alchemy\\alcm_slot_open.ddj"},
		{"type": 5, "id": 47, "parent": 28, "gp": 5, "rect": Rect2i(700, 291, 48, 48), "tex": "interface\\alchemy\\alcm_slot_open.ddj"},
		{"type": 5, "id": 48, "parent": 28, "gp": 5, "rect": Rect2i(465, 345, 48, 48), "tex": "interface\\alchemy\\alcm_slot_open.ddj"},
		{"type": 5, "id": 49, "parent": 28, "gp": 5, "rect": Rect2i(544, 345, 48, 48), "tex": "interface\\alchemy\\alcm_slot_open.ddj"},
		{"type": 5, "id": 50, "parent": 28, "gp": 5, "rect": Rect2i(622, 345, 48, 48), "tex": "interface\\alchemy\\alcm_slot_open.ddj"},
		{"type": 5, "id": 51, "parent": 28, "gp": 5, "rect": Rect2i(700, 346, 48, 48), "tex": "interface\\alchemy\\alcm_slot_open.ddj"},
		{"type": 18, "id": 62, "name": "CIFSlotWithHelpEx", "parent": 28, "gp": 5, "rect": Rect2i(472, 352, 32, 32)},
		{"type": 18, "id": 63, "name": "CIFSlotWithHelpEx", "parent": 28, "gp": 5, "rect": Rect2i(551, 352, 32, 32)},
		{"type": 18, "id": 64, "name": "CIFSlotWithHelpEx", "parent": 28, "gp": 5, "rect": Rect2i(629, 352, 32, 32)},
		{"type": 18, "id": 65, "name": "CIFSlotWithHelpEx", "parent": 28, "gp": 5, "rect": Rect2i(707, 297, 32, 32)},
		{"type": 18, "id": 66, "name": "CIFSlotWithHelpEx", "parent": 28, "gp": 5, "rect": Rect2i(472, 297, 32, 32)},
		{"type": 18, "id": 67, "name": "CIFSlotWithHelpEx", "parent": 28, "gp": 5, "rect": Rect2i(551, 297, 32, 32)},
		{"type": 18, "id": 68, "name": "CIFSlotWithHelpEx", "parent": 28, "gp": 5, "rect": Rect2i(629, 297, 32, 32)},
		{"type": 18, "id": 69, "name": "CIFSlotWithHelpEx", "parent": 28, "gp": 5, "rect": Rect2i(707, 353, 32, 32)},
		{"type": 18, "id": 70, "name": "CIFSlotWithHelpEx", "parent": 28, "gp": 5, "rect": Rect2i(451, 178, 32, 32)},
		{"type": 1, "id": 283, "parent": 28, "gp": 5, "rect": Rect2i(434, 159, 347, 120), "base": "interface\\frame\\frameg_wnd_"},
		{"type": 18, "id": 18, "name": "CIFPMLEx", "parent": 28, "gp": 5, "rect": Rect2i(445, 171, 322, 93)},
		{"type": 4, "id": 22, "parent": 5, "gp": 168, "rect": Rect2i(549, 448, 112, 24), "tex": "interface\\ifcommon\\com_mid_button02.ddj"},
		{"type": 1, "id": 72, "name": "CNIFSocketWnd", "parent": 168, "rect": Rect2i(425, 123, 366, 365), "base": "interface\\frame\\frameg01_wnd_"},
		{"type": 2, "id": 71, "parent": 72, "gp": 168, "rect": Rect2i(437, 137, 348, 339), "base": "interface\\ifcommon\\bg_tile\\com_bg_tile_b.ddj"},
		{"type": 5, "id": 55, "parent": 72, "gp": 168, "rect": Rect2i(509, 164, 272, 28), "tex": "interface\\messagebox\\msgbox_stall_title.ddj"},
		{"type": 4, "id": 56, "parent": 72, "gp": 168, "rect": Rect2i(488, 444, 112, 24), "tex": "interface\\ifcommon\\com_mid_button02.ddj", "textid": "UIIT_CTL_SOCKET_BUTTON_MAKE"},
		{"type": 4, "id": 57, "parent": 72, "gp": 168, "rect": Rect2i(620, 444, 112, 24), "tex": "interface\\ifcommon\\com_mid_button02.ddj", "textid": "UIIT_CTL_SOCKET_BUTTON_REMOVE"},
		{"type": 5, "id": 54, "parent": 72, "gp": 168, "rect": Rect2i(449, 151, 48, 48), "tex": "interface\\messagebox\\msgbox_itemwindow.ddj"},
		{"type": 18, "id": 70, "name": "CIFSlotWithHelpEx", "parent": 72, "gp": 168, "rect": Rect2i(454, 157, 32, 32)},
		{"type": 5, "id": 68, "parent": 72, "gp": 168, "rect": Rect2i(515, 169, 252, 19), "color": 0xffffca2a},
		{"type": 5, "id": 69, "parent": 72, "gp": 168, "rect": Rect2i(481, 297, 244, 19)},
		{"type": 5, "id": 78, "parent": 72, "gp": 168, "rect": Rect2i(678, 300, 48, 48), "tex": "interface\\alchemy\\alcm_slot_open.ddj"},
		{"type": 5, "id": 77, "parent": 72, "gp": 168, "rect": Rect2i(588, 300, 48, 48), "tex": "interface\\alchemy\\alcm_slot_open.ddj"},
		{"type": 5, "id": 76, "parent": 72, "gp": 168, "rect": Rect2i(495, 300, 48, 48), "tex": "interface\\alchemy\\alcm_slot_open.ddj"},
		{"type": 5, "id": 210, "parent": 72, "gp": 168, "rect": Rect2i(435, 404, 345, 24), "tex": "interface\\party\\pt_progress_window.ddj"},
		{"type": 10, "id": 211, "parent": 72, "gp": 168, "rect": Rect2i(438, 412, 333, 12), "tex": "interface\\party\\pt_progress.ddj"},
		{"type": 1, "id": 282, "parent": 72, "gp": 168, "rect": Rect2i(438, 224, 349, 162), "base": "interface\\frame\\frameg_wnd_"},
		{"type": 5, "id": 354, "parent": 72, "gp": 168, "rect": Rect2i(455, 258, 309, 17)},
		{"type": 5, "id": 73, "parent": 72, "gp": 168, "rect": Rect2i(503, 308, 32, 32), "tex": "interface\\skill\\skl_mastery_nothing.ddj"},
		{"type": 5, "id": 79, "parent": 72, "gp": 168, "rect": Rect2i(596, 308, 32, 32), "tex": "interface\\skill\\skl_mastery_nothing.ddj"},
		{"type": 5, "id": 80, "parent": 72, "gp": 168, "rect": Rect2i(685, 309, 32, 32), "tex": "interface\\skill\\skl_mastery_nothing.ddj"},
		{"type": 18, "id": 83, "name": "CIFSlotWithHelpEx", "parent": 72, "gp": 168, "rect": Rect2i(502, 306, 32, 32)},
		{"type": 18, "id": 84, "name": "CIFSlotWithHelpEx", "parent": 72, "gp": 168, "rect": Rect2i(593, 307, 32, 32)},
		{"type": 18, "id": 85, "name": "CIFSlotWithHelpEx", "parent": 72, "gp": 168, "rect": Rect2i(684, 306, 32, 32)},
	]

## nifenchantalchemymsgbox.2dt's 10 records in file order.
func _confirm() -> Array:
	return [
		{"type": 0, "id": 172, "name": "CNIFMiniConfirm", "root": true, "rect": Rect2i(471, 243, 454, 212), "base": "interface\\frame\\mframe_wnd_"},
		{"type": 2, "id": 2, "parent": 172, "rect": Rect2i(480, 280, 432, 161), "base": "interface\\ifcommon\\bg_tile\\com_bg_tile_b.ddj"},
		{"type": 3, "id": 5, "parent": 172, "rect": Rect2i(484, 284, 426, 115), "base": "interface\\ifcommon\\com_blacksquare_"},
		{"type": 2, "id": 6, "parent": 172, "rect": Rect2i(487, 286, 422, 111), "base": "interface\\ifcommon\\bg_tile\\com_bg_tile_e.ddj"},
		{"type": 5, "id": 7, "parent": 172, "rect": Rect2i(518, 305, 48, 48), "tex": "interface\\messagebox\\msgbox_itemwindow.ddj"},
		{"type": 7, "id": 8, "parent": 172, "rect": Rect2i(579, 308, 303, 39)},
		{"type": 1, "id": 10, "parent": 172, "rect": Rect2i(479, 280, 439, 167), "base": "interface\\frame\\frameg01_wnd_"},
		{"type": 4, "id": 3, "parent": 172, "rect": Rect2i(618, 409, 76, 24), "tex": "interface\\ifcommon\\com_button.ddj"},
		{"type": 4, "id": 4, "parent": 172, "rect": Rect2i(706, 409, 76, 24), "tex": "interface\\ifcommon\\com_button.ddj"},
		{"type": 18, "id": 9, "name": "CIFSlotWithHelpEx", "parent": 172, "rect": Rect2i(524, 312, 32, 32)},
	]

func _text_table() -> UiTextTable:
	var rows := PackedStringArray()
	for pair in [["UIIT_CTL_ALCHEMYBOX", "tt alchemy"], ["UIIT_CTL_WK_ALCHEMY", "tt wk alchemy"],
			["UIIT_CTL_SOCKET_TAP_TITLE", "tt socket"], ["UIIT_STT_SOCKET_TAP", "tt socket tip"],
			["SN_TAB_ALCHEMY", "tt alchemy tip"],
			["UIIT_CTL_ALCHEMYBOX_TAP_DISJOINTING", "tt tab 9"], ["UIIT_CTL_ALCHEMYBOX_TAP_DISMANTLING", "tt tab 10"],
			["UIIT_CTL_ALCHEMYBOX_TAP_MANUFACTURING", "tt tab 7"], ["UIIT_CTL_ALCHEMYBOX_TAP_STRENGTHENING", "tt tab 8"],
			["UIIT_CTL_ALCHEMYBOX_BUTTON_DISJOINTING_ALLSLOT", "tt act 0"], ["UIIT_CTL_ALCHEMYBOX_BUTTON_DISMANTLING", "tt act 1"],
			["UIIT_CTL_ALCHEMYBOX_BUTTON_MANUFACTURING", "tt act 2"], ["UIIT_CTL_ALCHEMYBOX_BUTTON_STRENGTHENING", "tt act 3"],
			["UIIT_STT_ALCHEMYBOX_TIP_DISJOINTING_ALLSLOT_BUTTON", "tt act tip 0"], ["UIIT_STT_ALCHEMYBOX_TIP_DISMANTLING_BUTTON", "tt act tip 1"],
			["UIIT_STT_ALCHEMYBOX_TIP_MANUFACTURING_BUTTON", "tt act tip 2"], ["UIIT_STT_ALCHEMYBOX_TIP_STRENGTHENING_BUTTON", "tt act tip 3"],
			["UIIT_STT_SOCKET_HELP_SOCKET_DEFAULT", "tt socket help"],
			["UIIT_STT_SOCKET_BUTTON_SOCKET_MAKE", "tt make tip"], ["UIIT_STT_SOCKET_BUTTON_SOCKET_REMOVE", "tt remove tip"],
			["UIIT_CTL_SOCKET_BUTTON_MAKE", "tt make"], ["UIIT_CTL_SOCKET_BUTTON_REMOVE", "tt remove"],
			["UIIT_STT_INVENTORY", "tt bag"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

# --- the main popup, for the inventory the window opens ---------------------

func _control(control_name: String, type: String, id: int, rect: String) -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"\"\n\t}\n" % [control_name, type, id, rect]

func _layout(body: String) -> String:
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" + body + "}\n"

func _mainpopup() -> String:
	return _layout(_control("GDR_SKILL", "CIFSkill", 73, "13,63,364,333")
		+ _control("GDR_EQUIPMENT", "CIFEquipment", 71, "198,41,178,355")
		+ _control("GDR_INVENTORY", "CIFInventory", 70, "13,63,176,333"))

func _registry() -> String:
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" \
		+ _entry("GDR_MAINPOPUP", "CIFMainPopup", 25, "595,262,388,408") \
		+ _entry("GDR_EXCHANGE", "CIFExchange", 26, "200,200,254,361") + "}\n"

func _entry(entry_name: String, type: String, id: int, rect: String) -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"interface\\\\frame\\\\mframe_wnd_\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"\"\n\t}\n" % [entry_name, type, id, rect]

func _ifdef_key(path: String, defines: Array) -> String:
	return "%s%s%s" % [path, char(1), char(2).join(PackedStringArray(defines))]

func _tex(builder: UiBuilder, path: String, size: Vector2i) -> void:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.4, 0.3, 0.2, 1.0))
	var t := ImageTexture.create_from_image(img)
	t.resource_name = path
	(builder.get("_texture_cache") as Dictionary)[path.to_lower()] = t

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, _text_table())
	var Reader = load(READER_PATH)
	var cache = builder.get("_twodt_cache")
	if Reader != null and cache is Dictionary:
		cache["res_ui\\nifenchantwnd.2dt"] = Reader.parse(_file(_enchant()))
		cache["res_ui\\nifenchantalchemymsgbox.2dt"] = Reader.parse(_file(_confirm()))
	var layouts: Dictionary = builder.get("_layout_cache")
	layouts[_ifdef_key("resinfo\\ifmainpopup.txt", ["APPLY_MENTOR_SYSTEM"])] = UiLayoutParser.parse(_mainpopup(), true, PackedStringArray(["APPLY_MENTOR_SYSTEM"]))
	layouts["resinfo\\ifinventory.txt"] = UiLayoutParser.parse(_layout(_control("GDR_INVENTORY_FRAME", "CIFFrame", 1, "0,0,176,308")))
	layouts["resinfo\\ifequipment.txt"] = UiLayoutParser.parse(_layout(_control("GDR_EQ_FRAME", "CIFFrame", 4, "0,0,178,355")))
	layouts["resinfo\\ifskill.txt"] = UiLayoutParser.parse(_layout(_control("GDR_SKILL_FRAME", "CIFFrame", 1, "0,0,364,333")))
	# The exchange window's layout, so the first open("exchange") builds a
	# fresh window (the case the client's show path must still catch).
	layouts["resinfo\\ifexchange.txt"] = UiLayoutParser.parse(_layout(_control("GDR_EXCHANGE_BG", "CIFStatic", 1, "10,40,234,300")))
	builder.set("_window_registry", UiLayoutParser.parse(_registry()))
	builder.set("_window_registry_loaded", true)
	builder.set("_window_registry_data", _registry())
	_tex(builder, CLOSE, Vector2i(16, 16))
	_tex(builder, ACTION_DDJ, Vector2i(112, 24))
	_tex(builder, ACTION_DISABLED_DDJ, Vector2i(112, 24))
	for base in TAB_BASES:
		for piece in ["on", "off"]:
			_tex(builder, base + piece + ".ddj", Vector2i(48, 24))
	return builder

# --- helpers -----------------------------------------------------------------

func _path(root: Node, ids: Array) -> Control:
	var at: Node = root
	for id in ids:
		var next: Node = null
		if at != null:
			for c in at.get_children():
				if c.has_meta("twodt_id") and int(c.get_meta("twodt_id")) == int(id):
					next = c
					break
		at = next
	return at as Control

func _rect(window: Control, node: Control) -> Rect2:
	if window == null or node == null:
		return Rect2(-1, -1, -1, -1)
	return Rect2(node.get_global_rect().position - window.get_global_rect().position, node.size)

func _art(node: Control) -> String:
	var b := node as TextureButton
	if b == null or b.texture_normal == null:
		return "<none>"
	return b.texture_normal.resource_name

func _text(node: Node) -> String:
	var l := node.get_node_or_null("Text") as Label if node != null else null
	return l.text if l != null else "<none>"

func _caption(window: Control) -> String:
	var bar := window.get_node_or_null("TitleBar") as Label if window != null else null
	return bar.text if bar != null else "<no caption>"

func _key(panels: Node, keycode: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = true
	panels.call("_unhandled_key_input", ev)

func _window(panels: Node) -> Control:
	if not panels.has_method("alchemy_window"):
		return null
	return panels.call("alchemy_window") as Control

# --- the checks --------------------------------------------------------------

func _run() -> void:
	await process_frame
	get_root().size = Vector2i(1152, 648)
	await process_frame
	var script := load(ALCHEMY_PATH) as GDScript
	if script != null:
		script.call("reset_tab_mode")
	var builder := _builder()
	var panels_script := load(PANELS_PATH) as GDScript
	var panels: Control = panels_script.new(builder)
	get_root().add_child(panels)
	await process_frame
	# Each section below stands on its own: one that needs the window says
	# so in a FAIL line when there is none and the next section still runs.
	await _check_first_state(panels, panels_script)
	await _check_mode_and_rebuild(panels, script)
	await _check_side_menu(panels)
	await _check_closing(panels)
	await _check_exchange(panels)
	await _check_escape_order(panels)
	await _check_small_view(panels)
	panels.queue_free()

## Y from closed, and the window as its OnCreates leave it.
func _check_first_state(panels: Control, panels_script: GDScript) -> void:
	var spec: Array = (panels_script.get_script_constant_map().get("PANELS", {}) as Dictionary).get("alchemy", [])
	_check(spec.size() == 2 and spec[0] == "res_ui\\nifenchantwnd.2dt",
		"PANELS[\"alchemy\"] is res_ui\\nifenchantwnd.2dt (got %s)" % [spec])
	# The key is the key table's (KeyMap, round 608): slot 24, Y.
	var keymap := load("res://scripts/ui/keymap.gd") as GDScript
	var slot = keymap.call("slot_for_action", "panel:alchemy") if keymap != null else null
	_check(slot != null and int(slot["slot"]) == 24 and int(slot["key"]) == KEY_Y,
		"the key table's slot 24 opens the alchemy window on Y (got %s)" % [slot])
	_key(panels, KEY_Y)
	await process_frame
	var window := _window(panels)
	var root: Control = window.get("panel_root") if window != null else null
	_check(root != null and str(root.get_meta("twodt_class", "")) == "CNIFEnchantWnd",
		"Y opens CNIFEnchantWnd from res_ui\\nifenchantwnd.2dt (0x780a65 -> 0x798e20(1))")
	# 0x79af20: the main popup on its inventory tab. Asked of HudPanels, so it
	# runs with or without the new window.
	_check(bool(panels.call("is_open", "inventory")), "opening it shows the main popup on its inventory tab (0x79af20)")
	if root == null:
		_check(false, "the first-state checks need the window (none was built)")
		return
	_check(window.visible and window.size == Vector2(389, 421), "it is shown, 389x421 (got %s)" % window.size)
	_check(window.position == Vector2(50, 39),
		"at (0x32, 648 - 0x261) = (50, 39) in the 1152x648 view (got %s)" % window.position)
	var bar := window.get_node_or_null("TitleBar") as Control
	_check(bar != null and bar.position == Vector2(10, 12) and bar.size.x == 368,
		"the caption is at (10, 12), 368 wide (got %s)" % (_rect(window, bar) if bar else null))
	_check(_caption(window) == "tt alchemy", "captioned UIIT_CTL_ALCHEMYBOX (got '%s')" % _caption(window))
	var close := window.get_node_or_null("CloseButton") as Control
	_check(close != null and _rect(window, close) == Rect2(363, 10, 16, 16),
		"the close button is (363, 10) (got %s)" % (_rect(window, close) if close else null))
	_check(_rect(window, _path(root, [2])) == Rect2(-16, 62, 24, 288), "the menu strip is at (-16, 62) 24x288 (got %s)" % _rect(window, _path(root, [2])))
	_check(_rect(window, _path(root, [4])) == Rect2(-36, 79, 40, 40) and _rect(window, _path(root, [3])) == Rect2(-36, 121, 40, 40),
		"the alchemy button at (-36, 79), the socket button at (-36, 121) (got %s, %s)" % [_rect(window, _path(root, [4])), _rect(window, _path(root, [3]))])
	_check(_path(root, [4]).tooltip_text == "tt alchemy tip" and _path(root, [3]).tooltip_text == "tt socket tip",
		"their hover strings are SN_TAB_ALCHEMY and UIIT_STT_SOCKET_TAP")
	var alchemy := _path(root, [5])
	_check(alchemy.visible and _rect(window, alchemy) == Rect2(12, 64, 366, 343),
		"the alchemy pane (5) is shown at (12, 64) 366x343 (got %s)" % _rect(window, alchemy))
	_check(not _path(root, [72]).visible, "the socket pane (72) is hidden")
	_check(_path(root, [5, 12]).visible and not _path(root, [5, 28]).visible,
		"the tab byte starts at 3: the pane of tabs 7 and 8 (12) shown, 28 hidden")
	_check(_art(_path(root, [5, 8])) == TAB_BASES[3] + "on.ddj", "tab 8 draws its on piece (got %s)" % _art(_path(root, [5, 8])))
	var offs := []
	for id in [7, 9, 10]:
		offs.append(_art(_path(root, [5, id])))
	_check(offs == [TAB_BASES[2] + "off.ddj", TAB_BASES[0] + "off.ddj", TAB_BASES[1] + "off.ddj"],
		"tabs 7, 9 and 10 draw their off pieces (got %s)" % [offs])
	var tips := []
	for id in [9, 10, 7, 8]:
		tips.append(_path(root, [5, id]).tooltip_text)
	_check(tips == ["tt tab 9", "tt tab 10", "tt tab 7", "tt tab 8"], "the tabs carry their hover strings (got %s)" % [tips])
	var action := _path(root, [5, 22]) as BaseButton
	_check(action != null and _rect(window, action) == Rect2(136, 366, 112, 24), "button 22 is at (136, 366) 112x24")
	_check(action != null and _text(action) == "tt act 3" and action.tooltip_text == "tt act tip 3" and action.disabled,
		"button 22: the reinforce caption, its hover string, disabled (got '%s', '%s', %s)" % [_text(action), action.tooltip_text if action else "", action.disabled if action else null])
	var confirm := _path(root, [5, 172])
	_check(confirm != null and not confirm.visible and str(confirm.get_meta("twodt_class", "")) == "CNIFMiniConfirm",
		"the confirm box (172) is built inside the alchemy pane, hidden")

## A tab click, the mode that outlives the window, Y from open, Y again.
func _check_mode_and_rebuild(panels: Control, script: GDScript) -> void:
	var window := _window(panels)
	var root: Control = window.get("panel_root") if window != null else null
	if root == null:
		_check(false, "the tab checks need the window (none was built)")
		return
	(_path(root, [5, 9]) as BaseButton).pressed.emit()
	_check(_path(root, [5, 28]).visible and not _path(root, [5, 12]).visible, "tab 9 shows pane 28 and hides 12")
	var action := _path(root, [5, 22]) as BaseButton
	_check(_text(action) == "tt act 0" and action.tooltip_text == "tt act tip 0" and action.disabled,
		"and its manager's caption and hover string go on button 22, still disabled (got '%s')" % _text(action))
	_check(script != null and int(script.call("current_tab_mode")) == 0, "the tab byte is 0")
	window.position = Vector2(300, 200)
	_key(panels, KEY_Y)
	await process_frame
	_check(_window(panels) == null and not is_instance_valid(window),
		"Y again destroys the window (0x798e20(0)), not hides it")
	_key(panels, KEY_Y)
	await process_frame
	window = _window(panels)
	root = window.get("panel_root") if window != null else null
	_check(root != null and _path(root, [5, 28]).visible and not _path(root, [5, 12]).visible
			and _art(_path(root, [5, 9])) == TAB_BASES[0] + "on.ddj",
		"rebuilt, it opens on tab 9: the byte outlived the window")
	_check(window != null and window.position == Vector2(50, 39), "and where the OnCreate puts it, not where it was dragged (got %s)" % (window.position if window else null))

## The side menu: socket pane and back.
func _check_side_menu(panels: Control) -> void:
	var window := _window(panels)
	var root: Control = window.get("panel_root") if window != null else null
	if root == null:
		_check(false, "the side-menu checks need the window (none was built)")
		return
	(_path(root, [3]) as BaseButton).pressed.emit()
	var socket := _path(root, [72])
	_check(socket.visible and not _path(root, [5]).visible, "the socket button shows the socket pane and hides the alchemy pane")
	_check(_caption(window) == "tt socket", "captioned UIIT_CTL_SOCKET_TAP_TITLE (got '%s')" % _caption(window))
	_check(_text(_path(root, [72, 354])) == "tt socket help" and _text(_path(root, [72, 68])) == " ",
		"the socket help and a blank note")
	var make := _path(root, [72, 56]) as BaseButton
	var remove := _path(root, [72, 57]) as BaseButton
	_check(make.disabled and remove.disabled and make.tooltip_text == "tt make tip" and remove.tooltip_text == "tt remove tip",
		"make and remove are disabled, with their hover strings")
	_check(_text(make) == "tt make" and _text(remove) == "tt remove", "and their record captions")
	(_path(root, [4]) as BaseButton).pressed.emit()
	_check(_path(root, [5]).visible and not socket.visible and _caption(window) == "tt wk alchemy",
		"the alchemy button goes back, captioned UIIT_CTL_WK_ALCHEMY (got '%s')" % _caption(window))

## The close button, and the menu's open-only item.
func _check_closing(panels: Control) -> void:
	var window := _window(panels)
	var close_btn: BaseButton = null
	if window != null:
		close_btn = window.get_node_or_null("CloseButton") as BaseButton
	var had_close := close_btn != null
	if had_close:
		close_btn.pressed.emit()
	await process_frame
	_check(had_close and _window(panels) == null, "the close button destroys it (vslot_043 -> 0x798e20(0))")
	if panels.has_method("menu_action"):
		panels.call("menu_action", "alchemy")
		panels.call("menu_action", "alchemy")
	_check(_window(panels) != null, "the menu's alchemy item opens it, and a second press leaves it open (0x798e20(1))")
	panels.call("close", "alchemy")
	await process_frame

## The exchange window (a real one, built from the fixture): the first show
## of the session destroys the alchemy window (0x7b3a37..0x7b3a4d), a later
## show does too, and while it is up Y is refused (0x77c941..0x77c95c).
func _check_exchange(panels: Control) -> void:
	_key(panels, KEY_Y)
	await process_frame
	_check(_window(panels) != null, "Y opens the window before the exchange is shown")
	var exchange := panels.call("open", "exchange") as Control
	await process_frame
	_check(exchange != null, "the exchange window builds from the fixture")
	_check(_window(panels) == null, "the FIRST exchange show destroys the alchemy window (0x7b3a4d)")
	_key(panels, KEY_Y)
	await process_frame
	_check(_window(panels) == null, "Y does nothing while the exchange window is up")
	if exchange != null:
		exchange.hide()
	_key(panels, KEY_Y)
	await process_frame
	_check(_window(panels) != null, "and opens once it is gone")
	panels.call("open", "exchange")
	await process_frame
	_check(_window(panels) == null, "a later exchange show destroys it too")
	if exchange != null:
		exchange.hide()

## A stand-in window registered under a panel id, so the order runs without
## those windows' layouts.
func _stand_in(panels: Control, panel_id: String) -> HudWindow:
	var windows = panels.get("_windows")
	var existing: HudWindow = (windows as Dictionary).get(panel_id) if windows is Dictionary else null
	if existing != null:
		return existing
	var w := HudWindow.new()
	w.name = "Window_" + panel_id
	panels.add_child(w)
	if windows is Dictionary:
		(windows as Dictionary)[panel_id] = w
	return w

## Escape's order, as 0x79d620 reads: System, the world map, the storage (the
## NPC-flag branch), the NPC window, the exchange, the alchemy window, then
## the rest (the main popup), topmost first (ours). Every window is opened and
## stacked in the reverse of that order -- the popup on top, System at the
## bottom -- so the topmost rule alone would close them backwards, and any
## two neighbours swapped in the code change the sequence.
func _check_escape_order(panels: Control) -> void:
	var names := ["system", "worldmap", "storage", "npctalk", "exchange", "alchemy", "inventory"]
	var shown := {}
	for id in ["system", "storage", "npctalk", "exchange"]:
		shown[id] = _stand_in(panels, id)
	var map := Control.new()
	map.name = "WorldMapStandIn"
	panels.add_child(map)
	panels.set("world_map", map)
	shown["worldmap"] = map
	# The alchemy window opens before the exchange shows (the exchange up
	# would refuse it); it opens the popup itself.
	for id in ["storage", "npctalk", "exchange"]:
		(shown[id] as Control).hide()
	_key(panels, KEY_Y)
	await process_frame
	var popup := panels.call("open", "inventory") as Control
	# Bottom to top: System, map, storage, NPC talk, exchange, alchemy, popup.
	for id in ["system", "worldmap", "storage", "npctalk", "exchange"]:
		(shown[id] as Control).show()
		(shown[id] as Control).move_to_front()
	var alchemy := _window(panels)
	if alchemy != null:
		alchemy.move_to_front()
	if popup != null:
		popup.move_to_front()
	var closed := []
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	for i in names.size():
		var before := _open_set(panels, shown)
		panels.call("_unhandled_key_input", esc)
		await process_frame
		var after := _open_set(panels, shown)
		var gone := []
		for n in names:
			if before.has(n) and not after.has(n):
				gone.append(n)
		closed.append(gone[0] if gone.size() == 1 else str(gone))
	_check(closed == names,
		"Escape closes System, the map, storage, NPC talk, exchange, alchemy, then the popup, one a press (got %s)" % [closed])
	panels.set("world_map", null)
	map.queue_free()

func _open_set(panels: Control, shown: Dictionary) -> Dictionary:
	var out := {}
	for id in shown:
		if (shown[id] as Control).visible:
			out[id] = true
	if _window(panels) != null:
		out["alchemy"] = true
	if bool(panels.call("is_open", "inventory")):
		out["inventory"] = true
	return out

## Kept on screen at a small view (ours): 432 - 609 is below zero.
func _check_small_view(panels: Control) -> void:
	get_root().size = Vector2i(768, 432)
	await process_frame
	panels.call("close", "alchemy")
	_key(panels, KEY_Y)
	var window := _window(panels)
	_check(window != null and window.position == Vector2(50, 0), "at 768x432 it is kept at (50, 0) (got %s)" % (window.position if window else null))
