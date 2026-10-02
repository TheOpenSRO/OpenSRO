extends RefCounted
class_name WorldPostEffects

## The world's two screen-space post effects, SSAO and glow, in one place
## (round 693), so the Options window can turn them on without touching the
## scene: `WorldPostEffects.apply(env, ssao, glow)`.
##
## Both are OFF by default. They came from an OURS "atmosphere pass" on
## 2026-08-26 (docs/WORLD_ISSUES.md, tenth and thirteenth rounds: values
## picked, never read from the game), and from round 581 to 692 nobody saw
## them, because the Compatibility renderer has neither (4.2.2's GLES3 has no
## SSAO or glow pass). Forward+ draws both, so round 693 made the default the
## look the project had verified.
##
## What the original has, READ in sro_client.exe's option page
## (FUN_005fef70 asks for the labels): a "Bloom effect" switch
## (UIIT_STT_BLOOM_EFFECT) beside Filtering, Lens flare, Texture detail,
## Dynamic animation and Effect quality -- so glow has a retail counterpart
## whose default and look are NOT read yet -- and no string naming ambient
## occlusion or SSAO (MEASURED: `strings` over the exe). Glow's parameters
## (intensity 0.8, bloom 0.2, HDR threshold 0.85) stay in World3D.tscn as the
## 2026-08-26 guess they are; they only matter once glow is turned on.
##
## The Compatibility renderer ignores both flags, so this is a no-op there.

const SSAO_DEFAULT := false
const GLOW_DEFAULT := false

static func apply(env: Environment, ssao: bool = SSAO_DEFAULT, glow: bool = GLOW_DEFAULT) -> void:
	if env == null:
		return
	env.ssao_enabled = ssao
	env.glow_enabled = glow

## The sun under Forward+ (round 693; the user, 2026-10-02: "Raise it to
## match"). Compatibility draws World3D's shadow-casting sun in a separate
## additive pass and adds it in display values (READ, gles3 scene.glsl
## 1805-1808), so its sunlit surfaces came out brighter than one pass of the
## same light: a lit quad (ambient 0.7, sun 0.3) read (225,176,127) with
## shadows on against (159,128,95) without, while Forward+ reads (158,128,95)
## either way (MEASURED, tools/measure_lit_space.gd). The look players and
## every box shot had from round 581 to 692 is Compatibility's, so under
## Forward+ the sun's energy is multiplied by FORWARD_PLUS_SUN_SCALE -- OURS,
## chosen by measurement to match that look (docs/WORLD_ISSUES.md, round 693),
## not a value of the original client. Under Compatibility the factor is 1:
## its look stays exactly as it was.
const FORWARD_PLUS_SUN_SCALE := 4.0

## The factor for the renderer running. SRREVAMP_QA_SUN_SCALE overrides it
## under Forward+ (QA only: the calibration runs).
static func sun_scale() -> float:
	if RendererChoice.running() != RendererChoice.FORWARD_PLUS:
		return 1.0
	var qa := OS.get_environment("SRREVAMP_QA_SUN_SCALE")
	if qa.is_valid_float():
		return qa.to_float()
	return FORWARD_PLUS_SUN_SCALE
