extends SceneTree

## The Auto potion window's controls (round 786, AutoPotionWindow) over a
## synthetic ifautopotion.txt / ifautopotionslot.txt: control names, ids and
## rects copied from the real layouts, no artwork, no game data. READ values
## asserted: the slot index from the combos (0x741420), the combos from a
## slot (0x7413d0), the thumb's travel (0x6598a0: 276 px over 1..100), the
## spin's text and range (0x6583f0, 500..9500), the check box re-enabling its
## slider on the SAVED percent (0x741460), Confirm handing the values out and
## closing (0x741590), Cancel closing (0x7417c0). Round 876 (OURS): the vigor
## row -- built under the MP row, everything below moved down a row pitch, the
## window grown, no two controls overlapping, its controls working.
##   godot4 --headless --path client --script res://scripts/ui/hud/auto_potion_window_test.gd

const PATH := "res://scripts/ui/hud/auto_potion_window.gd"

var _failures := 0
var _size_before := Vector2.ZERO

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _control(control_name: String, type: String, rect: String, id: int, text: String = "", extra: String = "") -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tID=INTEGER,\"%d\"\n%s\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"%s\"\n\t}\n" % [
		control_name, type, id, extra, rect, text]

func _section(section_name: String, body: String) -> String:
	return "Section = %s,\"0,0,0,0\",\"0\"\n{\n%s}\n" % [section_name, body]

func _window_layout() -> String:
	return "Interface Text\n\n" + _section("Create",
			_control("GDR_AUTO_POTION_CANCEL_BTN", "CIFButton", "205,462,80,24", 31, "UIIT_CTL_CANCEL")
			+ _control("GDR_AUTO_POTION_OK_BTN", "CIFButton", "117,462,80,24", 30, "UIIT_CTL_CONFIRM")
			+ _control("GDR_AUTO_POTION_SLOT_MP", "CIFAutoPotionSlot", "23,283,347,73", 11, "", "\t\tADDID=INTEGER,\"200\"\n")
			+ _control("GDR_AUTO_POTION_SLOT_HP", "CIFAutoPotionSlot", "23,197,347,73", 10, "", "\t\tADDID=INTEGER,\"100\"\n")
			+ _control("GDR_AUTO_POTION_DESC_PML", "CIFPML", "43,76,309,83", 7, "UIIT_STT_MACROPOTION_CONTENTS")
			+ _control("GDR_AUTO_POTION_FRAME_2", "CIFStatic", "24,55,346,126", 5)
			+ _control("GDR_AUTO_POTION_BG_1", "CIFStatic", "29,58,336,433", 4)
			+ _control("GDR_AUTO_POTION_FRAME_1", "CIFStatic", "13,42,368,465", 3)) \
		+ _section("AbnormalSlot",
			_control("GDR_AUTO_POTION_ABNORMAL_QUICKSLOT_COMBOBOX", "CIFComboBox", "306,375,57,20", 20)
			+ _control("GDR_AUTO_POTION_ABNORMAL_QUICKSLOT_STA", "CIFStatic", "255,379,45,12", 19, "Slot", RIGHT)
			+ _control("GDR_AUTO_POTION_ABNORMAL_QUICKSLOT_BELT_COMBOBOX", "CIFComboBox", "188,375,57,20", 18)
			+ _control("GDR_AUTO_POTION_ABNORMAL_QUICKSLOT_BELT_STA", "CIFStatic", "136,379,45,12", 17, "Belt", RIGHT)
			+ _control("GDR_AUTO_POTION_ABNORMAL_NAME", "CIFStatic", "55,379,61,12", 16, "Abnormal")
			+ _control("GDR_AUTO_POTION_ABNORMAL_CHECKBOX", "CIFCheckBox", "30,377,16,16", 15)) \
		+ _section("PotionDelaySlot",
			_control("GDR_AUTO_POTION_DELAY_VERTSPINCTRL", "CIFVerticalSpinCtrl", "306,413,58,25", 27)
			+ _control("GDR_AUTO_POTION_DELAY_NAME", "CIFStatic", "55,417,105,12", 26, "Potion use delay")
			+ _control("GDR_AUTO_POTION_DELAY_CHECKBOX", "CIFCheckBox", "30,416,16,16", 25))

