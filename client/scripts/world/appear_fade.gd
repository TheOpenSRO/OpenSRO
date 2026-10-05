extends RefCounted
class_name AppearFade

## A character fades into existence (round 676). Retail does not pop a
## monster or another player in: it fades the model up from nothing over two
## seconds. Everything below is READ from the client (sro_client.exe) unless
## it says otherwise; docs/protocol/appear_fade.md has the addresses.
##
## - **Who starts it.** A spawn (0x3015, `FUN_008a6ca0`) and a group spawn
##   (`FUN_008a6d20`, type 1) both run the object's body reader (vslot 0x64);
##   a character's reader ends in vslot 0x6c, `FUN_009d17e0`, which -- while
##   the object's byte +0x770 is set -- creates a `CIDecoAppear` (class link
##   0x110a770, name string 0xde5610) on the object's id with the float at
##   0xd86ecc, **2.0 seconds**. The byte is 1 from the CICharactor
##   constructor (asm 0x9d2e50) and cleared only for objects the client makes
##   itself (a game script's actor at 0x518514, an icscriptobj at 0x9e26de,
##   `FUN_0050f1b0`). Monsters, NPCs, guards, pets (CICCos) and other players
##   (CICUser, whose vslot 0x6c `FUN_009dbcc0` calls `FUN_009d17e0`) all
##   take it, at the same 2.0 s. Ground items (CIItem, vslot 0x6c
##   `FUN_009c1890`) do not: they pop in.
## - **The curve.** `CIDecoAppear::FUN_00a48a20` starts the alpha at 0 and
##   its rate at 255.0 (the double at 0xd83108) / 2.0; each frame
##   `CIDecoAppear::vslot_009` (0xa48ae0) adds rate x dt (the float at
##   0x110f7fc: the frame's elapsed seconds, clamped to 3.0, written beside
##   the milliseconds at 0x110f7f8 by 0xba40fb-0xba4136) and, while the sum
##   is <= 255, sets the model's alpha to the sum TRUNCATED, & 0xff (asm
##   0xa48b5f-0xa48b75: `fnstcw`, `or eax, 0xc00` -- rounding control
##   "chop" -- `fldcw`, `fistp`); past 255 it sets 0xff and the deco removes
##   itself. Linear, 0 to 255 in 2.0 s.
## - **What it fades.** The alpha goes to the model's compound,
##   `CCompChar` vslot 5 (0xc25590: +0x4c = alpha << 24). The name plate is
##   drawn at full alpha whatever the model's (`FUN_008b4d90(point, 0xff)`,
##   READ in round 673). Whether the shadow or attached effects read the
##   compound's alpha is not read (OPEN); this client fades the model's own
##   meshes only and leaves the name plate, the party mark and any effect
##   as they were.
## - **The way out** (round 677, READ): a despawn (0x3016, `FUN_008a6cc0`,
##   and a group despawn, `FUN_008a6d20` type 2, which calls it per id) runs
##   the object's vslot 0x4c with 0 (`IGIDObject::FUN_009c32f0`; CICMonster's
##   `FUN_009d3c90`, CICCos's 0x9c66e0, CIItem's 0x9e21c0 are the same shape;
##   CICUser's 0x9daf10 passes 1 -- no fade -- in its modes 4/6/7). It first
##   takes the object out of the game-id hash and zeroes its id
##   (`IGIDObject::FUN_009c3270`: g_sHashGID, +0xf8), then makes a
##   `CIDecoDisappear` (0x110a790) on it with the float at 0xd819ec, **1.5
##   s**. `CIDecoDisappear::FUN_00a49970` starts the alpha at 255.0 (float
##   0xd85284) and its rate at 255.0 (double 0xd83108) / 1.5; each frame
##   `CIDecoDisappear::vslot_009` (0xa49a30) subtracts rate x dt and, while
##   the result is >= 0, sets it TRUNCATED (asm 0xa49ab9-0xa49ad4: `fnstcw`,
##   `or eax, 0xc00`, `fldcw`, `fistp`, as the appear does); below 0 it
##   deletes itself and the object (`entitymanager::FUN_00ba3770`, asm
##   0xa49b34-0xa49b71). So 170 at 0.5 s, 85 at 1.0 s, 0 at 1.5 s, gone the
##   frame after. The object is not in the id hash while it fades: a new
##   spawn of the same id is a new object (fade_out() below hands the body
##   over; World3D builds a fresh one).
##
## How it is drawn (OURS). Godot 4.2's GL Compatibility renderer ignores
## GeometryInstance3D.transparency (MEASURED, round 676: a model at
## transparency 1.0 covered all of its pixels), so a fading model is drawn
## with blended twins of its own materials: a plain StandardMaterial3D as a
## ShaderMaterial on STANDARD_FADE_CODE (its own look; the alpha is the
## fade's alone, never the texture's -- the opaque original ignores texture
## alpha, so a twin that multiplied it in would show holes, then snap
## opaque), any other BaseMaterial3D duplicated with alpha blending, a
## ShaderMaterial duplicated onto its shader's fade
## twin (ObjectLoader.appear_fade_shader: the object shaders' fade twins,
## ObjectLoader.object_shader(kind, true) -- every object layer since round 706 -- and the
## mod shader's `fade` twin), the alpha set on the twin. The twins are shared
## by every model whose fade started in the same frame (one cohort: they are
## always at the same alpha), so a list of hundreds of one species makes one
## twin per material, not one per body. When the fade ends each mesh gets its
## own material back -- the shared, opaque one -- and the twins are dropped.
## A material with no fade twin (a shader this file does not know) is left
## as it is: that piece pops in, as before (counted in `unfadable`).
## The fade-out (round 677, Fades.start_out) is the same in reverse: the
## twins start at alpha 255 and go down, and when the fade ends the model is
## freed instead of getting its materials back (a piece with no twin stays
## opaque until then).

