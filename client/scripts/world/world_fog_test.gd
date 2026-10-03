extends SceneTree

## WorldFog (round 702): the original's linear fog between the zone's planes
## (READ, Map::FUN_00a26f60), its colour through the tone map, the order of
## the transparent pass, and what World3D no longer adds (Godot's
## exponential fog, sun scatter and aerial perspective).
##
## `godot4 --headless --path client --script res://scripts/world/world_fog_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	# D3D linear fog: none before the start, all of it from the end on.
	_check(WorldFog.amount(0.0, 1250.0, 2250.0) == 0.0 and WorldFog.amount(1249.0, 1250.0, 2250.0) == 0.0,
		"nothing nearer than the start plane is fogged (Jangan 1250)")
	_check(is_equal_approx(WorldFog.amount(1750.0, 1250.0, 2250.0), 0.5), "half-way between the planes is half fog")
	_check(WorldFog.amount(2250.0, 1250.0, 2250.0) == 1.0 and WorldFog.amount(9000.0, 1250.0, 2250.0) == 1.0,
		"the end plane and past it is the fog colour itself")
	_check(is_equal_approx(WorldFog.amount(90.0, -367.5, 1167.5), (90.0 + 367.5) / 1535.0),
		"a zone whose start is behind the camera (channel 10 = -0.147, READ range) fogs near the camera too")
	# The planes: channels 10 and 11 times the view distance (READ).
	_check(WorldFog.planes(0.5, 0.9) == Vector2(1250.0, 2250.0), "Jangan's Env7 (0.5, 0.9) at the default view distance 2500: 1250..2250")
	_check(WorldFog.planes(0.5, 0.9, VideoOptions.view_distance(0)) == Vector2(600.0, 1080.0),
		"Background Sight Range 1 (view distance 1200, READ) pulls the planes in: 600..1080")
	_check(is_equal_approx(WorldFog.VIEW_DISTANCE_DEFAULT, EnvironmentReader.VIEW_DISTANCE_DEFAULT), "the default view distance is 2500 (READ 0xec54b0)")

	# The colour: whatever the tone map, a fully fogged pixel shows the READ colour.
	for x in [0.0, 0.05, 0.2, 0.5, 0.9]:
		var t := WorldFog.filmic(x)
		_check(absf(WorldFog.filmic_inverse(t) - x) < 1.0e-4, "filmic_inverse(filmic(%.2f)) = %.2f" % [x, x])
	var env := Environment.new()
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var jangan := EnvironmentReader.render_fog_color(Color(0.357, 0.580, 0.677))
	var lin := WorldFog.pass_color(jangan, env)
	var shown := Color(WorldFog.linear_to_srgb(WorldFog.filmic(lin.r)), WorldFog.linear_to_srgb(WorldFog.filmic(lin.g)), WorldFog.linear_to_srgb(WorldFog.filmic(lin.b)))
	_check(absf(shown.r - jangan.r) < 0.002 and absf(shown.g - jangan.g) < 0.002 and absf(shown.b - jangan.b) < 0.002,
		"under Filmic the pass's colour is shown as the zone's fog colour (%s -> %s)" % [str(jangan), str(shown)])
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	lin = WorldFog.pass_color(jangan, env)
	_check(absf(WorldFog.linear_to_srgb(lin.g) - jangan.g) < 0.002, "under the linear tone map it is the decoded colour")

	# The transparent order: cloud layer, then what lies on opaque ground, then the pass, then the rest.
	_check(-128 < WorldFog.UNDER_PASS_PRIORITY and WorldFog.UNDER_PASS_PRIORITY < WorldFog.PASS_PRIORITY and WorldFog.PASS_PRIORITY < 0,
		"the pass sorts after the cloud layer (-128) and the ground's overlays and water (%d), before every default transparent (0)" % WorldFog.UNDER_PASS_PRIORITY)
	var pass_mi := WorldFog.build_pass(false)
	var pmat := pass_mi.material_override as ShaderMaterial
	_check(pmat != null and pmat.render_priority == WorldFog.PASS_PRIORITY and pass_mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"the pass's material has the pass priority and casts no shadow")
	var code := WorldFog.pass_shader_code()
	_check(code.contains("hint_depth_texture") and code.contains("depth_test_disabled") and code.contains("blend_mix") and code.contains("discard"),
		"the pass reads the opaque depth, ignores the depth test, blends, and leaves the sky (no depth) alone")
	pass_mi.free()
	_check(ProjectSettings.has_setting("shader_globals/srr_fog_params") and ProjectSettings.has_setting("shader_globals/srr_fog_color"),
		"project.godot declares the fog's shader globals")
	var water := MapmWater.water_material(null, Color(0.3, 0.6, 0.6))
	var still := MapmWater.still_material(null)
	_check(water.render_priority == WorldFog.UNDER_PASS_PRIORITY and still.render_priority == WorldFog.UNDER_PASS_PRIORITY,
		"both water surfaces are drawn before the pass, so it fogs them with the ground below")
	# A blended MTRL mod fogs itself; an opaque one is left to the pass.
	var blended := ObjectLoader._mod_shader("back", "mix", false)
	var opaque := ObjectLoader._mod_shader("back", "opaque", true)
	_check(blended.code.contains(WorldFog.SHADER_FOG_LINE) and blended.code.contains("global uniform vec4 srr_fog_params"),
		"a blended mod writes the original's fog itself (it is drawn after the pass)")
	_check(not opaque.code.contains(WorldFog.SHADER_FOG_LINE), "an opaque mod does not (the pass fogs it: no double fog)")
	_check(ObjectLoader._mod_shader("back", "opaque", true, true).code.contains(WorldFog.SHADER_FOG_LINE),
		"an opaque mod while it fades in is blended, so it fogs itself too")

	# World3D: Godot's own fog draws nothing now; the OURS haze terms are gone.
	var src := FileAccess.get_file_as_string("res://scripts/World3D.gd")
	_check(not src.contains("const FOG_DENSITY") and not src.contains("const FOG_SUN_SCATTER") and not src.contains("const FOG_AERIAL_PERSPECTIVE"),
		"the exponential fog's OURS density, sun scatter and aerial perspective are gone")
	_check(src.contains("env.fog_density = 0.0") and src.contains("env.fog_sun_scatter = 0.0") and src.contains("env.fog_aerial_perspective = 0.0"),
		"the environment's own fog is set to draw nothing")
	_check(src.contains("o.value(VideoOptions.FOG) == 1"), "the temporary Video row switches the fog")
	var ready_at := src.find("func _ready() -> void:")
	var build_at := src.find("_build_fog_pass()", ready_at)
	_check(build_at > ready_at and build_at < src.find("if title_mode:", ready_at), "World3D._ready builds the pass before the title branch (the title's backdrop is fogged too)")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit(1 if _failures > 0 else 0)
