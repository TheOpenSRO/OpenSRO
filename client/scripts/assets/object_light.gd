extends RefCounted
class_name ObjectLight

## How the original lights a placed object or a character (round 706): the
## object renderer's vertex shader, in display values, with no tone map.
##
## Labels: READ (sro_client.exe, the box's decompile and sro_client.asm),
## MEASURED, INFERRED, OURS.
##
## **The formula (READ).** Every object and character draw goes through
## CObjRendererVS (static meshes `vslot_024`, skinned `vslot_038`) and the
## vertex shader `Shader\vertexshader0.c` / `vertexshader2.c`:
##
##     oD0   = saturate(c10 + max(0, N . c9) x c11)
##     pixel = saturate(2 x texture x oD0)      (stage 0 MODULATE2X, flag 0x1000)
##
## - c10 (VSC_DLIGHT_AMBIENT) = the drawn object's colour (+0x14..+0x1c) x the
##   D3DLIGHT9's Ambient (0x1112e28..30); w 1. vslot_024 0xbf1df8..0xbf1e37,
##   vslot_038 0xbf59e1..0xbf5a04. The "raw colour" branch of vslot_038
##   (renderer+0x120 bit 0) is never taken: the field's only writers store 0
##   (the constructor 0xbf769d, vslot_038's entry 0xbf5891).
## - c11 (VSC_DLIGHT_DIFFUSE) = the material's +0x10..+0x18 x the light's
##   Diffuse (0x1112e18..20), per material (`FUN_00bf0e20`). The material is
##   a CPrimMtrl whose D3DMATERIAL9-shaped record starts at +0x10
##   (`CPrimMtrl::vslot_001` passes this+0x10 to `FUN_00bf9270`), and
##   FUN_00bf9270 stores the .bmt layer's SECOND colour at the record's +0
##   (D3DMATERIAL9.Diffuse) and the FIRST at its +0x10 (Ambient). So c11 uses
##   the layer's second colour (BmtReader `diffuse`), and the first colour
##   (BmtReader `ambient`) is in no object lighting at all. The flag word the
##   draw reads at material+0x70 is the record's +0x60, consistent.
## - c9 (VSC_DLIGHT_DIRECTION) = renderer+0x130..0x138 (the light's Direction
##   x -1.0, `vslot_025`, double 0xe1b8e8) times the inverse of the object's
##   world matrix, NOT renormalised (vslot_024 0xbf1e42..): a scaled object's
##   N . L scales by 1 / scale. Here: dot(MODEL_NORMAL_MATRIX x NORMAL, L),
##   the same product (the inverse transpose, unnormalised).
## - The light (`Map::FUN_00a19160`, every world draw, then `vslot_025`):
##   Direction = DAT_01109510, set once by `Map::FUN_00a2f370` to
##   normalize(-1, -1, 0) (0xa300c2..0xa301c4; nothing else writes it), so
##   the direction TO the light is (0.707, 0.707, 0) in the file's
##   coordinates -- the same in Godot's, the world mirror being z -> -z.
##   Ambient = world+0x6853, environment channel 3 clamped to [0, 1]
##   (round 635). Diffuse = world+0x677e = channel 2 clamped x world+0x68c3,
##   which is 0.8 (0xde4c64) while world+0x2e54 is set and 0.6 (0xd86fc0)
##   otherwise (0xa1d19b..0xa1d20b), halved while world+0x26bb (underwater)
##   is set (0xa1d27b). world+0x2e54 is set to 1 by the world's constructor
##   (`FUN_00a2f370`, param_1[0xb95] = 1) and cleared by `Map::FUN_009fb180`
##   (from SWorld::vslot_005, every frame) when the bloom's screen target
##   (world+0x27c3) does not exist: so 0.8 with the Bloom row on, 0.6 with it
##   off. (Its only writers are those two: once cleared it stays clear until
##   the world is built again -- not reproduced, the row's value decides.)
## - The object's colour: CCompoundObj's constructor (`ResourceMgr::
##   FUN_00c32e50`, 0xc330ed..0xc330fc) sets +0x14..+0x1c to 0.6 (0xd86fc0)
##   for all three classes built on it -- CCompChar (0xe0cd3c), CCompBldg
##   (0xe0ce8c, the map's buildings) and CCompSimple (0xe0cfd4). Its setter
##   (vtable slot 21, `CCompChar::FUN_00c255e0`) has two callers:
##   * `Map::FUN_009f6de0`, the region's 0x5d-byte decoration records, with
##     record+0x55 = the region's shadow byte / 382.5 (0xa27c0c, 0xde4de8);
##     those are not drawn here;
##   * `GlobalDataManager::FUN_009cf530`, every character's position setter
##     (CIObject slot 37): 0.6 unless the character's nav cell is a terrain
##     cell (vtable+8: CRTNavCellQuad returns 1, CRTNavCellTri 0), then
##     `FUN_00aa1030` -- 1.0 in a dungeon region (id bit 0x8000), else
##     `SWorld::vslot_041`: the byte of the region's .t ShadowMap (read into
##     region+0x73 by FUN_00a31d20, 0xa31e40) under the character, column
##     x / 20, row z / 20, divided by 384.0 (0xde4c48); 1.0 when no region.
##   So a placed object is 0.6 always, and a character standing on the
##   ground is 153..255 / 384 = 0.398..0.664 by the tile under it
##   (CharacterLight keeps that up to date).
## - Specular: none. The vertex shaders write no oD1, and c14 (the material
##   x the renderer's second light, `FUN_00bf0e20`) is uploaded only when
##   renderer+0x14 is 1, which `vslot_025` (the world's light) clears.
##   Metallic Sheen is an environment map (CRTModEnvMap), not drawn here.
##
## **Display values, no tone map (READ: Direct3D 9 fixed-function output,
## no D3DRS_SRGBWRITEENABLE).** The formula is evaluated on raw texels, as
## ShaderColour's rule says, so the arithmetic is the client's in both
## renderers. Godot then tone maps the frame (World3D: Filmic) -- which the
## original does not -- so the shaders write the value whose tone-mapped,
## encoded result is the formula's (srr_obj_present, the inverse of Godot
## 4.2's filmic curve, as the select screen's bodies and the fog pass
## already undo it). OURS method, decided by measurement (WORLD_ISSUES round
## 706). OPENSRO_QA_OBJ_TONEMAP=0 leaves the tone map on objects, for an A/B.
##
## The light reaches the shaders as global uniforms (project.godot
## [shader_globals]); the object's colour is the material uniform
## `object_color` (0.6), and a character standing on a tile of another level
## draws with a copy of each material at that level (with_object_color;
## CharacterLight) -- a per-instance uniform overflowed Godot's instance
## buffer once every placed mesh carried one (round 706 review, MEASURED),
## and GL Compatibility has none.

