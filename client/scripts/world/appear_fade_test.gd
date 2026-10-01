extends SceneTree

## A character fades into existence (round 676, AppearFade). Run headless on
## the render box: `client/tools/remote_godot.sh tests`.
##
## Holds the fade to what retail does (READ, CIDecoAppear: linear, alpha 0 to
## 255 over 2.0 s) and to how this client draws it: a blended twin of each of
## the model's materials while it fades, and the model's own, shared, opaque
## material back the moment it ends. Then the world: a monster's body built
## from a list and another player's body are drawn at alpha 0 the frame they
## appear, half way at 1.0 s, and with their own materials at 2.0 s.
##
## Everything is SYNTHETIC (one-triangle meshes, a 4 x 4 texture); no game data.
## AppearFade is reached through load(), not its class name, so the suite
## runs -- and prints its FAIL lines -- on a client without it.
##
## NEGATIVES: on the base (dev 4104a11), no AppearFade, and a monster's or a
## player's body is drawn opaque the frame it is built -- it pops in. On the
## round's first commit (555cfc0, its review): the alpha rounded where retail
## truncates (64/128 for 63/127), a StandardMaterial3D's twin multiplying in
## its texture's alpha, and a stale berserk copy taken as a piece's own.

const AF_PATH := "res://scripts/world/appear_fade.gd"

var _failures := 0
var AF = null

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(120.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	AF = load(AF_PATH) if ResourceLoader.exists(AF_PATH) else null
	_check(AF != null, "AppearFade exists (%s)" % AF_PATH)
	if AF != null:
		_test_curve()
		_test_model_fade()
		_test_cohorts()
		_test_taken_over()
		_test_mod_shader_twin()
		_test_unknown_shader()
		_test_other_standard()
		await _test_warm()
	var world := _make_world()
	if world != null:
		await _test_world_monster(world)
		await _test_world_player(world)
		root.remove_child(world)
		world.free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## The alpha a mesh is drawn at: its fade twin's, or 1.0 for an opaque one.
static func _drawn_alpha(mi: MeshInstance3D) -> float:
	var m := mi.material_override
	if m is ShaderMaterial:
		var a = (m as ShaderMaterial).get_shader_parameter("appear_alpha")
		return 1.0 if a == null else float(a)
	if m is BaseMaterial3D:
		var std := m as BaseMaterial3D
		return 1.0 if std.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED else std.albedo_color.a
	return 1.0

static func _near(a: float, b: float) -> bool:
	return absf(a - b) < 0.002

func _texture() -> Texture2D:
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.4, 0.3, 0.2, 1.0))
	return ImageTexture.create_from_image(image)

## One triangle with that material (an ArrayMesh: the headless renderer
## has no storage for a PrimitiveMesh).
func _box(material: Material) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3(1, 0, 0), Vector3(0, 1, 0)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2(1, 0), Vector2(0, 1)])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	return mi

## READ: CIDecoAppear::FUN_00a48a20 / vslot_009 -- 255 / 2.0 a second, set
## while the sum is <= 255.
func _test_curve() -> void:
	_check(AF.APPEAR_SECONDS == 2.0, "the fade-in takes 2.0 s (READ, float 0xd86ecc)")
	_check(AF.DISAPPEAR_SECONDS == 1.5, "the despawn fade-out is 1.5 s (READ, float 0xd819ec)")
	_check(AF.alpha_at(0.0) == 0, "alpha 0 at t = 0")
	_check(AF.alpha_at(0.5) == 63, "alpha 63 at 0.5 s (63.75 truncated: READ, rounding control chop at 0xa48b68)")
	_check(AF.alpha_at(1.0) == 127, "alpha 127 at 1.0 s, half way (127.5 truncated)")
	_check(AF.alpha_at(1.5) == 191, "alpha 191 at 1.5 s")
	_check(AF.alpha_at(2.0) == 255, "alpha 255 at 2.0 s")
	_check(AF.alpha_at(9.0) == 255, "and 255 after")
	_check(not AF.done_at(2.0) and AF.done_at(2.001), "the fade ends once the sum passes 255, just after 2.0 s")
	var linear := true
	for i in range(1, 200):
		var t := float(i) / 100.0
		if absi(AF.alpha_at(t) - int(127.5 * t)) > 0:
			linear = false
	_check(linear, "linear and truncated: int(127.5 x t) at every 10 ms")

