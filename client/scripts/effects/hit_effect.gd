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
		fx._layers.append({"node": node, "base_scale": node.scale, "intensity": layer.intensity})
	if fx._layers.is_empty():
		fx.free()
		return null
	return fx

## Builds the burst from an arbitrary hit `.efp` (skilleffect.txt gives each
## skill its own -- see the skill-animations note), so every skill plays its own
## real effect rather than one hardcoded set. The mesh/texture layers are read
## out of the .efp's own RenderMesh node stream at runtime (grounded); the
## animation is the same designed pop-and-fade as the hardcoded path (disclosed).
## Falls back to null (caller uses create()) if the .efp yields no layers.
static func create_from_efp(particles: Pk2Reader, efp_path: String, target_world_height: float) -> HitEffect:
	if particles == null:
		return null
	var pairs := _extract_layers(particles, efp_path)
	if pairs.is_empty():
		return null
	var fx := HitEffect.new()
	var burst: float = maxf(target_world_height, 1.0) * HEIGHT_MULTIPLE
	# Cap the layer count so a large effect stays a quick flash, not a soup.
	var count: int = mini(pairs.size(), 4)
	for i in range(count):
		# Designed per-layer animation: alternate tilt, taper intensity so the
		# stacked additive layers don't saturate (disclosed, as in LAYERS).
		var layer := Layer.new(pairs[i][0], pairs[i][1], 1.0,
			(-1.0 if i % 2 else 1.0) * (15.0 + 10.0 * i), 0.8 - 0.12 * i)
		var node := _build_layer(particles, layer, burst)
		if node == null:
			continue
		fx.add_child(node)
		fx._layers.append({"node": node, "base_scale": node.scale, "intensity": layer.intensity})
	if fx._layers.is_empty():
		fx.free()
		return null
	return fx

## Recovers a hit .efp's (mesh, texture) layer pairs by walking its printable
## strings in file order -- each RenderMesh names a meshes\*.bms then the
## textures\*.ddj it pairs with. Consecutive duplicate pairs (the .efp lists
## each twice) are collapsed. Returns [] if the file is missing or has none.
static func _extract_layers(particles: Pk2Reader, efp_path: String) -> Array:
	var data := AssetSource.read_bytes(efp_path, particles)
	if data.is_empty():
		return []
	# Printable-ASCII runs, in order.
	var runs: PackedStringArray = PackedStringArray()
	var cur := ""
	for b in data:
		if b >= 0x20 and b < 0x7f:
			cur += char(b)
		else:
			if cur.length() >= 5:
				runs.append(cur)
			cur = ""
	if cur.length() >= 5:
		runs.append(cur)
	# Pair each mesh with the next texture; collapse consecutive duplicate pairs.
	var pairs: Array = []
	var pending_mesh := ""
	for r in runs:
		var low := r.to_lower()
		if low.ends_with(".bms"):
			pending_mesh = r
		elif low.ends_with(".ddj") and pending_mesh != "":
			var pair := [pending_mesh, r]
			if pairs.is_empty() or pairs[-1] != pair:
				pairs.append(pair)
			pending_mesh = ""
	return pairs

## Builds one real mesh layer, centred on the effect origin (unlike the
## level-up burst which sits on the ground): a hit lands on the body, so the
## slash cards centre on the target's mid-height.
static func _build_layer(particles: Pk2Reader, layer: Layer, burst: float) -> MeshInstance3D:
	var mesh_bytes := AssetSource.read_bytes(layer.mesh_path, particles)
	if mesh_bytes.is_empty():
		return null
	var parsed := BmsReader.parse(mesh_bytes)
	if parsed == null or parsed.vertex_count() == 0:
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
	for entry in _layers:
		var node: Node3D = entry["node"]
		var base: Vector3 = entry["base_scale"]
		node.scale = base * scale_mul
		_set_alpha(node, a * float(entry["intensity"]))
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
