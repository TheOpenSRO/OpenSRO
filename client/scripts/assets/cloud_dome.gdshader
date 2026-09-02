shader_type spatial;
render_mode unshaded, cull_front, blend_mix, depth_draw_never;

// Real cloud1.ddj texture (see World3D._build_cloud_dome's doc comment for
// where this asset comes from). SphereMesh's auto-generated UV is a polar
// projection that compresses an entire ring of the mesh into a single point
// at the dome's pole (the zenith, since is_hemisphere=true puts the pole
// straight up) -- a real, confirmed projection singularity (see
// docs/WORLD_ISSUES.md's thirty-fifth/forty-second rounds), not fixable by
// UV tiling/scale alone. This shader doesn't try to fix the projection
// itself (no real per-pixel sky-dome UV data exists to build a better one
// from) -- it instead fades the real cloud texture's alpha to zero before
// the singularity is ever visible, so the compressed/sunburst pixels never
// render at all. Below pole_fade_start, the real texture shows completely
// normally, unmodified.
uniform sampler2D cloud_tex : source_color, filter_linear, repeat_enable;
uniform vec2 uv_offset = vec2(0.0);
uniform float pole_fade_start : hint_range(0.0, 1.0) = 0.8;
uniform float base_alpha : hint_range(0.0, 1.0) = 0.6;

varying float pole_closeness;

void vertex() {
	// Object-space vertex direction from the dome's own center -- for a
	// sphere/hemisphere this is exactly the surface normal, and its Y
	// component is 1.0 only at the true pole (straight up), falling off
	// smoothly toward the horizon ring at Y=0. Real, exact geometry, not an
	// approximation.
	pole_closeness = normalize(VERTEX).y;
}

void fragment() {
	vec4 tex = texture(cloud_tex, UV + uv_offset);
	float fade = 1.0 - smoothstep(pole_fade_start, 1.0, pole_closeness);
	ALBEDO = tex.rgb;
	ALPHA = tex.a * base_alpha * fade;
}