func _test_model_fade() -> void:
	var std := StandardMaterial3D.new()
	std.albedo_texture = _texture()
	var fol := ShaderMaterial.new()
	fol.shader = ObjectLoader.FOLIAGE_SHADER
	fol.set_shader_parameter("albedo_texture", std.albedo_texture)
	fol.set_shader_parameter("alpha_scissor", 0.5)
	var model := Node3D.new()
	var a := _box(std)
	var b := _box(fol)
	model.add_child(a)
	model.add_child(b)
	var plate := Label3D.new()
	plate.text = "name"
	model.add_child(plate)
	var mark := Sprite3D.new()
	model.add_child(mark)
	root.add_child(model)
	var fades = AF.Fades.new()
	fades.start(model)
	_check(fades.running() == 1 and fades.fading(model), "the model is fading")
	var std_twin := a.material_override as ShaderMaterial
	_check(std_twin != null and std_twin.shader != null and std_twin.shader.code.contains("ALPHA = appear_alpha;")
		and std_twin.get_shader_parameter("texture_albedo") == std.albedo_texture
		and std_twin.get_shader_parameter("albedo") == std.albedo_color,
		"a plain StandardMaterial3D piece draws with the standard fade shader, its own texture and colour")
	_check(std_twin != null and std_twin.shader != null and not std_twin.shader.code.contains("albedo_tex.a"),
		"whose alpha is the fade's alone: the texture's alpha is not multiplied in (the opaque original ignores it)")
	_check(b.material_override != fol and b.material_override is ShaderMaterial
		and (b.material_override as ShaderMaterial).shader == load("res://scripts/assets/foliage_fade.gdshader"),
		"a foliage piece draws with the foliage shader's fade twin")
	_check(b.material_override is ShaderMaterial and (b.material_override as ShaderMaterial).get_shader_parameter("alpha_scissor") == 0.5
		and (b.material_override as ShaderMaterial).get_shader_parameter("albedo_texture") == std.albedo_texture,
		"the twin keeps the piece's own texture and alpha test")
	_check(_near(_drawn_alpha(a), 0.0) and _near(_drawn_alpha(b), 0.0), "both pieces are drawn at alpha 0 at t = 0")
	_check(AF.original_material(a) == std, "the piece's own material is still known while it fades")
	_check(plate.modulate == Color(1, 1, 1, 1) and mark.modulate == Color(1, 1, 1, 1), "the name plate and the party mark (Sprite3D) are not faded")
	fades.step(1.0)
	_check(_near(_drawn_alpha(a), 127.0 / 255.0) and _near(_drawn_alpha(b), 127.0 / 255.0), "half way at 1.0 s (alpha 127)")
	fades.step(0.99)
	_check(_near(_drawn_alpha(a), 253.0 / 255.0), "253 at 1.99 s (253.725 truncated)")
	fades.step(0.02)
	_check(a.material_override == std and b.material_override == fol, "at 2.01 s each piece has its own material back")
	_check(std.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED and _near(_drawn_alpha(a), 1.0), "and it is opaque")
	_check(not a.has_meta(AF.ORIGINAL_META) and not b.has_meta(AF.ORIGINAL_META), "with nothing of the fade left on the meshes")
	_check(fades.running() == 0 and fades.twin_count() == 0, "the fade is over and its twins are dropped")
	fades.step(1.0)
	_check(a.material_override == std, "a later step changes nothing")
	model.free()

