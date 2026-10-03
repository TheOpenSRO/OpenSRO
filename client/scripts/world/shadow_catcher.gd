extends RefCounted
class_name ShadowCatcher

## Shadow Detail "Detail" on the terrain (round 702 review).
##
## The terrain is drawn with the client's own baked light (unshaded), so the
## sun's shadow map never reaches it. In Detail a second pass over the
## terrain's base surface -- this material, as the base material's next_pass
## -- multiplies the ground by `mix(k, 1, shadow)`: the shadow map's own
## attenuation in its light() function, nothing else (no ambient, no
## specular, no fog).
##
## **What the original draws (READ).** Detail projects each character's
## silhouette onto the ground under it (`Map::FUN_009f35f0`, redrawing the
## ground cells `Map::FUN_009f2f80` collects): colour SELECTARG2 DIFFUSE,
## alpha MODULATE(TEXTURE, DIFFUSE), SRCALPHA / INVSRCALPHA, the vertices'
## DIFFUSE black with alpha `round(150 - clamp((h - ref - 12) x 9, 0, 150))`
## (doubles 0xd83058 = 150, 0xd89248 = 12, 0xdd7ca8 = 9, float 0xdb8d74 =
## 150), h the vertex's depth along the light against the character's.
## So under a character's feet the ground keeps 1 - 150/255 = 0.412 of its
## displayed colour where the silhouette is solid, fading out over the 17
## units below.
##
## **Here (OURS method).** Only characters cast shadows (World3D turns
## casting off on terrain and placed objects, as the original's scenery casts
## none -- its building shadows are baked), so the shadow map holds the
## characters' silhouettes; this pass darkens the terrain by them. K_DISPLAY
## is the READ 0.412 of the displayed colour. The pass multiplies in the
## frame's linear light BEFORE the Filmic tone map, so no single factor
## gives 0.412 at every brightness: K_LINEAR is FITTED (rework review, M1)
## on the screen -- the shadow core's displayed ratio (Detail over Nothing,
## the farmland at 96/168, ground at luma ~97, top-down) measured 0.38 with
## k = 0.219, the value Godot's Filmic curve alone predicts for 0.412 at luma
## 95, so k is raised to 0.25 (the curve predicts 0.448 there; the screen
## measures the round's figure, docs/WORLD_ISSUES.md). The decoded 0.141 the
## review rejected kept ~0.36 by the curve.
## The original's fade with height is not reproduced. Forward+ only: the
## Compatibility renderer draws a shadowed sun in its own additive pass,
## where a multiplying material cannot work (World3D leaves the catcher off
## there).
##
## The order (render priority, transparent pass): the terrain's overlays and
## the water (WorldFog.UNDER_PASS_PRIORITY), then this, then the fog pass.

const K_DISPLAY := 1.0 - 150.0 / 255.0
const PRIORITY := -2

const SHADER := """
shader_type spatial;
// Shadow Detail's catcher (ShadowCatcher, round 702 review).
render_mode blend_mul, depth_draw_never, cull_disabled, ambient_light_disabled, specular_disabled, fog_disabled;
uniform float k = 0.25;
void fragment() {
	ALBEDO = vec3(1.0);
}
void light() {
	if (LIGHT_IS_DIRECTIONAL) {
		DIFFUSE_LIGHT += vec3(mix(k, 1.0, ATTENUATION));
	}
}
"""

static var _material: ShaderMaterial = null

## FITTED on the screen (see above).
const K_LINEAR := 0.25
## The ground's typical displayed luma the fit is made at (MEASURED).
const FIT_DISPLAY := 95.0 / 255.0

static func k_linear() -> float:
	return K_LINEAR

## The displayed fraction the catcher keeps of a ground pixel shown at
## `display` under Godot's Filmic (white 1, exposure 1), for the tests.
static func shown_ratio(k: float, display: float) -> float:
	var lo := 0.0
	var hi := 8.0
	for _i in 60:
		var m := (lo + hi) * 0.5
		if WorldFog.linear_to_srgb(WorldFog.filmic(m)) < display:
			lo = m
		else:
			hi = m
	return WorldFog.linear_to_srgb(WorldFog.filmic(k * lo)) / display

## The one material every terrain base shares as its next pass.
static func material() -> ShaderMaterial:
	if _material == null:
		var sh := Shader.new()
		sh.code = SHADER
		_material = ShaderMaterial.new()
		_material.shader = sh
		_material.render_priority = PRIORITY
		_material.set_shader_parameter("k", k_linear())
	return _material

## Puts the catcher on (or takes it off) a terrain patch's base surface.
static func set_on(patch: MeshInstance3D, on: bool) -> void:
	if patch == null or not is_instance_valid(patch) or patch.mesh == null or patch.mesh.get_surface_count() == 0:
		return
	var base: Material = patch.material_override if patch.material_override != null else patch.mesh.surface_get_material(0)
	if base == null:
		return
	base.next_pass = material() if on else null
