// Shared body of foliage.gdshader (two-sided) and foliage_one_sided.gdshader
// (one-sided): a layer the client draws alpha-tested or two-sided -- leaf
// cards, needle cards, grass (ObjectLoader.layer_draw_rule, READ in round
// 625). The cull mode is the only difference, and a render_mode.
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
// The alpha test's threshold: ObjectLoader.ALPHA_TEST_REF / 255 for a
// layer whose flag word asks for the test (0x200, READ round 625), 1/255
// under an env-map mod that asks for its own, and 0 for none -- then every
// texel is kept, as the client draws a two-sided solid layer.
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.50196;
#ifdef APPEAR_FADE
// A character fading into existence (AppearFade, round 676): the model's
// alpha, 0 to 1 over the fade. Only the *_fade.gdshader variants define
// APPEAR_FADE; the shaders the world draws with compile without it.
uniform float appear_alpha : hint_range(0.0, 1.0) = 1.0;
#endif

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	ALBEDO = albedo.rgb * tex.rgb;

	// Test the cutout against full-resolution alpha, not the mipmapped
	// alpha.
	//
	// A leaf card's texture is mostly holes, so each mip level averages a
	// leaf's own alpha together with the gaps around it and the card's
	// alpha falls as it recedes. Against a fixed cutout that makes leaves
	// wink out a mip level at a time, and a canopy a few hundred units off
	// collapses to bare branches -- reported from the fields outside
	// Jangan, where the tree overhead rendered fully and its neighbours
	// were skeletons.
	//
	// Colour still comes from the mipmapped sample, so the foliage does
	// not shimmer; only the keep-or-discard decision reads mip 0, which is
	// what preserves the canopy's shape at distance.
	//
	// Note for anyone tempted to "sharpen" the mipmapped alpha instead:
	// rescaling it around the threshold cannot work, because any monotonic
	// rescale crosses the threshold exactly where the original did and a
	// hard scissor discards the identical texels. That was tried here and
	// measured as a zero-pixel change.
	//
	// OURS, not the client's: retail tests the filtered, mipmapped alpha;
	// mip 0 is this project's answer to the canopy dissolving with distance.
#ifdef APPEAR_FADE
	// The same keep-or-discard test, made by hand, so the drawn alpha can be
	// the fade's: a blended draw cannot also take Godot's scissor (OURS).
	if (alpha_scissor > 0.0 && albedo.a * textureLod(albedo_texture, UV, 0.0).a < alpha_scissor) {
		discard;
	}
	ALPHA = appear_alpha;
#else
	ALPHA = alpha_scissor > 0.0 ? albedo.a * textureLod(albedo_texture, UV, 0.0).a : 1.0;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor;
#endif
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}
