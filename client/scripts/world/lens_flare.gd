extends Node3D
class_name LensFlare

## The Lens Flare row's flare (round 786): the sun's glow and its ghosts, as
## `Map::FUN_00a21280` draws them from SWorld::vslot_005 (0xa2dbb1) while the
## row is on (world +0x2e84, round 694), outside a dungeon, in the sky mode
## both other flags of the call (world +0x2eb4 clear, +0x2e5c == 1) leave on
## in the field. It replaced the SkyBox\glow.ddj sprite this client drew as
## its sun until round 786 -- a texture retail loads (world +0x27db,
## `Map::FUN_00a0d1b0`) and never draws (its only reads are the release at
## 0x9f66b3), and whose every texel is (252, 58, 4): the red sun.
##
## READ:
## - the twelve elements' textures `sun\lens%d.ddj` % (1 + the byte table at
##   0xec587c: 6, 5, 2, 6, 5, 6, 3, 6, 5, 6, 4, 5) and sizes (the floats at
##   0xec58a0: 30, 40, 150, 30, 40, 50, 300, 40, 30, 50, 0, 30); a size of 0
##   is skipped;
## - element 2 is the sun's glow, at the sun's own place, its quad +-2 x 150
##   = +-300 PIXELS (pre-transformed XYZRHW vertices, FVF 0x104), drawn
##   SRCALPHA / INVSRCALPHA; the others SRCALPHA / ONE (D3DRS_DESTBLEND 2,
##   set 6 for element 2 only);
## - colour = the texture's (COLOROP MODULATE with a TFACTOR of 0xffffff),
##   alpha = the texture's x a byte: 10 for elements 0-1, 255 for 2, 20 for
##   3-9, 20 + (10 - i) after -- times the visibility;
## - nothing is drawn when the sun projects outside [-1.1, 1.1] (0xde4d80,
##   0xde4d78) or behind the eye, or while the visibility is not above 0.1
##   (0xe1b8c0);
## - the visibility's target is 0.3 (0xdd9258) when a screen test at the
##   sun's projected point passes, plus 0.175 (0xde4da8) for each of four
##   points around it, 10 and 20 pixels x width / 1024 away (0xe1b840,
##   0xe1b830, 0xde48b0); it is eased at 10 a second (0x1101818 = 10.0,
##   FUN_009c7b90 / FUN_009c7bc0).
## OURS / INFERRED here:
## - the screen test is the depth buffer at the point holding nothing (the
##   sky), and the four points a +-10 px x width / 1024 cross (the exact
##   offsets of the decompile's walk were not resolved);
## - the target is used at once, not eased (the shader keeps no state);
## - the ghosts lie on the line from the sun through the screen's centre,
##   element i at sun + (i - 2) / 19 x 2.2 x (centre - sun) (the constants
##   2.2 at 0xde4da0 and 19.0 at 0xdd7c90 are READ; the decompile's operands
##   around them were not resolved, nor the 0.5-a-frame smoothing it applies);
## - a ghost's quad is +-size pixels (element 2's is +-2 x size, READ).

const TEXTURE_INDEX := [6, 5, 2, 6, 5, 6, 3, 6, 5, 6, 4, 5]
const SIZES := [30.0, 40.0, 150.0, 30.0, 40.0, 50.0, 300.0, 40.0, 30.0, 50.0, 0.0, 30.0]
const SUN_ELEMENT := 2

static func element_alpha(i: int) -> int:
	if i < 2:
		return 10
	if i == 2:
		return 255
	if i > 9:
		return 20 + (10 - i)
	return 20

## The texture of element i: "Sun\lens<n>.ddj".
static func element_texture(i: int) -> String:
	return "Sun\\lens%d.ddj" % (int(TEXTURE_INDEX[i]) + 1)

