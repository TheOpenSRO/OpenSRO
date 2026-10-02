extends SceneTree

## Measurement (round 693): does a lit surface come out the same under both
## renderers? One quad facing the camera, a StandardMaterial3D of a given
## albedo, lit by World3D's kind of light -- a DirectionalLight3D at energy
## 0.3 and an ambient colour (Environment ambient source COLOR) -- through
## World3D's tone mapper (Filmic), read back at the centre. Each case changes
## one thing, so a difference between the renderers can be put on the
## ambient term, the sun's term, the tone mapper or the albedo.
##
## Windowed, on the render box (tools/xwl_run.sh for Forward+, xvfb-run +
## vglrun for Compatibility), `--script res://tools/measure_lit_space.gd`.

const CASES := [
	# [name, albedo, unshaded, sun energy, ambient colour, tonemap filmic, sun casts shadows]
	["unshaded, linear tonemap", Color8(150, 120, 90), true, 0.0, Color.BLACK, false],
	["unshaded, filmic", Color8(150, 120, 90), true, 0.0, Color.BLACK, true],
	["ambient only 0.7, linear", Color8(150, 120, 90), false, 0.0, Color(0.7, 0.7, 0.7), false],
	["ambient only 0.7, filmic", Color8(150, 120, 90), false, 0.0, Color(0.7, 0.7, 0.7), true],
	["sun 0.3 only, linear", Color8(150, 120, 90), false, 0.3, Color.BLACK, false],
	["sun 0.3 only, filmic", Color8(150, 120, 90), false, 0.3, Color.BLACK, true],
	["sun 0.3 + ambient 0.7, filmic", Color8(150, 120, 90), false, 0.3, Color(0.7, 0.7, 0.7), true],
	["sun 1.0 + ambient 0.4, filmic", Color8(150, 120, 90), false, 1.0, Color(0.4, 0.4, 0.4), true],
	# World3D's sun casts shadows (World3D.tscn shadow_enabled); nothing
	# here occludes it, so a renderer that draws the same with and without
	# is drawing the same light.
	["sun 0.3 only, shadows on, filmic", Color8(150, 120, 90), false, 0.3, Color.BLACK, true, true],
	["sun 0.3 + ambient 0.7, shadows on, filmic", Color8(150, 120, 90), false, 0.3, Color(0.7, 0.7, 0.7), true, true],
	# The Forward+ sun scale's calibration (WorldPostEffects.sun_scale):
	# the same light at 0.3 x k.
	["sun 0.3x2 + ambient 0.7, shadows on, filmic", Color8(150, 120, 90), false, 0.6, Color(0.7, 0.7, 0.7), true, true],
	["sun 0.3x3 + ambient 0.7, shadows on, filmic", Color8(150, 120, 90), false, 0.9, Color(0.7, 0.7, 0.7), true, true],
	["sun 0.3x4 + ambient 0.7, shadows on, filmic", Color8(150, 120, 90), false, 1.2, Color(0.7, 0.7, 0.7), true, true],
]

var _case := -1
var _wait := 0
var _quad: MeshInstance3D
var _sun: DirectionalLight3D
var _env: Environment

func _initialize() -> void:
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color.BLACK
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	var we := WorldEnvironment.new()
	we.environment = _env
	root.add_child(we)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 3)
	cam.current = true
	root.add_child(cam)
	_sun = DirectionalLight3D.new()
	# 45 degrees off the quad's normal, as a sun above and in front.
	_sun.rotation_degrees = Vector3(-45.0, 0.0, 0.0)
	root.add_child(_sun)
	_quad = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(4.0, 4.0)
	_quad.mesh = q
	root.add_child(_quad)
	print("LIT renderer: %s, adapter %s" % [RendererChoice.running(), RenderingServer.get_video_adapter_name()])
	RenderingServer.frame_post_draw.connect(_drawn)
	_next()

func _next() -> void:
	_case += 1
	if _case >= CASES.size():
		quit(0)
		return
	var cs: Array = CASES[_case]
	var m := StandardMaterial3D.new()
	m.albedo_color = cs[1]
	if cs[2]:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_quad.material_override = m
	_sun.light_energy = cs[3]
	_sun.visible = cs[3] > 0.0
	_sun.shadow_enabled = cs.size() > 6 and cs[6]
	_env.ambient_light_color = cs[4]
	_env.ambient_light_energy = 1.0
	_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC if cs[5] else Environment.TONE_MAPPER_LINEAR
	_wait = 3

func _drawn() -> void:
	if _case >= CASES.size():
		return
	_wait -= 1
	if _wait > 0:
		return
	var img := root.get_texture().get_image()
	var p := img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	print("LIT %-32s read (%3d,%3d,%3d)" % [CASES[_case][0], p.r8, p.g8, p.b8])
	_next()
