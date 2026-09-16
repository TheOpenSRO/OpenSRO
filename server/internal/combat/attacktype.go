package combat

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
