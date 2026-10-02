// The cloud layer, drawn as the retail client draws it (round 628 review
// follow-up): Map::FUN_00a3f570, reached from the sky step of the landscape
// pass (FUN_00a26f60 -> FUN_00a19330). READ:
// - the camera's position is zeroed for the sky step and the far plane is
//   5,000,000, so the layer sits at a fixed offset from the eye: no parallax;
// - the mesh is a flat 5x5-vertex grid at y = 20000, x and z in
//   [-4,000,000, 4,000,000] (step 2,000,000), u and v in [-32, 32] (step 16)
//   -- one cloud1.ddj repeat per 125,000 units (FUN_00a3de90);
// - u scrolls by frac(GetTickCount() / 500000) (texture matrix _31, TTFF
//   COUNT2);
// - colour = texture x TFACTOR RGB (environment channel 4), alpha = texture
//   alpha x TFACTOR alpha (world+0x68c7 = (channel 12 + 1) / 2);
// - linear fog from 90,000 to 200,000 (D3DRS_FOGSTART / FOGEND) in view
//   depth, not distance (D3DRS_RANGEFOGENABLE is set 0 in FUN_00a26f60),
//   with the world's fog colour (D3DRS_FOGCOLOR = sqrt of channel 9,
//   EnvironmentReader.render_fog_color);
// - Z off, drawn before the terrain. Here the layer is pinned to depth 1.0
//   (z = w, the far plane itself) with its depth test on, which draws it
//   behind everything the same way (OURS: a transparent material cannot be
//   ordered before the opaque pass in Godot). Until the rounds 623-628
//   integration review it sat at z = 0.99999 w, which with a 0.05 near and
//   11,520 far is a view depth of about 5,400: opaque geometry beyond that
//   was painted over by the clouds (MEASURED).
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, fog_disabled, skip_vertex_transform;

// Raw: the arithmetic below is in display values, decoded at the end where
// the output is linear (ShaderColour, round 693).
uniform sampler2D cloud_tex : filter_linear_mipmap, repeat_enable;
uniform vec2 uv_offset = vec2(0.0);
uniform vec3 cloud_color = vec3(1.0);
uniform float cloud_alpha = 0.6;
uniform vec3 fog_color = vec3(1.0);
uniform float fog_start = 90000.0;
uniform float fog_end = 200000.0;

varying float view_depth;

void vertex() {
	// VERTEX is the offset from the eye (the mesh sits at the origin). Rotate
	// it into view space without the camera's translation.
	vec3 v = (VIEW_MATRIX * vec4(VERTEX, 0.0)).xyz;
	VERTEX = v;
	// View depth (view space looks down -z); affine in the vertex, so it
	// interpolates exactly.
	view_depth = -v.z;
	vec4 p = PROJECTION_MATRIX * vec4(v, 1.0);
	// Depth 1.0: behind every surface the camera can draw, and on (not past)
	// the far clip plane, so never clipped by it.
	p.z = p.w;
	POSITION = p;
}

void fragment() {
	vec4 tex = texture(cloud_tex, UV + uv_offset);
	float f = clamp((fog_end - max(view_depth, 0.0)) / (fog_end - fog_start), 0.0, 1.0);
	ALBEDO = mix(fog_color, tex.rgb * cloud_color, f);
	if (!OUTPUT_IS_SRGB) {
		vec3 c = clamp(ALBEDO, 0.0, 1.0);
		ALBEDO = mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
	}
	ALPHA = tex.a * cloud_alpha;
}
