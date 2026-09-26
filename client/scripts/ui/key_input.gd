extends Node
class_name KeyInput

## Turns key presses into KeyMap actions and hands them to the world (round
## 608). The windows' keys (KeyMap's "panel:" slots and M) stay with
## HudPanels, which reads the same table; Enter stays with HudChat and
## Escape with HudPanels. Everything else the keyboard does comes through
## here, so World3D no longer reads keys itself.
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
## 521, 605 and 606) only the keys a line never takes run: F1-F12, Ctrl+F1-F3
## and PrintScreen (KeyMap.runs_while_typing), so after a line of chat --
## which keeps the focus -- Ctrl+F3, F10, the pages, F9 and PrintScreen still
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
## suite and SRREVAMP_QA_INPUT read it; capped).
var dispatched: Array = []
const DISPATCH_LOG_CAP := 64

func _init(host_callables: Dictionary = {}) -> void:
	host = host_callables

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
	if key.keycode == KEY_SPACE:
		if not _typing():
			_space_held = true
			# Space presses a focused button (ui_accept, measured), which the
			# client does not do -- it has no keyboard focus on buttons -- and
			# which would also fire with every Space+digit chord. Taken here
			# when a button holds the focus; otherwise left alone (ours).
			if get_viewport().gui_get_focus_owner() is BaseButton:
				get_viewport().set_input_as_handled()
		return
	if _typing() and not KeyMap.runs_while_typing(key.keycode):
		return
	var hit := KeyMap.resolve(key.keycode, key.ctrl_pressed, key.alt_pressed, key.meta_pressed, _space_held)
	if hit.is_empty():
		return
	var action: String = hit[0]
	# The windows' keys are HudPanels' (the same table), in its
	# _unhandled_key_input.
	if action.begins_with("panel:") or action == "worldmap":
		return
	get_viewport().set_input_as_handled()
	if KeyMap.is_hold(action):
		if not _held.has(action):
			_held[action] = key.keycode
			var f: Callable = host.get("held", Callable())
			if f.is_valid():
				f.call(action, true)
			_note("%s down" % action)
		return
	if key.echo:
		return
	_run(OS.get_keycode_string(key.get_keycode_with_modifiers()), action, int(hit[1]))

func _on_release(key: InputEventKey) -> void:
	if key.keycode == KEY_SPACE:
		_space_held = false
		return
	for action in _held.keys():
		if int(_held[action]) == key.keycode:
			_let_go(action)
	var hit := KeyMap.resolve_release(key.keycode)
	if hit.is_empty():
		return
	get_viewport().set_input_as_handled()
	_run(OS.get_keycode_string(key.keycode), String(hit[0]), int(hit[1]))

func _run(key_name: String, action: String, arg: int) -> void:
	var f: Callable = host.get("run", Callable())
	var result := String(f.call(action, arg)) if f.is_valid() else "no host"
	_note("%s -> %s %d: %s" % [key_name, action, arg, result])
