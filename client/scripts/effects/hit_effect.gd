extends Node3D
class_name HitEffect

## The brief slash burst played on a target when a skill lands.
##
## WHAT IS REAL: the meshes and textures. They are the retail client's own
## critical-hit particle primitives, read out of `hiteffect\hit_3_critical.efp`
## (Particles.pk2) by walking the effect's RenderMesh node stream on the RE box
## (each RenderMesh names a `meshes\*.bms` and the `textures\*.ddj` it pairs
## with -- the same recovery LevelUpEffect used). They are loaded at runtime
## from the player's own Particles.pk2 and never committed (BYO-assets rule).
##
##   demagecutwon-01-m.bms  <- demage.ddj             (the round slash flash)
##   light-line-m.bms       <- gumsang-i-01.ddj       (the bright slash streak)
##   demagecutcorn-01.bms   <- sdamage-i-01.ddj       (the corner spark cut)
##
## WHAT IS DESIGNED (disclosed, per "never present a guessed value as real"):
## the ANIMATION -- the ~0.4s pop-and-fade timing, the per-layer scale/tilt,
## and the additive intensity caps are this project's own approximation of the
## effect's recovered *character* (a fast additive slash burst), NOT the .efp's
## real per-keyframe ScaleGraph/DiffuseGraph curves, which the flat EFP reader
## does not reliably recover (see LevelUpEffect and docs/protocol/EFP_FORMAT.md).
## Only the size is data-driven: layers are normalized to the target's own
## rendered height, not a magic scale.

## One real mesh layer: the mesh, its paired texture, and this project's
## designed animation columns for it.
class Layer:
	var mesh_path: String
	var texture_path: String
	## Size as a fraction of the burst height.
	var size_frac: float
	## Fixed tilt (degrees about X) so the flat slash cards read in 3D.
	var tilt_deg: float
	## Peak additive alpha (0..1); capped so the stacked layers don't saturate.
	var intensity: float

	func _init(mesh: String, tex: String, sf: float, tilt: float, intens: float) -> void:
		mesh_path = mesh
		texture_path = tex
		size_frac = sf
		tilt_deg = tilt
		intensity = intens

## The real hit_3_critical layers, in draw order (streak last so it reads on
## top). The animation columns are designed -- see the class comment.
const LAYERS := [
	["meshes\\demagecutwon-01-m.bms", "textures\\demage.ddj", 0.9, 12.0, 0.7],
	["meshes\\demagecutcorn-01.bms", "textures\\sdamage-i-01.ddj", 1.0, -20.0, 0.55],
	["meshes\\light-line-m.bms", "textures\\gumsang-i-01.ddj", 1.1, 40.0, 0.85],
]

## Total lifetime of the burst, seconds. Designed -- a hit is quick.
const LIFE := 0.42
## The burst is sized to this multiple of the target's world height. Designed.
const HEIGHT_MULTIPLE := 0.55

var _t := 0.0
var _layers: Array = [] # of {node, base_scale}
var _finished := false

## Builds the burst from the player's real Particles.pk2, sized to
## target_world_height. The caller positions this node at the target (its
## origin sits at the burst's centre). Returns null if the archive is missing
## or not one real mesh loaded -- the caller then shows no visual rather than a
## fabricated one.
static func create(particles: Pk2Reader, target_world_height: float) -> HitEffect:
	if particles == null:
		return null
	var fx := HitEffect.new()
	var burst: float = maxf(target_world_height, 1.0) * HEIGHT_MULTIPLE
	for row in LAYERS:
		var layer := Layer.new(row[0], row[1], row[2], row[3], row[4])
		var node := _build_layer(particles, layer, burst)
		if node == null:
			continue
		fx.add_child(node)
		fx._layers.append({"node": node, "base_scale": node.scale})
	if fx._layers.is_empty():
		fx.free()
		return null
	return fx

## Builds one real mesh layer, centred on the effect origin (unlike the
## level-up burst which sits on the ground): a hit lands on the body, so the
## slash cards centre on the target's mid-height.
static func _build_layer(particles: Pk2Reader, layer: Layer, burst: float) -> MeshInstance3D:
	var mesh_bytes := AssetSource.read_bytes(layer.mesh_path, particles)
	if mesh_bytes.is_empty():
		return null
	var parsed := BmsReader.parse(mesh_bytes)
	if parsed == null or parsed.vertices.is_empty():
		return null
	var array_mesh := BmsReader.to_array_mesh(parsed)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	# A hit flash lands ON the target, so it draws over the body rather than
	# being occluded by it (the effect origin sits inside the target mesh).
	mat.no_depth_test = true
	mat.vertex_color_use_as_albedo = true
	var tex := _load_texture(particles, layer.texture_path)
	if tex != null:
		mat.albedo_texture = tex
	array_mesh.surface_set_material(0, mat)

	var mi := MeshInstance3D.new()
	mi.mesh = array_mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.material_override = mat

	# Normalize by the mesh's own native height so no per-mesh scale is
	# hardcoded, then centre the mesh's own bounds on the origin.
	var native_h: float = maxf(parsed.bounds_max.y - parsed.bounds_min.y, 0.001)
	var s: float = (burst * layer.size_frac) / native_h
	mi.scale = Vector3(s, s, s)
	var cx: float = (parsed.bounds_min.x + parsed.bounds_max.x) * 0.5
	var cy: float = (parsed.bounds_min.y + parsed.bounds_max.y) * 0.5
	var cz: float = (parsed.bounds_min.z + parsed.bounds_max.z) * 0.5
	mi.position = Vector3(-cx * s, -cy * s, -cz * s)
	mi.rotation.x = deg_to_rad(layer.tilt_deg)
	return mi

static func _load_texture(particles: Pk2Reader, path: String) -> Texture2D:
	var bytes := AssetSource.read_bytes(path, particles)
	if bytes.is_empty():
		return null
	var parsed := DdjReader.parse(bytes)
	if parsed == null:
		return null
	return DdjReader.to_texture(parsed)

func _process(delta: float) -> void:
	if _finished:
		return
	_t += delta
	var u: float = clampf(_t / LIFE, 0.0, 1.0)
	# Scale: a fast pop past full then ease back -- a slash snaps out.
	var scale_mul: float
	if u < 0.30:
		scale_mul = lerpf(0.3, 1.25, _ease_out(u / 0.30))
	else:
		scale_mul = lerpf(1.25, 1.0, (u - 0.30) / 0.70)
	# Fade: in over the first 20%, out over the last 55%.
	var a: float
	if u < 0.20:
		a = u / 0.20
	elif u > 0.45:
		a = clampf((1.0 - u) / 0.55, 0.0, 1.0)
	else:
		a = 1.0
	for i in range(_layers.size()):
		var entry: Dictionary = _layers[i]
		var node: Node3D = entry["node"]
		var base: Vector3 = entry["base_scale"]
		node.scale = base * scale_mul
		var intensity: float = LAYERS[i][4]
		_set_alpha(node, a * intensity)
	if _t >= LIFE:
		_finished = true
		queue_free()

func _set_alpha(node: Node3D, a: float) -> void:
	var mi := node as MeshInstance3D
	if mi == null:
		return
	var mat := mi.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(1.0, 1.0, 1.0, clampf(a, 0.0, 1.0))

func _ease_out(x: float) -> float:
	return 1.0 - (1.0 - x) * (1.0 - x)
