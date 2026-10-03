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
## **Here.** One canvas pass on its own layer, above the 3D view and below
## every interface layer (LAYER; the brightness pass is 120), in both
## renderers, computing retail's pipeline at retail's resolution (rework
## review: taps at full resolution landed 19.5 / 39 pixels apart at 3840
## wide, drew sharp echoes of edges and cost +0.82 ms there; taps on the
## screen's Gaussian mips cost +2.0 ms there). The pass is a 514 x 514-vertex
## grid, one vertex per texel of the 512 x 512 target (plus a clamped edge
## ring): each vertex's shader computes that texel's blurred value exactly as
## retail's three passes would -- D at the texel centres (one bilinear sample
## of the screen, x 128/255), the horizontal blur's five taps between them
## (bilinear in 512 texels, each thresholded at 40/255), the vertical blur's
## five rows -- and the fragments interpolate it across the grid (retail
## magnifies its target bilinearly; a grid of triangles interpolates
## linearly within each half-cell, OURS), and the composite is the blend, as
## retail's is (premultiplied alpha: Blur x 192/255 + screen x 198/255, the
## framebuffer clamping at 1), so the fragments never read the screen. The texture is read clamped at the edges
## (retail's addressing there not read). It replaces round 693's Godot glow,
## whose parameters were a guess (intensity 0.8, bloom 0.2, threshold 0.85).
##
## **Under Compatibility** (round 707) the pass is a full-screen rect whose
## fragments compute the same pipeline at their own point of the 512 target:
## the 25 taps (+-2.6 / +-5.2 texels, the weights, the threshold per tap
## before the horizontal sum, the clamps at 1), each tap one bilinear sample
## of the screen itself at that point of the 512 target (COMPAT_SHADER). Two
## things differ from the grid, both OURS: a tap between two 512 texels reads
## the screen there instead of mixing the two texels' samples, and the blur is
## evaluated at every pixel instead of magnified from the 512 texels. GLES3's
## canvas reads the screen only in a fragment stage (READ, Godot 4.2.2
## canvas.glsl: `color_buffer`, the screen texture, is declared in the
## fragment section alone), so the grid cannot run there.
##
## **And it must keep a screen to read (round 707).** Under Compatibility a 3D
## pass that reads the depth texture -- WorldFog's -- makes Godot 4.2.2 create
## the render target's back buffer itself (READ, gles3 texture_storage.cpp
## `copy_scene_to_backbuffer`): a framebuffer with the depth copy and, unless
## some 3D material reads the screen too, NO colour texture. The canvas then
## finds the back buffer made (`render_target_copy_to_back_buffer` creates its
## own only while there is none), copies the screen into nothing, and every
## canvas screen read samples texture 0: black. The pass's opaque output made
## the whole frame (0, 0, 0) (MEASURED, round 705 and 707). So under
## Compatibility the bloom keeps a 3D anchor in the view (ANCHOR_SHADER): a
## material that reads the screen texture and covers no pixel, which makes
## the 3D pass give the back buffer its colour texture every time it creates
## it. That texture has one level and nearest filtering when the 3D pass made
## it, and a mip chain with linear filtering when the canvas did, so the taps
## read it with texelFetch and filter bilinearly themselves -- the same in
## either case (READ, the same file). They ask for no mipmaps: a canvas made
## back buffer sets the render target's mip count, which survives the target's
## re-creation, and a mip request over the one-level texture the 3D pass then
## makes would leave it incomplete -- black again (READ: `mipmap_count` is set
## only in `_create_render_target_backbuffer`, never reset; `gaussian_blur`
## sets MAX_LEVEL from it). The brightness pass (VideoOptions, layer 120)
## reads the screen the same way and keeps the anchor shown as well.

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
// The original's bloom (RetailBloom, round 702 review and rework):
// Map::FUN_00a1d790's three passes at 512 x 512, one vertex per texel. The
// composite is the blend itself, as retail's is: premultiplied alpha,
// out = src.rgb + dst x (1 - src.a) = Blur x 192/255 + S x 198/255.
render_mode blend_premul_alpha;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform vec2 canvas_size = vec2(1280.0, 720.0);
const float DOWNSAMPLE = 128.0 / 255.0;
const float THRESHOLD = 40.0 / 255.0;
const float SCREEN_KEEP = 198.0 / 255.0;
const float BLUR_ADD = 192.0 / 255.0;
const float T = 512.0;
const float W0 = 80.0 / 255.0;
const float W1 = 70.0 / 255.0;
const float W2 = 50.0 / 255.0;
varying vec3 v_blur;
// The downsampled target at texel t: one bilinear sample at its centre.
vec3 d_at(vec2 t) {
	t = clamp(t, vec2(0.0), vec2(T - 1.0));
	return textureLod(screen_tex, (t + 0.5) / T, 0.0).rgb * DOWNSAMPLE;
}
vec3 th(vec3 v) {
	return max(v - vec3(THRESHOLD), vec3(0.0));
}
// The horizontal pass at texel t: taps at 0, +-2.6, +-5.2, bilinear between
// texels, each thresholded; the 8-bit target clamps at 1.
vec3 h_at(vec2 t) {
	vec2 x = vec2(1.0, 0.0);
	vec3 h = W0 * th(d_at(t));
	h += W1 * th(mix(d_at(t + 2.0 * x), d_at(t + 3.0 * x), 0.6));
	h += W1 * th(mix(d_at(t - 3.0 * x), d_at(t - 2.0 * x), 0.4));
	h += W2 * th(mix(d_at(t + 5.0 * x), d_at(t + 6.0 * x), 0.2));
	h += W2 * th(mix(d_at(t - 6.0 * x), d_at(t - 5.0 * x), 0.8));
	return min(h, vec3(1.0));
}
// The vertical pass: the same taps in y, no threshold.
vec3 v_at(vec2 t) {
	vec2 y = vec2(0.0, 1.0);
	vec3 v = W0 * h_at(t);
	v += W1 * mix(h_at(t + 2.0 * y), h_at(t + 3.0 * y), 0.6);
	v += W1 * mix(h_at(t - 3.0 * y), h_at(t - 2.0 * y), 0.4);
	v += W2 * mix(h_at(t + 5.0 * y), h_at(t + 6.0 * y), 0.2);
	v += W2 * mix(h_at(t - 6.0 * y), h_at(t - 5.0 * y), 0.8);
	return min(v, vec3(1.0));
}
void vertex() {
	// UV carries the texel index, -1 .. 512 (the ring clamps to the edge).
	vec2 t = clamp(UV, vec2(0.0), vec2(T - 1.0));
	VERTEX = clamp((UV + 0.5) / T, vec2(0.0), vec2(1.0)) * canvas_size;
	v_blur = v_at(t);
}
void fragment() {
	COLOR = vec4(v_blur * BLUR_ADD, 1.0 - SCREEN_KEEP);
}
"""

## Compatibility's pass (see the header): the 25 taps per pixel, each a
## bilinear sample of the screen at that point of the 512 target, filtered
## here from texelFetch; the composite is the blend, as the grid's.
const COMPAT_SHADER := """
shader_type canvas_item;
// The original's bloom (RetailBloom) under Compatibility (round 707):
// Map::FUN_00a1d790's pipeline evaluated at each pixel's point of the 512 x
// 512 target. out = Blur x 192/255 + S x 198/255 (premultiplied alpha).
render_mode blend_premul_alpha;
uniform sampler2D screen_tex : hint_screen_texture, filter_nearest, repeat_disable;
const float DOWNSAMPLE = 128.0 / 255.0;
const float THRESHOLD = 40.0 / 255.0;
const float SCREEN_KEEP = 198.0 / 255.0;
const float BLUR_ADD = 192.0 / 255.0;
const float T = 512.0;
float w(int i) {
	int a = abs(i);
	return a == 0 ? 80.0 / 255.0 : (a == 1 ? 70.0 / 255.0 : 50.0 / 255.0);
}
float o(int i) {
	return float(sign(i)) * (abs(i) == 1 ? 2.6 : (abs(i) == 2 ? 5.2 : 0.0));
}
// One bilinear sample of the screen at pixel position p (texel centres at
// +0.5), clamped at the edges; texelFetch, so the back buffer's own filter
// (nearest or linear, by who made it) does not matter.
vec3 screen_at(vec2 p, ivec2 hi) {
	vec2 q = p - 0.5;
	vec2 f = fract(q);
	ivec2 i0 = clamp(ivec2(floor(q)), ivec2(0), hi);
	ivec2 i1 = clamp(ivec2(floor(q)) + 1, ivec2(0), hi);
	vec3 a = mix(texelFetch(screen_tex, i0, 0).rgb, texelFetch(screen_tex, ivec2(i1.x, i0.y), 0).rgb, f.x);
	vec3 b = mix(texelFetch(screen_tex, ivec2(i0.x, i1.y), 0).rgb, texelFetch(screen_tex, i1, 0).rgb, f.x);
	return mix(a, b, f.y);
}
void fragment() {
	ivec2 size = textureSize(screen_tex, 0);
	ivec2 hi = size - 1;
	vec2 scale = vec2(size) / T;
	// This pixel in texels of the 512 target (texel centres at integers).
	vec2 t = SCREEN_UV * T - 0.5;
	vec3 blur = vec3(0.0);
	for (int j = -2; j <= 2; j++) {
		vec3 row = vec3(0.0);
		for (int i = -2; i <= 2; i++) {
			// The downsampled target there (x 128/255), read clamped at its edge.
			vec2 tap = clamp(t + vec2(o(i), o(j)), vec2(0.0), vec2(T - 1.0));
			vec3 d = screen_at((tap + 0.5) * scale, hi) * DOWNSAMPLE;
			row += w(i) * max(d - vec3(THRESHOLD), vec3(0.0));
		}
		// The horizontal pass's 8-bit target clamps at 1.
		blur += w(j) * min(row, vec3(1.0));
	}
	COLOR = vec4(min(blur, vec3(1.0)) * BLUR_ADD, 1.0 - SCREEN_KEEP);
}
"""

## Compatibility's 3D anchor (see the header): reads the screen texture, so
## Godot's 3D pass gives the back buffer a colour texture, and draws nothing
## (every vertex outside the clip volume).
const ANCHOR_SHADER := """
shader_type spatial;
// RetailBloom's anchor (round 707): keeps the GL back buffer's colour texture.
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled, shadows_disabled, skip_vertex_transform;
uniform sampler2D screen_tex : hint_screen_texture, filter_nearest, repeat_disable;
void vertex() {
	POSITION = vec4(2.0, 2.0, 2.0, 1.0);
}
void fragment() {
	ALBEDO = textureLod(screen_tex, SCREEN_UV, 0.0).rgb;
	ALPHA = 0.0;
}
"""

var _pass: CanvasItem
var _material: ShaderMaterial
var _grid_used := false
var _anchor: MeshInstance3D = null
static var _mesh: ArrayMesh = null

func _init(use_grid: bool = RenderingServer.get_rendering_device() != null) -> void:
	name = "RetailBloom"
	layer = LAYER_INDEX
	_grid_used = use_grid
	var sh := Shader.new()
	sh.code = SHADER if use_grid else COMPAT_SHADER
	_material = ShaderMaterial.new()
	_material.shader = sh
	if use_grid:
		var grid := MeshInstance2D.new()
		grid.mesh = grid_mesh()
		_pass = grid
	else:
		var rect := ColorRect.new()
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_pass = rect
		_anchor = anchor_node()
		add_child(_anchor)
		# A 3D node does not follow a CanvasLayer's visibility on its own.
		visibility_changed.connect(_sync_anchor)
	_pass.name = "Pass"
	_pass.material = _material
	add_child(_pass)
	_sync_anchor()

## Whether the 512 grid (Forward+) draws the pass, or the per-pixel rect.
func uses_grid() -> bool:
	return _grid_used

## Compatibility's 3D anchor (null under Forward+).
func anchor() -> MeshInstance3D:
	return _anchor

## The anchor shows while any canvas pass of the world reads the screen: the
## bloom, or VideoOptions' brightness pass (round 707: with Bloom off from the
## start and Brightness off Normal, Compatibility drew that pass black too --
## MEASURED, the frame's mean 0). Off otherwise: no 3D copy of the screen.
func _sync_anchor() -> void:
	if _anchor != null:
		_anchor.visible = visible or _brightness_shown()

func _brightness_shown() -> bool:
	if not is_inside_tree():
		return false
	var b := get_tree().root.get_node_or_null(VideoOptions.BRIGHTNESS_LAYER) as CanvasLayer
	return b != null and b.visible

## The anchor (see the header): one triangle with ANCHOR_SHADER, never culled
## and casting nothing.
static func anchor_node() -> MeshInstance3D:
	var sh := Shader.new()
	sh.code = ANCHOR_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, mat)
	mesh.custom_aabb = AABB(Vector3(-1.0e6, -1.0e6, -1.0e6), Vector3(2.0e6, 2.0e6, 2.0e6))
	var mi := MeshInstance3D.new()
	mi.name = "ScreenAnchor"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func _process(_delta: float) -> void:
	if _grid_used and visible and is_inside_tree():
		_material.set_shader_parameter("canvas_size", get_viewport().get_visible_rect().size)
	# The brightness pass comes and goes on its own (VideoOptions); a frame's
	# delay at most.
	_sync_anchor()

## The 514 x 514-vertex grid (UV = texel index, -1 .. 512), built once.
static func grid_mesh() -> ArrayMesh:
	if _mesh != null:
		return _mesh
	var n := int(TARGET_SIZE) + 2
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	verts.resize(n * n)
	uvs.resize(n * n)
	for j in n:
		for i in n:
			var k := j * n + i
			uvs[k] = Vector2(i - 1, j - 1)
			verts[k] = Vector2(i, j)
	var idx := PackedInt32Array()
	idx.resize((n - 1) * (n - 1) * 6)
	var c := 0
	for j in n - 1:
		for i in n - 1:
			var a := j * n + i
			idx[c] = a
			idx[c + 1] = a + 1
			idx[c + 2] = a + n
			idx[c + 3] = a + 1
			idx[c + 4] = a + n + 1
			idx[c + 5] = a + n
			c += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	_mesh = ArrayMesh.new()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# The vertex shader places every vertex; a huge box keeps it from culling.
	_mesh.custom_aabb = AABB(Vector3(-1.0e6, -1.0e6, -1.0), Vector3(2.0e6, 2.0e6, 2.0))
	return _mesh

## The blur's value for one channel from the screen's values at the 25 taps
## (`taps[j + 2][i + 2]`, j the row) -- the separable arithmetic, for the
## tests (the shader takes its taps between 512 texels, as retail does).
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