## READ: 0xd86fc0 -- CCompoundObj's own colour, and the diffuse scale with
## no bloom target.
const OBJECT_COLOR := 0.6
const DIFFUSE_SCALE := 0.6
## READ: 0xde4c64 -- the diffuse scale while world+0x2e54 (the bloom
## target) is set.
const DIFFUSE_SCALE_BLOOM := 0.8
## READ: 0xde4c48 -- SWorld::vslot_041's divisor of the shadow byte.
const SHADOW_DIVISOR := 384.0
## READ: the ShadowMap's side and its tile (96 x 96 tiles of 20 units:
## 0xe1b830 = 20.0, 0xe1b838 = -20.0).
const SHADOW_SIDE := 96
const SHADOW_TILE := 20.0
## READ: the direction to the light in the file's coordinates
## (-DAT_01109510).
const TO_LIGHT_FILE := Vector3(0.70710678, 0.70710678, 0.0)
## READ: stage 0's D3DTOP_MODULATE2X.
const MODULATE_SCALE := 2.0
## OURS: the channels before any zone is known (a dev run without Map.pk2),
## stated rather than guessed: 1.0 each, as PlayerPortrait's fallback.
const FALLBACK_CHANNEL := Color(1.0, 1.0, 1.0, 1.0)

## The globals (project.godot [shader_globals]).
const GLOBAL_LIGHT := &"srr_obj_light"
const GLOBAL_AMBIENT := &"srr_obj_ambient"
const GLOBAL_DIFFUSE := &"srr_obj_diffuse"
const GLOBAL_TONEMAP := &"srr_obj_tonemap"

## The material uniform (CharacterLight sets it on per-level copies).
const OBJECT_COLOR_PARAM := &"object_color"
## On a per-level copy: the material it copies (with_object_color).
const VARIANT_BASE_META := &"opensro_obj_color_base"
## base material instance id -> {level: WeakRef(copy)}; a copy lives as long
## as a mesh draws with it, and holds its base.
static var _variants := {}
static var _variant_inserts := 0
## The levels a copy is keyed by: 1/1024 (the shadow map has five bytes).
const VARIANT_STEPS := 1024.0

## The light the shaders were last given (for the portrait and the tests).
static var current_ambient := Vector3.ONE
static var current_diffuse := Vector3.ONE * DIFFUSE_SCALE_BLOOM
static var current_bloom := true

