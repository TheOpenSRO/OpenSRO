extends SceneTree

## Round 795: the pet / COS interface (HudCos and its pieces) against layout
## fixtures that carry the authored names, IDs and rects of the real
## `resinfo` controls (client_ui.md section 1, as dumped on the box) and no
## art -- never game data. Text resolves to the stock English fallbacks.
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_cos_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

# --- fixtures --------------------------------------------------------------------

func _c(n: String, type: String, id: int, rect: String, ddj: String = "", text: String = "", extra: String = "") -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"%s\"\n%s\t}\n" % [
		n, type, ddj.replace("\\", "\\\\"), id, rect, text, extra]

func _sec(sec_name: String, body: String) -> String:
	return "Section = %s,\"0,0,0,0\",\"0\"\n{\n%s}\n" % [sec_name, body]

func _file(sections: String) -> String:
	return "Interface Text\n\n" + sections

func _ifcos() -> String:
	return _file(_sec("Create", _c("GDR_COS_IFRAME", "CIFFrame", 0, "12,66,331,314", "interface\\inventory\\int_window_"))
		+ _sec("COSInfoWnd", _c("GDR_COS_INFO", "CIFCOSInfo", 121, "12,66,331,314"))
		+ _sec("COSInventoryWnd", _c("GGDR_COS_INVENTORY", "CIFCOSInventory", 122, "12,66,331,314"))
		+ _sec("COSSetupWnd", _c("GDR_COS_SETUP", "CIFCOSSetup", 123, "12,66,331,314")))

func _ifcosinfo() -> String:
	var b := ""
	for spec in [["GDR_COS_INFO_NONE", "CIFStatic", 100, "94,191,194,11"],
			["GDR_COS_INFO_MAGDEF_DATA", "CIFStatic", 78, "246,258,59,11"], ["GDR_COS_INFO_MAGATT_DATA", "CIFStatic", 77, "246,238,59,11"],
			["GDR_COS_INFO_PARRY_DATA", "CIFStatic", 76, "246,218,59,11"], ["GDR_COS_INFO_MAGDEF_STA", "CIFStatic", 73, "174,258,59,11"],
			["GDR_COS_INFO_MAGATT_STA", "CIFStatic", 72, "174,238,59,11"], ["GDR_COS_INFO_PARRY_STA", "CIFStatic", 71, "174,218,59,11"],
			["GDR_COS_INFO_PHYDEF_DATA", "CIFStatic", 68, "108,258,59,11"], ["GDR_COS_INFO_PHYATT_DATA", "CIFStatic", 67, "108,238,59,11"],
			["GDR_COS_INFO_HIT_DATA", "CIFStatic", 66, "108,218,59,11"], ["GDR_COS_INFO_LEVEL_DATA", "CIFStatic", 65, "108,198,59,11"],
			["GDR_COS_INFO_PHYDEF_STA", "CIFStatic", 63, "36,258,59,11"], ["GDR_COS_INFO_PHYATT_STA", "CIFStatic", 62, "36,238,59,11"],
			["GDR_COS_INFO_HIT_STA", "CIFStatic", 61, "36,218,59,11"], ["GDR_COS_INFO_LEVEL_STA", "CIFStatic", 60, "36,198,59,11"],
			["GDR_COS_INFO_TIME", "CIFStatic", 52, "106,88,188,11"], ["GDR_COS_INFO_TIME_STA", "CIFStatic", 51, "29,88,63,11"],
			["GDR_COS_INFO_TIME_WND", "CIFStatic", 50, "26,80,280,28", "interface\\pet\\pt_time.ddj"],
			["GDR_COS_INFO_EXP_PERCENT", "CIFStatic", 45, "82,149,214,11"], ["GDR_COS_INFO_EXP_STA", "CIFStatic", 44, "36,149,28,11"],
			["GDR_COS_INFO_HGP_PERCENT", "CIFStatic", 43, "82,121,214,11"], ["GDR_COS_INFO_HGP_STA", "CIFStatic", 42, "36,121,28,11"],
			["GDR_COS_INFO_HP_PERCENT", "CIFStatic", 41, "82,90,214,11"], ["GDR_COS_INFO_HP_STA", "CIFStatic", 40, "36,91,28,11"],
			["GDR_COS_INFO_EXP_GAUGE", "CIFGauge", 37, "75,148,228,12", "interface\\pet\\pt_exp.ddj"],
			["GDR_COS_INFO_HGP_GAUGE", "CIFGauge", 36, "75,119,228,12", "interface\\pet\\pt_hgp.ddj"],
			["GDR_COS_INFO_HP_GAUGE", "CIFGauge", 35, "75,89,228,12", "interface\\pet\\pt_hp.ddj"],
			["GDR_COS_INFO_STAT_EXP_WND", "CIFStatic", 32, "24,142,284,24", "interface\\pet\\pt_stat_window.ddj"],
			["GDR_COS_INFO_STAT_HGP_WND", "CIFStatic", 31, "24,113,284,24", "interface\\pet\\pt_stat_window.ddj"],
			["GDR_COS_INFO_STAT_HP_WND", "CIFStatic", 30, "24,83,284,24", "interface\\pet\\pt_stat_window.ddj"],
			["GDR_COS_INFO_NAME", "CIFStatic", 27, "45,47,164,11"],
			["GDR_COS_INFO_NAME_BTN", "CIFButton", 26, "232,41,76,24", "interface\\ifcommon\\com_mall_button.ddj"],
			["GDR_COS_INFO_BLACKBOX_NAME", "CIFStatic", 25, "25,41,200,24", "interface\\pet\\pt_messagebox.ddj"],
			["GDR_COS_GFRAME", "CIFFrame", 10, "8,9,315,297", "interface\\frame\\frameg_wnd_"],
			["GDR_COS_BG_01", "CIFNormalTile", 5, "32,25,267,265", "interface\\ifcommon\\bg_tile\\com_bg_tile_b.ddj"]]:
		b += _c(spec[0], spec[1], spec[2], spec[3], spec[4] if spec.size() > 4 else "")
	return _file(_sec("Create", b))

