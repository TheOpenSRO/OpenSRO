extends SceneTree

## Measurement (round 693): in which colour space does this renderer blend?
##
## Draws, unshaded, an opaque background quad of colour B and in front of it a
## quad of colour A at alpha a (blend_mix), or added (blend_add), reads the
## frame back and prints the pixel beside two predictions:
##   gamma:  a*A + (1-a)*B                (blending the stored display values,
##                                         as Direct3D 9 and, by reading, GL
##                                         Compatibility's sRGB-valued
##                                         framebuffer do)
##   linear: enc(a*dec(A) + (1-a)*dec(B)) (blending in a linear buffer, as
##                                         Forward+ does)
## A and B are given as display values, set as Colors and read through
## ShaderColour's srr_color, decoded where the output is linear, so an
## opaque quad reads back as its own value under both renderers -- the
## "opaque" rows check that first.
##
## Run windowed (a real renderer) on the render box, e.g.
##   tools/xwl_run.sh godot --rendering-method forward_plus --rendering-driver vulkan \
##     --path client --script res://tools/measure_blend_space.gd
## or under xvfb-run + vglrun with --rendering-driver opengl3.

const CASES := [
	# [name, A, B, alpha, add]
	["opaque grass", Color8(90, 120, 50), Color8(30, 40, 60), 1.0, false],
	["opaque sand", Color8(200, 180, 140), Color8(30, 40, 60), 1.0, false],
	["mix 0.25 sand over grass", Color8(200, 180, 140), Color8(90, 120, 50), 0.25, false],
	["mix 0.50 sand over grass", Color8(200, 180, 140), Color8(90, 120, 50), 0.5, false],
	["mix 0.75 sand over grass", Color8(200, 180, 140), Color8(90, 120, 50), 0.75, false],
	["mix 0.50 water over dark", Color8(60, 90, 110), Color8(20, 25, 30), 0.5, false],
	["mix 0.784 water (200/255) over sand", Color8(60, 90, 110), Color8(200, 180, 140), 200.0 / 255.0, false],
	["add 0.5 glow over dark", Color8(120, 80, 40), Color8(20, 25, 30), 0.5, true],
]

const CODE := """shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, %s;
uniform vec4 col = vec4(1.0);
%s
void fragment() {
	ALBEDO = srr_color(col, OUTPUT_IS_SRGB).rgb;
	%s
	ALPHA = col.a;
}
"""

var _case := -1
var _wait := 0
var _bg: MeshInstance3D
var _fg: MeshInstance3D

func _quad(z: float, add: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(4.0, 4.0)
	mi.mesh = q
	mi.position = Vector3(0, 0, z)
	var sh := Shader.new()
	sh.code = CODE % ["blend_add" if add else "blend_mix", ShaderColour.DECODE_FN, ShaderColour.DECODE_ALBEDO]
	var m := ShaderMaterial.new()
	m.shader = sh
	mi.material_override = m
	root.add_child(mi)
	return mi

func _initialize() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 3)
	cam.current = true
	root.add_child(cam)
	_bg = _quad(-1.0, false)
	print("BLEND renderer: %s, adapter %s" % [RendererChoice.running(), RenderingServer.get_video_adapter_name()])
	RenderingServer.frame_post_draw.connect(_drawn)
	_next()

func _next() -> void:
	_case += 1
	if _case >= CASES.size():
		quit(0)
		return
	var cs: Array = CASES[_case]
	if _fg != null:
		_fg.queue_free()
	_fg = _quad(0.0, cs[4])
	var a: Color = cs[1]
	var b: Color = cs[2]
	(_bg.material_override as ShaderMaterial).set_shader_parameter("col", Color(b.r, b.g, b.b, 1.0))
	(_fg.material_override as ShaderMaterial).set_shader_parameter("col", Color(a.r, a.g, a.b, cs[3]))
	_wait = 3

func _drawn() -> void:
	if _case >= CASES.size():
		return
	_wait -= 1
	if _wait > 0:
		return
	var img := root.get_texture().get_image()
	var p := img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	var cs: Array = CASES[_case]
	var a: Color = cs[1]
	var b: Color = cs[2]
	var al: float = cs[3]
	var add: bool = cs[4]
	var gamma := Color(a.r * al + (0.0 if add else 1.0 - al) * b.r + (b.r if add else 0.0),
		a.g * al + (0.0 if add else 1.0 - al) * b.g + (b.g if add else 0.0),
		a.b * al + (0.0 if add else 1.0 - al) * b.b + (b.b if add else 0.0))
	var la := a.srgb_to_linear()
	var lb := b.srgb_to_linear()
	var lin := Color(la.r * al + (1.0 if add else 1.0 - al) * lb.r, la.g * al + (1.0 if add else 1.0 - al) * lb.g,
		la.b * al + (1.0 if add else 1.0 - al) * lb.b).linear_to_srgb()
	print("BLEND %-36s read (%3d,%3d,%3d)  gamma (%3d,%3d,%3d)  linear (%3d,%3d,%3d)  |read-gamma| %3d  |read-linear| %3d" % [
		cs[0], p.r8, p.g8, p.b8, _c8(gamma.r), _c8(gamma.g), _c8(gamma.b), _c8(lin.r), _c8(lin.g), _c8(lin.b),
		_dmax(p, gamma), _dmax(p, lin)])
	_next()

static func _c8(v: float) -> int:
	return clampi(roundi(v * 255.0), 0, 255)

static func _dmax(p: Color, q: Color) -> int:
	return maxi(maxi(absi(p.r8 - _c8(q.r)), absi(p.g8 - _c8(q.g))), absi(p.b8 - _c8(q.b)))
