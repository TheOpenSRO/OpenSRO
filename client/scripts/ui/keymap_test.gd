extends SceneTree

## The keyboard is the retail client's key table (round 608): KeyMap holds
## it, KeyInput runs it, HudPanels opens the windows from it. Every binding
## is driven through Viewport.push_input -- Godot's own routing, _input
## before the GUI and _unhandled_key_input after it, as a player's keys go --
## into a HudPanels whose toggle() is recorded and a KeyInput whose host is
## a recorder. Checked: what each key does, that nothing fires while a text
## line has the keyboard, that the held keys (V, Z, Space) let go on their
## release, on a line taking the keyboard and on the window losing focus,
## and that no key moves the character any more (no move_* actions). The
## pure parts -- G's 50-unit search, Z's 300-unit names, what V hides, F9's
## cycle, the screenshot name, R's line -- are checked directly.
##
## Scripts are loaded by path, so the suite runs (and fails, line by line)
## against a tree without them:
##   godot4 --headless --path client --script res://scripts/ui/keymap_test.gd

const KEYMAP_PATH := "res://scripts/ui/keymap.gd"
const KEY_INPUT_PATH := "res://scripts/ui/key_input.gd"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"
const UNDERBAR_PATH := "res://scripts/ui/hud/hud_underbar.gd"

var _failures := 0
## [action, arg] per run() the KeyInput host saw.
var _runs: Array = []
## [action, down] per held() call.
var _holds: Array = []
var _typing_line: LineEdit
## Round 808: what the "arrow" host heard: [keycode, down, echo].
var _arrows: Array = []
var _panels: Control
var _key_input: Node
var _map_toggles := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await _run()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

# --- input through the viewport ----------------------------------------------

func _event(code: int, pressed: bool, ctrl := false, echo := false) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code as Key
	ev.physical_keycode = code as Key
	ev.key_label = code as Key
	ev.pressed = pressed
	ev.echo = echo
	ev.ctrl_pressed = ctrl
	var name := OS.get_keycode_string(code as Key)
	if pressed and not ctrl and name.length() == 1:
		ev.unicode = name.to_lower().unicode_at(0)
	return ev

func _down(code: int, ctrl := false) -> void:
	get_root().push_input(_event(code, true, ctrl))

func _up(code: int, ctrl := false) -> void:
	get_root().push_input(_event(code, false, ctrl))

func _tap(code: int, ctrl := false) -> void:
	_down(code, ctrl)
	_up(code, ctrl)

## What one tap did: [runs, panel toggles, world map toggles], each since
## the tap.
func _what(code: int, ctrl := false) -> Array:
	var runs_before := _runs.size()
	var toggles: Array = _panels.get("toggled") if _panels != null else []
	var toggles_before := toggles.size()
	var maps_before := _map_toggles
	_tap(code, ctrl)
	return [_runs.slice(runs_before), toggles.slice(toggles_before), _map_toggles - maps_before]

func _name(code: int, ctrl := false) -> String:
	return ("Ctrl+" if ctrl else "") + OS.get_keycode_string(code as Key)

# --- the checks ----------------------------------------------------------------

func _run() -> void:
	await process_frame
	get_root().size = Vector2i(1152, 648)
	var keymap := load(KEYMAP_PATH) as GDScript
	var key_input_script := load(KEY_INPUT_PATH) as GDScript
	_check(keymap != null, "the key table exists (%s)" % KEYMAP_PATH)
	_check(key_input_script != null, "the key runner exists (%s)" % KEY_INPUT_PATH)

	var ui := Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_root().add_child(ui)
	# HudPanels with toggle() recorded: the windows are not built, only asked for.
	var rec := GDScript.new()
	rec.source_code = "extends \"%s\"\nvar toggled: Array = []\nfunc toggle(panel_id: String) -> void:\n\ttoggled.append(panel_id)\n" % PANELS_PATH
	rec.reload()
	_panels = rec.new()
	ui.add_child(_panels)
	_panels.connect("world_map_toggle_requested", func() -> void: _map_toggles += 1)
	_typing_line = LineEdit.new()
	_typing_line.name = "TypingLine"
	_typing_line.position = Vector2(10, 10)
	_typing_line.size = Vector2(200, 24)
	ui.add_child(_typing_line)
	if key_input_script != null:
		_key_input = key_input_script.new({
			"is_typing": func() -> bool: return bool(_panels.call("is_typing")),
			"run": func(action: String, arg: int) -> String:
				_runs.append([action, arg])
				return "recorded",
			"held": func(action: String, down: bool) -> void: _holds.append([action, down]),
			"arrow": func(code: int, down: bool, echo: bool) -> String:
				_arrows.append([code, down, echo])
				return "recorded",
		})
		get_root().add_child(_key_input)
	await process_frame

	_check_table(keymap)
	_check_windows()
	_check_world_keys()
	await _check_arrows()
	_check_outside_keys()
	await _check_holds()
	_check_typing()
	await _check_focus_button()
	_check_no_movement()
	_check_pure(keymap)
	await _check_ground_items(keymap)

