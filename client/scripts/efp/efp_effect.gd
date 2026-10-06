extends Node3D
class_name EfpEffect

## Draws a decoded .efp (round 620): EfpSim runs the client's own particle
## rules and this node draws them, one MultiMeshInstance3D per drawn node.
##
## What is READ (sro_client.exe; docs/protocol/EFP_FORMAT.md "Playback"):
## - Which draw routine a node uses: EFEffect::FUN_00cabda0 switches on the
##   render command's value, which its factory makes space + 1..5 for
##   RenderPlate, RenderMesh, RenderLinkDPipe, RenderLinkPipe, RenderLinkObj
##   (0 RenderNone); every retail render command has space 0 (MEASURED). So
##   1 = FUN_00c8c210 (plate), 2 = FUN_00c8bf50 (mesh), 3 = FUN_00c8de80,
##   4 = FUN_00c8e020, 5 = FUN_00c8c3a0.
## - A plate is the unit quad (-0.5..0.5 in X and Y, Z 0, UV (0,0) at the
##   top left) at 0x00edb070, scaled per axis by the particle's scale; a mesh
##   is the .bms scaled the same way. Every vertex takes the particle's
##   colour (it replaces the vertex colour) and the UV rectangle maps the
##   texture coordinates: u' = u0 + u*du, v' = v0 + v*dv.
## - The world matrix is shape rotation, then the view matrix, then the
##   position (row vectors): ViewNone uses the particle's rotation;
##   ViewBillboard the matrix at 0x00edbde8 and ViewYBillboard the one at
##   0x00edbe28, both built by CEFSystem::FUN_00cb0ee0 as the inverse of the
##   view matrix with its translation zeroed -- YBillboard's row 1 then forced
##   to (0, 1, 0), its rows 0 and 2 left as they are (READ); ViewVBillboard a
##   basis whose Y axis is the particle's velocity and whose Z is velocity x
##   up (the case-3 branch).
##   The inverse view's rows are the camera's right, up and LOOK directions.
##   This client keeps the game's coordinates unconverted (a mirrored world,
##   BmsReader reverses winding for it), so the look direction is Godot's
##   -camera.z: the billboard basis is (right, up, -back), a reflection
##   (INFERRED from that convention). Billboarded nodes therefore draw both
##   faces (OURS), as the mirrored winding would cull the wrong one.
## - The blend: the node's 36-byte D3D state (src/dest blend, colour and alpha
##   texture ops), ZWRITE off, lighting and fog off. See blend_class and the
##   shader below for the mapping to Godot.
##
## The Link modes (RenderLinkDPipe, RenderLinkPipe, RenderLinkObj; round 621)
## draw one strip per emitter through its chain of live particles, all of a
## node's chains stitched into one ArrayMesh triangle strip, rebuilt after a
## step (or a camera move, for a pipe) within a per-frame budget (OURS):
## EfpLinks has the geometry, READ from
## FUN_00c8de80, FUN_00c8e020, FUN_00c8c3a0 and FUN_00c8d0e0.
##
## Not drawn (OPEN; counted as `skipped` by the census): a node whose mesh or
## texture does not load. (BSAnimation needs
## no drawing: all 3,230 nodes carrying one are RenderNone, MEASURED; their
## motion reaches particles as the baked SetBANPos/SetBANRot keys.)
## Only the first mesh entry and its first texture are drawn: READ, round 621 --
## CEFCShape::FUN_00c883d0 gives a particle its node's first mesh entry and
## that entry's first texture.
##
## On a host (follow_host), the effect is simulated in a space that does not
## move with the host -- retail simulates in world space over the effect's
## scale (READ, round 621: CEFEffect::vslot_007/008, FUN_00cabda0) -- and the
## host's motion reaches the simulation as the effect's placement, which each
## node follows or not by its follow levels (EfpSim, "Motion per frame and
## the follow levels"). Without a host it is simulated in this node's space. It is authored in the game's native units. Attached to a body
## (follow_host), it places itself each frame in the frame of the body's
## current skeleton at a bone, so a skeleton rebuilt by an equipment change
## does not take the effect with it.
##
## Ending (READ, the IEasyFxEffect interface at 0x00e0f594): the owner ends
## a kept effect through slot 2 (CEFEffect::vslot_002: its particles are
## freed at once) or slot 4 with 0 (vslot_004: the keep/loop flag +0x49 is
## cleared and the effect released when its keep count reaches 0). Both drop
## every particle immediately, so stop() here frees the effect at once --
## loop and never-extinct particles included. While the flag is set the
## effect is kept by reviving its root particles (`loop`, round 623).

signal effect_finished

## AT_LOOP / AT_STOP: the effect is KEPT (retail's keep flag +0x49): its
## root particles are revived at age 0 instead of dying, so their child
## emitters cycle on while the older particles finish -- one continuous
## effect, never a restart (READ, round 623; EfpSim "Dying, and the kept
## effect"). It lasts until stop().
var loop := false:
	set(v):
		loop = v
		if sim != null:
			sim.keep = v
## Free the node when the effect ends (and loop is off).
var auto_free := true
var path := ""
var sim: EfpSim
var skipped: PackedStringArray = PackedStringArray()
## Seconds after which a looping effect stops by itself (0 = never; OURS guard).
var max_life := 0.0
## OURS (round 623's review): a one-shot (not kept) ends after this many
## seconds whatever its particles do. The longest retail one-shot that ends
## by itself lasts 238 frames (11.9 s, MEASURED over the 883 ACT_S and SHOT
## files); `mad_general_at03` never ends (its NormalTimeLoop node re-arms
## its children every wrap).
const ONESHOT_MAX_LIFE := 30.0
## The local player's own effect: may use EfpSim's reserved particle share.
var reserved := false:
	set(v):
		reserved = v
		if sim != null:
			sim.reserved = v
## How many times the MultiMeshes were rewritten (tests: only after a step).
var draw_updates := 0
var _has_billboard := false
var _last_cam := Basis()
var _draws: Array = [] # of [tpl index, MultiMeshInstance3D, view mode]
var _links: Array = [] # of [tpl index, MeshInstance3D (ArrayMesh), render mode, EfpLinks.Out, EfpLinks.Buf, EfpLinks.Buf, kind 0 DPipe / 1 Pipe / 2 Obj]
var _life := 0.0
var _follow_host: Node3D = null
var _follow_bone_name := ""
var _follow_offset := Vector3.ZERO
var _follow_skel: Skeleton3D = null
var _follow_bone := -1
var _anchored := false
var _placed := Transform3D()
var _anchor := Transform3D()
## OURS: how far (native units) the host may move from the anchor before
## the simulation space re-centres on it.
const ANCHOR_RECENTRE := 60.0
## OURS: a placement this far (native units) from the anchor in one frame is
## a jump (teleport, world re-base), not motion: the effect moves with it.
const ANCHOR_JUMP := 400.0

# Shared caches: one decode and one compiled template per file, one texture
# and mesh per asset path, one material per (texture, state). Bounded by
# least-recent use (OURS: CACHE_* below). _images / _mesh_arrays hold what a
# preload task decoded off the main thread, turned into resources on first use.
static var _templates: Dictionary = {} # path -> EfpSim.Template, or null when it failed
static var _textures: Dictionary = {} # path -> Texture2D or null
static var _meshes: Dictionary = {} # path -> ArrayMesh or null
static var _materials: Dictionary = {} # key -> ShaderMaterial
static var _shaders: Dictionary = {} # key -> Shader
static var _images: Dictionary = {} # path -> Image or null (preloaded)
static var _mesh_arrays: Dictionary = {} # path -> Array or null (preloaded)
static var _used: Dictionary = {} # "kind|path" -> use stamp (LRU)
static var _stamp := 0
static var _mutex := Mutex.new()
static var _preloads: Array = [] # WorkerThreadPool task ids still running
static var last_error := ""

const CACHE_TEMPLATES := 256 ## OURS
const CACHE_TEXTURES := 384 ## OURS
const CACHE_MESHES := 256 ## OURS

const PLATE := "RenderPlate"
const MESH := "RenderMesh"
const LINK_MODES := ["RenderLinkDPipe", "RenderLinkPipe", "RenderLinkObj"]
## OURS: particles move; a fixed box keeps a MultiMesh from being culled.
const DRAW_AABB := AABB(Vector3(-200, -200, -200), Vector3(400, 400, 400))

