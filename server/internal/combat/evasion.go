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
// THIS FUNCTION IS CALLED WITH ZERO EVERYWHERE TODAY, and it exists precisely
// so that stays visible. Round 406 censused the six divisors srrevamp's three
// attack directions need and found only TWO justified by the measurement the
// code cited for all of them:
//
//	player -> monster   crit   opposed by the MONSTER's 'evcr'   grounded zero
//	player -> monster   block  opposed by the PLAYER's  'evbl'   disclosed zero
//	monster -> player   crit   opposed by the PLAYER's  'evcr'   disclosed zero
//	monster -> player   block  opposed by the MONSTER's 'evbl'   grounded zero
//	duel                crit   opposed by the PLAYER's  'evcr'   disclosed zero
//	duel                block  opposed by the PLAYER's  'evbl'   disclosed zero
//
// A GROUNDED zero is measured: GObjMob_PublishStats publishes params 0, 3-12,
// 23, 24, 27-33 and 140, and neither 56 nor 57 is among them, so a monster
// genuinely has no evasion term.
//
// A DISCLOSED zero is a simplification: srrevamp has no magic-option ("blue"
// stat) aggregation at all, so no player can carry 'evcr' or 'evbl' either.
// That was measured four ways in round 406 -- the TagEvadeCri/TagEvadeBlock
// constants have no consumer outside the vocabulary table, the raw strings
// appear only in a PackTag unit test, no function turns an item's magic
// options into combat stats, and the client never mentions them. It is a real
// absence, not a missing grep. See TestNoPlayerEvasionSourceExists, which fails
// the day one appears.
//
// The distinction matters because the code previously carried the grounded
// reason in three comments that covered all six sites. If blues are ever added,
// four of these call sites become silently wrong; passing the term explicitly
// makes each one an argument to change rather than a division to remember.
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
