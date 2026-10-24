extends SceneTree

## Round 818: the mouse does not reach the world through a window. Retail
## sends the world nothing under a window (FUN_00b9dc00 != CGInterface, READ,
## round 697). No game data: plain controls.
## `godot4 --headless --path client --script res://scripts/ui/hud/input_bleed_test.gd`
##
## NEGATIVE, on the base (v0.1.579): World3D.wheel_over_window and
## HudWindow.catch_overhang do not exist -- the suite does not compile; the
## wheel zoomed the camera under every window and a click on the guild
## window's side tabs walked the player.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

class Sink extends Node:
	var seen := 0
	func _unhandled_input(_event: InputEvent) -> void:
		seen += 1

func _initialize() -> void:
	await process_frame
	# A headless window never hears the mouse come in.
	root.notification(Window.NOTIFICATION_WM_MOUSE_ENTER)
	root.size = Vector2i(800, 600)
	var world := load("res://scripts/World3D.gd") as GDScript
	var sink := Sink.new()
	root.add_child(sink)

	_check(not bool(world.call("wheel_over_window", null)), "nothing under the mouse: the wheel zooms")
	var hud := Control.new()
	hud.mouse_filter = Control.MOUSE_FILTER_PASS
	root.add_child(hud)
	_check(not bool(world.call("wheel_over_window", hud)), "a PASS container alone: the wheel zooms")

	var window := HudWindow.new()
	window.position = Vector2(200, 200)
	window.size = Vector2(100, 100)
	hud.add_child(window)
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var tex := ImageTexture.create_from_image(img)
	# A side tab drawn past the window's left edge, as the guild window's.
	var tab := TextureRect.new()
	tab.texture = tex
	tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tab.position = Vector2(-30, 10)
	tab.size = Vector2(40, 20)
	window.add_child(tab)
	# A button inside, under where the tab's catcher reaches.
	var button := Button.new()
	button.position = Vector2(0, 10)
	button.size = Vector2(10, 20)
	window.add_child(button)
	var pressed := [0]
	button.button_down.connect(func() -> void: pressed[0] += 1)
	await process_frame

	_check(_motion_leaks(Vector2(180, 220), sink), "before the catchers the tab's point reaches the world")
	window.catch_overhang()
	var catchers := window.get_children().filter(func(c: Node) -> bool: return c.has_meta(HudWindow.OVERHANG_META))
	_check(catchers.size() == 1 and window.get_child(0) == catchers[0], "one catcher, the window's first child")
	_check(not _motion_leaks(Vector2(180, 220), sink), "the tab's point now stops at the window")
	_check(_motion_leaks(Vector2(160, 220), sink), "a point past the tab still reaches the world")
	_check(not _motion_leaks(Vector2(250, 250), sink), "the window's own body stops it")

	# The button under the catcher still takes its click.
	var press := InputEventMouseButton.new()
	press.position = Vector2(205, 220)
	press.global_position = press.position
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	root.push_input(press)
	var release := press.duplicate() as InputEventMouseButton
	release.pressed = false
	root.push_input(release)
	_check(pressed[0] == 1, "a button the catcher overlaps still takes its click")

	# The wheel: Godot passes it through a STOP control (force-pass, the
	# default), so the world's own test decides.
	_motion_leaks(Vector2(250, 250), sink)
	var before := sink.seen
	var wheel := InputEventMouseButton.new()
	wheel.position = Vector2(250, 250)
	wheel.global_position = wheel.position
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	root.push_input(wheel)
	var reached := sink.seen > before
	_check(bool(world.call("wheel_over_window", root.gui_get_hovered_control())),
		"over the window the wheel is the window's (reached _unhandled_input: %s)" % str(reached))
	_motion_leaks(Vector2(180, 220), sink)
	_check(bool(world.call("wheel_over_window", root.gui_get_hovered_control())), "and over its side tab")
	_motion_leaks(Vector2(600, 500), sink)
	_check(not bool(world.call("wheel_over_window", root.gui_get_hovered_control())), "over the world the wheel zooms")

	# Shown again, the catchers are made anew, not added to.
	window.hide()
	window.show()
	for i in 5:
		await process_frame
	catchers = window.get_children().filter(func(c: Node) -> bool: return c.has_meta(HudWindow.OVERHANG_META))
	_check(catchers.size() == 1, "a show re-makes them (%d)" % catchers.size())

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _motion_leaks(p: Vector2, sink: Sink) -> bool:
	var before := sink.seen
	var motion := InputEventMouseMotion.new()
	motion.position = p
	motion.global_position = p
	root.push_input(motion)
	return sink.seen > before
