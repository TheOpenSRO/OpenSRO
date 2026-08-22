package refdata

// Skill is this project's own, deliberately curated subset of the real
// _RefSkill table's columns -- not all ~118 (only the first ~20 have been
// catalogued at all so far, see docs/protocol/refdata_schema.md), and of
// those, this keeps only the ones with reasonably confirmed semantics --
// the same curation approach refdata.Item already uses (it drops _RefObjItem
// columns like ER_*/PAR_*/BR_* whose exact meaning isn't decoded either).
//
// Notably absent: any damage/effect value. No confirmed _RefSkill column
// encodes what a skill actually does in combat -- that data plausibly lives
// in a separate, uncatalogued ability/effect system this project hasn't
// found yet. skill.Catalog's own DamageBonus stays an own-design choice
// layered on top of whichever real skill this identifies, not replaced by
// real data the way refdata.Item's stats are.
type Skill struct {
	ID      int64
	GroupID int64

	// BasicCode is an internal symbolic identifier (plausibly a SKILL_*
	// constant name), not display text. BasicName is a second confirmed
	// string column, but -- per refdata_schema.md's still-open "where do
	// display names live" question -- it's not confirmed to be real
	// human-readable text either, just a second internal string; treat it
	// the same way, not as something safe to show a player yet.
	BasicCode string
	BasicName string

	BasicLevel       int
	BasicChainCode   int64
	BasicRecycleCost int

	// Real timing/behavior fields, all in milliseconds unless noted.
	PreparingTimeMs  int
	CastingTimeMs    int
	ActionDurationMs int
	ReuseDelayMs     int
	CoolTimeMs       int
	FlyingSpeed      float64
	Interruptable    bool
	Overlap          bool
	AutoAttackType   int
}
