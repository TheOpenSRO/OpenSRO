extends RefCounted
class_name TerrainLight

## The terrain's light as the time of day moves it (round 786).
##
## Until round 786 the terrain's light was baked into its vertex colours when
## a region was built: tint x clamp(N.L x diffuse + ambient) per vertex
## (MapmTerrainBuilder._lit_vertex_color, READ from Shader\
## vertexshader0splatting.c: `mad oD0, N.L, c[VSC_DLIGHT_DIFFUSE],
## c[VSC_DLIGHT_AMBIENT]`), and the `.t` lightmap pass's TerrainShadowColor
## into the lightmap image (MapmTerrainBuilder.lightmap_term, round 610).
## Both are environment channels sampled at the day phase -- 2 (diffuse), 5
## (terrain ambient), 6 (terrain shadow) -- which retail re-evaluates every
## frame (Map::FUN_00a1baf0) and uploads as shader constants, so a baked
## colour would hold the hour the region was built at.
##
## So the dynamic terrain keeps only what does not change -- N.L per vertex,
## in the vertex colour's red (green and blue the same, alpha the overlay's
## fade), and the raw lightmap -- and this shader does the rest with three
## global uniforms World3D sets from DayCycle each frame:
##
##     lit   = tint x clamp(N.L x srr_terrain_diffuse + srr_terrain_ambient, 0, 1)   (per vertex)
##             x srr_terrain_night    (OURS, round 786: NightLight's k; 1 by day)
##     term  = min(lightmap + srr_terrain_shadow, 1)                               (per pixel)
##     pixel = texture x lit x term
##
## It is StandardMaterial3D's own arithmetic for what the baked terrain used
## (albedo texture, vertex colour decoded where the output is linear, a MUL
## detail layer on UV2, unshaded), with the bake moved in. Under
## Compatibility the result is the bake's exactly; under Forward+ the lit
## colour is decoded as the bake's vertex colour was, and the lightmap term
## after the add, as the baked term texture was sampled (source_color).

## The globals (project.godot [shader_globals]).
const GLOBAL_DIFFUSE := &"srr_terrain_diffuse"
const GLOBAL_AMBIENT := &"srr_terrain_ambient"
const GLOBAL_SHADOW := &"srr_terrain_shadow"
## OURS (round 786, NightLight): the night's scale on the lit colour, after
## retail's clamp -- so a zone whose night keys saturate the clamp (as at
## Bandit's Mountain Stronghold) still darkens. 1 with Night Darkness at
## Original and by day.
const GLOBAL_NIGHT := &"srr_terrain_night"

## What was last set (for the QA log and the tests).
static var current_diffuse := Color(1, 1, 1)
static var current_ambient := Color(0, 0, 0)
static var current_shadow := Color(0, 0, 0)
static var current_night := 1.0

## Sets the globals (display values; `night` NightLight's k, OURS).
static func set_light(diffuse: Color, ambient: Color, shadow: Color, night: float = 1.0) -> void:
	current_diffuse = diffuse
	current_ambient = ambient
	current_shadow = shadow
	current_night = night
	RenderingServer.global_shader_parameter_set(GLOBAL_NIGHT, Vector4(night, night, night, 1.0))
	RenderingServer.global_shader_parameter_set(GLOBAL_DIFFUSE, Vector4(diffuse.r, diffuse.g, diffuse.b, 1.0))
	RenderingServer.global_shader_parameter_set(GLOBAL_AMBIENT, Vector4(ambient.r, ambient.g, ambient.b, 1.0))
	RenderingServer.global_shader_parameter_set(GLOBAL_SHADOW, Vector4(shadow.r, shadow.g, shadow.b, 1.0))

## The CPU twin of the vertex term, for the tests: what the shader computes
## for a vertex whose baked N.L is `ndotl`.
static func lit(ndotl: float, tint: Color, diffuse: Color, ambient: Color, night: float = 1.0) -> Color:
	return Color(tint.r * clampf(ndotl * diffuse.r + ambient.r, 0.0, 1.0) * night,
		tint.g * clampf(ndotl * diffuse.g + ambient.g, 0.0, 1.0) * night,
		tint.b * clampf(ndotl * diffuse.b + ambient.b, 0.0, 1.0) * night)