## The fade-in's length, seconds. READ: the float at 0xd86ecc (2.0), passed
## by `FUN_009d17e0` (asm 0x9d190b) to `CIDecoAppear::FUN_00a48a20`.
const APPEAR_SECONDS := 2.0
## The fade-out's length on a despawn, seconds. READ: the float at 0xd819ec
## (1.5), passed by `IGIDObject::FUN_009c32f0` / `FUN_009d3c90` to
## `CIDecoDisappear::FUN_00a49970`. Drawn since round 677 (Fades.start_out).
const DISAPPEAR_SECONDS := 1.5
## Full alpha. READ: the double at 0xd83108 (255.0).
const FULL := 255.0
## Meta on a mesh while it fades: the material it gets back. BerserkLook
## reads it (original_material), so a berserk starting mid-fade keeps the
## real one.
const ORIGINAL_META := "opensro_appear_original"
## Meta on a fade twin (a material made by fade_twin).
const TWIN_META := "opensro_appear_twin"

## The twin of a plain StandardMaterial3D (OURS): the shader Godot 4.2
## generates for one -- albedo colour times the albedo texture's colour,
## metallic 0, roughness 1, specular 0.5, Burley diffuse, Schlick-GGX
## specular -- with ALPHA the fade's alone. `%s` is the cull mode.
const STANDARD_FADE_CODE := """shader_type spatial;
// A plain StandardMaterial3D while its character fades into existence
// (AppearFade, round 676): its own look, blended at the fade's alpha.
render_mode blend_mix, depth_draw_always, cull_%s, diffuse_burley, specular_schlick_ggx;
uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D texture_albedo : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float appear_alpha = 1.0;
void fragment() {
	vec4 albedo_tex = texture(texture_albedo, UV);
	ALBEDO = albedo.rgb * albedo_tex.rgb;
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
	SPECULAR = 0.5;
	ALPHA = appear_alpha;
}
"""
static var _standard_fade_shaders := {}