func _ifcosinventory() -> String:
	var create := _c("GDR_COS_INV_SPIN_PAGE", "CIFSpinButtonCtrl", 17, "140,271,52,18") \
		+ _c("GDR_COS_INV_STRETCH", "CIFStretchWnd", 16, "37,55,256,148", "interface\\ifcommon\\lattice_window\\com_lattice_outline_") \
		+ _c("GDR_COS_INV_LAT", "CIFLattice", 15, "41,59,252,144", "interface\\ifcommon\\lattice_window\\com_lattice_") \
		+ _c("GDR_COS_INV_NAME", "CIFStatic", 6, "49,30,237,12") \
		+ _c("GDR_COS_INV_INNER_BOX", "CIFFrame", 4, "21,27,290,235", "interface\\option\\opt_inner_box_") \
		+ _c("GDR_COS_INV_BG", "CIFNormalTile", 3, "32,25,267,265", "interface\\ifcommon\\bg_tile\\com_bg_tile_b.ddj") \
		+ _c("GDR_COS_INV_GFRAME", "CIFFrame", 2, "8,9,315,297", "interface\\frame\\frameg_wnd_")
	var trade := _c("GDR_COS_INV_ALLSELL_BTN", "CIFButton", 35, "230,268,76,24", "interface\\ifcommon\\com_button.ddj")
	for i in 5:
		trade += _c("GDR_COS_INV_TRADE_LEVEL_%d" % (5 - i), "CIFStatic", 30 - i, "%d,239,12,12" % (171 - 12 * i), "interface\\ifcommon\\com_star.ddj")
	trade += _c("GDR_COS_INV_TOTAL_GOLD", "CIFStatic", 23, "159,216,91,12")
	return _file(_sec("Create", create) + _sec("TradeInfo", trade))

func _ifcossetup() -> String:
	var b := _c("GDR_COS_SETUP_CANCEL_BTN", "CIFButton", 41, "171,263,76,24", "interface\\ifcommon\\com_button.ddj") \
		+ _c("GDR_COS_SETUP_OK_BTN", "CIFButton", 40, "83,263,76,24", "interface\\ifcommon\\com_button.ddj") \
		+ _c("GDR_COS_SETUP_TARGET_CHECKBOX_3", "CIFCheckBox", 27, "205,224,16,16", "interface\\ifcommon\\com_checkbutton_off.ddj") \
		+ _c("GDR_COS_SETUP_TARGET_CHECKBOX_2", "CIFCheckBox", 26, "108,224,16,16", "interface\\ifcommon\\com_checkbutton_off.ddj") \
		+ _c("GDR_COS_SETUP_TARGET_CHECKBOX_1", "CIFCheckBox", 25, "37,224,16,16", "interface\\ifcommon\\com_checkbutton_off.ddj") \
		+ _c("GDR_COS_SETUP_SCOPE_RADIOBTN", "CIFRadioButton", 22, "37,150,260,16") \
		+ _c("GDR_COS_SETUP_ONOFF_RADIOBTN", "CIFRadioButton", 20, "37,78,260,16") \
		+ _c("GDR_COS_SETUP_INNER_BOX", "CIFFrame", 3, "11,11,308,291", "interface\\option\\opt_inner_box_")
	return _file(_sec("Create", b))

func _ifcosstatus() -> String:
	return _file(_sec("Create", _c("GDR_COSSTAT_SGAUGE", "CIFGauge", 13, "4,56,36,4", "interface\\animal\\am_hgp.ddj")
		+ _c("GDR_COSSTAT_HP", "CIFGauge", 12, "4,47,36,4", "interface\\animal\\am_hp.ddj")
		+ _c("GDR_COSSTAT_ICON", "CIFSlotWithHelp", 11, "6,7,32,32")
		+ _c("GDR_COSSTAT_SLOT_WND", "CIFWnd", 7, "0,0,44,56", "interface\\animal\\am_window.ddj")
		+ _c("GDR_COSSTAT_SELECT", "CIFWnd", 5, "-11,-11,65,77", "icon\\etc\\cos_outline_2.ddj")))

func _ifcoscommand() -> String:
	return _file(_sec("Create", _c("GDR_COSCMD_OPENCLOSE", "CIFButton", 3, "5,16,16,16", "interface\\animal\\am_ctrl_close.ddj")
		+ _c("GDR_COSCMD_BOARD", "CIFStatic", 2, "0,11,36,28", "interface\\animal\\am_ctrl_tab.ddj")))

func _ifpetminiinfo() -> String:
	return _file(_sec("Create", _c("GDR_PET_MINI_BUFF", "CIFBuffViewer", 30, "32,39,0,0")
		+ _c("GDR_PET_MINI_PICTURE", "CIFStaticWithPictureClip", 20, "4,4,32,32")
		+ _c("GDR_PET_MINI_TXT_LEVEL", "CIFStatic", 16, "118,7,34,13")
		+ _c("GDR_PET_MINI_TXT_NAME", "CIFStatic", 15, "44,7,73,13")
		+ _c("GDR_PET_MINI_GAUGE_HGP", "CIFGauge", 11, "41,29,112,8", "interface\\playerminiinfo\\pmi_pet_hgp.ddj")
		+ _c("GDR_PET_MINI_GAUGE_HP", "CIFGauge", 10, "41,23,112,8", "interface\\playerminiinfo\\pmi_pet_hp.ddj")
		+ _c("GDR_PET_MINI_EFFECT_HP", "CIFStatic", 100, "42,24,107,32", "interface\\playerminiinfo\\pet_hp_effect_caution.ddj")))

