extends Node
class_name KeyInput

## Turns key presses into KeyMap actions and hands them to the world (round
## 608). Since round 609 that includes the windows' keys (KeyMap's "panel:"
## slots and M), through the host's "panel" callable, read here before the
## GUI like every other key; HudPanels' own handler for them remains as the
## fallback for a host without one. Enter stays with HudChat and Escape with
## HudPanels. World3D reads no keys itself.
##
## The keys are read in _input, before the GUI: with a button focused (a
## click leaves UiBuilder's FOCUS_ALL TextureButtons with the keyboard) the
## GUI consumes Tab -- measured on Godot 4.2.2 with push_input: the press
## never reached _unhandled_key_input, though the focus did not move -- and
## the client has no keyboard focus on buttons. (Space presses such a button
## as well as reaching the unhandled stage, measured the same way; Space is
## only tracked here, not consumed.) An action taken marks the event handled.
##
## **While a text line has the keyboard** (`is_typing`, the rule of rounds
## 521, 605 and 606) only the keys a line never takes run: F1-F12, Shift+F1-F3
## and PrintScreen (KeyMap.runs_while_typing), so after a line of chat --
## which keeps the focus -- Shift+F3, F10, the pages, F9 and PrintScreen still
## work. Everything else goes into the line. Ours: retail's CGInterface +0x3ce
## makes 0x778310 return -1 for the letter scan codes only (digits pass,
## read at 0x778356..0x77837a), but what +0x3ce means is not known
## (KeyMap.runs_while_typing has why).
##
## **Held keys** (V, Z; KeyMap.is_hold): down on the press, up on the
## release, as 0x780610 sets and 0x77d8d0 clears DAT_00eef5f4/f5 (read). Also
## up when the application loses the focus (CGInterface::vslot_012 0x77b140
## clears both when 0xb9da80(1) returns 0; that this is the focus test is
## inferred) and when a text line takes the keyboard (ours: the release would
## otherwise be the line's). Space is tracked the same way for Space+digit.
##
## The host is a Dictionary of Callables, so the suite drives this with
## stubs (keymap_test.gd):
##   "is_typing": func() -> bool
##   "run":       func(action: String, arg: int) -> String   what it did
##   "held":      func(action: String, down: bool) -> void   optional

var host: Dictionary = {}
## Actions whose key is down: action -> keycode.
var _held: Dictionary = {}
var _space_held := false
## Every action run, "<key> -> <action> <arg>: <result>", newest last (the
## suite and OPENSRO_QA_INPUT read it; capped).
var dispatched: Array = []
const DISPATCH_LOG_CAP := 64

func _init(host_callables: Dictionary = {}) -> void:
	host = host_callables

## A text line that holds the keyboard the way it did under Godot 4.2.2
## (round 754): Enter submits and the line keeps the keyboard AND its
## editing; Escape ends the input and gives the keyboard back to the game.
##
## Godot 4.4 gave LineEdit an editing state apart from the focus (READ,
## scene/gui/line_edit.cpp at 4.7.2-stable): Enter submits and then ends the
## editing unless keep_editing_on_text_submit (so the next Enter only starts
## editing again and submits nothing), and ui_cancel ends the editing but
## KEEPS the focus -- under 4.2.2 Escape released it. Without this, the chat
## line after a send ignored the next Enter, and after Escape the line kept
## the keyboard, so is_typing (World3D, a focused LineEdit) went on eating
## the game's keys (MEASURED: hud_keys_after_chat_test.gd, 8 failures under
## 4.7.2, 0 under 4.2.2). Both are no-ops under 4.2.2, which has neither the
## property nor the signal.
static func line_edit_as_42(edit: LineEdit) -> void:
	if edit == null or not edit.has_signal("editing_toggled"):
		return
	edit.set("keep_editing_on_text_submit", true)
	edit.connect("editing_toggled", func(on: bool) -> void:
		if not on and is_instance_valid(edit) and edit.has_focus():
			edit.release_focus())

func is_held(action: String) -> bool:
	return _held.has(action)

func space_held() -> bool:
	return _space_held

func _typing() -> bool:
	var f: Callable = host.get("is_typing", Callable())
	return f.is_valid() and bool(f.call())

func _process(_delta: float) -> void:
	# A text line took the keyboard while a key was held: its release now
	# belongs to the line, so let go here.
	if (not _held.is_empty() or _space_held) and _typing():
		release_all("typing")

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		release_all("focus lost")

## Lets go of every held key (V, Z and Space).
func release_all(why: String = "") -> void:
	_space_held = false
	for action in _held.keys():
		_let_go(action, why)

## One held key's release: the host hears it, and the log says why.
func _let_go(action: String, why: String = "") -> void:
	if not _held.has(action):
		return
	_held.erase(action)
	var f: Callable = host.get("held", Callable())
	if f.is_valid():
		f.call(action, false)
	_note("%s up%s" % [action, (" (%s)" % why) if why != "" else ""])

