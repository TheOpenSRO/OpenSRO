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

	// The variance group each OTHER stat reads is the ORDER of
	// Char_BuildAggregateStats' (0x00495d60) interpolation blocks for that
	// item kind -- `mov esi,N` before each Item_VarianceFactor call -- and
	// that order is NOT the stat's triple index in the ref row (round 243,
	// 2026-09-19, read off the disassembly; an earlier note said "triple k =
	// group k", which holds for durability alone). Armour: group 1 is PDStr,
	// 2 MDInt, 3 physical defence (ref +0x1bc/+0x1c0/+0x1c4 -> item+0x198,
	// param 5), 4 magic defence (+0x1ec/+0x1f0/+0x1f4 -> +0x1a8, param 6),
	// 5 ER. A shield inserts block rate at 3 (+0x1e0.. -> +0x1a4, param 10)
	// and shifts the two defences to 4 and 5.
	ArmourPhysDefenseGroup = 3 // 0x495f26
	ArmourMagDefenseGroup  = 4 // 0x495fa0
	ArmourParryGroup       = 5 // 0x496062: ER, ref +0x1c8/+0x1cc (itemdata 68/69) -> item+0x19c -> param 9
	ShieldBlockGroup       = 3 // 0x4967b0
	ShieldPhysDefenseGroup = 4 // 0x49682a
	ShieldMagDefenseGroup  = 5 // 0x4968a4
	// A weapon (the branch at 0x4960b7..0x496586): group 1 the physical
	// reinforce pair (+0x258/+0x25c min, +0x264/+0x268 max -> +0x1c8/+0x1cc,
	// params 34/36), 2 the magical reinforce pair (+0x270.. -> +0x1d0/+0x1d4,
	// params 35/37), 3 attack rate, 4 the PHYSICAL DAMAGE pair (+0x228/+0x22c
	// min and +0x234/+0x238 max, one `mov esi,4` at 0x4963f0 serving both
	// stores at +0x1b8/+0x1bc, params 13/14), 5 the MAGICAL DAMAGE pair
	// (+0x240.. and +0x24c.. -> +0x1c0/+0x1c4, params 15/16), 6 critical.
	WeaponPhysReinforceGroup = 1 // 0x496150
	WeaponMagReinforceGroup  = 2 // 0x49623f
	WeaponAttackRateGroup    = 3 // 0x49632e
	WeaponPhysDamageGroup    = 4 // 0x4963f0
	WeaponMagDamageGroup     = 5 // 0x4964df
	WeaponCriticalGroup      = 6 // 0x4965ce

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

// WhiteStat is the base of every stat Char_BuildAggregateStats interpolates:
// L + q*(U-L), q the instance's factor for the stat's variance group (Group/31).
// The engine adds Inc*plus on top; srrevamp instances carry no plus level, so
// that term is zero here. A zero range (U == L) returns L whatever the variance.
func WhiteStat(lo, hi float64, variance uint64, group int) float64 {
	q := float64(Group(variance, group)) / GroupMax
	return lo + q*(hi-lo)
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
