// Round 747 (CrowdGpu): the top of a far body part's vertex(), with
// crowd_gpu.gdshaderinc included above. It replaces what Godot's skinning
// pass (servers/rendering/renderer_rd/shaders/skeleton.glsl, 4.2.2) and the
// mesh instance's transform do for a near body:
//   m = sum of weight x bone matrix over the vertex's four bones,
//   vertex = m x vertex, normal = normalize(m x normal) (the pass's order);
// then the body's skeleton transform, written straight into VERTEX (the
// MultiMesh's instance transform is the identity, so MODEL_MATRIX is too) and
// its basis into NORMAL: for an instance whose scale is uniform (Height)
// Godot's MODEL_NORMAL_MATRIX is mat3(MODEL_MATRIX) itself, not its inverse
// transpose (scene_forward_clustered.glsl:210-214 and the Compatibility
// scene.glsl:318-323, 4.2.2, READ), so a near body's normal carries its
// Height and so does this one.
// INSTANCE_CUSTOM: x the body's slot, y its Volume row (-1: none), z the
// part's rest centre height, for Character Sight Range.
{
	int srr_cg_slot = int(INSTANCE_CUSTOM.x + 0.5);
	ivec2 srr_cg_at = ivec2((srr_cg_slot % 256) * 4, srr_cg_slot / 256);
	vec4 srr_cg_b0 = texelFetch(crowd_bodies, srr_cg_at, 0);
	vec4 srr_cg_b1 = texelFetch(crowd_bodies, srr_cg_at + ivec2(1, 0), 0);
	vec4 srr_cg_b2 = texelFetch(crowd_bodies, srr_cg_at + ivec2(2, 0), 0);
	vec4 srr_cg_an = texelFetch(crowd_bodies, srr_cg_at + ivec2(3, 0), 0);
	// The frame CrowdAnim.frame_index takes: the nearest quantum of the
	// body's time into its loop.
	int srr_cg_count = max(int(srr_cg_an.y + 0.5), 1);
	float srr_cg_ms = mod(srr_crowd_clock + srr_cg_an.w, max(srr_cg_an.z, 1.0));
	int srr_cg_row = int(srr_cg_an.x + 0.5) + int(srr_cg_ms / SRR_CG_QUANTUM_MS + 0.5) % srr_cg_count;
	int srr_cg_vol = int(floor(INSTANCE_CUSTOM.y + 0.5));
	mat4 srr_cg_m = mat4(0.0);
	for (int srr_k = 0; srr_k < 4; srr_k++) {
		float srr_w = BONE_WEIGHTS[srr_k];
		if (srr_w > 0.0) {
			int srr_bone = int(BONE_INDICES[srr_k]);
			mat4 srr_kb = srr_cg_bone(srr_bone, srr_cg_row);
			if (srr_cg_vol >= 0) {
				srr_kb = srr_kb * srr_cg_volume(srr_bone, srr_cg_vol);
			}
			srr_cg_m += srr_kb * srr_w;
		}
	}
	vec3 srr_cg_v = (srr_cg_m * vec4(VERTEX, 1.0)).xyz;
	vec3 srr_cg_n = normalize(mat3(srr_cg_m) * NORMAL);
	mat4 srr_cg_body = srr_cg_mat(srr_cg_b0, srr_cg_b1, srr_cg_b2);
	VERTEX = (srr_cg_body * vec4(srr_cg_v, 1.0)).xyz;
	NORMAL = mat3(srr_cg_body) * srr_cg_n;
	// Character Sight Range: Godot cuts a near part by the camera's distance
	// to its bounds' centre; here to the body's axis at the part's rest centre
	// height (OURS, within a part's half width of the engine's test).
	if (crowd_range > 0.0) {
		vec3 srr_cg_c = (srr_cg_body * vec4(0.0, INSTANCE_CUSTOM.z, 0.0, 1.0)).xyz;
		if (distance(srr_cg_c, INV_VIEW_MATRIX[3].xyz) > crowd_range) {
			VERTEX = vec3(0.0);
		}
	}
}
