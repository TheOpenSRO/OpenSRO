extends SceneTree

## The player block's portrait (round 635), from synthetic skeletons, meshes,
## materials and a synthetic layout (never real game data):
##   godot4 --headless --path client --script res://scripts/ui/hud/player_portrait_test.gd
##
## What is checked is what FUN_007b7740 and CIFStaticWithPictureClip do
## (READ; player_portrait.gd has the addresses): a 128x128 buffer, ANI_POSE,
## a camera 6.5 from the head + 1.0 at a 0.2 rad yaw with a 30 degree field of
## view, the avatar turned 0.1 rad, the frontal 0.7 / 0.3 light through the
## object shader's MODULATE2X, one render per dress, and the render shown in
## GDR_PMI_PICTURE through the mask's alpha.
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
	# A blended mod pass: left as it is.
	var glow := MeshInstance3D.new()
	glow.name = "glow"
	glow.mesh = box
	var glow_mat := ShaderMaterial.new()
	var gsh := Shader.new()
	gsh.code = "shader_type spatial;\nrender_mode cull_back, blend_add, depth_draw_never;\nvoid fragment() { ALBEDO = vec3(1.0); }\n"
	glow_mat.shader = gsh
	glow.material_override = glow_mat
	sk.add_child(glow)
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
	var script = load(PORTRAIT_PATH) if ResourceLoader.exists(PORTRAIT_PATH) else null
	_check(script != null, "player_portrait.gd exists")
	if script != null:
		_constants(script)
		_camera_math(script)
		_shading(script)
		await _render_setup(script)
	await _hud_integration()
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
	_check(_near(float(c.get("LIGHT_DIFFUSE", 0.0)), 0.7) and _near(float(c.get("LIGHT_AMBIENT", 0.0)), 0.3),
		"light diffuse 0.7 / ambient 0.3 (0x00d82f04 / 0x00d82f00)")
	_check(c.get("LIGHT_DIRECTION", Vector3.ZERO) == Vector3(0, 0, 1), "light direction (0, 0, 1)")
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
	_check(script.to_light_godot() == Vector3(0, 0, 1), "to-light = -direction, mirrored: (0,0,1)")

func _shading(script) -> void:
	# Face square to the light: 2 x 0.5 x 0.588 x (0.3 + 0.7).
	_check(_near(script.shade(0.5, 0.588, 1.0), 0.588), "lit texel 0.5 -> 0.588")
	# Facing away: ambient only, 2 x 0.5 x 0.588 x 0.3.
	_check(_near(script.shade(0.5, 0.588, -1.0), 0.1764), "unlit texel 0.5 -> 0.1764")
	_check(_near(script.shade(1.0, 0.588, 1.0), 1.0), "a white texel clamps at 1.0")
	# Brighter than the texture itself where it faces the light (the fix for
	# the dark circle): 1.176 x texel.
	_check(script.shade(0.4, 0.588, 1.0) > 0.4, "the lit face is brighter than its texture")

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
		_check((bm.get_shader_parameter("material_color") as Color).is_equal_approx(Color(0.588, 0.588, 0.588, 1)), "body colour = layer ambient 0.588")
		_check(bm.get_shader_parameter("tex") != null and bool(bm.get_shader_parameter("has_texture")), "body keeps its texture")
	var hm := (sk.get_node("hair") as MeshInstance3D).material_override as ShaderMaterial
	_check(hm != null and hm.shader.code.contains("cull_disabled"), "hair stays two-sided")
	var im := (sk.get_node("item") as MeshInstance3D).material_override as ShaderMaterial
	_check(im != null and (im.get_shader_parameter("material_color") as Color).is_equal_approx(Color(0.6, 0.5, 0.4, 1)),
		"a StandardMaterial3D item keeps its colour")
	var gm := (sk.get_node("glow") as MeshInstance3D).material_override
	_check(gm is ShaderMaterial and (gm as ShaderMaterial).shader.code.contains("blend_add"), "a blended mod pass is left as it is")
	_check(int(p.unmapped_materials) == 1, "one material left unmapped (the blend)")
	# A second dress replaces the first body and renders once more.
	var sk2 := _skeleton()
	p.set_character(sk2, null)
	await process_frame
	_check(not is_instance_valid(sk) or sk.is_queued_for_deletion() or sk.get_parent() == null, "the old body is dropped")
	_check(int(p.renders_requested) == 2, "a second dress renders again")
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
	pmi.call("set_portrait", _skeleton(), _pose())
	await process_frame
	var p = pmi.call("portrait")
	_check(view.visible and p != null and view.texture == p.get_texture(), "the dress shows the render in the circle")
	view.size = pic.size
	_check(view.get_rect().size == Vector2(48, 48), "scaled into the 48x48 picture rect: %s" % str(view.get_rect().size))
	pmi.queue_free()
