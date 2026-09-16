package combat

import "github.com/OpenSRO/srrevamp/server/internal/refdata"

// AttackType is a skill's damage-type mask -- `att` value[0] in the skill's
// Param block, the word this project read past for a year while consuming the
// three numbers behind it.
//
// It is RECOVERED, and it is the engine's own switch for which half of a blow
// exists. `Combat_ResolveDamage` (0058e5f0) computes two independent damages
// into one record and sums them:
//
//	rec[0x28] = Formula_MitigatePhysicalDamage(...)    // physical half
//	rec[0x24] = Formula_MitigateMagicalDamage(...)     // magical half
//	rec[0x20] = rec[0x28] + rec[0x24]
//
// and each formula opens by returning 0 unless its own bit is set in this mask:
//
//	if (skill[0x230] == 0 || ... || ((**(byte **)(skill + 0x230) & BIT) == 0))
//	    return 0;                      // BIT = 4 physical (0040e450)
//	                                   // BIT = 8 magical  (0040e830)
//
// Which bit is which is settled twice over, by two sources that were not asked
// to agree. The formulas' raw-damage builders read different ParamKeeper stats
// -- 0040db50 reads param `(max ? 1 : 0) + 13`, 0040dc10 reads `+ 15` -- and
// the recovered param registry names 13/14 "phys damage low/high" and 15/16
// "mag damage low/high" independently of any of this.
//
// THE SUM IS SAFE, which is the point of the whole recovery. This project left
// the magical half unimplemented for three ticks because summing two halves
// looked like it would double a blow. Measured over the real table it cannot:
// of 31,605 skilldata rows carrying `att`, the distribution of value[0] is
//
//	5  {1,4}  17,075 physical      10 {2,8}   6,971 magical
//	6  {2,4}   4,055 physical       9 {1,8}   2,528 magical
//	                                8 {8}       966 magical
//	0/1/2         10 neither
//
// and **zero rows set both bit 4 and bit 8**. The two halves are mutually
// exclusive by authoring, so the engine's sum always has exactly one live term.
// It is not an addition of two damages; it is how the engine writes "whichever
// half this skill deals".
//
// Bits 1 and 2 are an orthogonal axis. In the magical formula they choose which
// flat-absorption param the defender pays -- bit 1 selects param 130, bit 2
// param 131, through the getter at vtable +0x104. Nothing here models those
// params yet (both default to 0 in the registry, so they contribute nothing to
// an unbuffed character), so this type exposes the axis without acting on it.
//
// The same 4-bit vocabulary is shared by two other skill codes: `skc` (field
// 0x490) is AND-ed against this mask as a filter, and `pw` (field 0x2b4)
// inverts it -- a set bit there *removes* the corresponding half. See
// docs/protocol/skill_params.md.
type AttackType int

// The bits, as the two mitigation formulas test them.
const (
	// AttackPhysical gates Formula_MitigatePhysicalDamage (0040e450).
	AttackPhysical AttackType = 4
	// AttackMagical gates Formula_MitigateMagicalDamage (0040e830).
	AttackMagical AttackType = 8

	// AttackClassA and AttackClassB are the second axis, selecting the
	// defender's flat-absorption param (130 and 131 respectively). Named by
	// position rather than by meaning: what distinguishes the two classes was
	// not recovered, and inventing a name for it would be the kind of
	// plausible fiction this project has paid for before.
	AttackClassA AttackType = 1
	AttackClassB AttackType = 2
)

// IsPhysical reports whether the blow has a physical half.
//
// An unknown mask (0) reads as physical. That is deliberate and is NOT a claim
// about the engine, which would deal no damage at all: 0 is what a skill record
// from an export predating the AttackType column carries, and treating it as
// physical keeps such an export behaving exactly as it did before the column
// existed. The ten real rows that genuinely carry 0, 1 or 2 are buff-shaped and
// deal no weapon damage anyway.
func (t AttackType) IsPhysical() bool {
	if t&(AttackPhysical|AttackMagical) == 0 {
		return true
	}
	return t&AttackPhysical != 0
}