func _ifplayerminiinfo() -> String:
	return _file(_sec("Create", _c("GDR_PMI_PET_MINI_INFO", "CIFPetMiniInfo", 100, "53,55,154,40", "interface\\ifcommon\\window_all.ddj",
		"", "\t\tUV_LT=POINT,\"0.846679,0.138671\"\n\t\tUV_RB=POINT,\"0.997070,0.216796\"\n")))

func _ifmessagebox() -> String:
	return _file(_sec("Create", _c("GDR_MSGBOX_BG", "CIFNormalTile", 0, "16,40,284,122", "interface\\ifcommon\\bg_tile\\com_bg_tile_b.ddj"))
		+ _sec("MsgBoxSimple", _c("GDR_SIMPLE_BTN_CANCEL", "CIFButton", 253, "152,99,76,24", "interface\\ifcommon\\com_button.ddj", "UIIT_CTL_NO")
			+ _c("GDR_SIMPLE_BTN_OK", "CIFButton", 252, "72,99,76,24", "interface\\ifcommon\\com_button.ddj", "UIIT_CTL_YES")
			+ _c("GDR_SIMPLE_TEXTBOX_MESSAGE", "CIFTextBox", 251, "0,52,240,14"))
		+ _sec("MsgBoxINIF", _c("GDR_MBIN_BTN_CERTIFY", "CIFButton", 202, "112,99,76,24", "interface\\ifcommon\\com_button.ddj", "UIIT_CTL_CONFIRM")
			+ _c("GDR_MBIN_BTN_CANCEL", "CIFButton", 201, "152,99,76,24", "interface\\ifcommon\\com_button.ddj", "UIIT_CTL_NO")
			+ _c("GDR_MBIN_BTN_OK", "CIFButton", 200, "72,99,76,24", "interface\\ifcommon\\com_button.ddj", "UIIT_CTL_YES")
			+ _c("GDR_MBIN_STATIC_MESSAGE2", "CIFStatic", 2, "6,70,300,12")
			+ _c("GDR_MBIN_STATIC_MESSAGE1", "CIFStatic", 1, "0,52,300,12"))
		+ _sec("MsgBoxInsertMsg", _c("GDR_MB_INSERT_MSG_BTN_CANC", "CIFButton", 206, "216,104,76,24", "interface\\ifcommon\\com_button.ddj", "UIIT_CTL_CANCEL")
			+ _c("GDR_MB_INSERT_MSG_BTN_OK", "CIFButton", 205, "128,104,76,24", "interface\\ifcommon\\com_button.ddj", "UIIT_CTL_CONFIRM")
			+ _c("GDR_MB_INSERT_MSG_EDIT", "CIFEdit", 15, "9,62,100,20")
			+ _c("GDR_MB_INSERT_MSG_EDIT_BG", "CIFNormalTile", 12, "13,70,396,24", "interface\\ifcommon\\bg_tile\\com_bg_tile_e.ddj")
			+ _c("GDR_MB_INSERT_MSG_EDIT_FRAME", "CIFFrame", 11, "9,66,400,28", "interface\\frame\\frame_msg_")
			+ _c("GDR_MB_INSERT_MSG_TITLE", "CIFStatic", 10, "0,48,420,12", "", "UIIT_STT_INSERT_OWNER_MESSAGE")))

func _registry() -> String:
	return _file(_sec("Create", _c("GDR_COS_MANAGER", "CIFCOSManager", 39, "0,0,0,0"))
		+ _sec("COSWnd", _c("GDR_COS_WND", "CIFCOS", 120, "0,0,355,390", "interface\\frame\\mframe_wnd_")))

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, null)
	var cache: Dictionary = builder.get("_layout_cache")
	for pair in [["resinfo\\ifcos.txt", _ifcos()], ["resinfo\\ifcosinfo.txt", _ifcosinfo()],
			["resinfo\\ifcosinventory.txt", _ifcosinventory()], ["resinfo\\ifcossetup.txt", _ifcossetup()],
			["resinfo\\ifcosstatus.txt", _ifcosstatus()], ["resinfo\\ifcoscommand.txt", _ifcoscommand()],
			["resinfo\\ifpetminiinfo.txt", _ifpetminiinfo()], ["resinfo\\ifplayerminiinfo.txt", _ifplayerminiinfo()],
			["resinfo\\ifmessagebox.txt", _ifmessagebox()]]:
		cache[pair[0]] = UiLayoutParser.parse(pair[1])
	builder.set("_window_registry", UiLayoutParser.parse(_registry()))
	builder.set("_window_registry_loaded", true)
	builder.set("_window_registry_data", _registry())
	return builder

func _row(id: int, code: String, type4: int, level: int, max_hp: int) -> CosTable.Row:
	var r := CosTable.Row.new()
	r.id = id
	r.code = code
	r.type4 = type4
	r.level = level
	r.max_hp = max_hp
	r.icon = "icon\\cos\\" + code.to_lower() + ".ddj"
	r.name_key = "SN_" + code
	return r

var _rows := {}

