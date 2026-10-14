// The sun disc and the moon as the retail sky step draws them (round 786,
// DayCycle; READ Map::FUN_00a207a0 and Map::FUN_00a20d60): a quad facing the
// eye at `dir` x 20000, `half_ratio` = half-size / 20000 (666.67 / 20000 for
// the sun, 1000 / 20000 for the moon), its corners the table at 0xec554c --
// (y, z) = (-1, 1), (1, 1), (1, -1), (-1, -1) with uv (0, 0), (1, 0), (1, 1),
// (0, 1) -- turned about z by the body's angle, so its y runs along `axis_u`
// = (-sin a, cos a, 0) and its z along the file's +z (Godot's -z).
//
// Shared by the bodies' own quads (sky_body.gdshader) and the cloud layer's
// Forward+ blend (cloud_dome.gdshader's sky_display), so both find the same
// texel for an eye direction.
//
// srr_body_uv: where unit `eye` (world axes) meets the body's quad -- xy the
// texture coordinate, z 1.0 on the quad and 0.0 off it. Analytic: the eye ray
// meets the quad's plane at eye / dot(eye, dir) (in units of the distance).
vec3 srr_body_uv(vec3 eye, vec3 dir, vec3 axis_u, float half_ratio) {
	float ed = dot(eye, dir);
	if (ed <= 0.0) {
		return vec3(0.0);
	}
	vec3 p = eye / ed - dir;
	float cy = dot(p, axis_u) / half_ratio;
	float cz = -p.z / half_ratio;
	if (abs(cy) > 1.0 || abs(cz) > 1.0) {
		return vec3(0.0);
	}
	return vec3((cy + 1.0) * 0.5, (1.0 - cz) * 0.5, 1.0);
}
