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
// - linear fog from 90,000 to 200,000 (D3DRS_FOGSTART / FOGEND), with the
//   world's fog colour;
// - Z off, drawn before the terrain. Here the layer is pinned to the far
//   plane with its depth test on, which draws it behind everything the same
//   way (OURS: a transparent material cannot be ordered before the opaque
//   pass in Godot).
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, fog_disabled, skip_vertex_transform;

uniform sampler2D cloud_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec2 uv_offset = vec2(0.0);
uniform vec3 cloud_color = vec3(1.0);
uniform float cloud_alpha = 0.6;
uniform vec3 fog_color = vec3(1.0);
uniform float fog_start = 90000.0;
uniform float fog_end = 200000.0;

varying float eye_dist;

void vertex() {
	// VERTEX is the offset from the eye (the mesh sits at the origin). Rotate
	// it into view space without the camera's translation.
	vec3 v = (VIEW_MATRIX * vec4(VERTEX, 0.0)).xyz;
	VERTEX = v;
	eye_dist = length(v);
	vec4 p = PROJECTION_MATRIX * vec4(v, 1.0);
	// At the far plane: behind every surface, never clipped by it.
	p.z = p.w * 0.99999;
	POSITION = p;
}

void fragment() {
	vec4 tex = texture(cloud_tex, UV + uv_offset);
	float f = clamp((fog_end - eye_dist) / (fog_end - fog_start), 0.0, 1.0);
	ALBEDO = mix(fog_color, tex.rgb * cloud_color, f);
	ALPHA = tex.a * cloud_alpha;
}
