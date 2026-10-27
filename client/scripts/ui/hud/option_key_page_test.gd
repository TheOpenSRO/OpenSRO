extends SceneTree

## Round 833: the Key Map tab -- KeyNames (0x5fb544, 0x6ed9e0), KeyMap's live
## keys, and against the real Media.pk2 the page itself (OptionKeyPage).
##   godot4 --headless --path client --script res://scripts/ui/hud/option_key_page_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_names()
	_live_keys()
	_mouse()
	await _page()
	KeyMap.reset_to_defaults_unsaved()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

func _names() -> void:
	var taken := true
	for k in [KEY_A, KEY_Z, KEY_TAB, KEY_SPACE, KEY_SHIFT, KEY_CTRL, KEY_ENTER, KEY_BACKSPACE, KEY_PAGEUP,
			KEY_INSERT, KEY_DELETE, KEY_SEMICOLON, KEY_BRACKETLEFT, KEY_F13, KEY_CAPSLOCK]:
		taken = taken and KeyNames.accepts(k)
	_check(taken, "letters, Tab, Space, Shift, Ctrl, Enter, Backspace, PgUp, Ins, Del, the OEM keys, F13, CapsLock are taken")
	var refused := true
	for k in [KEY_1, KEY_0, KEY_F1, KEY_F10, KEY_F12, KEY_UP, KEY_LEFT, KEY_ESCAPE, KEY_KP_5, KEY_KP_ADD,
			KEY_NUMLOCK, KEY_SCROLLLOCK, KEY_PRINT, KEY_PAUSE, KEY_ALT]:
		refused = refused and not KeyNames.accepts(k)
	_check(refused, "digits, F1-F12, the arrows, Esc, the numpad, NumLock / ScrollLock, PrintScreen, Pause and Alt are refused")
	_check(KeyNames.name_of(KEY_TAB) == "Tab" and KeyNames.name_of(KEY_CAPSLOCK) == "C/L" and KeyNames.name_of(KEY_BACKSPACE) == "←"
		and KeyNames.name_of(KEY_SPACE) == "Space" and KeyNames.name_of(KEY_PAGEDOWN) == "PgDn" and KeyNames.name_of(KEY_F13) == "|",
		"names: Tab, C/L, a left arrow for Backspace, Space, PgDn; F13 (VK 0x7C) is its VK's character, '|' (0x6ed9e0's default)")
	_check(KeyNames.name_of(KEY_C) == "C" and KeyNames.name_of(KEY_SEMICOLON) == ";" and KeyNames.name_of(KEY_NONE) == " ",
		"a letter is itself, ';' its OEM name, an unbound row one space")

func _live_keys() -> void:
	KeyMap.reset_to_defaults_unsaved()
	_check(KeyMap.key_of_slot(0) == KEY_C and KeyMap.slot_for_key(KEY_C)["slot"] == 0, "the defaults: C is slot 0")
	var keys := KeyMap.default_keys()
	keys[0] = KEY_K
	keys[2] = KEY_C
	KeyMap.set_keys(keys, false)
	_check(KeyMap.key_for("panel:character") == KEY_K and int(KeyMap.slot_for_key(KEY_K)["slot"]) == 0
		and int(KeyMap.slot_for_key(KEY_C)["slot"]) == 2 and KeyMap.resolve(KEY_C, false, false, false, false) == ["panel:skill", 2],
		"rebound: K opens the character window, C the skill window (the action stays with the slot)")
	KeyMap.reset_to_defaults_unsaved()
	_check(KeyMap.resolve(KEY_C, false, false, false, false) == ["panel:character", 0], "and back")

func _mouse() -> void:
	var W = load("res://scripts/World3D.gd")
	var drag := InputEventMouseMotion.new()
	drag.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	_check(not W.orbit_motion_applies(drag, true, "free") and W.orbit_motion_applies(drag, true, "free", MOUSE_BUTTON_MASK_MIDDLE),
		"mode 1 turns the camera on a middle drag, mode 0 does not (0x77c2d5)")

