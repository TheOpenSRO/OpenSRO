shader_type spatial;
render_mode cull_disabled;

// Real cutout foliage (leaf cards, grass, anything whose real texture
// carries a real alpha cutout -- see ObjectLoader.build_godot_material).
//
// This exists for one reason: to reproduce the real client's own lighting
// for a double-sided card, which Godot's StandardMaterial3D cannot express.
//
// The real client lights objects **per-vertex, in its own vertex shader**,
// from the vertex's authored normal, with no facing test anywhere
// (Data.pk2's real `Shader\vertexshader0.c`):
//
//     dp3 r1.x, v3, c[VSC_DLIGHT_DIRECTION]      ; normal dot light
//     max r1.x, r1.x, c[VSC_UTIL].z              ; clamp to >= 0
//     mov r6, c[VSC_DLIGHT_AMBIENT]
//     mad oD0, r1.x, c[VSC_DLIGHT_DIFFUSE], r6   ; saturate(N.L)*diffuse + ambient
//
// Because that result is a single vertex colour, both faces of a real
// double-sided card are lit **identically** -- the back face is not
// flipped. Godot does flip NORMAL on back faces, which matters enormously
// here: the real willow canopy meshes are authored with *every* normal
// pointing straight up (measured: 156/156 and 68/68 vertices at exactly
// (0,1,0)), so under Godot's flip the underside of a canopy shades as if
// it faced away from the sun and collapses to ambient alone. With this
// project's real per-zone ambient being a blue-grey, that rendered every
// canopy as a dark navy plane when stood under -- a real reported bug.
//
// Undoing the flip restores the authored normal on both faces, which is
// what the real client's own maths does.

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.5;

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	ALBEDO = albedo.rgb * tex.rgb;
	ALPHA = albedo.a * tex.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}