## The compiled template of a file in Particles.pk2, decoded once.
static func template_for(efp_path: String, particles: Pk2Reader) -> EfpSim.Template:
	var key := efp_path.to_lower()
	_mutex.lock()
	var have := _templates.has(key)
	var cached: EfpSim.Template = _templates.get(key)
	_mutex.unlock()
	if have:
		_touch("t", key)
		if cached == null:
			last_error = "did not decode"
		return cached
	var err := []
	var t := _decode_template(efp_path, particles, err)
	if t == null:
		last_error = String(err[0]) if not err.is_empty() else "did not decode"
	_mutex.lock()
	_templates[key] = t
	_mutex.unlock()
	_touch("t", key)
	_evict()
	return t

## Reads and compiles one file (plain data: safe on a worker thread).
static func _decode_template(efp_path: String, particles: Pk2Reader, err: Array) -> EfpSim.Template:
	var data := AssetSource.read_bytes(efp_path, particles)
	if data.is_empty():
		err.append("not found")
		return null
	var f := EfpReader.decode(data)
	if f == null:
		err.append(EfpReader.last_error)
		return null
	return EfpSim.compile(f.root)

## Builds a playing effect for a file in the player's Particles.pk2, or null
## when it is missing or does not decode.
static func create(efp_path: String, particles: Pk2Reader) -> EfpEffect:
	if particles == null:
		last_error = "no Particles.pk2"
		return null
	var t := template_for(efp_path, particles)
	if t == null:
		return null
	var fx := from_template(t, func(p: String): return _texture(p, particles),
		func(p: String): return _mesh(p, particles))
	fx.path = efp_path
	return fx

## Builds from a compiled template with the given asset loaders (each takes a
## path and returns a Texture2D / ArrayMesh or null). The tests pass loaders
## that return null or stand-ins, so no game data is needed.
static func from_template(t: EfpSim.Template, load_texture: Callable, load_mesh: Callable,
		seed_value: int = 0) -> EfpEffect:
	var fx := EfpEffect.new()
	fx.name = "EfpEffect"
	fx.sim = EfpSim.new(t, seed_value)
	fx.sim.keep = fx.loop
	for u in t.unsupported:
		fx.skipped.append("command " + u)
	for tp in t.tpls:
		var n: EfpReader.EfpNode = tp.node
		var mode := n.render_mode()
		if mode == "" or mode == "RenderNone":
			continue
		if LINK_MODES.has(mode):
			_add_link(fx, tp, mode, load_texture)
			continue
		if mode != PLATE and mode != MESH:
			fx.skipped.append("%s (%s)" % [mode, n.name])
			continue
		if n.meshes.is_empty():
			fx.skipped.append("%s without a mesh entry (%s)" % [mode, n.name])
			continue
		var ref: EfpReader.EfpMeshRef = n.meshes[0]
		var tex: Texture2D = null
		if not ref.textures.is_empty():
			tex = load_texture.call(ref.textures[0])
		if tex == null:
			fx.skipped.append("texture %s" % (ref.textures[0] if not ref.textures.is_empty() else "(none)"))
			continue
		var mesh: Mesh = null
		if mode == MESH:
			if ref.mesh == "":
				fx.skipped.append("RenderMesh with no mesh (%s)" % n.name)
				continue
			mesh = load_mesh.call(ref.mesh)
			if mesh == null:
				fx.skipped.append("mesh %s" % ref.mesh)
				continue
		else:
			var q := QuadMesh.new()
			q.size = Vector2(1, 1)
			mesh = q
		for v in n.vars:
			if v is Dictionary and String(v.get("type", "")) == "BSAnimation":
				fx.skipped.append("BSAnimation (%s, drawn unanimated)" % n.name)
				break
		var view := n.view_mode()
		var billboard := view == "ViewBillboard" or view == "ViewYBillboard"
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = mesh
		mm.instance_count = 0
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = material_for(tex, n.state, billboard)
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.custom_aabb = DRAW_AABB
		mmi.name = "node_%d" % tp.index
		fx.add_child(mmi)
		fx._draws.append([tp.index, mmi, view])
		if billboard:
			fx._has_billboard = true
	return fx

## The blend class a template shader was built for (_shader).
const BLEND_CLASS_META := "opensro_efp_blend_class"

## Draws this effect's nodes blended in display values (round 722): each node
## gets its own copy of its material on display_shader. Call before
## make_glow, so the glow copies are made from these. Used for the objects'
## ambient effects (AmbientParticles.attach).
func use_display_blend() -> void:
	# Compatibility blends in display values already, and a shader that names
	# the screen texture would make it copy the back buffer every frame
	# (round 722's review): no twin there.
	if not VideoOptions.forward_plus_running():
		return
	var nodes: Array = []
	for d in _draws:
		nodes.append(d[1])
	for l in _links:
		nodes.append(l[1])
	for n in nodes:
		var gi := n as GeometryInstance3D
		var m := gi.material_override as ShaderMaterial
		if m == null or m.shader == null or not m.shader.has_meta(BLEND_CLASS_META):
			continue
		var c := m.duplicate() as ShaderMaterial
		c.shader = display_shader(m.shader)
		gi.material_override = c

## A template shader that blends as Direct3D 9 does, in the framebuffer's
## display values (round 722). The original sets no D3DRS_SRGBWRITEENABLE
## (WORLD_ISSUES, round 705's fog), so its blend adds and mixes the values the
## screen shows; Forward+ blends in a linear buffer, where an additive glow
## over a bright background (Samarkand's arch against the sky) barely shows
## (MEASURED, round 722: Compatibility, which blends in display values, draws
## the arch's glow; Forward+ does not). Under Forward+ the shader reads the
## colour underneath (hint_screen_texture: the opaque scene, before the
## transparent pass), turns it into what the screen shows (Godot's tone map
## forward, ObjectLight's tonemap vector), makes the blend the class names on
## those values, and writes what turns into that once Godot's own blend and
## tone map are done: an additive class adds the difference (ALPHA 1), a
## mixing class the colour whose linear mix lands on it. Under Compatibility
## (OUTPUT_IS_SRGB) nothing changes: it already blends in display values.
## OURS: overlapping particles each blend against the opaque scene and their
## differences add, which is the display sum only while nothing saturates; a
## transparent surface underneath (water, another effect) is not in the
## screen texture.
static func display_shader(sh: Shader) -> Shader:
	var key := "display|%d" % sh.get_instance_id()
	if _shaders.has(key):
		return _shaders[key]
	var cls := String(sh.get_meta(BLEND_CLASS_META, "mix"))
	var code := sh.code
	code = code.replace("\nvoid fragment() {", DISPLAY_FN + "\nvoid fragment() {")
	var rule := "mix(srr_d, srr_s, srr_a)"
	var out := "ALBEDO = max((srr_t - (1.0 - srr_a) * srr_bg) / max(srr_a, 1.0 / 255.0), vec3(0.0));"
	if cls == "add" or cls == "add_one":
		rule = "srr_d + srr_s * srr_a"
		out = "ALBEDO = max(srr_t - srr_bg, vec3(0.0));\n\t\tALPHA = 1.0;"
	code = code.replace(DISPLAY_TAIL_FROM, DISPLAY_TAIL_TO.replace("{RULE}", rule).replace("{OUT}", out))
	var g := Shader.new()
	g.code = code
	g.set_meta(BLEND_CLASS_META, cls)
	_shaders[key] = g
	return g

const DISPLAY_TAIL_FROM := "\tALPHA = clamp(a, 0.0, 1.0);\n}"
const DISPLAY_TAIL_TO := """	ALPHA = clamp(a, 0.0, 1.0);
	if (!OUTPUT_IS_SRGB) {
		vec3 srr_bg = textureLod(srr_screen, SCREEN_UV, 0.0).rgb;
		vec3 srr_d = srr_shown(srr_bg);
		vec3 srr_s = clamp(c, 0.0, 1.0);
		float srr_a = ALPHA;
		vec3 srr_t = srr_unshown(clamp({RULE}, vec3(0.0), vec3(1.0)));
		{OUT}
	}
}"""