func _page() -> void:
	if not FileAccess.file_exists(MEDIA):
		print("SKIP the archive checks (no %s)" % MEDIA)
		return
	var pk2 := Pk2Reader.open(MEDIA)
	if pk2 == null:
		_check(false, "Media.pk2 opens")
		return
	root.size = Vector2i(1280, 720)
	var saved_keys = ClientSettings.get_value(ClientSettings.SECTION_KEYMAP, ClientSettings.KEY_KEYMAP_SLOTS, null)
	var saved_mode = ClientSettings.get_value(ClientSettings.SECTION_UI, ClientSettings.KEY_MOUSE_MODE, null)
	KeyMap.reset_to_defaults_unsaved()
	var win := OptionWindow.new(UiBuilder.new(pk2, null))
	root.add_child(win)
	_check(win.build_option(), "the Option window builds")
	await process_frame
	var page := win.keymap_page
	_check(page != null and page.slot_count() == 14, "fourteen CNIFKeyOptionSlot rows (got %d)" % (page.slot_count() if page != null else -1))
	if page == null or page.slot_count() != 14:
		win.queue_free()
		return
	_check(page.key_text_at_slot(0) == "C" and page.key_text_at_slot(1) == "I" and page.key_text_at_slot(8) == "Tab"
		and page.label_text_at_slot(0) == "UIIT_STT_CHARACTER", "line 0: C Character, I Inventory; row 8 Tab (no text table here: the ids)")
	(win.control([OptionWindow.ID_TAB_INPUT]) as BaseButton).pressed.emit()
	_check(win.current_tab() == OptionWindow.ID_TAB_INPUT, "the Key Map tab is up")
	_check(not win._capture_key(KEY_S), "no row selected: a key goes to the game")
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	page.slot_node(0).gui_input.emit(press)
	_check(page.selected == 0 and page.select_shown_at_slot(0) and not page.select_shown_at_slot(1),
		"a press on the Character row selects it: its key box shows opt_key_select")
	_check(win._capture_key(KEY_I) and page.key_text_at_slot(0) == "I" and page.key_text_at_slot(1) == " ",
		"I: the Character row takes it and the Inventory row is unbound (no swap)")
	_check(win._capture_key(KEY_1) and page.key_text_at_slot(0) == "I", "a digit is refused: nothing changes (the key is still the page's)")
	_check(not win._capture_key(KEY_ESCAPE), "Esc is left to the window, which closes")
	_check(win._capture_key(KEY_K) and page.key_text_at_slot(0) == "K" and page.selected == 0,
		"the row stays selected and takes the next key too")
	page.scroll_to(99)
	_check(page.scroll_line() == 10 and page.slot_node(13).visible == false and page.key_text_at_slot(0) == "R",
		"scrolled to the end: line 10 shows rows 20..32 (Reply whisper's R first), the last slot hidden")
	page.scroll_to(0)
	_check(KeyMap.key_of_slot(0) == KEY_C, "nothing is in force before Apply")
	(win.control([OptionWindow.ID_TAB_VIDEO]) as BaseButton).pressed.emit()
	_check(not win._capture_key(KEY_J), "another tab up: keys go to the game (0x5fb460 answers only on the Key Map tab)")
	(win.control([OptionWindow.ID_TAB_INPUT]) as BaseButton).pressed.emit()
	page.radio(1).toggled.emit(true)
	var modes: Array[int] = []
	win.mouse_mode_changed.connect(func(m: int) -> void: modes.append(m))
	win.press_apply()
	_check(KeyMap.key_of_slot(0) == KEY_K and KeyMap.key_of_slot(1) == KEY_NONE and modes == [1] and ClientSettings.mouse_mode() == 1,
		"Apply on the tab: K is the character key, Inventory unbound, mouse mode 1 in force")
	win.press_default()
	_check(page.key_text_at_slot(0) == "C" and page.mouse_mode == 0 and modes == [1, 0] and ClientSettings.mouse_mode() == 0
		and KeyMap.key_of_slot(0) == KEY_K, "Default: the rows back to C..., mode 0 at once, the keys not yet")
	var cap := win.control([OptionWindow.ID_TAB_INPUT]).get_node_or_null(TwoDtBuilder.TEXT_NODE) as Label
	var other := win.control([OptionWindow.ID_TAB_VIDEO]).get_node_or_null(TwoDtBuilder.TEXT_NODE) as Label
	_check(cap != null and other != null and (cap.get_theme_font("font") != other.get_theme_font("font")),
		"the checked tab's caption is drawn semi-bold, the others not (0x47a950)")
	win.queue_free()
	KeyMap.reset_to_defaults_unsaved()
	ClientSettings.set_value(ClientSettings.SECTION_KEYMAP, ClientSettings.KEY_KEYMAP_SLOTS, saved_keys if saved_keys != null else Array(KeyMap.default_keys()))
	ClientSettings.set_value(ClientSettings.SECTION_UI, ClientSettings.KEY_MOUSE_MODE, saved_mode if saved_mode != null else 0)
