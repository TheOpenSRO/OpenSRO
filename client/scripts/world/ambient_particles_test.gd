extends SceneTree

## Round 720: the particle mod reader, the ambient set, the entry rotation,
## the glow's alpha steps and test point, and the glow shader. Synthetic
## bytes only -- no game data. Run headless:
## `godot4 --headless --path client --script res://scripts/world/ambient_particles_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: Vector3, b: Vector3, eps: float = 1e-4) -> bool:
	return a.distance_to(b) <= eps

func _u32(b: PackedByteArray, v: int) -> void:
	var at := b.size()
	b.resize(at + 4)
	b.encode_u32(at, v)

func _f32(b: PackedByteArray, v: float) -> void:
	var at := b.size()
	b.resize(at + 4)
	b.encode_float(at, v)

func _str(b: PackedByteArray, s: String) -> void:
	_u32(b, s.length())
	b.append_array(s.to_ascii_buffer())

## A particle mod's header and body as ModDataParticle::vslot_004 reads them.
func _particle_mod(entries: Array) -> PackedByteArray:
	var b := PackedByteArray()
	_u32(b, 0)      # header word 0 (+0x08)
	_u32(b, 1)      # word 1 (+0x0c), the dispatch
	for _i in range(4):
		_u32(b, 0)
	_u32(b, 0)      # the four header bytes
	_u32(b, entries.size())
	for e in entries:
		_u32(b, e["mode"])
		_str(b, e["efp"])
		_str(b, e["bone"])
		_f32(b, e["offset"].x)
		_f32(b, e["offset"].y)
		_f32(b, e["offset"].z)
		_u32(b, 7)  # +0x4c
		b.append(e["b50"])
		b.append(0)
		b.append(0)
		b.append(1 if e.has("rot") else 0)
		if e.has("rot"):
			_f32(b, e["rot"].x)
			_f32(b, e["rot"].y)
			_f32(b, e["rot"].z)
	return b

func _init() -> void:
	_test_reader()
	_test_ambient_set()
	_test_rotation()
	_test_alpha()
	_test_query_point()
	_test_glow_shader()
	_test_light_effect()
	_test_night_and_bones()
	_test_display_shader()
	# The camera tests need the tree: after the first frame.
	process_frame.connect(_in_tree, CONNECT_ONE_SHOT)

func _in_tree() -> void:
	_test_point_on_screen()
	_test_hidden_glow_still_queued()
	_texel_setup()
	# The bodies take a physics step before a ray meets them.
	_texel_wait = 4
	physics_frame.connect(_texel_tick)

var _texel_wait := 0
func _texel_tick() -> void:
	_texel_wait -= 1
	if _texel_wait == 0:
		physics_frame.disconnect(_texel_tick)
		_texel_checks()

## Round 722: a 2 x 2 quad at z 0 whose texture is cut on its left half
## (alpha 0) and kept on its right (alpha 255), alpha-tested at 128.
var _quads: Array = []
func _texel_quad(x0: float, with_uv: bool) -> void:
	var pos := PackedVector3Array([Vector3(x0 - 1, -1, 0), Vector3(x0 + 1, -1, 0), Vector3(x0 + 1, 1, 0), Vector3(x0 - 1, 1, 0)])
	var uv := PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	var idx := PackedInt32Array([0, 1, 2, 0, 2, 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_INDEX] = idx
	if with_uv:
		arrays[Mesh.ARRAY_TEX_UV] = uv
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.set_meta(AmbientParticles.META_ARRAYS, arrays)
	var img := Image.create(2, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Color(1, 1, 1, 0))
	img.set_pixel(1, 0, Color(1, 1, 1, 1))
	var tex := ImageTexture.create_from_image(img)
	tex.set_meta(AmbientParticles.META_IMAGE, img)
	var mat := ShaderMaterial.new()
	mat.shader = ObjectLoader.object_shader("one")
	mat.set_shader_parameter("albedo_texture", tex)
	mat.set_shader_parameter("alpha_scissor", 128.0 / 255.0)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var faces := PackedVector3Array()
	for i in idx:
		faces.append(pos[i])
	var concave := ConcavePolygonShape3D.new()
	concave.set_faces(faces)
	concave.backface_collision = true
	shape.shape = concave
	body.add_child(shape)
	mi.add_child(body)
	root.add_child(mi)
	_quads.append(mi)

func _texel_setup() -> void:
	_texel_quad(0.0, true)
	_texel_quad(10.0, false)

func _texel_hit(x: float) -> Dictionary:
	var space := root.get_world_3d().direct_space_state
	return space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(x, 0.2, 5), Vector3(x, 0.2, -5)))

