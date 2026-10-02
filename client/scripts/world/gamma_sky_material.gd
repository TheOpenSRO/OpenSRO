extends ShaderMaterial
class_name GammaSkyMaterial

## The world's sky gradient (round 693): Godot 4.2.2's own
## ProceduralSkyMaterial, made to draw the same under both renderers.
##
## World3D's sky has been a ProceduralSkyMaterial since 2026-08 (OURS: no
## retail sky image was found, so the gradient between environment.ifo's own
## sky colours is Godot's shape). The two renderers draw that material
## differently (READ, 4.2.2-stable):
## - GL Compatibility reads its colour parameters and the sun's colour as
##   stored (drivers/gles3/storage/material_storage.cpp; rasterizer_scene_gles3
##   .cpp 703, `light_get_color` unconverted), mixes the gradient in those
##   display values, then decodes the result (drivers/gles3/shaders/sky.glsl,
##   "Convert to Linear for tonemapping").
## - Forward+ decodes the colours first (renderer_rd/environment/sky.cpp
##   1085, and every Color parameter, ShaderColour) and mixes in linear space,
##   and it also mixes the environment fog into the sky (fog_sky_affect), which
##   Compatibility's sky shader does not.
## MEASURED round 693, the Jangan sky shot: the sky band's mean red 69.5 under
## Compatibility against 87.8 under Forward+, 20 % of its pixels more than 32
## apart.
##
## So this is the material's own shader code, unchanged in shape (sky_material
## .cpp, 4.2.2-stable, MIT, Copyright (c) 2014-present Godot Engine
## contributors), with its colours passed as stored (Vector3 parameters, which
## neither renderer converts), the sun's colour re-encoded where Forward+
## decoded it, the gradient mixed in display values as Compatibility mixes it,
## and the result decoded where the output is linear. `decode_out` says which:
## RendererChoice.running(), set when the material is made (a sky shader has
## no OUTPUT_IS_SRGB). Under Compatibility it computes what
## ProceduralSkyMaterial computed. Only the properties World3D sets are
## exposed, at the material's own defaults otherwise.

const SHADER_CODE := """shader_type sky;
uniform vec3 sky_top_color = vec3(0.385, 0.454, 0.55);
uniform vec3 sky_horizon_color = vec3(0.646, 0.656, 0.67);
uniform float sky_curve = 0.15;
uniform vec3 ground_bottom_color = vec3(0.2, 0.169, 0.133);
uniform vec3 ground_horizon_color = vec3(0.646, 0.656, 0.67);
uniform float ground_curve = 0.02;
uniform float sun_angle_max = 0.523599;
uniform float sun_curve = 0.15;
uniform bool decode_out = false;

vec3 enc(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - vec3(0.055), c * 12.92, lessThan(c, vec3(0.0031308)));
}
vec3 dec(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}

void sky() {
	float v_angle = acos(clamp(EYEDIR.y, -1.0, 1.0));
	float c = (1.0 - v_angle / (PI * 0.5));
	vec3 sky = mix(sky_horizon_color, sky_top_color, clamp(1.0 - pow(1.0 - c, 1.0 / sky_curve), 0.0, 1.0));
	if (LIGHT0_ENABLED) {
		vec3 lc = decode_out ? enc(LIGHT0_COLOR) : LIGHT0_COLOR;
		float sun_angle = acos(dot(LIGHT0_DIRECTION, EYEDIR));
		if (sun_angle < LIGHT0_SIZE) {
			sky = lc * LIGHT0_ENERGY;
		} else if (sun_angle < sun_angle_max) {
			float c2 = (sun_angle - LIGHT0_SIZE) / (sun_angle_max - LIGHT0_SIZE);
			sky = mix(lc * LIGHT0_ENERGY, sky, clamp(1.0 - pow(1.0 - c2, 1.0 / sun_curve), 0.0, 1.0));
		}
	}
	c = (v_angle - (PI * 0.5)) / (PI * 0.5);
	vec3 ground = mix(ground_horizon_color, ground_bottom_color, clamp(1.0 - pow(1.0 - c, 1.0 / ground_curve), 0.0, 1.0));
	COLOR = mix(ground, sky, step(0.0, EYEDIR.y));
	if (decode_out) {
		COLOR = dec(COLOR);
	}
}
"""

static var _shader: Shader = null

var sky_top_color := Color(0.385, 0.454, 0.55):
	set(v):
		sky_top_color = v
		set_shader_parameter("sky_top_color", Vector3(v.r, v.g, v.b))
var sky_horizon_color := Color(0.646, 0.656, 0.67):
	set(v):
		sky_horizon_color = v
		set_shader_parameter("sky_horizon_color", Vector3(v.r, v.g, v.b))
var ground_bottom_color := Color(0.2, 0.169, 0.133):
	set(v):
		ground_bottom_color = v
		set_shader_parameter("ground_bottom_color", Vector3(v.r, v.g, v.b))
var ground_horizon_color := Color(0.646, 0.656, 0.67):
	set(v):
		ground_horizon_color = v
		set_shader_parameter("ground_horizon_color", Vector3(v.r, v.g, v.b))

func _init() -> void:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
	shader = _shader
	set_shader_parameter("decode_out", RendererChoice.running() == RendererChoice.FORWARD_PLUS)
