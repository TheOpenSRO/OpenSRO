// The water surface with the Water Reflection option on (round 628): what
// sro_client's Map::FUN_00a2df70 draws. WaterReflection (water_reflection.gd)
// holds the READ rules and feeds the uniforms each frame.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// The mirrored render (READ: world+0x27bb, sampled WRAP). Sampled raw: it
// holds what the screen would show, already tone-mapped and encoded.
uniform sampler2D reflection_tex : filter_linear, repeat_enable;
// waterbump3.ddj's gradient as (du, dv) in RG, 128 = 0 (READ: FUN_009f2050;
// stage 0's sampler CLAMPs).
uniform sampler2D bump_tex : filter_linear, repeat_disable;
// water201.ddj, for PlaneType-1 blocks, raw like the reflection.
uniform sampler2D still_tex : filter_linear_mipmap, repeat_enable;
// WaterColor (environment channel 14), the texture factor's RGB.
uniform vec3 water_color = vec3(1.0);
// D3DTSS_BUMPENVMAT00, 01, 10, 11.
uniform vec4 bump_mat = vec4(0.04, 0.0, 0.0, 0.04);
// world+0x26bb: the camera is below the reflection plane over a water block.
uniform bool underwater = false;
// A PlaneType-1 block (pass B).
uniform bool still = false;
// The screen's tone map, undone so the modulate happens on displayed values.
uniform float tonemap_exposure = 1.0;
uniform float tonemap_white = 1.0;
uniform bool tonemap_filmic = true;
// QA only (SRREVAMP_QA_WATER_OUTMODE): 1 writes the displayed value straight.
uniform int qa_output_mode = 0;
// Retail's vertical squeeze (READ): the texture matrix's 0.8 over its
// projection's P22 / 2 = 0.866 (fovy 60 degrees).
const float V_SQUEEZE = 0.8 / 0.8660254;

// Godot 4.2's filmic curve (drivers/gles3 tonemap_inc: exposure bias 2
// folded into A and B).
const float TA = 0.88;
const float TB = 0.6;
const float TC = 0.1;
const float TD = 0.2;
const float TE = 0.01;
const float TF = 0.3;

float filmic_raw(float x) {
	return (x * (TA * x + TC * TB) + TD * TE) / (x * (TA * x + TB) + TD * TF) - TE / TF;
}

// The x >= 0 the filmic curve maps to t (t in [0, 1]).
float filmic_inverse(float t) {
	float u = clamp(t, 0.0, 0.999) * filmic_raw(tonemap_white) + TE / TF;
	float a = TA * (u - 1.0);
	float b = TB * (u - TC);
	float c = TD * (TF * u - TE);
	float disc = max(b * b - 4.0 * a * c, 0.0);
	return max((-b - sqrt(disc)) / (2.0 * a), 0.0);
}

vec3 srgb_to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}

vec3 linear_to_srgb(vec3 c) {
	return mix(1.055 * pow(max(c, vec3(0.0)), vec3(1.0 / 2.4)) - vec3(0.055), c * 12.92, lessThan(c, vec3(0.0031308)));
}

// The ALBEDO an unshaded material needs for the screen to show d. MEASURED
// on the box (a grey ramp written as ALBEDO, read back from the screen,
// round 628 review follow-up): this renderer shows srgb(T(lin(a) *
// exposure)) for an unshaded ALBEDO a, T Godot 4.2's filmic curve (rms 1.7
// of 255 over 19 steps). So a = srgb(T^-1(lin(d)) / exposure).
vec3 undo_output(vec3 d) {
	vec3 lin = srgb_to_linear(clamp(d, 0.0, 1.0));
	if (tonemap_filmic) {
		lin = vec3(filmic_inverse(lin.r), filmic_inverse(lin.g), filmic_inverse(lin.b));
	}
	return linear_to_srgb(lin / max(tonemap_exposure, 0.0001));
}

void fragment() {
	// The bump stage's texcoords run 0..1 with u along the block's z (READ:
	// the vertex order); the mesh's UV runs 0..4 with u along x.
	vec2 buv = vec2(UV.y, UV.x) * 0.25;
	vec2 d = texture(bump_tex, buv).rg * (255.0 / 128.0) - vec2(1.0);
	// D3D: u' = u + du*M00 + dv*M10, v' = v + du*M01 + dv*M11.
	vec2 off = vec2(d.x * bump_mat.x + d.y * bump_mat.z, d.x * bump_mat.y + d.y * bump_mat.w);
	// READ texture matrix: u = 0.65 x/z + 0.5 -- exactly the screen's u for
	// retail's 4:3, 60-degree projection -- and v = 0.48 + 0.8 y/z above
	// water, 0.52 - 0.8 y/z under it. Retail's projection has 0.866 where
	// the matrix has 0.8, so its reflection is squeezed to 0.924 vertically
	// and 0.02 off; that misregistration is reproduced (relative to this
	// camera's frame), which also keeps v inside 0..1 at the screen's edge.
	// yz is 0.8 y/z in retail's terms: V_SQUEEZE times the exact offset.
	float yz = (0.5 - SCREEN_UV.y) * V_SQUEEZE / 0.8;
	float u = SCREEN_UV.x;
	vec3 disp;
	if (underwater) {
		vec3 refl = texture(reflection_tex, vec2(u, 0.52 - 0.8 * yz) + off).rgb;
		disp = refl * water_color * (128.0 / 255.0);
		ALPHA = 200.0 / 255.0;
	} else if (still) {
		// Pass B has no bump stage: stage 0 is water201.
		vec3 refl = texture(reflection_tex, vec2(u, 0.48 + 0.8 * yz)).rgb;
		disp = mix(refl, texture(still_tex, UV * 0.25).rgb, 200.0 / 255.0);
		ALPHA = 200.0 / 255.0;
	} else {
		vec3 refl = texture(reflection_tex, vec2(u, 0.48 + 0.8 * yz) + off).rgb;
		disp = refl * water_color;
		ALPHA = COLOR.a;
	}
	ALBEDO = qa_output_mode == 1 ? disp : undo_output(disp);
	// ALBEDO is a display value, as Compatibility decodes it; Forward+ takes
	// it as linear, so decode it there (ShaderColour, round 693).
	if (!OUTPUT_IS_SRGB) {
		ALBEDO = srgb_to_linear(clamp(ALBEDO, 0.0, 1.0));
	}
	if (qa_output_mode == 2) {
		ALBEDO = vec3(SCREEN_UV.x);
		ALPHA = 1.0;
	}
}