## Round 806 (READ, object.gdshaderinc): a plain layer's pixel, before the
## tone map undo -- saturate(2 x texture x oD0) -- and a night-lit layer's at
## night (`night`): saturate(1 x texture x 1), the texture itself.
static func night_lit_pixel(tex: Vector3, od0: Vector3, night: bool) -> Vector3:
	var v := tex if night else tex * od0 * MODULATE_SCALE
	return v.clamp(Vector3.ZERO, Vector3.ONE)

## The scale on channel 2 for the Bloom row (READ, above).
static func diffuse_scale(bloom_on: bool) -> float:
	return DIFFUSE_SCALE_BLOOM if bloom_on else DIFFUSE_SCALE

## The light's colours from the zone's channels: ambient = channel 3
## clamped, diffuse = channel 2 clamped x diffuse_scale (READ).
static func light_colors(diffuse_channel: Color, ambient_channel: Color, bloom_on: bool) -> Dictionary:
	var k := diffuse_scale(bloom_on)
	return {
		"ambient": Vector3(clampf(ambient_channel.r, 0.0, 1.0), clampf(ambient_channel.g, 0.0, 1.0), clampf(ambient_channel.b, 0.0, 1.0)),
		"diffuse": Vector3(clampf(diffuse_channel.r, 0.0, 1.0), clampf(diffuse_channel.g, 0.0, 1.0), clampf(diffuse_channel.b, 0.0, 1.0)) * k,
	}

## The direction to the light in Godot's world (the mirror flips z).
static func to_light_godot() -> Vector3:
	return Vector3(TO_LIGHT_FILE.x, TO_LIGHT_FILE.y, -TO_LIGHT_FILE.z)

## QA only (QaShotEnv's `objdiag=` key): 0 the light as READ, 1 the
## diffuse term alone (ambient zeroed), 2 the ambient term alone.
static var qa_diag := 0
static var _last_channels: Array = [FALLBACK_CHANNEL, FALLBACK_CHANNEL, true]

## Sets the light every object shader reads.
static func set_light(diffuse_channel: Color, ambient_channel: Color, bloom_on: bool) -> void:
	_last_channels = [diffuse_channel, ambient_channel, bloom_on]
	var c := light_colors(diffuse_channel, ambient_channel, bloom_on)
	current_ambient = c["ambient"]
	current_diffuse = c["diffuse"]
	current_bloom = bloom_on
	if qa_diag == 1:
		c["ambient"] = Vector3.ZERO
	elif qa_diag == 2:
		c["diffuse"] = Vector3.ZERO
	var amb: Vector3 = c["ambient"]
	var dif: Vector3 = c["diffuse"]
	var l := to_light_godot()
	RenderingServer.global_shader_parameter_set(GLOBAL_LIGHT, Vector4(l.x, l.y, l.z, 0.0))
	RenderingServer.global_shader_parameter_set(GLOBAL_AMBIENT, Vector4(amb.x, amb.y, amb.z, 1.0))
	RenderingServer.global_shader_parameter_set(GLOBAL_DIFFUSE, Vector4(dif.x, dif.y, dif.z, 1.0))

## QA: the last light again (after qa_diag changes).
static func reapply() -> void:
	set_light(_last_channels[0], _last_channels[1], _last_channels[2])

## QA only: -1 follows OPENSRO_QA_OBJ_TONEMAP, 0 / 1 force (QaShotEnv's
## `objtm=` key, per shot).
static var qa_undo := -1

## Whether the object shaders undo the tone map (OPENSRO_QA_OBJ_TONEMAP=0 or
## a shot's `objtm=0`: they do not, QA only).
static func undo_tonemap_enabled() -> bool:
	if qa_undo >= 0:
		return qa_undo == 1
	return OS.get_environment("OPENSRO_QA_OBJ_TONEMAP") != "0"

## The tone map the shaders undo, from `env`: x exposure, y white, z 1 for
## Filmic, w 1 when the undo is on.
static func set_tonemap(env: Environment) -> void:
	current_tonemap = tonemap_vector(env)
	RenderingServer.global_shader_parameter_set(GLOBAL_TONEMAP, current_tonemap)

## The tone map vector last set (EfpDisplayPass reads it: the global's own
## getter is the editor's only).
static var current_tonemap := Vector4(1.0, 1.0, 0.0, 0.0)

static func tonemap_vector(env: Environment) -> Vector4:
	var filmic := env != null and env.tonemap_mode == Environment.TONE_MAPPER_FILMIC
	return Vector4(env.tonemap_exposure if env != null else 1.0, env.tonemap_white if env != null else 1.0,
		1.0 if filmic else 0.0, 1.0 if undo_tonemap_enabled() else 0.0)