func _data(uid: int, ref_id: int, name: String = "") -> CosNet.Data:
	var d := CosNet.Data.new()
	d.uid = uid
	d.ref_id = ref_id
	var r: CosTable.Row = _rows[ref_id]
	d.kind = r.type4
	d.hp = r.max_hp / 2
	d.name = name
	return d

# --- tests ---------------------------------------------------------------------

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the checks never reported (a script error stopped them)")
		quit(1))
	_rule_tests()
	await process_frame
	await _manager_tests()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILURES" % _failures)
	quit(1 if _failures > 0 else 0)

func _rule_tests() -> void:
	# The window's tabs, pages and rows per kind (0x79ff50, 0x7a5610).
	_check(HudCosWindow.tabs_enabled(0) == [true, false, false] and HudCosWindow.tabs_enabled(1) == [true, true, false]
		and HudCosWindow.tabs_enabled(2) == [true, true, true] and HudCosWindow.tabs_enabled(3) == [true, false, false],
		"tabs: Inventory only for kinds 1/2, Setting only for kind 2")
	_check(HudCosWindow.info_command_page(1) == 1 and HudCosWindow.info_command_page(2) == 1
		and HudCosWindow.info_command_page(3) == 0 and HudCosWindow.info_command_page(0) == 0,
		"Ins opens page 1 for a transport or an ability pet, else page 0")
	_check(HudCosWindow.resolve_page(3, 2, 2) == 2 and HudCosWindow.resolve_page(3, 1, 3) == 0
		and HudCosWindow.resolve_page(2, 0, 1) == 0, "page 3 keeps the last page; a disabled page falls back to 0")
	var g := HudCosWindow.info_visibility(3)
	_check(g[36] and g[45] and g[35] and not g[52] and g[67] and not g[100],
		"growth: HP, HGP and EXP rows and the stats; no rental row; no \"<Stat does not exist.>\"")
	var a := HudCosWindow.info_visibility(2)
	_check(not a[35] and not a[41] and a[50] and a[52] and not a[36] and not a[67] and a[100],
		"ability: no HP row, the rental row, no stats, \"<Stat does not exist.>\"")
	var r := HudCosWindow.info_visibility(0)
	_check(r[35] and not r[52] and not r[36] and r[100], "ride: the HP row only")
	# Texts and ratios (0x7a2e60, 0x7a2fc0, 0x7a30a0, 0x7a3bd0).
	_check(HudCosWindow.hp_text(491, 983) == "491/983 (49%)", "HP text \"%%d/%%d (%%d%%%%)\" truncates (got %s)" % HudCosWindow.hp_text(491, 983))
	_check(HudCosWindow.hp_text(5, 0) == "100%", "no MaxHP reads \"100%\"")
	_check(HudCosWindow.hgp_text(5000) == "51% (5000)", "HGP 5000 shows \"51%% (5000)\" (READ as written; got %s)" % HudCosWindow.hgp_text(5000))
	_check(HudCosWindow.hgp_text(10000) == "100% (10000)" and HudCosWindow.hgp_text(0) == "1% (0)",
		"HGP full caps at 100%%; 0 shows 1%% (got %s, %s)" % [HudCosWindow.hgp_text(10000), HudCosWindow.hgp_text(0)])
	_check(is_equal_approx(HudCosWindow.hgp_ratio(2500), 0.25), "HGP gauge = HGP / 10000")
	_check(HudCosWindow.exp_text(150, 900) == "150/900 (16.67%)", "EXP \"%%I64d/%%I64d (%%.2f%%%%)\" (got %s)" % HudCosWindow.exp_text(150, 900))
	_check(HudCosWindow.exp_text(1000, 1000) == "1000/1000 (99.99%)", "the EXP percent is capped at 99.99")
	_check(HudCosWindow.rent_text(93780000, "Day", "Hour", "Minute") == "1Day 2Hour 3Minute"
		and HudCosWindow.rent_text(0, "Day", "Hour", "Minute") == "0Day 0Hour 0Minute", "the rental row's days, hours and minutes")
	_check(HudCosWindow.range_text(10, 20) == "10 ~ 20" and HudCosWindow.range_text(0, 0) == "0", "\"%d ~ %d\", or \"0\" when the max is 0")
	_check(HudCosWindow.inventory_pages(140) == 5 and HudCosWindow.inventory_pages(0) == 1 and HudCosWindow.inventory_pages(28) == 1,
		"pet bag pages of 28")
	_check(HudCosWindow.inventory_caption("Pet", 1, 5) == "Pet (2/5)", "the bag caption \"%s (%d/%d)\"")
	_check(HudCosWindow.name_valid("Rex") and HudCosWindow.name_valid("abcdefghijkl") and not HudCosWindow.name_valid("")
		and not HudCosWindow.name_valid("abcdefghijklm") and not HudCosWindow.name_valid("Big Rex"),
		"a name is 1..12 characters with no space")
	# The pickup flags (0x7a83e0 / 0x7a84c0).
	_check(HudCosWindow.flags_with_radio(0, HudCosWindow.ID_RADIO_ONOFF, 0) == 0x80
		and HudCosWindow.flags_with_radio(0x81, HudCosWindow.ID_RADIO_ONOFF, 1) == 0x01, "ON sets 0x80, OFF clears it")
	_check(HudCosWindow.flags_with_radio(0, HudCosWindow.ID_RADIO_SCOPE, 1) == 0x40
		and HudCosWindow.flags_with_radio(0xc0, HudCosWindow.ID_RADIO_SCOPE, 0) == 0x80, "\"all items\" sets 0x40, \"only mine\" clears it")
	_check(HudCosWindow.flags_with_check(0, HudCosWindow.ID_CHECK_GOLD, true) == 1 and HudCosWindow.flags_with_check(0, HudCosWindow.ID_CHECK_EQUIP, true) == 2
		and HudCosWindow.flags_with_check(7, HudCosWindow.ID_CHECK_OTHER, false) == 3, "gold 0x01, equipment 0x02, other 0x04")
	# The status slots (0x810660, 0x7a8d70).
	_check(HudCosStatus.slot_position(1024, 0) == Vector2(852, 2) and HudCosStatus.slot_position(1024, 2) == Vector2(756, 2),
		"slot i at (W - 172 - 48 i, 2): 852, 804, 756 at 1024")
	# The command strip (0x7a25c0, 0x7a20c0, 0x7a0210, 0x7a0f90).
	_check(HudCosCommand.commands_for(0) == [0, 1, 5] and HudCosCommand.commands_for(1) == [0, 1, 5]
		and HudCosCommand.commands_for(2) == [0, 1, 4, 3] and HudCosCommand.commands_for(3) == [0, 1, 4, 3, 2, 6]
		and HudCosCommand.commands_for(4) == [5], "buttons per kind")
	_check(HudCosCommand.piece_offsets(3) == [[0, 4], [33, 35], [64, 66], [95, 97], [126, 128], [157, 159]],
		"pieces advance 33, 31, ... 34; slots at +4 on the first, +2 after (got %s)" % str(HudCosCommand.piece_offsets(3)))
	_check(HudCosCommand.strip_origin(Vector2(112, 700), 6) == Vector2(579, 672), "strip at bar x + 653 - 31 n, bar y - 28")
	var st := {"kind": 3, "settings": 1, "rideable": false}
	_check(HudCosCommand.icon_path(0, st) == "icon\\action\\cos_cmd_coswindow.ddj"
		and HudCosCommand.icon_path(2, st) == "icon\\action\\cos_cmd_skill_page.ddj"
		and HudCosCommand.icon_path(6, st) == "icon\\action\\cos_cmd_aggressive.ddj"
		and HudCosCommand.icon_path(1, st) == "icon\\action\\cos_cmd_embark_disable.ddj"
		and HudCosCommand.icon_path(5, st) == "icon\\action\\cos_cmd_ai_destruction_disable.ddj", "growth pet icons")
	st["settings"] = 0
	_check(HudCosCommand.icon_path(6, st) == "icon\\action\\cos_cmd_defensive.ddj", "AI mode 0 shows the defensive icon")
	st["dead"] = true
	_check(HudCosCommand.icon_path(0, st) == "icon\\action\\cos_cmd_coswindow.ddj" and not HudCosCommand.enabled(3, st)
		and HudCosCommand.icon_path(6, st) == "icon\\action\\cos_cmd_aggressive_disable.ddj", "a dead owner greys everything but info")
	var ride := {"kind": 0, "rideable": true, "riding": false}
	_check(HudCosCommand.icon_path(1, ride) == "icon\\action\\cos_cmd_embark.ddj" and HudCosCommand.enabled(5, ride), "a horse: embark, terminate")
	ride["riding"] = true
	_check(HudCosCommand.icon_path(1, ride) == "icon\\action\\cos_cmd_disembark.ddj", "riding: disembark")
	_check(HudCosCommand.tooltip_key(1, ride) == ["UIIT_STT_TOGGLE_CONTENTS_MENU_COS_DISMOUNT", true]
		and HudCosCommand.tooltip_key(4, ride)[0] == "UIIT_STT_TOGGLE_CONTENTS_MENU_COS_UNSOMMON"
		and HudCosCommand.tooltip_key(6, {"settings": 7}) == ["UIIT_STT_COS_AGGRESSIVE", false], "tooltip keys")
	_check(HudCosCommand.tooltip_text("Info ( %s )", true, "Insert") == "Info ( Insert )", "the key name fills %s")
	_check(HudCos.pgup_command(2) == 4 and HudCos.pgup_command(3) == 4 and HudCos.pgup_command(1) == 5, "PgUp: unsummon a pet, else terminate")
	# The EXP loop (FUN_008aa340 case 3).
	var next := func(lv: int) -> int: return lv * 100
	var e := HudCos.apply_exp_delta(7, 650, 1000, next)
	_check(e["level"] == 9 and e["exp"] == 150 and e["leveled"], "650 + 1000 at Lv 7 (700, 800, 900): Lv 9 with 150 (got %s)" % str(e))
	e = HudCos.apply_exp_delta(7, 100, 50, next)
	_check(e["level"] == 7 and e["exp"] == 150 and not e["leveled"], "below the threshold: added, no level")
	e = HudCos.apply_exp_delta(7, 100, -500, next)
	_check(e["level"] == 7 and e["exp"] == 0, "a loss clamps at 0")
	_check(HudPetMiniInfo.caution_on(0.3) and not HudPetMiniInfo.caution_on(0.0) and not HudPetMiniInfo.caution_on(0.31),
		"the pet strip's caution shows for 0 < HP <= 30%")

