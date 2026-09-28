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
##   position (row vectors): ViewNone uses the particle's rotation,
##   ViewBillboard and ViewYBillboard the camera matrices at 0x00edbde8 and
##   0x00edbe28 (INFERRED: the camera-facing and the upright-camera-facing
##   billboard, by name), ViewVBillboard a basis whose Y axis is the
##   particle's velocity and whose Z is velocity x up (the case-3 branch).
## - The blend: the node's 36-byte D3D state (src/dest blend, colour and alpha
##   texture ops), ZWRITE off, lighting and fog off. See blend_class and the
##   shader below for the mapping to Godot.
##
## Not drawn (OPEN; counted as `skipped` by the census): RenderLinkPipe,
## RenderLinkDPipe and RenderLinkObj (the trails; their routines were not
## read), and a node whose mesh or texture does not load. (BSAnimation needs
## no drawing: all 3,230 nodes carrying one are RenderNone, MEASURED; their
## motion reaches particles as the baked SetBANPos/SetBANRot keys.)
## Only the first mesh entry and its first texture are drawn (OURS).
##
## The effect is simulated in its own local space and moves with its parent
## node (OURS). It is authored in the game's native units, so it belongs
## under the character's skeleton, which carries the native-to-world scale.

signal effect_finished

## AT_LOOP: start over whenever the effect ends, until stopped.
var loop := false
## Free the node when the effect ends (and loop is off).
var auto_free := true
var path := ""
var sim: EfpSim
var skipped: PackedStringArray = PackedStringArray()
## Seconds after which a looping effect stops by itself (0 = never; OURS guard).
var max_life := 0.0
var _draws: Array = [] # of [tpl index, MultiMeshInstance3D, view mode]
var _stopping := false
var _life := 0.0
var _follow_skel: Skeleton3D = null
var _follow_bone := -1
var _follow_offset := Vector3.ZERO

# Shared caches: one decode and one compiled template per file, one texture
# and mesh per asset path, one material per (texture, state).
static var _templates: Dictionary = {} # path -> EfpSim.Template, or null when it failed
static var _textures: Dictionary = {} # path -> Texture2D or null
static var _meshes: Dictionary = {} # path -> ArrayMesh or null
static var _materials: Dictionary = {} # key -> ShaderMaterial
static var _shaders: Dictionary = {} # key -> Shader
static var last_error := ""

const PLATE := "RenderPlate"
const MESH := "RenderMesh"
## OURS: particles move; a fixed box keeps a MultiMesh from being culled.
const DRAW_AABB := AABB(Vector3(-200, -200, -200), Vector3(400, 400, 400))

## The compiled template of a file in Particles.pk2, decoded once.
static func template_for(efp_path: String, particles: Pk2Reader) -> EfpSim.Template:
	var key := efp_path.to_lower()
	if _templates.has(key):
		return _templates[key]
	var t: EfpSim.Template = null
	var data := AssetSource.read_bytes(efp_path, particles)
	if data.is_empty():
		last_error = "not found"
	else:
		var f := EfpReader.decode(data)
		if f == null:
			last_error = EfpReader.last_error
		else:
			t = EfpSim.compile(f.root)
	_templates[key] = t
	return t

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
	for u in t.unsupported:
		fx.skipped.append("command " + u)
	for tp in t.tpls:
		var n: EfpReader.EfpNode = tp.node
		var mode := n.render_mode()
		if mode == "" or mode == "RenderNone":
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
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = mesh
		mm.instance_count = 0
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = material_for(tex, n.state)
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.custom_aabb = DRAW_AABB
		mmi.name = "node_%d" % tp.index
		fx.add_child(mmi)
		fx._draws.append([tp.index, mmi, n.view_mode()])
	return fx

## How many nodes draw.
func draw_count() -> int:
	return _draws.size()

## Lets a looping effect finish its current cycle and end.
func stop() -> void:
	loop = false
	_stopping = true

## Keeps the effect at a bone's position (plus `offset`) of the skeleton it
## is a child of; its rotation stays the skeleton's (OURS, see SkillEffects).
func follow(skel: Skeleton3D, bone: int, offset: Vector3) -> void:
	_follow_skel = skel
	_follow_bone = bone
	_follow_offset = offset
	_place()

