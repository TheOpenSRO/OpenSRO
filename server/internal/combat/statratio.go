package combat

import "math"

// The Str/Int-against-level damage ratios, recovered 2026-09-16.
//
// These are a SECOND stat-to-damage coupling, separate from ReinforceDamage.
// That one is additive -- `Str * reinforce/100` folded into the weapon's range.
// This one is a multiplier applied to the damage as it passes through
// `Formula_MitigatePhysicalDamage`:
//
//	40e6cb  mov esi,ebp      ; the ATTACKER
//	40e6cd  call 0x410a00    ; ratio(attacker)
//	40e6d2  fstp [esp+0x2c]
//	40e6d6  mov esi,edi      ; the DEFENDER
//	40e6d8  call 0x410a00    ; ratio(defender)
//	40e6df  fld  [esp+0x2c]  ; reload the attacker's
//	40e6e3  fmul [esp+0x24]  ; into the damage accumulator
//
// so the engine computes it for both parties and, on the arm that was read,
// multiplies by the attacker's.
//
// THE TWO ARE NOT SYMMETRIC, which is the detail most likely to be "tidied"
// into a bug. `Formulae::StrLevelDamageRatio` (`0x00410a00`) adds a level term
// to its numerator and `Formulae::IntLevelDamageRatio` (`0x00410ab0`) does not:
//
//	410a4c  fadd [0xb45db8]   ; Str + 16          <- only the Str one
//	410a52  fld  [esp] ...    ; + 2*(level-1)     <- only the Str one
//	410a5b  fmul [0xb45db0]   ; (level-1) * 7        vs the Int one's * 5
//	410a61  fadd [0xb45da8]   ;            + 56      vs            + 40
//	410a67  fmul [0xb45da0]   ;            * 6/7     vs            * 0.8
//
// The denominators simplify exactly: `((level-1)*7 + 56) * 6/7` is
// `6*(level+7)`, and `((level-1)*5 + 40) * 0.8` is `4*(level+7)`.
//
// Both are gated on `IsPC` (vtable slot 7) and return **1.0** for anything
// else, so this is a player-only term -- a monster's swing is unaffected. The
// level is `GetMaxLevel` (vtable slot 74), not the current level.
//
// NOT WIRED INTO THE DAMAGE PATH YET, deliberately. The mitigation function
// accumulates several multipliers into `[esp+0x24]` and this pass read one of
// them; wiring a partial accumulator is the mistake this ledger keeps
// recording. The formulas are exact and tested; the ordering is the open part.
const (
	// StatRatioClamp is the upper bound both ratios are clamped to,
	// `.rdata 0x00b45d90` read as a float32.
	StatRatioClamp = 1.2
	// StatRatioNonPC is what a non-player gets: the IsPC gate returns `fld1`
	// before reading any stat.
	StatRatioNonPC = 1.0

	strRatioNumeratorBias = 14 // 16 - 2, folding the `-1` of (level-1)
	strRatioDenomFactor   = 6
	intRatioDenomFactor   = 4
	statRatioLevelOffset  = 7
)

// StrLevelDamageRatio is `(Str + 2*level + 14) / (6 * (level + 7))`, clamped to
// [0, StatRatioClamp].
func StrLevelDamageRatio(str, level int) float64 {
	num := float64(str) + 2*float64(level) + strRatioNumeratorBias
	den := float64(strRatioDenomFactor) * (float64(level) + statRatioLevelOffset)
	return clampStatRatio(num, den)
}

// IntLevelDamageRatio is `Int / (4 * (level + 7))`, clamped the same way. Note
// the absent level term in the numerator -- that asymmetry is the engine's.
func IntLevelDamageRatio(intel, level int) float64 {
	den := float64(intRatioDenomFactor) * (float64(level) + statRatioLevelOffset)
	return clampStatRatio(float64(intel), den)
}

func clampStatRatio(num, den float64) float64 {
	if den <= 0 {
		// level + 7 is never <= 0 for a real character; guard rather than
		// divide by zero.
		return 0
	}
	r := num / den
	if math.IsNaN(r) || r < 0 {
		return 0
	}
	if r > StatRatioClamp {
		return StatRatioClamp
	}
	return r
}

// StrForMaxRatio and IntForMaxRatio are the stat values at which each ratio
// reaches its 1.2 ceiling -- i.e. the point past which more of that stat does
// nothing. They are algebra on the recovered constants, not a new measurement:
//
//	1.2 = (Str + 2L + 14) / (6*(L+7))   =>  Str = 5.2*L + 36.4
//	1.2 =  Int            / (4*(L+7))   =>  Int = 4.8*L + 33.6
//
// WHY THIS IS WORTH HAVING. The ratio is only meaningful relative to the stat
// scale it was calibrated against, and that scale is not otherwise readable:
// the engine takes a character's Str from charData, `GObjPC_InitStats`
// publishing `charData+0x74` into param 1, and that column comes from a table
// this project does not have. These two lines are the one statement the binary
// DOES make about the intended scale, so they are the yardstick for any future
// attempt to ground character.StartingStr.
//
// Measured against OpenSRO's own numbers, which is why stage 15 of the damage
// pipeline is not wired: a character putting every point into Str reaches
// `StartingStr + 4*(level-1)` = 20, 96 and 216 at levels 1, 20 and 50, against
// an engine ceiling of 41.6, 140.4 and 296.4. OpenSRO's stats sit below the
// scale the ratio expects at every level, so feeding them in produces a
// systematic multiplier under 1 -- an artifact of our Str, not a recovered
// value. See docs/protocol/damage_pipeline.md.
func StrForMaxRatio(level int) float64 {
	return 5.2*float64(level) + 36.4
}

func IntForMaxRatio(level int) float64 {
	return 4.8*float64(level) + 33.6
}