## The screen read and Godot's tone map both ways for display_shader (the
## filmic curve and its inverse are ObjectLight's, round 706).
const DISPLAY_FN := """
uniform sampler2D srr_screen : hint_screen_texture, filter_nearest;
global uniform vec4 srr_obj_tonemap;
float srr_fx_filmic_raw(float x) {
	return (x * (0.88 * x + 0.1 * 0.6) + 0.2 * 0.01) / (x * (0.88 * x + 0.6) + 0.2 * 0.3) - 0.01 / 0.3;
}
float srr_fx_filmic_inverse(float t, float white) {
	float u = clamp(t, 0.0, 0.999) * srr_fx_filmic_raw(white) + 0.01 / 0.3;
	float a = 0.88 * (u - 1.0);
	float b = 0.6 * (u - 0.1);
	float c = 0.2 * (0.3 * u - 0.01);
	float disc = max(b * b - 4.0 * a * c, 0.0);
	return max((-b - sqrt(disc)) / (2.0 * a), 0.0);
}
// A linear scene value -> the display value the screen shows for it.
vec3 srr_shown(vec3 srr_l) {
	vec3 srr_v = srr_l * srr_obj_tonemap.x;
	if (srr_obj_tonemap.z > 0.5) {
		float srr_w = srr_fx_filmic_raw(srr_obj_tonemap.y);
		srr_v = vec3(srr_fx_filmic_raw(srr_v.r), srr_fx_filmic_raw(srr_v.g), srr_fx_filmic_raw(srr_v.b)) / srr_w;
	}
	return srr_linear_to_srgb(clamp(srr_v, vec3(0.0), vec3(1.0)));
}
// A display value -> the linear scene value the screen shows it for.
vec3 srr_unshown(vec3 srr_v) {
	vec3 srr_l = srr_srgb_to_linear(clamp(srr_v, vec3(0.0), vec3(1.0)));
	if (srr_obj_tonemap.z > 0.5) {
		srr_l = vec3(srr_fx_filmic_inverse(srr_l.r, srr_obj_tonemap.y), srr_fx_filmic_inverse(srr_l.g, srr_obj_tonemap.y), srr_fx_filmic_inverse(srr_l.b, srr_obj_tonemap.y));
	}
	return srr_l / max(srr_obj_tonemap.x, 0.0001);
}
"""

## The glow pass's draw (round 720, AmbientParticles; READ there): every
## node of this effect is drawn with the depth test off, and its particle
## colours' alpha is scaled by the glow alpha. Each node gets its own copy of
## its material, so the alpha is this effect's alone.
func make_glow() -> void:
	var nodes: Array = []
	for d in _draws:
		nodes.append(d[1])
	for l in _links:
		nodes.append(l[1])
	for n in nodes:
		var gi := n as GeometryInstance3D
		var m := gi.material_override as ShaderMaterial
		if m == null:
			continue
		var g := m.duplicate() as ShaderMaterial
		g.shader = glow_shader(m.shader)
		g.set_shader_parameter("glow_alpha", 0)
		gi.material_override = g
		_glow_materials.append(g)
		_glow_swaps.append([gi, m, g])
	_glow_on = true
	set_glow_alpha(0)

var _glow_materials: Array[ShaderMaterial] = []
var _glow_swaps: Array = [] # of [GeometryInstance3D, its own material, its glow copy]
var _glow_on := false
var _glow_alpha := -1

## Light Effect off (round 720's review, READ: with the effect manager's
## +0x1a4 at 0, CRTModParticle::FUN_00c81450 draws the effect with the scene,
## depth-tested and at full alpha): the nodes take their own materials back
## and the effect shows. On: the glow copies, at the last glow alpha.
func use_glow(on: bool) -> void:
	if on == _glow_on or _glow_swaps.is_empty():
		return
	_glow_on = on
	for sw in _glow_swaps:
		(sw[0] as GeometryInstance3D).material_override = sw[2] if on else sw[1]
	visible = (not on) or _glow_alpha > 0

## The glow alpha, 0..255 (CEFEffect +0x4a): 0 draws nothing
## (CRTModParticle::FUN_00c81130), 255 leaves the colours as they are. Set
## only when it changes (round 720's review).
func set_glow_alpha(a: int) -> void:
	if a == _glow_alpha:
		return
	_glow_alpha = a
	if not _glow_on:
		return
	visible = a > 0
	for m in _glow_materials:
		m.set_shader_parameter("glow_alpha", a)

## Builds every plate, mesh and link shader with its glow twin (round 720's
## review: the glow shader's first compile cost 75 ms on the main thread as
## a gate's region bound). Returns the shaders made.
static func warm_glow_shaders() -> Array[Shader]:
	var out: Array[Shader] = []
	for cls in ["mix", "add", "add_one", "darken", "other"]:
		for no_cull in [false, true]:
			for link in [false, true]:
				var sh := _shader(cls, no_cull, link)
				out.append(sh)
				out.append(glow_shader(sh))
				# The display-blended twins the objects' ambient effects draw
				# with (round 722), for the classes plates and meshes use.
				if not link and cls in ["mix", "add", "add_one"] and VideoOptions.forward_plus_running():
					var dsh := display_shader(sh)
					out.append(dsh)
					out.append(glow_shader(dsh))
	return out

## Draws every EFP shader and its glow twin once, as tiny instanced quads in
## front of `camera`, so their pipelines compile behind the loading screen
## (round 720's review; AppearFade.warm's way: they free themselves after a
## few frames). Returns how many it warms.
static func warm(camera: Camera3D) -> int:
	if camera == null:
		return 0
	var node := AppearFade.Warm.new()
	node.name = "EfpWarm"
	var white := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	white.fill(Color.WHITE)
	var tex := ImageTexture.create_from_image(white)
	var quad := QuadMesh.new()
	quad.size = Vector2(0.01, 0.01)
	var shaders := warm_glow_shaders()
	for i in range(shaders.size()):
		var m := ShaderMaterial.new()
		m.shader = shaders[i]
		m.set_shader_parameter("tex", tex)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = quad
		mm.instance_count = 1
		mm.set_instance_transform(0, Transform3D.IDENTITY)
		mm.set_instance_color(0, Color(1, 1, 1, 0.0))
		mm.set_instance_custom_data(0, Color(0, 0, 1, 1))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = m
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.position = Vector3(0.002 * i, 0.0, -1.0)
		node.add_child(mmi)
	camera.add_child(node)
	return shaders.size()

## `sh` with the depth test off and the glow alpha applied to the particle
## colour (EFEffect::FUN_00c893f0 at 0x00c8affd: when the effect's alpha is
## not 255, the colour's alpha byte becomes (a x alpha) >> 8). Cached per
## shader.
static func glow_shader(sh: Shader) -> Shader:
	var key := "glow|%d" % sh.get_instance_id()
	if _shaders.has(key):
		return _shaders[key]
	var code := sh.code.replace("render_mode unshaded,", "render_mode unshaded, depth_test_disabled,")
	code = code.replace("uniform int c_op = 4;", "uniform int glow_alpha = 255;\nuniform int c_op = 4;")
	code = code.replace("\tvec4 d = COLOR;",
		"\tvec4 d = COLOR;\n\tif (glow_alpha < 255) d.a = floor(floor(d.a * 255.0 + 0.5) * float(glow_alpha) / 256.0) / 255.0;")
	var g := Shader.new()
	g.code = code
	if sh.has_meta(BLEND_CLASS_META):
		g.set_meta(BLEND_CLASS_META, sh.get_meta(BLEND_CLASS_META))
	_shaders[key] = g
	return g

## How many nodes draw.
func draw_count() -> int:
	return _draws.size() + _links.size()

## A Link node's draw: a MeshInstance3D whose ArrayMesh _update_links
## rebuilds from EfpLinks' packed buffers (one Out and two Bufs per node,
## reused every frame). Its texture is the node's first mesh entry's first
## texture (READ, CEFCShape::FUN_00c883d0), bound for every render mode
## (FUN_00cabda0).
static func _add_link(fx: EfpEffect, tp: EfpSim.Tpl, mode: String, load_texture: Callable) -> void:
	var n: EfpReader.EfpNode = tp.node
	var tex: Texture2D = null
	var tname := "(none)"
	if not n.meshes.is_empty():
		var ref: EfpReader.EfpMeshRef = n.meshes[0]
		if not ref.textures.is_empty():
			tname = ref.textures[0]
			tex = load_texture.call(tname)
	if tex == null:
		fx.skipped.append("texture %s" % tname)
		return
	var mi := MeshInstance3D.new()
	mi.mesh = ArrayMesh.new()
	mi.material_override = link_material_for(tex, n.state)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.custom_aabb = DRAW_AABB
	mi.name = "link_%d" % tp.index
	fx.add_child(mi)
	var kind := 2 if mode == "RenderLinkObj" else (1 if mode == "RenderLinkPipe" else 0)
	fx._link_tpls[tp.index] = fx._links.size()
	fx._links.append([tp.index, mi, mode, EfpLinks.Out.new(), EfpLinks.Buf.new(), EfpLinks.Buf.new(), kind])
	if mode != "RenderLinkObj":
		fx._has_pipe = true