## Bodies whose fades start in the same frame share their materials' twins;
## a body started a frame later has its own.
func _test_cohorts() -> void:
	var std := StandardMaterial3D.new()
	var bodies: Array[Node3D] = []
	for i in range(3):
		var body := Node3D.new()
		body.add_child(_box(std))
		root.add_child(body)
		bodies.append(body)
	var fades = AF.Fades.new()
	fades.start(bodies[0])
	fades.start(bodies[1])
	_check(fades.twin_count() == 1, "two bodies of one material started together share one twin")
	_check((bodies[0].get_child(0) as MeshInstance3D).material_override == (bodies[1].get_child(0) as MeshInstance3D).material_override,
		"and draw with the same one")
	fades.step(0.5)
	fades.start(bodies[2])
	_check(fades.twin_count() == 2, "a body started a frame later has its own")
	_check(_near(_drawn_alpha(bodies[0].get_child(0)), 63.0 / 255.0) and _near(_drawn_alpha(bodies[2].get_child(0)), 0.0),
		"each at its own alpha")
	fades.step(1.6)
	_check((bodies[0].get_child(0) as MeshInstance3D).material_override == std, "the first two are done at 2.1 s")
	_check(fades.running() == 1 and _near(_drawn_alpha(bodies[2].get_child(0)), float(AF.alpha_at(1.6)) / 255.0), "the third is still fading")
	fades.step(0.5)
	_check((bodies[2].get_child(0) as MeshInstance3D).material_override == std and fades.running() == 0, "and then it is done too")
	for b in bodies:
		b.free()

## A mesh whose material is replaced mid-fade (BerserkLook copies the
## piece's own material) keeps the replacement when the fade ends.
func _test_taken_over() -> void:
	var std := StandardMaterial3D.new()
	var body := Node3D.new()
	var mi := _box(std)
	body.add_child(mi)
	root.add_child(body)
	var fades = AF.Fades.new()
	fades.start(body)
	var taken := AF.original_material(mi).duplicate() as Material
	mi.material_override = taken
	fades.step(2.5)
	_check(mi.material_override == taken, "a material replaced mid-fade is left in place when the fade ends")
	_check(not mi.has_meta(AF.ORIGINAL_META), "and the fade's mark is gone")
	body.free()
	# A berserk player entering view: the fade takes berserk's copy B as the
	# original; berserk ends and restores the template's T; a berserk starting
	# again within the 2 s must copy T, not the stale B.
	var t_mat := StandardMaterial3D.new()
	var b_mat := t_mat.duplicate() as StandardMaterial3D
	var body2 := Node3D.new()
	var mi2 := _box(b_mat)
	body2.add_child(mi2)
	root.add_child(body2)
	var fades2 = AF.Fades.new()
	fades2.start(body2)
	_check(AF.original_material(mi2) == b_mat, "while the twin draws, the piece's own material is the one the fade took")
	mi2.material_override = t_mat
	_check(AF.original_material(mi2) == t_mat, "once something else put another material back, that one is the piece's own (not the stale copy)")
	fades2.step(2.5)
	_check(mi2.material_override == t_mat, "and the fade leaves it there")
	body2.free()

## The mod shader's fade twin (ObjectLoader._mod_shader, fade): the world's
## shaders are generated as before; the twin multiplies the alpha.
func _test_mod_shader_twin() -> void:
	var opaque := ObjectLoader._mod_shader("back", "opaque", true)
	var mixed := ObjectLoader._mod_shader("back", "mix", false)
	_check(not opaque.code.contains("appear_alpha") and not mixed.code.contains("appear_alpha"), "the world's mod shaders have no fade uniform")
	_check(not opaque.code.contains("ALPHA ="), "an opaque mod shader still writes no ALPHA")
	var t_opaque := _fade_shader_of(opaque)
	var t_mixed := _fade_shader_of(mixed)
	_check(t_opaque != null and t_opaque.code.contains("blend_mix") and t_opaque.code.contains("ALPHA = appear_alpha;"),
		"an opaque mod shader's twin is blended at the fade's alpha")
	_check(t_mixed != null and t_mixed.code.contains("ALPHA = clamp(out_a, 0.0, 1.0) * appear_alpha;"),
		"a blended one's twin multiplies its own alpha by the fade's")
	_check(t_opaque != null and _fade_shader_of(opaque) == t_opaque, "one twin per mod shader")
	_check(not ObjectLoader.FOLIAGE_SHADER.code.contains("APPEAR_FADE"), "the world's foliage shader does not define APPEAR_FADE")

