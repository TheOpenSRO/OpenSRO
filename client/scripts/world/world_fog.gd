extends RefCounted
class_name WorldFog

## The world's distance fog, as the original draws it (round 702).
##
## **What the original does (READ, sro_client.exe).** The landscape step
## `Map::FUN_00a26f60` turns fog on (render state 0x1c FOGENABLE = 1 at
## 0xa27549), sets D3DRS_FOGCOLOR (0x22, 0xa2755c) to world+0x67e6 -- the
## square root of the zone's channel 9 (EnvironmentReader.render_fog_color) --
## and picks the range (0xa27568..0xa2765e):
## - world+0x26e1 == 0: start = end = 10000.0 (float 0xd82efc). Its one writer
##   is the world's constructor, which sets it to 1 (0xa2f76a), so this branch
##   is not taken in the world;
## - world+0x26bb == 0: start = world+0x68af, end = world+0x68b3 (0x11081ff,
##   0x1108203) -- the zone's channels 10 and 11 times the view distance
##   (Map::FUN_00a1baf0, docs/protocol/ENVIRONMENT_FORMAT.md, round 229):
##   Jangan 1250 .. 2250;
## - world+0x26bb != 0 (cleared at 0xa2cd33, set at 0xa2ce1a when the
##   camera's cell holds a flagged object region -- INFERRED to be an indoor
##   or dungeon cell): start -200.0 (0xde4db8), end = far plane / 10 (double
##   0xe1b840). Not drawn here.
## It then sets FOGDENSITY 0.005 (0xde4d6c, unused by linear fog),
## RANGEFOGENABLE (0x30, 0xa276b0) = 0, and either table fog LINEAR (0x23 = 3,
## vertex mode 0x8c = 0) or vertex fog LINEAR (0x8c = 3) by world+0x237e bit
## 15 (0xa276fc..0xa27735), and hands the same start and end to the object
## renderer's fog slot (vslot_014, vertex constant c16: `vss0.c`'s LINEAR fog,
## docs/RE_MAP_ENGINE.md). So the terrain, the objects and the characters fog
## alike: linear in VIEW DEPTH (range fog off), nothing before the start, the
## fog colour from the end on. Particles turn fog off (EFP_FORMAT.md:
## FOGENABLE 0). The sky step fogs its own cloud layer from 90,000 to 200,000
## (cloud_dome.gdshader). Nothing else in the step darkens or hazes what is
## near the camera.
##
## **How it is drawn here (OURS method, READ values).** Godot 4.2's own fog is
## exponential from the camera (no depth range until 4.3), so it is set to
## nothing and the fog is a full-screen pass instead: a quad drawn first in
## the transparent pass reads the opaque depth, turns it into view depth and
## blends the fog colour at `(depth - start) / (end - start)` -- D3D's linear
## fog factor, `(end - d) / (end - start)` of the surface kept. Transparent
## surfaces that lie ON opaque ones (the terrain's feathered overlays, the
## water) are drawn before the pass (UNDER_PASS_PRIORITY) and so are fogged
## with what they cover; a transparent MTRL mod is drawn after it and fogs
## itself with the same values (SHADER_FN, the `srr_fog_*` shader globals in
## project.godot). Particles, name plates, the blob and the markers are not
## fogged (particles as in the original; the rest are near the player).
## The sky (nothing in the depth buffer) is left to its own fog, as retail.
##
## **Colour.** The pass draws a colour that the tone map turns back into the
## zone's fog colour (`pass_color`: T^-1 of the decoded colour, over the
## exposure -- as the water and the cloud layer undo it), so a fully fogged
## pixel shows exactly the READ colour. Blending: Compatibility blends in
## display values, as Direct3D 9 does; Forward+ blends in its linear buffer,
## so a half-fogged pixel there is lighter than the original's (OURS; the
## round's entry measures it).

## The globals (project.godot [shader_globals]).
const GLOBAL_PARAMS := &"srr_fog_params"
const GLOBAL_COLOR := &"srr_fog_color"

## The pass's place in the transparent sort: after the cloud layer (-128) and
## the surfaces it must fog (UNDER_PASS_PRIORITY), before every other
## transparent surface (priority 0 and up). Godot sorts the transparent list
## by priority before depth in both renderers (render_list
## sort_by_reverse_depth_and_priority).
const PASS_PRIORITY := -1
const UNDER_PASS_PRIORITY := -2

## The view distance the planes scale by when no row says otherwise
## (READ, 0xec54b0 = 2500.0).
const VIEW_DISTANCE_DEFAULT := 2500.0

## A transparent world shader's fog (Godot's FOG built-in: the colour, and how
## much of it). Both renderers mix the fragment's linear colour toward FOG.rgb
## by FOG.a (scene_forward_clustered.glsl 2371-2374; gles3 scene.glsl
## 1580-1588, which needs the environment's fog enabled -- World3D keeps it
## enabled at density 0).
const SHADER_FN := """
global uniform vec4 srr_fog_params;
global uniform vec4 srr_fog_color;
vec4 srr_fog(vec3 srr_view_vertex) {
	float srr_span = max(srr_fog_params.y - srr_fog_params.x, 0.001);
	float srr_amount = srr_fog_params.z * clamp((-srr_view_vertex.z - srr_fog_params.x) / srr_span, 0.0, 1.0);
	return vec4(srr_fog_color.rgb, srr_amount);
}
"""
const SHADER_FOG_LINE := "FOG = srr_fog(VERTEX);"

