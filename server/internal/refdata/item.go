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
	ID                             int64
	MaxStack                       int
	ReqStr                         int
	ReqInt                         int
	ItemClass                      int
	TwoHanded                      bool
	DurabilityMin, DurabilityMax   float64
	PhysDefenseMin, PhysDefenseMax float64
	MagDefenseMin, MagDefenseMax   float64
	PhysAttackMin, PhysAttackMax   float64
	MagAttackMin, MagAttackMax     float64
	HitRateMin, HitRateMax         float64
	CriticalMin, CriticalMax       float64
}