func _note(line: String) -> void:
	dispatched.append(line)
	if dispatched.size() > DISPATCH_LOG_CAP:
		dispatched.pop_front()
	print("KEYMAP " + line)

func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null:
		return
	if not key.pressed:
		_on_release(key)
		return
	if key_code_of(key) == KEY_SPACE:
		# Alt+Space is the OS's window menu (KeyMap.is_os_combination).
		if not _typing() and not KeyMap.is_os_combination(KEY_SPACE, key.alt_pressed):
			_space_held = true
			# Space presses a focused button (ui_accept, measured), which the
			# client does not do -- it has no keyboard focus on buttons -- and
			# which would also fire with every Space+digit chord. Taken here
			# when a button holds the focus; otherwise left alone (ours).
			if get_viewport().gui_get_focus_owner() is BaseButton:
				get_viewport().set_input_as_handled()
		return
	var keycode := key_code_of(key)
	if _typing() and not KeyMap.runs_while_typing(keycode):
		_log_typing()
		return
	_typing_logged = false
	var hit := KeyMap.resolve(keycode, key.ctrl_pressed, key.alt_pressed, key.meta_pressed, _space_held, key.shift_pressed)
	if hit.is_empty():
		if not key.echo:
			_log_key(key, keycode, "no action")
		return
	var action: String = hit[0]
	# The windows' keys (the "panel:" slots and M) run here too, before the
	# GUI, when the host has a "panel" callable (World3D does): left to
	# HudPanels' _unhandled_key_input they reach it only if no control on the
	# way takes them -- the same trap Tab fell into (round 608's measurement
	# above), and the one Tab, read here, never hit (v0.1.453 playtest: Tab
	# worked, the window keys did not). Without the callable (the suite's
	# stub hosts) they stay with HudPanels as before.
	if action.begins_with("panel:") or action == "worldmap":
		var panel: Callable = host.get("panel", Callable())
		if not panel.is_valid():
			return
		get_viewport().set_input_as_handled()
		if key.echo:
			return
		var done := String(panel.call(action))
		_log_key(key, keycode, "%s: %s" % [action, done])
		return
	get_viewport().set_input_as_handled()
	if KeyMap.is_hold(action):
		if not _held.has(action):
			_held[action] = keycode
			var f: Callable = host.get("held", Callable())
			if f.is_valid():
				f.call(action, true)
			_note("%s down" % action)
		return
	if key.echo:
		return
	_run(OS.get_keycode_string(key.get_keycode_with_modifiers()), action, int(hit[1]))

## The key's code: its keycode, or, when the platform leaves that empty
## (KEY_NONE) but sends the physical key, the code the current layout gives
## that key -- so a table key is never lost to an event that carries only
## the physical code. Ours.
static func key_code_of(key: InputEventKey) -> int:
	if key.keycode != KEY_NONE:
		return key.keycode
	if key.physical_keycode != KEY_NONE:
		return DisplayServer.keyboard_get_keycode_from_physical(key.physical_keycode)
	return KEY_NONE

## One line in the log per key press that is not typing, saying where it
## went -- the playtest log is how a key problem on a tester's machine gets
## seen (ours). The focus owner is named, never the text of a line.
func _log_key(key: InputEventKey, keycode: int, what: String) -> void:
	var focus := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	print("KEY %s (code %d, physical %d): %s; focus %s" % [
		OS.get_keycode_string(keycode), keycode, key.physical_keycode, what,
		("%s<%s>" % [focus.name, focus.get_class()]) if focus != null else "none"])

## While a text line has the keyboard, one line when that starts, naming the
## line -- never the keys, which are the player's text.
var _typing_logged := false
func _log_typing() -> void:
	if _typing_logged:
		return
	_typing_logged = true
	var focus := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	print("KEY typing: keys go to %s until it lets go of the keyboard" % [
		("%s<%s>" % [focus.name, focus.get_class()]) if focus != null else "a text line"])

func _on_release(key: InputEventKey) -> void:
	var keycode := key_code_of(key)
	if keycode == KEY_SPACE:
		_space_held = false
		return
	for action in _held.keys():
		if int(_held[action]) == keycode:
			_let_go(action)
	var hit := KeyMap.resolve_release(keycode)
	if hit.is_empty():
		return
	get_viewport().set_input_as_handled()
	_run(OS.get_keycode_string(keycode), String(hit[0]), int(hit[1]))

func _run(key_name: String, action: String, arg: int) -> void:
	var f: Callable = host.get("run", Callable())
	var result := String(f.call(action, arg)) if f.is_valid() else "no host"
	_note("%s -> %s %d: %s" % [key_name, action, arg, result])