## The ShadowMap byte under region-local (x, z), or -1 off the map or with
## no map (READ indexing: column x / 20, row z / 20, 96 wide).
static func shadow_byte_at(shadow_map: PackedByteArray, x: float, z: float) -> int:
	if shadow_map.size() < SHADOW_SIDE * SHADOW_SIDE:
		return -1
	var col := int(floorf(x / SHADOW_TILE))
	var row := int(floorf(z / SHADOW_TILE))
	if col < 0 or row < 0 or col >= SHADOW_SIDE or row >= SHADOW_SIDE:
		return -1
	return shadow_map[row * SHADOW_SIDE + col]

## A character's object colour (READ, FUN_009cf530 and SWorld::vslot_041):
## 0.6 off a terrain cell, else the shadow byte / 384, 1.0 with no region
## (`shadow_byte` < 0) or in a dungeon.
static func character_color(shadow_byte: int, on_terrain: bool, dungeon: bool = false) -> float:
	if not on_terrain:
		return OBJECT_COLOR
	if dungeon or shadow_byte < 0:
		return 1.0
	return float(shadow_byte) / SHADOW_DIVISOR

## Whether `m` is an object material whose object colour can be set: one of
## ObjectLoader's object or MTRL-mod shaders, not a fade twin (AppearFade
## owns those while it runs).
static func is_object_material(m: Material) -> bool:
	if not (m is ShaderMaterial):
		return false
	var sh := (m as ShaderMaterial).shader
	if sh == null:
		return false
	if not (sh.has_meta(ObjectLoader.OBJECT_SHADER_KIND_META) or sh.has_meta(ObjectLoader.MOD_SHADER_KEY_META)):
		return false
	return not sh.code.contains("APPEAR_FADE") and not sh.code.contains("appear_alpha")

## The material it copies, for a per-level copy; `m` itself otherwise.
static func base_of(m: Material) -> Material:
	return m.get_meta(VARIANT_BASE_META, m) if m != null else null

## Round 759: the object colour `m` draws with (its `object_color`'s x; the
## shader's default, OBJECT_COLOR, when it sets none). CrowdGpu writes it in
## a far body's texel instead of drawing the level copy.
static func object_color_of(m: Material) -> float:
	var v = (m as ShaderMaterial).get_shader_parameter(OBJECT_COLOR_PARAM) if m is ShaderMaterial else null
	return float((v as Vector3).x) if v is Vector3 else OBJECT_COLOR

## Round 759: the object colour with_object_color(m, value) draws at, without
## making the copy: the base's own near 0.6, else the level's.
static func object_color_at(m: Material, value: float) -> float:
	var base := base_of(m)
	if base == null or absf(value - OBJECT_COLOR) < 0.5 / VARIANT_STEPS:
		return object_color_of(base)
	return float(int(roundf(value * VARIANT_STEPS))) / VARIANT_STEPS

## `m` (or the material it copies) drawn at object colour `value`: the base
## itself at 0.6, else one shared copy per base and level with
## `object_color` set (OURS method for the READ value).
static func with_object_color(m: Material, value: float) -> Material:
	var base := base_of(m)
	if base == null or absf(value - OBJECT_COLOR) < 0.5 / VARIANT_STEPS:
		return base
	var level := int(roundf(value * VARIANT_STEPS))
	var key := base.get_instance_id()
	var per: Dictionary = _variants.get(key, {})
	var ref: WeakRef = per.get(level)
	var copy: Material = ref.get_ref() as Material if ref != null else null
	if copy == null:
		copy = copy_material(base as ShaderMaterial)
		(copy as ShaderMaterial).set_shader_parameter(OBJECT_COLOR_PARAM, Vector3.ONE * (float(level) / VARIANT_STEPS))
		copy.set_meta(VARIANT_BASE_META, base)
		per[level] = weakref(copy)
		_variants[key] = per
		_variant_inserts += 1
		if _variant_inserts % 512 == 0:
			_prune_variants()
	return copy

## A new material on `src`'s shader with each of its parameters set again
## by name, its priority and its metadata. Not Resource.duplicate(): MEASURED
## (round 706 review), a duplicated character material drew its diffuse term
## up to 1.5x brighter than the material it copied at the same values.
static func copy_material(src: ShaderMaterial) -> ShaderMaterial:
	var out := ShaderMaterial.new()
	out.resource_name = src.resource_name
	out.shader = src.shader
	out.render_priority = src.render_priority
	for u in src.shader.get_shader_uniform_list():
		var n: String = u["name"]
		var v = src.get_shader_parameter(n)
		if v != null:
			out.set_shader_parameter(n, v)
	for m in src.get_meta_list():
		out.set_meta(m, src.get_meta(m))
	return out