## OURS: at most this many Link triangles are rebuilt per rendered frame
## across every effect; a node past the budget keeps last frame's strips.
const LINK_TRIS_PER_FRAME := 20000
static var _link_budget_frame := -1
static var _link_budget_left := 0
var _link_tpls: Dictionary = {} # tpl index -> index into _links
var _has_pipe := false
var _link_cam := Transform3D()
var _link_self := Transform3D()
var _link_proj := Projection()
## How many times the Link strips were rebuilt (tests).
var link_updates := 0

## Refills the per-frame Link budget now (benches and tests that rebuild
## many times within one frame).
static func reset_link_budget() -> void:
	_link_budget_frame = -1

## True when a screen-space strip would change without a step: the camera
## or this effect moved, or the projection changed.
func _link_camera_moved() -> bool:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return false
	var ct := cam.global_transform
	var st := global_transform
	var pr := cam.get_camera_projection()
	if ct.is_equal_approx(_link_cam) and st.is_equal_approx(_link_self) and pr == _link_proj:
		return false
	return true

## The pipe view in this effect's space: [clip Projection, right, up].
## Without a camera (headless), an orthographic view down -Z of the effect's
## own axes (OURS).
func _link_view() -> Array:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return [Projection.IDENTITY, Vector3.RIGHT, Vector3.UP]
	var gt := global_transform
	_link_cam = cam.global_transform
	_link_self = gt
	_link_proj = cam.get_camera_projection()
	var vp := _link_proj * Projection(cam.get_camera_transform().affine_inverse() * gt)
	var inv := gt.basis.inverse()
	var cb := cam.global_transform.basis.orthonormalized()
	return [vp, inv * cb.x, inv * cb.y]

## Every Link node's strips for this frame (see EfpLinks): one pass over
## the particles finds each emitter's oldest live one (link == null) and
## walks its chain; each node's chains go into one stitched strip.
func _update_links() -> void:
	if _links.is_empty():
		return
	link_updates += 1
	var frame := Engine.get_process_frames()
	if frame != _link_budget_frame:
		_link_budget_frame = frame
		_link_budget_left = LINK_TRIS_PER_FRAME
	if _link_budget_left <= 0:
		return
	var view := _link_view() if _has_pipe else [Projection.IDENTITY, Vector3.RIGHT, Vector3.UP]
	var vp: Projection = view[0]
	var right: Vector3 = view[1]
	var up: Vector3 = view[2]
	for d in _links:
		(d[3] as EfpLinks.Out).clear()
	for p in sim.particles:
		if p.link != null:
			continue
		var di: int = _link_tpls.get(p.tpl, -1)
		if di < 0:
			continue
		var d: Array = _links[di]
		var out: EfpLinks.Out = d[3]
		var a: EfpLinks.Buf = d[4]
		match int(d[6]):
			2:
				EfpLinks.gather_from(p, true, a)
				EfpLinks.obj_ribbon(a, out)
			1:
				EfpLinks.gather_from(p, false, a)
				var b: EfpLinks.Buf = d[5]
				EfpLinks.spline(a, b)
				if out.turn:
					EfpLinks.pipe_turn(b, out)
				else:
					EfpLinks.pipe_ribbon(b, vp, right, up, out)
			_:
				EfpLinks.gather_from(p, false, a)
				if out.turn:
					EfpLinks.pipe_turn(a, out)
				else:
					EfpLinks.pipe_ribbon(a, vp, right, up, out)
	for d in _links:
		if _link_budget_left <= 0:
			return
		var out: EfpLinks.Out = d[3]
		var am: ArrayMesh = (d[1] as MeshInstance3D).mesh
		am.clear_surfaces()
		if out.nv >= 3:
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLE_STRIP, out.arrays(), [], {}, out.format_flags())
		_link_budget_left -= out.triangles()

## Each Link node's live particles, one list per emitter, oldest first:
## the chains _update_links draws (each emitter's list from its head,
## link == null, along next_link; READ, see EfpLinks). `only` limits it to
## those tpl indices. tpl index -> Array of Array[EfpSim.Particle].
static func link_chains(s: EfpSim, only: Dictionary = {}) -> Dictionary:
	var out := {}
	for p in s.particles:
		if p.link != null or (not only.is_empty() and not only.has(p.tpl)):
			continue
		var chain: Array = []
		var q: EfpSim.Particle = p
		while q != null:
			chain.append(q)
			q = q.next_link
		if not out.has(p.tpl):
			out[p.tpl] = []
		(out[p.tpl] as Array).append(chain)
	return out

## Ends the effect now: every particle goes, and the node frees itself
## (READ: the interface's release, see the header).
func stop() -> void:
	loop = false
	if sim != null:
		sim.clear()
	_end()

func _end() -> void:
	if is_queued_for_deletion():
		return
	set_process(false)
	effect_finished.emit()
	if auto_free:
		queue_free()

## Keeps the effect on `host` (a body): each frame it takes the frame of the
## host's current skeleton, at `bone`'s position (none / unknown: the
## skeleton's origin) plus `offset`; without a skeleton, the host's origin
## plus `offset`. Its rotation is the skeleton's (OURS, see SkillEffects).
## The effect should be a child of `host`.
## Where the effect is placed in the world: its host's bone plus offset, as
## last placed (round 621: with a host the node itself stays at its anchor,
## so this, not global_position, is where the effect is).
func placed_at() -> Vector3:
	return _placed.origin if _anchored else global_position

## A turn applied at the attach point in the host's frame (round 720: an
## object's particle mod entry with a rotation, AmbientParticles), identity
## for every other effect.
var follow_basis := Basis.IDENTITY
## Placed at the bone's full transform rather than its origin (round 720's
## review: an object's mode-0 particle entry, CRTModParticle::FUN_00c81190
## 0xc811c5..0xc811e0 multiplies the bone's matrix by the world's).
var follow_bone_full := false
## The effect's own uniform scale on top of its host's (round 734): an
## equipment glow's particle row asks for col 3 / 100 (READ: CRTModParticle
## +0xc0, handed each placement to CEFEffect::vslot_010, which sets the
## effect's scale). 1 for every other effect.
var effect_scale := 1.0

func follow_host(host: Node3D, bone: String, offset: Vector3) -> void:
	_follow_host = host
	_follow_bone_name = bone
	_follow_offset = offset
	_follow_skel = null
	_place()

## The skeleton now carrying the host, re-found when the old one goes.
func _skeleton() -> Skeleton3D:
	if _follow_skel != null and is_instance_valid(_follow_skel) and not _follow_skel.is_queued_for_deletion() \
			and _follow_skel.is_inside_tree():
		return _follow_skel
	_follow_skel = SkillEffects.skeleton_of(_follow_host)
	_follow_bone = -1
	var b := _follow_bone_name.strip_edges()
	if _follow_skel != null and b != "" and b.to_lower() != "none" and b != "*" and not b.begins_with("#"):
		_follow_bone = _follow_skel.find_bone(b)
	return _follow_skel

