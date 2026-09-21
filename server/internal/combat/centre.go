package combat

import (
	"math"
	"math/rand"
)

// The engine's CENTRE-BIASED damage roll, recovered 2026-09-15 and ported in
// round 378. This is the roll the ordinary attack takes: `Combat_ResolveDamage`
// switches on a damage-kind byte and **case 0** -- `Formula_MitigatePhysicalDamage`
// and its magical twin, params 13/14 -- is the ordinary attack.
// `Formula_RollWeaponDamage`'s simpler uniform roll on 190/191 (RollDamage) is a
// different damage kind, reached from case 3.
//
// The recovered shape (`FUN_0040dce0`, docs/RE_COMPLETION.md "What 'attack rate'
// actually does, and the damage dice"):
//
//	centre% = clamp( ((hra/era) * 0.5 + levelTerm) * 100 , 10 , 90 )
//	p       = min(u1, u2, u3)        ui = rand()/32767 * 100
//	damage% = centre% ± p            fair coin, then clamped to [0, 100]
//	damage  = lo + damage%/100 * (hi - lo)
//
// So attack-rate-versus-parry decides WHERE IN THE WEAPON'S RANGE a blow lands,
// never below 10 % nor above 90 % of it. It is not a hit/miss roll -- three
// rounds of this project's own work mistook it for one before the retraction in
// round 373, and the mistake is recorded there.
//
// The excursion being the MINIMUM OF THREE uniform samples is what makes the
// distribution non-uniform: it is heavily biased toward zero, so blows cluster
// near the centre rather than spreading evenly.

// The centre's own constants, read out of the PE image and matching the
// 2026-09-15 disassembly at every value.
const (
	// centreRatioScale is the 0.5 the hra/era ratio is multiplied by
	// (.rdata 0x00b45c50, a double).
	centreRatioScale = 0.5
	// CentreFloorPercent and CentreCeilingPercent clamp the centre
	// (.rdata 0x00b45b44 = 10.0 and 0x00b45e18 = 90.0, floats). A blow never
	// lands in the bottom tenth or the top tenth of its range on the centre
	// alone -- the excursion can still carry it there.
	CentreFloorPercent   = 10.0
	CentreCeilingPercent = 90.0
	// InnateRate is a character's innate attack rate AND parry rate, each set
	// to 10.0 at slot 0 by GObjPC_InitStats (.rdata 0x00b45b44 -- the same
	// constant as the floor above), with a direct Level edge at slot 0 and
	// slot 0 summing. So a bare character's rate is 10 + Level.
	InnateRate = 10.0
)

// MonsterRate is a monster's attack rate and parry rate, which are the same
// number: characterdata columns 77 (`'hra'`) and 75 (`'era'`) both hold
// 2*level + 25 for every monster row in the retail table. It is computed here
// rather than carried per species because that regularity is the data's own --
// col 76 (`'bri'`, blocking) is 0 for every monster and col 78 (`'cri'`) is 2,
// while 75 and 77 agree row for row.
func MonsterRate(level int) float64 { return float64(2*level + 25) }

// CharacterRate is a character's attack or parry rate: the innate 10, plus the
// level edge, plus whatever equipment contributes -- a weapon's attack rate
// (itemdata col 113, refdata Item.HitRateMin) for `hra`, body armour's parry
// (col 68, Item.ParryRatioMin) for `era`.
//
// NOT MODELLED, and it only ever reduces the rate: buffs and skill modifiers
// also contribute through the same slots (`AbnormalState_Apply13_p11` is one).
// srrevamp has no such modifiers on these two params, so there is nothing to
// add rather than something omitted.
func CharacterRate(level int, equipment float64) float64 {
	r := InnateRate + float64(level) + equipment
	if r < 0 {
		return 0
	}
	return r
}

// DamageCentrePercent is where in the [lo, hi] damage range a blow lands, as a
// percentage, before the excursion. hra is the attacker's attack rate and era
// the defender's parry rate.
//
// A non-positive era would divide by zero; the engine cannot reach that (every
// character has the innate 10 and every monster 2*level+25), so a caller that
// manages it gets the ceiling rather than a panic.
func DamageCentrePercent(hra, era float64, attackerLevel, defenderLevel int) float64 {
	if era <= 0 {
		return CentreCeilingPercent
	}
	// The same level term the damage multiplier uses -- FUN_0040fd60 is a
	// shared helper with two callers, and LevelAdvantage is the other one.
	// Floored at 0: out-levelling helps, being out-levelled does not hurt.
	bonus := float64(attackerLevel-defenderLevel) * LevelAdvantagePerLevel
	if bonus < 0 {
		bonus = 0
	}
	if bonus > LevelAdvantageCap {
		bonus = LevelAdvantageCap
	}
	pct := (hra/era*centreRatioScale + bonus) * 100
	if pct < CentreFloorPercent {
		return CentreFloorPercent
	}
	if pct > CentreCeilingPercent {
		return CentreCeilingPercent
	}
	return pct
}

// RollCentred picks a blow in [lo, hi] clustered around centrePercent, the way
// the engine does. The excursion is the minimum of three uniform samples, which
// is what biases the result toward the centre.
//
// A nil r takes ZERO EXCURSION -- the centre itself. That differs from
// RollDamage's "nil rolls the maximum" convention on purpose: a centred
// distribution has no maximum to take, and the deterministic analogue of "no
// randomness" is the point the distribution is built around.
func RollCentred(lo, hi int, centrePercent float64, r *rand.Rand) int {
	if hi < lo {
		lo, hi = hi, lo
	}
	pct := centrePercent
	if r != nil {
		p := math.Min(math.Min(r.Float64(), r.Float64()), r.Float64()) * 100
		if r.Intn(2) == 0 {
			pct -= p
		} else {
			pct += p
		}
	}
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	return lo + int(math.Round(pct/100*float64(hi-lo)))
}
