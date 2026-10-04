extends SceneTree

## The player block's portrait (round 635), from synthetic skeletons, meshes,
## materials and a synthetic layout (never real game data):
##   godot4 --headless --path client --script res://scripts/ui/hud/player_portrait_test.gd
##
## What is checked is what FUN_007b7740 and CIFStaticWithPictureClip do
## (READ; player_portrait.gd has the addresses): a 128x128 buffer, ANI_POSE,
## a camera 6.5 from the head + 1.0 at a 0.2 rad yaw with a 30 degree field of
## view, the avatar turned 0.1 rad, the ZONE's light (round 635's review
## follow-up: to-light (0.707, 0.707, 0), diffuse = channel 2 clamped x 0.6,
## ambient = channel 3 x the object's own 0.6) through the object shader's
## MODULATE2X, one render per dress and per zone-light change, every body
## material mapped (blended and MTRL mod passes included), and the render
## shown in GDR_PMI_PICTURE through the mask's alpha under the block's
## modulate.
##
## The script is loaded by path and driven untyped so that the same file runs
## against a tree without the portrait and reports FAIL lines there rather
## than a parse error.

const PORTRAIT_PATH := "res://scripts/ui/hud/player_portrait.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps

func _near3(a: Vector3, b: Vector3, eps: float = 1e-3) -> bool:
	return a.distance_to(b) <= eps

## A two-bone skeleton: a root at the origin and `Bip01 Head` at (0.3, 16, 0.5).
func _skeleton() -> Skeleton3D:
	var sk := Skeleton3D.new()
	sk.name = "Body"
	sk.add_bone("Bip01")
	sk.add_bone("Bip01 Head")
	sk.set_bone_parent(1, 0)
	sk.set_bone_rest(0, Transform3D.IDENTITY)
	sk.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(0.3, 16.0, 0.5)))
	sk.reset_bone_poses()
	var box := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 15, 0), Vector3(1, 16, 0), Vector3(0, 17, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3(0, 0, -1), Vector3(0, 0, -1), Vector3(0, 0, -1)])
	box.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# A body layer as ObjectLoader builds it for flags 0x340 (alpha-tested):
	# the foliage shader with the layer's ambient and its texture.
	var body := MeshInstance3D.new()
	body.name = "body"
	body.mesh = box
	var foliage := ShaderMaterial.new()
	var fsh := Shader.new()
	fsh.code = "shader_type spatial;\nrender_mode cull_back;\nuniform vec4 albedo : source_color = vec4(1.0);\nuniform sampler2D albedo_texture : source_color;\nuniform float alpha_scissor = 0.5;\nvoid fragment() { ALBEDO = albedo.rgb; ALPHA = 1.0; }\n"
	foliage.shader = fsh
	foliage.set_shader_parameter("albedo", Color(0.588, 0.588, 0.588, 1.0))
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.5, 0.5, 1.0))
	foliage.set_shader_parameter("albedo_texture", ImageTexture.create_from_image(img))
	foliage.set_shader_parameter("alpha_scissor", 128.0 / 255.0)
	body.material_override = foliage
	sk.add_child(body)
	# A hair layer (flags 0x341): the two-sided foliage variant.
	var hair := MeshInstance3D.new()
	hair.name = "hair"
	hair.mesh = box
	var hair_mat := ShaderMaterial.new()
	var hsh := Shader.new()
	hsh.code = fsh.code.replace("cull_back", "cull_disabled")
	hair_mat.shader = hsh
	hair_mat.set_shader_parameter("albedo", Color(0.588, 0.588, 0.588, 1.0))
	hair_mat.set_shader_parameter("alpha_scissor", 128.0 / 255.0)
	hair.material_override = hair_mat
	sk.add_child(hair)
	# A plain StandardMaterial3D surface (an item layer without a test).
	var item := MeshInstance3D.new()
	item.name = "item"
	item.mesh = box
	var sm := StandardMaterial3D.new()
	sm.albedo_color = Color(0.6, 0.5, 0.4, 1.0)
	item.material_override = sm
	sk.add_child(item)
	# A blended layer (StandardMaterial3D, alpha blend): mapped, blending.
	var glow := MeshInstance3D.new()
	glow.name = "glow"
	glow.mesh = box
	var glow_mat := StandardMaterial3D.new()
	glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow_mat.albedo_color = Color(1, 1, 1, 0.5)
	glow.material_override = glow_mat
	sk.add_child(glow)
	# An MTRL mod pass as ObjectLoader builds it (additive, its own ops).
	var mod := MeshInstance3D.new()
	mod.name = "mod"
	mod.mesh = box
	var mod_mat := ShaderMaterial.new()
	mod_mat.shader = ObjectLoader._mod_shader("back", "add", false)
	mod_mat.set_shader_parameter("albedo", Color(0.588, 0.588, 0.588, 1.0))
	mod_mat.set_shader_parameter("alpha_func", 5)
	mod_mat.set_shader_parameter("alpha_scissor", 0.25)
	mod_mat.set_shader_parameter("color_op", 4)
	mod.material_override = mod_mat
	sk.add_child(mod)
	return sk

