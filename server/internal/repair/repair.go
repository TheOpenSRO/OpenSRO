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
// clamped to [MinUnitPrice, MaxUnitPrice].
//
// `refRecord[0xa4]` IDENTIFIED 2026-09-17 as **_RefObjCommon field 28**, from
// `fields2.py` on `RefObjCommon_ExtractData` (the scanner validated against that
// function's independently-fixed 58-field count). It belongs to the COMMON
// record, not the item-specific one -- `RefObjItem::ExtractData` writes nothing
// below `+0x198`.
//
// That does NOT give it a text column. `docs/protocol/refobj_binary_format.md`
// says outright that treating "consumed field N" as "text column N" is wrong:
// the binary tables are self-describing, carry a per-column schema, and the
// parser skips columns, so binary field 57 and text column 57 are different
// fields. Mapping field 28 to an itemdata column needs that schema, and until
// it is read, priceBasis stays a caller-supplied input rather than something
// this package can look up.
//
// `refRecord[0xa4]` is the item's
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

// The object offsets this model reads.
//
// WHICH HALF OF THE RECORD THEY LIVE IN IS NOW SETTLED (2026-09-17), and it
// matters because the two halves are deserialised by different functions, so a
// column index for one would be wrong for the other.
//
// A `CRefObjItem` is ONE object with two adjacent halves:
//
//	0x000 .. 0x184   written by RefObjCommon_ExtractData   -- the common record
//	0x198 .. 0x53d   written by RefObjItem::ExtractData    -- the item record
//
// The ranges are disjoint, which is the proof. Every `+0xa4` in
// RefObjItem::ExtractData turned out to be `[esp+0xa4]` -- a stack local, not a
// record store -- so the item half never touches it, and
// RefObjCommon_ExtractData writes `record+0xa4` through a register traced back
// to the record pointer it spills at entry.
//
// So **the repair price basis and the restore cost are COMMON-record fields**:
// properties every game object has, not item-specific ones. That is not a
// curiosity -- it is why a fortress structure can be charged from the same
// field, below.
const (
	// PriceBasisOffset is `+0xa4`, a _RefObjCommon field.
	PriceBasisOffset = 0xa4
	// RestoreCostOffset is `+0xa8`, also _RefObjCommon: a FLAT cost charged
	// when an object is restored rather than merely repaired.
	RestoreCostOffset = 0xa8
	// MaxDurabilityOffset is `+0x194` on the item instance.
	MaxDurabilityOffset = 0x194
	// CurrentDurabilityOffset is `+0x38` on the item's data block -- the same
	// block whose `+0x18` is the reference record.
	CurrentDurabilityOffset = 0x38

	// CommonHalfEnd is the last offset the common deserializer writes, and the
	// first item offset is CommonHalfStart below it -- see the block comment.
	CommonHalfEnd = 0x184
	ItemHalfStart = 0x198
)

// RestorePredicateSlot is vtable slot 55 (`+0xdc`), the "can this be restored"
// question both restore paths ask before charging RestoreCostOffset.
const RestorePredicateSlot = 55

// RestoreCostReaders are the two functions that read RestoreCostOffset, and
// they are the evidence for what it is. They are in unrelated subsystems and
// have the same shape:
//
//	if (!obj->vt[55]())  refuse;
//	cost = refRecord[0xa8];
//	if (gold < cost)     refuse;
//	gold -= cost;
//
// with GObjNPCNPC::HandleRepairRequest refusing CANNOT_BE_REVIVED (0x1c12) and
// SiegeFortressMgr's structure path refusing FORT_BATTLEAIDE_REPAIR_FAIL
// (0x2830). One field, two subsystems, one guard slot -- which is what makes it
// a common-record cost rather than an item-repair detail.
var RestoreCostReaders = []string{
	"GObjNPCNPC::HandleRepairRequest",         // 0x004c7af0
	"SiegeFortressMgr::HandleStructureRepair", // 0x00634950
}
