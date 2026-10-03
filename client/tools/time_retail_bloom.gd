extends SceneTree

## Timing (round 702 rework): the root viewport's GPU time a frame with
## RetailBloom off and on, over a synthetic picture, at the window's size --
## and, for finding where it goes, the pass with its blur stubbed out.
## Prints `TIME <renderer> <w>x<h> <mode> gpu <ms> cpu <ms>` per mode.
##
##   tools/xwl_run.sh -s 3840x2160 godot --rendering-method forward_plus --rendering-driver vulkan \
##     --resolution 3840x2160 --path client --script res://tools/time_retail_bloom.gd

const FRAMES := 240
var _modes := ["off", "on", "stub", "off2", "on2"]
var _mode := -1
var _frame := 0
var _gpu := 0.0
var _cpu := 0.0
var _n := 0
var _bloom: RetailBloom
var _stub: ColorRect

func _initialize() -> void:
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	var under := CanvasLayer.new()
	under.layer = RetailBloom.LAYER_INDEX - 1
	var rect := TextureRect.new()
	var img := Image.create(256, 256, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	for y in 256:
		for x in 256:
			img.set_pixel(x, y, Color(rng.randf(), rng.randf(), rng.randf()))
	rect.texture = ImageTexture.create_from_image(img)
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	under.add_child(rect)
	root.add_child(under)
	_bloom = RetailBloom.new()
	_bloom.visible = false
	root.add_child(_bloom)
	# The copy and the composite alone: the screen read once and kept.
	var sl := CanvasLayer.new()
	sl.layer = RetailBloom.LAYER_INDEX
	_stub = ColorRect.new()
	_stub.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var sh := Shader.new()
	sh.code = "shader_type canvas_item;\nuniform sampler2D s : hint_screen_texture, filter_linear;\nvoid fragment() { COLOR = vec4(textureLod(s, SCREEN_UV, 0.0).rgb * (198.0 / 255.0), 1.0); }\n"
	var m := ShaderMaterial.new()
	m.shader = sh
	_stub.material = m
	_stub.visible = false
	sl.add_child(_stub)
	root.add_child(sl)
	_next()

func _next() -> void:
	if _mode >= 0:
		var rend := "forward_plus" if RenderingServer.get_rendering_device() != null else "gl_compatibility"
		print("TIME %s %dx%d %s gpu %.3f ms cpu %.3f ms" % [rend, root.get_texture().get_width(), root.get_texture().get_height(),
			_modes[_mode], _gpu / maxf(_n, 1), _cpu / maxf(_n, 1)])
	_mode += 1
	_frame = 0
	_gpu = 0.0
	_cpu = 0.0
	_n = 0
	if _mode < _modes.size():
		var m: String = _modes[_mode]
		_bloom.visible = m.begins_with("on")
		_stub.visible = m == "stub"

func _process(_delta: float) -> bool:
	if _mode >= _modes.size():
		return true
	_frame += 1
	if _frame > 60:
		_gpu += RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
		_cpu += RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid())
		_n += 1
	if _frame >= FRAMES:
		_next()
		if _mode >= _modes.size():
			return true
	return false
