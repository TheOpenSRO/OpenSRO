extends SceneTree

## Round 848, lane H: the in-world HUD's native Godot widgets replaced by the
## original's (CifEdit, MsgBoxInif, ReviveBox, the guild name box, the quest
## give-up box, the composite window's buttons, MdToPml, PmlText.put_on). The
## layouts are synthetic but carry ifmessagebox.txt's MsgBoxINIF /
## MsgBoxSimple / MsgBoxInsertMsg names, IDs and rects; the texts are each
## key in angle brackets. No game data.
##   godot4 --headless --path client --script res://scripts/ui/hud/native_gui848h_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _text(n: Node) -> String:
	if n == null:
		return "(null)"
	if n is Label:
		return (n as Label).text
	for child_name in ["Text", "ButtonLabel"]:
		var l := n.get_node_or_null(child_name) as Label
		if l != null:
			return l.text
	return "(no text)"

func _key(code: Key, ctrl := false, shift := false, unicode := 0) -> InputEventKey:
	var k := InputEventKey.new()
	k.keycode = code
	k.pressed = true
	k.ctrl_pressed = ctrl
	k.shift_pressed = shift
	k.unicode = unicode
	return k

func _initialize() -> void:
	var builder := MsgBoxFixture.builder()
	_msg_boxes(builder)
	_revive(builder)
	_guild_name(builder)
	_give_up(builder)
	_md_to_pml()
	_composite()
	await process_frame
	root.size = Vector2i(1280, 720)
	await _cif_edit()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## MsgBoxInif: purposes 5, 0x1f and 0x20.
func _msg_boxes(builder: UiBuilder) -> void:
	var rp := MsgBoxInif.new()
	_check(rp.build_kind(builder, MsgBoxInif.Kind.RETURN_POINT, "RecallDesignatePrompt", "Donwhang"), "box 5 builds")
	_check(rp.size == Vector2(308, 148) and rp.caption.text == "<UIIT_STT_AGREEMENT_BOX>", "box 5: 308 x 148, the agreement box")
	_check(rp.line(0) == "The current position : [Donwhang]" and rp.line(1) == "<UIIT_MSG_MSGBOX_SETREBIRTH_ASKCERTIFY>",
		"box 5's lines: the zone's position, then the question (got %s / %s)" % [rp.line(0), rp.line(1)])
	_check(not rp.node("GDR_MBIN_BTN_CERTIFY").visible and _text(rp.node("GDR_MBIN_BTN_OK")) == "<UIIT_CTL_YES>",
		"+0x808 hidden; the layout's Yes")
	_check(rp.button("GDR_MBIN_BTN_OK") is TextureButton, "the buttons are the layout's, not Godot Buttons")
	rp.place_on(Vector2(1024, 768))
	_check(rp.position == Vector2(512 - 0x9a, 384 - 0x4a), "placed as 0x6ec5d0 places it")
	var said: Array = []
	rp.accepted.connect(func(_t: String) -> void: said.append("yes"))
	rp.button("GDR_MBIN_BTN_OK").pressed.emit()
	_check(said == ["yes"], "Yes accepts")
	rp.free()
	var use := MsgBoxInif.new()
	use.build_kind(builder, MsgBoxInif.Kind.ITEM_USE, "UseOnConfirm")
	_check(use.caption.text == "<UIIT_STT_CONFIRM_BOX>" and use.line(0) == "<UIIT_MSG_QUESTION_SILKMALL_ITEM_USE>" and use.line(1) == "",
		"box 0x1f: the confirm box, one line")
	use.free()
	var cb := MsgBoxInif.new()
	cb.build_kind(builder, MsgBoxInif.Kind.BUFF_CANCEL, "BuffCancelConfirm")
	_check(cb.line(0) == "<UIIT_MSG_QUESTION_SILKMALL_ITEM_USE_CANCLE_1>" and cb.line(1) == "<UIIT_MSG_QUESTION_SILKMALL_ITEM_USE_CANCLE_2>",
		"box 0x20: CANCLE_1, CANCLE_2")
	cb.free()
	var none := MsgBoxInif.new()
	_check(not none.build_kind(builder, 0x42, "X"), "an unknown purpose builds nothing")
	none.free()

