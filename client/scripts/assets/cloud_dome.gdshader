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
// The far plane's clip z / w (WorldFog.far_clip_z): 1 before Godot 4.3; from
// 4.3 the depth is reversed and z = w is the NEAR plane -- drawn over
// everything -- so the far plane is 0 under Forward+ (Vulkan's 0..1) and -1
// under Compatibility (OpenGL's -1..1; round 760: 0 there drew the clouds
// over the far scenery).
uniform float far_clip_z = 1.0;
uniform vec3 cloud_color = vec3(1.0);
uniform float cloud_alpha = 0.6;
uniform vec3 fog_color = vec3(1.0);
uniform float fog_start = 90000.0;
uniform float fog_end = 200000.0;

varying float view_depth;

// Round 693's review: under Forward+ the layer would blend into the sky in
// linear space, which made the clouds whiter and denser than Compatibility's
// display-value blend (MEASURED: +24.7 luma in the fog-on Jangan sky's top
// band). The sky behind the layer is analytic -- GammaSkyMaterial's gradient
// and sun in the eye direction -- so under Forward+ (`gamma_blend`, set by
// GammaSkyMaterial.feed_clouds) the layer computes Compatibility's result
// itself: both colours through the tone mapper and encode as Compatibility
// draws them, mixed in display values as its framebuffer blends them, and
// the inverse tone map of that, drawn opaque. OURS on READ (gles3 sky.glsl
// and scene.glsl: decode, exposure, tone map, encode; the Filmic curve as the
// water reflection's inverse, round 628).
uniform bool gamma_blend = false;
uniform vec3 sky_top = vec3(0.385, 0.454, 0.55);
uniform vec3 sky_horizon = vec3(0.646, 0.656, 0.67);
uniform vec3 ground_bottom = vec3(0.2, 0.169, 0.133);
uniform vec3 ground_horizon = vec3(0.646, 0.656, 0.67);
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_color = vec3(1.0);
uniform float sun_energy = 0.0;
uniform float sun_size = 0.0;
uniform float tm_exposure = 1.0;
uniform float tm_white = 1.0;
uniform bool tm_filmic = true;

const float SKY_CURVE = 0.15;
const float GROUND_CURVE = 0.02;
const float SUN_ANGLE_MAX = 0.523599;
const float SUN_CURVE = 0.15;
const float FA = 0.88;
const float FB = 0.6;
const float FC = 0.1;
const float FD = 0.2;
const float FE = 0.01;
const float FF = 0.3;

vec3 enc3(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - vec3(0.055), c * 12.92, lessThan(c, vec3(0.0031308)));
}
vec3 dec3(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}
float filmic_raw(float x) {
	return (x * (FA * x + FC * FB) + FD * FE) / (x * (FA * x + FB) + FD * FF) - FE / FF;
}
vec3 tonemap(vec3 lin) {
	vec3 x = max(lin * tm_exposure, vec3(0.0));
	if (!tm_filmic) {
		return x;
	}
	return vec3(filmic_raw(x.r), filmic_raw(x.g), filmic_raw(x.b)) / filmic_raw(tm_white);
}
float filmic_inv(float t) {
	float u = clamp(t, 0.0, 0.999) * filmic_raw(tm_white) + FE / FF;
	float a = FA * (u - 1.0);
	float b = FB * (u - FC);
	float c = FD * (FF * u - FE);
	float disc = max(b * b - 4.0 * a * c, 0.0);
	return max((-b - sqrt(disc)) / (2.0 * a), 0.0);
}
vec3 untonemap(vec3 t) {
	vec3 x = tm_filmic ? vec3(filmic_inv(t.r), filmic_inv(t.g), filmic_inv(t.b)) : t;
	return x / max(tm_exposure, 0.0001);
}
// GammaSkyMaterial's colour in the eye direction (display values).
vec3 sky_display(vec3 eye) {
	float v_angle = acos(clamp(eye.y, -1.0, 1.0));
	float c = 1.0 - v_angle / (PI * 0.5);
	vec3 sky = mix(sky_horizon, sky_top, clamp(1.0 - pow(1.0 - c, 1.0 / SKY_CURVE), 0.0, 1.0));
	if (sun_energy > 0.0) {
		float sun_angle = acos(clamp(dot(sun_dir, eye), -1.0, 1.0));
		if (sun_angle < sun_size) {
			sky = sun_color * sun_energy;
		} else if (sun_angle < SUN_ANGLE_MAX) {
			float c2 = (sun_angle - sun_size) / (SUN_ANGLE_MAX - sun_size);
			sky = mix(sun_color * sun_energy, sky, clamp(1.0 - pow(1.0 - c2, 1.0 / SUN_CURVE), 0.0, 1.0));
		}
	}
	c = (v_angle - PI * 0.5) / (PI * 0.5);
	vec3 ground = mix(ground_horizon, ground_bottom, clamp(1.0 - pow(1.0 - c, 1.0 / GROUND_CURVE), 0.0, 1.0));
	return mix(ground, sky, step(0.0, eye.y));
}

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
	p.z = far_clip_z * p.w;
	POSITION = p;
}

void fragment() {
	vec4 tex = texture(cloud_tex, UV + uv_offset);
	float f = clamp((fog_end - max(view_depth, 0.0)) / (fog_end - fog_start), 0.0, 1.0);
	ALBEDO = mix(fog_color, tex.rgb * cloud_color, f);
	ALPHA = tex.a * cloud_alpha;
	if (!OUTPUT_IS_SRGB) {
		vec3 c = clamp(ALBEDO, 0.0, 1.0);
		if (gamma_blend) {
			vec3 eye = normalize((INV_VIEW_MATRIX * vec4(VERTEX, 0.0)).xyz);
			vec3 sky_out = enc3(tonemap(dec3(sky_display(eye))));
			vec3 cloud_out = enc3(tonemap(dec3(c)));
			ALBEDO = untonemap(dec3(mix(sky_out, cloud_out, clamp(ALPHA, 0.0, 1.0))));
			ALPHA = 1.0;
		} else {
			ALBEDO = dec3(c);
		}
	}
}