## Drops the cache's dead entries.
static func _prune_variants() -> void:
	for key in _variants.keys():
		var per: Dictionary = _variants[key]
		for level in per.keys():
			if (per[level] as WeakRef).get_ref() == null:
				per.erase(level)
		if per.is_empty():
			_variants.erase(key)

## One channel as the original draws it, in display values (the CPU
## reference the tests hold the shaders to).
static func shade(texel: float, material_diffuse: float, object: float, ambient: float, diffuse: float, n_dot_l: float) -> float:
	var od0 := clampf(object * ambient + maxf(n_dot_l, 0.0) * material_diffuse * diffuse, 0.0, 1.0)
	return clampf(MODULATE_SCALE * texel * od0, 0.0, 1.0)

## The vertex colour's line in the generated shaders (PlayerPortrait
## replaces it with its own light).
const OD0_LINE := "srr_od0 = srr_obj_od0(MODEL_NORMAL_MATRIX * NORMAL, srr_color(albedo, OUTPUT_IS_SRGB).rgb, object_color, object_tint);"

## The shared GLSL of the generated shaders (the .gdshaderinc carries the
## same text; object_light_test.gd holds the two equal). Needs
## ShaderColour.DECODE_FN before it.
const SHADER_FN := """
global uniform vec4 srr_obj_light;
global uniform vec4 srr_obj_ambient;
global uniform vec4 srr_obj_diffuse;
global uniform vec4 srr_obj_tonemap;
// The drawn object's colour (+0x14..+0x1c): 0.6 for every placed object
// (CCompoundObj). A character's shadow tile is set on per-level copies of
// its materials (ObjectLight.with_object_color, CharacterLight). Not a
// per-instance uniform: one per placed mesh overflowed Godot's instance buffer
// at the Jangan spawn (round 706 review, MEASURED: 1,093 "Too many
// instances using shader instance variables"), and GL Compatibility has
// none at all.
uniform vec3 object_color = vec3(0.6);
// BerserkLook's pulse (READ: CObjRendererVS::FUN_00c27180 puts the colour in
// place of both the material's and the object's): w 1 while it runs.
uniform vec4 object_tint = vec4(0.0);
varying vec3 srr_od0;
// oD0 = saturate(object x La + max(0, N.L) x material x Ld) (ObjectLight).
vec3 srr_obj_od0(vec3 srr_n, vec3 srr_material, vec3 srr_object, vec4 srr_tint) {
	vec3 srr_c10 = (srr_tint.w > 0.5 ? srr_tint.rgb : srr_object) * srr_obj_ambient.rgb;
	vec3 srr_c11 = (srr_tint.w > 0.5 ? srr_tint.rgb : srr_material) * srr_obj_diffuse.rgb;
	return clamp(srr_c10 + max(dot(srr_n, srr_obj_light.xyz), 0.0) * srr_c11, vec3(0.0), vec3(1.0));
}
float srr_obj_filmic_raw(float x) {
	return (x * (0.88 * x + 0.1 * 0.6) + 0.2 * 0.01) / (x * (0.88 * x + 0.6) + 0.2 * 0.3) - 0.01 / 0.3;
}
float srr_obj_filmic_inverse(float t, float white) {
	float u = clamp(t, 0.0, 0.999) * srr_obj_filmic_raw(white) + 0.01 / 0.3;
	float a = 0.88 * (u - 1.0);
	float b = 0.6 * (u - 0.1);
	float c = 0.2 * (0.3 * u - 0.01);
	float disc = max(b * b - 4.0 * a * c, 0.0);
	return max((-b - sqrt(disc)) / (2.0 * a), 0.0);
}
// A display value -> the value to write as ALBEDO (display-encoded) so that
// Godot's tone map shows it unchanged (ObjectLight).
vec3 srr_obj_present(vec3 srr_v) {
	if (srr_obj_tonemap.w < 0.5) {
		return srr_v;
	}
	vec3 srr_l = srr_srgb_to_linear(clamp(srr_v, vec3(0.0), vec3(1.0)));
	if (srr_obj_tonemap.z > 0.5) {
		srr_l = vec3(srr_obj_filmic_inverse(srr_l.r, srr_obj_tonemap.y), srr_obj_filmic_inverse(srr_l.g, srr_obj_tonemap.y), srr_obj_filmic_inverse(srr_l.b, srr_obj_tonemap.y));
	}
	return srr_linear_to_srgb(srr_l / max(srr_obj_tonemap.x, 0.0001));
}
"""