## ReviveBox: purpose 3's art, rects and buttons.
func _revive(builder: UiBuilder) -> void:
	var box := ReviveBox.new()
	_check(box.build_revive(builder, 10), "the dead window builds")
	_check(box.size == Vector2(400, 210) and box.caption.text == "<UIIT_STT_CONFIRM_BOX>", "400 x 210, the confirm box's title")
	var img := box.node("GDR_MBIN_STATIC_MESSAGE1")
	_check(img != null and img.position == Vector2(0x80, 0x2b) and img.size == Vector2(0x94, 0x34), "the rebirth image at (0x80, 0x2b) 0x94 x 0x34")
	_check(box.node("GDR_MBIN_STATIC_MESSAGE2").position == Vector2(0, 0x86) and box.node("GDR_MBIN_STATIC_MESSAGE3").position == Vector2(0, 0x96),
		"+0x844 / +0x848 at y 0x86 / 0x96")
	_check(box.pml != null and box.pml.position == Vector2(0, 0x75) and box.pml.size == Vector2(0x190, 0x10), "the CIFPML at (0, 0x75) 400 x 16")
	var shown := "".join(box.pml.plain_lines()) if box.pml != null else ""
	_check(shown == "the character  is now paralyzed.", "REBIRTH_1 drawn from its <sml2> element, quotes left out (got '%s')" % shown)
	var point := box.root.find_child("RevivePoint", true, false) as BaseButton
	var here := box.root.find_child("ReviveHere", true, false) as BaseButton
	_check(point is TextureButton and point.position == Vector2(0x16, 0xa8) and point.size == Vector2(0xb0, 0x18)
		and _text(point) == "<UIIT_MSG_MSGBOX_REBIRTH_POINT_BUTTON>", "the return-point button at (0x16, 0xa8) 176 x 24")
	_check(here != null and here.position == Vector2(0xca, 0xa8) and _text(here) == "<UIIT_MSG_MSGBOX_REBIRTH_STANDING_BUTTON>",
		"level 10: the present point at (0xca, 0xa8)")
	_check(not box.node("GDR_MBIN_BTN_CERTIFY").visible, "+0x808 hidden")
	var options: Array = []
	box.chosen.connect(func(o: int) -> void: options.append(o))
	point.pressed.emit()
	here.pressed.emit()
	_check(options == [1, 2], "the buttons choose 1 and 2 (got %s)" % [options])
	box.free()
	var hi := ReviveBox.new()
	hi.build_revive(builder, 11)
	var help := hi.root.find_child("ReviveHelp", true, false) as BaseButton
	_check(help != null and help.disabled and _text(help) == "<UIIT_MSG_MSGBOX_REBIRTH_HELP_BUTTON>", "level 11: the help button, disabled")
	hi.place_on(Vector2(1024, 768))
	_check(hi.position == Vector2(512 - 0x9a, 384 - 0x4a), "placed by 0x6ec5d0 at its opening size")
	hi.free()
	_check(ReviveBox.sml2_element("\"\"\"<sml2>a</sml2>\"\"\"") == "<sml2>a</sml2>" and ReviveBox.sml2_element("plain") == "plain",
		"the <sml2> element of a quoted string")

## HudCosBox.build_guild_name_input: purpose 2.
func _guild_name(builder: UiBuilder) -> void:
	var box := HudCosBox.new()
	_check(box.build_guild_name_input(builder), "the guild name box builds")
	_check(box.size == Vector2(280, 144) and box.caption.text == "<UIIT_STT_INPUT_BOX>", "280 x 144, the input box")
	_check(_text(box.node("GDR_MB_INSERT_MSG_TITLE")) == "<UIIT_MSG_GUILD_NAME_INPUT>" and box.node("GDR_MB_INSERT_MSG_TITLE").position == Vector2(0x1b, 0x2f),
		"the prompt UIIT_MSG_GUILD_NAME_INPUT at (0x1b, 0x2f)")
	# The authored rect (the size itself is clamped by the test's fallback font).
	_check(box.edit is CifEdit and box.edit.max_length == 12
		and box.edit.get_meta(UiBuilder.AUTHORED_RECT_META) == Rect2(0x12, 0x46, 0xf3, 0x14),
		"the edit: a CifEdit, 12 at most, at (0x12, 0x46) 0xf3 x 0x14")
	_check(box.node("GDR_MB_INSERT_MSG_BTN_OK").position == Vector2(0x37, 0x68) and box.node("GDR_MB_INSERT_MSG_BTN_CANC").position == Vector2(0x8f, 0x68),
		"OK (0x37, 0x68), Cancel (0x8f, 0x68)")
	var typed: Array = []
	box.accepted.connect(func(t: String) -> void: typed.append(t))
	box.edit.text = "Lions"
	box.edit.text_submitted.emit("Lions")
	_check(typed == ["Lions"], "Enter accepts with the name")
	box.free()

