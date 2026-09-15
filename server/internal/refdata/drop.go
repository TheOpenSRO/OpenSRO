package refdata

// MonsterDrop is this project's own curated subset of one real
// _RefMonster_AssignedItemRndDrop row: which real item group a monster can
// drop from, and at what rate/quantity. See docs/protocol/refdata_schema.md
// for the full real column list -- Service, param1, param2 are left out,
// same curation discipline as refdata.Item/Skill (their meaning isn't
// confirmed).
type MonsterDrop struct {
	MonsterID   int64
	ItemGroupID int64
	Overlap     bool

	// DropAmountMin/Max are NOT a stack size. They bound how many
	// INDEPENDENT drop attempts this row makes, each rolled separately at
	// DropRatio -- so a row with 1..3 and a 10% ratio usually yields nothing,
	// sometimes one item, and rarely three. Recovered from
	// CRefDropData__AddAssignedItemDrop, which picks
	// `count = rand() % (max-min+1) + min` from the bytes at record+6/+7 and
	// then loops `count` times, rolling afresh each iteration.
	//
	// This is a different mechanic from "roll once, then choose a quantity",
	// and the difference is visible in play: the two give the same mean only
	// when DropRatio is 1.0.
	DropAmountMin int
	DropAmountMax int

	// DropRatio is a PROBABILITY FRACTION in [0, 1], not a percentage. The
	// engine compares it against a per-million roll:
	//
	//	roll = (rand()<<15 | rand()) % 1000000       // [0, 999999]
	//	if (roll <= dropRatio * 1000000.0) { drop }
	//
	// The two rand() calls are because MSVC's rand() yields 15 bits; the
	// scale is `fmul QWORD ds:0xb45bc0` = 1000000.0, a DOUBLE, while the
	// ratio itself is `fld DWORD [record+8]`, a float32.
	DropRatio float64
}

// DropGroupEntry is this project's own curated subset of one real
// _RefDropItemGroup row: one item's real relative weight within a drop
// group. RefMagicGroupID (a link to a real magic-option table this project
// hasn't inspected yet) is left out.
type DropGroupEntry struct {
	GroupID  int64
	CodeName string
	ItemID   int64

	// SelectRatio is the entry's weight in a CUMULATIVE pick across the
	// group, on the same per-million scale as MonsterDrop.DropRatio: the
	// engine accumulates `round(selectRatio * 1000000)` across entries and
	// takes the first whose running total is not less than a per-million
	// roll. So the ratios within one group are fractions meant to sum
	// towards 1, not independent chances.
	SelectRatio float64
}
