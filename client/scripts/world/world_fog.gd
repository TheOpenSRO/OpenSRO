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
##   (Map::FUN_00a1baf0, docs/protocol/ENVIRONMENT_FORMAT.md, round 229).
##   Jangan's record (EnvironmentID 15, Env7) has 0.759 / 1.000 at phase 0.5
##   (MEASURED from the archive, round 702): 1897 .. 2500 at the default view
##   distance (the "1250 .. 2250" this said until round 705 was a stale
##   example). The view distance is `_DAT_00ec54b0` = min(0.8 x far, 2500),
##   written by Background Sight Range (READ, SWorld::vslot_043 case 8):
##   1200 / 2000 / 2500 / 2500 / 2500, so at setting 1 the planes are
##   911 .. 1200 and at 2, 1518 .. 2000;
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
## display values, as Direct3D 9 does. Forward+ blends in its linear buffer,
## which made a half-fogged pixel lighter than the original's until round
## 705; the pass now writes the colour and alpha whose linear blend is the
## display-value mix, exactly for a reference destination and close around
## it (BLEND_FORWARD). The blended MTRL
## mods' own FOG still mixes in linear light under Forward+ (OURS).

## The globals (project.godot [shader_globals]).
const GLOBAL_PARAMS := &"srr_fog_params"
const GLOBAL_COLOR := &"srr_fog_color"

