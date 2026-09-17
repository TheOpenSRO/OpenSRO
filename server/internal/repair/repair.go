// Package repair holds the item-repair cost model recovered from
// SR_GameServer.exe.
//
// srrevamp has item durability columns in its reference data and no repair
// path. This is the path.
//
// See docs/protocol/durability.md.
package repair

// The refusal codes, with the client's name for each.
const (
	ErrNotEnoughMoney   = 0x1c07 // INTERACTION_FAIL_NOT_ENOUGH_MONEY
	ErrNothingToRepair  = 0x1c09 // returned when the item is already whole
	ErrCannotBeRepaired = 0x1c11 // INTERACTION_FAIL_CANNOT_BE_REPAIRED
	ErrCannotBeRevived  = 0x1c12 // INTERACTION_FAIL_CANNOT_BE_REVIVED
)

// MaxUnitsPerRepair is 100,000 (`0x186a0`), the cap on how many durability
// points one repair may restore:
//
//	496f78  cmp esi,0x186a0
//	496f7e  jb  keep
//	496f80  mov esi,0x186a0
//
// applied to the affordable count, before it is compared against what the item
// is actually missing.
const MaxUnitsPerRepair = 100000

// MinUnitPrice is 1.0. The per-unit price is clamped from below by a literal
// `fld1`:
//
//	496f1b  fld1
//	496f1d  fld DWORD PTR [esp+0x28]     ; the computed ratio
//	496f21  fcom st(1)
//
// so a repair never costs less than one gold per durability point, whatever the
// item's price basis works out to.
const MinUnitPrice = 1.0

// MaxUnitPrice is the upper guard, `9.9999997e+37` at `.rdata 0x00b45c44`.
// It is a float-overflow guard rather than a tuning value -- no real item can
// approach it -- and is recorded because the clamp is two-sided in the binary
// and a one-sided reimplementation would not be faithful.
const MaxUnitPrice = 9.9999997e+37

// UnitPrice is the cost of restoring one durability point:
//
//	price = (float)refRecord[0xa4] / (float)item[0x194]
//
// clamped to [MinUnitPrice, MaxUnitPrice]. `refRecord[0xa4]` is the item's
// price basis and `item[0x194]` its maximum durability, so a FULL repair of an
// undamaged-to-destroyed item costs the basis -- the division spreads the basis
// across the item's durability range.
//
// Both operands are read with the signed-to-float fixup the compiler emits for
// values it treats as unsigned (`fadd 4294967296.0` when negative), so both are
// unsigned quantities.
func UnitPrice(priceBasis, maxDurability int) float64 {
	if maxDurability == 0 {
		// The binary divides without guarding this; a zero denominator cannot
		// occur for a real item, and returning the floor is the safe reading.
		return MinUnitPrice
	}
	p := float64(priceBasis) / float64(maxDurability)
	if p < MinUnitPrice {
		return MinUnitPrice
	}
	if p > MaxUnitPrice {
		return MaxUnitPrice
	}
	return p
}

// Quote is what one repair would cost and restore.
type Quote struct {
	// Units is how many durability points the repair restores.
	Units int
	// Cost is what it charges, `UnitPrice * Units`.
	Cost float64
	// Refusal is non-zero when no repair happens.
	Refusal int
}

// Estimate reproduces GItemEquip::FUN_00496e60 (0x00496e60) in its order:
//
//	if (gold <= 0)                    -> 0x1c07
//	missing = maxDurability - currentDurability
//	if (missing < 1)                  -> 0x1c09
//	price      = clamp(basis / maxDurability, 1.0, 1e38)
//	affordable = clamp((int64)(gold / price), 0, 100000)
//	units      = min(missing, affordable)
//	cost       = price * units
//
// Note the cap applies to the AFFORDABLE count, not to the final units, so an
// item missing more than 100,000 points cannot be fully repaired in one go even
// by a character who could pay for it.
func Estimate(gold int64, priceBasis, maxDurability, currentDurability int) Quote {
	if gold <= 0 {
		return Quote{Refusal: ErrNotEnoughMoney}
	}
	missing := maxDurability - currentDurability
	if missing < 1 {
		return Quote{Refusal: ErrNothingToRepair}
	}
	price := UnitPrice(priceBasis, maxDurability)
	affordable := int64(float64(gold) / price)
	if affordable < 0 {
		affordable = 0
	}
	if affordable > MaxUnitsPerRepair {
		affordable = MaxUnitsPerRepair
	}
	units := int64(missing)
	if affordable < units {
		units = affordable
	}
	if units <= 0 {
		return Quote{Refusal: ErrNotEnoughMoney}
	}
	return Quote{Units: int(units), Cost: price * float64(units)}
}

// The object offsets this model reads, recorded so a later pass checking them
// does not have to re-derive which is which.
const (
	// PriceBasisOffset is `+0xa4` in the item's reference record.
	PriceBasisOffset = 0xa4
	// MaxDurabilityOffset is `+0x194` on the item instance.
	MaxDurabilityOffset = 0x194
	// CurrentDurabilityOffset is `+0x38` on the item's data block -- the same
	// block whose `+0x18` is the reference record.
	CurrentDurabilityOffset = 0x38
)
