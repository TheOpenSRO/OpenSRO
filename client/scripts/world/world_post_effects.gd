extends RefCounted
class_name WorldPostEffects

## The world's two screen-space post effects, SSAO and glow, in one place
## (round 693), so the Options window can turn them on without touching the
## scene: `WorldPostEffects.apply(env, ssao, glow)`.
##
## Both are OFF here by default; since round 694 the Option window's record
## decides (VideoOptions.apply_post_effects calls this): retail's Middle, the
## default the user chose, has the Bloom Effect (= glow) ON, and SSAO is an
## OURS option, off. They came from an OURS "atmosphere pass" on
## 2026-08-26 (docs/WORLD_ISSUES.md, tenth and thirteenth rounds: values
## picked, never read from the game), and from round 581 to 692 nobody saw
## them, because the Compatibility renderer has neither (4.2.2's GLES3 has no
## SSAO or glow pass). Forward+ draws both, so round 693 made the default the
## look the project had verified.
##
## What the original has, READ in sro_client.exe's option page
## (FUN_005fef70 asks for the labels): a "Bloom effect" switch
## (UIIT_STT_BLOOM_EFFECT) beside Filtering, Lens flare, Texture detail,
## Dynamic animation and Effect quality -- glow's retail counterpart, ON in
## Middle (round 694, READ 0x5015a0) and its look NOT read -- and no string naming ambient
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