## A one-key clip that lifts the head to (0, 20, 0) relative to its parent.
func _pose() -> BanReader.ParsedAnimation:
	var a := BanReader.ParsedAnimation.new()
	a.animation_name = "synthetic_pose"
	a.duration_ms = 1000
	a.key_times = PackedInt32Array([0])
	var head := BanReader.Bone.new()
	head.bone_name = "Bip01 Head"
	var kf := BanReader.Keyframe.new()
	kf.rotation = Quaternion.IDENTITY
	kf.position = Vector3(0.0, 20.0, 0.0)
	head.keyframes.append(kf)
	a.bones.append(head)
	return a

func _init() -> void:
	await process_frame
	var bloom_was := ObjectLight.current_bloom
	var script = load(PORTRAIT_PATH) if ResourceLoader.exists(PORTRAIT_PATH) else null
	_check(script != null, "player_portrait.gd exists")
	if script != null:
		_constants(script)
		_camera_math(script)
		_shading(script)
		await _render_setup(script)
	await _hud_integration()
	# The static the bloom checks set (round 706 review): put back.
	ObjectLight.current_bloom = bloom_was
	print("player_portrait_test: %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)

func _constants(script) -> void:
	var c: Dictionary = script.get_script_constant_map()
	_check(int(c.get("BUFFER_SIZE", 0)) == 128, "buffer 128x128 (BufRender::FUN_009edae0(0x80, 0x80))")
	_check(int(c.get("ANI_POSE", -1)) == 0x3c and int(SkillEffectReader.ANI_TYPES["ANI_POSE"]) == 0x3c,
		"the pose is animation 0x3c = ANI_POSE")
	_check(String(c.get("HEAD_BONE", "")) == "Bip01 Head", "camera anchored on Bip01 Head")
	_check(_near(float(c.get("TARGET_LIFT", 0.0)), 1.0), "target lifted 1.0 (0x00e1b7f0)")
	_check(_near(float(c.get("CAMERA_YAW", 0.0)), 0.2) and _near(float(c.get("CAMERA_PITCH", 1.0)), 0.0),
		"camera yaw 0.2, pitch 0 (0x00da95f8)")
	_check(_near(float(c.get("CAMERA_DISTANCE", 0.0)), 6.5), "camera distance 6.5 (0x00da95f4)")
	_check(_near(float(c.get("CAMERA_FOV_DEG", 0.0)), 30.0), "vertical field of view 30 degrees (0x00d82ef0)")
	_check(_near(float(c.get("MODEL_YAW", 0.0)), 0.1), "avatar yaw 0.1 (0x00e1b7fc)")
	var dir: Vector3 = c.get("WORLD_LIGHT_DIRECTION", Vector3.ZERO)
	_check(_near3(dir, Vector3(-1, -1, 0).normalized()), "the zone light's direction normalize(-1,-1,0) (DAT_01109510): %s" % str(dir))
	_check(_near(float(c.get("DIFFUSE_SCALE", 0.0)), 0.6), "diffuse = channel 2 x 0.6 (0x00d86fc0)")
	_check(_near(float(c.get("OBJECT_COLOR", 0.0)), 0.6), "the object's own colour 0.6 (CCompoundObj constructor)")
	_check(not c.has("LIGHT_DIRECTION") and not c.has("LIGHT_DIFFUSE"), "the portrait's own device light (dead state) is not used")
	_check(c.get("CLEAR_COLOR", Color(1, 1, 1, 1)) == Color(0, 0, 0, 1), "clear to opaque black (0xff000000)")
	_check(_near(float(c.get("MODULATE_SCALE", 0.0)), 2.0), "the object draw's MODULATE2X")

func _camera_math(script) -> void:
	var target := Vector3(0.3, 17.0, 0.5)
	var eye: Vector3 = script.camera_eye(target)
	# (0, 0, 6.5) * RotY(0.2) = (6.5 sin 0.2, 0, 6.5 cos 0.2); eye = target - that.
	_check(_near3(eye, target - Vector3(6.5 * sin(0.2), 0.0, 6.5 * cos(0.2))),
		"eye = target - (0,0,6.5)*RotY(0.2): %s" % str(eye))
	_check(_near(eye.distance_to(target), 6.5), "eye 6.5 from the target")
	_check(_near(eye.y, target.y), "the look is level (pitch 0)")
	# The camera looks toward +z in the file's coordinates: the body's front
	# (-z) faces it.
	_check((target - eye).z > 0.0, "the camera looks along +z, at the body's front")
	# The avatar's yaw: the setter's [[c,0,s],[0,1,0],[-s,0,c]] sends (1,0,0)
	# to (cos 0.1, 0, sin 0.1); Godot's rotation.y does the same.
	var ry: float = script.model_rotation_y()
	var x := Basis(Vector3.UP, ry) * Vector3(1, 0, 0)
	_check(_near3(x, Vector3(cos(0.1), 0.0, sin(0.1))), "avatar yaw maps (1,0,0) to (cos .1, 0, sin .1): %s" % str(x))
	_check(script.to_godot(Vector3(1, 2, 3)) == Vector3(1, 2, -3), "file space mirrored z -> -z")
	_check(_near3(script.to_light_godot(), Vector3(0.70710678, 0.70710678, 0.0)), "to-light = -direction (vslot_025), mirrored: (0.707, 0.707, 0)")
	# The face (normal -z in the file's coordinates) is square to the camera
	# and edge-on to that light: n.l = 0, ambient only.
	_check(_near(Vector3(0, 0, -1).dot(-Vector3(-1, -1, 0).normalized()), 0.0), "the face front gets no diffuse")

func _shading(script) -> void:
	if not script.get_script_constant_map().has("OBJECT_COLOR"):
		_check(false, "shade() takes the zone light and the object colour")
		return
	# Jangan-like channels: diffuse 0.7 -> 0.42, ambient 0.58 -- with the
	# Bloom row off (x 0.6); on, x 0.8 (round 706, ObjectLight).
	ObjectLight.current_bloom = true
	var zb: Dictionary = script.zone_light_colors(Color(0.7, 0.6, 1.3), Color(0.58, 0.58, 0.58))
	_check(_near3(zb["diffuse"], Vector3(0.56, 0.48, 0.8)), "with the bloom target: clamp(channel 2) x 0.8: %s" % str(zb["diffuse"]))
	ObjectLight.current_bloom = false
	var z: Dictionary = script.zone_light_colors(Color(0.7, 0.6, 1.3), Color(0.58, 0.58, 0.58))
	_check(_near3(z["diffuse"], Vector3(0.42, 0.36, 0.6)), "diffuse = clamp(channel 2) x 0.6: %s" % str(z["diffuse"]))
	_check(_near3(z["ambient"], Vector3(0.58, 0.58, 0.58)), "ambient = channel 3")
	# Both world fields are clamped to [0, 1] (FUN_00a1baf0, 0x00a1cc50..): an
	# ambient channel above 1 or below 0 lights as 1 or 0.
	var zc: Dictionary = script.zone_light_colors(Color(0.7, 0.6, 1.3), Color(1.3, -0.2, 0.5))
	_check(_near3(zc["ambient"], Vector3(1.0, 0.0, 0.5)), "ambient = clamp(channel 3): %s" % str(zc["ambient"]))
	# Face front: 2 x 0.5 x (0.6 x 0.58).
	_check(_near(script.shade(0.5, 0.588, 0.6, 0.58, 0.42, 0.0), 0.348), "face texel 0.5 -> 0.348 (ambient only)")
	# Square to the light: + 0.588 x 0.42.
	_check(_near(script.shade(0.5, 0.588, 0.6, 0.58, 0.42, 1.0), 0.59496), "lit texel 0.5 -> 0.595")
	_check(_near(script.shade(1.0, 0.588, 0.6, 1.0, 1.0, 1.0), 1.0), "a white texel clamps at 1.0")
	# The old frontal 0.7 / 0.3 device light would have given 0.588 on the face.
	_check(not _near(script.shade(0.5, 0.588, 0.6, 0.58, 0.42, 0.0), 0.588), "not the dead device light's 0.588")

func _render_setup(script) -> void:
	var p = script.new()
	root.add_child(p)
	_check(p.size == Vector2i(128, 128), "SubViewport 128x128")
	_check(p.render_target_update_mode == SubViewport.UPDATE_DISABLED, "nothing renders before a dress")
	var sk := _skeleton()
	p.set_character(sk, _pose())
	_check(p.render_target_update_mode == SubViewport.UPDATE_ONCE, "a dress renders once")
	_check(int(p.renders_requested) == 1, "one render per dress")
	var mirror := sk.get_parent() as Node3D
	_check(mirror != null and mirror.scale == Vector3(1, 1, -1), "body under the z -> -z node")
	_check(_near(sk.rotation.y, -0.1), "body turned by the avatar yaw")
	# The pose moved the head to (0, 20, 0) under its root.
	var head: Vector3 = script.head_position(sk)
	_check(_near3(head, Vector3(0, 20, 0)), "the pose is applied before the head is read: %s" % str(head))
	var cam := p.camera() as Camera3D
	var target := Vector3(0, 21, 0)
	var eye: Vector3 = script.camera_eye(target)
	_check(_near3(cam.transform.origin, script.to_godot(eye)), "camera at the eye: %s" % str(cam.transform.origin))
	var fwd := -cam.transform.basis.z
	var want: Vector3 = (script.to_godot(target) - script.to_godot(eye)).normalized()
	_check(_near3(fwd, want), "camera looks at head + 1.0")
	_check(_near(cam.fov, 30.0) and cam.keep_aspect == Camera3D.KEEP_HEIGHT, "30 degree vertical fov")
	var body := sk.get_node("body") as MeshInstance3D
	var bm := body.material_override as ShaderMaterial
	_check(bm != null and bm.shader != null and bm.shader.code.contains("unshaded") and bm.shader.code.contains("cull_back"),
		"body re-materialed: portrait shader, back-face cull")
	if bm != null:
		_check(_near(float(bm.get_shader_parameter("alpha_ref")), 128.0 / 255.0), "body keeps its alpha test (0x80)")
		_check(_near(float(bm.get_shader_parameter("modulate_scale")), 2.0), "body drawn MODULATE2X")
		_check((bm.get_shader_parameter("material_color") as Color).is_equal_approx(Color(0.588, 0.588, 0.588, 1)), "body colour = the material's colour 0.588")
		_check(bm.get_shader_parameter("tex") != null and bool(bm.get_shader_parameter("has_texture")), "body keeps its texture")
	var hm := (sk.get_node("hair") as MeshInstance3D).material_override as ShaderMaterial
	_check(hm != null and hm.shader.code.contains("cull_disabled"), "hair stays two-sided")
	var im := (sk.get_node("item") as MeshInstance3D).material_override as ShaderMaterial
	_check(im != null and (im.get_shader_parameter("material_color") as Color).is_equal_approx(Color(0.6, 0.5, 0.4, 1)),
		"a StandardMaterial3D item keeps its colour")
	var gm := (sk.get_node("glow") as MeshInstance3D).material_override as ShaderMaterial
	_check(gm != null and gm.shader.code.contains("blend_mix") and gm.shader.code.contains("ALPHA = t.a"), "a blended layer is mapped and still blends")
	var mm := (sk.get_node("mod") as MeshInstance3D).material_override as ShaderMaterial
	_check(mm != null and mm.shader.code.contains("portrait_light_diffuse") and mm.shader.code.contains("unshaded") and mm.shader.code.contains("blend_add"),
		"an MTRL mod keeps its shader, blend and ops, lit by the portrait's vertex colour")
	if mm != null:
		_check(int(mm.get_shader_parameter("alpha_func")) == 5 and _near(float(mm.get_shader_parameter("alpha_scissor")), 0.25) and int(mm.get_shader_parameter("color_op")) == 4,
			"the mod's alpha func, ref and stage ops are carried over")
	_check(int(p.unmapped_materials) == 0, "no material left unmapped (%d)" % int(p.unmapped_materials))
	if bm != null and p.has_method("set_zone_light"):
		var before := int(p.renders_requested)
		p.set_zone_light(Color(0.7, 0.7, 0.7), Color(0.58, 0.58, 0.58))
		_check(int(p.renders_requested) == before + 1, "a new zone light re-renders the dressed portrait")
		_check(_near3(bm.get_shader_parameter("light_ambient"), Vector3(0.58, 0.58, 0.58)) and _near3(bm.get_shader_parameter("light_diffuse"), Vector3(0.42, 0.42, 0.42)),
			"the materials take the zone light")
		_check(_near3(bm.get_shader_parameter("to_light"), Vector3(0.70710678, 0.70710678, 0.0)) and _near3(bm.get_shader_parameter("object_color"), Vector3(0.6, 0.6, 0.6)),
			"light from above and +x; object colour 0.6")
		p.set_zone_light(Color(0.7, 0.7, 0.7), Color(0.58, 0.58, 0.58))
		_check(int(p.renders_requested) == before + 1, "the same light does not render again")
		if mm != null:
			_check(_near3(mm.get_shader_parameter("portrait_light_ambient"), Vector3(0.58, 0.58, 0.58)), "the mod pass takes the zone light too")
	else:
		_check(false, "PlayerPortrait.set_zone_light exists")
	# A second dress replaces the first body and renders once more.
	var sk2 := _skeleton()
	p.set_character(sk2, null)
	await process_frame
	_check(not is_instance_valid(sk) or sk.is_queued_for_deletion() or sk.get_parent() == null, "the old body is dropped")
	_check(int(p.renders_requested) >= 2, "a second dress renders again")
	p.queue_free()

## The block shows the render in GDR_PMI_PICTURE through the mask.
func _hud_integration() -> void:
	var builder := UiBuilder.new(null, null)
	var cache: Dictionary = builder.get("_layout_cache")
	var layout := "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" \
		+ "\tGDR_PMI_PICTURE:CIFStaticWithPictureClip\n\t{\n\t\tDDJ=STRING,\"\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tRect=RECT,\"15,7,48,48\"\n\t\tText=STRING,\"\"\n\t}\n" \
		+ "}\n"
	cache["resinfo\\ifplayerminiinfo.txt"] = UiLayoutParser.parse(layout)
	var pmi := HudPlayerInfo.new(builder)
	root.add_child(pmi)
	pmi.setup()
	var pic := pmi.find_child("GDR_PMI_PICTURE", true, false) as Control
	_check(pic != null, "the picture control is built")
	var view: TextureRect = null
	if pic != null:
		view = pic.find_child("PortraitView", true, false) as TextureRect
	_check(view != null, "GDR_PMI_PICTURE carries the portrait view")
	_check(pmi.has_method("set_portrait"), "HudPlayerInfo.set_portrait exists")
	if view == null or not pmi.has_method("set_portrait"):
		pmi.queue_free()
		return
	_check(not view.visible, "no portrait drawn before the first dress")
	var mat := view.material as ShaderMaterial
	_check(mat != null and mat.shader.code.contains("texture(mask_tex, UV).a"), "alpha comes from the mask (stage 1 SELECTARG1(TEXTURE))")
	_check(mat != null and mat.shader.code.contains("texture(TEXTURE, UV).rgb"), "colour comes from the render (stage 0)")
	_check(mat != null and mat.shader.code.contains("modulate = COLOR;") and mat.shader.code.contains("* modulate;"),
		"the picture follows the block's modulate (read in vertex(), not the texture-multiplied fragment COLOR)")
	_check(pmi.has_method("set_portrait_zone_light"), "HudPlayerInfo.set_portrait_zone_light exists")
	pmi.call("set_portrait", _skeleton(), _pose())
	await process_frame
	var p = pmi.call("portrait")
	_check(view.visible and p != null and view.texture == p.get_texture(), "the dress shows the render in the circle")
	view.size = pic.size
	_check(view.get_rect().size == Vector2(48, 48), "scaled into the 48x48 picture rect: %s" % str(view.get_rect().size))
	pmi.queue_free()
