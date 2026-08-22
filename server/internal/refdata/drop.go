package refdata

// MonsterDrop is this project's own curated subset of one real
// _RefMonster_AssignedItemRndDrop row: which real item group a monster can
// drop from, and at what rate/quantity. See docs/protocol/refdata_schema.md
// for the full real column list -- Service, param1, param2 are left out,
// same curation discipline as refdata.Item/Skill (their meaning isn't
// confirmed).
type MonsterDrop struct {
	MonsterID     int64
	ItemGroupID   int64
	Overlap       bool
	DropAmountMin int
	DropAmountMax int
	DropRatio     float64
}

// DropGroupEntry is this project's own curated subset of one real
// _RefDropItemGroup row: one item's real relative weight within a drop
// group. RefMagicGroupID (a link to a real magic-option table this project
// hasn't inspected yet) is left out.
type DropGroupEntry struct {
	GroupID     int64
	CodeName    string
	ItemID      int64
	SelectRatio float64
}
