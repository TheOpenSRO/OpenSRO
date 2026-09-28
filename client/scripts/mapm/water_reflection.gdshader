// The water surface with the Water Reflection option on (round 628): what
// sro_client's Map::FUN_00a2df70 draws. WaterReflection (water_reflection.gd)
// holds the READ rules and feeds the uniforms each frame.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// The 512-row mirrored render (READ: world+0x27bb, sampled WRAP).
uniform sampler2D reflection_tex : source_color, filter_linear, repeat_enable;
// waterbump3.ddj's gradient as (du, dv) in RG, 128 = 0 (READ: FUN_009f2050).
uniform sampler2D bump_tex : filter_linear, repeat_enable;
// water201.ddj, for PlaneType-1 blocks.
uniform sampler2D still_tex : source_color, filter_linear_mipmap, repeat_enable;
// WaterColor (environment channel 14), the texture factor's RGB.
uniform vec3 water_color = vec3(1.0);
// D3DTSS_BUMPENVMAT00, 01, 10, 11.
uniform vec4 bump_mat = vec4(0.04, 0.0, 0.0, 0.04);
// world+0x26bb: the camera is below the reflection plane over a water block.
uniform bool underwater = false;
// A PlaneType-1 block (pass B).
uniform bool still = false;
// The texture matrix's v offset past a plain screen mapping (READ: 0.48 and
// 0.52 where 0.5 would be).
uniform float v_bias = 0.02;

void fragment() {
	// The mesh's UV runs 0..4 across a block, u along x. The bump stage's
	// texcoords run 0..1 with u along the block's z (READ: the vertex order).
	vec2 buv = vec2(UV.y, UV.x) * 0.25;
	vec2 d = texture(bump_tex, buv).rg * (255.0 / 128.0) - vec2(1.0);
	// D3D: u' = u + du*M00 + dv*M10, v' = v + du*M01 + dv*M11.
	vec2 off = vec2(d.x * bump_mat.x + d.y * bump_mat.z, d.x * bump_mat.y + d.y * bump_mat.w);
	if (underwater) {
		vec3 refl = texture(reflection_tex, vec2(SCREEN_UV.x, SCREEN_UV.y + v_bias) + off).rgb;
		ALBEDO = refl * water_color * (128.0 / 255.0);
		ALPHA = 200.0 / 255.0;
	} else if (still) {
		// Pass B has no bump stage: stage 0 is water201.
		vec3 refl = texture(reflection_tex, vec2(SCREEN_UV.x, 1.0 - SCREEN_UV.y - v_bias)).rgb;
		ALBEDO = mix(refl, texture(still_tex, UV * 0.25).rgb, 200.0 / 255.0);
		ALPHA = 200.0 / 255.0;
	} else {
		vec3 refl = texture(reflection_tex, vec2(SCREEN_UV.x, 1.0 - SCREEN_UV.y - v_bias) + off).rgb;
		ALBEDO = refl * water_color;
		ALPHA = COLOR.a;
	}
}
