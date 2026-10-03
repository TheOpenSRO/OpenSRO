extends SceneTree

## RetailBloom (round 702 review): the original's bloom arithmetic
## (Map::FUN_00a1d790, READ) and its place among the canvas layers; and
## ShadowCatcher's READ darkness.
##
## `godot4 --headless --path client --script res://scripts/world/retail_bloom_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _flat(v: float) -> Array:
	var rows: Array = []
	for j in 5:
		rows.append([v, v, v, v, v])
	return rows

func _initialize() -> void:
	var wsum := 0.0
	for i in range(-2, 3):
		wsum += float(RetailBloom.WEIGHTS[absi(i)])
	_check(is_equal_approx(wsum, 320.0 / 255.0), "the five taps' weights add to 320/255 (80 + 2x70 + 2x50)")
	# Below the threshold (40/255 after x128/255, i.e. a screen value under 0.312): no blur.
	_check(RetailBloom.blur_of(_flat(0.3)) == 0.0, "a screen at 0.3 everywhere is under the threshold: no blur")
	_check(is_equal_approx(RetailBloom.composite(0.3, 0.0), 0.3 * 198.0 / 255.0), "... and it is kept at 198/255: darker (more contrast)")
	var v := 1.0
	var expect := wsum * wsum * (v * 128.0 / 255.0 - 40.0 / 255.0)
	_check(is_equal_approx(RetailBloom.blur_of(_flat(v)), expect), "white everywhere: the blur is (320/255)^2 x (128 - 40)/255 = %.3f" % expect)
	_check(RetailBloom.composite(1.0, expect) == 1.0, "... and the composite clamps at 1")
	# A flat field crosses over at 0.5: darker below, brighter above -- more contrast.
	var lo := RetailBloom.composite(0.4, RetailBloom.blur_of(_flat(0.4)))
	var hi := RetailBloom.composite(0.6, RetailBloom.blur_of(_flat(0.6)))
	var half := RetailBloom.composite(0.5, RetailBloom.blur_of(_flat(0.5)))
	_check(lo < 0.4 and hi > 0.6 and absf(half - 0.5) < 0.003,
		"flat fields: 0.4 -> %.3f, 0.5 -> %.3f, 0.6 -> %.3f (the bloom raises contrast about 0.5)" % [lo, half, hi])
	_check(RetailBloom.LAYER_INDEX < 0 and RetailBloom.LAYER_INDEX < VideoOptions.BRIGHTNESS_LAYER_INDEX,
		"the pass sits under the default canvas, the world's UI (layer 1) and the brightness pass (%d)" % VideoOptions.BRIGHTNESS_LAYER_INDEX)
	var b := RetailBloom.new(true)
	var grid := b.get_node("Pass") as MeshInstance2D
	var code := (grid.material as ShaderMaterial).shader.code
	_check(code.contains("hint_screen_texture, filter_linear,") and code.contains("198.0 / 255.0") and code.contains("192.0 / 255.0")
		and code.contains("T = 512.0") and code.contains("0.6))") and code.contains("0.2))") and code.contains("v_blur = v_at(t)"),
		"the shader runs retail's three passes per 512 texel in its vertex stage (taps 2.6 / 5.2 between texels) and composites 198/255 + 192/255")
	var arrays := grid.mesh.surface_get_arrays(0)
	_check((arrays[Mesh.ARRAY_VERTEX] as PackedVector2Array).size() == 514 * 514, "one vertex per texel of the 512 x 512 target, plus the edge ring")
	b.free()
	var bm := RetailBloom.new(false)
	_check(bm.get_node("Pass") is ColorRect and not bm.uses_grid()
		and ((bm.get_node("Pass") as CanvasItem).material as ShaderMaterial).shader.code.contains("filter_linear_mipmap"),
		"under Compatibility (no vertex-stage screen reads) the pass is a rect on the 512-wide mip")
	bm.free()
	# Godot's glow never; the scene carries no guessed glow values.
	var tscn := FileAccess.get_file_as_string("res://scenes/World3D.tscn")
	_check(not tscn.contains("glow_intensity") and not tscn.contains("glow_bloom") and not tscn.contains("glow_hdr_threshold"),
		"World3D.tscn has none of round 693's guessed glow values")
	var src := FileAccess.get_file_as_string("res://scripts/World3D.gd")
	_check(src.contains("_retail_bloom.visible = o.value(VideoOptions.BLOOM) == 1"), "the Bloom row shows and hides the pass")
	_check(src.count("layers = OverlayView.BIT") >= 4 and src.contains("_overlay_view.follow(camera_3d)"),
		"name plates, party marks, name boxes and damage numbers are drawn after the bloom (OverlayView)")
	_check(OverlayView.LAYER_INDEX > RetailBloom.LAYER_INDEX and OverlayView.LAYER_INDEX < 1, "the overlays' layer sits over the bloom and under the world's UI")

	# Detail's terrain catcher: the original keeps 1 - 150/255 of the ground's displayed colour.
	_check(is_equal_approx(ShadowCatcher.K_DISPLAY, 105.0 / 255.0), "the catcher's darkness is READ: 1 - 150/255 (FUN_009f2f80's vertex alpha 150)")
	var shown := ShadowCatcher.shown_ratio(ShadowCatcher.k_linear(), ShadowCatcher.FIT_DISPLAY)
	_check(shown > ShadowCatcher.K_DISPLAY and shown < 0.46,
		"the k fitted on the screen (0.25) is above the curve's own 0.412 point (curve: %.3f at 95/255), as the screen measured darker" % shown)
	_check(ShadowCatcher.shown_ratio(WorldFog.srgb_to_linear(ShadowCatcher.K_DISPLAY), ShadowCatcher.FIT_DISPLAY) < 0.38,
		"the plain decode (0.141) would keep too little there (the rework review's M1)")
	var cm := ShadowCatcher.material()
	_check(cm.render_priority == ShadowCatcher.PRIORITY and (cm.shader.code.contains("blend_mul") and cm.shader.code.contains("LIGHT_IS_DIRECTIONAL")),
		"the catcher multiplies by the sun's shadow alone, at its own priority")
	_check(src.contains("single_patch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF") and src.contains("(g as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF"),
		"the terrain and placed objects cast no shadow (only characters do, as the original's scenery)")
	_check(src.contains("const SHADOW_MAP_DISTANCE := 400.0"), "Detail's shadow reach is 400: the READ 300 from the player plus the camera's 90")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit(1 if _failures > 0 else 0)
