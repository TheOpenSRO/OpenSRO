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
#ifdef CROWD_GPU
// Round 756: a fading GPU ghost's alpha, per instance (CrowdGpu's fade
// groups): the vertex include works it out from INSTANCE_CUSTOM.w.
varying float appear_alpha;
#define SRR_CG_FADE
#else
// A character fading into existence (AppearFade, round 676): the model's
// alpha, 0 to 1 over the fade. Only the *_fade.gdshader variants define
// APPEAR_FADE; the shaders the world draws with compile without it.
uniform float appear_alpha : hint_range(0.0, 1.0) = 1.0;
#endif
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

#ifdef LIGHTMAP
// A light-mapped piece (round 774; ObjectLoader._commit_lightmap, READ
// FUN_00bf1250): stage 0 MODULATE (not 2X) of the texture and oD0, stage 1
// MODULATE2X of that and the light map on the second coordinates, each
// clamped; with no material texture stage 0 is oD0 alone and stage 1 a plain
// MODULATE. The light maps are DXT1 with no mip levels (MEASURED).
uniform sampler2D lightmap_texture : hint_default_white, filter_linear, repeat_disable;
uniform bool lightmap_textured = true;
vec3 srr_lightmapped(vec3 srr_tex, vec3 srr_lit, vec2 srr_uv2) {
	vec3 srr_lm = texture(lightmap_texture, srr_uv2).rgb;
	if (!lightmap_textured) {
		return clamp(srr_lit * srr_lm, vec3(0.0), vec3(1.0));
	}
	return clamp(2.0 * clamp(srr_tex * srr_lit, vec3(0.0), vec3(1.0)) * srr_lm, vec3(0.0), vec3(1.0));
}
#endif

// A TEXANI mod's texture-coordinate matrix, rows c23 and c24 (TexAni, rounds
// 722 and 786): its start rows, their rates a second, the clock it was
// bound at, and the stage whose coordinates it moves (0 TEXANI0 / TEXANI1R,
// 1 TEXANI1). The identity, unmoving, for every other material.
global uniform float srr_texani_clock;
uniform vec3 texani_u = vec3(1.0, 0.0, 0.0);
uniform vec3 texani_v = vec3(0.0, 1.0, 0.0);
uniform vec3 texani_du = vec3(0.0);
uniform vec3 texani_dv = vec3(0.0);
uniform float texani_t0 = 0.0;
uniform int texani_stage = 0;
// Texture stage 1's coordinates (a MULTITEX mod's texture, round 786).
varying vec2 srr_uv1;

#ifdef MULTITEX
// A MULTITEX mod's second texture (round 786; ObjectLoader._commit_multitex,
// READ CRTModMultiTex): texture stage 1, on srr_uv1 (TexAni), blended over
// the stage-0 result by its own alpha (op 1: COLORARG1 TEXTURE, COLORARG2
// CURRENT, COLOROP BLENDTEXTUREALPHA, 0xc82ac0) or by the mod's factor
// alpha (op 0: COLOROP BLENDFACTORALPHA, TEXTUREFACTOR = the mod's colour,
// 0xc82e70); ALPHAOP DISABLE, so the alpha stays stage 0's. A MULTITEXREV
// (multitex_rev) swaps the two textures: the mod's on stage 0, the
// material's on stage 1 (READ, 0xc83160 and CObjRendererVS::FUN_00bf0e20's
// 0x80000000).
uniform sampler2D multitex_texture : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform int multitex_op = 1;
uniform float multitex_factor = 0.0;
uniform bool multitex_rev = false;
vec3 srr_multitex(vec3 srr_current, vec4 srr_t1) {
	float srr_k = multitex_op == 1 ? srr_t1.a : multitex_factor;
	return mix(srr_current, srr_t1.rgb, srr_k);
}
#endif

