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
// RESOLVED 2026-09-17, and CORRECTED 2026-09-20 (round 304).
// `refRecord[0xa4]` is **_RefObjCommon field 28**, which is **itemdata text
// column 27**, not 28. Deserializer field indices are 1-based over the row and
// column indices are 0-based, so the two differ by one, and the earlier note
// here equated them.
//
// The correction is measured, not argued. `fields.py` on
// `RefObjCommon_ExtractData` (0x006a3090) resolves field 28 -> `+0xa4` and
// field 29 -> `+0xa8`, and three disjoint anchors tie field k to row field k:
// fields 3-7 are five string reads against the row's five name strings, fields
// 33-40 are the stride-8 requirement pairs, fields 53-57 are five more string
// reads against the row's .bsr/.bsr/.ddj asset paths and two "xxx".
//
// WHAT IT IS, from the use-site rather than its shape: the engine computes
// `price = basis/maxDurability` and `cost = price * units`, so repairing from
// zero to full buys `units = maxDurability` and costs exactly `basis`. Column 27
// is therefore **the item's full-repair cost in gold**. Checked against the real
// table: ITEM_CH_SWORD_01_A has column 27 = 198 and durability 62/76, giving
// 2.6 gold per unit and a full repair of 198 against a vendor price (column 26)
// of 890. Column 28 (297) is `+0xa8`, the adjacent flat restore cost.
//
// WHY THE OFF-BY-ONE SURVIVED A TEST. TestFullRepairCostsExactlyTheBasis checks
// that a full repair costs the basis -- which is true of ANY number fed in as
// the basis, because it is an identity of the formula, not of the column. It
// described the arithmetic and could never have caught the wrong column. The
// column is pinned instead by TestRepairCostReadsTheBasisColumn, in the
// exporter, where the two adjacent columns are given different values.
//
// The data agrees, and this is the check that discriminates: across the whole
// real table column 27 is non-zero for 13,949 of the 13,961 items that have
// durability and **zero for every one of the items that do not**, which is the
// predicate a repair basis must satisfy. The twelve exceptions are one coherent
// set -- the `_SUPER` HEAVY_07 armours, durability 9000/9999, vendor price 0 --
// which never needs repairing.
//
// A FALSE ALARM THIS REPLACES, worth keeping. An earlier note here recorded a
// conflict: column 28 looked "durability-shaped" -- one of a 1.5-ratio pair
// climbing with tier -- which divided into max durability would make UnitPrice a
// constant. That reading was an off-by-one in a column dump of mine: the pair is
// 27/28, not 28/29, and column 26 is Price (`export-refdata`'s `fPrice = 26`),
// which is what the mislabelled column actually held. Durability is 63/64, not
// 28/29. The conflict was mine, not the binary's.
//
// // `refRecord[0xa4]` is the item's
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
