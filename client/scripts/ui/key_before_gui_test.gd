extends SceneTree

## The window keys are read before the GUI (round 609). v0.1.453's playtest
## log: Tab -- read by KeyInput in _input -- worked, while the window keys,
## left to HudPanels' _unhandled_key_input, did not; a key reaches that stage
## only if nothing on the way takes it. KeyInput now runs them itself, before
## the GUI, whenever its host has a "panel" callable (World3D's does).
##
## Checked through Viewport.push_input, Godot's own routing:
##   (a) with a focused control that accepts every key in its _gui_input --
##       the kind of control that swallowed them -- I, C, S and M still reach
##       the host's "panel", once each, and the control never sees them;
##   (b) Tab still runs berserk the same way (unchanged);
##   (c) a key repeat (echo) does not toggle a window a second time;
##   (d) while the host says a line is typing, a window key does nothing;
##   (e) an event that carries only its physical key code (keycode 0) still
##       resolves, via KeyInput.key_code_of;
##   (f) a host without "panel" (the old stub hosts) leaves the window keys
##       unhandled, as before.
## Loaded by path, so it runs (and fails) against a tree without the change:
##   godot4 --headless --path client --script res://scripts/ui/key_before_gui_test.gd

const KEY_INPUT_PATH := "res://scripts/ui/key_input.gd"

var _failures := 0
var _panels: Array = []
var _runs: Array = []
var _typing := false
var _swallowed: Array = []

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

func _key(code: int, pressed: bool, echo := false, physical_only := false) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = (KEY_NONE if physical_only else code) as Key
	ev.physical_keycode = code as Key
	ev.key_label = code as Key
	ev.pressed = pressed
	ev.echo = echo
	var name := OS.get_keycode_string(code as Key)
	if pressed and name.length() == 1:
		ev.unicode = name.to_lower().unicode_at(0)
	return ev

func _press(code: int, echo := false, physical_only := false) -> void:
	get_root().push_input(_key(code, true, echo, physical_only))
	await process_frame
	if not echo:
		get_root().push_input(_key(code, false, false, physical_only))
		await process_frame

## A control that takes the keyboard and accepts every key it is given.
func _swallower() -> Control:
	var script := GDScript.new()
	script.source_code = """extends Control
var seen: Array = []
func _gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		seen.append(event.keycode)
		accept_event()
"""
	script.reload()
	var c := Control.new()
	c.set_script(script)
	c.focus_mode = Control.FOCUS_ALL
	c.size = Vector2(50, 50)
	return c

func _run() -> void:
	await process_frame
	if not ResourceLoader.exists(KEY_INPUT_PATH):
		_check(false, "KeyInput exists")
		return
	var KeyInputScript: GDScript = load(KEY_INPUT_PATH)
	var host := {
		"is_typing": func() -> bool: return _typing,
		"run": func(action: String, arg: int) -> String:
			_runs.append([action, arg])
			return "ran",
		"panel": func(action: String) -> String:
			_panels.append(action)
			return "toggled",
	}
	var key_input: Node = KeyInputScript.new(host)
	get_root().add_child(key_input)
	var swallower := _swallower()
	get_root().add_child(swallower)
	swallower.grab_focus()
	await process_frame
	_check(get_root().gui_get_focus_owner() == swallower, "the swallowing control has the keyboard")

	# (a)
	for code in [KEY_I, KEY_C, KEY_S, KEY_M]:
		await _press(code)
	_check(_panels == ["panel:inventory", "panel:character", "panel:skill", "worldmap"],
		"I, C, S and M reach the window toggles past a focused control that takes every key (got %s)" % [_panels])
	_check(swallower.get("seen").is_empty(),
		"the focused control never sees them (saw %s)" % [swallower.get("seen")])

	# (b)
	_runs.clear()
	await _press(KEY_TAB)
	_check(_runs.size() == 1 and _runs[0][0] == "berserk", "Tab still runs berserk (ran %s)" % [_runs])

	# (c)
	_panels.clear()
	get_root().push_input(_key(KEY_I, true))
	await process_frame
	get_root().push_input(_key(KEY_I, true, true))
	await process_frame
	get_root().push_input(_key(KEY_I, false))
	await process_frame
	_check(_panels == ["panel:inventory"], "a held I toggles once, not on its repeats (got %s)" % [_panels])

	# (d)
	_panels.clear()
	_typing = true
	await _press(KEY_I)
	_typing = false
	_check(_panels.is_empty(), "while a line is typing, I opens nothing (got %s)" % [_panels])

	# (e)
	_panels.clear()
	await _press(KEY_I, false, true)
	_check(_panels == ["panel:inventory"], "an I that carries only its physical code still opens the inventory (got %s)" % [_panels])
	_check(KeyInputScript.has_method("key_code_of"), "KeyInput.key_code_of exists")

	# (f)
	key_input.queue_free()
	await process_frame
	var bare: Node = KeyInputScript.new({"is_typing": func() -> bool: return false})
	get_root().add_child(bare)
	var before: int = swallower.get("seen").size()
	await _press(KEY_I)
	_check(swallower.get("seen").size() == before + 1,
		"without a \"panel\" callable the window key is left to the GUI and HudPanels, as before")
	bare.queue_free()
	swallower.queue_free()
	await process_frame
