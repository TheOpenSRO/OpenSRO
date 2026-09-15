package refdata

import "math/rand"

// DropRollScale is the denominator the engine rolls against for every drop
// decision: 1,000,000.
//
// RECOVERED. `CRefDropData__AddAssignedItemDrop` builds its roll from two
// rand() calls because MSVC's rand() yields only 15 bits, then takes it modulo
// a literal 1,000,000 (`mov ecx,0xf4240`) and compares against the ratio scaled
// by the same figure (`fmul QWORD ds:0xb45bc0` = 1000000.0, a double):
//
//	roll = (rand()<<15 | rand()) % 1000000       // [0, 999999]
//	if (roll <= ratio * 1000000.0) { ... }
//
// The group picker in RefItemDrop::FUN_00724e30 uses the identical scale for
// SelectRatio, which is what establishes that both ratios are fractions on one
// common scale rather than two differently-encoded numbers.
const DropRollScale = 1000000

// rollBelow reports whether a fresh per-million roll lands at or below ratio.
// Split out so both drop paths share exactly one rounding rule.
//
// The comparison is `<=` against a roll in [0, 999999], which is the engine's
// own and is very slightly generous: a ratio of 0 still fires when the roll is
// 0, one chance in a million. That is reproduced rather than corrected, because
// the point of this file is to match the engine, and a caller that wants "never"
// should not have the row at all.
func rollBelow(rnd *rand.Rand, ratio float64) bool {
	if ratio >= 1 {
		return true
	}
	if ratio < 0 {
		return false
	}
	return int64(rnd.Intn(DropRollScale)) <= int64(ratio*DropRollScale)
}

// RollAssignedDrop returns how many item instances one assigned-drop row
// produces for a single kill.
//
// The engine's shape, not a simplification of it: pick an attempt count in
// [DropAmountMin, DropAmountMax], then roll DropRatio independently that many
// times and count the successes. A row with 1..3 attempts at a 10% ratio
// therefore yields nothing most kills and three items rarely -- which is not
// what "roll once, then pick a quantity in 1..3" produces.
//
// rnd may be nil, in which case the global source is used.
func (d MonsterDrop) RollAssignedDrop(rnd *rand.Rand) int {
	if rnd == nil {
		rnd = rand.New(rand.NewSource(rand.Int63()))
	}
	lo, hi := d.DropAmountMin, d.DropAmountMax
	if hi < lo {
		lo, hi = hi, lo
	}
	if hi <= 0 {
		return 0
	}
	if lo < 0 {
		lo = 0
	}
	attempts := lo
	if hi > lo {
		attempts += rnd.Intn(hi - lo + 1)
	}

	hits := 0
	for i := 0; i < attempts; i++ {
		if rollBelow(rnd, d.DropRatio) {
			hits++
		}
	}
	return hits
}

// SelectFromGroup picks one entry from a drop group by cumulative SelectRatio
// weight, the way RefItemDrop::FUN_00724e30 does: accumulate each entry's ratio
// on the per-million scale and take the first whose running total reaches the
// roll.
//
// Returns nil when the group is empty, or when the ratios sum to less than 1
// and the roll falls past the last entry -- that is a real outcome in the
// engine (a group need not be exhaustive), not an error to paper over.
//
// rnd may be nil, in which case the global source is used.
func SelectFromGroup(entries []*DropGroupEntry, rnd *rand.Rand) *DropGroupEntry {
	if len(entries) == 0 {
		return nil
	}
	if rnd == nil {
		rnd = rand.New(rand.NewSource(rand.Int63()))
	}
	roll := int64(rnd.Intn(DropRollScale))
	var cumulative int64
	for _, e := range entries {
		if e == nil || e.SelectRatio <= 0 {
			continue
		}
		cumulative += int64(e.SelectRatio*DropRollScale + 0.5) // engine ROUNDs
		if cumulative >= roll {
			return e
		}
	}
	return nil
}