## ObjectLoader.appear_fade_shader(shader), or null on a client without it
## (called by name, so the suite compiles there too).
func _fade_shader_of(shader: Shader) -> Shader:
	var ol: Script = load("res://scripts/assets/object_loader.gd")
	for m in ol.get_script_method_list():
		if String(m["name"]) == "appear_fade_shader":
			return ol.call("appear_fade_shader", shader)
	return null

## A StandardMaterial3D with a setting the standard fade shader does not
## draw keeps the duplicated-BaseMaterial3D twin.
func _test_other_standard() -> void:
	var std := StandardMaterial3D.new()
	std.vertex_color_use_as_albedo = true
	_check(not AF.is_plain_standard(std), "a StandardMaterial3D using vertex colour is not plain")
	var twin = AF.fade_twin(std)
	_check(twin is BaseMaterial3D and (twin as BaseMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_ALPHA
		and (twin as BaseMaterial3D).vertex_color_use_as_albedo, "and fades as a blended duplicate of itself")
	var capsule := StandardMaterial3D.new()
	capsule.albedo_color = Color(0.55, 0.15, 0.1)
	_check(AF.is_plain_standard(capsule), "a capsule's colour-only material is plain")

## The warm-up (round 676's review): one quad per fade twin shader, at alpha
## 0, in front of the camera, gone after WARM_FRAMES frames.
func _test_warm() -> void:
	var cam := Camera3D.new()
	root.add_child(cam)
	var n: int = AF.warm(cam)
	var node := cam.get_node_or_null("AppearFadeWarm")
	_check(n >= 4 and node != null and node.get_child_count() == n, "the warm-up draws a quad per fade shader (%d)" % n)
	var all_zero := true
	if node != null:
		for c in node.get_children():
			var m := (c as MeshInstance3D).material_override as ShaderMaterial
			if m == null or float(m.get_shader_parameter("appear_alpha")) != 0.0:
				all_zero = false
	_check(all_zero, "each at alpha 0")
	for i in range(AF.WARM_FRAMES + 1):
		await process_frame
	_check(cam.get_node_or_null("AppearFadeWarm") == null, "and frees them after WARM_FRAMES frames")
	cam.free()

## A shader with no fade twin is left as it is: that piece pops in.
func _test_unknown_shader() -> void:
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nvoid fragment() { ALBEDO = vec3(1.0); }\n"
	var own := ShaderMaterial.new()
	own.shader = sh
	var body := Node3D.new()
	var mi := _box(own)
	body.add_child(mi)
	root.add_child(body)
	var fades = AF.Fades.new()
	fades.start(body)
	_check(mi.material_override == own and fades.unfadable() == 1 and fades.running() == 0,
		"an unknown shader's piece keeps its material, counted as unfadable")
	body.free()

# --- The world --------------------------------------------------------------

var _mob_material: StandardMaterial3D = null

func _make_world() -> Node:
	var sub := GDScript.new()
	sub.source_code = "\n".join(PackedStringArray([
		"extends \"res://scripts/World3D.gd\"",
		"func _ready() -> void:",
		"\tpass",
		"func _physics_process(_delta: float) -> void:",
		"\tpass",
		"func _input(_event: InputEvent) -> void:",
		"\tpass",
		"func _unhandled_input(_event: InputEvent) -> void:",
		"\tpass",
		"func _exit_tree() -> void:",
		"\tpass",
		""]))
	_check(sub.reload() == OK and sub.can_instantiate(), "a quiet subclass of World3D.gd compiles")
	var scene := load("res://scenes/World3D.tscn") as PackedScene
	if not sub.can_instantiate() or scene == null:
		return null
	var world: Node = scene.instantiate()
	world.set_script(sub)
	world.set("_monster_models_loaded", true)
	world.set("_monster_models_by_code", {"MOB_FADE_TEST": "synthetic\\fade.bsr"})
	world.set("_monster_assemble", _synthetic_model)
	root.add_child(world)
	return world

func _synthetic_model(_path: String) -> SkinnedBsrAssembler.AssembledCharacter:
	var skel := Skeleton3D.new()
	skel.add_bone("root")
	skel.add_bone("top")
	skel.set_bone_parent(1, 0)
	skel.set_bone_rest(1, Transform3D(Basis(), Vector3(0.0, 2.0, 0.0)))
	skel.set_bone_pose_position(1, Vector3(0.0, 2.0, 0.0))
	_mob_material = StandardMaterial3D.new()
	_mob_material.albedo_texture = _texture()
	skel.add_child(_box(_mob_material))
	var result := SkinnedBsrAssembler.AssembledCharacter.new()
	result.skeleton = skel
	return result

## The world's fades, stepped by hand (the quiet world has no physics step);
## null on a client without them.
func _step_world(world: Node, seconds: float) -> bool:
	var fades = world.get("_appear_fades")
	if fades == null:
		return false
	fades.step(seconds)
	return true

func _model_meshes(body: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for n in body.find_children("*", "MeshInstance3D", true, false):
		out.append(n as MeshInstance3D)
	return out

func _test_world_monster(world: Node) -> void:
	var snap := CombatNet.MonsterSnapshot.new()
	snap.monster_id = 76001
	snap.code_name = "MOB_FADE_TEST"
	snap.monster_name = "Fade test"
	snap.max_hp = 10
	snap.hp = 10
	world.call("_spawn_or_update_monster", snap)
	var bodies: Dictionary = world.get("_monster_bodies")
	var body: Node3D = bodies.get(76001)
	_check(body != null, "the monster's body is built")
	if body == null:
		return
	var meshes := _model_meshes(body)
	_check(meshes.size() == 1, "its model has one mesh (the synthetic box)")
	if meshes.is_empty():
		return
	var mi := meshes[0]
	_check(_near(_drawn_alpha(mi), 0.0), "a monster's body is drawn at alpha 0 the frame it is built (it does not pop in)")
	var label := body.get_node_or_null("Label") as Label3D
	var plate_colour := label.modulate if label != null else Color.BLACK
	var stepped := _step_world(world, 1.0)
	_check(stepped and _near(_drawn_alpha(mi), 127.0 / 255.0), "half way through its fade at 1.0 s")
	_check(label != null and label.modulate == plate_colour and label.modulate.a == 1.0, "its name plate is not faded")
	world.call("_spawn_or_update_monster", snap)
	_check(_near(_drawn_alpha(mi), 127.0 / 255.0), "a refresh of the same monster does not restart it")
	_step_world(world, 1.01)
	_check(mi.material_override == _mob_material and _mob_material.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED,
		"at 2.01 s it draws with its species' own, shared, opaque material")
	world.call("_forget_monster", 76001)
	await process_frame

func _test_world_player(world: Node) -> void:
	world.call("_spawn_or_update_other", 76002, "Fader", Vector3(10.0, 0.0, 10.0))
	var others: Dictionary = world.get("_other_bodies")
	var body: Node3D = others.get(76002)
	_check(body != null, "another player's body is built")
	if body == null:
		return
	var meshes := _model_meshes(body)
	_check(not meshes.is_empty(), "it has a mesh")
	if meshes.is_empty():
		return
	var own: Material = AF.original_material(meshes[0]) if AF != null else meshes[0].material_override
	_check(_near(_drawn_alpha(meshes[0]), 0.0), "another player's body is drawn at alpha 0 the frame it appears (READ: the same 2.0 s fade)")
	_step_world(world, 1.0)
	_check(_near(_drawn_alpha(meshes[0]), 127.0 / 255.0), "half way at 1.0 s")
	_step_world(world, 1.01)
	_check(meshes[0].material_override == own and _near(_drawn_alpha(meshes[0]), 1.0), "opaque, with its own material, at 2.01 s")
	world.call("_on_entity_left", 76002)
	await process_frame