## The slot table itself: 33 slots in slot order, each on the retail default
## key and command (0x7778be, 0x778310).
func _check_table(keymap: GDScript) -> void:
	if keymap == null:
		_check(false, "the slot table: no KeyMap to read")
		return
	var slots: Array = keymap.get_script_constant_map().get("SLOTS", [])
	_check(slots.size() == 33, "the table has the retail client's 33 slots (got %d)" % slots.size())
	var want := [KEY_C, KEY_I, KEY_S, KEY_A, KEY_P, KEY_Q, KEY_U, KEY_M, KEY_TAB, KEY_H, KEY_Z, KEY_X,
		KEY_N, KEY_G, KEY_INSERT, KEY_HOME, KEY_PAGEUP, KEY_DELETE, KEY_END, KEY_PAGEDOWN, KEY_R, KEY_T,
		KEY_W, KEY_E, KEY_Y, KEY_NONE, KEY_NONE, KEY_NONE, KEY_NONE, KEY_V, KEY_L, KEY_NONE, KEY_NONE]
	var cmds := [0x43, 0x49, 0x53, 0x41, 0x50, 0x51, 0x55, 0x4d, 0x09, 0x48, 0x5a, 0x58, 0x4e, 0x47, 0x2d,
		0x24, 0x21, 0x2e, 0x23, 0x22, 0x52, 0x54, 0x57, 0x45, 0x59, 0x8019, 0x801a, 0x801b, 0x801c, 0x56,
		0x4c, 0x801f, 0x8020]
	var bad: Array = []
	for i in mini(slots.size(), 33):
		var slot: Dictionary = slots[i]
		if int(slot["slot"]) != i or int(slot["key"]) != want[i] or int(slot["cmd"]) != cmds[i]:
			bad.append(i)
	_check(bad.is_empty(), "every slot is the retail default key and command, in slot order (wrong: %s)" % [bad])

## The windows' keys, through HudPanels.
func _check_windows() -> void:
	var windows := {KEY_C: "character", KEY_I: "inventory", KEY_S: "skill", KEY_A: "action", KEY_P: "party",
		KEY_Q: "quest", KEY_U: "guild", KEY_T: "autopotion", KEY_E: "partymatch", KEY_Y: "alchemy",
		KEY_L: "academy"}
	for code in windows:
		var got := _what(code)
		_check(got[1] == [windows[code]] and got[0].is_empty(),
			"%s opens the %s window and runs nothing else (toggled %s, ran %s)" % [_name(code), windows[code], got[1], got[0]])
	var m := _what(KEY_M)
	_check(m[2] == 1 and m[1].is_empty(), "M asks for the world map (%d, toggled %s)" % [m[2], m[1]])
	# This client's own keys that retail does not have are gone.
	for code in [KEY_K, KEY_O]:
		var got := _what(code)
		_check(got[0].is_empty() and got[1].is_empty(), "%s does nothing (retail has no %s; toggled %s, ran %s)" % [
			_name(code), _name(code), got[1], got[0]])
	var g := _what(KEY_G)
	_check(not g[1].has("guild"), "G does not open the guild window (toggled %s)" % [g[1]])

