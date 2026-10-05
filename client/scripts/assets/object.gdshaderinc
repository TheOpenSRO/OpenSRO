// The body of every object shader (round 706; ObjectLoader.object_shader
// builds them): a solid layer (OBJECT_SOLID, back faces culled), a
// two-sided layer and an alpha-tested one-sided one (the round-625 foliage
// shaders), and their fade twins (APPEAR_FADE, AppearFade). The cull mode
// and blending are the only differences, set by the builder's render_mode.
//
// The lighting is the original's object vertex shader, per vertex, in
// display values (ObjectLight has every address):
//
//     oD0   = saturate(object x La + max(0, N.L) x material x Ld)
//     pixel = saturate(2 x texture x oD0)
//
// with `albedo` the .bmt layer's SECOND colour (D3DMATERIAL9.Diffuse) and
// `object_color` 0.6 (CCompoundObj) or a character's shadow tile. Unshaded:
// no Godot light reaches an object (the sun is kept for Detail's character
// shadows on the terrain only, as the original projects them on ground
// cells). Because oD0 is one vertex colour, both faces of a double-sided
// card are lit the same -- the authored normal, never flipped -- which is
// what the round-625 foliage shader existed to reproduce: the willow
// canopies' normals all point up (MEASURED 156/156 and 68/68 vertices at
// (0,1,0)), so a flipped underside went dark.
//
// The alpha test reads full-resolution alpha (mip 0): OURS, the client tests
// the filtered alpha, but a leaf card's mipmapped alpha falls with distance
// and the canopy dissolves (rounds 120s; a rescale of the filtered alpha
// was tried and measured as a zero-pixel change). Colour still comes from
// the mipmapped sample.
//
// Texels are raw (no source_color) and ALBEDO is decoded at the end only
// where the output is linear (ShaderColour, round 693): the arithmetic is
// the client's gamma-space arithmetic in both renderers. ObjectLight.
// SHADER_FN and ShaderColour.DECODE_FN carry the same GLSL as below
// (object_light_test.gd holds them equal).

// The material's colour (BmtReader `diffuse`, set as a Color: read through
// srr_color).
uniform vec4 albedo = vec4(1.0);
uniform sampler2D albedo_texture : hint_default_white, filter_linear_mipmap, repeat_enable;
// The alpha test's threshold: ObjectLoader.ALPHA_TEST_REF / 255 for a layer
// whose flag word asks for the test (0x200, READ round 625), 1/255 under an
// env-map mod that asks for its own, 0 for none -- every texel kept.
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.0;
#ifdef APPEAR_FADE
// A character fading into existence (AppearFade, round 676): the model's
// alpha, 0 to 1 over the fade. Only the *_fade.gdshader variants define
// APPEAR_FADE; the shaders the world draws with compile without it.
uniform float appear_alpha : hint_range(0.0, 1.0) = 1.0;
#endif