## Places the effect on its host and hands the placement to the
## simulation (round 621, follow levels). Returns whether anything moved,
## so the caller redraws.
##
## The effect simulates in a space that does NOT move with its host -- as
## retail's does, in world units over the effect's scale (READ: the world
## matrix FUN_00cabda0 sets is scale only) -- and the host's motion reaches
## the simulation as the effect's placement (EfpSim.set_origin), which each
## node follows or not by its levels. This node is pinned (top_level) at an
## anchor whose basis is the host's SCALE only (its handedness kept, its
## facing not), so space-0 commands point along world axes and the facing
## arrives as the effect's rotation, as retail's SetMatrix hands it
## (CEFEffect::vslot_007). The anchor re-centres (EfpSim.shift) once the
## host is ANCHOR_RECENTRE away; a jump past ANCHOR_JUMP in one frame (a
## teleport, or the world re-based on a zone change) carries the whole
## effect along instead (OURS both).
func _place() -> bool:
	if _follow_host == null or not is_instance_valid(_follow_host):
		return false
	if not is_inside_tree():
		return false
	var skel := _skeleton()
	var placed: Transform3D
	if skel != null and skel.is_inside_tree():
		var at := _follow_offset
		if follow_bone_full and _follow_bone >= 0:
			placed = skel.global_transform * skel.get_bone_global_pose(_follow_bone) * Transform3D(follow_basis, at)
		else:
			if _follow_bone >= 0:
				at += skel.get_bone_global_pose(_follow_bone).origin
			placed = skel.global_transform * Transform3D(follow_basis, at)
	elif _follow_host.is_inside_tree():
		# No skeleton yet: the host's own frame, never a bare world position
		# (review: this node is top_level once anchored).
		placed = _follow_host.global_transform * Transform3D(follow_basis, _follow_offset)
	else:
		return false
	_placed = placed
	var redraw := false
	if not _anchored:
		_anchored = true
		_anchor = Transform3D(scale_basis(placed.basis) * effect_scale, placed.origin)
		top_level = true
	var e := _anchor.affine_inverse() * placed
	if e.origin.length() > ANCHOR_JUMP and sim != null:
		sim.shift(sim.origin())
		_anchor.origin = placed.origin
		e = _anchor.affine_inverse() * placed
		redraw = true
	elif e.origin.length() > ANCHOR_RECENTRE and sim != null:
		sim.shift(e.origin)
		_anchor.origin = placed.origin
		e = _anchor.affine_inverse() * placed
		redraw = true
	global_transform = _anchor
	if sim == null:
		return redraw
	return sim.set_origin(e.origin, e.basis.orthonormalized()) or redraw

## A basis's scale alone, its handedness kept (a mirrored basis keeps a
## negative Z), its rotation dropped.
static func scale_basis(b: Basis) -> Basis:
	var sc := Vector3(b.x.length(), b.y.length(), b.z.length())
	if b.determinant() < 0.0:
		sc.z = -sc.z
	return Basis.from_scale(sc)

func _process(delta: float) -> void:
	if sim == null:
		return
	_life += delta
	if max_life > 0.0 and _life >= max_life and loop:
		stop()
		return
	var t0 := Time.get_ticks_usec() if profile else 0
	var moved := _place()
	var t1 := Time.get_ticks_usec() if profile else 0
	var stepped := sim.advance(delta)
	if profile:
		prof["place"] += t1 - t0
		prof["sim"] += Time.get_ticks_usec() - t1
		prof["calls"] += 1
		prof["moved"] += 1 if moved else 0
		prof["steps"] += stepped
	# Finished -- nothing alive, no emitter spawning -- ends the effect, kept
	# or not (READ: CRTModParticle::FUN_00c80ff0 releases the effect when
	# CEFEffect::vslot_000 returns 0; round 620's restart of a finished kept
	# effect blinked every aura out once a cycle, round 623). A kept effect
	# does not finish: its root particles never die.
	if sim.finished():
		if loop and sim.dropped > 0:
			# OURS (round 623's review): the budget refused the kept effect's
			# root, so there is nothing to revive. Retail has no budget; a
			# kept aura retries its root each frame until the budget has room
			# rather than being lost for the rest of the buff.
			sim.restart()
		else:
			_end()
			return
	# OURS guard (round 623's review): a one-shot that never finishes by
	# itself. Retail hands a finished-with one-shot (keep 0) to its body's
	# list of leftover effects (CRTModParticle::FUN_00c80f60 ->
	# FUN_00c31f80), updates it there every frame and drops it only when it
	# finishes (CObjRendererVS::FUN_00c2a700) or the whole list is released
	# (FUN_00c2a670: the body's destructor FUN_00c323e0, and
	# CCompChar::FUN_00c33230 / FUN_00c33430 on an update whose third
	# argument is 0 -- what that argument means is OPEN). So retail plays
	# such an effect until its body goes; this client frees it with its
	# body too (the effect is the body's child) and ends it after
	# ONESHOT_MAX_LIFE besides, because a player's body lives all session.
	if not loop and _life >= ONESHOT_MAX_LIFE:
		stop()
		return
	# The MultiMeshes change only when the simulation stepped -- or, for a
	# billboarded node, when the camera turned (else it would lag the view).
	# (Round 621: also when the host moved the effect, whose followers the
	# placement pass moved this frame, or the space re-centred.)
	if stepped > 0 or moved or (_has_billboard and _camera_turned()):
		var t3 := Time.get_ticks_usec() if profile else 0
		_update_draws()
		if profile:
			prof["draws"] += Time.get_ticks_usec() - t3
			prof["draw_calls"] += 1
	# The Link strips likewise: after a step, or when the camera or the
	# effect moved for a screen-space pipe (round 621's review follow-up).
	if not _links.is_empty() and (stepped > 0 or moved or (_has_pipe and _link_camera_moved())):
		_update_links()
	if stepped > 0 and _qa_log():
		print("QA FXLOG %s frame %d particles %d drawn %d" % [path, sim.age, sim.particles.size(), drawn_particles()])

## Round 734: per-part timings of every effect's _process, microseconds,
## while `profile` is set (QA and tools only; off by default).
static var profile := false
static var prof := {"place": 0, "sim": 0, "draws": 0, "calls": 0, "moved": 0, "steps": 0, "draw_calls": 0}

## OPENSRO_QA_FXLOG=1 (round 623): every effect prints its particle and
## drawn counts after each simulation frame, so a render's frames can be
## matched to what was drawn.
static var _qa_log_state := -1
static func _qa_log() -> bool:
	if _qa_log_state < 0:
		_qa_log_state = 1 if OS.get_environment("OPENSRO_QA_FXLOG") != "" else 0
	return _qa_log_state == 1

## The particles this effect draws now: its drawn nodes' MultiMesh instances
## plus the live particles of its Link nodes.
func drawn_particles() -> int:
	var n := 0
	for d in _draws:
		n += (d[1] as MultiMeshInstance3D).multimesh.visible_instance_count
	if not _links.is_empty():
		for p in sim.particles:
			if _link_tpls.has(p.tpl):
				n += 1
	return n

## The world-space box of the drawn particles' centres (the QA log, round
## 722), or an empty AABB at the effect when none is drawn.
func particle_extent() -> AABB:
	var out := AABB(global_position, Vector3.ZERO)
	var first := true
	for d in _draws:
		var mmi := d[1] as MultiMeshInstance3D
		var mm := mmi.multimesh
		for i in range(mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count):
			var at := mmi.global_transform * mm.get_instance_transform(i).origin
			if first:
				out = AABB(at, Vector3.ZERO)
				first = false
			else:
				out = out.expand(at)
	return out

func _exit_tree() -> void:
	if sim != null:
		sim.clear()

func _camera_turned() -> bool:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return false
	var b := cam.global_transform.basis
	if b.is_equal_approx(_last_cam):
		return false
	_last_cam = b
	return true

