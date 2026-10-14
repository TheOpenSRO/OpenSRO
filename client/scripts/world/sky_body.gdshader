// The sun disc or the moon (round 786, DayCycle; READ Map::FUN_00a207a0 and
// Map::FUN_00a20d60, sky_bodies.gdshaderinc): a quad at `body_dir` x 20000
// from the eye, drawn as the cloud layer is drawn (cloud_dome.gdshader) --
// without the camera's translation, pinned to the far plane (z = far_clip_z
// w) with the depth test on, so everything the camera draws covers it, and
// before the clouds (render priority -128 / -127 against the clouds' -126),
// as retail's sky step draws the sun, then the moon, then the clouds with Z
// off before the landscape.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, fog_disabled, skip_vertex_transform;

#include "res://scripts/world/sky_bodies.gdshaderinc"

uniform sampler2D body_tex : filter_linear, repeat_disable, hint_default_transparent;
uniform vec3 body_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 body_axis = vec3(-1.0, 0.0, 0.0);
uniform float half_ratio = 0.0333333;
// The sun disc: colour = this (SunColor, display values), alpha the texture's.
// The moon: the texture's colour and alpha (body_color unused).
uniform bool flat_color = true;
uniform vec3 body_color = vec3(1.0);
uniform float far_clip_z = 1.0;

varying vec3 eye_world;

void vertex() {
	// VERTEX.xy is the corner (y, z) in [-1, 1]; the quad is built here.
	vec3 zf = vec3(0.0, 0.0, -1.0);
	vec3 offset = body_dir + (body_axis * VERTEX.x + zf * VERTEX.y) * half_ratio;
	eye_world = offset;
	vec3 v = (VIEW_MATRIX * vec4(offset, 0.0)).xyz;
	vec4 p = PROJECTION_MATRIX * vec4(v, 1.0);
	p.z = far_clip_z * p.w;
	POSITION = p;
}

void fragment() {
	vec3 uv = srr_body_uv(normalize(eye_world), body_dir, body_axis, half_ratio);
	vec4 t = uv.z > 0.0 ? textureLod(body_tex, uv.xy, 0.0) : vec4(0.0);
	vec3 c = flat_color ? body_color : t.rgb;
	ALBEDO = c;
	ALPHA = clamp(t.a, 0.0, 1.0);
	// Display values, decoded where the output is linear (ShaderColour).
	if (!OUTPUT_IS_SRGB) {
		ALBEDO = mix(pow((max(c, vec3(0.0)) + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), max(c, vec3(0.0)) * (1.0 / 12.92), lessThan(max(c, vec3(0.0)), vec3(0.04045)));
	}
}
