extends SceneTree

## Measurement (round 702 review): does RetailBloom draw the original's bloom
## formula on screen, under the renderer it runs on?
##
## Draws a synthetic picture (ramps across and down, and 7-pixel blocks of
## seeded random colours) on a canvas layer under RetailBloom's, reads the
## frame back with the bloom hidden (the screen texture the pass samples:
## S) and shown (B), and for 4000 seeded pixels away from the edges computes
## the formula on the CPU from S -- 25 bilinear taps at the READ 512-texel
## offsets, each `max(t x 128/255 - 40/255, 0)`, weighted 80/70/50 per axis,
## then `clamp(S x 198/255 + Blur x 192/255)` -- and compares it with B.
## Prints `BLOOM <renderer> max |diff| <d>/255, mean <m>/255, over <n>
## channels; within 1/255: <p> %` and exits 1 when any channel is off by
## more than TOLERANCE.
##
##   tools/xwl_run.sh -s 1280x720 godot --rendering-method forward_plus --rendering-driver vulkan \
##     --resolution 1280x720 --path client --script res://tools/measure_retail_bloom.gd
## or under xvfb-run + vglrun with --rendering-driver opengl3 (Compatibility).

const TOLERANCE := 1.0 / 255.0 + 0.0001
const SAMPLES := 4000

var _bloom: RetailBloom
var _frame := 0
var _s: Image

func _initialize() -> void:
	var w := 1280
	var h := 720
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 702
	for y in h:
		for x in w:
			var c: Color
			if y < h / 3:
				c = Color(float(x) / float(w - 1), float(x) / float(w - 1), 0.5 * float(x) / float(w - 1))
			elif y < 2 * h / 3 and x < w / 2:
				var v := float(y - h / 3) / float(h / 3)
				c = Color(v, 0.8 * v, 1.0 - v)
			else:
				c = Color(0, 0, 0)
			img.set_pixel(x, y, c)
	# Blocks over the lower half's right and bottom.
	for by in range(2 * h / 3, h, 7):
		for bx in range(0, w, 7):
			var c := Color(rng.randf(), rng.randf(), rng.randf())
			for y in range(by, mini(by + 7, h)):
				for x in range(bx, mini(bx + 7, w)):
					img.set_pixel(x, y, c)
	for by in range(h / 3, 2 * h / 3, 7):
		for bx in range(w / 2, w, 7):
			var c := Color(rng.randf(), rng.randf(), rng.randf())
			for y in range(by, mini(by + 7, 2 * h / 3)):
				for x in range(bx, mini(bx + 7, w)):
					img.set_pixel(x, y, c)
	var under := CanvasLayer.new()
	under.layer = RetailBloom.LAYER_INDEX - 1
	var rect := TextureRect.new()
	rect.texture = ImageTexture.create_from_image(img)
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	under.add_child(rect)
	root.add_child(under)
	_bloom = RetailBloom.new()
	_bloom.visible = false
	root.add_child(_bloom)

func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 6:
		_s = root.get_texture().get_image()
		_s.convert(Image.FORMAT_RGB8)
		_bloom.visible = true
	elif _frame == 12:
		var b := root.get_texture().get_image()
		b.convert(Image.FORMAT_RGB8)
		_compare(b)
		return true
	return false

func _tap(x: float, y: float, ch: int) -> float:
	# Bilinear at a continuous pixel position, texel centres at +0.5, clamped.
	var px := x - 0.5
	var py := y - 0.5
	var x0 := floori(px)
	var y0 := floori(py)
	var fx := px - x0
	var fy := py - y0
	var w := _s.get_width()
	var h := _s.get_height()
	var xa := clampi(x0, 0, w - 1)
	var xb := clampi(x0 + 1, 0, w - 1)
	var ya := clampi(y0, 0, h - 1)
	var yb := clampi(y0 + 1, 0, h - 1)
	var top := lerpf(_s.get_pixel(xa, ya)[ch], _s.get_pixel(xb, ya)[ch], fx)
	var bot := lerpf(_s.get_pixel(xa, yb)[ch], _s.get_pixel(xb, yb)[ch], fx)
	return lerpf(top, bot, fy)

func _compare(b: Image) -> void:
	var w := _s.get_width()
	var h := _s.get_height()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7021
	var max_d := 0.0
	var sum_d := 0.0
	var n := 0
	var within := 0
	for k in SAMPLES:
		var x := rng.randi_range(12, w - 13)
		var y := rng.randi_range(12, h - 13)
		for ch in 3:
			var taps: Array = []
			for j in range(-2, 3):
				var row: Array = []
				for i in range(-2, 3):
					var ox: float = signf(i) * float(RetailBloom.OFFSETS[absi(i)]) * float(w) / RetailBloom.TARGET_SIZE
					var oy: float = signf(j) * float(RetailBloom.OFFSETS[absi(j)]) * float(h) / RetailBloom.TARGET_SIZE
					row.append(_tap(x + 0.5 + ox, y + 0.5 + oy, ch))
				taps.append(row)
			var want := RetailBloom.composite(_s.get_pixel(x, y)[ch], RetailBloom.blur_of(taps))
			var d := absf(want - b.get_pixel(x, y)[ch])
			max_d = maxf(max_d, d)
			sum_d += d
			n += 1
			if d <= TOLERANCE:
				within += 1
	var rend := "forward_plus" if RenderingServer.get_rendering_device() != null else "gl_compatibility"
	print("BLOOM %s max |diff| %.2f/255, mean %.3f/255, over %d channels; within 1/255: %.2f %%" % [
		rend, max_d * 255.0, sum_d / float(n) * 255.0, n, 100.0 * float(within) / float(n)])
	quit(1 if max_d > TOLERANCE else 0)