## Round 741: an effect simulated once and drawn at many hosts, each turned
## by its own bone (EquipFx). The effect's frame turns with the host --
## CRTModParticle::FUN_00c81190 (READ) hands the effect the bone's whole
## matrix times the world's (`0xc811c5`: the bone object's +0x80 -> +0x40
## matrix, multiplied by the owner's world matrix through `0x55ebd0`), then
## CEFEffect::vslot_007 makes that the effect's placement -- so a holder's
## transform carries the bone's rotation. A billboard, though, must face the
## camera whatever the holder's turn, and the instances are shared: so for
## every ViewBillboard / ViewYBillboard plate or mesh node this switches the
## node to a shader that builds the billboard itself (OURS, the same READ
## basis: the camera's right, up -- or world up for YBillboard -- and look,
## EFP_FORMAT.md "Drawing"). The instance then carries only the particle's
## scale (its basis) and position, and its custom data the shape's rotation
## as a quaternion; the shader takes the scale from the instance matrix's
## column lengths (times the holder's uniform scale, which is in them too),
## turns the plate by the shape, lays it on the camera's axes and puts it at
## the instance's turned position. A negative particle scale would lose its
## sign there (none in the 16 enchant files: MEASURED, round 741).
##
## A node with a TextureSlide keeps the old path (its custom data is the UV
## rectangle), and with it the old fault: its billboards turn with the
## holder. No node of the 16 enchant files has one (MEASURED, round 741).
## Call once, after the effect is built.
func use_shared_turn() -> void:
	_has_billboard = false
	for d in _draws:
		var view := String(d[2])
		if view != "ViewBillboard" and view != "ViewYBillboard":
			continue
		if _slides(int(d[0])):
			_has_billboard = true
			continue
		var mmi := d[1] as MultiMeshInstance3D
		var m := mmi.material_override as ShaderMaterial
		if m == null or m.shader == null:
			_has_billboard = true
			continue
		var key := "%d|%s" % [m.get_instance_id(), view]
		if not _turn_materials.has(key):
			var c := m.duplicate() as ShaderMaterial
			c.shader = turn_shader(m.shader, view == "ViewYBillboard")
			_turn_materials[key] = c
		mmi.material_override = _turn_materials[key]
		while d.size() < 4:
			d.append(false)
		d[3] = true
	# The pipes (LinkPipe, LinkDPipe): their side is the camera's, so the
	# shader builds it per holder (EfpLinks.pipe_turn). LinkObj's side is the
	# particle's own Y axis (READ), which turns with the holder as it should.
	_has_pipe = false
	for l in _links:
		if int(l[6]) == 2:
			continue
		var mi := l[1] as MeshInstance3D
		var m := mi.material_override as ShaderMaterial
		if m == null or m.shader == null:
			_has_pipe = true
			continue
		var key := "%d|pipe" % m.get_instance_id()
		if not _turn_materials.has(key):
			var c := m.duplicate() as ShaderMaterial
			c.shader = pipe_turn_shader(m.shader)
			_turn_materials[key] = c
		mi.material_override = _turn_materials[key]
		(l[3] as EfpLinks.Out).turn = true
	shared_turn = true

## A shared-turn instance's custom data: the shape's rotation as a
## quaternion (x, y, z, w); its transform is the particle's scale and position.
static func turn_custom(p: EfpSim.Particle) -> Color:
	var q := p.shape.orthonormalized().get_rotation_quaternion()
	return Color(q.x, q.y, q.z, q.w)

## Whether use_shared_turn ran.
var shared_turn := false
static var _turn_materials: Dictionary = {} # "material id|view" -> ShaderMaterial

## Whether template node `tpl_index` runs a TextureSlide (its instances then
## carry their UV rectangle).
func _slides(tpl_index: int) -> bool:
	if sim == null or sim.template == null or tpl_index < 0 or tpl_index >= sim.template.tpls.size():
		return true
	for frame in sim.template.tpls[tpl_index].schedule:
		if frame is Array:
			for c in frame:
				if c is Array and not (c as Array).is_empty() and int(c[0]) == EfpSim.K_SLIDE:
					return true
	return false

## The billboard as the vertex shader builds it for a shared-turn node (see
## use_shared_turn): scale, then shape, then the view basis -- the camera's
## right, up (world up for YBillboard, READ) and look (-back, EfpEffect's
## view_basis) -- then the instance's position in the world.
const TURN_VERTEX := """void vertex() {
	vec3 srr_sc = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	vec4 srr_q = INSTANCE_CUSTOM;
	vec3 srr_v = VERTEX * srr_sc;
	srr_v = srr_v + 2.0 * cross(srr_q.xyz, cross(srr_q.xyz, srr_v) + srr_q.w * srr_v);
	vec3 srr_up = {UP};
	vec3 srr_w = MODEL_MATRIX[3].xyz + INV_VIEW_MATRIX[0].xyz * srr_v.x + srr_up * srr_v.y - INV_VIEW_MATRIX[2].xyz * srr_v.z;
	VERTEX = (VIEW_MATRIX * vec4(srr_w, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
}
"""

## A shared-turn pipe's vertex stage (EfpLinks.pipe_turn): the point's two
## neighbours (CUSTOM0.xyz, CUSTOM1.xyz) projected to normalised device
## coordinates by the camera drawing this holder, d = previous - next, and the
## side right * d.y - up * d.x (READ, EFEffect::FUN_00c8d0e0 through the
## billboard matrix's rows), normalised and scaled to the signed width
## (CUSTOM0.w) times the holder's own scale -- what pipe_ribbon computes in
## the effect's space, for one camera. The projection's off-centre terms
## cancel in the difference; its signs are dropped (abs) so a renderer whose
## projection flips Y draws the same side (OURS).
const PIPE_TURN_VERTEX := """void vertex() {
	mat4 srr_mv = VIEW_MATRIX * MODEL_MATRIX;
	vec3 srr_a = (srr_mv * vec4(CUSTOM0.xyz, 1.0)).xyz;
	vec3 srr_b = (srr_mv * vec4(CUSTOM1.xyz, 1.0)).xyz;
	bool srr_ortho = PROJECTION_MATRIX[3][3] > 0.5;
	float srr_wa = srr_ortho ? 1.0 : max(-srr_a.z, 1e-4);
	float srr_wb = srr_ortho ? 1.0 : max(-srr_b.z, 1e-4);
	vec2 srr_k = vec2(abs(PROJECTION_MATRIX[0][0]), abs(PROJECTION_MATRIX[1][1]));
	vec2 srr_d = srr_k * srr_a.xy / srr_wa - srr_k * srr_b.xy / srr_wb;
	vec3 srr_side = INV_VIEW_MATRIX[0].xyz * srr_d.y - INV_VIEW_MATRIX[1].xyz * srr_d.x;
	float srr_l = length(srr_side);
	float srr_s = length(MODEL_MATRIX[0].xyz);
	vec3 srr_w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (srr_l > 0.0) {
		srr_w += srr_side * (CUSTOM0.w * srr_s / srr_l);
	}
	VERTEX = (VIEW_MATRIX * vec4(srr_w, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
}
"""

## A link shader with its vertex stage replaced by PIPE_TURN_VERTEX.
static func pipe_turn_shader(sh: Shader) -> Shader:
	var key := "pipeturn|%d" % sh.get_instance_id()
	if _shaders.has(key):
		return _shaders[key]
	var out := _with_vertex(sh, PIPE_TURN_VERTEX)
	_shaders[key] = out
	return out

## `sh`'s code with its `void vertex() { ... }` replaced by `vertex_code` and
## `skip_vertex_transform` added (the stage writes view-space VERTEX).
static func _with_vertex(sh: Shader, vertex_code: String) -> Shader:
	var code := sh.code
	var at := code.find("void vertex() {")
	var end := code.find("}", at)
	if at < 0 or end < 0:
		return sh
	code = code.substr(0, at) + vertex_code + code.substr(end + 1)
	code = code.replace("render_mode unshaded,", "render_mode unshaded, skip_vertex_transform,")
	var out := Shader.new()
	out.code = code
	for m in sh.get_meta_list():
		out.set_meta(m, sh.get_meta(m))
	return out

## `sh` (a template shader) with its vertex stage replaced by TURN_VERTEX.
static func turn_shader(sh: Shader, y_billboard: bool) -> Shader:
	var key := "turn|%d|%s" % [sh.get_instance_id(), str(y_billboard)]
	if _shaders.has(key):
		return _shaders[key]
	var out := _with_vertex(sh, TURN_VERTEX.replace("{UP}", "vec3(0.0, 1.0, 0.0)" if y_billboard else "INV_VIEW_MATRIX[1].xyz"))
	_shaders[key] = out
	return out

