extends SceneTree

## Measurement (round 702 review and rework): how close is RetailBloom to the
## original's bloom pipeline, under the renderer it runs on?
##
## 1. **Against retail's 512 pipeline.** Draws a synthetic picture (ramps
##    across and down, 7- and 41-pixel blocks of seeded random colours) on a
##    canvas layer under RetailBloom's, reads the frame back with the bloom
##    hidden (S) and shown (B), and computes the original's pipeline on the
##    CPU from S: a 512 x 512 bilinear downsample, x 128/255, a horizontal
##    blur thresholded at 40/255 (weights 80/70/50 at 0 / 2.6 / 5.2 texels),
##    the vertical blur without it, a bilinear magnification back, and
##    `clamp(S x 198/255 + Blur x 192/255)`. Prints the differences over 4000
##    seeded pixels away from the edges (`BLOOM <renderer> <w>x<h> vs 512
##    pipeline: max .. p99 .. mean ..`). Ours runs the same pipeline per
##    512 texel; it differs by the grid's linear (not bilinear) magnification
##    within each half-cell and the 8-bit targets retail rounds to.
## 2. **Echoes.** A black frame with one white bar (1/64 of the width); the bloom's
##    added light along a row to the right of the bar should fall off
##    smoothly, as retail's magnified 512 target does. Prints how many local
##    maxima the added light has there (`ECHO ... peaks <n>`; 0 is smooth) and
##    exits 1 if there is any.
##
##   tools/xwl_run.sh -s 1280x720 godot --rendering-method forward_plus --rendering-driver vulkan \
##     --resolution 1280x720 --path client --script res://tools/measure_retail_bloom.gd
## or under xvfb-run + vglrun with --rendering-driver opengl3 (Compatibility);
## any --resolution (3840x2160 for the 4K figures).

const SAMPLES := 4000
const T := 512

var _bloom: RetailBloom
var _rect: TextureRect
var _frame := 0
var _s: Image
var _phase := 0
var _w := 0
var _h := 0
var _failures := 0

func _initialize() -> void:
	var under := CanvasLayer.new()
	under.layer = RetailBloom.LAYER_INDEX - 1
	_rect = TextureRect.new()
	_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.stretch_mode = TextureRect.STRETCH_SCALE
	under.add_child(_rect)
	root.add_child(under)
	_bloom = RetailBloom.new()
	_bloom.visible = false
	root.add_child(_bloom)

func _picture() -> Image:
	var w := _w
	var h := _h
	var data := PackedByteArray()
	data.resize(w * h * 3)
	var rng := RandomNumberGenerator.new()
	rng.seed = 702
	for y in h:
		for x in w:
			var c := Color(0, 0, 0)
			if y < h / 3:
				var v := float(x) / float(w - 1)
				c = Color(v, v, 0.5 * v)
			elif y < 2 * h / 3 and x < w / 2:
				var v := float(y - h / 3) / float(h / 3)
				c = Color(v, 0.8 * v, 1.0 - v)
			var n := (y * w + x) * 3
			data[n] = c.r8
			data[n + 1] = c.g8
			data[n + 2] = c.b8
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RGB8, data)
	for band in [[2 * h / 3, h, 0, w, 7], [h / 3, 2 * h / 3, w / 2, w, 41]]:
		var size: int = band[4]
		for by in range(band[0], band[1], size):
			for bx in range(band[2], band[3], size):
				var c := Color(rng.randf(), rng.randf(), rng.randf())
				img.fill_rect(Rect2i(bx, by, mini(size, band[3] - bx), mini(size, band[1] - by)), c)
	return img

## Wide enough to survive the 512 downsample above the threshold: 1/64 of
## the width (20 px at 1280, 60 at 3840).
func _bar_width() -> int:
	return ceili(_w / 64.0)

func _bar() -> Image:
	var img := Image.create(_w, _h, false, Image.FORMAT_RGB8)
	img.fill(Color(0, 0, 0))
	img.fill_rect(Rect2i(_w / 2, 0, _bar_width(), _h), Color(1, 1, 1))
	return img

func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 3 and _phase == 0:
		# The window has its size by now (at _initialize it is 100 x 100).
		_w = root.get_texture().get_width()
		_h = root.get_texture().get_height()
		_rect.texture = ImageTexture.create_from_image(_picture())
	elif _frame == 8:
		_s = root.get_texture().get_image()
		_s.convert(Image.FORMAT_RGB8)
		_bloom.visible = true
	elif _frame == 14:
		var b := root.get_texture().get_image()
		b.convert(Image.FORMAT_RGB8)
		if _phase == 0:
			_compare(b)
			_phase = 1
			_frame = 3
			_bloom.visible = false
			_rect.texture = ImageTexture.create_from_image(_bar())
		else:
			_echo(b)
			quit(1 if _failures > 0 else 0)
			return true
	return false