func _texel_checks() -> void:
	var cut := _texel_hit(-0.5)
	var kept := _texel_hit(0.5)
	var bare := _texel_hit(10.5)
	_check(not cut.is_empty() and AmbientParticles.texel_kept(cut) == 0, "texel_kept: the cut half reads 0 (got %s)" % str(AmbientParticles.texel_kept(cut) if not cut.is_empty() else "no hit"))
	_check(not kept.is_empty() and AmbientParticles.texel_kept(kept) == 1, "texel_kept: the kept half reads 1")
	_check(not bare.is_empty() and AmbientParticles.texel_kept(bare) == -1, "texel_kept: a mesh without UVs is unreadable (-1)")
	print("ambient_particles_test: %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)

func _test_reader() -> void:
	var body := _particle_mod([
		{"mode": 1, "efp": "map\\a.efp", "bone": "", "offset": Vector3(1, 2, 3), "b50": 25},
		{"mode": 0, "efp": "map\\b.efp", "bone": "Bone02", "offset": Vector3.ZERO, "b50": 0,
			"rot": Vector3(0, PI / 2, 0)},
	])
	# The skip and the read agree on the body's length.
	var cursor := [0]
	_check(BsrReader._skip_mod_body(body, cursor, BsrReader.MOD_PARTICLE) and cursor[0] == body.size(),
		"the particle body's skip ends where the body does (%d of %d)" % [cursor[0], body.size()])
	var pm := BsrReader._read_particle_mod(body, 0, 0, -1, "ambient")
	_check(pm != null and pm.entries.size() == 2, "two entries read")
	if pm == null or pm.entries.size() != 2:
		return
	var a: BsrReader.ParticleEntry = pm.entries[0]
	var b: BsrReader.ParticleEntry = pm.entries[1]
	_check(pm.set_name == "ambient" and pm.set_kind == BsrReader.SET_BY_CLIP and pm.w1 == 1, "the set and header word 1")
	_check(a.mode == 1 and a.efp == "map\\a.efp" and _near(a.offset, Vector3(1, 2, 3)) and a.b50 == 25 and a.w4c == 7
		and not a.rotated, "entry 0: mode, effect, offset, the glow byte, +0x4c")
	_check(b.mode == 0 and b.bone == "Bone02" and b.rotated and _near(b.angles, Vector3(0, PI / 2, 0)),
		"entry 1: a bone and a rotation")

func _test_ambient_set() -> void:
	var amb := BsrReader.ParticleMod.new()
	amb.set_name = "ambient"
	amb.entries.append(BsrReader.ParticleEntry.new())
	var other := BsrReader.ParticleMod.new()
	other.set_name = "status_bad_burn"
	other.entries.append(BsrReader.ParticleEntry.new())
	var typed := BsrReader.ParticleMod.new()
	typed.set_kind = BsrReader.SET_BY_TYPE
	typed.set_name = "ambient"
	typed.entries.append(BsrReader.ParticleEntry.new())
	var cap := BsrReader.ParticleMod.new()
	cap.set_name = "Ambient"
	cap.entries.append(BsrReader.ParticleEntry.new())
	var two := BsrReader.ParticleMod.new()
	two.set_name = "ambient2"
	two.entries.append(BsrReader.ParticleEntry.new())
	var got := AmbientParticles.ambient_entries([other, amb, typed, cap, two])
	_check(got.size() == 1 and (got[0] as Array).size() == 1,
		"only the clip set named exactly 'ambient' (case-sensitive, FUN_004722d0) is kept, one Array per mod")

func _test_rotation() -> void:
	# A y-only entry turns like Godot's Basis(UP, y).
	var b := AmbientParticles.rotation_basis(Vector3(0, PI / 2, 0))
	var g := Basis(Vector3.UP, PI / 2)
	_check(_near(b.x, g.x) and _near(b.y, g.y) and _near(b.z, g.z), "rotation (0, 90deg, 0) == Basis(UP, 90deg)")
	# The general form: a row vector v placed as v x M equals Basis * v.
	var ang := Vector3(0.3, -0.7, 1.1)
	var cx := cos(ang.x)
	var sx := sin(ang.x)
	var cy := cos(ang.y)
	var sy := sin(ang.y)
	var cz := cos(ang.z)
	var sz := sin(ang.z)
	var m := [[cy * cz, -sz * cy, -sy], [sz * cx - sx * sy * cz, cz * cx + sx * sy * sz, -sx * cy],
		[sz * sx + cx * sy * cz, cz * sx - cx * sy * sz, cx * cy]]
	var v := Vector3(0.2, 1.5, -0.9)
	var row := Vector3(v.x * m[0][0] + v.y * m[1][0] + v.z * m[2][0], v.x * m[0][1] + v.y * m[1][1] + v.z * m[2][1],
		v.x * m[0][2] + v.y * m[1][2] + v.z * m[2][2])
	_check(_near(AmbientParticles.rotation_basis(ang) * v, row), "Basis * v == v x M (FUN_00c67500's matrix)")

func _test_alpha() -> void:
	_check(AmbientParticles.step_alpha(0, true, 16.7, true) == 25, "visible: +trunc(16.7 x 1.5) = 25")
	_check(AmbientParticles.step_alpha(250, true, 16.7, true) == 255, "visible: capped at 255")
	_check(AmbientParticles.step_alpha(100, false, 16.7, true) == 75, "hidden: -25")
	_check(AmbientParticles.step_alpha(20, false, 16.7, true) == 0, "hidden: below 1 is 0")
	_check(AmbientParticles.step_alpha(200, false, 16.7, false) == 0, "hidden, not seen the frame before: 0")
	_check(AmbientParticles.step_alpha(200, true, 16.7, false) == 225, "visible, not seen before: still fades in")

func _test_query_point() -> void:
	var p := AmbientParticles.query_point(Vector3(0, 10, 0), Vector3(0, 10, 100), 25)
	_check(_near(p, Vector3(0, 10, 24)), "the test point moves 24 (25 - 1) toward the camera")
	_check(_near(AmbientParticles.query_point(Vector3(1, 1, 1), Vector3(1, 1, 1), 25), Vector3(1, 1, 1)),
		"camera at the point: the point itself")

## An effect with one draw node and its own material, for the glow tests.
func _fx_with_one_draw() -> Array:
	var fx := EfpEffect.new()
	var mmi := MultiMeshInstance3D.new()
	var m := EfpEffect.material_for(PlaceholderTexture2D.new(), null)
	mmi.material_override = m
	fx.add_child(mmi)
	fx._draws.append([0, mmi, "ViewNone"])
	return [fx, mmi, m]

func _test_light_effect() -> void:
	var made := _fx_with_one_draw()
	var fx: EfpEffect = made[0]
	var mmi: MultiMeshInstance3D = made[1]
	var own: ShaderMaterial = made[2]
	fx.make_glow()
	var glow := mmi.material_override as ShaderMaterial
	_check(glow != own and glow.shader.code.contains("depth_test_disabled") and not fx.visible,
		"make_glow: the glow copy, drawn only once its alpha is above 0")
	fx.set_glow_alpha(255)
	_check(fx.visible, "glow alpha 255: shown")
	var ap := AmbientParticles.new()
	var g := AmbientParticles.Glow.new()
	g.fx = fx
	ap._glows.append(g)
	ap.set_light_effect(false)
	_check(mmi.material_override == own and fx.visible,
		"Light Effect off: the effect's own (depth-tested) material back, shown at full alpha")
	ap.set_light_effect(true)
	_check(mmi.material_override == glow, "Light Effect on: the glow copy again")
	fx.set_glow_alpha(0)
	_check(not fx.visible, "glow alpha 0: not drawn")
	ap.light_effect = false
	ap.update(16.7, null, null)
	_check(g.alpha == 0 and g.seen_frame == -1, "Light Effect off: the pass steps nothing")
	fx.free()

## Round 774's regression (v0.1.523): the pass skipped every effect not
## `visible`, and a glow is hidden until it fades in, so no glow ever did --
## the Jangan gate's went dark. A hidden glow is still queued; only one its
## owner culled (EfpEffect.culled) is not.
func _test_hidden_glow_still_queued() -> void:
	var made := _fx_with_one_draw()
	var fx: EfpEffect = made[0]
	fx.make_glow()
	var host := Node3D.new()
	get_root().add_child(host)
	var ap := AmbientParticles.new()
	var g := AmbientParticles.Glow.new()
	g.fx = fx
	g.host = host
	g.box = AABB(Vector3.ZERO, Vector3.ONE)
	g.byte = 20
	host.add_child(fx)
	ap._glows.append(g)
	_check(not fx.visible, "a glow at alpha 0 is hidden")
	ap.update(16.7, null, null)
	_check(g.seen_frame == ap._frame, "...and still queued by the glow pass, so it can fade in")
	_check(fx.glow_anchor == Vector4(fx.placed_at().x, fx.placed_at().y, fx.placed_at().z, float(g.byte) - AmbientParticles.BIAS_OFFSET)
		and (fx._glow_materials[0].get_shader_parameter("glow_anchor") as Vector4) == fx.glow_anchor,
		"round 807: the pass hands the glow its occlusion point and bias, which its shader tests every frame")
	fx.culled = true
	ap.update(16.7, null, null)
	_check(g.seen_frame == ap._frame - 1, "a glow its owner culled is not queued")
	host.free()

func _test_point_on_screen() -> void:
	var cam := Camera3D.new()
	get_root().add_child(cam)
	cam.global_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)
	var at := Vector3(0, 0, -50)
	var near := AmbientParticles.query_point(at, cam.global_position, 95)
	_check(not AmbientParticles.point_on_screen(near, cam),
		"byte 95, camera 50 away: the test point is behind the eye -- hidden (a camera nearer than byte - 1)")
	var far := AmbientParticles.query_point(at, cam.global_position, 25)
	_check(AmbientParticles.point_on_screen(far, cam), "byte 25, camera 50 away: on screen")
	_check(not AmbientParticles.point_on_screen(Vector3(500, 0, -10), cam), "far to the side: off screen")
	var host := Node3D.new()
	get_root().add_child(host)
	host.visible = false
	_check(not AmbientParticles.drawn(host, AABB(at, Vector3.ONE), cam), "a hidden host is not drawn")
	host.visible = true
	_check(AmbientParticles.drawn(host, AABB(at, Vector3.ONE), cam), "a shown host in front is drawn")
	_check(not AmbientParticles.drawn(host, AABB(Vector3(0, 0, 50), Vector3.ONE), cam), "a host behind is not drawn")
	host.free()
	cam.free()