#ifdef EQUIP_GLOW
// A weapon or shield's glow (round 734, EquipGlow; weapon_glow.md §2.2): the
// item's own draw under CRTModProgEquipPow's stages, READ --
//     stage 0  op0(optionTex(uv + scroll), TFACTOR)   MODULATE / MODULATE2X
//     stage 1  op1(itemTex, CURRENT)                   ADD / ADDSIGNED2X
// each clamped to 0..1, with no lighting (TFACTOR stands where DIFFUSE was).
// TFACTOR is round(lerp(c1, c2, t) x 255) / 255 with t a triangle wave of
// period 2 x glow_period starting at colour 1; the scroll is uv x 50 a
// second. Both run on srr_glow_clock, one clock for every glow (OURS: retail's clock is per mod, from when the
// item was put on, and stops while the character fades; every glow here
// pulses in step). Stage 1's texture is the item's own: READ (round 734's
// review, F7; weapon_glow.md OPEN 9): the mod's 0x80000000 makes
// CObjRendererVS::FUN_00bf0e20 bind the item's texture to stage 1
// (SetTexture(1, FUN_00c39f70(i)) at 0xbf10ce).
// The clock (EquipGlow's accumulator, not TIME: round 734's review, F8).
global uniform float srr_glow_clock;
uniform sampler2D glow_texture : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform vec2 glow_uv_speed = vec2(0.0);
uniform vec3 glow_c1 = vec3(1.0);
uniform vec3 glow_c2 = vec3(1.0);
uniform float glow_period = 1.0;
uniform float glow_mul0 = 1.0;
uniform float glow_signed2x = 0.0;

vec3 srr_glow(vec3 srr_item, vec2 srr_uv, float srr_time) {
	float srr_ph = mod(srr_time, 2.0 * glow_period) / glow_period;
	float srr_t = srr_ph <= 1.0 ? srr_ph : 2.0 - srr_ph;
	vec3 srr_tf = round(mix(glow_c1, glow_c2, srr_t) * 255.0) / 255.0;
	// fract keeps the offset's precision; the texture repeats, as the
	// client's never-wrapped offset does through the sampler's wrap.
	vec3 srr_opt = texture(glow_texture, srr_uv + fract(glow_uv_speed * srr_time)).rgb;
	vec3 srr_s0 = clamp(srr_opt * srr_tf * glow_mul0, vec3(0.0), vec3(1.0));
	vec3 srr_s1 = glow_signed2x > 0.5 ? (srr_item + srr_s0 - vec3(0.5)) * 2.0 : srr_item + srr_s0;
	return clamp(srr_s1, vec3(0.0), vec3(1.0));
}
#ifdef CROWD_GPU
// Round 759: a far part's glow row, per instance (CrowdGpu's glow table, set
// in crowd_gpu_vertex.gdshaderinc), so one twin draws an item at every plus:
// g1 = (glow_c1, glow_period), g2 = (glow_c2, glow_mul0), g3 = (glow_uv_speed,
// glow_signed2x, 0). srr_glow's arithmetic on them (crowd_gpu_test holds the
// two equal).
varying flat vec4 srr_cg_g1;
varying flat vec4 srr_cg_g2;
varying flat vec4 srr_cg_g3;
// The row's option texture (g3.w: its slot + 1, CrowdGpu.GLOW_TEX_SLOTS; 0 is
// glow_texture), with glow_texture's sampling. A row is one instance's, so
// the choice is the same over a whole primitive and its quads.
uniform sampler2D crowd_glow_t0 : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D crowd_glow_t1 : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D crowd_glow_t2 : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D crowd_glow_t3 : hint_default_black, filter_linear_mipmap, repeat_enable;
vec3 srr_glow_opt(vec2 srr_at, float srr_slot) {
	int srr_s = int(srr_slot + 0.5);
	if (srr_s == 1) {
		return texture(crowd_glow_t0, srr_at).rgb;
	} else if (srr_s == 2) {
		return texture(crowd_glow_t1, srr_at).rgb;
	} else if (srr_s == 3) {
		return texture(crowd_glow_t2, srr_at).rgb;
	} else if (srr_s == 4) {
		return texture(crowd_glow_t3, srr_at).rgb;
	}
	return texture(glow_texture, srr_at).rgb;
}
vec3 srr_glow_row(vec3 srr_item, vec2 srr_uv, float srr_time, vec4 srr_g1, vec4 srr_g2, vec4 srr_g3) {
	float srr_ph = mod(srr_time, 2.0 * srr_g1.a) / srr_g1.a;
	float srr_t = srr_ph <= 1.0 ? srr_ph : 2.0 - srr_ph;
	vec3 srr_tf = round(mix(srr_g1.rgb, srr_g2.rgb, srr_t) * 255.0) / 255.0;
	vec3 srr_opt = srr_glow_opt(srr_uv + fract(srr_g3.xy * srr_time), srr_g3.w);
	vec3 srr_s0 = clamp(srr_opt * srr_tf * srr_g2.a, vec3(0.0), vec3(1.0));
	vec3 srr_s1 = srr_g3.z > 0.5 ? (srr_item + srr_s0 - vec3(0.5)) * 2.0 : srr_item + srr_s0;
	return clamp(srr_s1, vec3(0.0), vec3(1.0));
}
#endif
#endif

