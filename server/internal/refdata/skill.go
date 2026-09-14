package refdata

// Skill is this project's own, deliberately curated subset of the real
// _RefSkill table's 118 columns (all confirmed as of 2026-08-22, see
// docs/protocol/refdata_schema.md) -- this keeps only the ones with
// reasonably confirmed semantics, the same curation approach refdata.Item
// already uses (it drops _RefObjItem columns like ER_*/PAR_*/BR_* whose
// exact meaning isn't decoded either). Real column groups not represented
// here at all: the full targeting-rule bitset (Target_*/TargetGroup_*),
// weapon-cast requirements, and the 50 generic Param slots -- real, but not
// curated in yet.
//
// Notably absent: any damage/effect value. No confirmed _RefSkill column
// encodes what a skill actually does in combat, even after all 118 columns
// were catalogued -- that data plausibly lives in a separate, uncatalogued
// ability/effect system this project hasn't found yet. skill.Catalog's own
// DamageBonus stays an own-design choice layered on top of whichever real
// skill this identifies, not replaced by real data the way refdata.Item's
// stats are.
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

	// Range is the real skill range (Action_Range), same unit convention as
	// everything else in this project's real distance fields (unconfirmed
	// scale, see the standing real-world-scale open item in
	// docs/protocol/MAPO_FORMAT.md).
	Range int

	// Real resource cost to use the skill (Consume_HP/Consume_MP) -- not
	// previously known before the 2026-08-22 full-column pass.
	ConsumeHP int
	ConsumeMP int

	// AttackPercent is the share of the wielder's weapon damage this skill
	// deals, and DamageMin/DamageMax a flat range added on top. REAL, from
	// the skill's own 'att' parameter (see cmd/export-refdata's attackParam):
	// a Sword Smash is 143% plus 15-18 at level 1, a plain swing 60% plus
	// nothing. Zero for the many skills that are buffs, heals or passives.
	AttackPercent int
	DamageMin     int
	DamageMax     int

	// Real cost/prerequisite to learn the skill (ReqLearn_SP/ReqLearn_Race).
	ReqLearnSP   int
	ReqLearnRace int

	// The mastery this skill belongs to and the mastery level required to learn
	// it (ReqCommon_Mastery1 / ReqCommon_MasteryLevel1). These are what the
	// skill window gates a skill on -- a skill is learnable once the character's
	// level in Mastery1 reaches MasteryLevel1. The real table has a second
	// mastery/level pair too; only the first is curated in here for now.
	Mastery1      int64
	MasteryLevel1 int

	// UISkillName is a real, plausible candidate for the skill's actual
	// display name (UI_SkillName) -- distinct from BasicCode/BasicName, but
	// still not 100% confirmed to hold literal player-facing text rather
	// than another internal lookup key. Treat with the same caution as
	// BasicName until confirmed either way.
	UISkillName string
}