## The quest give-up box: MsgBoxSimple with the agreement title.
func _give_up(builder: UiBuilder) -> void:
	var box := PartyMatchConfirm.new()
	_check(box.build(builder, "<UIIT_MSG_QUEST_GIVEUP_WINDOW_1>", PartyMatchConfirm.SIZE, "UIIT_STT_AGREEMENT_BOX"), "the give-up box builds")
	_check(box.caption.text == "<UIIT_STT_AGREEMENT_BOX>" and box.size == Vector2(360, 151), "360 x 151, UIIT_STT_AGREEMENT_BOX")
	_check((box.get_node("Message") as Label).text == "<UIIT_MSG_QUEST_GIVEUP_WINDOW_1>", "its text")
	box.free()

func _md_to_pml() -> void:
	var pml := MdToPml.convert("# Title\n\nSome **bold** and `a<b>` [link](http://x).\n- item\n| a | b |\n|---|---|\n| 1 | 2 |")
	_check(pml.begins_with("<sml2><strong><font color=\"255,226,74,0\">Title</font></strong><br>"), "a heading: bold orange (got %s)" % pml)
	_check(pml.contains("Some <strong>bold</strong> and a‹b› link (http://x).") and pml.contains("<br>· item<br>a  b<br>1  2</sml2>"),
		"bold, code with its <> made safe, a link, a bullet, a table (got %s)" % pml)
	_check(MdToPml.convert("one\ntwo\n\nthree") == "<sml2>one two<br><br>three</sml2>",
		"a paragraph's lines are joined, a blank line breaks (got %s)" % MdToPml.convert("one\ntwo\n\nthree"))
	var p := PmlText.new()
	p.size = Vector2(300, 100)
	p.setup(null, 12, Color.BLACK)
	p.set_markup(pml)
	_check(p.plain_lines()[0] == "Title" and p.plain_lines().has("· item"), "PmlText lays the converted page out")
	p.free()
	# PmlText.put_on takes the record's FontColor and HAlign.
	var def := UiLayoutParser.ControlDef.new()
	def.name = "GDR_TEST_PML"
	def.type = "CIFPML"
	def.font_color = Color8(10, 20, 30)
	def.halign = 1
	def.rect = Rect2i(0, 0, 200, 40)
	var host := UiBuilder.new(null, null).build_control(def)
	var put := PmlText.put_on(host, null, "<sml2>x</sml2>")
	_check(put != null and put.base_align == PmlText.TAG_CENTER and put.default_color == Color8(10, 20, 30) and put.size == Vector2(200, 40),
		"PmlText.put_on: the record's HAlign 1, FontColor, rect")
	_check(PmlText.put_on(host, null, "<sml2>y</sml2>") == put, "a second fill reuses it")
	host.free()

func _composite() -> void:
	var win := CompositeItemWindow.new()
	win.set("_builder", UiBuilder.new(null, null))
	win.show_entries([[1, "A", 0], [2, "B", 3]])
	var a := win.get_node_or_null("CompositeButton0") as BaseButton
	var c := win.get_node_or_null("CompositeCancel") as BaseButton
	_check(a is TextureButton and a.disabled and CompositeItemWindow.button_text(a) == "A(0)", "a zero-count button: a CIFButton, disabled")
	_check(c != null and c.position == CompositeItemWindow.BUTTON_ORIGIN + Vector2(0, 2 * CompositeItemWindow.BUTTON_STEP), "Cancel two steps down")
	win.free()