func _manager_tests() -> void:
	_rows = {5001: _row(5001, "COS_P_WOLF_001", 3, 7, 300), 5002: _row(5002, "COS_P_RABBIT", 4, 1, 100),
		5003: _row(5003, "COS_C_HORSE1", 1, 1, 983), 5004: _row(5004, "COS_T_HORSE1", 2, 1, 1200),
		5005: _row(5005, "COS_GUARD", 5, 1, 500)}
	var cos := HudCos.new(_builder())
	cos.setup({
		"cos_row": func(id: int) -> CosTable.Row: return _rows.get(id),
		"item_row": func(_id: int) -> ItemTableReader.Item: return null,
		"text": func(k: String) -> String: return k,
		"exp_to_next": func(lv: int) -> int: return lv * 100,
		"screen_width": func() -> int: return 1024,
		"screen_height": func() -> int: return 768,
		"object_name": func(k: String) -> String: return "Horse" if k == "SN_COS_C_HORSE1" else "",
	})
	root.add_child(cos)
	var cmds: Array = []
	var settings: Array = []
	var lines: Array = []
	var renames: Array = []
	var rejected: Array = []
	var moves: Array = []
	var targets: Array = []
	cos.command.connect(func(uid: int, c: int) -> void: cmds.append([uid, c]))
	cos.setting_requested.connect(func(uid: int, k: int, v: int) -> void: settings.append([uid, k, v]))
	cos.system_line.connect(func(t: String, col: Color) -> void: lines.append([t, col]))
	cos.rename_requested.connect(func(uid: int, n: String) -> void: renames.append([uid, n]))
	cos.name_rejected.connect(func(uid: int, n: String) -> void: rejected.append([uid, n]))
	cos.bag_move_requested.connect(func(t: int, uid: int, s: int, d: int, n: int) -> void: moves.append([t, uid, s, d, n]))
	cos.target_requested.connect(func(uid: int) -> void: targets.append(uid))

	_check(not cos.has_any() and not cos.visible, "empty: hidden (Style 64)")
	var horse := _data(1, 5003)
	var wolf := _data(2, 5001)
	wolf.level = 7
	wolf.exp = 650
	wolf.hgp = 5000
	var rabbit := _data(3, 5002, "Bun")
	rabbit.inv_size = 30
	rabbit.pet_option = 0x81
	rabbit.item_slot = 4
	cos.add_cos(horse)
	cos.add_cos(wolf)
	cos.add_cos(rabbit)
	await process_frame
	_check(cos.visible and cos.has_any() and cos.summon_order() == [1, 2, 3], "three out, in summon order")
	_check(cos.current_uid() == 3, "the last summoned is current")
	_check(cos.status_of(1).position == Vector2(852, 2) and cos.status_of(2).position == Vector2(804, 2)
		and cos.status_of(3).position == Vector2(756, 2), "status slots at 852 / 804 / 756")
	_check(cos.status_of(2).gauges_shown() == [true, true] and cos.status_of(2).size == Vector2(44, 68)
		and cos.status_of(1).gauges_shown() == [false, true] and cos.status_of(1).size == Vector2(44, 56),
		"growth: 44x68 with HGP; ride: 44x56 HP only")
	_check(cos.status_of(3).is_current() and not cos.status_of(1).is_current() and not cos.status_of(2).is_current(),
		"only the current COS's outline")
	_check(cos.command_of(3).visible and not cos.command_of(2).visible and not cos.command_of(1).visible,
		"only the current COS's strip")
	_check(cos.command_of(2).position == Vector2(579, 672), "the growth strip's 6 buttons at (112 + 653 - 186, 700 - 28) (got %s)" % cos.command_of(2).position)
	cos._process(0.0)
	_check(is_equal_approx(cos.status_of(2).hp_value(), 0.5) and is_equal_approx(cos.status_of(2).hgp_value(), 0.5),
		"the gauges: HP / MaxHP (column 59), HGP / 10000")
	_check(cos.pet_info.visible and cos.pet_info.uid == 2 and cos.pet_info.level_label.text == "Lv. 7"
		and cos.pet_info.name_label.text == "No name", "the growth pet's strip: \"No name\", \"Lv. 7\"")
	# W: next in summon order, wrapping.
	cos.switch_next()
	_check(cos.current_uid() == 1 and cos.command_of(1).visible and not cos.command_of(3).visible, "W wraps to the first")
	cos.switch_next()
	_check(cos.current_uid() == 2, "W again: the second")
	# A status slot click.
	cos.status_of(3).pressed_left.emit()
	_check(cos.current_uid() == 3 and targets == [3], "a slot's left press makes it current and targets it")

	# Ins on the ability pet: the window on its Inventory page.
	cos.run_command(0)
	await process_frame
	var w := cos.window
	_check(w.visible and w.cos_uid == 3 and w.page == HudCosWindow.PAGE_INVENTORY, "Ins opens the window on page 1 for an ability pet")
	_check(not tabs_disabled(w, 0) and not tabs_disabled(w, 1) and not tabs_disabled(w, 2), "all three tabs for an ability pet")
	var cap := w.inventory_node(HudCosWindow.ID_INV_NAME)
	_check(cap is Label and (cap as Label).text == "Pet (1/2)", "the bag caption \"Pet (1/2)\" for 30 slots (got %s)" % ((cap as Label).text if cap is Label else "?"))
	_check(w.inv_slots.size() == 28 and (w.inv_slots[1] as Control).position == Vector2(77, 59)
		and (w.inv_slots[7] as Control).position == Vector2(41, 95), "28 slots at (41 + 36 col, 59 + 36 row)")
	w.inv_page = 1
	w.refresh_inventory()
	_check(not bool((w.inv_slots[1] as Control).get_meta("cos_locked")) and bool((w.inv_slots[2] as Control).get_meta("cos_locked")),
		"page 2: slots 28, 29 open, 30 on locked (pt_block)")
	w.inv_page = 0
	w.refresh_inventory()
	# The bag ops (0xB034).
	var it := ItemInstance.new()
	it.ref_item_id = 77
	it.slot = 0
	rabbit.items[0] = it
	cos.bag_applied({"ok": true, "type": CosNet.BAG_COS_TO_COS, "cos": 3, "src": 0, "dst": 5})
	_check(not rabbit.items.has(0) and rabbit.items.get(5) == it and it.slot == 5, "COS_TO_COS moves the item")
	var picked := ItemInstance.new()
	picked.ref_item_id = 88
	cos.bag_applied({"ok": true, "type": CosNet.BAG_PICK, "cos": 3, "slot": 2, "item": picked})
	_check(rabbit.items.get(2) == picked, "a picked item lands in its slot")
	cos.bag_applied({"ok": true, "type": CosNet.BAG_COS_TO_BAG, "cos": 3, "src": 5, "dst": 9})
	_check(not rabbit.items.has(5), "COS_TO_BAG removes it")
	# A drop on the bag's slot 3 of a pet-bag item from slot 2.
	await process_frame
	var at := (w.inv_slots[3] as Control).get_global_rect().get_center()
	_check(cos.pet_bag_slot_at(at) == 3, "pet_bag_slot_at finds slot 3")
	_check(cos.accept_drop({"kind": "cos_bag", "uid": 3, "slot": 2, "qty": 1}, at) and moves == [[CosNet.BAG_COS_TO_COS, 3, 2, 3, 1]],
		"a pet-bag item dropped on another slot asks for 0x10 (got %s)" % str(moves))
	moves.clear()
	_check(cos.accept_drop({"kind": "bag", "slot": 6, "qty": 4}, at) and moves == [[CosNet.BAG_BAG_TO_COS, 3, 6, 3, 4]],
		"a bag item dropped on the pet bag asks for 0x1b")
	_check(not cos.accept_drop({"kind": "bag", "slot": 6}, Vector2(-500, -500)), "a drop elsewhere is not the window's")
	var to_inv: Array = []
	cos.bag_drag_to_inventory.connect(func(uid: int, src: int) -> void: to_inv.append([uid, src]))
	_check(cos.held_dropped_on_inventory({"kind": "cos_bag", "uid": 3, "slot": 2}) and to_inv == [[3, 2]], "a pet-bag item put on the bag")

	# The Setting page: 0x81 = ON, only mine, gold.
	w.select_page(HudCosWindow.PAGE_SETUP)
	_check(w.radio_choice(HudCosWindow.ID_RADIO_ONOFF) == 0 and w.radio_choice(HudCosWindow.ID_RADIO_SCOPE) == 0
		and w.check_state(HudCosWindow.ID_CHECK_GOLD) and not w.check_state(HudCosWindow.ID_CHECK_EQUIP), "the page loads 0x81")
	var ok := w.setup_node(HudCosWindow.ID_SETUP_OK) as BaseButton
	_check(ok != null and ok.disabled, "Confirm disabled while nothing changed")
	w.set_check(HudCosWindow.ID_CHECK_EQUIP, true)
	_check(not ok.disabled and w.edit_flags == 0x83, "a change enables Confirm")
	w.press_setup_ok()
	_check(settings == [[3, CosNet.SETTING_PICKUP, 0x83]], "Confirm asks for 0x7420 {uid, 2, 0x83} (got %s)" % str(settings))
	settings.clear()
	w.choose_radio(HudCosWindow.ID_RADIO_SCOPE, 1)
	w.press_setup_cancel()
	_check(w.edit_flags == 0x81 and ok.disabled, "Cancel reloads the record's flags")
	cos.setting_applied(3, CosNet.SETTING_PICKUP, 0xc3)
	_check(rabbit.pet_option == 0xc3 and w.edit_flags == 0xc3 and w.radio_choice(HudCosWindow.ID_RADIO_SCOPE) == 1,
		"0xB420 applies the flags to the record and the page")

	# The current COS moves: the window follows, keeping the page where it can.
	cos.make_current(2)
	_check(w.cos_uid == 2 and w.page == HudCosWindow.PAGE_INFO and tabs_disabled(w, 1) and tabs_disabled(w, 2),
		"switching to the growth pet re-shows the window; its disabled page falls back to Basic Info")
	_check(w.info_node(36).visible and w.info_node(45).visible and not w.info_node(52).visible and not w.info_node(100).visible,
		"growth: HGP and EXP rows, no rental row")
	w.refresh()
	_check(w.info_text(41) == "150/300 (50%)" and w.info_text(43) == "51% (5000)" and w.info_text(45) == "650/700 (92.86%)"
		and w.info_text(65) == "7", "the growth rows (got %s / %s / %s / %s)" % [w.info_text(41), w.info_text(43), w.info_text(45), w.info_text(65)])
	var bar := w.get_node_or_null("TitleBar") as Label
	_check(bar != null and bar.text == "No name", "the caption: \"No name\" for an unnamed pet")
	_check(w.name_button_enabled() and not (w.info_node(26) as BaseButton).disabled, "Create name is enabled for an unnamed pet")

	# The EXP update and its line (0x30C9 case 3).
	var u := CosNet.Update.new()
	u.uid = 2
	u.type = CosNet.UPDATE_EXP
	u.exp_delta = 1000
	cos.apply_update(u)
	_check(wolf.level == 9 and wolf.exp == 150, "the level-up loop: Lv 9, 150")
	_check(lines.size() == 1 and lines[0][0] == "You have gained [1000]amount of pet experience." and lines[0][1] == HudCos.SYSTEM_COLOUR,
		"the gain line in 0xffdbc99b (got %s)" % str(lines))
	_check(cos.pet_info.level_label.text == "Lv. 9", "the pet strip refills on a level-up")
	lines.clear()
	u.exp_delta = -40
	cos.apply_update(u)
	_check(wolf.exp == 110 and lines.size() == 1 and lines[0][0] == "You have lost [40]amount of pet experience.", "the loss line")
	lines.clear()
	# HGP across 30 % (0x3057 path).
	cos.set_hgp(2, 2900)
	_check(lines.size() == 1 and String(lines[0][0]).begins_with("All stats are lowered by 50%"), "crossing 3000 prints the warning")
	cos.set_hgp(2, 1000)
	_check(lines.size() == 1, "staying below prints nothing")
	lines.clear()

	# Naming (1e).
	_check(not w.submit_name("Big Rex") and rejected == [[2, "Big Rex"]], "a name with a space is refused")
	w.open_name_box()
	_check(w.name_box != null and w.name_box.edit != null and w.name_box.edit.max_length == 12, "the input box limits the name to 12")
	_check(w.name_box.size == Vector2(306, 151), "the input box is 306x151")
	w.name_box.edit.text = "Rex"
	w.name_box.press_ok()
	_check(w.confirm_box != null and renames.is_empty(), "OK asks for confirmation first")
	if w.confirm_box != null:
		w.confirm_box.confirmed.emit()
	_check(renames == [[2, "Rex"]], "Yes asks for 0x7117 (got %s)" % str(renames))
	u = CosNet.Update.new()
	u.uid = 2
	u.type = CosNet.UPDATE_NAME
	u.name = "Rex"
	cos.apply_update(u)
	_check(cos.pet_info.name_label.text == "Rex" and bar.text == "Rex" and not w.name_button_enabled(),
		"0x30C9 case 5: the strip, the caption and the button follow the name")

	# Commands on the current COS.
	cmds.clear()
	cos.run_command(6)
	_check(cmds == [[2, 6]] and settings == [[2, CosNet.SETTING_AI, 1]], "AI toggles 0 -> 1 (0x7420 {uid, 1, 1})")
	cos.setting_applied(2, CosNet.SETTING_AI, 1)
	_check(cos.command_of(2).icon_of(6) == "icon\\action\\cos_cmd_aggressive.ddj", "the AI icon follows the mode")
	cmds.clear()
	cos.run_command(5)
	_check(cmds.is_empty(), "a pet cannot be terminated")
	cos.run_command(4)
	_check(cmds == [[2, 4]], "unsummon")
	cmds.clear()
	cos.set_owner_dead(true)
	cos.run_command(3)
	_check(cmds.is_empty() and cos.command_of(2).icon_of(3) == "icon\\action\\cos_cmd_follower_disable.ddj",
		"a dead owner's commands are refused and greyed")
	cos.run_command(0)
	_check(not w.visible, "but Ins still toggles the window")
	cos.set_owner_dead(false)
	# The ride horse.
	cos.make_current(1)
	_check(cos.cos_data(1).name == "Horse", "a ride's record takes its row's name (SN_COS_C_HORSE1)")
	cos.run_command(1)
	_check(cmds == [[1, 1]], "ride on a horse")
	cos.set_riding(1, true)
	_check(cos.command_of(1).icon_of(1) == "icon\\action\\cos_cmd_disembark.ddj", "0xB0CB: the dismount icon")
	cmds.clear()
	cos.run_command(5)
	_check(cmds == [[1, 5]], "a horse terminates directly")
	cmds.clear()
	# A transport asks first.
	var cart := _data(4, 5004)
	cos.add_cos(cart)
	cos.run_command(5)
	_check(cmds.is_empty() and cos.clean_box != null and cos.clean_box.size == Vector2(388, 144), "a transport asks first (388x144)")
	if cos.clean_box != null:
		cos.clean_box.press_ok()
	_check(cmds == [[4, 5]], "Yes terminates it")

	# Removal: the current falls to the first.
	cos.remove_cos(4)
	_check(cos.current_uid() == 1 and cos.summon_order() == [1, 2, 3], "the current COS removed: the first becomes current")
	_check(cos.status_of(3).position == Vector2(756, 2), "slots re-laid")
	var gone := CosNet.Update.new()
	gone.uid = 2
	gone.type = CosNet.UPDATE_REMOVED
	cos.apply_update(gone)
	_check(not cos.pet_info.visible and cos.status_of(3).position == Vector2(804, 2), "the growth pet gone: its strip hides, slots close up")
	# A re-sent 0x30C8 replaces in place.
	cos.add_cos(_data(3, 5002, "Bunny"))
	_check(cos.summon_order() == [1, 3] and cos.cos_data(3).name == "Bunny", "a re-sent record replaces its own")
	# Guild soldiers: one slot for all.
	cos.add_cos(_data(10, 5005))
	cos.add_cos(_data(11, 5005))
	_check(cos.status_of(10) != null and cos.status_of(11) == null and cos.current_uid() == 10, "a second soldier gets no slot")
	_check(cos.status_of(10).gauges_shown() == [false, false], "a soldier's slot has no gauge")
	cos.remove_cos(10)
	_check(cos.status_of(11) != null, "the remaining soldier takes the slot")
	for uid in cos.summon_order():
		cos.remove_cos(uid)
	_check(not cos.has_any() and not cos.visible and cos.current_uid() == 0, "all gone: hidden, no current COS")
	cos.queue_free()
	await process_frame

func tabs_disabled(w: HudCosWindow, i: int) -> bool:
	return (w.tabs[i] as TextureButton).disabled
