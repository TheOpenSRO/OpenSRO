extends SceneTree

## Exercises WaterReflection's rules against synthetic data (never real game
## data), run headless:
## `godot4 --headless --path client --script res://scripts/mapm/water_reflection_test.gd`
##
## Loads the script by path, so the file also runs on a tree without it --
## how round 628's negative was taken: there the option does not exist and
## the default water samples no reflection.

const PATH := "res://scripts/mapm/water_reflection.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	if not ResourceLoader.exists(PATH):
		print("note: %s is missing -- checking what the tree draws instead" % PATH)
		_check(false, "a Water Reflection option exists and is ON by default, as the shipped SROptionSet.dat has it")
		var tex := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
		var m = MapmWater.water_material(tex, Color(1, 1, 1))
		_check(m is ShaderMaterial and (m as ShaderMaterial).get_shader_parameter("reflection_tex") != null,
			"the default water surface samples a reflection (got %s)" % m.get_class())
		_finish()
		return
	var R: GDScript = load(PATH)

	# --- The option: ON unless the setting or the env says otherwise.
	OS.set_environment("SRREVAMP_WATER_REFLECTION", "")
	# Only a settings.cfg that says `water_reflection=false` under [world]
	# turns it off; with the key absent it is on.
	var saved = ClientSettings.get_value("world", "water_reflection", "unset")
	_check(R.enabled() == (str(saved) == "unset" or bool(saved)), "with no env override the option is the setting, ON when unset (saved: %s)" % str(saved))
	OS.set_environment("SRREVAMP_WATER_REFLECTION", "0")
	_check(not R.enabled(), "SRREVAMP_WATER_REFLECTION=0 turns it off")
	OS.set_environment("SRREVAMP_WATER_REFLECTION", "1")
	_check(R.enabled(), "SRREVAMP_WATER_REFLECTION=1 turns it on")
	OS.set_environment("SRREVAMP_WATER_REFLECTION", "")

	# --- The bump map: (left - right) / 2 and (above - below) / 2 on blue,
	# wrapping, C division.
	var src := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	for y in range(4):
		for x in range(4):
			src.set_pixel(x, y, Color8(0, 0, x * 10 + y * 100, 255))
	var bump: Image = R.bump_image(src)
	_check(bump != null and bump.get_format() == Image.FORMAT_RG8 and bump.get_width() == 4, "the bump is RG8 at the source size")
	# x = 1, y = 1: left 100+0, right 100+20 -> du = -10; above 0+10, below 200+10 -> dv = -100.
	var p := bump.get_pixel(1, 1)
	_check(p.r8 - 128 == -10 and p.g8 - 128 == -100, "du = (left - right) / 2, dv = (above - below) / 2 (got %d, %d)" % [p.r8 - 128, p.g8 - 128])
	# x = 0 wraps left to x = 3: (130 - 110) / 2 = 10 at y = 1.
	var q := bump.get_pixel(0, 1)
	_check(q.r8 - 128 == 10, "the left neighbour wraps (got %d)" % (q.r8 - 128))
	_check(R._c_half(-3) == -1 and R._c_half(3) == 1 and R._c_half(-1) == 0, "C division truncates toward zero")

	# --- The bump matrix: 0.04 in magnitude, turning at 4.5 per time unit.
	var m0: Vector4 = R.bump_matrix(0.0)
	_check(m0.is_equal_approx(Vector4(0.04, 0.0, 0.0, 0.04)), "at t = 0 the bump matrix is 0.04 I (got %s)" % m0)
	var mq: Vector4 = R.bump_matrix(PI / 9.0) # 4.5 * pi / 9 = pi / 2
	_check(mq.is_equal_approx(Vector4(0.0, -0.04, 0.04, 0.0)), "a quarter turn at t = pi/9: [[0, -0.04], [0.04, 0]] (got %s)" % mq)

	# --- The mirrored camera.
	var cam := Transform3D(Basis.looking_at(Vector3(0, -0.5, -1).normalized(), Vector3.UP), Vector3(10, 80, 20))
	var mir: Transform3D = R.mirror_transform(cam, 50.0)
	_check(mir.origin.is_equal_approx(Vector3(10, 20, 20)), "the eye mirrors in the plane: y' = 2h - y (got %s)" % mir.origin)
	_check(absf(mir.basis.determinant() - 1.0) < 0.001, "the mirror camera is a rotation (det %s)" % mir.basis.determinant())
	var fwd := -cam.basis.z
	var mfwd := -mir.basis.z
	_check(mfwd.is_equal_approx(Vector3(fwd.x, -fwd.y, fwd.z)), "its look direction has y negated (got %s from %s)" % [mfwd, fwd])
	var down := Transform3D(Basis.looking_at(Vector3(0, -1, 0), Vector3(0, 0, -1)), Vector3(0, 300, 0))
	var mdown: Transform3D = R.mirror_transform(down, 50.0)
	_check((-mdown.basis.z).is_equal_approx(Vector3(0, 1, 0)), "straight down mirrors to straight up, no degenerate basis")

	# --- The plane: the water block nearest the camera's block.
	var blocks := [[5, 5, 30.0, Vector3.ZERO], [2, 2, 50.0, Vector3.ZERO], [3, 4, -20.0, Vector3.ZERO]]
	_check(R.pick_plane(blocks, 3, 3) == -20.0, "the nearest block's plane wins (got %s)" % R.pick_plane(blocks, 3, 3))
	_check(R.pick_plane(blocks, 2, 2) == 50.0, "the camera's own block is nearest")
	_check(is_nan(R.pick_plane([], 0, 0)), "no water, no plane")

	# --- Underwater: eye - 0.5 below the plane over a water block.
	_check(R.is_underwater(49.6, 50.0, true), "an eye at 49.6 under a 50 plane is under water")
	_check(not R.is_underwater(50.6, 50.0, true), "at 50.6 it is not")
	_check(not R.is_underwater(10.0, 50.0, false), "not over a water block, never")

	# --- The clip plane (READ, round 628 review): above keep y >= h, under
	# keep y <= h.
	var above_clip: Vector4 = R.clip_plane(50.0, false)
	var under_clip: Vector4 = R.clip_plane(50.0, true)
	var keep := func(c: Vector4, y: float) -> bool: return c.y * y + c.w >= 0.0
	_check(keep.call(above_clip, 60.0) and not keep.call(above_clip, 40.0), "above water the mirror keeps y >= h and drops the lake bed")
	_check(keep.call(under_clip, 40.0) and not keep.call(under_clip, 60.0), "under water it keeps y <= h")
	var code: String = R.terrain_clip_code(true, false)
	_check(code.contains("global uniform vec4 water_clip_plane") and code.contains("discard") and code.contains("unshaded"),
		"the mirror terrain's shader clips against the global plane")
	_check(R.terrain_clip_code(false, true).contains("blend_mix") and R.terrain_clip_code(false, true).contains("ALPHA"),
		"a blended terrain pass keeps its blending")

	# --- What the mirror draws: sky, terrain (its clipped copy), scenery.
	var tree := Node3D.new()
	var mi := MeshInstance3D.new()
	tree.add_child(mi)
	R.mark_reflected(tree)
	_check(mi.layers & R.REFLECTED_BIT != 0 and mi.layers & 1 != 0, "scenery marked for the mirror stays on the main layer too")
	tree.free()
	var mirror_mask: int = R.MIRROR_TERRAIN_BIT | R.REFLECTED_BIT
	_check(mirror_mask & 1 == 0 and mirror_mask & R.WATER_LAYER_BIT == 0,
		"the mirror leaves out layer 1 (characters, effects, the unclipped terrain) and the water")

	# --- The cloud layer's mesh (READ, FUN_00a3de90).
	var W3D: GDScript = load("res://scripts/World3D.gd")
	var cm: ArrayMesh = W3D.cloud_layer_mesh()
	var cv: PackedVector3Array = cm.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var cuv: PackedVector2Array = cm.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
	_check(cv.size() == 25 and cv[0].is_equal_approx(Vector3(-4000000, 20000, -4000000)) and cv[24].is_equal_approx(Vector3(4000000, 20000, 4000000)),
		"the cloud layer is a flat 5x5 grid 20000 above the eye, +-4,000,000 wide")
	_check(cuv[0].is_equal_approx(Vector2(-32, -32)) and cuv[24].is_equal_approx(Vector2(32, 32)), "its UVs run -32..32")

	# --- The shader compiles, and a material carries the reflection.
	var node: Node = R.new()
	root.add_child(node)
	await process_frame
	var tex2 := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	var mat: ShaderMaterial = node.make_material(false, tex2, tex2, Color(0.5, 0.6, 0.7))
	_check(mat.shader != null and mat.get_shader_parameter("reflection_tex") != null, "a water material samples the reflection target")
	_check(mat.shader.code.contains("SCREEN_UV"), "and samples it by screen position")
	node.set_water_color(Color(2, 0.5, -1))
	var wc: Vector3 = mat.get_shader_parameter("water_color")
	_check(wc.is_equal_approx(Vector3(1, 0.5, 0)), "WaterColor is clamped into the material (got %s)" % wc)

	# --- Integration review: the mirror terrain's materials are not cached
	# (a cache keyed by per-region materials held every region's textures).
	var std := StandardMaterial3D.new()
	std.albedo_texture = tex2
	var c1: Material = node.clip_material(std)
	var c2: Material = node.clip_material(std)
	_check(c1 != c2 and c1 is ShaderMaterial and not ("_clip_cache" in node),
		"each mirror terrain gets its own clip material; nothing holds it past its node")
	var wr: WeakRef = weakref(c1)
	c1 = null
	c2 = null
	_check(wr.get_ref() == null, "a clip material is freed once its user lets it go (no cache keeps it)")
	var fallback := StandardMaterial3D.new()
	fallback.ao_enabled = true
	fallback.ao_texture = tex2
	fallback.ao_light_affect = 1.0
	var cf: ShaderMaterial = node.clip_material(fallback)
	_check(bool(cf.get_shader_parameter("use_ao")) and cf.get_shader_parameter("ao_tex") == tex2
			and cf.shader.code.contains("AO_LIGHT_AFFECT = ao_light_affect"),
		"the untextured fallback's AO lightmap reaches the mirror copy")
	_check(not R.terrain_clip_code(true, false).contains("AO ="),
		"(negative) an unshaded copy evaluates no AO, as StandardMaterial3D does not")
	_check(R.terrain_clip_code(false, false).contains("mix(c.rgb, c.rgb * d.rgb, d.a)"),
		"the MUL detail layer is blended by the detail texel's alpha, as BaseMaterial3D does")
	node.queue_free()
	await process_frame
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