## The table's other keys, through KeyInput.
func _check_world_keys() -> void:
	var keys := {KEY_TAB: ["berserk", 8], KEY_H: ["help", 9], KEY_X: ["mouse_slot", 11], KEY_N: ["sit", 12],
		KEY_G: ["pickup", 13], KEY_INSERT: ["pet_info", 14], KEY_HOME: ["pet_ride", 15],
		KEY_PAGEUP: ["pet_unsummon", 16], KEY_DELETE: ["pet_follow", 17], KEY_END: ["pet_attack", 18],
		KEY_PAGEDOWN: ["pet_ai", 19], KEY_R: ["whisper_reply", 20], KEY_W: ["pet_switch", 22]}
	for code in keys:
		var got := _what(code)
		_check(got[0] == [keys[code]] and got[1].is_empty(),
			"%s runs %s (slot %d) (ran %s, toggled %s)" % [_name(code), keys[code][0], keys[code][1], got[0], got[1]])
	# Keys retail does not bind do nothing here.
	for code in [KEY_D, KEY_J, KEY_F5, KEY_F12]:
		var got := _what(code)
		_check(got[0].is_empty() and got[1].is_empty(), "%s does nothing (ran %s)" % [_name(code), got[0]])

## Round 808: the arrows reach the host's "arrow" callable -- the press, each
## OS repeat (echo) and the release; Down too (the world does nothing with it,
## READ) -- and run no table slot; while a text line has the keyboard they are
## the line's, and a held one is let go when it takes it.
func _check_arrows() -> void:
	_arrows.clear()
	var runs_before := _runs.size()
	get_root().push_input(_event(KEY_LEFT, true))
	get_root().push_input(_event(KEY_LEFT, true, false, true))
	get_root().push_input(_event(KEY_LEFT, false))
	_check(_arrows == [[KEY_LEFT, true, false], [KEY_LEFT, true, true], [KEY_LEFT, false, false]] and _runs.size() == runs_before,
		"Left's press, repeat and release reach the arrow path, no slot (%s)" % str(_arrows))
	_arrows.clear()
	for code in [KEY_UP, KEY_RIGHT, KEY_DOWN]:
		_tap(code)
	_check(_arrows.size() == 6 and _arrows[0] == [KEY_UP, true, false] and _arrows[5] == [KEY_DOWN, false, false],
		"Up, Right and Down reach it too (%s)" % str(_arrows))
	_arrows.clear()
	get_root().push_input(_event(KEY_UP, true))
	_typing_line.grab_focus()
	await process_frame
	_check(_arrows.size() == 1 and _key_input._arrows_down.is_empty(), "a held Up is let go when a line takes the keyboard (%s)" % str(_arrows))
	_tap(KEY_LEFT)
	_check(_arrows.size() == 1, "typing, the arrows are the line's")
	_typing_line.release_focus()
	await process_frame