## Writes every drawn node's particles into its MultiMesh.
func _update_draws() -> void:
	draw_updates += 1
	if _draws.is_empty():
		return
	var cam_rot := Basis.IDENTITY
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		cam_rot = global_transform.basis.orthonormalized().inverse() * cam.global_transform.basis.orthonormalized()
	var by_tpl: Dictionary = {}
	for p in sim.particles:
		if not by_tpl.has(p.tpl):
			by_tpl[p.tpl] = []
		(by_tpl[p.tpl] as Array).append(p)
	for d in _draws:
		var mmi: MultiMeshInstance3D = d[1]
		var mm := mmi.multimesh
		var ps: Array = by_tpl.get(int(d[0]), [])
		if ps.size() > mm.instance_count:
			mm.instance_count = maxi(ps.size(), mm.instance_count * 2)
		mm.visible_instance_count = ps.size()
		if d.size() > 3 and bool(d[3]):
			# A shared-turn node (use_shared_turn): the shader billboards, so
			# the instance carries only the particle's scale and position
			# and, in its custom data, the shape's rotation.
			for i in range(ps.size()):
				var p: EfpSim.Particle = ps[i]
				mm.set_instance_transform(i, Transform3D(Basis.from_scale(p.scale), p.pos))
				mm.set_instance_color(i, EfpSim.color_of(p.color))
				mm.set_instance_custom_data(i, turn_custom(p))
			continue
		for i in range(ps.size()):
			var p: EfpSim.Particle = ps[i]
			mm.set_instance_transform(i, particle_transform(p, String(d[2]), cam_rot))
			mm.set_instance_color(i, EfpSim.color_of(p.color))
			mm.set_instance_custom_data(i, Color(p.uv.x, p.uv.y, p.uv.z, p.uv.w))

## A particle's transform in the effect's space (READ order: scale, shape,
## view, then position; see the header).
static func particle_transform(p: EfpSim.Particle, view: String, cam_rot: Basis) -> Transform3D:
	var v := view_basis(p, view, cam_rot)
	return Transform3D(v * p.shape * Basis.from_scale(p.scale), p.pos)

## `cam_rot` is the camera's rotation in the effect's space. The billboard
## bases are the inverse view's rows as columns: right, up, look (= -back);
## YBillboard with its up forced to (0, 1, 0) (READ, CEFSystem::FUN_00cb0ee0).
static func view_basis(p: EfpSim.Particle, view: String, cam_rot: Basis) -> Basis:
	match view:
		"ViewBillboard":
			return Basis(cam_rot.x, cam_rot.y, -cam_rot.z)
		"ViewYBillboard":
			return Basis(cam_rot.x, Vector3.UP, -cam_rot.z)
		"ViewVBillboard":
			if p.vel.length_squared() < 1e-12:
				return Basis.IDENTITY
			var y := p.vel.normalized()
			var zc := y.cross(Vector3.UP)
			if zc.length_squared() < 1e-12:
				return Basis.IDENTITY
			var zn := zc.normalized()
			return Basis(y.cross(zn), y, zn)
	return p.rot

# ---------------------------------------------------------------- blending

## The Godot blend for a node's D3D src/dest pair (D3DBLEND: 1 ZERO, 2 ONE,
## 5 SRCALPHA, 6 INVSRCALPHA, 12 BOTHSRCALPHA):
##   "add"      SRCALPHA/ONE -> BLEND_MODE_ADD (exact: Godot adds src*alpha)
##   "add_one"  ONE/ONE -> BLEND_MODE_ADD with alpha forced to 1 (exact)
##   "mix"      SRCALPHA/INVSRCALPHA, and BOTHSRCALPHA (which means that pair)
##              -> BLEND_MODE_MIX (exact)
##   "darken"   ZERO/INVSRCALPHA -> MIX with a black colour (exact:
##              dst*(1-a))
##   "other"    anything else -> MIX (OURS, approximate; 30 retail files use
##              other pairs, MEASURED round 619). Godot 4.2's spatial shaders
##              have no premultiplied blend, so ONE/INVSRCALPHA is here too.
static func blend_class(src: int, dest: int) -> String:
	if src == 12:
		return "mix"
	if src == 5 and dest == 2:
		return "add"
	if src == 2 and dest == 2:
		return "add_one"
	if src == 5 and dest == 6:
		return "mix"
	if src == 1 and dest == 6:
		return "darken"
	return "other"

## The Godot blend mode a class draws with.
static func godot_blend(cls: String) -> int:
	match cls:
		"add", "add_one":
			return BaseMaterial3D.BLEND_MODE_ADD
	return BaseMaterial3D.BLEND_MODE_MIX

## D3DCULL 1 NONE draws both faces; 3 CCW (the loader turns 2 into 3) culls
## back faces -- BmsReader reverses the .bms winding so Godot's front faces
## are D3D's (INFERRED from that fix).
static func cull_disabled(cull: int) -> bool:
	return cull <= 1

static func material_for(tex: Texture2D, st: EfpReader.EfpRenderState, billboard: bool = false) -> ShaderMaterial:
	var src := st.src_blend if st != null else 5
	var dest := st.dest_blend if st != null else 2
	var cls := blend_class(src, dest)
	var no_cull := billboard or cull_disabled(st.cull if st != null else 1)
	var skey := "%s|%s" % [cls, str(no_cull)]
	var key := "%d|%s|%d,%d,%d,%d,%d,%d" % [tex.get_instance_id() if tex != null else 0, skey,
		st.color_op if st else 4, st.color_arg1 if st else 2, st.color_arg2 if st else 0,
		st.alpha_op if st else 4, st.alpha_arg1 if st else 2, st.alpha_arg2 if st else 0]
	if _materials.has(key):
		return _materials[key]
	var m := ShaderMaterial.new()
	m.shader = _shader(cls, no_cull)
	m.set_shader_parameter("tex", tex)
	m.set_shader_parameter("c_op", st.color_op if st else 4)
	m.set_shader_parameter("c_a1", st.color_arg1 if st else 2)
	m.set_shader_parameter("c_a2", st.color_arg2 if st else 0)
	m.set_shader_parameter("a_op", st.alpha_op if st else 4)
	m.set_shader_parameter("a_a1", st.alpha_arg1 if st else 2)
	m.set_shader_parameter("a_a2", st.alpha_arg2 if st else 0)
	_materials[key] = m
	return m

## A Link strip's material: the node's blend, texture ops and cull as for a
## plate (the node's cull, render block +0x1a4, applies to its strips; see
## EfpLinks for the winding), with the strip's own UVs.
static func link_material_for(tex: Texture2D, st: EfpReader.EfpRenderState) -> ShaderMaterial:
	var src := st.src_blend if st != null else 5
	var dest := st.dest_blend if st != null else 2
	var cls := blend_class(src, dest)
	var no_cull := cull_disabled(st.cull if st != null else 1)
	var key := "link|%d|%s|%s|%d,%d,%d,%d,%d,%d" % [tex.get_instance_id() if tex != null else 0, cls, str(no_cull),
		st.color_op if st else 4, st.color_arg1 if st else 2, st.color_arg2 if st else 0,
		st.alpha_op if st else 4, st.alpha_arg1 if st else 2, st.alpha_arg2 if st else 0]
	if _materials.has(key):
		return _materials[key]
	var m := ShaderMaterial.new()
	m.shader = _shader(cls, no_cull, true)
	m.set_shader_parameter("tex", tex)
	m.set_shader_parameter("c_op", st.color_op if st else 4)
	m.set_shader_parameter("c_a1", st.color_arg1 if st else 2)
	m.set_shader_parameter("c_a2", st.color_arg2 if st else 0)
	m.set_shader_parameter("a_op", st.alpha_op if st else 4)
	m.set_shader_parameter("a_a1", st.alpha_arg1 if st else 2)
	m.set_shader_parameter("a_a2", st.alpha_arg2 if st else 0)
	_materials[key] = m
	return m

## The instance UV rectangle a plate or mesh applies (the draw routines' u0 +
## u*du, READ); a Link strip writes its own u, v and applies none (READ).
const UVMAP_INSTANCE := "UV = INSTANCE_CUSTOM.xy + UV * INSTANCE_CUSTOM.zw;"

static func _shader(cls: String, no_cull: bool, link: bool = false) -> Shader:
	var key := "%s|%s|%s" % [cls, str(no_cull), "link" if link else "inst"]
	if _shaders.has(key):
		return _shaders[key]
	var blend := "blend_mix"
	match godot_blend(cls):
		BaseMaterial3D.BLEND_MODE_ADD:
			blend = "blend_add"
	var sh := Shader.new()
	sh.code = SHADER_TEMPLATE.replace("{BLEND}", blend) \
		.replace("{CULL}", "cull_disabled" if no_cull else "cull_back") \
		.replace("{FORCE_ALPHA_ONE}", "true" if cls == "add_one" else "false") \
		.replace("{DARKEN}", "true" if cls == "darken" else "false") \
		.replace("{UVMAP}", "" if link else UVMAP_INSTANCE) \
		.replace("{DECODE}", ShaderColour.DECODE_ALBEDO) \
		.replace("\nvoid fragment() {", ShaderColour.DECODE_FN + "\nvoid fragment() {")
	sh.set_meta(BLEND_CLASS_META, cls)
	_shaders[key] = sh
	return sh

