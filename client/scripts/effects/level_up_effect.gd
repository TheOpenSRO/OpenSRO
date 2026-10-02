extends Node3D
class_name LevelUpEffect

## The golden burst played on a character the moment it advances a level.
##
## WHAT IS REAL: the meshes and textures. They are the retail client's own
## level-up particle primitives -- the four `meshes\levelup0N.bms` shapes from
## `system\system_levelup.efp` (Particles.pk2), each paired with the exact
## texture that effect's RenderMesh node names for it. Those pairings were
## recovered by walking the .efp's node stream on the RE box (see
## docs/WORLD_ISSUES.md); they are loaded at runtime from the player's own
## Particles.pk2 and never committed, the same BYO-assets rule as every other
## real asset this client reads.
##
##   levelup01.bms -> won-light-up-i.ddj     (the vertical light shaft)
##   levelup02.bms -> won-light-up-sb.ddj    (the soft bloom)
##   levelup03.bms -> hoon-out-light-02.ddj  (the expanding ground ring)
##   levelup04.bms -> sdamage-wb-01.ddj      (the rising sparkle band)
##
## WHAT IS DESIGNED (and disclosed as such, per the project's "never present a
## guessed value as real" rule): the ANIMATION. The timing, the per-layer
## rise/scale/spin, and the fade are this project's own approximation of the
## effect's recovered *character* -- a grow-then-fade additive burst -- NOT the
## .efp's real per-keyframe ScaleGraph/DiffuseGraph curves. Those graphs are
## not reliably recovered: the EFP reader flattens the tagged tree to
## (name, raw-bytes), and a decode of the graph keyframe block fits cleanly on
## only about a third of this file's ScaleGraph nodes (see
## docs/protocol/EFP_FORMAT.md), so driving the exact curves from it would be
## dressing a guessed structure as real. Only the size is data-driven: every
## layer is normalized to the player's own rendered height, not a magic scale.

## One real mesh layer of the burst: the mesh file, the texture the effect
## pairs with it, and how this project animates it (all timing here is the
## disclosed designed part).
class Layer:
	var mesh_path: String
	var texture_path: String
	## Height of this layer relative to the target burst height (1.0 == full).
	var height_frac: float
	## Peak scale as a fraction of the settled scale -- how far it overshoots.
	var peak_scale: float
	## Degrees per second this layer spins about the vertical axis.
	var spin_deg: float
	## Seconds after the burst starts before this layer begins.
	var delay: float
	## Peak alpha for this layer (0..1). These are additive light textures, so
	## capping each below 1 keeps the stacked layers from saturating to a
	## screen-filling white -- a designed value, see the class comment.
	var intensity: float

	func _init(mesh: String, tex: String, hf: float, peak: float, spin: float, d: float, intens: float) -> void:
		mesh_path = mesh
		texture_path = tex
		height_frac = hf
		peak_scale = peak
		spin_deg = spin
		delay = d
		intensity = intens

## The real level-up meshes with their real paired textures, in draw order
## (ground ring first, shaft last so it reads on top). The animation columns
## are designed, see the class comment.
const LAYERS := [
	# mesh, texture, height_frac, peak_scale, spin_deg, delay, intensity
	["meshes\\levelup03.bms", "textures\\hoon-out-light-02.ddj", 0.12, 1.9, 20.0, 0.00, 0.75],
	["meshes\\levelup02.bms", "textures\\won-light-up-sb.ddj", 0.55, 1.3, -30.0, 0.05, 0.45],
	["meshes\\levelup04.bms", "textures\\sdamage-wb-01.ddj", 0.90, 1.15, 60.0, 0.10, 0.80],
	["meshes\\levelup01.bms", "textures\\won-light-up-i.ddj", 1.00, 1.1, 0.0, 0.00, 0.50],
]

## Total lifetime of the burst, seconds. Designed.
const LIFE := 1.4
## The burst is sized to this multiple of the character's world height.
## Designed: a level-up burst rises a bit past head height without swallowing
## the whole scene (2.2 whited the frame out).
const HEIGHT_MULTIPLE := 1.5

var _t := 0.0
var _layers: Array = [] # of {node, base_scale, layer}
var _finished := false