## The pass's place in the transparent sort: after the cloud layer (-128),
## the surfaces it must fog (UNDER_PASS_PRIORITY) and Detail's terrain
## shadow catcher (ShadowCatcher.PRIORITY, -2), before every other
## transparent surface (priority 0 and up). Godot sorts the transparent list
## by priority before depth in both renderers (render_list
## sort_by_reverse_depth_and_priority).
const PASS_PRIORITY := -1
const UNDER_PASS_PRIORITY := -3

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
// QA only (round 705, OURS): draw the measurement instead of the fog -- red
// the fog amount, green the view depth / 5000 -- opaque, for a frame read.
uniform bool qa_probe = false;
%s
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
	if (qa_probe) {
		f = vec4(srr_fog_params.z > 0.0 ? f.a : 0.0, clamp(-view.z / view.w / 5000.0, 0.0, 1.0), 0.0, 1.0);
	} else if (f.a <= 0.0) {
		discard;
	} else {
		%s
	}
	ALBEDO = f.rgb;
	ALPHA = f.a;
	%s
}
"""

## Compatibility blends the pass in the framebuffer's display values, as
## Direct3D 9 blends its fog (the client sets no D3DRS_SRGBWRITEENABLE --
## MEASURED: no 0xc2 render state in the decompile), so the pass just writes
## the colour with the fog amount as its alpha.
const BLEND_COMPATIBILITY := "f = vec4(srr_linear_to_srgb(f.rgb), f.a);"

## Forward+ blends in its linear buffer, before the tone map: a half-fogged
## pixel came out lighter there than the original's (round 702; MEASURED in
## round 705 at the user's Jangan spot, Background Sight Range 1, the dragon
## at view depth 1018 = 37 % fog: luma 154 here against Compatibility's 129,
## bloom off). The display-value mix of an unknown destination D,
## `unshown(mix(shown(D), shown(fog), a))`, is not something Godot's fixed
## blend can make from one colour and one alpha, and reading the opaque colour
## (hint_screen_texture) to compute it exactly cost +1.4 ms a frame at
## 3840 x 2160 (MEASURED, the round's perf gate: 4.79 -> 6.16 ms at the
## Jangan spawn; +0.0 at 1280 x 720) -- Godot's copy of the 3D buffer. So the
## pass writes the colour and alpha whose linear blend is the display mix
## EXACTLY for a destination shown at REFERENCE_SHOWN and for one already at
## the fog colour (the alpha from the three channels' mean slope, the colour
## per channel), and close in between: against the exact mix, worst 17.1 /
## 255 over destinations 0.05..0.6 and amounts 0.05..1 (world_fog_test.gd's
## CPU check; the linear blend before: 50.5). On the box at that spot the
## dragon reads 133 with it (the exact mix 130). OURS method; the fully
## fogged pixel is still exactly the READ colour.
## REFERENCE_SHOWN = 0.2 is OURS, anchored on what the Jangan spawn's surfaces
## show (MEASURED, round 705: gate wall, dragon and paving 44-51 / 255).
const REFERENCE_SHOWN := 0.2
const FORWARD_DECL := """
// The environment's tone map (World3D sets them with the fog): the pass
// mixes in the values the screen shows. The reference destination is
// WorldFog.REFERENCE_SHOWN (0.2, OURS).
uniform float tm_exposure = 1.0;
uniform float tm_white = 1.0;
uniform bool tm_filmic = true;
const float SRR_TA = 0.88;
const float SRR_TB = 0.6;
const float SRR_TC = 0.1;
const float SRR_TD = 0.2;
const float SRR_TE = 0.01;
const float SRR_TF = 0.3;
float srr_filmic_raw(float x) {
	return (x * (SRR_TA * x + SRR_TC * SRR_TB) + SRR_TD * SRR_TE) / (x * (SRR_TA * x + SRR_TB) + SRR_TD * SRR_TF) - SRR_TE / SRR_TF;
}
float srr_filmic_inverse(float t) {
	float u = clamp(t, 0.0, 0.999) * srr_filmic_raw(tm_white) + SRR_TE / SRR_TF;
	float a = SRR_TA * (u - 1.0);
	float b = SRR_TB * (u - SRR_TC);
	float c = SRR_TD * (SRR_TF * u - SRR_TE);
	float disc = max(b * b - 4.0 * a * c, 0.0);
	return max((-b - sqrt(disc)) / (2.0 * a), 0.0);
}
// Linear (before the tone map) -> what the screen shows.
vec3 srr_shown(vec3 lin) {
	vec3 x = max(lin, vec3(0.0)) * tm_exposure;
	if (tm_filmic) {
		float w = srr_filmic_raw(tm_white);
		x = vec3(srr_filmic_raw(x.r), srr_filmic_raw(x.g), srr_filmic_raw(x.b)) / w;
	}
	return srr_linear_to_srgb(clamp(x, vec3(0.0), vec3(1.0)));
}
// The slope of the line through (ref, at_ref) and (fog, fog): what one unit
// of the destination keeps (1 - the linear alpha), for a channel whose fog
// colour sits at the reference -- no line -- the plain linear blend's.
float srr_line_slope(float fog, float ref, float at_ref, float amount) {
	float d = fog - ref;
	return abs(d) > 0.0001 ? (fog - at_ref) / d : 1.0 - amount;
}
// What the screen shows -> the linear value before the tone map.
vec3 srr_unshown(vec3 shown) {
	vec3 x = srr_srgb_to_linear(clamp(shown, vec3(0.0), vec3(1.0)));
	if (tm_filmic) {
		x = vec3(srr_filmic_inverse(x.r), srr_filmic_inverse(x.g), srr_filmic_inverse(x.b));
	}
	return x / max(tm_exposure, 0.0001);
}
"""
const BLEND_FORWARD := """vec3 srr_fog_shown = srr_shown(f.rgb);
		vec3 srr_ref = srr_unshown(vec3(0.2));
		vec3 srr_at_ref = srr_unshown(mix(vec3(0.2), srr_fog_shown, f.a));
		vec3 srr_slope = vec3(srr_line_slope(f.rgb.r, srr_ref.r, srr_at_ref.r, f.a),
			srr_line_slope(f.rgb.g, srr_ref.g, srr_at_ref.g, f.a), srr_line_slope(f.rgb.b, srr_ref.b, srr_at_ref.b, f.a));
		float srr_a = clamp(1.0 - (srr_slope.r + srr_slope.g + srr_slope.b) / 3.0, 0.0, 1.0);
		vec3 srr_src = srr_a > 0.0001 ? max((srr_at_ref - srr_ref * (1.0 - srr_a)) / srr_a, vec3(0.0)) : f.rgb;
		f = vec4(srr_linear_to_srgb(srr_src), srr_a);"""

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

## The pass's code: `compatibility` picks the blend (BLEND_COMPATIBILITY,
## BLEND_FORWARD).
static func pass_shader_code(compatibility: bool = false) -> String:
	return PASS_SHADER % [ShaderColour.DECODE_FN, SHADER_FN, "" if compatibility else FORWARD_DECL,
		BLEND_COMPATIBILITY if compatibility else BLEND_FORWARD, ShaderColour.DECODE_ALBEDO]

## The tone map the Forward+ pass mixes under (BLEND_FORWARD), from `env`.
static func set_pass_tonemap(pass_mi: MeshInstance3D, env: Environment) -> void:
	if pass_mi == null or not (pass_mi.material_override is ShaderMaterial):
		return
	var mat := pass_mi.material_override as ShaderMaterial
	mat.set_shader_parameter("tm_exposure", env.tonemap_exposure if env != null else 1.0)
	mat.set_shader_parameter("tm_white", env.tonemap_white if env != null else 1.0)
	mat.set_shader_parameter("tm_filmic", env != null and env.tonemap_mode == Environment.TONE_MAPPER_FILMIC)

## The pass: a 2 x 2 quad whose vertex shader puts it over the whole view,
## parented to the camera so it is never culled (its margin covers the far
## plane). `compatibility` picks the depth's NDC range and the blend.
static func build_pass(compatibility: bool) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	var sh := Shader.new()
	sh.code = pass_shader_code(compatibility)
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