## Stage 0 of the fixed-function pipeline the client sets up: each op takes
## its two arguments (D3DTA 0 DIFFUSE = the particle colour, 2 TEXTURE); ops
## 2 SELECTARG1, 3 SELECTARG2, 4 MODULATE, 5 MODULATE2X, 6 MODULATE4X, 7 ADD
## (D3DTOP). Anything else is taken as MODULATE (OURS).
const SHADER_TEMPLATE := """shader_type spatial;
render_mode unshaded, {BLEND}, {CULL}, depth_draw_never, fog_disabled, shadows_disabled;
// Raw, and the result decoded where the output is linear: the stage
// arithmetic is D3D's, in display values, under both renderers (ShaderColour,
// round 693).
uniform sampler2D tex : filter_linear_mipmap, repeat_enable;
uniform int c_op = 4;
uniform int c_a1 = 2;
uniform int c_a2 = 0;
uniform int a_op = 4;
uniform int a_a1 = 2;
uniform int a_a2 = 0;

vec4 arg(int which, vec4 t, vec4 d) {
	return which == 2 ? t : d;
}

vec4 op(int o, vec4 a, vec4 b) {
	if (o == 2) return a;
	if (o == 3) return b;
	if (o == 5) return a * b * 2.0;
	if (o == 6) return a * b * 4.0;
	if (o == 7) return a + b;
	return a * b;
}

void vertex() {
	{UVMAP}
}

void fragment() {
	vec4 t = texture(tex, UV);
	vec4 d = COLOR;
	vec3 c = op(c_op, arg(c_a1, t, d), arg(c_a2, t, d)).rgb;
	float a = op(a_op, arg(a_a1, t, d), arg(a_a2, t, d)).a;
	if ({FORCE_ALPHA_ONE}) a = 1.0;
	if ({DARKEN}) c = vec3(0.0);
	ALBEDO = clamp(c, 0.0, 1.0);
	{DECODE}
	ALPHA = clamp(a, 0.0, 1.0);
}
"""

# ---------------------------------------------------------------- assets

static func _texture(p: String, particles: Pk2Reader) -> Texture2D:
	var key := p.to_lower()
	if _textures.has(key):
		_touch("x", key)
		return _textures[key]
	var img: Image = null
	_mutex.lock()
	var pre := _images.has(key)
	if pre:
		img = _images[key]
		_images.erase(key)
	_mutex.unlock()
	if not pre:
		img = _decode_image(p, particles)
	var tex: Texture2D = ImageTexture.create_from_image(img) if img != null else null
	_textures[key] = tex
	_touch("x", key)
	_evict()
	return tex

static func _decode_image(p: String, particles: Pk2Reader) -> Image:
	var bytes := AssetSource.read_bytes(p, particles)
	if bytes.is_empty():
		return null
	var parsed := DdjReader.parse(bytes)
	return DdjReader.to_image(parsed) if parsed != null else null

static func _mesh(p: String, particles: Pk2Reader) -> ArrayMesh:
	var key := p.to_lower()
	if _meshes.has(key):
		_touch("m", key)
		return _meshes[key]
	var arrays = null
	_mutex.lock()
	var pre := _mesh_arrays.has(key)
	if pre:
		arrays = _mesh_arrays[key]
		_mesh_arrays.erase(key)
	_mutex.unlock()
	if not pre:
		arrays = _decode_mesh(p, particles)
	var mesh: ArrayMesh = BmsReader.mesh_from_arrays(arrays) if arrays is Array else null
	_meshes[key] = mesh
	_touch("m", key)
	_evict()
	return mesh

static func _decode_mesh(p: String, particles: Pk2Reader):
	var bytes := AssetSource.read_bytes(p, particles)
	if bytes.is_empty():
		return null
	var parsed := BmsReader.parse(bytes)
	if parsed == null or parsed.vertex_count() == 0:
		return null
	return BmsReader.to_arrays(parsed)

## Decodes these .efp files and their meshes and textures on a
## WorkerThreadPool task, so their first create() on a cast does not decode
## on the main thread (the review measured 661 ms for the worst cold file).
## The task only produces plain data (templates, Images, mesh arrays); the
## resources are made on first use. Returns the task id, or -1 with nothing
## to do.
static func preload_paths(paths: PackedStringArray, particles: Pk2Reader) -> int:
	if particles == null:
		return -1
	var todo := PackedStringArray()
	_mutex.lock()
	for p in paths:
		if not _templates.has(p.to_lower()) and not todo.has(p):
			todo.append(p)
	_mutex.unlock()
	if todo.is_empty():
		return -1
	var id := WorkerThreadPool.add_task(_preload_task.bind(todo, particles), false, "efp preload")
	_preloads.append(id)
	return id

static func _preload_task(paths: PackedStringArray, particles: Pk2Reader) -> void:
	for p in paths:
		var err := []
		var t := _decode_template(p, particles, err)
		_mutex.lock()
		if not _templates.has(p.to_lower()):
			_templates[p.to_lower()] = t
		_mutex.unlock()
		if t == null:
			continue
		for tp in t.tpls:
			var n: EfpReader.EfpNode = tp.node
			var mode := n.render_mode()
			if (mode != PLATE and mode != MESH) or n.meshes.is_empty():
				continue
			var ref: EfpReader.EfpMeshRef = n.meshes[0]
			if not ref.textures.is_empty():
				var tk := ref.textures[0].to_lower()
				_mutex.lock()
				var need := not _textures.has(tk) and not _images.has(tk)
				_mutex.unlock()
				if need:
					var img := _decode_image(ref.textures[0], particles)
					_mutex.lock()
					_images[tk] = img
					_mutex.unlock()
			if mode == MESH and ref.mesh != "":
				var mk := ref.mesh.to_lower()
				_mutex.lock()
				var needm := not _meshes.has(mk) and not _mesh_arrays.has(mk)
				_mutex.unlock()
				if needm:
					var arr = _decode_mesh(ref.mesh, particles)
					_mutex.lock()
					_mesh_arrays[mk] = arr
					_mutex.unlock()

## Whether `efp_path`'s template is decoded (or known not to decode).
static func has_template(efp_path: String) -> bool:
	_mutex.lock()
	var have := _templates.has(efp_path.to_lower())
	_mutex.unlock()
	return have

## Waits for every preload task (tests; a world teardown).
static func wait_preloads() -> void:
	for id in _preloads:
		WorkerThreadPool.wait_for_task_completion(id)
	_preloads.clear()

static func _touch(kind: String, key: String) -> void:
	_stamp += 1
	_used[kind + "|" + key] = _stamp

## Drops the least recently used entries past each bound (OURS). A texture
## that goes takes the materials made with it.
static func _evict() -> void:
	_evict_kind("t", _templates, CACHE_TEMPLATES)
	_evict_kind("x", _textures, CACHE_TEXTURES)
	_evict_kind("m", _meshes, CACHE_MESHES)

static func _evict_kind(kind: String, cache: Dictionary, bound: int) -> void:
	if cache.size() <= bound:
		return
	var keys := cache.keys()
	keys.sort_custom(func(a, b): return int(_used.get(kind + "|" + String(a), 0)) < int(_used.get(kind + "|" + String(b), 0)))
	var n := cache.size() - bound
	_mutex.lock()
	for i in range(n):
		var k = keys[i]
		if kind == "x" and cache[k] != null:
			var prefix := "%d|" % (cache[k] as Texture2D).get_instance_id()
			for mk in _materials.keys():
				if String(mk).begins_with(prefix):
					_materials.erase(mk)
		cache.erase(k)
		_used.erase(kind + "|" + String(k))
	_mutex.unlock()

## How many entries each cache holds (tests, logs).
static func cache_sizes() -> Dictionary:
	return {"templates": _templates.size(), "textures": _textures.size(), "meshes": _meshes.size(),
		"materials": _materials.size()}

## Empties the shared caches (tests, and a world reload).
static func clear_caches() -> void:
	wait_preloads()
	_mutex.lock()
	_templates.clear()
	_textures.clear()
	_meshes.clear()
	_materials.clear()
	_shaders.clear()
	_turn_materials.clear()
	_images.clear()
	_mesh_arrays.clear()
	_used.clear()
	_mutex.unlock()
