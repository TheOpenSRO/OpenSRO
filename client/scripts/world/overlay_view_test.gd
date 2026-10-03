extends SceneTree

## OverlayView (round 702 rework): the overlay viewport is shown over the
## whole window at any UI scale (the final review found it doubled from the
## top-left corner at content_scale_factor 2.0), and it stops rendering when
## asked (the front-end's backdrop).
##
## `godot4 --headless --path client --script res://scripts/world/overlay_view_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	var view := OverlayView.new()
	root.add_child(view)
	var cam := Camera3D.new()
	root.add_child(cam)
	view.follow(cam)
	for scale in [1.0, 1.5, 2.0]:
		root.content_scale_factor = scale
		await process_frame
		await process_frame
		var want := root.get_visible_rect().size
		var got := view.shown_rect().size
		_check(got.distance_to(want) < 1.0,
			"UI scale %.1f: the overlay covers the window's %s UI units (got %s)" % [scale, str(want), str(got)])
	root.content_scale_factor = 1.0
	_check((cam.cull_mask & OverlayView.BIT) == 0, "the followed camera leaves the overlay layer out")
	view.set_rendering(false)
	_check(not view.shown_rect().visible, "set_rendering(false) hides the overlay")
	view.set_rendering(true)
	_check(view.shown_rect().visible, "set_rendering(true) shows it again")
	print("ALL PASS" if _failures == 0 else "%d FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