const SHADER := """
shader_type spatial;
render_mode unshaded, %s, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled, shadows_disabled, skip_vertex_transform;
uniform sampler2D srr_depth : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D lens3 : filter_linear, repeat_disable, hint_default_transparent;
uniform sampler2D lens4 : filter_linear, repeat_disable, hint_default_transparent;
uniform sampler2D lens5 : filter_linear, repeat_disable, hint_default_transparent;
uniform sampler2D lens6 : filter_linear, repeat_disable, hint_default_transparent;
uniform sampler2D lens7 : filter_linear, repeat_disable, hint_default_transparent;
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform bool reverse_z = false;
uniform bool flare_on = false;
// QA only: >= 0 replaces the depth tests' visibility.
uniform float qa_visibility = -1.0;
varying flat int elem;
varying vec2 sun_uv;
varying vec2 corner_uv;
varying float base_alpha;

const float SIZES[12] = float[](30.0, 40.0, 150.0, 30.0, 40.0, 50.0, 300.0, 40.0, 30.0, 50.0, 0.0, 30.0);
const int TEX[12] = int[](6, 5, 2, 6, 5, 6, 3, 6, 5, 6, 4, 5);

void vertex() {
	elem = int(VERTEX.z + 0.5);
	corner_uv = UV;
	vec3 v = (VIEW_MATRIX * vec4(sun_dir, 0.0)).xyz;
	vec4 c = PROJECTION_MATRIX * vec4(v * 1000.0, 1.0);
	vec2 ndc = c.xy / max(c.w, 0.0001);
	bool hide = !flare_on || c.w <= 0.0 || abs(ndc.x) > 1.1 || abs(ndc.y) > 1.1 || SIZES[elem] <= 0.0;
	sun_uv = ndc * 0.5 + 0.5;
	float k = (float(elem) - 2.0) / 19.0;
	vec2 pos = ndc + k * 2.2 * (vec2(0.0) - ndc);
	float half_px = elem == 2 ? 2.0 * SIZES[elem] : SIZES[elem];
	int a = elem < 2 ? 10 : (elem == 2 ? 255 : (elem > 9 ? 20 + (10 - elem) : 20));
	base_alpha = float(a) / 255.0;
	POSITION = hide ? vec4(3.0, 3.0, 0.5, 1.0) : vec4(pos + VERTEX.xy * half_px * 2.0 / VIEWPORT_SIZE, 0.5, 1.0);
}

bool sky_at(vec2 uv) {
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
		return false;
	}
	float d = textureLod(srr_depth, uv, 0.0).r;
	return reverse_z ? d <= 0.0 : d >= 1.0;
}

void fragment() {
	float vis = qa_visibility;
	if (vis < 0.0) {
		vec2 px = vec2(10.0 * VIEWPORT_SIZE.x / 1024.0) / VIEWPORT_SIZE;
		vis = (sky_at(sun_uv) ? 0.3 : 0.0)
			+ (sky_at(sun_uv + vec2(px.x, 0.0)) ? 0.175 : 0.0) + (sky_at(sun_uv - vec2(px.x, 0.0)) ? 0.175 : 0.0)
			+ (sky_at(sun_uv + vec2(0.0, px.y)) ? 0.175 : 0.0) + (sky_at(sun_uv - vec2(0.0, px.y)) ? 0.175 : 0.0);
	}
	if (vis <= 0.1) {
		discard;
	}
	int t = TEX[elem];
	vec4 tex = t == 2 ? texture(lens3, corner_uv) : (t == 3 ? texture(lens4, corner_uv) : (t == 4 ? texture(lens5, corner_uv)
		: (t == 5 ? texture(lens6, corner_uv) : texture(lens7, corner_uv))));
	vec3 c = tex.rgb;
	ALPHA = clamp(tex.a * round(base_alpha * 255.0 * vis) / 255.0, 0.0, 1.0);
	ALBEDO = c;
	if (!OUTPUT_IS_SRGB) {
		vec3 s = max(c, vec3(0.0));
		ALBEDO = mix(pow((s + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), s * (1.0 / 12.92), lessThan(s, vec3(0.04045)));
	}
}
"""

var _sun_mat: ShaderMaterial
var _ghost_mat: ShaderMaterial
var _sun_mesh: MeshInstance3D
var _ghost_mesh: MeshInstance3D

## Builds the flare from the five lens textures (lens3..lens7, any may be
## null: its elements then draw nothing).
func setup(textures: Dictionary) -> void:
	var sun_sh := Shader.new()
	sun_sh.code = SHADER % "blend_mix"
	var ghost_sh := Shader.new()
	ghost_sh.code = SHADER % "blend_add"
	_sun_mat = ShaderMaterial.new()
	_sun_mat.shader = sun_sh
	_ghost_mat = ShaderMaterial.new()
	_ghost_mat.shader = ghost_sh
	# After everything 3D, as retail draws it last (Z off).
	_sun_mat.render_priority = 126
	_ghost_mat.render_priority = 127
	for m in [_sun_mat, _ghost_mat]:
		m.set_shader_parameter("reverse_z", WorldFog.reverse_z())
		for n in range(3, 8):
			m.set_shader_parameter("lens%d" % n, textures.get(n))
	var sun_elems := PackedInt32Array([SUN_ELEMENT])
	var ghost_elems := PackedInt32Array()
	for i in range(TEXTURE_INDEX.size()):
		if i != SUN_ELEMENT and float(SIZES[i]) > 0.0:
			ghost_elems.append(i)
	_sun_mesh = _instance("LensFlareSun", sun_elems, _sun_mat)
	_ghost_mesh = _instance("LensFlareGhosts", ghost_elems, _ghost_mat)

## One quad per element: corners (+-1, +-1), the element's index in z, uv
## over the texture.
static func quads(elements: PackedInt32Array) -> ArrayMesh:
	var pos := PackedVector3Array()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	for e in elements:
		var base := pos.size()
		for corner in [Vector2(-1, 1), Vector2(1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			pos.append(Vector3(corner.x, corner.y, float(e)))
			uv.append(Vector2((corner.x + 1.0) * 0.5, (1.0 - corner.y) * 0.5))
		idx.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _instance(node_name: String, elements: PackedInt32Array, mat: ShaderMaterial) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = quads(elements)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Placed by the shader in screen space: never cull it.
	mi.custom_aabb = AABB(Vector3(-1.0e7, -1.0e7, -1.0e7), Vector3(2.0e7, 2.0e7, 2.0e7))
	add_child(mi)
	return mi

## The sun's direction from the eye (DayCycle.sun_direction) and whether the
## flare draws at all (the Lens Flare row, the field, the sun up -- the caller
## decides).
func set_sun(direction: Vector3, on: bool) -> void:
	for m in [_sun_mat, _ghost_mat]:
		if m != null:
			m.set_shader_parameter("sun_dir", direction)
			m.set_shader_parameter("flare_on", on)

## QA: a fixed visibility (< 0: the depth tests).
func set_qa_visibility(v: float) -> void:
	for m in [_sun_mat, _ghost_mat]:
		if m != null:
			m.set_shader_parameter("qa_visibility", v)
