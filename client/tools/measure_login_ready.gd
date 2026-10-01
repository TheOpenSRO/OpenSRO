extends Node

## Round 678's measurement: how long the login screen takes to become USABLE
## -- the ID field visible, fully faded in, and accepting focus -- when the
## player clicks at its first frame (the skip, so the intro's own length is
## not counted), plus the longest frame and the frames over 100 ms in the
## first SECONDS seconds (a load that freezes the window shows there).
## Instances res://scenes/Login.tscn under this node, so it runs the same
## against any revision that has that scene and its `username_edit`.
##
##   xvfb-run godot --path client res://tools/measure_login_ready.tscn
##   (MEASURE_SECONDS=<s>, default 12; MEASURE_NO_CLICK=1 waits for the
##   intro's own end instead of clicking)
##
## Prints `MEASURE login interactable after <ms> ms` (the field shown and
## taking input, maybe still fading in), `MEASURE login usable after <ms> ms
## (click at <ms>)` (fully faded in) and
## `MEASURE frames: longest <ms> ms, <n> over 100 ms in <s> s`. OURS.

var _t0 := 0
var _login: Node = null
var _usable_ms := -1
var _interactable_ms := -1
var _click_ms := -1
var _longest := 0.0
var _over := 0
var _last_us := 0
var _frames := 0
var _seconds := 12.0

func _ready() -> void:
	var s := OS.get_environment("MEASURE_SECONDS")
	if s != "":
		_seconds = s.to_float()
	_t0 = Time.get_ticks_msec()
	_last_us = Time.get_ticks_usec()
	var packed := load("res://scenes/Login.tscn") as PackedScene
	_login = packed.instantiate()
	add_child(_login)
	print("MEASURE Login instanced in %d ms" % (Time.get_ticks_msec() - _t0))

func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var frame_ms := (now - _last_us) / 1000.0
	_last_us = now
	_frames += 1
	if _frames > 1:
		_longest = maxf(_longest, frame_ms)
		if frame_ms > 100.0:
			_over += 1
	var since := Time.get_ticks_msec() - _t0
	if _click_ms < 0 and _frames >= 1 and OS.get_environment("MEASURE_NO_CLICK") == "":
		_click_ms = since
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = Vector2(5, 5)
		Input.parse_input_event(press)
		var release := press.duplicate() as InputEventMouseButton
		release.pressed = false
		Input.parse_input_event(release)
	if _interactable_ms < 0 and _interactable():
		_interactable_ms = since
		print("MEASURE login interactable after %d ms (click at %d ms)" % [_interactable_ms, _click_ms])
	if _usable_ms < 0 and _usable():
		_usable_ms = since
		print("MEASURE login usable after %d ms (click at %d ms)" % [_usable_ms, _click_ms])
	if since > _seconds * 1000.0:
		print("MEASURE frames: longest %.1f ms, %d over 100 ms in %.0f s (%d frames)" % [_longest, _over, _seconds, _frames])
		if _usable_ms < 0:
			print("MEASURE login NOT usable within %.0f s" % _seconds)
		get_tree().quit()

## The ID field shown and taking input (it may still be fading in).
func _interactable() -> bool:
	var edit = _login.get("username_edit")
	return edit != null and edit is Control and (edit as Control).is_visible_in_tree() \
		and (edit as Control).focus_mode != Control.FOCUS_NONE

## ... and fully faded in.
func _usable() -> bool:
	var edit = _login.get("username_edit")
	if edit == null or not (edit is Control) or not (edit as Control).is_visible_in_tree():
		return false
	var a := 1.0
	var n: Node = edit
	while n != null and n is CanvasItem:
		a *= (n as CanvasItem).modulate.a * (n as CanvasItem).self_modulate.a
		n = n.get_parent()
	return a >= 0.99 and (edit as Control).focus_mode != Control.FOCUS_NONE
