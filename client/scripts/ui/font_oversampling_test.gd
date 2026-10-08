extends SceneTree

## Round 760: FontOversampling gives Godot 4.7.2's text 4.2.2's look at a UI
## scale -- an emboldened face's stroke divided by the oversampling, a
## Label3D's raster at size x oversampling with its quad unchanged -- and does
## nothing below 4.5 or at scale 1.
## `godot4 --headless --path client --script res://scripts/ui/font_oversampling_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var per := FontOversampling.per_viewport()
	FontOversampling.set_ui(1.0)
	var b := FontOversampling.bold(ThemeDB.fallback_font, 1.4)
	_check(is_equal_approx(b.variation_embolden, 1.4), "scale 1: the face's own embolden")
	var label := Label3D.new()
	root.add_child(label)
	FontOversampling.label3d(label, 12, 8, 0.0004)
	_check(label.font_size == 12 and label.outline_size == 8 and is_equal_approx(label.pixel_size, 0.0004), "scale 1: the label as given")
	FontOversampling.set_ui(2.0, root)
	if per:
		_check(is_equal_approx(b.variation_embolden, 0.7), "4.5+, scale 2: the stroke halved (4.2.2 keyed embolden by the unscaled size)")
		_check(label.font_size == 24 and label.outline_size == 16 and is_equal_approx(label.pixel_size, 0.0002),
			"4.5+, scale 2: the label rasterised at 2x, its quad the same (%d, %d, %f)" % [label.font_size, label.outline_size, label.pixel_size])
		FontOversampling.label3d_pixel_size(label, 0.001)
		_check(label.font_size == 24 and is_equal_approx(label.pixel_size, 0.0005), "a new pixel size keeps the raster's factor")
	else:
		_check(is_equal_approx(b.variation_embolden, 1.4) and label.font_size == 12, "before 4.5: nothing changes (the engine oversamples itself)")
	FontOversampling.set_ui(1.0, root)
	_check(is_equal_approx(b.variation_embolden, 1.4) and label.font_size == 12 and label.outline_size == 8,
		"back to scale 1: the face and the label as given")
	label.queue_free()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit()
