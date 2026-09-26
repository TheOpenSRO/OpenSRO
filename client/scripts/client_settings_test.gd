extends SceneTree

## ClientSettings.apply_ui_scale: the text server's font oversampling is the
## scale at a whole-number UI scale and 1.0 at any other, and it STAYS so
## after the window is resized.
##
## A resize is where it went wrong before round 581: the window resets the
## oversampling on every viewport update (Window::_update_viewport_size), and
## the old size_changed hook ran before that reset, so a resize left 2.35 at
## a 2.35 scale (the setting that should have stopped it was swallowed by a
## `#` comment in project.godot) and, once the setting applied, 1.0 at every
## scale. Headless: the root window still runs that code, and setting its
## size is a resize.
##
## Reads no settings file and writes none; puts the scale back to 1.0.
##
## `godot4 --headless --path client --script res://scripts/client_settings_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _oversampling() -> float:
	return TextServerManager.get_primary_interface().font_get_global_oversampling()

func _initialize() -> void:
	_run()

func _run() -> void:
	# In --script mode the root window takes its real size over the first
	# frame (after _initialize), which is itself a viewport update; start after.
	await process_frame
	await process_frame
	var root := get_root()
	var sizes := [Vector2i(1160, 700), Vector2i(1000, 640), Vector2i(1280, 720)]
	var step := 0
	for c in [[2.0, 2.0], [2.35, 1.0], [3.0, 3.0], [2.5, 1.0], [1.0, 1.0]]:
		var scale: float = c[0]
		var want: float = c[1]
		ClientSettings.apply_ui_scale(root, scale)
		await process_frame
		_check(is_equal_approx(_oversampling(), want), "UI scale %.2f: oversampling %.2f (got %.3f)" % [scale, want, _oversampling()])
		root.size = sizes[step % sizes.size()]
		step += 1
		await process_frame
		await process_frame
		_check(is_equal_approx(_oversampling(), want), "UI scale %.2f after a resize to %s: oversampling %.2f (got %.3f)" % [scale, root.size, want, _oversampling()])
		_check(is_equal_approx(root.content_scale_factor, scale), "UI scale %.2f is the window's content scale (got %.2f)" % [scale, root.content_scale_factor])

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit(1 if _failures > 0 else 0)
