extends CanvasLayer
class_name RetailBloom

## The Bloom Effect row, drawn as the original draws it (round 702 review).
##
## **READ** (`Map::FUN_00a1d790`, the bloom pass; its constants are set by the
## world's constructor `Map::FUN_00a2f370`):
## 1. The finished screen (target world+0x27c3, screen-sized) goes into a
##    512 x 512 target (+0x27c7), bilinear, stage 0 MODULATE(TEXTURE, TFACTOR)
##    with TFACTOR RGB 0x80: x 128 / 255.
## 2. A horizontal blur into a target cleared to 0 (+0x27cb), blended
##    SRCALPHA / ONE: colour SUBTRACT(TEXTURE, TFACTOR 0x28) -- a threshold of
##    40 / 255, clamped at 0 -- and each tap's alpha its weight: the centre
##    0x50, +-1 0x46, +-2 0x32 (/ 255), at +-2.6 and +-5.2 texels of 512
##    (2 x 13 x i / 10, the step world+0x690b = 13; the tap colours
##    world+0x68e3..).
## 3. A vertical blur back, the same weights and offsets in y, no threshold.
## 4. The composite: the plain screen first, then the blur with SRCBLEND =
##    BLENDFACTOR 0xc0c0c0 (+0x690d) and DESTBLEND = SRCALPHA, the alpha the
##    TFACTOR's 0xc6 (+0x690c):  out = clamp(S x 198/255 + Blur x 192/255),
##    in the frame's display values, before the interface is drawn.
## So it is a contrast effect as much as a glow: where nothing near is
## brighter than the threshold, the screen is kept at 198/255.
##
## **Here.** One full-screen canvas pass on its own layer, above the 3D view
## and below every interface layer (LAYER; the brightness pass is 120), in
## both renderers: the screen sampled bilinear at the 25 tap positions of the
## separable blur (OURS: at the screen's own resolution, not through a
## 512 x 512 copy -- the taps' offsets are the READ 512-texel ones), each
## through the READ downsample and threshold, weighted by the READ weights
## and composited by the READ blend. It replaces round 693's Godot glow, whose
## parameters were a guess (intensity 0.8, bloom 0.2, threshold 0.85).

## Below the default canvas (0), the world's UI (1) and every later layer;
## above the 3D view, which every canvas layer is.
const LAYER_INDEX := -1
const DOWNSAMPLE := 128.0 / 255.0
const THRESHOLD := 40.0 / 255.0
## Centre, +-1, +-2.
const WEIGHTS := [80.0 / 255.0, 70.0 / 255.0, 50.0 / 255.0]
## In texels of the 512 x 512 target.
const OFFSETS := [0.0, 2.6, 5.2]
const TARGET_SIZE := 512.0
const SCREEN_KEEP := 198.0 / 255.0
const BLUR_ADD := 192.0 / 255.0

const SHADER := """
shader_type canvas_item;
// The original's bloom (RetailBloom, round 702 review): Map::FUN_00a1d790.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
const float DOWNSAMPLE = 128.0 / 255.0;
const float THRESHOLD = 40.0 / 255.0;
const float SCREEN_KEEP = 198.0 / 255.0;
const float BLUR_ADD = 192.0 / 255.0;
const float TARGET = 512.0;
float w(int i) {
	int a = abs(i);
	return a == 0 ? 80.0 / 255.0 : (a == 1 ? 70.0 / 255.0 : 50.0 / 255.0);
}
float o(int i) {
	return float(sign(i)) * (abs(i) == 1 ? 2.6 : (abs(i) == 2 ? 5.2 : 0.0));
}
void fragment() {
	vec3 s = texture(screen_tex, SCREEN_UV).rgb;
	vec3 blur = vec3(0.0);
	for (int j = -2; j <= 2; j++) {
		vec3 row = vec3(0.0);
		for (int i = -2; i <= 2; i++) {
			vec3 t = texture(screen_tex, SCREEN_UV + vec2(o(i), o(j)) / TARGET).rgb;
			row += w(i) * max(t * DOWNSAMPLE - vec3(THRESHOLD), vec3(0.0));
		}
		blur += w(j) * row;
	}
	COLOR = vec4(clamp(s * SCREEN_KEEP + blur * BLUR_ADD, 0.0, 1.0), 1.0);
}
"""

var _rect: ColorRect

func _init() -> void:
	name = "RetailBloom"
	layer = LAYER_INDEX
	_rect = ColorRect.new()
	_rect.name = "Pass"
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var sh := Shader.new()
	sh.code = SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	_rect.material = mat
	add_child(_rect)

## The blur's value for one channel from the screen's values at the 25 taps
## (`taps[j + 2][i + 2]`, j the row): the shader's arithmetic, for the tests.
static func blur_of(taps: Array) -> float:
	var out := 0.0
	for j in range(-2, 3):
		var row := 0.0
		for i in range(-2, 3):
			row += float(WEIGHTS[absi(i)]) * maxf(float(taps[j + 2][i + 2]) * DOWNSAMPLE - THRESHOLD, 0.0)
		out += float(WEIGHTS[absi(j)]) * row
	return out

## The composite for one channel (READ blend).
static func composite(screen: float, blur: float) -> float:
	return clampf(screen * SCREEN_KEEP + blur * BLUR_ADD, 0.0, 1.0)
