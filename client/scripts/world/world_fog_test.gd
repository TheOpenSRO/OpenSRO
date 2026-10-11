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

## The engine's depth correction (READ, core/math/projection.cpp
## set_depth_correction at 4.7.2-stable, no y flip): z scaled by +-1 (or
## +-0.5 and offset 0.5 when remapped to 0..1). 4.2.2's RenderingDevice
## correction is the remap without the reversal; its GLES3 applies none.
func _depth_correction(reverse: bool, remap: bool) -> Projection:
	if not reverse and not remap:
		return Projection.IDENTITY
	var zz := (-0.5 if reverse else 0.5) if remap else (-1.0 if reverse else 1.0)
	return Projection(Vector4(1, 0, 0, 0), Vector4(0, 1, 0, 0), Vector4(0, 0, zz, 0), Vector4(0, 0, 0.5 if remap else 0.0, 1))

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
	_check(-128 < WorldFog.UNDER_PASS_PRIORITY and WorldFog.UNDER_PASS_PRIORITY < ShadowCatcher.PRIORITY
		and ShadowCatcher.PRIORITY < WorldFog.PASS_PRIORITY and WorldFog.PASS_PRIORITY < 0,
		"the transparent order: cloud layer (-128), the ground's overlays and water (%d), Detail's catcher (%d), the fog pass (%d), every default transparent (0)" % [
			WorldFog.UNDER_PASS_PRIORITY, ShadowCatcher.PRIORITY, WorldFog.PASS_PRIORITY])
	var pass_mi := WorldFog.build_pass(false)
	var pmat := pass_mi.material_override as ShaderMaterial
	_check(pmat != null and pmat.render_priority == WorldFog.PASS_PRIORITY and pass_mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"the pass's material has the pass priority and casts no shadow")
	var code := WorldFog.pass_shader_code()
	_check(code.contains("hint_depth_texture") and code.contains("depth_test_disabled") and code.contains("blend_mix") and code.contains("discard"),
		"the pass reads the opaque depth, ignores the depth test, blends, and leaves the sky (no depth) alone")
	pass_mi.free()
	# Round 705: Forward+ mixes in display values, as Direct3D 9 and Compatibility do -- without
	# reading the screen (Godot's copy cost +1.4 ms at 4K, MEASURED).
	var fwd := WorldFog.pass_shader_code(false)
	var gl := WorldFog.pass_shader_code(true)
	_check(not fwd.contains("hint_screen_texture") and fwd.contains("srr_unshown(mix(vec3(0.2), srr_fog_shown, f.a))")
		and is_equal_approx(WorldFog.REFERENCE_SHOWN, 0.2),
		"Forward+: the pass mixes in the values the screen shows, at the reference destination (0.2), with no screen read")
	_check(not gl.contains("hint_screen_texture") and gl.contains(WorldFog.BLEND_COMPATIBILITY),
		"Compatibility: the framebuffer blend already mixes display values")
	# The shader's algebra on the CPU (linear tone map): exact at the reference and at the fog
	# colour, close between, much closer than the linear blend was.
	var fog_shown := [jangan.r, jangan.g, jangan.b]
	var worst := 0.0
	var worst_linear := 0.0
	for dshown in [0.05, 0.1, 0.2, 0.3, 0.4, 0.6]:
		for a in [0.05, 0.25, 0.37, 0.5, 0.75, 1.0]:
			var lref := WorldFog.srgb_to_linear(WorldFog.REFERENCE_SHOWN)
			var slopes := 0.0
			var at_ref := []
			for c in 3:
				var lf := WorldFog.srgb_to_linear(fog_shown[c])
				var g := WorldFog.srgb_to_linear(lerpf(WorldFog.REFERENCE_SHOWN, fog_shown[c], a))
				at_ref.append(g)
				slopes += (lf - g) / (lf - lref)
			var la := clampf(1.0 - slopes / 3.0, 0.0, 1.0)
			for c in 3:
				var src := maxf((float(at_ref[c]) - lref * (1.0 - la)) / la, 0.0)
				var dst := WorldFog.srgb_to_linear(dshown)
				var mixed := WorldFog.linear_to_srgb(src * la + dst * (1.0 - la))
				var want := lerpf(dshown, fog_shown[c], a)
				worst = maxf(worst, absf(mixed - want))
				var lf2 := WorldFog.srgb_to_linear(fog_shown[c])
				worst_linear = maxf(worst_linear, absf(WorldFog.linear_to_srgb(lerpf(dst, lf2, a)) - want))
				if is_equal_approx(dshown, WorldFog.REFERENCE_SHOWN) or a == 1.0:
					_check(absf(mixed - want) < 0.002, "exact at %s (destination %.2f, %.0f%% fog, channel %d)" % [
						"the reference" if a < 1.0 else "full fog", dshown, a * 100.0, c])
	_check(worst < 0.075 and worst_linear > 0.15, "the mix's worst error %.1f/255 against the display mix (the linear blend's: %.1f/255)" % [worst * 255.0, worst_linear * 255.0])
	var tm_pass := WorldFog.build_pass(false)
	var tm_env := Environment.new()
	tm_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	tm_env.tonemap_exposure = 1.25
	WorldFog.set_pass_tonemap(tm_pass, tm_env)
	var tmm := tm_pass.material_override as ShaderMaterial
	_check(bool(tmm.get_shader_parameter("tm_filmic")) and is_equal_approx(float(tmm.get_shader_parameter("tm_exposure")), 1.25),
		"the Forward+ pass takes the environment's tone map")
	tm_pass.free()
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

	# Round 760: the cloud layer's far-plane pin per engine and renderer (WorldFog.far_clip_z).
	if WorldFog.reverse_z():
		_check(WorldFog.far_clip_z(false) == 0.0 and WorldFog.far_clip_z(true) == -1.0,
			"4.3+: the far plane is clip z 0 under Forward+ (0..1) and -w under Compatibility (-1..1)")
	else:
		_check(WorldFog.far_clip_z(false) == 1.0 and WorldFog.far_clip_z(true) == 1.0, "4.2: the far plane is z = w in both")
	var cloud := FileAccess.get_file_as_string("res://scripts/assets/cloud_dome.gdshader")
	_check(cloud.contains("p.z = far_clip_z * p.w;") and src.contains("WorldFog.far_clip_z(RendererChoice.running() != RendererChoice.FORWARD_PLUS)"),
		"the cloud layer is pinned through far_clip_z, per renderer")
	# The pin sits on the far plane after the engine's own depth correction (core/math/projection.cpp).
	for compat in [false, true]:
		var proj: Projection = _depth_correction(WorldFog.reverse_z(), not compat) * Projection.create_perspective(60.0, 1.5, 0.05, 11520.0)
		var far_clip: Vector4 = proj * Vector4(0.0, 0.0, -11520.0, 1.0)
		_check(absf(far_clip.z / far_clip.w - WorldFog.far_clip_z(compat)) < 1e-3,
			"%s: a point on the far plane has clip z/w %.4f = far_clip_z" % ["Compatibility" if compat else "Forward+", far_clip.z / far_clip.w])

	# Round 774: a dungeon's fog (READ, the object shader's EXP + HEIGHT).
	var b1 := Vector4(1000.0, 830.0, 135.0, 0.21)
	for row in [[1000.0, 0.987], [3000.0, 0.885], [5000.0, 0.712], [10000.0, 0.257]]:
		var kept := 1.0 - WorldFog.dungeon_amount(row[0], 1000.0, 0.00014, b1)
		_check(absf(kept - row[1]) < 0.0015, "dungeon EXP: 2^-((z x density)^2) at depth %d keeps %.3f (got %.4f)" % [row[0], row[1], kept])
	var low := 1.0 - WorldFog.dungeon_amount(0.0, 0.0, 0.00014, b1)
	_check(absf(low - (1.0 - 0.21 * (1000.0 - 830.0) / 135.0)) < 1e-4, "dungeon HEIGHT: y 0 keeps 1 - A3 (|y - A0| - A1) / A2 (got %.4f)" % low)
	_check(WorldFog.dungeon_amount(0.0, 1000.0, 0.00014, b1) == 0.0, "inside the band and at the eye: no fog")
	_check(WorldFog.height_constant(Vector4(1.0, 2.0, 0.0, 0.5)) == Vector4(1.0, 2.0, 1.0, 0.5) and WorldFog.height_constant(Vector4(1, 2, 3, 0)) == Vector4.ZERO,
		"c22: A2 0 taken as 1, A3 not above 0 uploads nothing")
	_check(WorldFog.SHADER_FN.contains("exp2(") and WorldFog.SHADER_FOG_LINE.contains("INV_VIEW_MATRIX"),
		"the shaders' dungeon branch is base 2, and a self-fogged shader passes its world height")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit(1 if _failures > 0 else 0)