void vertex() {
#ifdef CROWD_GPU
	// A far other player's part, drawn as a GPU instance (round 747,
	// CrowdGpu.twin_shader): skinned and placed here first.
#include "res://scripts/world/crowd_gpu_vertex.gdshaderinc"
#endif
#ifdef CROWD_GPU
	// Round 759: a far part takes its body's object colour from the body's
	// texel (CrowdGpu._write_light), so every level is one material.
	srr_od0 = srr_obj_od0(MODEL_NORMAL_MATRIX * NORMAL, srr_color(albedo, OUTPUT_IS_SRGB).rgb,
		srr_cg_objc >= 0.0 ? vec3(srr_cg_objc) : object_color, object_tint);
#else
	srr_od0 = srr_obj_od0(MODEL_NORMAL_MATRIX * NORMAL, srr_color(albedo, OUTPUT_IS_SRGB).rgb, object_color, object_tint);
#endif
	{ float srr_ta = srr_texani_clock - texani_t0; vec3 srr_tu = texani_u + texani_du * srr_ta; vec3 srr_tv = texani_v + texani_dv * srr_ta; vec2 srr_ta_uv = vec2(dot(vec3(UV, 1.0), srr_tu), dot(vec3(UV, 1.0), srr_tv)); srr_uv1 = texani_stage == 1 ? srr_ta_uv : UV; UV = texani_stage == 1 ? UV : srr_ta_uv; }
}

void fragment() {
#ifdef MULTITEX
	vec4 tex = multitex_rev ? texture(multitex_texture, UV) : texture(albedo_texture, UV);
	vec4 srr_t1 = multitex_rev ? texture(albedo_texture, srr_uv1) : texture(multitex_texture, srr_uv1);
#else
	vec4 tex = texture(albedo_texture, UV);
#endif
#ifdef EQUIP_GLOW
#ifdef CROWD_GPU
	ALBEDO = srr_obj_present(srr_glow_row(tex.rgb, UV, srr_glow_clock, srr_cg_g1, srr_cg_g2, srr_cg_g3));
#else
#ifdef OBJECT_NO_PRESENT
	// A Linear view (the portrait, the equipment window): written as is.
	ALBEDO = srr_glow(tex.rgb, UV, srr_glow_clock);
#else
	ALBEDO = srr_obj_present(srr_glow(tex.rgb, UV, srr_glow_clock));
#endif
#endif
#else
#ifdef LIGHTMAP
	ALBEDO = srr_obj_present(srr_lightmapped(tex.rgb, srr_od0, UV2));
#elif defined(MULTITEX)
	ALBEDO = srr_obj_present(srr_multitex(clamp(2.0 * tex.rgb * srr_od0, vec3(0.0), vec3(1.0)), srr_t1));
#else
	ALBEDO = srr_obj_present(clamp(2.0 * tex.rgb * srr_od0, vec3(0.0), vec3(1.0)));
#endif
#endif
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
