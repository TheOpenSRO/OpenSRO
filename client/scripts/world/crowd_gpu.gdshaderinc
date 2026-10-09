// Round 747 (crowd scale A5, docs/protocol/crowd_gpu.md; CrowdGpu): what a
// far other player's body part needs to be skinned in its own vertex shader.
// CrowdGpu.twin_shader puts `#define CROWD_GPU` and this file after the
// render_mode of the body material's own shader; crowd_gpu_vertex.gdshaderinc
// is the code at the top of its vertex(). Everything after that is the
// material's own code, unchanged (OURS: the skin is a compute pass in Godot,
// so the shader math here is new; tools/crowd_gpu_probe.gd holds it to the
// engine's pixels).
//
// Every far body has 5 texels in crowd_bodies (CrowdGpu.TEXELS_PER_BODY, at
// slot % 256 * 5, slot / 256): the rows of its skeleton's global transform,
// then (row of its clip's frame 0, the clip's frame count, its duration in
// ms, the body's offset into it in ms), then (round 759) its object colour
// in x (CrowdGpu._write_light). crowd_bones holds, per skeleton layout,
// one row per baked frame and 3 texels per bone: the rows of the skin matrix
// pose_global(bone) x inverse(global rest), which is what Godot's skeleton
// writes for the shared skin (Skeleton3DBuilder.canonical_skin). crowd_volume
// holds a Volume variant's per-bone factor matrix (rest x scale(1, f, f) x
// inverse rest), so its skin is the baked matrix times that.
uniform sampler2D crowd_bodies : filter_nearest, repeat_disable;
// The bone store in pages of SRR_CG_PAGE_ROWS rows, a layer each (round
// 747's review, F3: a new clip uploads its pages, not the whole store).
uniform sampler2DArray crowd_bones : filter_nearest, repeat_disable;
uniform sampler2D crowd_volume : filter_nearest, repeat_disable;
// Round 759: the glow rows (CrowdGpu._glow_row), 3 texels a row: (c1,
// period), (c2, mul0), (uv speed, signed2x, 0).
uniform sampler2D crowd_glow : filter_nearest, repeat_disable;
// Character Sight Range (VideoOptions.CHARACTER_RANGE): 0 draws every body.
uniform float crowd_range = 0.0;
// Round 762: whether this material's fading bodies are drawn by a fade twin
// (CrowdGpu: false when the material has none, so they stay opaque).
uniform bool crowd_fades = true;
// The clip clock, ms since CrowdGpu's epoch (CrowdGpu.flush).
global uniform float srr_crowd_clock;

// CrowdGpu.TEXELS_PER_BODY (round 759: 5, the fifth the object colour).
const int SRR_CG_TEXELS = 5;
// CrowdAnim.QUANTUM_MS: 1000 / 120.
const float SRR_CG_QUANTUM_MS = 1000.0 / 120.0;
// CrowdGpu.PAGE_ROWS.
const int SRR_CG_PAGE_ROWS = 1024;

// A 3 x 4 matrix stored as three row texels, as a mat4.
mat4 srr_cg_mat(vec4 srr_r0, vec4 srr_r1, vec4 srr_r2) {
	return mat4(vec4(srr_r0.x, srr_r1.x, srr_r2.x, 0.0), vec4(srr_r0.y, srr_r1.y, srr_r2.y, 0.0),
		vec4(srr_r0.z, srr_r1.z, srr_r2.z, 0.0), vec4(srr_r0.w, srr_r1.w, srr_r2.w, 1.0));
}

mat4 srr_cg_bone(int srr_bone, int srr_row) {
	ivec3 srr_at = ivec3(srr_bone * 3, srr_row % SRR_CG_PAGE_ROWS, srr_row / SRR_CG_PAGE_ROWS);
	return srr_cg_mat(texelFetch(crowd_bones, srr_at, 0),
		texelFetch(crowd_bones, srr_at + ivec3(1, 0, 0), 0),
		texelFetch(crowd_bones, srr_at + ivec3(2, 0, 0), 0));
}

// Round 762: a far body's fade, from the fifth texel's y (CrowdGpu._write_fade)
// -- 0 none; 1e6 + the clock (ms) its fade-in began at; -(1e6 + that) for a
// fade-out; 4e6 + k for a page held until its reveal, whose clock is
// srr_crowd_reveal[k] (1e9 while held: alpha 0) -- as AppearFade sets the
// model's byte: 255 / 2.0 s x elapsed, truncated, up to 255 (READ,
// CIDecoAppear); 255 - 255 / 1.5 s x elapsed, truncated, down to 0 (READ,
// CIDecoDisappear). Every part of a far body draws from its mesh's one group;
// the group's opaque instance leaves out a fading body's vertices and its fade
// instance (the same MultiMesh with the blended fade twin) draws only them.
global uniform vec4 srr_crowd_reveal;
float srr_cg_fade(float srr_f) {
	if (srr_f >= 3.5e6) {
		int srr_k = clamp(int(srr_f - 4.0e6 + 0.5), 0, 3);
		float srr_e = max(srr_crowd_clock - srr_crowd_reveal[srr_k], 0.0) / 1000.0;
		return min(floor(255.0 / 2.0 * srr_e), 255.0) / 255.0;
	}
	if (srr_f > 0.0) {
		float srr_e = max(srr_crowd_clock - (srr_f - 1.0e6), 0.0) / 1000.0;
		return min(floor(255.0 / 2.0 * srr_e), 255.0) / 255.0;
	}
	float srr_e = max(srr_crowd_clock - (-srr_f - 1.0e6), 0.0) / 1000.0;
	return max(floor(255.0 - 255.0 / 1.5 * srr_e), 0.0) / 255.0;
}

mat4 srr_cg_volume(int srr_bone, int srr_row) {
	return srr_cg_mat(texelFetch(crowd_volume, ivec2(srr_bone * 3, srr_row), 0),
		texelFetch(crowd_volume, ivec2(srr_bone * 3 + 1, srr_row), 0),
		texelFetch(crowd_volume, ivec2(srr_bone * 3 + 2, srr_row), 0));
}