## F-keys, digits, Space+digit, Ctrl+digit, PrintScreen and the developer keys.
func _check_outside_keys() -> void:
	for i in 4:
		var code: int = KEY_F1 + i
		var got := _what(code)
		_check(got[0] == [["page", i + 1]], "%s selects hotbar page %d (ran %s)" % [_name(code), i + 1, got[0]])
	var digits := [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9, KEY_0]
	for i in digits.size():
		var got := _what(digits[i])
		_check(got[0] == [["quickslot_key", i + 1]], "%s fires the page's slot key %d (ran %s)" % [_name(digits[i]), i + 1, got[0]])
	_down(KEY_SPACE)
	for i in digits.size():
		var got := _what(digits[i])
		_check(got[0] == [["quickslot", 41 + i]], "Space+%s fires quick slot %d (ran %s)" % [_name(digits[i]), 41 + i, got[0]])
	_up(KEY_SPACE)
	var after := _what(KEY_1)
	_check(after[0] == [["quickslot_key", 1]], "after Space's release 1 is the page's slot again (ran %s)" % [after[0]])
	var self_sel := _what(KEY_1, true)
	_check(self_sel[0] == [["select_self", 0]], "Ctrl+1 selects yourself (ran %s)" % [self_sel[0]])
	for n in range(2, 9):
		var got := _what(KEY_0 + n, true)
		_check(got[0] == [["select_party", n - 1]], "Ctrl+%d selects party member %d (ran %s)" % [n, n - 1, got[0]])
	for code in [KEY_9, KEY_0]:
		var got := _what(code, true)
		_check(got[0].is_empty(), "Ctrl+%s does nothing (0x780c31's range is '1'..'8'; ran %s)" % [_name(code), got[0]])
	var f9 := _what(KEY_F9)
	_check(f9[0] == [["camera_cycle", 0]], "F9 cycles the camera view (ran %s)" % [f9[0]])
	var f10 := _what(KEY_F10)
	_check(f10[0] == [["hide_ui", 0]], "F10 hides the UI (ran %s)" % [f10[0]])
	var before := _runs.size()
	_down(KEY_PRINT)
	_check(_runs.size() == before, "PrintScreen does nothing on its press")
	_up(KEY_PRINT)
	_check(_runs.slice(before) == [["screenshot", 0]], "PrintScreen saves a screenshot on its release (ran %s)" % [_runs.slice(before)])
	for pair in [[KEY_F1, "dev_tools"], [KEY_F2, "debug_tabs"], [KEY_F3, "debug_panel"]]:
		var got := _what_mod(pair[0], ["shift"])
		_check(got[0] == [[pair[1], 0]], "Shift+%s toggles %s (ran %s)" % [_name(pair[0]), pair[1], got[0]])
		# Round 699: Ctrl+F1-F3 are retail's pages again (macOS keeps Ctrl+F1-F3).
		var page := _what_mod(pair[0], ["ctrl"])
		_check(page[0] == [["page", pair[0] - KEY_F1 + 1]], "Ctrl+%s selects its page, as retail (ran %s)" % [_name(pair[0]), page[0]])
	_check_modifiers()

## A modified press: mods is any of "ctrl", "shift", "alt", "meta".
func _what_mod(code: int, mods: Array) -> Array:
	var runs_before := _runs.size()
	var toggles: Array = _panels.get("toggled") if _panels != null else []
	var toggles_before := toggles.size()
	var ev := _event(code, true, mods.has("ctrl"))
	ev.shift_pressed = mods.has("shift")
	ev.alt_pressed = mods.has("alt")
	ev.meta_pressed = mods.has("meta")
	ev.unicode = 0
	get_root().push_input(ev)
	var up := _event(code, false)
	get_root().push_input(up)
	return [_runs.slice(runs_before), toggles.slice(toggles_before)]

## Retail tests no modifier for a table key (0x778310, 0x780610): Ctrl,
## Shift and Alt change nothing there. Meta is ours: nothing.
func _check_modifiers() -> void:
	for mods in [["ctrl"], ["shift"], ["alt"]]:
		var s_key := _what_mod(KEY_S, mods)
		_check(s_key[1] == ["skill"], "%s+S opens the skill window (toggled %s)" % [mods[0], s_key[1]])
		var g_key := _what_mod(KEY_G, mods)
		_check(g_key[0] == [["pickup", 13]], "%s+G picks up (ran %s)" % [mods[0], g_key[0]])
		var f9 := _what_mod(KEY_F9, mods)
		_check(f9[0] == [["camera_cycle", 0]], "%s+F9 cycles the camera (ran %s)" % [mods[0], f9[0]])
	var shift_one := _what_mod(KEY_1, ["shift"])
	_check(shift_one[0] == [["quickslot_key", 1]], "shift+1 fires the page's slot 1 (ran %s)" % [shift_one[0]])
	# Round 788, OURS: Alt+digit is the first extra quick-slot bar's (retail's
	# Alt+digit is unread -- WM_SYSKEYDOWN is not in its message map).
	var alt_one := _what_mod(KEY_1, ["alt"])
	_check(alt_one[0] == [["ext_quickslot", 1]], "alt+1 fires the extra bar's slot 1 (ran %s)" % [alt_one[0]])
	var alt_zero := _what_mod(KEY_0, ["alt"])
	_check(alt_zero[0] == [["ext_quickslot", 10]], "alt+0 fires the extra bar's slot 10 (ran %s)" % [alt_zero[0]])
	var ctrl_alt_two := _what_mod(KEY_2, ["ctrl", "alt"])
	_check(ctrl_alt_two[0] == [["select_party", 1]], "Ctrl wins over Alt: Ctrl+Alt+2 selects (ran %s)" % [ctrl_alt_two[0]])
	for mods in [["ctrl"], ["alt"]]:
		var f1 := _what_mod(KEY_F1, mods)
		_check(f1[0] == [["page", 1]], "%s+F1 selects page 1 (ran %s)" % [mods[0], f1[0]])
	# The OS's window combinations do nothing (ours; retail's are unread).
	var alt_tab := _what_mod(KEY_TAB, ["alt"])
	_check(alt_tab[0].is_empty(), "Alt+Tab does not go berserk (ran %s)" % [alt_tab[0]])
	var alt_f4 := _what_mod(KEY_F4, ["alt"])
	_check(alt_f4[0].is_empty(), "Alt+F4 does not select page 4 (ran %s)" % [alt_f4[0]])
	var alt_space := _event(KEY_SPACE, true)
	alt_space.alt_pressed = true
	get_root().push_input(alt_space)
	var after_alt_space := _what(KEY_1)
	get_root().push_input(_event(KEY_SPACE, false))
	_check(after_alt_space[0] == [["quickslot_key", 1]],
		"Alt+Space starts no Space chord: 1 is the page's slot (ran %s)" % [after_alt_space[0]])
	var shift_f4 := _what_mod(KEY_F4, ["shift"])
	_check(shift_f4[0] == [["page", 4]], "Shift+F4 selects page 4 (only Shift+F1-F3 are ours; ran %s)" % [shift_f4[0]])
	var meta := _what_mod(KEY_G, ["meta"])
	var meta_s := _what_mod(KEY_S, ["meta"])
	_check(meta[0].is_empty() and meta_s[1].is_empty(), "Meta+G and Meta+S do nothing (ran %s, toggled %s)" % [meta[0], meta_s[1]])