// IsMagical reports whether the blow has a magical half. An unknown mask (0) is
// not magical, so an old export cannot silently reroute damage -- see
// IsPhysical.
func (t AttackType) IsMagical() bool { return t&AttackMagical != 0 }

// Known reports whether the mask actually names a damage half, distinguishing a
// real physical skill from an export that predates the column.
func (t AttackType) Known() bool { return t&(AttackPhysical|AttackMagical) != 0 }

// WeaponRange picks the ends of a weapon's damage roll for a blow of the given
// type, and is the ONE place that decision is made. It used to live inline in
// session.attackerDamage with a copy of itself in the test, which is how the
// test went on asserting the old rule after the rule changed.
//
// str and intel are the wielder's Strength and Intellect. WHICH STAT GOES WITH
// WHICH HALF IS RECOVERED, from the parameter graph GObjPC_InitStats (004e3200)
// declares edge by edge:
//
//	1 (str) -> 17 -> 13    phys low      34 -> 17 at slot 3
//	1 (str) -> 18 -> 14    phys high     36 -> 18 at slot 3
//	2 (int) -> 19 -> 15    mag low       35 -> 19 at slot 3
//	2 (int) -> 20 -> 16    mag high      37 -> 20 at slot 3
//
// Params 13-16 are named "phys/mag damage low/high" in the recovered registry,
// and the two mitigation formulas read exactly these pairs -- 0040db50 reads
// param `(max ? 1 : 0) + 13`, 0040dc10 reads `+ 15`. Param 2 carries the game's
// own tag `int`, so Intellect is named by the binary rather than by position.
//
// The magical half therefore scales with INTELLECT, not Strength. This code
// passed `str` into both halves until 2026-09-16 -- a real bug, and one that
// symmetry alone would not have justified fixing, which is why the edge list
// was read instead of assumed.
//
// Slot 3 is the percent scale (ParamKeeper_EvaluateParam divides it by 100), so
// each derived term is stat*reinforce/100 -- see ReinforceDamage.
func WeaponRange(item *refdata.Item, str, intel int, atk AttackType) (min, max int) {
	if item == nil {
		return 0, 0
	}
	min = int(item.PhysAttackMin) + ReinforceDamage(str, item.ReinforcePhysMin)
	max = int(item.PhysAttackMax) + ReinforceDamage(str, item.ReinforcePhysMax)

	// The magical columns are used when the blow is magical, and also when the
	// weapon has no physical damage at all -- 448 of 1,582 real attack-carrying
	// items are magical-only, and reading only the physical columns would give
	// them 0 and land every swing on MitigateDamage's floor of 1.
	//
	// NOT DONE, deliberately: routing a magical blow to the magical columns
	// when the weapon has none. That IS the engine's behaviour and it is now
	// fully grounded -- Char_PublishCombatStats (00497830) writes params 34-37
	// UNCONDITIONALLY (the only branch substitutes 0.0, it never skips the
	// write), so a physical-only weapon writes param 35 = 0 rather than leaving
	// it at the registry default of 100, slot 3 scales Intellect to nothing,
	// and the magical half really is 0. Measured: all 574 physical-only items
	// carry no magical reinforce, with no exceptions.
	//
	// The engine can afford that because it refuses the cast first: skills
	// carry ReqCast_Weapon1/2 (skilldata columns 50/51) and srrevamp does not
	// model them yet (refdata/skill.go says so outright). Shipping the penalty
	// without the prevention would give a tester holding a sword 1 damage from
	// a skill the real game would not have let them cast. The gate comes
	// first; this follows it.
	if (atk.IsMagical() || max <= 0) && item.MagAttackMax > 0 {
		min = int(item.MagAttackMin) + ReinforceDamage(intel, item.ReinforceMagMin)
		max = int(item.MagAttackMax) + ReinforceDamage(intel, item.ReinforceMagMax)
	}
	return min, max
}