func _test_night_and_bones() -> void:
	var night := BsrReader.ParticleEntry.new()
	night.b51 = 1
	_check(AmbientParticles.night_only(night), "+0x51 bit 0: a night-only entry (round 806: built, held by day)")
	var day := BsrReader.ParticleEntry.new()
	_check(not AmbientParticles.night_only(day), "an ordinary entry is not")
	var bone := BsrReader.ParticleEntry.new()
	bone.mode = 0
	bone.bone = "Bone02"
	bone.efp = "map\\x.efp"
	var after := BsrReader.ParticleEntry.new()
	after.mode = 1
	after.efp = "map\\y.efp"
	var host := Node3D.new()
	get_root().add_child(host)
	var ap := AmbientParticles.new()
	var made := ap.attach(host, [[bone, after]], null)
	_check(made.is_empty() and ap.aborted_mods == 1,
		"mode 0 without the bone: vslot_001 returns at once -- the mod's later entries are not built")
	_check(not AmbientParticles.has_bone(host, "Bone02"), "no skeleton, no bone")
	host.free()

func _test_glow_shader() -> void:
	var m := EfpEffect.material_for(PlaceholderTexture2D.new(), null)
	var g := EfpEffect.glow_shader(m.shader)
	_check(g.code.contains("depth_test_disabled") and g.code.contains("uniform int glow_alpha"),
		"the glow shader draws without the depth test and has the alpha")
	_check(g.code.contains("if (glow_alpha < 255) d.a ="), "the alpha scales the particle colour's alpha")
	_check(EfpEffect.glow_shader(m.shader) == g, "cached per shader")
	_check(not m.shader.code.contains("glow_alpha"), "the shared shader is untouched")