vec3 srr_srgb_to_linear(vec3 srr_v) {
	vec3 srr_c = max(srr_v, vec3(0.0));
	return mix(pow((srr_c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), srr_c * (1.0 / 12.92), lessThan(srr_c, vec3(0.04045)));
}
vec3 srr_linear_to_srgb(vec3 srr_v) {
	vec3 srr_c = max(srr_v, vec3(0.0));
	return mix(1.055 * pow(srr_c, vec3(1.0 / 2.4)) - vec3(0.055), srr_c * 12.92, lessThan(srr_c, vec3(0.0031308)));
}
vec4 srr_color(vec4 srr_v, bool srr_output_is_srgb) {
	return srr_output_is_srgb ? srr_v : vec4(srr_linear_to_srgb(srr_v.rgb), srr_v.a);
}

global uniform vec4 srr_obj_light;
global uniform vec4 srr_obj_ambient;
global uniform vec4 srr_obj_diffuse;
global uniform vec4 srr_obj_tonemap;
// The drawn object's colour (+0x14..+0x1c): 0.6 for every placed object
// (CCompoundObj). A character's shadow tile is set on per-level copies of
// its materials (ObjectLight.with_object_color, CharacterLight). Not a
// per-instance uniform: one per placed mesh overflowed Godot's instance buffer
// at the Jangan spawn (round 706 review, MEASURED: 1,093 "Too many
// instances using shader instance variables"), and GL Compatibility has
// none at all.
uniform vec3 object_color = vec3(0.6);
// BerserkLook's pulse (READ: CObjRendererVS::FUN_00c27180 puts the colour in
// place of both the material's and the object's): w 1 while it runs.
uniform vec4 object_tint = vec4(0.0);
// A TEXANI mod's texture-coordinate matrix, rows c23 and c24 (TexAni, round
// 722; READ: vertexshader0texani.c's m3x3 oT0, (u, v, 1), c23). The
// identity for every other material.
uniform vec3 texani_u = vec3(1.0, 0.0, 0.0);
uniform vec3 texani_v = vec3(0.0, 1.0, 0.0);
varying vec3 srr_od0;
// oD0 = saturate(object x La + max(0, N.L) x material x Ld) (ObjectLight).
vec3 srr_obj_od0(vec3 srr_n, vec3 srr_material, vec3 srr_object, vec4 srr_tint) {
	vec3 srr_c10 = (srr_tint.w > 0.5 ? srr_tint.rgb : srr_object) * srr_obj_ambient.rgb;
	vec3 srr_c11 = (srr_tint.w > 0.5 ? srr_tint.rgb : srr_material) * srr_obj_diffuse.rgb;
	return clamp(srr_c10 + max(dot(srr_n, srr_obj_light.xyz), 0.0) * srr_c11, vec3(0.0), vec3(1.0));
}
float srr_obj_filmic_raw(float x) {
	return (x * (0.88 * x + 0.1 * 0.6) + 0.2 * 0.01) / (x * (0.88 * x + 0.6) + 0.2 * 0.3) - 0.01 / 0.3;
}
float srr_obj_filmic_inverse(float t, float white) {
	float u = clamp(t, 0.0, 0.999) * srr_obj_filmic_raw(white) + 0.01 / 0.3;
	float a = 0.88 * (u - 1.0);
	float b = 0.6 * (u - 0.1);
	float c = 0.2 * (0.3 * u - 0.01);
	float disc = max(b * b - 4.0 * a * c, 0.0);
	return max((-b - sqrt(disc)) / (2.0 * a), 0.0);
}
// A display value -> the value to write as ALBEDO (display-encoded) so that
// Godot's tone map shows it unchanged (ObjectLight).
vec3 srr_obj_present(vec3 srr_v) {
	if (srr_obj_tonemap.w < 0.5) {
		return srr_v;
	}
	vec3 srr_l = srr_srgb_to_linear(clamp(srr_v, vec3(0.0), vec3(1.0)));
	if (srr_obj_tonemap.z > 0.5) {
		srr_l = vec3(srr_obj_filmic_inverse(srr_l.r, srr_obj_tonemap.y), srr_obj_filmic_inverse(srr_l.g, srr_obj_tonemap.y), srr_obj_filmic_inverse(srr_l.b, srr_obj_tonemap.y));
	}
	return srr_linear_to_srgb(srr_l / max(srr_obj_tonemap.x, 0.0001));
}

void vertex() {
	srr_od0 = srr_obj_od0(MODEL_NORMAL_MATRIX * NORMAL, srr_color(albedo, OUTPUT_IS_SRGB).rgb, object_color, object_tint);
	UV = vec2(dot(vec3(UV, 1.0), texani_u), dot(vec3(UV, 1.0), texani_v));
}

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	ALBEDO = srr_obj_present(clamp(2.0 * tex.rgb * srr_od0, vec3(0.0), vec3(1.0)));
#ifdef APPEAR_FADE
	// The keep-or-discard test made by hand, so the drawn alpha can be the
	// fade's: a blended draw cannot also take Godot's scissor (OURS).
	if (alpha_scissor > 0.0 && textureLod(albedo_texture, UV, 0.0).a < alpha_scissor) {
		discard;
	}
	ALPHA = appear_alpha;
#else
#ifndef OBJECT_SOLID
	ALPHA = alpha_scissor > 0.0 ? textureLod(albedo_texture, UV, 0.0).a : 1.0;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor;
#endif
#endif
	if (!OUTPUT_IS_SRGB) { ALBEDO = srr_srgb_to_linear(ALBEDO); }
}