## HAlign 2 (right), as the real layouts' belt and quick-slot statics have it.
const RIGHT := "\t\tHAlign=INTEGER,\"2\"\n"

func _slot_layout() -> String:
	return "Interface Text\n\n" + _section("Create",
		_control("GDR_AUTOPOTION_SLOT_MAX_STA", "CIFStatic", "317,55,26,12", 19)
		+ _control("GDR_AUTOPOTION_SLOT_CENTER_STA", "CIFStatic", "164,56,26,12", 18)
		+ _control("GDR_AUTOPOTION_SLOT_MIN_STA", "CIFStatic", "10,55,26,12", 17)
		+ _control("GDR_AUTOPOTION_SLOT_SLIDERCTRL", "CIFSliderCtrl", "6,32,334,21", 15)
		+ _control("GDR_AUTOPOTION_SLOT_QUICKSLOT_COMBOBOX", "CIFComboBox", "282,6,57,20", 13)
		+ _control("GDR_AUTOPOTION_SLOT_QUICKSLOT_STA", "CIFStatic", "232,10,45,12", 12, "Slot", RIGHT)
		+ _control("GDR_AUTOPOTION_SLOT_QUICKSLOT_BELT_COMBOBOX", "CIFComboBox", "165,6,57,20", 11)
		+ _control("GDR_AUTOPOTION_SLOT_QUICKSLOT_BELT_STA", "CIFStatic", "113,10,45,12", 10, "Belt", RIGHT)
		+ _control("GDR_AUTOPOTION_SLOT_DATA_UNIT_STA", "CIFStatic", "91,10,14,12", 7)
		+ _control("GDR_AUTOPOTION_SLOT_DATA", "CIFStatic", "59,11,25,12", 6, "", RIGHT)
		+ _control("GDR_AUTOPOTION_SLOT_DATA_BOX", "CIFStatic", "54,8,34,18", 5)
		+ _control("GDR_AUTOPOTION_SLOT_NAME", "CIFStatic", "32,10,19,12", 2)
		+ _control("GDR_AUTOPOTION_SLOT_CHECKBOX", "CIFCheckBox", "7,8,16,16", 1))