## Round 722: the display-blended twin of a template shader.
func _test_display_shader() -> void:
	var add := EfpEffect._shader("add", true)
	var d := EfpEffect.display_shader(add)
	_check(d.code.contains("hint_screen_texture") and d.code.contains("srr_d + srr_s * srr_a * srr_stack")
		and d.code.contains("ALBEDO = max(srr_t - srr_bg, vec3(0.0)) / srr_stack;") and d.code.contains("ALPHA = 1.0;"),
		"an additive class adds its share of the display sum's difference over srr_stack layers, alpha 1")
	# Round 774: srr_stack per effect -- min(its additive layers, the cap).
	var made := _fx_with_one_draw()
	var one: EfpEffect = made[0]
	one.use_display_blend()
	var st = ((made[1] as MultiMeshInstance3D).material_override as ShaderMaterial).get_shader_parameter("srr_stack")
	_check(not VideoOptions.forward_plus_running() or is_equal_approx(float(st), 1.0),
		"one additive layer: srr_stack 1, the exact per-layer blend (got %s)" % str(st))
	one.free()
	_check(d.code.contains("if (!OUTPUT_IS_SRGB)") and d.code.contains("blend_add"),
		"only where the output is linear; Godot's own additive blend kept")
	var mix := EfpEffect.display_shader(EfpEffect._shader("mix", true))
	_check(mix.code.contains("mix(srr_d, srr_s, srr_a)") and mix.code.contains("/ max(srr_a, 1.0 / 255.0)"),
		"a mixing class writes the colour whose linear mix lands on the display mix")
	_check(EfpEffect.display_shader(add) == d and String(d.get_meta(EfpEffect.BLEND_CLASS_META)) == "add",
		"cached, and it keeps its class")
	var g := EfpEffect.glow_shader(d)
	_check(g.code.contains("depth_test_disabled") and g.code.contains("hint_screen_texture") and g.code.contains("glow_alpha"),
		"its glow twin keeps the screen read and adds the glow's states")
