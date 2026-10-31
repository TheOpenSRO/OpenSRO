extends SceneTree

## Round 848: no native Godot GUI before the world.
##   godot4 --headless --path client --script res://scripts/frontend/frontend_native_test.gd
##
## - CifEditStyle (READ, CIFEdit): a 2 px caret in the font's colour blinking
##   every 0.2 s; no context menu, no shortcut keys, no selecting; a click
##   only focuses the edit (the caret stays put) and typing still types;
##   Ctrl+V pastes nothing; Up / Down keep the focus; 512 characters by
##   default.
## - FrontEndUi.cif_button: a TextureButton with its caption a Label, the
##   caption 0xffe6e6e6 while disabled (READ, CIFButton) and the layout's
##   colour again after.
## - FrontMessageBox (the update prompt): no Godot dialog or Button in it;
##   YES and NO answer once; Escape answers No.
## - The sources: Boot has no ConfirmationDialog; the screens make no
##   Button.new() / Panel.new() outside the no-archive fallbacks; the
##   loading screen draws no Panel and no caption Label.
##
## NEGATIVE (fails before round 848): CifEditStyle, FrontMessageBox and
## FrontEndUi.cif_button do not exist (the suite's script loads FAIL),
## Boot.gd makes a ConfirmationDialog, CharacterSelect / ServerListWindow /
## Login make their buttons with Button.new(), the loading screen a Panel.

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
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	var have_edit := ResourceLoader.exists("res://scripts/frontend/cif_edit_style.gd")
	var have_box := ResourceLoader.exists("res://scripts/frontend/front_message_box.gd")
	_check(have_edit, "CifEditStyle exists")
	_check(have_box, "FrontMessageBox exists")
	if have_edit:
		await _edit_rules()
	await _button_caption()
	if have_box:
		await _message_box()
	_sources()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit()

func _key(code: Key, unicode: int = 0, ctrl: bool = false) -> void:
	for pressed in [true, false]:
		var k := InputEventKey.new()
		k.keycode = code
		k.physical_keycode = code
		k.unicode = unicode if pressed else 0
		k.ctrl_pressed = ctrl
		k.pressed = pressed
		root.push_input(k)

func _click(at: Vector2, button := MOUSE_BUTTON_LEFT) -> void:
	for pressed in [true, false]:
		var m := InputEventMouseButton.new()
		m.button_index = button
		m.pressed = pressed
		m.position = at
		m.global_position = at
		root.push_input(m)

func _edit_rules() -> void:
	var holder := Control.new()
	holder.size = Vector2(400, 200)
	root.add_child(holder)
	var a := LineEdit.new()
	a.position = Vector2(10, 10)
	a.size = Vector2(200, 20)
	holder.add_child(a)
	var b := LineEdit.new()
	b.position = Vector2(10, 60)
	b.size = Vector2(200, 20)
	holder.add_child(b)
	var colour := Color8(255, 103, 29)
	CifEditStyle.apply(a, colour)
	CifEditStyle.apply(b, colour)
	_check(not a.context_menu_enabled and not a.shortcut_keys_enabled and not a.selecting_enabled \
			and not a.middle_mouse_paste_enabled and not a.drag_and_drop_selection_enabled,
		"no context menu, shortcut keys, selecting, middle-click paste or drag (READ: CIFEdit has none)")
	_check(a.get_theme_constant(&"caret_width") == 2, "the caret is 2 px wide (READ 0xe1b898)")
	_check(a.get_theme_color(&"caret_color") == colour, "the caret is the font's colour (READ +0xa0)")
	_check(a.caret_blink and is_equal_approx(a.caret_blink_interval, 0.2), "the caret blinks every 0.2 s (READ, rate 5)")
	_check(a.max_length == 512, "512 characters by default (READ, +0x400 = 0x200)")
	await process_frame
	a.text = "abc"
	a.caret_column = 1
	_click(Vector2(200, 20))
	await process_frame
	_check(a.has_focus(), "a click focuses the edit")
	_check(a.caret_column == 1, "a click does not move the caret (READ 0x6378a5; got %d)" % a.caret_column)
	_key(KEY_X, "x".unicode_at(0))
	await process_frame
	_check(a.text == "axbc", "typing still types at the caret (got '%s')" % a.text)
	DisplayServer.clipboard_set("PASTED")
	_key(KEY_V, 0, true)
	await process_frame
	_check(a.text == "axbc", "Ctrl+V pastes nothing (READ: no 0x200 flag; got '%s')" % a.text)
	_key(KEY_A, 0, true)
	await process_frame
	_check(not a.has_selection(), "Ctrl+A selects nothing")
	_key(KEY_DOWN)
	await process_frame
	_check(a.has_focus() and not b.has_focus(), "Down keeps the focus in the edit (READ: a no-op)")
	_click(Vector2(50, 20), MOUSE_BUTTON_RIGHT)
	await process_frame
	_check(a.get_menu() == null or not a.get_menu().visible, "a right click opens no menu")
	holder.queue_free()
	await process_frame