## The shader for one kind of surface: an overlay (`blend`) or not, and the
## water mirror's clip (`clip`: discard below WaterReflection's plane).
static func shader_code(blend: bool, clip: bool) -> String:
	var modes := ["cull_back", "unshaded"]
	if blend:
		modes.append("blend_mix")
		modes.append("depth_draw_never")
	return """shader_type spatial;
render_mode %s;
global uniform vec4 srr_terrain_diffuse;
global uniform vec4 srr_terrain_ambient;
global uniform vec4 srr_terrain_shadow;
global uniform vec4 srr_terrain_night;
%s
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform bool use_albedo_tex = false;
// Raw: the term is formed in display values and decoded after the add.
uniform sampler2D lightmap_tex : filter_linear_mipmap, repeat_enable;
uniform bool use_lightmap = false;
// The pass's tint (display values, set as a Vector3): white for a textured
// pass, MapmTerrainBuilder's flat fallback for the base and the -1 pass.
uniform vec3 tint = vec3(1.0);
varying vec3 lit;
%s
%s
void vertex() {
	// Retail's terrain vertex shader: mad oD0, N.L, c[DIFFUSE], c[AMBIENT],
	// saturated into the colour register -- N.L is the vertex colour's red.
	lit = tint * clamp(COLOR.r * srr_terrain_diffuse.rgb + srr_terrain_ambient.rgb, 0.0, 1.0);
	// OURS (round 786, NightLight): the night's scale, after the clamp.
	lit *= srr_terrain_night.rgb;
	if (!OUTPUT_IS_SRGB) {
		lit = srr_srgb_to_linear(lit);
	}
%s}
void fragment() {
%s	vec4 c = vec4(lit, COLOR.a);
	if (use_albedo_tex) {
		c *= texture(albedo_tex, UV);
	}
	if (use_lightmap) {
		vec3 term = min(texture(lightmap_tex, UV2).rgb + srr_terrain_shadow.rgb, vec3(1.0));
		if (!OUTPUT_IS_SRGB) {
			term = srr_srgb_to_linear(term);
		}
		c.rgb *= term;
	}
	ALBEDO = c.rgb;
%s}
""" % [", ".join(modes),
		"global uniform vec4 water_clip_plane;" if clip else "",
		"varying vec3 world_pos;" if clip else "",
		ShaderColour.DECODE_FN,
		"\tworld_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;\n" if clip else "",
		"\tif (dot(world_pos, water_clip_plane.xyz) + water_clip_plane.w < 0.0) {\n\t\tdiscard;\n\t}\n" if clip else "",
		"\tALPHA = c.a;\n" if blend else ""]

static var _shaders := {}

static func shader(blend: bool, clip: bool) -> Shader:
	var key := "%d%d" % [int(blend), int(clip)]
	if not _shaders.has(key):
		var sh := Shader.new()
		sh.code = shader_code(blend, clip)
		_shaders[key] = sh
	return _shaders[key]

## A dynamic terrain material (MapmTerrainBuilder._surface_material).
static func material(texture: Texture2D, lightmap: Texture2D, tint: Color, blend: bool, priority: int, texture_key: int) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader(blend, false)
	m.render_priority = priority
	m.set_meta("terrain_texture_key", texture_key)
	m.set_meta("terrain_blend", blend)
	m.set_shader_parameter("albedo_tex", texture)
	m.set_shader_parameter("use_albedo_tex", texture != null)
	m.set_shader_parameter("lightmap_tex", lightmap)
	m.set_shader_parameter("use_lightmap", lightmap != null)
	m.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
	return m

static func is_terrain(mat: Material) -> bool:
	return mat is ShaderMaterial and mat.has_meta("terrain_blend")

## The water mirror's copy (WaterReflection.clip_material for this kind).
static func clip_material(src: ShaderMaterial) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader(bool(src.get_meta("terrain_blend", false)), true)
	m.render_priority = src.render_priority
	for p in ["albedo_tex", "use_albedo_tex", "lightmap_tex", "use_lightmap", "tint"]:
		m.set_shader_parameter(p, src.get_shader_parameter(p))
	return m

## The pass's ground texture, whichever kind of material it is (GroundProbe).
static func albedo_of(mat: Material) -> Texture2D:
	if mat is BaseMaterial3D:
		return (mat as BaseMaterial3D).albedo_texture
	if is_terrain(mat):
		return (mat as ShaderMaterial).get_shader_parameter("albedo_tex") as Texture2D
	return null

## The pass's lightmap texture, whichever kind of material it is.
static func lightmap_of(mat: Material) -> Texture2D:
	if mat is BaseMaterial3D:
		var b := mat as BaseMaterial3D
		return b.detail_albedo if b.detail_enabled else null
	if is_terrain(mat):
		return (mat as ShaderMaterial).get_shader_parameter("lightmap_tex") as Texture2D
	return null
