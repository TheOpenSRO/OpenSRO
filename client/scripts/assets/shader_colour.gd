extends RefCounted
class_name ShaderColour

## The colour arithmetic this client's own shaders do, kept the same under
## both renderers (round 693).
##
## The two Godot 4.2.2 renderers take a shader's colours differently (READ,
## 4.2.2-stable source):
## - **GL Compatibility** samples every texture and reads every colour uniform
##   as stored, whatever its hint: `source_color` changes nothing there
##   (drivers/gles3/storage/material_storage.cpp has no sRGB texture view, and
##   its uniform conversion is commented out). The scene shader then decodes
##   the shader's ALBEDO and EMISSION from sRGB to linear before lighting
##   (drivers/gles3/shaders/scene.glsl 1368-1370: `albedo =
##   srgb_to_linear(albedo)`, unshaded included), and encodes the result
##   after tone mapping (1590-1593). So ALBEDO is written in display (gamma)
##   values, and the arithmetic on it is gamma-space arithmetic -- the space
##   the original client's Direct3D 9 fixed-function stages work in.
## - **Forward+** decodes a `source_color` texture as it samples it (an sRGB
##   view, renderer_rd/storage_rd/material_storage.cpp 912) and a
##   `source_color` colour uniform as it is set (1375), and takes ALBEDO and
##   EMISSION as linear. Nothing is decoded after the shader.
##
## Most of the project's arithmetic was written for, and measured under, the
## first: the portrait's MODULATE2X on raw texels (PlayerPortrait, round 635),
## the water's tone-mapping undo (round 628), the select screen's (round 688),
## the mod stages' D3DTOP emulation, the particles' DIFFUSE x TEXTURE. Under
## Forward+ those values would be read as linear and come out brighter.
## So these shaders sample raw (no `source_color`) and end with DECODE_ALBEDO
## (and DECODE_EMISSION where they write it), which decodes only where the
## output is not sRGB -- OUTPUT_IS_SRGB, the shader built-in that is true under
## Compatibility and false under Forward+ and Mobile (the same test
## StandardMaterial3D's own vertex_color_is_srgb code uses, scene/resources/
## material.cpp 973-976). Under Compatibility nothing changes, so every
## measurement made there still holds. Under Forward+ the value lit, blended
## and tone-mapped is the one Compatibility would have decoded.
##
## StandardMaterial3D needs no rewrite: its albedo colour and texture are both
## `source_color`, so Forward+'s dec(colour) x dec(texture) is Compatibility's
## dec(colour x texture) (exactly for a power curve, within the sRGB curve's
## toe otherwise). Its vertex colour is raw, though, so a material that
## multiplies by it sets vertex_color_is_srgb, which decodes COLOR only where
## OUTPUT_IS_SRGB is false (VERTEX_COLOR_IS_SRGB below).
##
## What this does not make equal: blending. Compatibility blends in the
## framebuffer's display values, Forward+ in a linear buffer, so a
## half-transparent surface (a terrain overlay's feathered edge, water,
## particles) mixes differently. Round 693's WORLD_ISSUES entry measures how
## much.

## The sRGB decode (the same piecewise curve as Godot's own srgb_to_linear),
## clamped below at 0 so a negative stage result cannot make a NaN. Its names
## carry the srr_ prefix: a parameter `c` collided with a shader's uniform `c`
## ("Redefinition of 'c'", MEASURED round 693).
##
## srr_color(v, OUTPUT_IS_SRGB): a colour uniform SET FROM A Color, as stored.
## (OUTPUT_IS_SRGB is a stage built-in: a user function cannot read it --
## "Unknown identifier in expression", MEASURED round 693 -- so the caller
## passes it.) Forward+ turns
## every vec3/vec4 parameter that arrives as a Color into linear on the way in,
## whatever its hint (READ: renderer_rd/storage_rd/material_storage.cpp
## update_uniform_buffer passes p_use_linear_color = true for 3D materials,
## scene_shader_forward_clustered.cpp 449, and servers/rendering/storage/
## variant_converters.h convert_to_vector applies srgb_to_linear to a COLOR
## variant; MEASURED round 693: a Color(90,120,50) parameter read back as
## (26,48,8) once decoded again). A Vector3/Vector4 parameter arrives as given
## in both renderers. So a shader on this rule reads a Color parameter through
## srr_color, which re-encodes it where the output is linear; parameters set
## as Vector3 are read directly.
const DECODE_FN := """
vec3 srr_srgb_to_linear(vec3 srr_v) {
	vec3 srr_c = max(srr_v, vec3(0.0));
	return mix(pow((srr_c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), srr_c * (1.0 / 12.92), lessThan(srr_c, vec3(0.04045)));
}
vec3 srr_linear_to_srgb(vec3 srr_v) {
	vec3 srr_c = max(srr_v, vec3(0.0));
	return mix(1.055 * pow(srr_c, vec3(1.0 / 2.4)) - vec3(0.055), srr_c * 12.92, lessThan(srr_c, vec3(0.0031308)));
}
vec4 srr_color(vec4 srr_v, bool srr_output_is_srgb) {
	return srr_output_is_srgb ? srr_v : vec4(srr_linear_to_srgb(srr_v.rgb), srr_v.a);
}
"""
const DECODE_ALBEDO := "if (!OUTPUT_IS_SRGB) { ALBEDO = srr_srgb_to_linear(ALBEDO); }"
const DECODE_EMISSION := "if (!OUTPUT_IS_SRGB) { EMISSION = srr_srgb_to_linear(EMISSION); }"
## For a vertex() of a shader that mirrors StandardMaterial3D with
## vertex_color_is_srgb on.
const DECODE_COLOR := "if (!OUTPUT_IS_SRGB) { COLOR.rgb = srr_srgb_to_linear(COLOR.rgb); }"
## Every StandardMaterial3D that multiplies by its vertex colour sets this.
const VERTEX_COLOR_IS_SRGB := true