func _builder() -> UiBuilder:
	var rows := PackedStringArray()
	for pair in [["UIIT_STT_MACROPOTION_HP", "HP"], ["UIIT_STT_MACROPOTION_MP", "MP"],
			["UIIT_STT_MACROPOTION_CONTENTS", "<sml2>Auto recovery settings<br>Set the %</sml2>"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	var builder := UiBuilder.new(null, UiTextTable.parse(("\n".join(rows)).to_utf16_buffer()))
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\ifautopotion.txt"] = UiLayoutParser.parse(_window_layout())
	cache["resinfo\\ifautopotionslot.txt"] = UiLayoutParser.parse(_slot_layout())
	return builder

func _initialize() -> void:
	if not ResourceLoader.exists(PATH):
		_check(false, "the auto potion window exists (auto_potion_window.gd)")
		_finish()
		return
	var script := load(PATH) as Script
	_check(int(script.call("slot_of", 0, 0)) == 1, "F1 '1' is slot 1")
	_check(int(script.call("slot_of", 0, 9)) == 10, "F1 '0' is slot 10")
	_check(int(script.call("slot_of", 3, 9)) == 40, "F4 '0' is slot 40")
	_check(script.call("combos_for", 20) == [1, 9], "slot 20 is F2 '0' (got %s)" % str(script.call("combos_for", 20)))
	_check(script.call("combos_for", 0) == [], "slot 0 leaves the combos alone (0x7413d0's `< 0x28` test)")
	_check(int(script.call("thumb_offset", 1)) == 0 and int(script.call("thumb_offset", 100)) == 276,
		"the thumb travels 0..276 px over 1..100")
	_check(int(script.call("thumb_offset", 50)) == 136, "50 sits at trunc(49 x 276 / 99) = 136 (got %d)" % int(script.call("thumb_offset", 50)))
	_check(String(script.call("spin_text", 1000)) == "1.0" and String(script.call("spin_text", 9500)) == "9.5",
		"the spin shows ms / 1000 with one decimal")
	_compose(script)
	_finish()

func _compose(script: Script) -> void:
	var builder := _builder()
	var window := HudWindow.new()
	root.add_child(window)
	if not window.build(builder, "resinfo\\ifautopotion.txt", "Auto potion", PackedStringArray(["AbnormalSlot", "PotionDelaySlot"])):
		_check(false, "the synthetic window builds")
		return
	_size_before = window.size
	var c = script.call("compose", window, builder)
	_check(c != null, "the controls compose")
	if c == null:
		return
	var hp: Dictionary = c.row_controls(0)
	_check(hp.get("check") != null and hp.get("slider") != null and hp.get("belt") != null and hp.get("quick") != null,
		"the HP row has its check box, slider and two combos")
	var name_label := window.find_child("GDR_AUTOPOTION_SLOT_NAME", true, false) as Label
	_check(name_label != null and name_label.text == "HP", "the HP row is named from UIIT_STT_MACROPOTION_HP")
	var values := {"rows": [{"enabled": true, "percent": 40, "slot": 1}, {"enabled": false, "percent": 60, "slot": 12},
		{"enabled": true, "percent": 0, "slot": 3}, {"enabled": false, "percent": 35, "slot": 24}],
		"delay_enabled": true, "delay_ms": 1500}
	c.fill(values)
	var back: Dictionary = c.read()
	_check(back == values, "fill then read gives the values back (got %s)" % str(back))
	var mp: Dictionary = c.row_controls(1)
	var mp_slider := mp.get("slider") as Control
	_check(not bool(mp_slider.get_meta("enabled")), "an unchecked row's slider is disabled")
	var thumb := mp_slider.get_node_or_null("Thumb") as Control
	_check(thumb == null or not thumb.visible, "and its thumb hidden (0x6597d0)")
	# The slider moves, then the box is turned on: back on the SAVED 60.
	(hp.get("slider") as Control).get_node("Next").emit_signal("pressed")
	_check(int(c.read()["rows"][0]["percent"]) == 41, "the next arrow steps one up")
	var data := (hp.get("data") as Control)
	_check(data is Label and (data as Label).text == "41", "and the row's percent static follows")
	var box := mp.get("check") as Control
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = false
	box.gui_input.emit(ev)
	_check(bool(mp_slider.get_meta("enabled")) and int(c.read()["rows"][1]["percent"]) == 60,
		"checking the box enables the slider on the saved percent")
	c.set_spin(20000)
	_check(c.spin_value() == 9500, "the spin stops at 9500 ms")
	c.set_spin(100)
	_check(c.spin_value() == 500, "and at 500 ms")
	var got := []
	c.on_confirm = func(v: Dictionary) -> void: got.append(v)
	window.show()
	(window.node("GDR_AUTO_POTION_OK_BTN") as BaseButton).emit_signal("pressed")
	_check(got.size() == 1 and not window.visible, "Confirm hands the values out and closes")
	window.show()
	(window.node("GDR_AUTO_POTION_CANCEL_BTN") as BaseButton).emit_signal("pressed")
	_check(got.size() == 1 and not window.visible, "Cancel closes and hands nothing out")
	window.show()
	_vigor(c, window)
	window.queue_free()

## Round 876 (OURS): the vigor row.
func _vigor(c, window: HudWindow) -> void:
	var v: Dictionary = c.row_controls(3)
	_check(v.get("check") != null and v.get("slider") != null and v.get("belt") != null and v.get("quick") != null,
		"vigor: the row has its check box, slider and two combos")
	var host := window.node("GDR_AUTO_POTION_SLOT_VIGOR") as Control
	_check(host != null and host.position == Vector2(23, 369) and host.size == Vector2(347, 73),
		"vigor: the row sits one row pitch under MP, at 23,369 347x73 (got %s)" % (str(host.get_rect()) if host != null else "none"))
	var hp := window.node("GDR_AUTO_POTION_SLOT_HP") as Control
	var mp := window.node("GDR_AUTO_POTION_SLOT_MP") as Control
	_check(hp.position == Vector2(23, 197) and mp.position == Vector2(23, 283), "vigor: the HP and MP rows stay where the layout puts them")
	var name_label := host.find_child("GDR_AUTOPOTION_SLOT_NAME", true, false) as Label
	_check(name_label != null and name_label.text == "Vigor", "vigor: the row is named Vigor")
	_check(c.vigor_pitch == 86, "vigor: the pitch is the layout's HP -> MP step, 86 (got %d)" % c.vigor_pitch)
	_check(window.size == _size_before + Vector2(0, 86), "vigor: the window grows by it (%s -> %s; the real one 394x520 -> 394x606)" % [str(_size_before), str(window.size)])
	var moved := {"GDR_AUTO_POTION_OK_BTN": Vector2(117, 548), "GDR_AUTO_POTION_CANCEL_BTN": Vector2(205, 548),
		"GDR_AUTO_POTION_ABNORMAL_CHECKBOX": Vector2(30, 463), "GDR_AUTO_POTION_ABNORMAL_QUICKSLOT_COMBOBOX": Vector2(306, 461),
		"GDR_AUTO_POTION_DELAY_CHECKBOX": Vector2(30, 502), "GDR_AUTO_POTION_DELAY_VERTSPINCTRL": Vector2(306, 499),
		"GDR_AUTO_POTION_DESC_PML": Vector2(43, 76)}
	for n in moved:
		var ctl := window.node(n) as Control
		_check(ctl != null and ctl.position == moved[n], "vigor: %s at %s (got %s)" % [n, str(moved[n]), str(ctl.position) if ctl != null else "none"])
	var frame := window.node("GDR_AUTO_POTION_FRAME_1") as Control
	var bg := window.node("GDR_AUTO_POTION_BG_1") as Control
	var pml_frame := window.node("GDR_AUTO_POTION_FRAME_2") as Control
	_check(frame.size.y == 551 and bg.size.y == 519 and pml_frame.size.y == 126,
		"vigor: the window's frame and tile grow by 86, the description's frame does not (got %s, %s, %s)" % [frame.size.y, bg.size.y, pml_frame.size.y])
	var problems: Array = c.layout_problems()
	_check(problems.is_empty(), "vigor: no two controls overlap and all are inside the window (%s)" % str(problems))
	# A box too close: the check catches it.
	var unit := host.find_child("GDR_AUTOPOTION_SLOT_DATA_UNIT_STA", true, false) as Control
	var box := host.find_child("GDR_AUTOPOTION_SLOT_DATA_BOX", true, false) as Control
	_check(box.position.x >= 54 and unit.position.x - box.position.x == 37, "vigor: the value box and unit keep their spacing (box at %d)" % int(box.position.x))
	# The controls work: the box on, the next arrow, the combos.
	var check := v.get("check") as Control
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = false
	check.gui_input.emit(ev)
	var slider := v.get("slider") as Control
	_check(AutoPotionWindow.is_checked(check) and bool(slider.get_meta("enabled")) and int(c.read()["rows"][3]["percent"]) == 35,
		"vigor: its check box turns it on, the slider on the saved 35")
	slider.get_node("Next").emit_signal("pressed")
	slider.get_node("Next").emit_signal("pressed")
	_check(int(c.read()["rows"][3]["percent"]) == 37, "vigor: the next arrow steps it up (got %d)" % int(c.read()["rows"][3]["percent"]))
	(v.get("belt") as OptionButton).select(2)
	(v.get("quick") as OptionButton).select(4)
	_check(int(c.read()["rows"][3]["slot"]) == 25, "vigor: F3 '5' is slot 25 (got %d)" % int(c.read()["rows"][3]["slot"]))
	_check(c.read()["rows"][0] == {"enabled": true, "percent": 41, "slot": 1}, "vigor: the HP row is untouched by it")
	var got := []
	c.on_confirm = func(vals: Dictionary) -> void: got.append(vals)
	(window.node("GDR_AUTO_POTION_OK_BTN") as BaseButton).emit_signal("pressed")
	_check(got.size() == 1 and got[0]["rows"][3] == {"enabled": true, "percent": 37, "slot": 25}, "vigor: Confirm hands the row out fourth")

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