## V and Z act while held.
func _check_holds() -> void:
	if _key_input == null:
		_check(false, "held keys: no KeyInput")
		return
	for pair in [[KEY_V, "hide_objects"], [KEY_Z, "item_names"]]:
		var code: int = pair[0]
		var action: String = pair[1]
		var holds_before := _holds.size()
		_down(code)
		_check(bool(_key_input.call("is_held", action)), "%s held turns %s on" % [_name(code), action])
		get_root().push_input(_event(code, true, false, true))
		_check(_holds.slice(holds_before) == [[action, true]], "a held %s's repeats change nothing (heard %s)" % [_name(code), _holds.slice(holds_before)])
		_up(code)
		_check(not bool(_key_input.call("is_held", action)) and _holds.slice(holds_before) == [[action, true], [action, false]],
			"%s's release turns %s off (heard %s)" % [_name(code), action, _holds.slice(holds_before)])
	# A text line taking the keyboard lets go: its release is the line's.
	_down(KEY_V)
	_typing_line.grab_focus()
	await process_frame
	_check(not bool(_key_input.call("is_held", "hide_objects")), "V lets go when a text line takes the keyboard")
	_up(KEY_V)
	_typing_line.release_focus()
	# The window losing the focus lets go (CGInterface::vslot_012).
	_down(KEY_Z)
	_key_input.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(not bool(_key_input.call("is_held", "item_names")), "Z lets go when the window loses the focus")
	_up(KEY_Z)
	_down(KEY_SPACE)
	_key_input.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	var got := _what(KEY_1)
	_check(got[0] == [["quickslot_key", 1]], "Space lets go with the focus too (ran %s)" % [got[0]])
	_up(KEY_SPACE)