## Bilinear on a w x h float grid at a continuous position (texel centres at
## +0.5), clamped at the edges.
static func _bil(g: PackedFloat32Array, w: int, h: int, x: float, y: float) -> float:
	var px := x - 0.5
	var py := y - 0.5
	var x0 := floori(px)
	var y0 := floori(py)
	var fx := px - x0
	var fy := py - y0
	var xa := clampi(x0, 0, w - 1)
	var xb := clampi(x0 + 1, 0, w - 1)
	var ya := clampi(y0, 0, h - 1)
	var yb := clampi(y0 + 1, 0, h - 1)
	return lerpf(lerpf(g[ya * w + xa], g[ya * w + xb], fx), lerpf(g[yb * w + xa], g[yb * w + xb], fx), fy)

## Retail's blur, one channel, magnified to the screen: a w x h grid.
func _retail_blur(ch: int) -> PackedFloat32Array:
	var src := PackedFloat32Array()
	src.resize(_w * _h)
	var bytes := _s.get_data()
	for n in _w * _h:
		src[n] = bytes[n * 3 + ch] / 255.0
	var d := PackedFloat32Array()
	d.resize(T * T)
	for v in T:
		for u in T:
			d[v * T + u] = _bil(src, _w, _h, (u + 0.5) * _w / T, (v + 0.5) * _h / T) * RetailBloom.DOWNSAMPLE
	var hz := PackedFloat32Array()
	hz.resize(T * T)
	for v in T:
		for u in T:
			var acc := 0.0
			for i in range(-2, 3):
				var o: float = signf(i) * float(RetailBloom.OFFSETS[absi(i)])
				acc += float(RetailBloom.WEIGHTS[absi(i)]) * maxf(_bil(d, T, T, u + 0.5 + o, v + 0.5) - RetailBloom.THRESHOLD, 0.0)
			hz[v * T + u] = minf(acc, 1.0)
	var vt := PackedFloat32Array()
	vt.resize(T * T)
	for v in T:
		for u in T:
			var acc := 0.0
			for j in range(-2, 3):
				var o: float = signf(j) * float(RetailBloom.OFFSETS[absi(j)])
				acc += float(RetailBloom.WEIGHTS[absi(j)]) * _bil(hz, T, T, u + 0.5, v + 0.5 + o)
			vt[v * T + u] = minf(acc, 1.0)
	return vt

func _rend() -> String:
	return "forward_plus" if RenderingServer.get_rendering_device() != null else "gl_compatibility"

func _compare(b: Image) -> void:
	var blur := [_retail_blur(0), _retail_blur(1), _retail_blur(2)]
	var rng := RandomNumberGenerator.new()
	rng.seed = 7021
	var diffs: Array = []
	var sum_d := 0.0
	for k in SAMPLES:
		var x := rng.randi_range(12, _w - 13)
		var y := rng.randi_range(12, _h - 13)
		for ch in 3:
			var bl := _bil(blur[ch], T, T, (x + 0.5) * T / _w, (y + 0.5) * T / _h)
			var want := RetailBloom.composite(_s.get_pixel(x, y)[ch], bl)
			var d := absf(want - b.get_pixel(x, y)[ch])
			diffs.append(d)
			sum_d += d
	diffs.sort()
	print("BLOOM %s %dx%d vs the 512 pipeline: max %.2f/255, p99 %.2f/255, p90 %.2f/255, mean %.3f/255 over %d channels" % [
		_rend(), _w, _h, float(diffs[-1]) * 255.0, float(diffs[int(diffs.size() * 0.99)]) * 255.0,
		float(diffs[int(diffs.size() * 0.9)]) * 255.0, sum_d / float(diffs.size()) * 255.0, diffs.size()])

func _echo(b: Image) -> void:
	# The light the bloom adds right of the bar, along the middle row.
	var y := _h / 2
	var added: Array = []
	for x in range(_w / 2 + _bar_width(), mini(_w / 2 + _bar_width() + _w / 8, _w)):
		added.append(b.get_pixel(x, y).r - _s.get_pixel(x, y).r * RetailBloom.SCREEN_KEEP)
	var peaks := 0
	for i in range(1, added.size() - 1):
		# A rise of more than one level: 8-bit steps of a falling signal are not a peak.
		if float(added[i]) > float(added[i - 1]) + 1.5 / 255.0 and float(added[i]) >= float(added[i + 1]):
			peaks += 1
	print("ECHO %s %dx%d: the added light right of a white bar over %d px falls from %.1f/255 to %.1f/255 with %d peaks" % [
		_rend(), _w, _h, added.size(), float(added[0]) * 255.0, float(added[-1]) * 255.0, peaks])
	if peaks > 0:
		_failures += 1
