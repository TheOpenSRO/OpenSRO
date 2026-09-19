// Package durability is the game's own durability rules, read from
// SR_GameServer.exe and written up in docs/protocol/durability.md. Every
// number here is cited there; none is a choice of this project.
//
//   - An item instance carries a 64-bit Variance: twelve 5-bit groups, one per
//     stat triple, group 0 being durability's. Item_VarianceFactor (0x00495d10)
//     reads a group as ((Variance >> 5*k) & 0x1f) / 31.0.
//   - A fresh item rolls each group as round(RollWhiteStatUnit() * 31), where
//     RollWhiteStatUnit (0x00729280) is the MINIMUM of three rand()/32767 draws
//     (InitItemVarianceAndData, 0x007286c0).
//   - Max durability is round(Dur_L + v0/31 * (Dur_U - Dur_L))
//     (Char_BuildAggregateStats, 0x00495d60); the per-plus increment the
//     formula carries is written as a constant 0 by RefObjItem::ExtractData,
//     and a fresh item's durability starts at its max (SetInitialItemData,
//     0x00728470).
//   - Loss is always -1, rolled by RollDurabilityLoss (0x004a9a90) at
//     min(2*rate, 100) percent: the weapon (slot 6) once per action with rate =
//     hits landed, one armour slot per hit taken (slots 0..7 except 6, rolled in
//     order, the first success wins), the shield (slot 7) once per blocked hit.
//   - ChangeItemDurability (0x004e7100) refuses to go below 0 and, at 0, removes
//     the item's stats from the ParamKeeper: a broken item is dead weight until
//     repaired.
package durability

import "math"

// Rand is the subset of math/rand's *Rand these rules draw from; tests hand
// in a deterministic one.
type Rand interface {
	Intn(n int) int
}

const (
	// RandMax is the C runtime's RAND_MAX the engine divides rand() by --
	// .rdata 0xb45af8, read as 32767.
	RandMax = 32767
	// GroupMax is the top of a 5-bit variance group and the divisor of the
	// white-stat factor -- .rdata 0xb45e28, read as 31.0.
	GroupMax = 31
	// Groups is how many 5-bit groups a Variance holds; Item_VarianceFactor
	// asserts the group index below 12.
	Groups = 12
	// DurabilityGroup is the variance group durability reads: the first
	// stat triple (`xor esi,esi` before the Item_VarianceFactor call in the
	// block that stores max durability).
	DurabilityGroup = 0

	// Untracked marks an instance whose durability is not (yet) followed:
	// a legacy row from before this existed, or a store without reference
	// data to roll from. It is treated as whole and never breaks.
	Untracked = -1
	// Broken is the durability at which an item's stats stop applying.
	Broken = 0

	// SlotWeapon and SlotShield are the equipment slots RollDurabilityLoss
	// names outright (6 and 7); the armour walk covers 0..7 except 6.
	SlotWeapon = 6
	SlotShield = 7
)

// ArmourSlots is the order RollDurabilityLoss rolls a hit's armour loss:
// slots 0..7 skipping the weapon. The first slot whose roll succeeds takes
// the point -- even an empty one, which then simply loses nothing.
var ArmourSlots = []int{0, 1, 2, 3, 4, 5, 7}

// RollWhiteStatUnit is the engine's white-stat unit: the minimum of three
// uniform rand()/RAND_MAX draws. Its density is 3(1-x)^2 -- mean 25%, a
// 31/31 group about 1 in 250,000.
func RollWhiteStatUnit(r Rand) float64 {
	u := 1.0
	for i := 0; i < 3; i++ {
		d := float64(r.Intn(RandMax+1)) / float64(RandMax)
		if d < u {
			u = d
		}
	}
	return u
}

// RollVariance rolls all twelve groups the way InitItemVarianceAndData does
// for an item created without a preset, packing group k at bits 5k..5k+4.
func RollVariance(r Rand) uint64 {
	var v uint64
	for k := 0; k < Groups; k++ {
		g := uint64(math.Round(RollWhiteStatUnit(r) * GroupMax))
		if g > GroupMax {
			g = GroupMax
		}
		v |= g << (5 * uint(k))
	}
	return v
}

// Group returns the 5-bit value of variance group k.
func Group(variance uint64, k int) int {
	return int((variance >> (5 * uint(k))) & 0x1f)
}

// Tracked reports whether an item has a durability at all: its reference row
// carries a durability range. Consumables and quest items do not.
func Tracked(durMin, durMax float64) bool {
	return durMax > 0
}

// MaxDurability is round(Dur_L + v0/31 * (Dur_U - Dur_L)) for the instance's
// group 0, floored at 1 (ApplyDurabilityAndRateOptions never leaves a zero
// max). Items without a range have no max (0).
func MaxDurability(durMin, durMax float64, variance uint64) int {
	if !Tracked(durMin, durMax) {
		return 0
	}
	q := float64(Group(variance, DurabilityGroup)) / GroupMax
	m := int(math.Round(durMin + q*(durMax-durMin)))
	if m < 1 {
		m = 1
	}
	return m
}

// LossChancePercent is min(2*rate, 100): the rate is a hit counter, so a
// single blow rolls at 2%, a five-hit action at 10%.
func LossChancePercent(rate int) int {
	c := 2 * rate
	if c > 100 {
		c = 100
	}
	if c < 0 {
		c = 0
	}
	return c
}

// RollLoss is one durability-loss roll: rand()%100 + 1 <= chance.
func RollLoss(r Rand, rate int) bool {
	chance := LossChancePercent(rate)
	if chance <= 0 {
		return false
	}
	return r.Intn(100)+1 <= chance
}

// ArmourLossSlot rolls a hit's armour loss the engine's way: each slot in
// ArmourSlots in order at the same chance, the first success taking the
// point. It returns that slot, or -1 when every roll failed.
func ArmourLossSlot(r Rand, rate int) int {
	for _, slot := range ArmourSlots {
		if RollLoss(r, rate) {
			return slot
		}
	}
	return -1
}

// Apply is ChangeItemDurability's arithmetic on one value: a refused
// decrease below 0, a clamp to [0, max], and whether the result crosses the
// broken line in either direction. An Untracked value is left alone.
func Apply(current, max, delta int) (next int, broke, mended bool) {
	if current == Untracked || max <= 0 {
		return current, false, false
	}
	if delta < 0 && current == 0 {
		return current, false, false
	}
	next = current + delta
	if next < 0 {
		next = 0
	}
	if next > max {
		next = max
	}
	broke = current > 0 && next == 0
	mended = current == 0 && next > 0
	return next, broke, mended
}

// IsBroken is the stat-removal condition: a tracked item at 0.
func IsBroken(current int) bool { return current == Broken }