## Nothing fires while a text line has the keyboard.
func _check_typing() -> void:
	_typing_line.grab_focus()
	# Tab last: Godot's own focus_next may take it out of the line (not a
	# key-table matter), and every key after it would then not be typed.
	var codes := [KEY_C, KEY_I, KEY_S, KEY_A, KEY_P, KEY_Q, KEY_U, KEY_M, KEY_H, KEY_Z, KEY_X, KEY_N,
		KEY_G, KEY_INSERT, KEY_HOME, KEY_PAGEUP, KEY_DELETE, KEY_END, KEY_PAGEDOWN, KEY_R, KEY_T, KEY_W, KEY_E,
		KEY_Y, KEY_V, KEY_L, KEY_1, KEY_0]
	var ran: Array = []
	for code in codes:
		var got := _what(code)
		if not got[0].is_empty() or not got[1].is_empty() or got[2] != 0:
			ran.append(_name(code))
	for code in [KEY_1, KEY_5]:
		var got := _what(code, true)
		if not got[0].is_empty():
			ran.append(_name(code, true))
	# The keys a line never takes still run (round 608's review): after a
	# line of chat the line keeps the focus, and Shift+F3 is the bug-report
	# path.
	var still := {KEY_F1: ["page", 1], KEY_F4: ["page", 4], KEY_F9: ["camera_cycle", 0], KEY_F10: ["hide_ui", 0]}
	var dead: Array = []
	for code in still:
		var got := _what(code)
		if got[0] != [still[code]]:
			dead.append("%s ran %s" % [_name(code), got[0]])
	for pair in [[KEY_F1, "dev_tools"], [KEY_F2, "debug_tabs"], [KEY_F3, "debug_panel"]]:
		var got := _what_mod(pair[0], ["shift"])
		if got[0] != [[pair[1], 0]]:
			dead.append("Shift+%s ran %s" % [_name(pair[0]), got[0]])
	var before := _runs.size()
	_down(KEY_PRINT)
	_up(KEY_PRINT)
	if _runs.slice(before) != [["screenshot", 0]]:
		dead.append("PrintScreen ran %s" % [_runs.slice(before)])
	_check(dead.is_empty() and get_root().gui_get_focus_owner() == _typing_line,
		"with a text line focused F1-F4, F9, F10, Shift+F1-F3 and PrintScreen still run, and the line keeps the focus (%s)" % [dead])
	_down(KEY_V)
	var held := _key_input != null and bool(_key_input.call("is_held", "hide_objects"))
	_up(KEY_V)
	if get_root().gui_get_focus_owner() == _typing_line:
		var tab := _what(KEY_TAB)
		if not tab[0].is_empty():
			ran.append("Tab")
	_check(ran.is_empty() and not held, "with a text line focused no letter, digit, Tab or editing key runs or opens anything (ran: %s; V held: %s)" % [ran, held])
	_check(_typing_line.text.length() > 0, "the letters went into the line instead (%d characters)" % _typing_line.text.length())
	_typing_line.text = ""
	_typing_line.release_focus()

## A button the mouse left with the keyboard focus does not take Tab (the
## GUI consumes Tab with a focused button: KeyInput's doc has the probe).
func _check_focus_button() -> void:
	var btn := Button.new()
	btn.focus_mode = Control.FOCUS_ALL
	btn.position = Vector2(300, 10)
	btn.size = Vector2(80, 24)
	get_root().add_child(btn)
	var other := Button.new()
	other.focus_mode = Control.FOCUS_ALL
	other.position = Vector2(400, 10)
	other.size = Vector2(80, 24)
	get_root().add_child(other)
	await process_frame
	var btn_presses := [0]
	btn.pressed.connect(func() -> void: btn_presses[0] += 1)
	btn.grab_focus()
	_down(KEY_SPACE)
	var chord := _what(KEY_1)
	_up(KEY_SPACE)
	await process_frame
	_check(chord[0] == [["quickslot", 41]] and btn_presses[0] == 0,
		"Space+1 with a button focused fires slot 41 and does not press the button (ran %s, pressed %d)" % [chord[0], btn_presses[0]])
	var got := _what(KEY_TAB)
	_check(got[0] == [["berserk", 8]] and get_root().gui_get_focus_owner() == btn,
		"Tab with a button focused is berserk -- the GUI would consume it (ran %s, focus %s)" % [got[0], get_root().gui_get_focus_owner()])
	btn.queue_free()
	other.queue_free()
	await process_frame

## No key moves the character: the move_* actions are gone from the project.
func _check_no_movement() -> void:
	var left: Array = []
	for action in ["move_forward", "move_back", "move_left", "move_right", "toggle_panels", "toggle_ui"]:
		if InputMap.has_action(action):
			left.append(action)
	_check(left.is_empty(), "project.godot binds no move or panel action (still there: %s)" % [left])