## The STANDARD_FADE_CODE shader for a cull mode, made once.
static func standard_fade_shader(cull: String) -> Shader:
	if not _standard_fade_shaders.has(cull):
		var sh := Shader.new()
		sh.code = STANDARD_FADE_CODE % cull
		_standard_fade_shaders[cull] = sh
	return _standard_fade_shaders[cull]

## Whether `m` is a StandardMaterial3D STANDARD_FADE_CODE draws as it is
## drawn: opaque, an albedo colour and texture and every other setting at
## Godot's default (ObjectLoader's plain layers and the capsules are).
static func is_plain_standard(m: Material) -> bool:
	if not (m is StandardMaterial3D):
		return false
	var std := m as StandardMaterial3D
	return std.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED \
		and std.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL \
		and std.diffuse_mode == BaseMaterial3D.DIFFUSE_BURLEY \
		and std.specular_mode == BaseMaterial3D.SPECULAR_SCHLICK_GGX \
		and std.blend_mode == BaseMaterial3D.BLEND_MODE_MIX \
		and std.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY \
		and std.cull_mode in [BaseMaterial3D.CULL_BACK, BaseMaterial3D.CULL_DISABLED] \
		and not std.vertex_color_use_as_albedo \
		and std.metallic == 0.0 and std.roughness == 1.0 and std.metallic_specular == 0.5 \
		and std.metallic_texture == null and std.roughness_texture == null \
		and not std.emission_enabled and not std.normal_enabled and not std.rim_enabled \
		and not std.clearcoat_enabled and not std.ao_enabled and not std.detail_enabled \
		and not std.disable_ambient_light and not std.disable_receive_shadows \
		and not std.no_depth_test and not std.fixed_size and not std.use_point_size \
		and std.billboard_mode == BaseMaterial3D.BILLBOARD_DISABLED \
		and std.texture_filter == BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS \
		and std.texture_repeat \
		and std.uv1_scale == Vector3.ONE and std.uv1_offset == Vector3.ZERO \
		and not std.uv1_triplanar

## The model's alpha byte `elapsed` seconds into a fade of `duration`, as
## `CIDecoAppear::vslot_009` sets it: 255 / duration x elapsed, truncated
## (READ: the FPU's rounding control set to chop around its `fistp`), while
## that is <= 255, else 255.
static func alpha_at(elapsed: float, duration: float = APPEAR_SECONDS) -> int:
	if duration <= 0.0:
		return 255
	var a := FULL / duration * maxf(elapsed, 0.0)
	if a > FULL:
		return 255
	return int(a) & 0xff

## Whether a fade of `duration` is over `elapsed` seconds in: the deco's sum
## has passed 255 (it set 0xff and removed itself).
static func done_at(elapsed: float, duration: float = APPEAR_SECONDS) -> bool:
	return duration <= 0.0 or FULL / duration * elapsed > FULL

## The model's alpha byte `elapsed` seconds into a despawn's fade-out of
## `duration`, as `CIDecoDisappear::vslot_009` (0xa49a30) sets it: 255 less
## 255 / duration x elapsed, truncated (READ, the same chop as the appear),
## while that is >= 0; 0 after (the object is gone by then: out_done_at).
static func out_alpha_at(elapsed: float, duration: float = DISAPPEAR_SECONDS) -> int:
	if duration <= 0.0:
		return 0
	var a := FULL - FULL / duration * maxf(elapsed, 0.0)
	if a < 0.0:
		return 0
	return int(a) & 0xff

## Whether a fade-out of `duration` is over `elapsed` seconds in: the
## deco's value has gone below 0, and it deleted itself and the object
## (READ, asm 0xa49aaa-0xa49ab5: `fcomp` against 0, `test ah, 0x41`). A
## duration of 0 (`IGIDObject::FUN_009c32f0`'s CICMonster +0x7b0 branch)
## ends at the first step.
static func out_done_at(elapsed: float, duration: float = DISAPPEAR_SECONDS) -> bool:
	return duration <= 0.0 or FULL - FULL / duration * elapsed < 0.0