func _place() -> void:
	if _follow_skel != null and is_instance_valid(_follow_skel) and _follow_bone >= 0:
		position = _follow_skel.get_bone_global_pose(_follow_bone).origin + _follow_offset

func _process(delta: float) -> void:
	if sim == null:
		return
	_life += delta
	if max_life > 0.0 and _life >= max_life and loop:
		stop()
	_place()
	sim.advance(delta)
	if sim.finished():
		if loop and not _stopping:
			sim.restart()
		else:
			effect_finished.emit()
			if auto_free:
				queue_free()
			set_process(false)
			return
	_update_draws()

func _exit_tree() -> void:
	if sim != null:
		sim.clear()

## Writes every drawn node's particles into its MultiMesh.
func _update_draws() -> void:
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

static func view_basis(p: EfpSim.Particle, view: String, cam_rot: Basis) -> Basis:
	match view:
		"ViewBillboard":
			return cam_rot
		"ViewYBillboard":
			var z := cam_rot.z
			z.y = 0.0
			if z.length_squared() < 1e-8:
				return Basis.IDENTITY
			z = z.normalized()
			return Basis(Vector3.UP.cross(z), Vector3.UP, z)
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

static func material_for(tex: Texture2D, st: EfpReader.EfpRenderState) -> ShaderMaterial:
	var src := st.src_blend if st != null else 5
	var dest := st.dest_blend if st != null else 2
	var cls := blend_class(src, dest)
	var no_cull := cull_disabled(st.cull if st != null else 1)
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

static func _shader(cls: String, no_cull: bool) -> Shader:
	var key := "%s|%s" % [cls, str(no_cull)]
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
		.replace("{DARKEN}", "true" if cls == "darken" else "false")
	_shaders[key] = sh
	return sh

## Stage 0 of the fixed-function pipeline the client sets up: each op takes
## its two arguments (D3DTA 0 DIFFUSE = the particle colour, 2 TEXTURE); ops
## 2 SELECTARG1, 3 SELECTARG2, 4 MODULATE, 5 MODULATE2X, 6 MODULATE4X, 7 ADD
## (D3DTOP). Anything else is taken as MODULATE (OURS).
const SHADER_TEMPLATE := """shader_type spatial;
render_mode unshaded, {BLEND}, {CULL}, depth_draw_never, fog_disabled, shadows_disabled;
uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_enable;
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
	UV = INSTANCE_CUSTOM.xy + UV * INSTANCE_CUSTOM.zw;
}

void fragment() {
	vec4 t = texture(tex, UV);
	vec4 d = COLOR;
	vec3 c = op(c_op, arg(c_a1, t, d), arg(c_a2, t, d)).rgb;
	float a = op(a_op, arg(a_a1, t, d), arg(a_a2, t, d)).a;
	if ({FORCE_ALPHA_ONE}) a = 1.0;
	if ({DARKEN}) c = vec3(0.0);
	ALBEDO = clamp(c, 0.0, 1.0);
	ALPHA = clamp(a, 0.0, 1.0);
}
"""

# ---------------------------------------------------------------- assets

static func _texture(p: String, particles: Pk2Reader) -> Texture2D:
	var key := p.to_lower()
	if _textures.has(key):
		return _textures[key]
	var tex: Texture2D = null
	var bytes := AssetSource.read_bytes(p, particles)
	if not bytes.is_empty():
		var parsed := DdjReader.parse(bytes)
		if parsed != null:
			tex = DdjReader.to_texture(parsed)
	_textures[key] = tex
	return tex

static func _mesh(p: String, particles: Pk2Reader) -> ArrayMesh:
	var key := p.to_lower()
	if _meshes.has(key):
		return _meshes[key]
	var mesh: ArrayMesh = null
	var bytes := AssetSource.read_bytes(p, particles)
	if not bytes.is_empty():
		var parsed := BmsReader.parse(bytes)
		if parsed != null and not parsed.vertices.is_empty():
			mesh = BmsReader.to_array_mesh(parsed)
	_meshes[key] = mesh
	return mesh

## Empties the shared caches (tests, and a world reload).
static func clear_caches() -> void:
	_templates.clear()
	_textures.clear()
	_meshes.clear()
	_materials.clear()
	_shaders.clear()
