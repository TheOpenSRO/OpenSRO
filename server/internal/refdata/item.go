// Package refdata holds this project's own static game-data model (item
// stats, and eventually skills/drops) plus an importer for populating it
// from a player-supplied export of their own legally-obtained game data —
// the same "bring your own data" approach this repo already uses for pk2
// client assets (see docs/LEGAL.md). No actual game-balance numbers are
// ever committed to this repo; only the schema/format is.
package refdata

import "errors"

// ErrItemNotFound means the store has no row for that item id. It is a
// normal answer, not a failure: reference data is brought by the operator
// (see docs/LEGAL.md), so a deployment that has imported nothing -- or has
// imported a partial export -- has items nobody has stats for. Callers
// treat those as contributing nothing rather than refusing to work, and
// keep real errors for a lookup that actually broke.
var ErrItemNotFound = errors.New("refdata: no such item")

// Item is this project's own, deliberately curated subset of item stats —
// not a 1:1 mirror of the original's ~105-column layout (documented
// structurally in docs/protocol/refdata_schema.md), just the fields that
// matter for combat/equipment math. Extend as gameplay needs grow.
type Item struct {
	ID       int64
	MaxStack int
	// TypeID1..4 are the game's own four-level classification of the item:
	// 3/1/x/y is equipment, where TypeID3 says which family (China's
	// garment/protector/armour are 1/2/3, Europe's robe/light/heavy are
	// 9/10/11, weapons 6, shields 4, accessories 7) and TypeID4 which
	// piece -- for armour 1 helm, 2 shoulder guard, 3 mail, 4 pants,
	// 5 gauntlet, 6 boots, which is what decides the slot an item may go
	// in. See docs/protocol/ITEM_FORMAT.md.
	TypeID1, TypeID2, TypeID3, TypeID4 int
	// Country is the race the item belongs to: 0 China, 1 Europe, 3 either.
	Country int
	// ReqGender is who may wear it: 1 a man, 0 a woman, 2 either.
	ReqGender int
	// ReqLevelType1/ReqLevel1 are the first of the table's four requirement
	// pairs. Type 1 is the character's own level -- what every ordinary
	// armour and weapon row carries.
	ReqLevelType1, ReqLevel1       int
	ReqStr                         int
	ReqInt                         int
	ItemClass                      int
	// Price is the NPC buy price in gold, and SellPrice what the NPC pays to
	// buy it back -- both real, from the client's own itemdata (_RefObjCommon
	// Price and SellPrice columns; SellPrice < Price on every row checked).
	// This is the one place the earlier "no real vendor price" conclusion was
	// wrong: it held for the restored DB's _RefObjItem, but the client
	// itemdata.txt carries these columns. Zero when an import predates them,
	// in which case the shop falls back to its own formula. See
	// docs/protocol/refdata_schema.md.
	Price     int64
	SellPrice int64
	TwoHanded bool
	DurabilityMin, DurabilityMax   float64
	PhysDefenseMin, PhysDefenseMax float64
	MagDefenseMin, MagDefenseMax   float64
	PhysAttackMin, PhysAttackMax   float64
	MagAttackMin, MagAttackMax     float64
	HitRateMin, HitRateMax         float64
	CriticalMin, CriticalMax       float64
}