## CifEdit: CIFEdit's caret, keys and mouse.
func _cif_edit() -> void:
	var e := CifEdit.new()
	e.size = Vector2(200, 20)
	e.position = Vector2(100, 100)
	root.add_child(e)
	e.set_colour(Color8(250, 240, 200))
	_check(not e.context_menu_enabled and not e.shortcut_keys_enabled and not e.middle_mouse_paste_enabled,
		"no context menu, no Godot shortcuts, no middle-button paste")
	_check(e.get_theme_constant("caret_width") == 2 and is_equal_approx(e.caret_blink_interval, 0.2) and e.caret_blink,
		"the caret 2 wide, blinking every 200 ms (0xe1b898, CETime at 5 Hz)")
	_check(e.get_theme_color("caret_color") == Color8(250, 240, 200) and e.get_theme_color("font_color") == Color8(250, 240, 200)
		and e.get_theme_color("font_uneditable_color") == Color8(250, 240, 200), "the caret and the text in the FontColor")
	_check(e.get_theme_color("selection_color") == CifEdit.MARK_COLOUR, "the mark's background 0xff3b457a")
	e.text = "abcdef"
	e.caret_column = 6
	# A left press inside gives the keyboard and does not move the caret.
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(110, 110)
	press.global_position = press.position
	root.push_input(press)
	var rel := press.duplicate() as InputEventMouseButton
	rel.pressed = false
	root.push_input(rel)
	await process_frame
	_check(e.has_focus(), "a left press gives the edit the keyboard")
	_check(e.caret_column == 6 and not e.has_selection(), "and leaves the caret where it was, nothing selected (caret %d)" % e.caret_column)
	# A double click selects nothing.
	var dbl := press.duplicate() as InputEventMouseButton
	dbl.double_click = true
	root.push_input(dbl)
	root.push_input(rel)
	_check(not e.has_selection(), "a double click selects nothing")
	# Typing still works.
	root.push_input(_key(KEY_G, false, false, 0x67))
	_check(e.text == "abcdefg", "a character is typed (got %s)" % e.text)
	# Ctrl+A / C / X / V do nothing.
	DisplayServer.clipboard_set("PASTE")
	for k in [KEY_A, KEY_C, KEY_X, KEY_V, KEY_Z]:
		root.push_input(_key(k, true))
	_check(e.text == "abcdefg" and not e.has_selection(), "Ctrl+A, C, X, V and Z do nothing (got %s)" % e.text)
	root.push_input(_key(KEY_INSERT, false, true))
	_check(e.text == "abcdefg", "Shift+Insert pastes nothing")
	# Left moves one character, also with Ctrl and Shift.
	root.push_input(_key(KEY_LEFT, true))
	_check(e.caret_column == 6, "Ctrl+Left moves one character (caret %d)" % e.caret_column)
	root.push_input(_key(KEY_LEFT, false, true))
	_check(e.caret_column == 5 and not e.has_selection(), "Shift+Left moves one character and selects nothing")
	# Ctrl+Backspace deletes one character.
	root.push_input(_key(KEY_BACKSPACE, true))
	_check(e.text == "abcdfg" and e.caret_column == 4, "Ctrl+Backspace deletes one character (got %s, %d)" % [e.text, e.caret_column])
	# Shift+End marks the whole text; a character replaces it.
	root.push_input(_key(KEY_END, false, true))
	_check(e.has_selection() and e.get_selected_text() == "abcdfg", "Shift+End marks the whole text")
	root.push_input(_key(KEY_H, false, false, 0x68))
	_check(e.text == "h", "a character typed over the mark replaces the text (got %s)" % e.text)
	e.text = "xyz"
	e.caret_column = 1
	root.push_input(_key(KEY_HOME, false, true))
	root.push_input(_key(KEY_DELETE))
	_check(e.text == "", "Delete with the mark empties the edit (got %s)" % e.text)
	e.text = "xyz"
	root.push_input(_key(KEY_HOME, false, true))
	root.push_input(_key(KEY_RIGHT))
	_check(not e.has_selection() and e.caret_column == 1, "Right clears the mark and moves one (caret %d)" % e.caret_column)
	# Enter submits and keeps the keyboard (round 754).
	var sent: Array = []
	e.text_submitted.connect(func(t: String) -> void: sent.append(t))
	root.push_input(_key(KEY_ENTER))
	_check(sent == ["xyz"] and e.has_focus(), "Enter submits; the edit keeps the keyboard (round 754)")
	# A right press opens nothing and takes nothing.
	var rp := InputEventMouseButton.new()
	rp.button_index = MOUSE_BUTTON_RIGHT
	rp.pressed = true
	rp.position = Vector2(110, 110)
	rp.global_position = rp.position
	root.push_input(rp)
	_check(e.text == "xyz", "a right press changes nothing")
	e.free()
	# The multi-line edit's rules (the guild notice body).
	var te := TextEdit.new()
	te.size = Vector2(200, 60)
	te.position = Vector2(100, 200)
	root.add_child(te)
	CifEdit.style_text_edit(te, Color.BLACK)
	_check(not te.context_menu_enabled and not te.selecting_enabled and not te.shortcut_keys_enabled
		and te.get_theme_constant("caret_width") == 2, "a multi-line edit: no menu, selection or shortcuts, the 2 px caret")
	var tp := press.duplicate() as InputEventMouseButton
	tp.position = Vector2(110, 210)
	tp.global_position = tp.position
	root.push_input(tp)
	_check(te.has_focus(), "a left press gives the multi-line edit the keyboard")
	te.free()