## Builds the effect from the player's real Particles.pk2, sized to
## target_world_height (the character's rendered height in world units).
## Returns null if the archive is missing or not one real mesh loaded --
## the caller then just shows the level-up message with no visual, rather
## than a fabricated one.
static func create(particles: Pk2Reader, target_world_height: float) -> LevelUpEffect:
	if particles == null:
		return null
	var fx := LevelUpEffect.new()
	var burst_height: float = maxf(target_world_height, 1.0) * HEIGHT_MULTIPLE
	for row in LAYERS:
		var layer := Layer.new(row[0], row[1], row[2], row[3], row[4], row[5], row[6])
		var node := _build_layer(particles, layer, burst_height)
		if node == null:
			continue
		fx.add_child(node)
		fx._layers.append({"node": node, "base_scale": node.scale, "layer": layer})
	if fx._layers.is_empty():
		fx.free()
		return null
	# Start hidden; _process fades the layers in from their delay.
	for entry in fx._layers:
		(entry["node"] as Node3D).visible = false
	return fx

## Builds one real mesh layer as an additive, unshaded MeshInstance3D scaled
## so its own native height becomes height_frac of the burst height.
static func _build_layer(particles: Pk2Reader, layer: Layer, burst_height: float) -> MeshInstance3D:
	var mesh_bytes := AssetSource.read_bytes(layer.mesh_path, particles)
	if mesh_bytes.is_empty():
		return null
	var parsed := BmsReader.parse(mesh_bytes)
	if parsed == null or parsed.vertex_count() == 0:
		return null
	var array_mesh := BmsReader.to_array_mesh(parsed)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Additive light: these are glow textures over the world, the same way the
	# effect renders them (RenderMesh with a light texture, no depth write).
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.vertex_color_use_as_albedo = true
	# Display values, as Compatibility reads them; decoded where the output
	# is linear (Forward+), round 693's ShaderColour.
	mat.vertex_color_is_srgb = ShaderColour.VERTEX_COLOR_IS_SRGB
	var tex := _load_texture(particles, layer.texture_path)
	if tex != null:
		mat.albedo_texture = tex
	array_mesh.surface_set_material(0, mat)

	var mi := MeshInstance3D.new()
	mi.mesh = array_mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.material_override = mat

	# Normalize by the mesh's own native height so no per-mesh scale is
	# hardcoded: whatever the real mesh's authored size, it becomes
	# height_frac of the burst.
	var native_h: float = maxf(parsed.bounds_max.y - parsed.bounds_min.y, 0.001)
	var s: float = (burst_height * layer.height_frac) / native_h
	mi.scale = Vector3(s, s, s)
	# Sit the mesh at the character's feet, centred on them: its base to y=0
	# and its own horizontal centre to the effect origin, so a mesh authored
	# off-origin does not leave the burst hanging to one side of the body.
	var cx: float = (parsed.bounds_min.x + parsed.bounds_max.x) * 0.5
	var cz: float = (parsed.bounds_min.z + parsed.bounds_max.z) * 0.5
	mi.position = Vector3(-cx * s, -parsed.bounds_min.y * s, -cz * s)
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
	for entry in _layers:
		var node: Node3D = entry["node"]
		var layer: Layer = entry["layer"]
		var base: Vector3 = entry["base_scale"]
		var local_t: float = _t - layer.delay
		if local_t < 0.0:
			continue
		node.visible = true
		var span: float = maxf(LIFE - layer.delay, 0.001)
		var u: float = clampf(local_t / span, 0.0, 1.0)
		# Scale: overshoot to peak by ~a third of the life, ease back to settle.
		var scale_mul: float
		if u < 0.33:
			scale_mul = lerpf(0.2, layer.peak_scale, _ease_out(u / 0.33))
		else:
			scale_mul = lerpf(layer.peak_scale, 1.0, _ease_in((u - 0.33) / 0.67))
		node.scale = base * scale_mul
		# Spin about the vertical axis.
		node.rotation.y = deg_to_rad(layer.spin_deg) * local_t
		# Fade: in over the first 15%, hold, out over the last 45%, scaled by
		# the layer's intensity cap so the additive layers don't saturate.
		var a: float
		if u < 0.15:
			a = u / 0.15
		elif u > 0.55:
			a = clampf((1.0 - u) / 0.45, 0.0, 1.0)
		else:
			a = 1.0
		_set_alpha(node, a * layer.intensity)
	if _t >= LIFE:
		_finished = true
		queue_free()

func _set_alpha(node: Node3D, a: float) -> void:
	var mi := node as MeshInstance3D
	if mi == null:
		return
	var mat := mi.material_override as StandardMaterial3D
	if mat == null:
		return
	var c := mat.albedo_color
	c.a = a
	mat.albedo_color = c

static func _ease_out(x: float) -> float:
	return 1.0 - pow(1.0 - clampf(x, 0.0, 1.0), 2.0)

static func _ease_in(x: float) -> float:
	var v := clampf(x, 0.0, 1.0)
	return v * v