func _check_pure(keymap: GDScript) -> void:
	if keymap == null:
		_check(false, "the table's helpers: no KeyMap")
		return
	var hides: Array = []
	for kind in ["player", "other_player", "monster", "npc", "guard", "ground_item", "fortress", "stall", "pet"]:
		if bool(keymap.call("hides_under_v", kind)):
			hides.append(kind)
	_check(hides == ["other_player", "monster", "stall", "pet"],
		"V hides other players, monsters, stalls and pets, and keeps you, NPCs, guards, items and fortresses (hides %s)" % [hides])
	_check(int(keymap.call("next_camera_view", 0)) == 1 and int(keymap.call("next_camera_view", 1)) == 2
		and int(keymap.call("next_camera_view", 2)) == 0, "F9 cycles free -> third person -> quarter -> free")
	_check(str(keymap.call("camera_view_string", 1)) == "UIIT_STT_CHANGED_SIGHT_THIRD_PERSON_DESC", "F9 announces the view with the client's own line")
	var name := str(keymap.call("screenshot_name", {"year": 2026, "month": 9, "day": 6, "hour": 7, "minute": 8, "second": 9}, 1234))
	_check(name == "SRO[2026-09-06 07-08-09]_34.jpg", "the screenshot is named as 0xba7240 names it (got %s)" % name)
	_check(str(keymap.call("reply_line", "ttFriend", "ttMe")) == "$ttFriend ", "R's line whispers the last whisperer, retail's \"$name \" (0x7ab470)")
	_check(str(keymap.call("reply_line", "", "ttMe")) == "" and str(keymap.call("reply_line", "ttMe", "ttMe")) == "",
		"R does nothing with no whisper, or when the last whisperer is you")
	var underbar := load(UNDERBAR_PATH) as GDScript
	var skill_key := str(underbar.call("key_name", "skill")) if underbar != null else ""
	var equip_key := str(underbar.call("key_name", "equipment")) if underbar != null else "?"
	_check(skill_key == "S" and equip_key == "", "the bar names S for the skill window and no key for equipment (got '%s', '%s')" % [skill_key, equip_key])

## G's 50-unit search and Z's 300-unit names, on real GroundItems nodes.
func _check_ground_items(_keymap: GDScript) -> void:
	var items := GroundItems.new()
	items.setup(null, {}, func(_id: int) -> String: return "tt item",
		func(text: String, _top: float) -> Label3D:
			var l := Label3D.new()
			l.text = text
			return l,
		Callable())
	get_root().add_child(items)
	for spec in [[1, 49.9], [2, 50.0], [3, 299.9], [4, 300.0]]:
		var snap := GroundItemsNet.Snapshot.new()
		snap.id = spec[0]
		snap.item_id = 7
		snap.quantity = 1
		snap.x = spec[1]
		items.spawn(snap)
	await process_frame
	var has := items.has_method("nearest_within") and items.has_method("update_labels")
	_check(has, "GroundItems has G's search and Z's names")
	if not has:
		items.queue_free()
		return
	_check(int(items.call("nearest_within", Vector3.ZERO, 50.0)) == 1, "G finds the item at 49.9")
	items.remove(1)
	_check(int(items.call("nearest_within", Vector3.ZERO, 50.0)) == -1, "and not the one at exactly 50.0 (strictly closer, 0x9e18f0)")
	var shown := func() -> Array:
		var out: Array = []
		for id in [2, 3, 4]:
			var label := items.get_node("GroundItem_%d/Label" % id) as Node3D
			if label != null and label.visible:
				out.append(id)
		return out
	_check((shown.call() as Array).is_empty(), "item names are hidden by default (shown %s)" % [shown.call()])
	items.call("update_labels", Vector3.ZERO, 300.0, -1)
	_check(shown.call() == [2, 3], "Z shows the names strictly within 300 (shown %s)" % [shown.call()])
	items.call("update_labels", Vector3.ZERO, -1.0, 4)
	_check(shown.call() == [4], "without Z only the hovered item's name shows (shown %s)" % [shown.call()])
	items.call("update_labels", Vector3.ZERO, -1.0, -1)
	_check((shown.call() as Array).is_empty(), "and none once the mouse is off it")
	items.queue_free()