## The meshes a model is drawn with: every MeshInstance3D at or under
## `model`, not counting an effect's (under an EfpEffect). The name plate
## (Label3D), the party mark (Sprite3D) and a collider are not meshes.
static func instances_of(model: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if model == null:
		return out
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is EfpEffect:
			continue
		if n is MeshInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out

## The material `mi` really draws with: the one it gets back after a fade
## while it still draws with its fade twin, else its material_override. (A
## mesh whose twin something else replaced mid-fade -- a berserk ending and
## restoring its own original -- draws with that now, and the fade's mark is
## stale until the fade ends.)
static func original_material(mi: MeshInstance3D) -> Material:
	var now := mi.material_override
	if mi.has_meta(ORIGINAL_META) and now != null and now.has_meta(TWIN_META):
		return mi.get_meta(ORIGINAL_META)
	return now

## A blended twin of `src` at alpha 0, or null when `src` has none. OURS:
## depth is written (depth_draw_always) so the model's near faces stay in
## front of its far ones while it is translucent.
static func fade_twin(src: Material) -> Material:
	var twin := _make_twin(src)
	if twin != null:
		twin.set_meta(TWIN_META, true)
	return twin

static func _make_twin(src: Material) -> Material:
	# A glowing weapon fades on its plain material: the glow is drawn only
	# while the owner's colour word is at full alpha (READ,
	# CRTModProgEquipPow::vslot_002/004; EquipGlow, round 734).
	src = EquipGlow.plain_of(src)
	if is_plain_standard(src):
		var std := src as StandardMaterial3D
		var plain := ShaderMaterial.new()
		plain.shader = standard_fade_shader("disabled" if std.cull_mode == BaseMaterial3D.CULL_DISABLED else "back")
		plain.set_shader_parameter("albedo", std.albedo_color)
		if std.albedo_texture != null:
			plain.set_shader_parameter("texture_albedo", std.albedo_texture)
		set_twin_alpha(plain, 0.0)
		return plain
	if src is BaseMaterial3D:
		var std := (src as BaseMaterial3D).duplicate() as BaseMaterial3D
		std.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		std.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
		std.set_meta("opensro_appear_base_alpha", (src as BaseMaterial3D).albedo_color.a)
		set_twin_alpha(std, 0.0)
		return std
	if src is ShaderMaterial:
		var shader := ObjectLoader.appear_fade_shader((src as ShaderMaterial).shader)
		if shader == null:
			return null
		# Copied by parameter, not Resource.duplicate(): a duplicated object
		# material drew its diffuse term brighter (round 706 review, MEASURED;
		# ObjectLight.copy_material).
		var sm := ObjectLight.copy_material(src as ShaderMaterial)
		sm.shader = shader
		set_twin_alpha(sm, 0.0)
		return sm
	return null

## Sets a twin's alpha, 0..1.
static func set_twin_alpha(twin: Material, a: float) -> void:
	if twin is BaseMaterial3D:
		var std := twin as BaseMaterial3D
		var c := std.albedo_color
		c.a = float(std.get_meta("opensro_appear_base_alpha", 1.0)) * a
		std.albedo_color = c
	elif twin is ShaderMaterial:
		(twin as ShaderMaterial).set_shader_parameter("appear_alpha", a)

## The fade twins' shaders, compiled before the first fade needs them
## (round 676's review). A GL driver compiles a shader the first frame it
## draws it: MEASURED with empty Godot and Mesa shader caches, a monster's
## first frame took 138-197 ms on its fade twin (`measure_appear_fade.gd`,
## WORLD_ISSUES round 676, Review), the hitch landing when the first monster
## of each material kind appears. So while the world loads, `warm(camera)`
## draws one tiny quad per twin shader -- the standard fade shader both
## culls, the two foliage fade variants, the solid object's (round 706), and the fade twin of every MTRL mod
## shader made so far -- at alpha 0 in front of the camera for WARM_FRAMES
## frames, then frees them. OURS.
const WARM_FRAMES := 3

static func warm_materials() -> Array[Material]:
	var out: Array[Material] = []
	var white := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	white.fill(Color.WHITE)
	var tex := ImageTexture.create_from_image(white)
	var shaders: Array[Shader] = [standard_fade_shader("back"), standard_fade_shader("disabled"),
		ObjectLoader.appear_fade_shader(ObjectLoader.FOLIAGE_SHADER),
		ObjectLoader.appear_fade_shader(ObjectLoader.FOLIAGE_SHADER_ONE_SIDED),
		ObjectLoader.appear_fade_shader(ObjectLoader.OBJECT_SHADER)]
	for sh in ObjectLoader.mod_shaders_made():
		var twin := ObjectLoader.appear_fade_shader(sh)
		if twin != null and not shaders.has(twin):
			shaders.append(twin)
	for sh in shaders:
		if sh == null:
			continue
		var m := ShaderMaterial.new()
		m.shader = sh
		m.set_shader_parameter("appear_alpha", 0.0)
		m.set_shader_parameter("texture_albedo", tex)
		m.set_shader_parameter("albedo_texture", tex)
		out.append(m)
	return out

## Puts the warm-up quads in front of `camera`; they free themselves after
## WARM_FRAMES drawn frames. Returns how many shaders it warms.
static func warm(camera: Camera3D) -> int:
	if camera == null:
		return 0
	var node := Warm.new()
	node.name = "AppearFadeWarm"
	var mats := warm_materials()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.01, 0.01)
	for i in range(mats.size()):
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.material_override = mats[i]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(0.002 * i, 0.0, -1.0)
		node.add_child(mi)
	camera.add_child(node)
	return mats.size()

