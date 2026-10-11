package combat

import "math"

// The evasion divisor that opposes the game's two chance rolls.
//
// Both rolls in Combat_ResolveDamage are divided by the OPPOSING party's
// evasion of that particular roll (docs/RE_COMPLETION.md:1522):
//
//	effective crit  = attacker 'cri' (12) / (1 + defender 'evcr' (57)/100)
//	effective block = defender 'bri' (10) / (1 + attacker 'evbl' (56)/100)
//
// The rule is `my stat / (1 + my opponent's evasion of it)`. Because block is
// the DEFENDER's stat, the two parties swap between the lines -- an asymmetry
// that two records in RE_COMPLETION.md each got half right until the
// disassembly settled it in round 406's predecessor. `MagicOption.txt` agrees
// from a second artefact: MATTR_CRITICAL sits on a weapon against
// MATTR_EVADE_CRITICAL on a shield, MATTR_BLOCKRATE on a shield against
// MATTR_EVADE_BLOCK on a weapon.
//
// Who opposes what, in OpenSRO's three attack directions:
//
//	player -> monster   crit   opposed by the MONSTER's 'evcr'   grounded zero
//	player -> monster   block  opposed by the PLAYER's  'evbl'   the worn options
//	monster -> player   crit   opposed by the PLAYER's  'evcr'   the worn options
//	monster -> player   block  opposed by the MONSTER's 'evbl'   grounded zero
//	duel                crit   opposed by the PLAYER's  'evcr'   the worn options
//	duel                block  opposed by the PLAYER's  'evbl'   the worn options
//
// A GROUNDED zero is measured: GObjMob_PublishStats publishes params 0, 3-12,
// 23, 24, 27-33 and 140, and neither 56 nor 57 is among them, so a monster
// genuinely has no evasion term. A player's is the sum of its worn items'
// 'evbl' / 'evcr' options (Stat_ApplyTaggedModifier 0x498690 writes them into
// params 56 / 57, clamped at 100), wired in round 769 (session/equipstats.go)
// -- until then those four were a disclosed zero, because nothing aggregated
// an item's options.
func EvadedChance(chance int, evadePercent float64) int {
	if chance <= 0 {
		return 0
	}
	if evadePercent <= 0 {
		return chance
	}
	out := int(math.Round(float64(chance) / (1 + evadePercent/100)))
	if out < 0 {
		return 0
	}
	return out
}