func _button_caption() -> void:
	var def := UiLayoutParser.ControlDef.new()
	def.type = "CIFButton"
	def.halign = 1
	def.valign = 1
	def.font_color = Color8(255, 254, 251, 216)
	def.rect = Rect2i(0, 0, 76, 24)
	var b := FrontEndUi.cif_button(UiBuilder.new(null, null), def, "Yes", FrontEndUi.OUTER_BUTTON_DDJ, Vector2(76, 24))
	root.add_child(b)
	await process_frame
	_check(b is TextureButton, "a front-end button is a TextureButton")
	_check(FrontEndUi.cif_button_text(b) == "Yes", "its caption is a label (%s)" % FrontEndUi.cif_button_text(b))
	_check(b.size == Vector2(76, 24), "at the layout's size (%s)" % b.size)
	var l := b.get_node("ButtonLabel") as Label
	b.disabled = true
	await process_frame
	await process_frame
	_check(l.get_theme_color(&"font_color") == FrontEndUi.DISABLED_CAPTION,
		"disabled: the caption is 0xffe6e6e6 (READ 0x655ea0; got %s)" % l.get_theme_color(&"font_color"))
	b.disabled = false
	await process_frame
	await process_frame
	_check(l.get_theme_color(&"font_color") == def.font_color, "enabled again: the layout's colour")
	b.queue_free()
	await process_frame

func _message_box() -> void:
	var box := FrontMessageBox.new()
	root.add_child(box)
	box.build(null, null, "A new version (v9.9.9) is available.", "Download and restart now?")
	await process_frame
	_check(box.find_children("*", "AcceptDialog", true, false).is_empty() \
			and box.find_children("*", "Button", true, false).is_empty() \
			and box.find_children("*", "Panel", true, false).is_empty(),
		"no Godot dialog, Button or Panel in the box")
	_check(box.yes_button is TextureButton and box.no_button is TextureButton, "YES and NO are CIFButtons")
	_check(box.line_text(box.line1).contains("v9.9.9"), "line 1 names the version")
	_check(box.box.size == FrontMessageBox.SIZE, "the box is 308 x 148 (READ)")
	var yes := [0]
	var no := [0]
	box.accepted.connect(func() -> void: yes[0] += 1)
	box.declined.connect(func() -> void: no[0] += 1)
	box.yes_button.pressed.emit()
	box.no_button.pressed.emit()
	_check(yes[0] == 1 and no[0] == 0, "YES answers once, and nothing after")
	box.queue_free()
	var box2 := FrontMessageBox.new()
	root.add_child(box2)
	box2.build(null, null, "x", "")
	var no2 := [0]
	box2.declined.connect(func() -> void: no2[0] += 1)
	await process_frame
	_key(KEY_ESCAPE)
	await process_frame
	_check(no2[0] == 1, "Escape answers No (OURS)")
	box2.queue_free()
	await process_frame

func _src(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""

## The source without the no-archive fallbacks' functions (named here).
func _without(src: String, funcs: Array) -> String:
	var out := src
	for fn in funcs:
		var at := out.find("\nfunc %s(" % fn)
		if at < 0:
			continue
		var re := RegEx.create_from_string("\n(static )?func ")
		var m := re.search(out, at + 1)
		var end := m.get_start() if m != null else out.length()
		out = out.substr(0, at) + out.substr(end)
	return out

func _sources() -> void:
	var boot := _src("res://scripts/Boot.gd")
	_check(boot != "" and not boot.contains("ConfirmationDialog.new"), "Boot makes no ConfirmationDialog")
	var login := _without(_src("res://scripts/Login.gd"), ["_build_ui", "_slot_field", "_plate", "_text_button", "_button_style"])
	_check(login != "" and not login.contains("Button.new()") and not login.contains("PanelContainer.new()"),
		"Login makes no Button / PanelContainer outside the no-archive screen")
	var sel := _src("res://scripts/CharacterSelect.gd")
	_check(sel != "" and not sel.contains("Button.new()") and not sel.contains("Panel.new()"),
		"CharacterSelect makes no Button / Panel")
	var list := _src("res://scripts/frontend/server_list_window.gd")
	_check(list != "" and not list.contains("Button.new()"), "ServerListWindow makes no Button")
	var lock := _src("res://scripts/frontend/charselect_lock.gd")
	_check(lock != "" and not lock.contains("Button.new()"), "CharSelectLock makes no Button")
	var load := _src("res://scripts/ui/loading_screen.gd")
	_check(load != "" and not load.contains("Panel.new()") and not load.contains("FrontEndUi.label("),
		"the loading screen draws no Panel and no caption label")
	for p in ["res://scripts/Login.gd", "res://scripts/CharacterCreate.gd", "res://scripts/frontend/captcha_window.gd",
			"res://scripts/frontend/charselect_rename.gd"]:
		_check(_src(p).contains("CifEditStyle.apply("), "%s gives its edits CIFEdit's rules" % p.get_file())