class Warm extends Node3D:
	var _frames := 0
	func _process(_delta: float) -> void:
		_frames += 1
		if _frames >= AppearFade.WARM_FRAMES:
			queue_free()

## Models fading together: started in the same frame and the same way, so
## always at the same alpha, and sharing their materials' twins. `out` is a
## despawn's fade-out (round 677): 255 down to 0, then the models are freed.
class Cohort:
	var elapsed := 0.0
	var duration := APPEAR_SECONDS
	var out := false
	## source material instance id -> its twin (null: none)
	var twins := {}
	## [MeshInstance3D, surface (-1: material_override), original, twin, model]
	var meshes: Array = []
	var models: Array = []
	## A fade-out's callbacks: model instance id -> Callable(model), run just
	## before the model is freed.
	var done_calls := {}

## The fades running, stepped once a physics step by World3D.
class Fades:
	var _cohorts: Array[Cohort] = []
	## The cohorts started since the last step, which new models join: one
	## fading in, one fading out.
	var _open: Cohort = null
	var _open_out: Cohort = null
	var _started := 0
	var _finished := 0
	var _started_out := 0
	var _freed := 0
	var _unfadable := 0

	## Starts `model` fading in from nothing: from now every mesh under it
	## (instances_of) draws with its material's twin at alpha 0, the deco's
	## start value, until step() raises it.
	func start(model: Node, duration: float = APPEAR_SECONDS) -> void:
		if model == null or not is_instance_valid(model) or fading(model):
			return
		if _open == null or _open.duration != duration:
			_open = Cohort.new()
			_open.duration = duration
			_cohorts.append(_open)
		if _take_model(_open, model, 0.0):
			_open.models.append(model)
			_started += 1

	## Starts `model` fading out (round 677; READ, CIDecoDisappear): from now
	## every mesh under it draws with its material's twin at alpha 255, the
	## deco's start value, step() lowers it, and when it goes below 0 the
	## model is freed -- `on_done(model)` first, when given. The model is the
	## fade's from here: the caller drops it from whatever tracks it (the
	## object leaves retail's id hash at this point, FUN_009c3270).
	##
	## A model still fading in stops doing so: its meshes get their own
	## materials back and fade out from 255. INFERRED: the appear and the
	## disappear deco are both live on the object then and each sets the
	## alpha every frame; the disappear, made later, is taken to run later in
	## the entity list and so to be the one drawn (the list order was not
	## read). A model already fading out is left to finish its own fade.
	## A model with nothing fadable is still freed after `duration` (its
	## pieces stay opaque until then).
	func start_out(model: Node, duration: float = DISAPPEAR_SECONDS, on_done: Callable = Callable()) -> void:
		if model == null or not is_instance_valid(model) or fading_out(model):
			return
		_cancel_in(model)
		if _open_out == null or _open_out.duration != duration:
			_open_out = Cohort.new()
			_open_out.duration = duration
			_open_out.out = true
			_cohorts.append(_open_out)
		_take_model(_open_out, model, 1.0)
		_open_out.models.append(model)
		if on_done.is_valid():
			_open_out.done_calls[model.get_instance_id()] = on_done
		_started_out += 1

	## Puts every mesh under `model` on its twin in `co`, at alpha `a`.
	## Whether any mesh took one.
	func _take_model(co: Cohort, model: Node, a: float) -> bool:
		var took := false
		for mi in AppearFade.instances_of(model):
			if mi.has_meta(AppearFade.ORIGINAL_META):
				continue
			if mi.material_override != null:
				took = _take(co, mi, -1, mi.material_override, model, a) or took
			elif mi.mesh != null:
				for s in range(mi.mesh.get_surface_count()):
					var src := mi.get_active_material(s)
					if src != null:
						took = _take(co, mi, s, src, model, a) or took
		return took

	func _take(co: Cohort, mi: MeshInstance3D, surface: int, src: Material, model: Node, a: float) -> bool:
		var id := src.get_instance_id()
		if not co.twins.has(id):
			var made := AppearFade.fade_twin(src)
			if made != null:
				AppearFade.set_twin_alpha(made, a)
			co.twins[id] = made
		var twin: Material = co.twins[id]
		if twin == null:
			_unfadable += 1
			return false
		var original: Material = src if surface < 0 else mi.get_surface_override_material(surface)
		if surface < 0:
			mi.set_meta(AppearFade.ORIGINAL_META, original)
			mi.material_override = twin
		else:
			mi.set_surface_override_material(surface, twin)
		co.meshes.append([mi, surface, original, twin, model])
		return true

	## Ends `model`'s fade-in now: its meshes get their own materials back
	## (_restore_mesh) and it leaves its cohort.
	func _cancel_in(model: Node) -> void:
		for co in _cohorts:
			if co.out or not co.models.has(model):
				continue
			var keep: Array = []
			for m in co.meshes:
				if m[4] == model:
					_restore_mesh(m)
				else:
					keep.append(m)
			co.meshes = keep
			co.models.erase(model)

	## Advances every fade by `delta` seconds: the twins take the cohort's
	## alpha; a finished fade-in gives each mesh its own material back, a
	## finished fade-out frees its models; either is then dropped.
	func step(delta: float) -> void:
		_open = null
		_open_out = null
		if _cohorts.is_empty():
			return
		var keep: Array[Cohort] = []
		for co in _cohorts:
			co.elapsed += delta
			if co.out:
				if AppearFade.out_done_at(co.elapsed, co.duration):
					_free_out(co)
					continue
				var oa := float(AppearFade.out_alpha_at(co.elapsed, co.duration)) / AppearFade.FULL
				for twin in co.twins.values():
					if twin != null:
						AppearFade.set_twin_alpha(twin, oa)
				keep.append(co)
				continue
			if AppearFade.done_at(co.elapsed, co.duration):
				_restore(co)
				_finished += co.models.size()
				continue
			if co.models.is_empty():
				continue
			var a := float(AppearFade.alpha_at(co.elapsed, co.duration)) / AppearFade.FULL
			for twin in co.twins.values():
				if twin != null:
					AppearFade.set_twin_alpha(twin, a)
			keep.append(co)
		_cohorts = keep

	## Ends every fade-out now: their models are freed at once (a zone
	## change: World3D's teardown frees the old zone's bodies at once, as
	## retail's FUN_009c2c20 deletes every object with vslot 0x4c(1), no
	## fade). Returns how many were freed.
	func free_out_now() -> int:
		var before := _freed
		var keep: Array[Cohort] = []
		for co in _cohorts:
			if co.out:
				_free_out(co)
			else:
				keep.append(co)
		_cohorts = keep
		_open_out = null
		return _freed - before

	## A fade-out is over: each model's callback, then the model is freed.
	func _free_out(co: Cohort) -> void:
		for model in co.models:
			if model == null or not is_instance_valid(model):
				continue
			var call: Callable = co.done_calls.get(model.get_instance_id(), Callable())
			if call.is_valid():
				call.call(model)
			if is_instance_valid(model) and not (model as Node).is_queued_for_deletion():
				(model as Node).queue_free()
			_freed += 1
		co.meshes.clear()
		co.twins.clear()
		co.done_calls.clear()

	## Gives each still-fading mesh its own material back. A mesh whose
	## material something else has replaced since (BerserkLook) is left with
	## what it has now.
	func _restore(co: Cohort) -> void:
		for m in co.meshes:
			_restore_mesh(m)
		co.meshes.clear()
		co.twins.clear()

	func _restore_mesh(m: Array) -> void:
		var mi = m[0]
		if mi == null or not is_instance_valid(mi):
			return
		var surface: int = m[1]
		if surface < 0:
			if (mi as MeshInstance3D).material_override == m[3]:
				(mi as MeshInstance3D).material_override = m[2]
			(mi as Node).remove_meta(AppearFade.ORIGINAL_META)
		elif (mi as MeshInstance3D).get_surface_override_material(surface) == m[3]:
			(mi as MeshInstance3D).set_surface_override_material(surface, m[2])

	## Models fading, in or out.
	func running() -> int:
		var n := 0
		for co in _cohorts:
			for m in co.models:
				if is_instance_valid(m):
					n += 1
		return n

	## Models fading out.
	func running_out() -> int:
		var n := 0
		for co in _cohorts:
			if not co.out:
				continue
			for m in co.models:
				if is_instance_valid(m):
					n += 1
		return n

	## Whether `model` is fading, in or out.
	func fading(model: Node) -> bool:
		for co in _cohorts:
			if co.models.has(model):
				return true
		return false

	func fading_out(model: Node) -> bool:
		for co in _cohorts:
			if co.out and co.models.has(model):
				return true
		return false

	## The alpha (0..255) `model` is drawn at, or 255 when it is not fading.
	func alpha_of(model: Node) -> int:
		for co in _cohorts:
			if co.models.has(model):
				if co.out:
					return AppearFade.out_alpha_at(co.elapsed, co.duration)
				return AppearFade.alpha_at(co.elapsed, co.duration)
		return 255

	## How many twins are alive (shared materials made for the fades running).
	func twin_count() -> int:
		var n := 0
		for co in _cohorts:
			for t in co.twins.values():
				if t != null:
					n += 1
		return n

	func started() -> int:
		return _started

	func finished() -> int:
		return _finished

	func started_out() -> int:
		return _started_out

	## Models a fade-out has freed.
	func freed() -> int:
		return _freed

	func unfadable() -> int:
		return _unfadable