const PASS_SHADER := """
shader_type spatial;
// The world's linear distance fog (WorldFog, round 702): a full-screen quad,
// first in the transparent pass, over the opaque depth.
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled, shadows_disabled, skip_vertex_transform;
uniform sampler2D srr_depth : hint_depth_texture, filter_nearest, repeat_disable;
// Compatibility's depth is OpenGL's [-1, 1] NDC; Forward+'s Vulkan [0, 1].
uniform bool ndc_signed = false;
%s
%s
void vertex() {
	POSITION = vec4(VERTEX.xy, 0.5, 1.0);
}
void fragment() {
	float d = textureLod(srr_depth, SCREEN_UV, 0.0).r;
	// Nothing drawn here: the sky, which fogs itself.
	if (d >= 1.0) {
		discard;
	}
	vec4 clip = vec4(SCREEN_UV * 2.0 - 1.0, ndc_signed ? d * 2.0 - 1.0 : d, 1.0);
	vec4 view = INV_PROJECTION_MATRIX * clip;
	vec4 f = srr_fog(vec3(0.0, 0.0, view.z / view.w));
	if (f.a <= 0.0) {
		discard;
	}
	ALBEDO = srr_linear_to_srgb(f.rgb);
	ALPHA = f.a;
	%s
}
"""

## D3D linear fog's share of the fog colour at view depth `depth`.
static func amount(depth: float, start: float, end: float) -> float:
	return clampf((depth - start) / maxf(end - start, 0.001), 0.0, 1.0)

## The fog planes: channels 10 and 11 times the view distance (READ).
static func planes(channel_10: float, channel_11: float, view_distance: float = VIEW_DISTANCE_DEFAULT) -> Vector2:
	return Vector2(channel_10 * view_distance, channel_11 * view_distance)

## Godot 4.2's filmic curve (tonemap_inc.glsl / tonemap.glsl, exposure bias 2
## folded into A and B), and its inverse on [0, 1).
const _TA := 0.88
const _TB := 0.6
const _TC := 0.1
const _TD := 0.2
const _TE := 0.01
const _TF := 0.3

static func _filmic_raw(x: float) -> float:
	return (x * (_TA * x + _TC * _TB) + _TD * _TE) / (x * (_TA * x + _TB) + _TD * _TF) - _TE / _TF

static func filmic(x: float, white: float = 1.0) -> float:
	return _filmic_raw(maxf(x, 0.0)) / _filmic_raw(white)

static func filmic_inverse(t: float, white: float = 1.0) -> float:
	var u := clampf(t, 0.0, 0.999) * _filmic_raw(white) + _TE / _TF
	var a := _TA * (u - 1.0)
	var b := _TB * (u - _TC)
	var c := _TD * (_TF * u - _TE)
	var disc := maxf(b * b - 4.0 * a * c, 0.0)
	return maxf((-b - sqrt(disc)) / (2.0 * a), 0.0)

static func srgb_to_linear(v: float) -> float:
	v = maxf(v, 0.0)
	return v / 12.92 if v < 0.04045 else pow((v + 0.055) / 1.055, 2.4)

static func linear_to_srgb(v: float) -> float:
	v = maxf(v, 0.0)
	return v * 12.92 if v < 0.0031308 else 1.055 * pow(v, 1.0 / 2.4) - 0.055

## The linear colour, before tone mapping, the screen shows as `display`
## under `env`'s tone map (filmic or linear; exposure and white as set).
static func pass_color(display: Color, env: Environment) -> Color:
	var filmic_on := env != null and env.tonemap_mode == Environment.TONE_MAPPER_FILMIC
	var exposure := env.tonemap_exposure if env != null else 1.0
	var white := env.tonemap_white if env != null else 1.0
	var out := Color(0, 0, 0, 1)
	for i in 3:
		var lin := srgb_to_linear(clampf(display[i], 0.0, 1.0))
		if filmic_on:
			lin = filmic_inverse(lin, white)
		out[i] = lin / maxf(exposure, 0.0001)
	return out

## Sets the globals every fogged shader reads. `on` false draws no fog.
static func set_globals(fog_planes: Vector2, on: bool, linear_color: Color) -> void:
	RenderingServer.global_shader_parameter_set(GLOBAL_PARAMS,
		Vector4(fog_planes.x, fog_planes.y, 1.0 if on else 0.0, 0.0))
	RenderingServer.global_shader_parameter_set(GLOBAL_COLOR,
		Vector4(linear_color.r, linear_color.g, linear_color.b, 1.0))

static func pass_shader_code() -> String:
	return PASS_SHADER % [ShaderColour.DECODE_FN, SHADER_FN, ShaderColour.DECODE_ALBEDO]

## The pass: a 2 x 2 quad whose vertex shader puts it over the whole view,
## parented to the camera so it is never culled (its margin covers the far
## plane). `compatibility` picks the depth's NDC range.
static func build_pass(compatibility: bool) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	var sh := Shader.new()
	sh.code = pass_shader_code()
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.render_priority = PASS_PRIORITY
	mat.set_shader_parameter("ndc_signed", compatibility)
	var mi := MeshInstance3D.new()
	mi.name = "WorldFogPass"
	mi.mesh = quad
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 16384.0
	mi.position = Vector3(0.0, 0.0, -1.0)
	return mi
